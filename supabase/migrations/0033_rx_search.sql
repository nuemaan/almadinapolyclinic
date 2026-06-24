-- ============================================================================
-- Phase 30 — full previous prescriptions + prescription search.
--   * patient_prescriptions(patient_id) — every full prescription for one
--     patient (newest first), with the patient's details, for the letterhead view.
--   * search_patients(query)            — find any patient by name or phone (who
--     has at least one prescription), with a prescription count and last-visit date.
-- Both are staff-only (granted to authenticated, revoked from anon/public) — the
-- same gating as recent_prescriptions, since they expose patient PII.
-- ============================================================================

create or replace function patient_prescriptions(p_patient_id uuid)
returns table (
  id uuid, created_at timestamptz, doctor_name text, notes text, medicines jsonb,
  complaint text, examination jsonb, diagnosis text, lab_advice text, temperature text,
  weight text, followups jsonb,
  patient_name text, phone text, age_years int, age_months int, age_days int,
  gender text, residence text
)
language sql security definer set search_path = public stable as $$
  select pr.id, pr.created_at, pr.doctor_name, pr.notes, pr.medicines,
         pr.complaint, pr.examination, pr.diagnosis, pr.lab_advice, pr.temperature,
         pr.weight, coalesce(pr.followups, '[]'::jsonb),
         p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence
    from prescriptions pr
    join patients p on p.id = pr.patient_id
   where pr.patient_id = p_patient_id
   order by pr.created_at desc
   limit 100;
$$;
revoke execute on function patient_prescriptions(uuid) from public, anon;
grant  execute on function patient_prescriptions(uuid) to authenticated;

create or replace function search_patients(p_query text)
returns table (
  id uuid, name text, phone text,
  age_years int, age_months int, age_days int, gender text, residence text,
  rx_count bigint, last_rx timestamptz
)
language sql security definer set search_path = public stable as $$
  with q as (
    select btrim(coalesce(p_query, ''))                       as term,
           regexp_replace(coalesce(p_query, ''), '\D', '', 'g') as digits
  )
  select p.id, p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence,
         count(pr.id) as rx_count, max(pr.created_at) as last_rx
    from patients p
    join prescriptions pr on pr.patient_id = p.id
    cross join q
   where (length(q.term)   >= 2 and p.name ilike '%' || q.term   || '%')
      or (length(q.digits) >= 3 and p.phone like  '%' || q.digits || '%')
   group by p.id
   order by max(pr.created_at) desc
   limit 50;
$$;
revoke execute on function search_patients(text) from public, anon;
grant  execute on function search_patients(text) to authenticated;

notify pgrst, 'reload schema';
