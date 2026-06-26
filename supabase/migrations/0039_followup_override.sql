-- ============================================================================
-- Phase 34 — follow-up rule fixes.
--  (1) A no-show / not-shown appointment must NOT count toward follow-up. Only
--      visits the patient was actually SEEN for (status 'done') count now.
--  (2) The doctor can manually mark a visit New or Follow-up, overriding the
--      automatic rule. visits.followup_override (null = auto, true = follow-up,
--      false = new). Every is_followup computation now honours the override.
-- ============================================================================

-- (1) count only visits actually attended ------------------------------------
create or replace function counting_prior_visits(p_patient uuid, p_before timestamptz, p_since timestamptz)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int
    from visits v2
   where v2.patient_id = p_patient
     and v2.created_at < p_before
     and (p_since is null or v2.created_at >= p_since)
     and v2.status = 'done';
$$;
grant execute on function counting_prior_visits(uuid, timestamptz, timestamptz) to authenticated;

-- (2) per-visit manual override ----------------------------------------------
alter table visits add column if not exists followup_override boolean;

create or replace function set_followup_override(p_visit_id uuid, p_value boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  update visits set followup_override = p_value where id = p_visit_id;
  if not found then raise exception 'VISIT_NOT_FOUND'; end if;
  return p_value;
end;
$$;
revoke execute on function set_followup_override(uuid, boolean) from public, anon;
grant  execute on function set_followup_override(uuid, boolean) to authenticated;

-- session_queue: is_followup honours the override ----------------------------
create or replace function session_queue()
returns table (
  id uuid, token_number int, source text, status text,
  patient_id uuid, name text, phone text,
  age_years int, age_months int, age_days int, gender text, residence text,
  weight text, temperature text, height text, last_dewormed_on date, is_followup boolean
)
language sql security definer set search_path = public stable as $$
  select v.id, v.token_number, v.source, v.status,
         p.id, p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence,
         v.weight, v.temperature, v.height, p.last_dewormed_on,
         coalesce(v.followup_override,
                  counting_prior_visits(v.patient_id, v.created_at, v.created_at - interval '14 days') = 1) as is_followup
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

-- recent_prescriptions: tag honours the encounter visit's override -----------
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
    select v.id as visit_id, v.token_number, v.created_at, v.followup_override
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
         coalesce(cov.followup_override,
                  counting_prior_visits(pr.patient_id, rxa.enc_at, rxa.enc_at - interval '14 days') = 1) as is_followup,
         vown.rx_released_at, p.id, coalesce(p.balance, 0)
    from rxa
    join prescriptions pr on pr.id = rxa.rx_id
    join patients p on p.id = pr.patient_id
    left join visits vown on vown.id = pr.visit_id
    left join csv cov on cov.token_number = rxa.token
   order by rxa.token asc
   limit 300;
$$;
revoke execute on function recent_prescriptions() from public, anon;
grant  execute on function recent_prescriptions() to authenticated;

-- doctor_stats: New/Follow-up counts honour the override ---------------------
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
    count(*) filter (where not coalesce(v.followup_override, counting_prior_visits(v.patient_id, v.created_at, null) > 0)),
    count(*) filter (where     coalesce(v.followup_override, counting_prior_visits(v.patient_id, v.created_at, null) > 0))
    into v_new, v_followup
    from visits v
    where v.session_date = v_sd and v.status = 'done';

  return jsonb_build_object(
    'session_date', v_sd, 'session', v_se,
    'issued', coalesce(v_issued, 0), 'waiting', coalesce(v_waiting, 0),
    'attended_session', coalesce(v_att_session, 0), 'attended_today', coalesce(v_att_today, 0),
    'new_today', coalesce(v_new, 0), 'followup_today', coalesce(v_followup, 0)
  );
end;
$$;
revoke execute on function doctor_stats() from public, anon;
grant  execute on function doctor_stats() to authenticated;

notify pgrst, 'reload schema';
