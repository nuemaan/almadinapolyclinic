-- ============================================================================
-- Phase 32 — pharmacist can send the saved prescription to the patient.
-- The patient's appointment screen (which they already hold) swaps to show the
-- prescription + a download button. Privacy: token numbers are guessable, so the
-- prescription is gated by BOTH a per-visit secret claim_code (delivered only in
-- the booking response, stored on the patient's device) AND a staff release flag.
--   * visits.claim_code      — random secret minted per visit (column default)
--   * visits.rx_released_at   — set when the pharmacist sends it
--   * book_appointment()      — now returns claim_code to the booking device
--   * recent_prescriptions()  — now returns rx_released_at (so the button shows state)
--   * release_prescription()  — staff-only; toggles the release flag
--   * claim_prescription()    — anon; returns the Rx ONLY with the secret + released
-- ============================================================================

alter table visits add column if not exists claim_code text default replace(gen_random_uuid()::text, '-', '');
alter table visits add column if not exists rx_released_at timestamptz;
update visits set claim_code = replace(gen_random_uuid()::text, '-', '') where claim_code is null;

create or replace function book_appointment(
  p_name       text,
  p_phone      text,
  p_source     text default 'home',
  p_qr_token   text default null,
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_age_years  int default null,
  p_age_months int default null,
  p_age_days   int default null,
  p_residence  text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_now    timestamptz := now();
  v_local  timestamp   := timezone('Asia/Kolkata', v_now);
  v_today  date        := v_local::date;
  v_lt     time        := v_local::time;
  v_cur_sess text      := case when extract(hour from v_local) < 15 then 'am' else 'pm' end;
  v_buffer int; v_speed numeric; v_road numeric; v_deftravel int; v_horizon int;
  v_clat double precision; v_clng double precision;
  v_travel int := 0; v_lead int;
  v_es record; v_t record; v_d date; v_cut time;
  v_tdate date := null; v_tsess text := null;
  v_name_key text; v_patient_id uuid; v_token int; v_visit visits;
  v_headline text; v_message text; v_reason text; v_daylabel text;
  v_is_staff boolean := coalesce(auth.role(), 'anon') = 'authenticated';
  v_cap int; v_phone_count int;
begin
  p_name  := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if p_source not in ('home','walkin') then p_source := 'home'; end if;
  if p_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if length(p_phone) <> 10 then raise exception 'PHONE_INVALID'; end if;
  if p_source = 'walkin' and not v_is_staff and not qr_token_valid(p_qr_token) then
    raise exception 'INVALID_SCAN';
  end if;

  -- Abuse guard: blocked numbers can't book (staff at the desk exempt).
  if not v_is_staff and exists (select 1 from blocked_phones b where b.phone = p_phone) then
    raise exception 'PHONE_BLOCKED';
  end if;

  if p_source = 'walkin' then
    select s.session_date, s.session into v_tdate, v_tsess from app_current_session(v_now) s;
    v_headline := 'You are in today''s queue 🎟️';
    v_message  := 'Please show this number at the reception desk.';
  else
    select (value::text)::int into v_buffer from settings where key = 'booking_buffer_min';
    select (value::text)::numeric into v_speed from settings where key = 'avg_speed_kmh';
    select (value::text)::numeric into v_road from settings where key = 'road_factor';
    select (value::text)::int into v_deftravel from settings where key = 'default_travel_min';
    select (value::text)::int into v_horizon from settings where key = 'booking_horizon_days';
    select (value->>'lat')::double precision, (value->>'lng')::double precision into v_clat, v_clng from settings where key = 'clinic_location';
    v_buffer := coalesce(v_buffer,5); v_speed := coalesce(v_speed,25); v_road := coalesce(v_road,1.4);
    v_deftravel := coalesce(v_deftravel,10); v_horizon := coalesce(v_horizon,14);

    if p_lat is not null and p_lng is not null and v_clat is not null then
      v_travel := ceil(haversine_km(p_lat, p_lng, v_clat, v_clng) * v_road / nullif(v_speed,0) * 60)::int;
    else v_travel := v_deftravel; end if;
    v_lead := v_travel + v_buffer;

    for i in 0..v_horizon loop
      v_d := v_today + i;
      select * into v_es from effective_schedule(v_d);
      if v_es.am_open is not null and v_es.am_close is not null then
        v_cut := coalesce(v_es.am_flex_close, v_es.am_close);
        if (v_local + (v_lead || ' minutes')::interval) <= (v_d + v_cut) then v_tdate := v_d; v_tsess := 'am'; exit; end if;
      end if;
      if v_es.pm_open is not null and v_es.pm_close is not null then
        v_cut := coalesce(v_es.pm_flex_close, v_es.pm_close);
        if (v_local + (v_lead || ' minutes')::interval) <= (v_d + v_cut) then v_tdate := v_d; v_tsess := 'pm'; exit; end if;
      end if;
    end loop;

    if v_tdate is null then raise exception 'NO_SLOT'; end if;

    select * into v_t from effective_schedule(v_today);
    if v_tdate = v_today and v_tsess = 'am' then
      v_headline := 'You are booked for this morning ☀️';
      v_message  := 'You are in this morning''s queue. Please reach the clinic before the session closes.';
    elsif v_tdate = v_today and v_tsess = 'pm' then
      v_headline := 'You are booked for this evening 🌇';
      if v_cur_sess = 'pm' then
        v_message := 'You are in this evening''s queue. Please reach the clinic before the session closes.';
      else
        if v_t.am_open is null then v_reason := 'The morning session is closed today';
        elsif v_lt > v_t.am_close then v_reason := 'The morning session is already over for today';
        else v_reason := 'The morning session cannot be reached in time from your location';
        end if;
        v_message := v_reason || ', so we have reserved your spot for this evening.';
      end if;
    else
      if (v_t.am_open is null and v_t.pm_open is null) then v_reason := 'The clinic is closed for the rest of today';
      elsif (v_t.pm_close is null or v_lt > coalesce(v_t.pm_flex_close, v_t.pm_close)) then v_reason := 'Today''s sessions are over';
      else v_reason := 'Today''s remaining sessions cannot be reached in time';
      end if;
      v_daylabel := case when v_tdate = v_today + 1 then 'tomorrow' else to_char(v_tdate, 'Dy, DD Mon') end;
      v_headline := 'You are booked for ' || v_daylabel || ' ' || (case when v_tsess='am' then 'morning' else 'evening' end) || ' 🗓️';
      v_message  := v_reason || ', so we have booked the next available slot for you — ' || v_daylabel || ' ' || (case when v_tsess='am' then 'morning' else 'evening' end) || '.';
    end if;
  end if;

  v_name_key := lower(p_name);
  insert into patients (phone, name, name_key, age_years, age_months, age_days, residence)
    values (p_phone, p_name, v_name_key, p_age_years, p_age_months, p_age_days, nullif(btrim(coalesce(p_residence,'')), ''))
    on conflict (phone, name_key) do update
      set name       = excluded.name,
          age_years  = coalesce(excluded.age_years,  patients.age_years),
          age_months = coalesce(excluded.age_months, patients.age_months),
          age_days   = coalesce(excluded.age_days,   patients.age_days),
          residence  = coalesce(excluded.residence,  patients.residence)
    returning id into v_patient_id;

  perform pg_advisory_xact_lock(hashtext(v_tdate::text || v_tsess));

  -- Abuse guard: cap ONLINE bookings per phone per session (walk-ins & staff exempt).
  if not v_is_staff and p_source = 'home' then
    select coalesce((value::text)::int, 4) into v_cap from settings where key = 'max_bookings_per_phone_session';
    v_cap := coalesce(v_cap, 4);
    select count(*) into v_phone_count
      from visits vv join patients pp on pp.id = vv.patient_id
     where pp.phone = p_phone and vv.session_date = v_tdate and vv.session = v_tsess;
    if v_phone_count >= v_cap then raise exception 'TOO_MANY'; end if;
  end if;

  select coalesce(max(token_number),0)+1 into v_token from visits where session_date = v_tdate and session = v_tsess;
  insert into visits (patient_id, session_date, session, token_number, source, status)
    values (v_patient_id, v_tdate, v_tsess, v_token, p_source, 'waiting')
    returning * into v_visit;

  return jsonb_build_object(
    'claim_code', v_visit.claim_code,
    'token_number', v_visit.token_number, 'session_date', v_visit.session_date,
    'session', v_visit.session, 'source', v_visit.source, 'travel_min', v_travel,
    'is_today', (v_tdate = v_today),
    'is_current', (v_tdate = v_today and v_tsess = v_cur_sess),
    'headline', v_headline, 'message', v_message
  );
end;
$$;

grant execute on function book_appointment(text, text, text, text, double precision, double precision, int, int, int, text) to anon, authenticated;

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
  select pr.id, pr.created_at, pr.doctor_name, pr.notes, pr.medicines,
         pr.complaint, pr.examination, pr.diagnosis, pr.lab_advice, pr.temperature,
         pr.weight, coalesce(pr.followups, '[]'::jsonb),
         p.name, p.phone, p.age_years, p.age_months, p.age_days,
         p.gender, p.residence, v.token_number,
         counting_prior_visits(
           pr.patient_id,
           coalesce(v.created_at, pr.created_at),
           coalesce(v.created_at, pr.created_at) - interval '14 days'
         ) = 1 as is_followup, v.rx_released_at
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

-- ---- staff: send / unsend the prescription to the patient -------------------
create or replace function release_prescription(p_rx_id uuid, p_on boolean default true)
returns jsonb
language plpgsql security definer set search_path = public as $FN$
declare v_vid uuid; v_code text; v_ts timestamptz;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select visit_id into v_vid from prescriptions where id = p_rx_id;
  if v_vid is null then raise exception 'RX_NOT_FOUND'; end if;
  update visits
     set rx_released_at = case when p_on then coalesce(rx_released_at, now()) else null end,
         claim_code = coalesce(claim_code, replace(gen_random_uuid()::text, '-', ''))
   where id = v_vid
   returning claim_code, rx_released_at into v_code, v_ts;
  return jsonb_build_object('claim_code', v_code, 'released_at', v_ts);
end;
$FN$;
revoke execute on function release_prescription(uuid, boolean) from public, anon;
grant  execute on function release_prescription(uuid, boolean) to authenticated;

-- ---- patient: fetch their own released prescription by the secret code -------
create or replace function claim_prescription(p_claim_code text)
returns jsonb
language sql security definer set search_path = public stable as $FN$
  select case when v.rx_released_at is null or pr.id is null then null else
    jsonb_build_object(
      'released_at', v.rx_released_at, 'token_number', v.token_number,
      'session_date', v.session_date, 'session', v.session,
      'created_at', pr.created_at, 'doctor_name', pr.doctor_name,
      'name', p.name, 'phone', p.phone,
      'age_years', p.age_years, 'age_months', p.age_months, 'age_days', p.age_days,
      'gender', p.gender, 'residence', p.residence,
      'weight', pr.weight, 'height', v.height, 'temperature', pr.temperature,
      'complaint', pr.complaint, 'examination', pr.examination,
      'diagnosis', pr.diagnosis, 'lab_advice', pr.lab_advice,
      'medicines', pr.medicines, 'followups', coalesce(pr.followups, '[]'::jsonb),
      'notes', pr.notes
    ) end
  from visits v
  join patients p on p.id = v.patient_id
  left join lateral (
    select * from prescriptions pr2 where pr2.visit_id = v.id order by pr2.created_at desc limit 1
  ) pr on true
  where p_claim_code is not null and length(p_claim_code) >= 16 and v.claim_code = p_claim_code
  limit 1;
$FN$;
revoke execute on function claim_prescription(text) from public;
grant  execute on function claim_prescription(text) to anon, authenticated;

notify pgrst, 'reload schema';
