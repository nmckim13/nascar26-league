-- Expose only the current public-season contract summary on driver profiles.
-- Detailed contract and transaction records remain commissioner-only.
create table if not exists public.n26_public_driver_season_contract (
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id) on delete cascade,
  team_id uuid not null references public.n26_teams(id) on delete cascade,
  start_season integer not null,
  end_season integer not null,
  original_term_seasons integer not null check (original_term_seasons between 1 and 3),
  term_discount_bps integer not null default 0 check (term_discount_bps in (0, 200, 400)),
  loyalty_discount_bps integer not null default 0 check (loyalty_discount_bps in (0, 100)),
  status text not null check (status in ('introductory', 'active')),
  cap_charge_cents integer not null check (cap_charge_cents >= 0),
  updated_at timestamptz not null default now(),
  primary key (season_id, driver_id)
);

alter table public.n26_public_driver_season_contract enable row level security;

drop policy if exists "public can read driver season contracts" on public.n26_public_driver_season_contract;
create policy "public can read driver season contracts"
  on public.n26_public_driver_season_contract
  for select to anon, authenticated
  using (
    exists (
      select 1
      from public.n26_seasons seasons
      where seasons.id = n26_public_driver_season_contract.season_id
        and seasons.status in ('open', 'in_progress', 'appeal_window', 'certified', 'archived')
    )
  );

drop policy if exists "service manages driver season contracts" on public.n26_public_driver_season_contract;
create policy "service manages driver season contracts"
  on public.n26_public_driver_season_contract
  for all to service_role
  using (true)
  with check (true);

grant select on public.n26_public_driver_season_contract to anon, authenticated;
grant all on public.n26_public_driver_season_contract to service_role;

create or replace function public.n26_refresh_public_driver_season_contracts()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  delete from public.n26_public_driver_season_contract;
  insert into public.n26_public_driver_season_contract (
    season_id, driver_id, team_id, start_season, end_season,
    original_term_seasons, term_discount_bps, loyalty_discount_bps,
    status, cap_charge_cents, updated_at
  )
  select distinct on (seasons.id, contracts.driver_id)
    seasons.id,
    contracts.driver_id,
    contracts.team_id,
    contracts.start_season,
    contracts.end_season,
    contracts.original_term_seasons,
    contracts.term_discount_bps,
    contracts.loyalty_discount_bps,
    contracts.status,
    contracts.cap_charge_cents,
    now()
  from public.n26_seasons seasons
  join public.n26_contracts contracts
    on contracts.start_season <= seasons.season_number
   and contracts.end_season >= seasons.season_number
   and contracts.status in ('introductory', 'active')
  where seasons.status in ('open', 'in_progress', 'appeal_window', 'certified', 'archived')
  order by seasons.id, contracts.driver_id, contracts.start_season desc, contracts.created_at desc;
  return null;
end;
$$;

drop trigger if exists n26_refresh_public_driver_contract_contract_trigger on public.n26_contracts;
create trigger n26_refresh_public_driver_contract_contract_trigger
after insert or update or delete on public.n26_contracts
for each statement execute function public.n26_refresh_public_driver_season_contracts();

drop trigger if exists n26_refresh_public_driver_contract_season_trigger on public.n26_seasons;
create trigger n26_refresh_public_driver_contract_season_trigger
after insert or update of status, season_number on public.n26_seasons
for each statement execute function public.n26_refresh_public_driver_season_contracts();

revoke execute on function public.n26_refresh_public_driver_season_contracts() from public, anon, authenticated;
