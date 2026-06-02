-- ============================================================================
-- Phase 3 migration — per-child patient identity.
-- A patient is now identified by (phone + normalized name) instead of phone
-- alone, so siblings sharing one mobile number each keep their own history and
-- their own token shows the right name. Idempotent.
-- ============================================================================

-- Normalized name used for matching ("  Amaan  Khan " -> "amaan khan").
alter table patients add column if not exists name_key text;
update patients
   set name_key = lower(regexp_replace(btrim(name), '\s+', ' ', 'g'))
 where name_key is null or name_key = '';
alter table patients alter column name_key set not null;

-- Replace the phone-only uniqueness with (phone, name_key).
alter table patients drop constraint if exists patients_phone_key;
create unique index if not exists patients_phone_namekey_uniq on patients (phone, name_key);
create index if not exists patients_phone_idx on patients (phone);

-- take_token: upsert identity on (phone, name_key).
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
  v_name_key     text;
  v_token        int;
  v_visit        visits;
begin
  p_name  := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');  -- collapse inner spaces
  p_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if p_source not in ('home','walkin') then p_source := 'home'; end if;

  if p_name = '' then raise exception 'NAME_REQUIRED'; end if;
  if length(p_phone) <> 10 then raise exception 'PHONE_INVALID'; end if;

  if p_source = 'walkin' then
    if coalesce(auth.role(), 'anon') <> 'authenticated' and not qr_token_valid(p_qr_token) then
      raise exception 'INVALID_SCAN';
    end if;
  else
    if not is_booking_open(v_now) then raise exception 'WINDOW_CLOSED'; end if;
  end if;

  select s.session_date, s.session into v_session_date, v_session
    from app_current_session(v_now) s;

  v_name_key := lower(regexp_replace(p_name, '\s+', ' ', 'g'));
  insert into patients (phone, name, name_key) values (p_phone, p_name, v_name_key)
    on conflict (phone, name_key) do update set name = excluded.name
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
grant execute on function take_token(text, text, text, text) to anon, authenticated;

-- Count of OTHER family members booked under the same phone (for the UI).
create or replace function family_size(p_phone text)
returns int language sql security definer set search_path = public stable as $$
  select count(*)::int from patients where phone = regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
$$;
grant execute on function family_size(text) to authenticated;
