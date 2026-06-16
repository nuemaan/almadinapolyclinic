-- ============================================================================
-- Phase 20 — pharmacist "Saved prescriptions" resets every new session.
--   Was: prescriptions from the last 3 days.
--   Now: only prescriptions whose visit is in the CURRENT session (today am
--        before 3 PM IST / today pm after), so the list clears when a new
--        session begins.
-- ============================================================================

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
         counting_prior_visits(
           pr.patient_id,
           coalesce(v.created_at, pr.created_at),
           coalesce(v.created_at, pr.created_at) - interval '14 days'
         ) = 1 as is_followup
    from prescriptions pr
    join patients p on p.id = pr.patient_id
    join visits   v on v.id = pr.visit_id
    cross join app_current_session() cs
   where v.session_date = cs.session_date
     and v.session      = cs.session
   order by v.token_number asc
   limit 300;
$$;
grant execute on function recent_prescriptions() to authenticated;
revoke execute on function recent_prescriptions() from public, anon;
