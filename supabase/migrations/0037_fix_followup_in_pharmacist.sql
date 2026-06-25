-- ============================================================================
-- Phase 32b — FIX: follow-ups stopped showing in the pharmacist tab.
-- 0036 rebuilt recent_prescriptions from the older 0023 body and accidentally
-- dropped the 0024 logic that surfaces a prescription when a follow-up was made
-- from a current-session visit. This restores that logic AND keeps the
-- rx_released_at column added in 0036.
-- ============================================================================

drop function if exists recent_prescriptions();
create or replace function recent_prescriptions()
returns table (
  id uuid, created_at timestamptz, doctor_name text, notes text, medicines jsonb,
  complaint text, examination jsonb, diagnosis text, lab_advice text, temperature text,
  weight text, followups jsonb,
  patient_name text, phone text, age_years int, age_months int, age_days int,
  gender text, residence text, token_number int, is_followup boolean, rx_released_at timestamptz
)
language sql security definer set search_path = public stable as $$
  with cs as (select session_date, session from app_current_session()),
  csv as (
    select v.id as visit_id, v.token_number, v.created_at
      from visits v cross join cs
     where v.session_date = cs.session_date and v.session = cs.session
  ),
  rx as (
    -- prescriptions written this session (own visit is current)
    select pr.id as rx_id, csv.token_number as token, csv.created_at as enc_at
      from prescriptions pr
      join csv on csv.visit_id = pr.visit_id
    union
    -- prescriptions that received a follow-up from a current-session visit
    select pr.id, csv.token_number, csv.created_at
      from prescriptions pr
      cross join lateral jsonb_array_elements(coalesce(pr.followups, '[]'::jsonb)) f
      join csv on csv.visit_id = nullif(f->>'visit_id', '')::uuid
  ),
  rxa as (
    select rx_id, max(token) as token, max(enc_at) as enc_at
      from rx group by rx_id
  )
  select pr.id, pr.created_at, pr.doctor_name, pr.notes, pr.medicines,
         pr.complaint, pr.examination, pr.diagnosis, pr.lab_advice, pr.temperature,
         pr.weight, coalesce(pr.followups, '[]'::jsonb),
         p.name, p.phone, p.age_years, p.age_months, p.age_days,
         p.gender, p.residence, rxa.token,
         counting_prior_visits(pr.patient_id, rxa.enc_at, rxa.enc_at - interval '14 days') = 1 as is_followup,
         vown.rx_released_at
    from rxa
    join prescriptions pr on pr.id = rxa.rx_id
    join patients p on p.id = pr.patient_id
    left join visits vown on vown.id = pr.visit_id
   order by rxa.token asc
   limit 300;
$$;
revoke execute on function recent_prescriptions() from public, anon;
grant  execute on function recent_prescriptions() to authenticated;

notify pgrst, 'reload schema';
