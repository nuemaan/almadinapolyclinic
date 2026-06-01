-- ============================================================================
-- Phase 2 migration — doctor console: attendance flow + prescriptions.
-- Idempotent.
-- ============================================================================

-- Optional demographics the doctor can fill while consulting.
alter table patients add column if not exists age    int;
alter table patients add column if not exists gender text;

-- Tighten phone to exactly 10 digits (matches the patient form).
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
  p_phone := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');  -- digits only
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
grant execute on function take_token(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- set_attending() — mark a visit as "now serving"; demote any other one.
-- ---------------------------------------------------------------------------
create or replace function set_attending(p_visit_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_sd date; v_se text;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select session_date, session into v_sd, v_se from visits where id = p_visit_id;
  if v_sd is null then raise exception 'NOT_FOUND'; end if;
  update visits set status = 'waiting'
    where session_date = v_sd and session = v_se and status = 'attending' and id <> p_visit_id;
  update visits set status = 'attending'
    where id = p_visit_id and status in ('waiting','attending');
end;
$$;
grant execute on function set_attending(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- set_status() — reception/doctor: no-show, cancel, or send back to waiting.
-- ---------------------------------------------------------------------------
create or replace function set_status(p_visit_id uuid, p_status text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  if p_status not in ('waiting','attending','noshow','cancelled','done') then
    raise exception 'BAD_STATUS';
  end if;
  update visits
     set status = p_status,
         attended_at = case when p_status = 'done' then coalesce(attended_at, now()) else attended_at end
   where id = p_visit_id;
end;
$$;
grant execute on function set_status(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- save_prescription() — store the prescription, update demographics, and
-- mark the visit done (stamping attended_at, which advances everyone's ETA).
-- ---------------------------------------------------------------------------
create or replace function save_prescription(
  p_visit_id    uuid,
  p_doctor_name text,
  p_notes       text,
  p_medicines   jsonb,
  p_age         int  default null,
  p_gender      text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_patient uuid; v_rx uuid;
begin
  if auth.role() <> 'authenticated' then raise exception 'STAFF_ONLY'; end if;
  select patient_id into v_patient from visits where id = p_visit_id;
  if v_patient is null then raise exception 'VISIT_NOT_FOUND'; end if;

  update patients
     set age    = coalesce(p_age, age),
         gender = coalesce(nullif(p_gender, ''), gender)
   where id = v_patient;

  insert into prescriptions (visit_id, patient_id, doctor_name, doctor_user, notes, medicines)
    values (p_visit_id, v_patient, p_doctor_name, auth.uid(), p_notes, coalesce(p_medicines, '[]'::jsonb))
    returning id into v_rx;

  update visits set status = 'done', attended_at = coalesce(attended_at, now())
   where id = p_visit_id;

  return v_rx;
end;
$$;
grant execute on function save_prescription(uuid, text, text, jsonb, int, text) to authenticated;
