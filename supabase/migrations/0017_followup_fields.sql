-- ============================================================================
-- Phase 14 — follow-up entries carry Complaint / Examination / Treatment /
-- Investigation (plain text), printed at the bottom of the same prescription.
-- ============================================================================

drop function if exists add_followup(uuid, text, text);

create or replace function add_followup(
  p_visit_id      uuid,
  p_complaint     text default null,
  p_examination   text default null,
  p_treatment     text default null,
  p_investigation text default null,
  p_doctor        text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid; v_date text; v_entry jsonb;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  if btrim(coalesce(p_complaint, '')) = '' and btrim(coalesce(p_examination, '')) = ''
     and btrim(coalesce(p_treatment, '')) = '' and btrim(coalesce(p_investigation, '')) = '' then
    raise exception 'NOTE_REQUIRED';
  end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;
  select id into v_rx from prescriptions
    where patient_id = v_patient and created_at >= now() - interval '14 days'
    order by created_at desc limit 1;
  if v_rx is null then raise exception 'NO_PRESCRIPTION'; end if;
  v_date := to_char(timezone('Asia/Kolkata', now()), 'DD Mon');
  v_entry := jsonb_strip_nulls(jsonb_build_object(
    'date',          v_date,
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
grant execute on function add_followup(uuid, text, text, text, text, text) to authenticated;
