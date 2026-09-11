-- Cover the public contract summary foreign keys used by history and team views.
create index if not exists n26_public_driver_contract_driver_idx
  on public.n26_public_driver_season_contract (driver_id, season_id);

create index if not exists n26_public_driver_contract_team_idx
  on public.n26_public_driver_season_contract (team_id, season_id);
