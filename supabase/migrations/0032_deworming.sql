-- ============================================================================
-- Phase 29 — Deworming recall.
-- Children 2 years and older are dewormed every 6 months. The doctor ticks
-- "Deworming done" on the consult; we stamp the date on the patient. On a later
-- visit, if the last deworming was 6 months or more ago, the doctor sees a
-- "Deworm alert".
--   * patients.last_dewormed_on  — date of the most recent deworming
--   * session_queue()             — now returns it (drives the checkbox + alert)
--   * mark_dewormed(visit_id)     — staff-only; stamps today's date on the
--                                   visit's patient (resolves merges correctly)
-- ============================================================================

alter table patients add column if not exists last_dewormed_on date;

-- ---- session_queue now also returns last_dewormed_on -----------------------
drop function if exists session_queue();
create or replace function session_queue()
returns table (
  id uuid, token_number int, source text, status text,
  patient_id uuid, name text, phone text,
  age_years int, age_months int, age_days int, gender text, residence text,
  weight text, temperature text, last_dewormed_on date, is_followup boolean
)
language sql security definer set search_path = public stable as $$
  select v.id, v.token_number, v.source, v.status,
         p.id, p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence,
         v.weight, v.temperature, p.last_dewormed_on,
         counting_prior_visits(v.patient_id, v.created_at, v.created_at - interval '14 days') = 1 as is_followup
    from visits v
    join patients p on p.id = v.patient_id
    cross join app_current_session() cs
   where v.session_date = cs.session_date
     and v.session = cs.session
     and v.status in ('waiting','attending','noshow','done')
   order by v.token_number;
$$;
revoke execute on function session_queue() from public, anon;
grant  execute on function session_queue() to authenticated;

-- ---- mark_dewormed: stamp today's date on the visit's patient --------------
create or replace function mark_dewormed(p_visit_id uuid)
returns date
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_date date;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;
  v_date := (timezone('Asia/Kolkata', now()))::date;
  update patients set last_dewormed_on = v_date where id = v_patient;
  return v_date;
end;
$$;
revoke execute on function mark_dewormed(uuid) from public, anon;
grant  execute on function mark_dewormed(uuid) to authenticated;

notify pgrst, 'reload schema';
