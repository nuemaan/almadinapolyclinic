-- ============================================================================
-- Phase 19 —
--   1) doctor_stats "Follow-up today" now uses the SAME rule as the pharmacist
--      tag: a patient is follow-up only on the 2nd counting visit within 14 days
--      (1st = new, 3rd+ or >14 days later = new again). Previously it flagged
--      any all-time return as follow-up.
--   2) Booking cap now applies to ONLINE (home) bookings only — walk-in QR
--      scans at the clinic are exempt (block-list still applies to both).
-- ============================================================================

-- 1) doctor_stats: 14-day, "exactly the 2nd visit" follow-up rule -------------
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
    count(*) filter (where counting_prior_visits(v.patient_id, v.created_at, v.created_at - interval '14 days') <> 1),
    count(*) filter (where counting_prior_visits(v.patient_id, v.created_at, v.created_at - interval '14 days')  = 1)
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
revoke execute on function doctor_stats() from public, anon;
grant execute on function doctor_stats() to authenticated;

-- 2) book_appointment: cap online bookings only (walk-ins exempt) -------------
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
    'token_number', v_visit.token_number, 'session_date', v_visit.session_date,
    'session', v_visit.session, 'source', v_visit.source, 'travel_min', v_travel,
    'is_today', (v_tdate = v_today),
    'is_current', (v_tdate = v_today and v_tsess = v_cur_sess),
    'headline', v_headline, 'message', v_message
  );
end;
$$;
grant execute on function book_appointment(text, text, text, text, double precision, double precision, int, int, int, text) to anon, authenticated;
