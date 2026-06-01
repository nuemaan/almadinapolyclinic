-- ============================================================================
-- Phase 1 migration — server-side walk-in QR validation + live queue status.
-- Idempotent: safe to re-run.
-- ============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Private secrets (QR secret + display key). RLS on + NO policies => not even
-- logged-in staff can read this table; only SECURITY DEFINER functions can.
-- ---------------------------------------------------------------------------
create table if not exists app_secrets (
  key   text primary key,
  value text not null
);
alter table app_secrets enable row level security;

insert into app_secrets (key, value) values
  ('qr_secret',   'almadina-clinic-queue-v1-2026'),
  ('display_key', 'rayis-clinic-screen-2026')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- qr_token_valid() — mirrors queue-token.js: first 6 bytes of
-- SHA-256("<secret>:<slot>") where slot = floor(epoch_ms / 600000).
-- Accepts the current slot or the previous one (10-min grace), like the JS.
-- ---------------------------------------------------------------------------
create or replace function qr_token_valid(p_token text)
returns boolean
language plpgsql security definer set search_path = public, extensions stable as $$
declare
  v_secret text;
  v_slot   bigint;
  v_a      text;
  v_b      text;
begin
  if p_token is null or length(p_token) < 6 then return false; end if;
  select value into v_secret from app_secrets where key = 'qr_secret';
  if v_secret is null then return false; end if;
  v_slot := floor(extract(epoch from now()) * 1000 / 600000)::bigint;
  v_a := encode(substring(digest(v_secret || ':' || v_slot::text,       'sha256') from 1 for 6), 'hex');
  v_b := encode(substring(digest(v_secret || ':' || (v_slot - 1)::text, 'sha256') from 1 for 6), 'hex');
  return p_token = v_a or p_token = v_b;
end;
$$;

-- ---------------------------------------------------------------------------
-- take_token() — now 4 args. Walk-ins (anon) must present a valid scan token;
-- staff may issue walk-ins without one. Home bookings still window-gated.
-- ---------------------------------------------------------------------------
drop function if exists take_token(text, text, text);

create or replace function take_token(
  p_name     text,
  p_phone    text,
  p_source   text default 'home',
  p_qr_token text default null
) returns visits
language plpgsql security definer set search_path = public as $$
declare
  v_now          timestamptz := now();
  v_session_date date;
  v_session      text;
  v_patient_id   uuid;
  v_token        int;
  v_visit        visits;
begin
  p_name  := btrim(coalesce(p_name, ''));
  p_phone := regexp_replace(coalesce(p_phone, ''), '\s+', '', 'g');
  if p_source not in ('home','walkin') then p_source := 'home'; end if;

  if p_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if length(p_phone) < 7 then raise exception 'PHONE_INVALID'; end if;

  if p_source = 'walkin' then
    if coalesce(auth.role(), 'anon') <> 'authenticated' and not qr_token_valid(p_qr_token) then
      raise exception 'INVALID_SCAN';
    end if;
  else  -- home
    if not is_booking_open(v_now) then
      raise exception 'WINDOW_CLOSED';
    end if;
  end if;

  select s.session_date, s.session into v_session_date, v_session
    from app_current_session(v_now) s;

  insert into patients (phone, name) values (p_phone, p_name)
    on conflict (phone) do update set name = excluded.name
    returning id into v_patient_id;

  perform pg_advisory_xact_lock(hashtext(v_session_date::text || v_session));
  select coalesce(max(token_number), 0) + 1 into v_token
    from visits where session_date = v_session_date and session = v_session;

  insert into visits (patient_id, session_date, session, token_number, source, status)
    values (v_patient_id, v_session_date, v_session, v_token, p_source, 'waiting')
    returning * into v_visit;

  return v_visit;
end;
$$;

grant execute on function qr_token_valid(text)             to anon, authenticated;
grant execute on function take_token(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- queue_status() — public, PII-free live snapshot for the patient's screen.
-- Pass your token to also get "patients ahead of you" + an ETA in seconds.
-- avg_seconds self-tunes from real attended_at gaps once the session is moving.
-- ---------------------------------------------------------------------------
create or replace function queue_status(p_token int default null)
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare
  v_sd date; v_se text;
  v_attended int; v_now_serving int; v_ahead int := 0;
  v_last_issued int; v_waiting int;
  v_first timestamptz; v_last timestamptz;
  v_avg numeric; v_seed int; v_your text;
begin
  select session_date, session into v_sd, v_se from app_current_session();

  select count(*) filter (where status = 'done'),
         max(token_number) filter (where status = 'attending'),
         max(token_number) filter (where status <> 'cancelled'),
         count(*) filter (where status in ('waiting','attending'))
    into v_attended, v_now_serving, v_last_issued, v_waiting
    from visits where session_date = v_sd and session = v_se;

  if v_now_serving is null then
    select max(token_number) into v_now_serving
      from visits where session_date = v_sd and session = v_se and status = 'done';
  end if;

  select min(attended_at), max(attended_at) into v_first, v_last
    from visits where session_date = v_sd and session = v_se
                  and status = 'done' and attended_at is not null;

  select coalesce((value::text)::int, 240) into v_seed from settings where key = 'avg_consult_seconds';

  if coalesce(v_attended,0) >= 2 and v_first is not null and v_last > v_first then
    v_avg := extract(epoch from (v_last - v_first)) / (v_attended - 1);
  else
    v_avg := v_seed;
  end if;

  if p_token is not null then
    select count(*) into v_ahead from visits
      where session_date = v_sd and session = v_se
        and status in ('waiting','attending') and token_number < p_token;
    select status into v_your from visits
      where session_date = v_sd and session = v_se and token_number = p_token;
  end if;

  return jsonb_build_object(
    'session_date', v_sd,
    'session',      v_se,
    'attended',     coalesce(v_attended, 0),
    'now_serving',  v_now_serving,
    'last_issued',  v_last_issued,
    'waiting',      coalesce(v_waiting, 0),
    'ahead',        v_ahead,
    'avg_seconds',  round(v_avg),
    'eta_seconds',  v_ahead * round(v_avg),
    'your_status',  v_your,
    'server_now',   now()
  );
end;
$$;
grant execute on function queue_status(int) to anon, authenticated;
