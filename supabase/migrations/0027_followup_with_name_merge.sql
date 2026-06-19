-- ============================================================================
-- Phase 24 — follow-up works for returning patients who booked under a different
-- name spelling. add_followup gains p_name: if the corrected name matches an
-- existing record on the same phone, it merges this visit onto that record first,
-- then appends the follow-up to that record's latest prescription.
-- ============================================================================

drop function if exists add_followup(uuid, text, text, text, text, text);

create or replace function add_followup(
  p_visit_id      uuid,
  p_complaint     text default null,
  p_examination   text default null,
  p_treatment     text default null,
  p_investigation text default null,
  p_doctor        text default null,
  p_name          text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid; v_date text; v_entry jsonb; v_phone text; v_name text; v_target uuid;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  if btrim(coalesce(p_complaint, '')) = '' and btrim(coalesce(p_examination, '')) = ''
     and btrim(coalesce(p_treatment, '')) = '' and btrim(coalesce(p_investigation, '')) = '' then
    raise exception 'NOTE_REQUIRED';
  end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;

  -- Name correction / merge so the follow-up lands on the right (existing) record.
  v_name := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if v_name <> '' then
    select phone into v_phone from patients where id = v_patient;
    select id into v_target from patients
      where phone = v_phone and name_key = lower(v_name) and id <> v_patient limit 1;
    if v_target is not null then
      update visits        set patient_id = v_target where id = p_visit_id;
      update prescriptions set patient_id = v_target where visit_id = p_visit_id;
      if not exists (select 1 from visits where patient_id = v_patient) then
        delete from patients where id = v_patient;
      end if;
      v_patient := v_target;
    else
      update patients set name = v_name, name_key = lower(v_name) where id = v_patient;
    end if;
  end if;

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
revoke execute on function add_followup(uuid, text, text, text, text, text, text) from public, anon;
grant  execute on function add_followup(uuid, text, text, text, text, text, text) to authenticated;
