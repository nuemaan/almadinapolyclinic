-- ============================================================================
-- Phase 18 — fix the pharmacist New/Follow-up tag.
--
-- Bug: recent_prescriptions passed the prescription's created_at (the SAVE time,
-- which is after the visit was booked) as the "before" cutoff to
-- counting_prior_visits. That made the patient's OWN current visit (booked
-- earlier the same day, now status='done') count as a prior visit, so every
-- first-timer was tagged "Follow-up" and the whole tag was off by one.
--
-- Fix: count prior visits strictly before THIS visit's own booking time
-- (v.created_at), exactly like doctor_stats does. First visit -> 0 (New),
-- 2nd within 14 days -> 1 (Follow-up), 3rd+ -> New again.
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
    left join visits v on v.id = pr.visit_id
   where pr.created_at >= now() - interval '3 days'
   order by pr.created_at desc
   limit 300;
$$;
grant execute on function recent_prescriptions() to authenticated;
revoke execute on function recent_prescriptions() from public, anon;
