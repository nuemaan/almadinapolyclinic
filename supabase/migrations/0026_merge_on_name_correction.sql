-- ============================================================================
-- Phase 23 — correcting a patient's name MERGES into the existing record.
--
-- A misspelled / first-name-only booking creates a separate patient (identity is
-- phone + name_key), so the real history sits under the correctly-spelled record.
-- When the doctor fixes the name to one that already exists on the same phone,
-- save_prescription now moves this visit (and its prescription) onto that
-- canonical record and drops the orphan, so previous visits show up.
-- (No match -> just rename in place, unifying future history.)
-- ============================================================================

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
  p_name        text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid; v_phone text; v_name text; v_newkey text; v_target uuid;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;

  -- Name correction / merge (resolve identity BEFORE writing the prescription).
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if v_name <> '' then
    select phone into v_phone from patients where id = v_patient;
    v_newkey := lower(v_name);
    select id into v_target from patients
      where phone = v_phone and name_key = v_newkey and id <> v_patient limit 1;
    if v_target is not null then
      -- merge this visit (and any prescription on it) onto the canonical record
      update visits        set patient_id = v_target where id = p_visit_id;
      update prescriptions set patient_id = v_target where visit_id = p_visit_id;
      if not exists (select 1 from visits where patient_id = v_patient) then
        delete from patients where id = v_patient;
      end if;
      v_patient := v_target;
    else
      update patients set name = v_name, name_key = v_newkey where id = v_patient;
    end if;
  end if;

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
revoke execute on function save_prescription(uuid, text, jsonb, int, int, int, text, text, text, jsonb, text, text, text, text, text, text) from public, anon;
grant  execute on function save_prescription(uuid, text, jsonb, int, int, int, text, text, text, jsonb, text, text, text, text, text, text) to authenticated;

-- Look up another record on the same phone by corrected name (for the live
-- history preview while the doctor types). Staff-only.
create or replace function patient_by_phone_name(p_phone text, p_name text)
returns uuid
language sql security definer set search_path = public stable as $$
  select id from patients
   where phone = regexp_replace(coalesce(p_phone, ''), '\D', '', 'g')
     and name_key = lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'))
   limit 1;
$$;
revoke execute on function patient_by_phone_name(text, text) from public, anon;
grant  execute on function patient_by_phone_name(text, text) to authenticated;
