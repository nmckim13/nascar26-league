-- Store optional team identity metadata and expose only aggregate contract
-- information to public profile pages. Driver-level contract terms stay private.
alter table public.n26_teams
  add column if not exists owner_name text,
  add column if not exists honors jsonb not null default '[]'::jsonb;

alter table public.n26_teams
  drop constraint if exists n26_teams_honors_array_check;

alter table public.n26_teams
  add constraint n26_teams_honors_array_check
  check (jsonb_typeof(honors) = 'array');

create or replace view public.n26_public_team_season_summary
with (security_barrier = true)
as
select
  seasons.id as season_id,
  contracts.team_id,
  coalesce(sum(contracts.cap_charge_cents), 0)::integer as cap_charge_cents,
  max(contracts.end_season)::integer as latest_contract_expiration_season,
  count(*)::integer as active_contract_count
from public.n26_seasons seasons
join public.n26_contracts contracts
  on contracts.start_season <= seasons.season_number
 and contracts.end_season >= seasons.season_number
 and contracts.status in ('introductory', 'active')
where seasons.status in ('open', 'in_progress', 'appeal_window', 'certified', 'archived')
group by seasons.id, contracts.team_id;

grant select on public.n26_public_team_season_summary to anon, authenticated;
