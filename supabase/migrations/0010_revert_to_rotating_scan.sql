-- ============================================================================
-- Phase 7.5 — revert to rotating scan tokens only (no permanent token).
-- The clinic runs the display on a screen; its QR auto-refreshes, so scans
-- always work there, but a copied link expires within ~10-20 minutes.
-- Removes the stable scan token so a copied URL can no longer be reused.
-- Idempotent.
-- ============================================================================

delete from app_secrets where key = 'scan_token';

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
  -- Current or previous 10-minute slot (≈10-20 min grace for slow scans).
  v_slot := floor(extract(epoch from now()) * 1000 / 600000)::bigint;
  v_a := encode(substring(digest(v_secret || ':' || v_slot::text,       'sha256') from 1 for 6), 'hex');
  v_b := encode(substring(digest(v_secret || ':' || (v_slot - 1)::text, 'sha256') from 1 for 6), 'hex');
  return p_token = v_a or p_token = v_b;
end;
$$;
grant execute on function qr_token_valid(text) to anon, authenticated;
