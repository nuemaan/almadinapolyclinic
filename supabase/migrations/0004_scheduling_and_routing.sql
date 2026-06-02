-- ============================================================================
-- Phase 6 migration — pharmacist-set daily schedule + smart session routing
-- (+ optional GPS travel estimate). Idempotent.
--
-- Model:
--   • weekly_hours (settings)  — default clinic session times per weekday.
--   • day_schedule (table)     — per-date overrides set by the pharmacist
--     (a NULL open/close = that session is closed that day).
--   • book_appointment()       — picks the earliest session a patient can
--     actually reach: today AM -> today PM -> next open day, within a horizon.
--     Reachability = now + travel + buffer <= session close. Travel comes from
--     the patient's GPS (haversine) or a default if not shared. Walk-ins = 0.
-- ============================================================================

-- ---- settings -------------------------------------------------------------
insert into settings (key, value) values
  ('weekly_hours', $json$
    {
      "mon_sat": { "am": {"open":"09:00","close":"10:00"}, "pm": {"open":"17:30","close":"20:30"} },
      "sun":     { "am": {"open":"10:00","close":"13:30"}, "pm": {"open":"18:30","close":"20:00"} }
    }
  $json$::jsonb),
  ('clinic_location',      '{"lat":34.218357,"lng":74.779436}'::jsonb),
  ('booking_buffer_min',   '5'::jsonb),    -- must arrive >= this many min before close
  ('avg_speed_kmh',        '25'::jsonb),   -- assumed travel speed
  ('road_factor',          '1.4'::jsonb),  -- straight-line -> road distance fudge
  ('default_travel_min',   '10'::jsonb),   -- used when no GPS shared
  ('booking_horizon_days', '14'::jsonb)    -- how far ahead routing will look
on conflict (key) do nothing;

-- ---- per-day schedule overrides ------------------------------------------
create table if not exists day_schedule (
  date       date primary key,
  am_open    time, am_close time,    -- NULL/NULL = morning closed
  pm_open    time, pm_close time,    -- NULL/NULL = evening closed
  note       text,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
alter table day_schedule enable row level security;
drop policy if exists day_sched_read  on day_schedule;
drop policy if exists day_sched_write on day_schedule;
create policy day_sched_read  on day_schedule for select using (true);
create policy day_sched_write on day_schedule for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
grant select on day_schedule to anon, authenticated;

-- ---- helpers --------------------------------------------------------------
create or replace function haversine_km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

-- Effective session times for a date: override if present, else weekly default.
create or replace function effective_schedule(d date)
returns table (am_open time, am_close time, pm_open time, pm_close time)
language plpgsql stable set search_path = public as $$
declare r day_schedule; w jsonb; daykey text;
begin
  select * into r from day_schedule where date = d;
  if found then
    am_open := r.am_open; am_close := r.am_close; pm_open := r.pm_open; pm_close := r.pm_close;
    return next; return;
  end if;
  select value into w from settings where key = 'weekly_hours';
  daykey := case when extract(dow from d) = 0 then 'sun' else 'mon_sat' end;
  am_open  := (w->daykey->'am'->>'open')::time;  am_close := (w->daykey->'am'->>'close')::time;
  pm_open  := (w->daykey->'pm'->>'open')::time;  pm_close := (w->daykey->'pm'->>'close')::time;
  return next;
end;
$$;
grant execute on function effective_schedule(date) to anon, authenticated;
grant execute on function haversine_km(double precision,double precision,double precision,double precision) to anon, authenticated;

-- ---- the router -----------------------------------------------------------
create or replace function book_appointment(
  p_name     text,
  p_phone    text,
  p_source   text default 'home',
  p_qr_token text default null,
  p_lat      double precision default null,
  p_lng      double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_now      timestamptz := now();
  v_local    timestamp   := timezone('Asia/Kolkata', v_now);
  v_today    date        := v_local::date;
  v_buffer   int; v_speed numeric; v_road numeric; v_deftravel int; v_horizon int;
  v_clat double precision; v_clng double precision;
  v_travel   int; v_lead int;
  v_es       record; v_d date; v_close_dt timestamp;
  v_tdate    date := null; v_tsess text := null;
  v_name_key text; v_patient_id uuid; v_token int; v_visit visits;
begin
  p_name  := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  p_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if p_source not in ('home','walkin') then p_source := 'home'; end if;
  if p_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if length(p_phone) <> 10 then raise exception 'PHONE_INVALID'; end if;
  if p_source = 'walkin' and coalesce(auth.role(),'anon') <> 'authenticated' and not qr_token_valid(p_qr_token) then
    raise exception 'INVALID_SCAN';
  end if;

  select (value::text)::int     into v_buffer    from settings where key = 'booking_buffer_min';
  select (value::text)::numeric into v_speed     from settings where key = 'avg_speed_kmh';
  select (value::text)::numeric into v_road      from settings where key = 'road_factor';
  select (value::text)::int     into v_deftravel from settings where key = 'default_travel_min';
  select (value::text)::int     into v_horizon   from settings where key = 'booking_horizon_days';
  select (value->>'lat')::double precision, (value->>'lng')::double precision into v_clat, v_clng from settings where key = 'clinic_location';
  v_buffer := coalesce(v_buffer,5); v_speed := coalesce(v_speed,25); v_road := coalesce(v_road,1.4);
  v_deftravel := coalesce(v_deftravel,10); v_horizon := coalesce(v_horizon,14);

  if p_source = 'walkin' then
    v_travel := 0;                                   -- already at the clinic
  elsif p_lat is not null and p_lng is not null and v_clat is not null then
    v_travel := ceil(haversine_km(p_lat, p_lng, v_clat, v_clng) * v_road / nullif(v_speed,0) * 60)::int;
  else
    v_travel := v_deftravel;                          -- no location shared
  end if;
  v_lead := v_travel + v_buffer;

  for i in 0..v_horizon loop
    v_d := v_today + i;
    select * into v_es from effective_schedule(v_d);
    if v_es.am_open is not null and v_es.am_close is not null then
      v_close_dt := v_d + v_es.am_close;
      if (v_local + (v_lead || ' minutes')::interval) <= v_close_dt then v_tdate := v_d; v_tsess := 'am'; exit; end if;
    end if;
    if v_es.pm_open is not null and v_es.pm_close is not null then
      v_close_dt := v_d + v_es.pm_close;
      if (v_local + (v_lead || ' minutes')::interval) <= v_close_dt then v_tdate := v_d; v_tsess := 'pm'; exit; end if;
    end if;
  end loop;

  if v_tdate is null then raise exception 'NO_SLOT'; end if;

  v_name_key := lower(p_name);
  insert into patients (phone, name, name_key) values (p_phone, p_name, v_name_key)
    on conflict (phone, name_key) do update set name = excluded.name
    returning id into v_patient_id;

  perform pg_advisory_xact_lock(hashtext(v_tdate::text || v_tsess));
  select coalesce(max(token_number),0)+1 into v_token from visits where session_date = v_tdate and session = v_tsess;
  insert into visits (patient_id, session_date, session, token_number, source, status)
    values (v_patient_id, v_tdate, v_tsess, v_token, p_source, 'waiting')
    returning * into v_visit;

  return jsonb_build_object(
    'token_number', v_visit.token_number,
    'session_date', v_visit.session_date,
    'session',      v_visit.session,
    'source',       v_visit.source,
    'travel_min',   v_travel,
    'is_today',     (v_tdate = v_today),
    'is_current',   (v_tdate = v_today and v_tsess = (case when extract(hour from v_local) < 15 then 'am' else 'pm' end))
  );
end;
$$;
grant execute on function book_appointment(text, text, text, text, double precision, double precision) to anon, authenticated;

-- ---- pharmacist role ------------------------------------------------------
alter table staff drop constraint if exists staff_role_check;
alter table staff add constraint staff_role_check check (role in ('doctor','reception','lab','pharmacist'));
