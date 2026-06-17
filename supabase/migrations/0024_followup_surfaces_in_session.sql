-- ============================================================================
-- Phase 21 — fix follow-ups disappearing from the pharmacist after the
-- "reset per session" change (0023).
--
-- A follow-up attaches to the patient's OLD prescription (a past session), so a
-- follow-up patient seen today never appeared in the current-session pharmacist
-- list and couldn't be printed.
--
-- Fix: (1) add_followup records the current visit_id on each follow-up entry.
--      (2) recent_prescriptions surfaces a prescription when EITHER its own visit
--          is in the current session OR it received a follow-up from a
--          current-session visit. Token shown = the current visit's token.
-- ============================================================================

-- 1) add_followup: stamp the current visit on the follow-up entry --------------
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
revoke execute on function add_followup(uuid, text, text, text, text, text) from public, anon;
grant  execute on function add_followup(uuid, text, text, text, text, text) to authenticated;

-- 2) recent_prescriptions: include follow-ups made in the current session ------
create or replace function recent_prescriptions()
returns table (
  id uuid, created_at timestamptz, doctor_name text, notes text, medicines jsonb,
  complaint text, examination jsonb, diagnosis text, lab_advice text, temperature text,
  weight text, followups jsonb,
  patient_name text, phone text, age_years int, age_months int, age_days int,
  gender text, residence text, token_number int, is_followup boolean
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
         counting_prior_visits(pr.patient_id, rxa.enc_at, rxa.enc_at - interval '14 days') = 1 as is_followup
    from rxa
    join prescriptions pr on pr.id = rxa.rx_id
    join patients p on p.id = pr.patient_id
   order by rxa.token asc
   limit 300;
$$;
revoke execute on function recent_prescriptions() from public, anon;
grant  execute on function recent_prescriptions() to authenticated;
