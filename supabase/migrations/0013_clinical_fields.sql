-- ============================================================================
-- Phase 10 — richer consultation: complaint, clinical examination,
-- provisional diagnosis, lab investigations (+ structured medicine fields).
-- Idempotent.
-- ============================================================================

alter table prescriptions add column if not exists complaint   text;
alter table prescriptions add column if not exists examination jsonb default '{}'::jsonb;
alter table prescriptions add column if not exists diagnosis   text;
alter table prescriptions add column if not exists lab_advice  text;

drop function if exists save_prescription(uuid, text, text, jsonb, int, text, text);

create or replace function save_prescription(
  p_visit_id    uuid,
  p_doctor_name text,
  p_medicines   jsonb default '[]'::jsonb,
  p_age         int  default null,
  p_gender      text default null,
  p_residence   text default null,
  p_complaint   text default null,
  p_examination jsonb default '{}'::jsonb,
  p_diagnosis   text default null,
  p_lab         text default null,
  p_notes       text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;

  update patients
     set age       = coalesce(p_age, age),
         gender    = coalesce(nullif(p_gender, ''), gender),
         residence = coalesce(nullif(p_residence, ''), residence)
   where id = v_patient;

  insert into prescriptions (visit_id, patient_id, doctor_name, doctor_user,
                             notes, medicines, complaint, examination, diagnosis, lab_advice)
    values (p_visit_id, v_patient, p_doctor_name, auth.uid(),
            p_notes, coalesce(p_medicines, '[]'::jsonb), p_complaint,
            coalesce(p_examination, '{}'::jsonb), p_diagnosis, p_lab)
    returning id into v_rx;

  update visits set status = 'done', attended_at = coalesce(attended_at, now())
   where id = p_visit_id;

  return v_rx;
end;
$$;
grant execute on function save_prescription(uuid, text, jsonb, int, text, text, text, jsonb, text, text, text) to authenticated;
