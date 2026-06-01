-- ============================================================================
-- Al Madina Polyclinic — Supabase schema (Phase 0)
-- Run this ONCE in: Supabase Dashboard → SQL Editor → New query → paste → Run.
-- Safe to re-run: it uses IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT.
--
-- What this sets up:
--   • patients, visits (tokens), prescriptions, lab_tests, staff, settings
--   • One shared token sequence per session (am/pm), Asia/Kolkata time
--   • Home bookings allowed only inside the booking window (editable in settings)
--   • A PUBLIC queue board (token + status only — NO names/phones leak)
--   • Row-Level Security locking real patient data to logged-in staff
--   • Self-tuning ETA: clients read attended_at timestamps to learn the real
--     average consult time (seeded at 4 min for the very first patient)
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Settings (booking windows + ETA seed). Editable any time, no code change.
-- ---------------------------------------------------------------------------
create table if not exists settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into settings (key, value) values
  ('clinic_timezone', '"Asia/Kolkata"'::jsonb),
  -- First-patient seed only; ETA auto-tunes from real timings after that.
  ('avg_consult_seconds', '240'::jsonb),
  -- Booking windows by day-group + session. Times are 24h, clinic-local.
  ('booking_windows', $json$
    {
      "mon_sat": {
        "am": { "open": "08:00", "close": "09:45" },
        "pm": { "open": "16:00", "close": "20:15" }
      },
      "sun": {
        "am": { "open": "08:30", "close": "13:15" },
        "pm": { "open": "17:00", "close": "19:45" }
      }
    }
  $json$::jsonb)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 1. Core tables
-- ---------------------------------------------------------------------------
create table if not exists patients (
  id         uuid primary key default gen_random_uuid(),
  phone      text unique not null,       -- identity key for repeat-patient lookup
  name       text not null,
  created_at timestamptz not null default now()
);

create table if not exists visits (
  id           uuid primary key default gen_random_uuid(),
  patient_id   uuid not null references patients(id) on delete cascade,
  session_date date not null,
  session      text not null check (session in ('am','pm')),
  token_number int  not null,
  source       text not null default 'home'   check (source in ('home','walkin')),
  status       text not null default 'waiting' check (status in ('waiting','attending','done','noshow','cancelled')),
  created_at   timestamptz not null default now(),
  attended_at  timestamptz,
  unique (session_date, session, token_number)
);
create index if not exists visits_session_idx on visits (session_date, session, status);

create table if not exists prescriptions (
  id          uuid primary key default gen_random_uuid(),
  visit_id    uuid references visits(id) on delete set null,
  patient_id  uuid not null references patients(id) on delete cascade,
  doctor_name text,
  doctor_user uuid references auth.users(id),
  notes       text,
  medicines   jsonb not null default '[]'::jsonb,  -- [{name,dosage,frequency,duration,quantity,instructions}]
  created_at  timestamptz not null default now()
);
create index if not exists rx_patient_idx on prescriptions (patient_id, created_at desc);

create table if not exists lab_tests (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,
  patient_name text not null,
  test_name    text not null,
  files        jsonb not null default '[]'::jsonb, -- [{name,path,size,type}]
  uploaded_at  timestamptz not null default now(),
  expires_at   timestamptz not null
);

-- Staff directory (rows link a Supabase Auth user to a role).
create table if not exists staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text,
  role       text not null check (role in ('doctor','reception','lab')),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. Time / session helpers (Asia/Kolkata; am before 3 PM, pm after)
-- ---------------------------------------------------------------------------
create or replace function app_current_session(at timestamptz default now())
returns table (session_date date, session text)
language sql stable set search_path = public as $$
  select (timezone('Asia/Kolkata', at))::date,
         case when extract(hour from timezone('Asia/Kolkata', at)) < 15 then 'am' else 'pm' end;
$$;

create or replace function is_booking_open(at timestamptz default now())
returns boolean
language plpgsql stable set search_path = public as $$
declare
  v_local   timestamp := timezone('Asia/Kolkata', at);
  v_dow     int  := extract(dow from v_local);  -- 0 = Sunday
  v_session text := case when extract(hour from v_local) < 15 then 'am' else 'pm' end;
  v_daykey  text := case when v_dow = 0 then 'sun' else 'mon_sat' end;
  v_time    text := to_char(v_local, 'HH24:MI');
  v_win     jsonb;
  v_open    text;
  v_close   text;
begin
  select value into v_win from settings where key = 'booking_windows';
  if v_win is null then return true; end if;
  v_open  := v_win -> v_daykey -> v_session ->> 'open';
  v_close := v_win -> v_daykey -> v_session ->> 'close';
  if v_open is null or v_close is null then return false; end if;
  return v_time >= v_open and v_time <= v_close;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. take_token() — the ONLY way a token is issued. Atomic, server-side.
--    • Patients (anon) may issue 'home' tokens, but only inside the window.
--    • 'walkin' tokens require a logged-in staff member (reception).
--    • Date/session decided server-side, so a stale phone can't game it.
-- ---------------------------------------------------------------------------
create or replace function take_token(p_name text, p_phone text, p_source text default 'home')
returns visits
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

  if p_source = 'walkin' and coalesce(auth.role(), 'anon') <> 'authenticated' then
    raise exception 'STAFF_ONLY';
  end if;

  if p_source = 'home' and not is_booking_open(v_now) then
    raise exception 'WINDOW_CLOSED';
  end if;

  select s.session_date, s.session into v_session_date, v_session
    from app_current_session(v_now) s;

  -- Upsert patient by phone (keeps name fresh, enables repeat-patient history).
  insert into patients (phone, name) values (p_phone, p_name)
    on conflict (phone) do update set name = excluded.name
    returning id into v_patient_id;

  -- Serialize token allocation for this exact session to avoid duplicates.
  perform pg_advisory_xact_lock(hashtext(v_session_date::text || v_session));
  select coalesce(max(token_number), 0) + 1 into v_token
    from visits where session_date = v_session_date and session = v_session;

  insert into visits (patient_id, session_date, session, token_number, source, status)
    values (v_patient_id, v_session_date, v_session, v_token, p_source, 'waiting')
    returning * into v_visit;

  return v_visit;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. get_lab_by_code() — patient fetches ONLY their own report by code.
-- ---------------------------------------------------------------------------
create or replace function get_lab_by_code(p_code text)
returns lab_tests
language sql security definer set search_path = public stable as $$
  select * from lab_tests
   where code = upper(btrim(p_code)) and expires_at > now()
   limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 5. Public queue board — safe columns only (no name, no phone, no patient_id)
-- ---------------------------------------------------------------------------
create or replace view queue_public as
  select session_date, session, token_number, source, status, created_at, attended_at
    from visits;

-- ---------------------------------------------------------------------------
-- 6. Row-Level Security
-- ---------------------------------------------------------------------------
alter table patients      enable row level security;
alter table visits        enable row level security;
alter table prescriptions enable row level security;
alter table lab_tests     enable row level security;
alter table staff         enable row level security;
alter table settings      enable row level security;

drop policy if exists settings_read  on settings;
drop policy if exists settings_write on settings;
create policy settings_read  on settings for select using (true);
create policy settings_write on settings for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy if exists patients_staff on patients;
create policy patients_staff on patients for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy if exists visits_staff on visits;
create policy visits_staff on visits for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy if exists rx_staff on prescriptions;
create policy rx_staff on prescriptions for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy if exists lab_staff on lab_tests;
create policy lab_staff on lab_tests for all
  using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

drop policy if exists staff_self on staff;
create policy staff_self on staff for select using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 7. Grants — anon may read settings + public board, and call the two RPCs.
-- ---------------------------------------------------------------------------
grant select on settings     to anon, authenticated;
grant select on queue_public to anon, authenticated;
grant execute on function app_current_session(timestamptz) to anon, authenticated;
grant execute on function is_booking_open(timestamptz)     to anon, authenticated;
grant execute on function take_token(text, text, text)     to anon, authenticated;
grant execute on function get_lab_by_code(text)            to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Realtime — staff screens (logged in) get live queue pushes.
--    Patients poll queue_public (low volume; keeps RLS simple and $0).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'visits'
  ) then
    alter publication supabase_realtime add table visits;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Lab report storage bucket (private; staff upload, patients via signed URL)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
  values ('lab-reports', 'lab-reports', false)
  on conflict (id) do nothing;

drop policy if exists lab_files_staff on storage.objects;
create policy lab_files_staff on storage.objects for all
  using (bucket_id = 'lab-reports' and auth.role() = 'authenticated')
  with check (bucket_id = 'lab-reports' and auth.role() = 'authenticated');

-- ============================================================================
-- Done. Verify with:  select * from settings;
-- ============================================================================
