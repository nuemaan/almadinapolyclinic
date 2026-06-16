-- ============================================================================
-- Phase 16 — a returned no-show patient can be put back to "now serving".
-- set_attending() now also promotes a 'noshow' visit (not just waiting).
-- ============================================================================

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
    where id = p_visit_id and status in ('waiting','attending','noshow');
end;
$$;
grant execute on function set_attending(uuid) to authenticated;
