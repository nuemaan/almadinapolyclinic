-- ============================================================================
-- Phase 8 — doctor console stats.
--   issued            : tokens issued this session (the count on the QR screen)
--   waiting           : still waiting/attending this session
--   attended_session  : patients seen (done) this session
--   attended_today    : patients seen (done) across both sessions today
--   new_today / followup_today : split of today's seen patients (a patient is
--                       follow-up if they have an earlier visit, else new)
-- Staff-only. Idempotent.
-- ============================================================================

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
    count(*) filter (where not exists (select 1 from visits e where e.patient_id = v.patient_id and e.created_at < v.created_at)),
    count(*) filter (where     exists (select 1 from visits e where e.patient_id = v.patient_id and e.created_at < v.created_at))
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
grant execute on function doctor_stats() to authenticated;
