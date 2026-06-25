-- ============================================================================
-- Phase 33 — pharmacy balance (money owed for medicines).
-- The pharmacist records an outstanding balance on the PATIENT (carries across
-- visits). It is shown only to staff (pharmacist) — never on the prescription
-- the patient sees/downloads. The pharmacist can update or clear it.
--   * patients.balance         — current outstanding amount (₹), default 0
--   * recent_prescriptions()    — now also returns patient_id + balance
--   * search_patients()         — now also returns balance
--   * set_patient_balance()     — staff-only; set/clear a patient's balance
-- ============================================================================

alter table patients add column if not exists balance numeric not null default 0;

-- ---- recent_prescriptions: + patient_id + balance (keeps followup surfacing) --
drop function if exists recent_prescriptions();
create or replace function recent_prescriptions()
returns table (
  id uuid, created_at timestamptz, doctor_name text, notes text, medicines jsonb,
  complaint text, examination jsonb, diagnosis text, lab_advice text, temperature text,
  weight text, followups jsonb,
  patient_name text, phone text, age_years int, age_months int, age_days int,
  gender text, residence text, token_number int, is_followup boolean, rx_released_at timestamptz,
  patient_id uuid, balance numeric
)
language sql security definer set search_path = public stable as $$
  with cs as (select session_date, session from app_current_session()),
  csv as (
    select v.id as visit_id, v.token_number, v.created_at
      from visits v cross join cs
     where v.session_date = cs.session_date and v.session = cs.session
  ),
  rx as (
    select pr.id as rx_id, csv.token_number as token, csv.created_at as enc_at
      from prescriptions pr join csv on csv.visit_id = pr.visit_id
    union
    select pr.id, csv.token_number, csv.created_at
      from prescriptions pr
      cross join lateral jsonb_array_elements(coalesce(pr.followups, '[]'::jsonb)) f
      join csv on csv.visit_id = nullif(f->>'visit_id', '')::uuid
  ),
  rxa as (select rx_id, max(token) as token, max(enc_at) as enc_at from rx group by rx_id)
  select pr.id, pr.created_at, pr.doctor_name, pr.notes, pr.medicines,
         pr.complaint, pr.examination, pr.diagnosis, pr.lab_advice, pr.temperature,
         pr.weight, coalesce(pr.followups, '[]'::jsonb),
         p.name, p.phone, p.age_years, p.age_months, p.age_days,
         p.gender, p.residence, rxa.token,
         counting_prior_visits(pr.patient_id, rxa.enc_at, rxa.enc_at - interval '14 days') = 1 as is_followup,
         vown.rx_released_at, p.id, coalesce(p.balance, 0)
    from rxa
    join prescriptions pr on pr.id = rxa.rx_id
    join patients p on p.id = pr.patient_id
    left join visits vown on vown.id = pr.visit_id
   order by rxa.token asc
   limit 300;
$$;
revoke execute on function recent_prescriptions() from public, anon;
grant  execute on function recent_prescriptions() to authenticated;

-- ---- search_patients: + balance --------------------------------------------
drop function if exists search_patients(text);
create or replace function search_patients(p_query text)
returns table (
  id uuid, name text, phone text,
  age_years int, age_months int, age_days int, gender text, residence text,
  rx_count bigint, last_rx timestamptz, balance numeric
)
language sql security definer set search_path = public stable as $$
  with q as (
    select btrim(coalesce(p_query, ''))                       as term,
           regexp_replace(coalesce(p_query, ''), '\D', '', 'g') as digits
  )
  select p.id, p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence,
         count(pr.id) as rx_count, max(pr.created_at) as last_rx, coalesce(p.balance, 0) as balance
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

-- ---- set / clear a patient's balance (staff-only) --------------------------
create or replace function set_patient_balance(p_patient_id uuid, p_amount numeric)
returns numeric
language plpgsql security definer set search_path = public as $$
declare v_bal numeric;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  if not exists (select 1 from patients where id = p_patient_id) then raise exception 'PATIENT_NOT_FOUND'; end if;
  v_bal := round(greatest(0, coalesce(p_amount, 0))::numeric, 2);
  update patients set balance = v_bal where id = p_patient_id;
  return v_bal;
end;
$$;
revoke execute on function set_patient_balance(uuid, numeric) from public, anon;
grant  execute on function set_patient_balance(uuid, numeric) to authenticated;

notify pgrst, 'reload schema';
