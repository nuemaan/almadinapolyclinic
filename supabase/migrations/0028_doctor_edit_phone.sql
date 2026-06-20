-- ============================================================================
-- Phase 25 — doctor can also correct the patient's phone number.
-- A shared resolve_patient() handles identity changes (phone and/or name): if the
-- corrected identity matches an existing record on that phone, the visit is merged
-- onto it; otherwise the current record is updated in place. Both save_prescription
-- and add_followup now route name/phone edits through it.
-- ============================================================================

create or replace function resolve_patient(p_visit_id uuid, p_name text, p_phone text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_curphone text; v_curname text; v_phone text; v_name text; v_key text; v_target uuid;
begin
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;
  select phone, name into v_curphone, v_curname from patients where id = v_patient;

  v_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_name  := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if length(v_phone) <> 10 then v_phone := v_curphone; end if;   -- ignore invalid phone
  if v_name = '' then v_name := v_curname; end if;               -- ignore blank name
  v_key := lower(v_name);

  if v_phone is distinct from v_curphone or v_key is distinct from lower(v_curname) then
    select id into v_target from patients
      where phone = v_phone and name_key = v_key and id <> v_patient limit 1;
    if v_target is not null then
      update visits        set patient_id = v_target where id = p_visit_id;
      update prescriptions set patient_id = v_target where visit_id = p_visit_id;
      if not exists (select 1 from visits where patient_id = v_patient) then
        delete from patients where id = v_patient;
      end if;
      v_patient := v_target;
    else
      update patients set phone = v_phone, name = v_name, name_key = v_key where id = v_patient;
    end if;
  end if;
  return v_patient;
end;
$$;
revoke execute on function resolve_patient(uuid, text, text) from public, anon;

-- ---- save_prescription + p_phone -------------------------------------------
drop function if exists save_prescription(uuid, text, jsonb, int, int, int, text, text, text, jsonb, text, text, text, text, text, text);

create or replace function save_prescription(
  p_visit_id    uuid,
  p_doctor_name text,
  p_medicines   jsonb default '[]'::jsonb,
  p_age_years   int  default null,
  p_age_months  int  default null,
  p_age_days    int  default null,
  p_gender      text default null,
  p_residence   text default null,
  p_complaint   text default null,
  p_examination jsonb default '{}'::jsonb,
  p_diagnosis   text default null,
  p_lab         text default null,
  p_notes       text default null,
  p_temperature text default null,
  p_weight      text default null,
  p_name        text default null,
  p_phone       text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  v_patient := resolve_patient(p_visit_id, p_name, p_phone);

  update patients
     set age_years  = coalesce(p_age_years,  age_years),
         age_months = coalesce(p_age_months, age_months),
         age_days   = coalesce(p_age_days,   age_days),
         gender     = coalesce(nullif(p_gender, ''), gender),
         residence  = coalesce(nullif(p_residence, ''), residence)
   where id = v_patient;

  select id into v_rx from prescriptions where visit_id = p_visit_id order by created_at desc limit 1;
  if v_rx is not null then
    update prescriptions
       set doctor_name = p_doctor_name, notes = p_notes,
           medicines = coalesce(p_medicines, '[]'::jsonb), complaint = p_complaint,
           examination = coalesce(p_examination, '{}'::jsonb), diagnosis = p_diagnosis,
           lab_advice = p_lab, temperature = p_temperature, weight = p_weight
     where id = v_rx;
  else
    insert into prescriptions (visit_id, patient_id, doctor_name, doctor_user, notes, medicines,
                               complaint, examination, diagnosis, lab_advice, temperature, weight)
      values (p_visit_id, v_patient, p_doctor_name, auth.uid(), p_notes, coalesce(p_medicines, '[]'::jsonb),
              p_complaint, coalesce(p_examination, '{}'::jsonb), p_diagnosis, p_lab, p_temperature, p_weight)
      returning id into v_rx;
  end if;

  update visits set status = 'done', attended_at = coalesce(attended_at, now()) where id = p_visit_id;
  return v_rx;
end;
$$;
revoke execute on function save_prescription(uuid, text, jsonb, int, int, int, text, text, text, jsonb, text, text, text, text, text, text, text) from public, anon;
grant  execute on function save_prescription(uuid, text, jsonb, int, int, int, text, text, text, jsonb, text, text, text, text, text, text, text) to authenticated;

-- ---- add_followup + p_phone ------------------------------------------------
drop function if exists add_followup(uuid, text, text, text, text, text, text);

create or replace function add_followup(
  p_visit_id      uuid,
  p_complaint     text default null,
  p_examination   text default null,
  p_treatment     text default null,
  p_investigation text default null,
  p_doctor        text default null,
  p_name          text default null,
  p_phone         text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid; v_date text; v_entry jsonb;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  if btrim(coalesce(p_complaint, '')) = '' and btrim(coalesce(p_examination, '')) = ''
     and btrim(coalesce(p_treatment, '')) = '' and btrim(coalesce(p_investigation, '')) = '' then
    raise exception 'NOTE_REQUIRED';
  end if;
  v_patient := resolve_patient(p_visit_id, p_name, p_phone);

  select id into v_rx from prescriptions
    where patient_id = v_patient and created_at >= now() - interval '14 days'
    order by created_at desc limit 1;
  if v_rx is null then raise exception 'NO_PRESCRIPTION'; end if;

  v_date := to_char(timezone('Asia/Kolkata', now()), 'DD Mon');
  v_entry := jsonb_strip_nulls(jsonb_build_object(
    'date',          v_date,
    'visit_id',      p_visit_id,
    'complaint',     nullif(btrim(coalesce(p_complaint, '')), ''),
    'examination',   nullif(btrim(coalesce(p_examination, '')), ''),
    'treatment',     nullif(btrim(coalesce(p_treatment, '')), ''),
    'investigation', nullif(btrim(coalesce(p_investigation, '')), ''),
    'doctor',        nullif(p_doctor, '')
  ));
  update prescriptions
     set followups = coalesce(followups, '[]'::jsonb) || jsonb_build_array(v_entry)
   where id = v_rx;
  update visits set status = 'done', attended_at = coalesce(attended_at, now()) where id = p_visit_id;
  return v_rx;
end;
$$;
revoke execute on function add_followup(uuid, text, text, text, text, text, text, text) from public, anon;
grant  execute on function add_followup(uuid, text, text, text, text, text, text, text) to authenticated;
