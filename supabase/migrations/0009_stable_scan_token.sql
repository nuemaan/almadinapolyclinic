-- ============================================================================
-- Phase 7.4 — stable clinic scan token.
-- The QR now carries a fixed token so it can be printed and never expires.
-- qr_token_valid() accepts that fixed token OR the older rotating tokens
-- (backward compatible). Walk-ins still always join the current session
-- regardless of time/schedule (handled in book_appointment). Idempotent.
-- ============================================================================

insert into app_secrets (key, value) values ('scan_token', 'amq7f3k9scan')
  on conflict (key) do update set value = excluded.value;

create or replace function qr_token_valid(p_token text)
returns boolean
language plpgsql security definer set search_path = public, extensions stable as $$
declare
  v_secret text;
  v_scan   text;
  v_slot   bigint;
  v_a      text;
  v_b      text;
begin
  if p_token is null or length(p_token) < 6 then return false; end if;

  -- Stable clinic scan token (printed QR) — always valid.
  select value into v_scan from app_secrets where key = 'scan_token';
  if v_scan is not null and p_token = v_scan then return true; end if;

  -- Legacy rotating tokens (current or previous 10-min slot) — still accepted.
  select value into v_secret from app_secrets where key = 'qr_secret';
  if v_secret is null then return false; end if;
  v_slot := floor(extract(epoch from now()) * 1000 / 600000)::bigint;
  v_a := encode(substring(digest(v_secret || ':' || v_slot::text,       'sha256') from 1 for 6), 'hex');
  v_b := encode(substring(digest(v_secret || ':' || (v_slot - 1)::text, 'sha256') from 1 for 6), 'hex');
  return p_token = v_a or p_token = v_b;
end;
$$;
grant execute on function qr_token_valid(text) to anon, authenticated;
