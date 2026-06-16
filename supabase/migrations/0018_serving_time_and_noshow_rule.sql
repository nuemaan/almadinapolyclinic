-- ============================================================================
-- Phase 15 —
--   1) Default serving time per patient 4 min -> 3 min.
--   2) No-show counting rule: a no-show counts as a visit ONLY if the patient
--      already had a real (seen) visit before it. A brand-new patient who books
--      and doesn't turn up does NOT get counted; an established (follow-up)
--      patient who books and doesn't turn up DOES (it uses up their 2nd visit).
-- ============================================================================

-- 1) serving-time seed (used until 2+ patients have actually been seen)
update settings set value = '180'::jsonb where key = 'avg_consult_seconds';

-- 2) shared helper: how many of a patient's prior visits "count" before a moment
--    (optionally limited to a 14-day-style window via p_since).
create or replace function counting_prior_visits(p_patient uuid, p_before timestamptz, p_since timestamptz)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
    from visits v2
   where v2.patient_id = p_patient
     and v2.created_at < p_before
     and (p_since is null or v2.created_at >= p_since)
     and (
       v2.status = 'done'
       or (v2.status = 'noshow' and exists (
             select 1 from visits v3
             where v3.patient_id = p_patient
               and v3.status = 'done'
               and v3.created_at < v2.created_at
           ))
     );
$$;
grant execute on function counting_prior_visits(uuid, timestamptz, timestamptz) to authenticated;

-- doctor_stats: new vs follow-up split now uses the counting rule.
create or replace function doctor_stats()
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare
  v_sd date; v_se text;
  v_issued int; v_waiting int; v_att_session int;
  v_att_today int; v_new int; v_followup int;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select session_date, session into v_sd, v_se from app_current_session();

  select count(*) filter (where status <> 'cancelled'),
         count(*) filter (where status in ('waiting','attending')),
         count(*) filter (where status = 'done')
    into v_issued, v_waiting, v_att_session
    from visits where session_date = v_sd and session = v_se;

  select count(*) filter (where status = 'done')
    into v_att_today
    from visits where session_date = v_sd;

  select
    count(*) filter (where counting_prior_visits(v.patient_id, v.created_at, null) = 0),
    count(*) filter (where counting_prior_visits(v.patient_id, v.created_at, null) > 0)
    into v_new, v_followup
    from visits v
    where v.session_date = v_sd and v.status = 'done';

  return jsonb_build_object(
    'session_date',     v_sd,
    'session',          v_se,
    'issued',           coalesce(v_issued, 0),
    'waiting',          coalesce(v_waiting, 0),
    'attended_session', coalesce(v_att_session, 0),
    'attended_today',   coalesce(v_att_today, 0),
    'new_today',        coalesce(v_new, 0),
    'followup_today',   coalesce(v_followup, 0)
  );
end;
$$;
grant execute on function doctor_stats() to authenticated;

-- pharmacist tag: Follow-up = exactly the 2nd counting visit within 14 days.
drop function if exists recent_prescriptions();
create or replace function recent_prescriptions()
returns table (
  id uuid, created_at timestamptz, doctor_name text, notes text, medicines jsonb,
  complaint text, examination jsonb, diagnosis text, lab_advice text, temperature text,
  weight text, followups jsonb,
  patient_name text, phone text, age_years int, age_months int, age_days int,
  gender text, residence text, token_number int, is_followup boolean
)
language sql security definer set search_path = public stable as $$
  select pr.id, pr.created_at, pr.doctor_name, pr.notes, pr.medicines,
         pr.complaint, pr.examination, pr.diagnosis, pr.lab_advice, pr.temperature,
         pr.weight, coalesce(pr.followups, '[]'::jsonb),
         p.name, p.phone, p.age_years, p.age_months, p.age_days,
         p.gender, p.residence, v.token_number,
         counting_prior_visits(pr.patient_id, pr.created_at, pr.created_at - interval '14 days') = 1 as is_followup
    from prescriptions pr
    join patients p on p.id = pr.patient_id
    left join visits v on v.id = pr.visit_id
   where pr.created_at >= now() - interval '3 days'
   order by pr.created_at desc
   limit 300;
$$;
grant execute on function recent_prescriptions() to authenticated;
