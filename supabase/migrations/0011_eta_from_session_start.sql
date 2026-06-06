-- ============================================================================
-- Phase 7.6 — ETA counts from the session start, not "now".
-- If the current session has not opened yet (e.g. it is 3:14 PM and the
-- evening session opens at 5:30 PM), a waiting patient's turn must be
-- estimated from the session opening time, not the current time.
-- queue_status now returns session_open + an absolute turn_at. Idempotent.
-- ============================================================================

create or replace function queue_status(p_token int default null)
returns jsonb
language plpgsql security definer set search_path = public stable as $$
declare
  v_sd date; v_se text;
  v_local timestamp := timezone('Asia/Kolkata', now());
  v_attended int; v_now_serving int; v_ahead int := 0;
  v_last_issued int; v_waiting int;
  v_first timestamptz; v_last timestamptz;
  v_avg numeric; v_seed int; v_your text;
  v_es record; v_open time; v_open_dt timestamp; v_base timestamp;
  v_turn timestamptz; v_session_open timestamptz;
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
    from visits where session_date = v_sd and session = v_se and status = 'done' and attended_at is not null;

  select coalesce((value::text)::int, 240) into v_seed from settings where key = 'avg_consult_seconds';
  if coalesce(v_attended,0) >= 2 and v_first is not null and v_last > v_first then
    v_avg := extract(epoch from (v_last - v_first)) / (v_attended - 1);
  else
    v_avg := v_seed;
  end if;

  if p_token is not null then
    select count(*) into v_ahead from visits
      where session_date = v_sd and session = v_se and status in ('waiting','attending') and token_number < p_token;
    select status into v_your from visits
      where session_date = v_sd and session = v_se and token_number = p_token;
  end if;

  -- Session opening time for the current session (today).
  select * into v_es from effective_schedule(v_sd);
  v_open := case when v_se = 'am' then v_es.am_open else v_es.pm_open end;
  if v_open is not null then
    v_open_dt := v_sd + v_open;
    v_session_open := timezone('Asia/Kolkata', v_open_dt);
  else
    v_open_dt := v_local;          -- no scheduled open (e.g. walk-in/closed) => from now
    v_session_open := null;
  end if;

  -- Turn estimate counts from whichever is later: now, or the session opening.
  v_base := greatest(v_local, v_open_dt);
  v_turn := timezone('Asia/Kolkata', v_base + (v_ahead * round(v_avg)) * interval '1 second');

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
    'server_now',   now(),
    'session_open', v_session_open,
    'turn_at',      v_turn
  );
end;
$$;
grant execute on function queue_status(int) to anon, authenticated;
