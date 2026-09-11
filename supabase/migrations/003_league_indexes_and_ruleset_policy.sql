-- Follow-up hardening for the normalized league tables.

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'n26_rulesets'
      and policyname = 'public can read rulesets'
  ) then
    create policy "public can read rulesets"
      on public.n26_rulesets for select using (true);
  end if;
end
$$;

create index if not exists n26_team_car_numbers_team_idx
  on public.n26_team_car_numbers (team_id);

create index if not exists n26_season_entries_driver_idx
  on public.n26_season_entries (driver_id);

create index if not exists n26_season_races_season_idx
  on public.n26_season_races (season_id, race_number);

create index if not exists n26_seat_assignments_driver_idx
  on public.n26_seat_assignments (driver_id, season_id);

create index if not exists n26_seat_assignments_team_idx
  on public.n26_seat_assignments (team_id, season_id);

create index if not exists n26_race_results_seat_assignment_idx
  on public.n26_race_results (seat_assignment_id);

create index if not exists n26_race_results_team_idx
  on public.n26_race_results (team_id, race_id);

create index if not exists n26_contracts_season_idx
  on public.n26_contracts (season_id, status);

create index if not exists n26_contracts_driver_idx
  on public.n26_contracts (driver_id, status);

create index if not exists n26_contracts_team_idx
  on public.n26_contracts (team_id, start_season);

create index if not exists n26_rating_snapshots_driver_idx
  on public.n26_rating_snapshots (driver_id, season_id);

create index if not exists n26_rating_snapshots_ruleset_idx
  on public.n26_rating_snapshots (ruleset_id);

create index if not exists n26_transactions_season_idx
  on public.n26_transactions (season_id, effective_at desc);

create index if not exists n26_transactions_from_team_idx
  on public.n26_transactions (from_team_id, effective_at desc);

create index if not exists n26_transactions_to_team_idx
  on public.n26_transactions (to_team_id, effective_at desc);
