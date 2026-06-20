-- ============================================================================
-- Phase 26 — doctor queue carries the New / Follow-up tag (same 14-day,
-- "exactly the 2nd visit" rule as the pharmacist). One server call, no per-row
-- client queries.
-- ============================================================================

create or replace function session_queue()
returns table (
  id uuid, token_number int, source text, status text,
  patient_id uuid, name text, phone text,
  age_years int, age_months int, age_days int, gender text, residence text,
  is_followup boolean
)
language sql security definer set search_path = public stable as $$
  select v.id, v.token_number, v.source, v.status,
         p.id, p.name, p.phone, p.age_years, p.age_months, p.age_days, p.gender, p.residence,
         counting_prior_visits(v.patient_id, v.created_at, v.created_at - interval '14 days') = 1 as is_followup
    from visits v
    join patients p on p.id = v.patient_id
    cross join app_current_session() cs
   where v.session_date = cs.session_date
     and v.session = cs.session
     and v.status in ('waiting','attending','noshow','done')
   order by v.token_number;
$$;
revoke execute on function session_queue() from public, anon;
grant  execute on function session_queue() to authenticated;
