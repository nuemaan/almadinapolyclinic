-- ============================================================================
-- Phase 27 — Reception desk.
-- Reception records the patient's identity + intake weight before the doctor
-- sees them. Weight is captured per-VISIT (a child's weight changes over time),
-- so it lives on visits and flows straight into the doctor's consult.
--   * visits.weight        — intake weight (kg), set by reception
--   * session_queue()      — now also returns the visit weight
--   * reception_update()   — staff-only; corrects name/phone (via resolve_patient),
--                            age and weight. Edits land on the same patient/visit
--                            record the doctor sees, so the queue auto-corrects.
-- ============================================================================

alter table visits add column if not exists weight text;

-- ---- session_queue now carries the intake weight ---------------------------
drop function if exists session_queue();
create or replace function session_queue()
returns table (
  id uuid, token_number int, source text, status text,
  patient_id uuid, name text, phone text,
  age_years int, age_months int, age_days int, gender text, residence text,
  weight text, is_followup boolean
)
language sql security definer set search_path = public stable as $$
  select v.id, v.token_number, v.source, v.status,
         p.id, p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence,
         v.weight,
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

-- ---- reception_update: correct identity / age / weight ---------------------
create or replace function reception_update(
  p_visit_id   uuid,
  p_name       text default null,
  p_phone      text default null,
  p_age_years  int  default null,
  p_age_months int  default null,
  p_age_days   int  default null,
  p_weight     text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  -- name/phone corrections (merges onto an existing record if they now match one)
  v_patient := resolve_patient(p_visit_id, p_name, p_phone);

  update patients
     set age_years  = coalesce(p_age_years,  age_years),
         age_months = coalesce(p_age_months, age_months),
         age_days   = coalesce(p_age_days,   age_days)
   where id = v_patient;

  update visits set weight = nullif(btrim(coalesce(p_weight, '')), '') where id = p_visit_id;
  return v_patient;
end;
$$;
revoke execute on function reception_update(uuid, text, text, int, int, int, text) from public, anon;
grant  execute on function reception_update(uuid, text, text, int, int, int, text) to authenticated;

notify pgrst, 'reload schema';
