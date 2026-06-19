-- ============================================================================
-- Phase 22 — doctor can correct the patient's name (misspelled / first-name only).
-- save_prescription gains p_name. It updates patients.name (and name_key, so the
-- corrected spelling unifies future history) unless another record on the same
-- phone already uses that name_key, in which case only the display name changes.
-- ============================================================================

drop function if exists save_prescription(uuid, text, jsonb, int, int, int, text, text, text, jsonb, text, text, text, text, text);

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
declare v_patient uuid; v_rx uuid; v_phone text; v_name text; v_newkey text;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;

  update patients
     set age_years  = coalesce(p_age_years,  age_years),
         age_months = coalesce(p_age_months, age_months),
         age_days   = coalesce(p_age_days,   age_days),
         gender     = coalesce(nullif(p_gender, ''), gender),
         residence  = coalesce(nullif(p_residence, ''), residence)
   where id = v_patient;

  -- Correct the patient name if the doctor supplied one.
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if v_name <> '' then
    select phone into v_phone from patients where id = v_patient;
    v_newkey := lower(v_name);
    if not exists (select 1 from patients where phone = v_phone and name_key = v_newkey and id <> v_patient) then
      update patients set name = v_name, name_key = v_newkey where id = v_patient;
    else
      update patients set name = v_name where id = v_patient;  -- key taken on this phone; keep it to avoid a clash
    end if;
  end if;

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
