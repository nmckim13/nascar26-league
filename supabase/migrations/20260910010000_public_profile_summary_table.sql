-- Keep public cap information in a narrow, RLS-protected aggregate table.
-- Individual contracts remain private and are never exposed through the API.
drop view if exists public.n26_public_team_season_summary;

create table if not exists public.n26_public_team_season_summary (
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  team_id uuid not null references public.n26_teams(id) on delete cascade,
  cap_charge_cents integer not null default 0 check (cap_charge_cents >= 0),
  latest_contract_expiration_season integer,
  active_contract_count integer not null default 0 check (active_contract_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (season_id, team_id)
);

alter table public.n26_public_team_season_summary enable row level security;

drop policy if exists "public can read team season summaries" on public.n26_public_team_season_summary;
create policy "public can read team season summaries"
  on public.n26_public_team_season_summary
  for select to anon, authenticated
  using (
    exists (
      select 1
      from public.n26_seasons seasons
      where seasons.id = n26_public_team_season_summary.season_id
        and seasons.status in ('open', 'in_progress', 'appeal_window', 'certified', 'archived')
    )
  );

drop policy if exists "service manages team season summaries" on public.n26_public_team_season_summary;
create policy "service manages team season summaries"
  on public.n26_public_team_season_summary
  for all to service_role
  using (true)
  with check (true);

grant select on public.n26_public_team_season_summary to anon, authenticated;
grant all on public.n26_public_team_season_summary to service_role;

create or replace function public.n26_refresh_public_team_season_summaries()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  delete from public.n26_public_team_season_summary;
  insert into public.n26_public_team_season_summary (
    season_id, team_id, cap_charge_cents, latest_contract_expiration_season,
    active_contract_count, updated_at
  )
  select
    seasons.id,
    contracts.team_id,
    coalesce(sum(contracts.cap_charge_cents), 0)::integer,
    max(contracts.end_season)::integer,
    count(*)::integer,
    now()
  from public.n26_seasons seasons
  join public.n26_contracts contracts
    on contracts.start_season <= seasons.season_number
   and contracts.end_season >= seasons.season_number
   and contracts.status in ('introductory', 'active')
  where seasons.status in ('open', 'in_progress', 'appeal_window', 'certified', 'archived')
  group by seasons.id, contracts.team_id;
  return null;
end;
$$;

drop trigger if exists n26_refresh_public_team_summary_contract_trigger on public.n26_contracts;
create trigger n26_refresh_public_team_summary_contract_trigger
after insert or update or delete on public.n26_contracts
for each statement execute function public.n26_refresh_public_team_season_summaries();

drop trigger if exists n26_refresh_public_team_summary_season_trigger on public.n26_seasons;
create trigger n26_refresh_public_team_summary_season_trigger
after insert or update of status, season_number on public.n26_seasons
for each statement execute function public.n26_refresh_public_team_season_summaries();

-- Backfill summaries for any already-public contracts.
insert into public.n26_public_team_season_summary (
  season_id, team_id, cap_charge_cents, latest_contract_expiration_season,
  active_contract_count
)
select
  seasons.id,
  contracts.team_id,
  coalesce(sum(contracts.cap_charge_cents), 0)::integer,
  max(contracts.end_season)::integer,
  count(*)::integer
from public.n26_seasons seasons
join public.n26_contracts contracts
  on contracts.start_season <= seasons.season_number
 and contracts.end_season >= seasons.season_number
 and contracts.status in ('introductory', 'active')
where seasons.status in ('open', 'in_progress', 'appeal_window', 'certified', 'archived')
group by seasons.id, contracts.team_id
on conflict (season_id, team_id) do update set
  cap_charge_cents = excluded.cap_charge_cents,
  latest_contract_expiration_season = excluded.latest_contract_expiration_season,
  active_contract_count = excluded.active_contract_count,
  updated_at = now();

revoke execute on function public.n26_refresh_public_team_season_summaries() from public, anon, authenticated;
