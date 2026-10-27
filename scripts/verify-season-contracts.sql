-- Run only against an empty, disposable PostgreSQL database as a superuser.
-- psql -X -v ON_ERROR_STOP=1 -d league_test -f scripts/verify-season-contracts.sql
-- All fixture objects, contracts, and season transitions roll back.
\set ON_ERROR_STOP on
begin;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role bypassrls; end if;
end;
$$;
create schema auth;
create table auth.users (id uuid primary key);
-- Empty legacy schedule prerequisite; fixture races use the normalized model.
create table public.n26_races (race_number integer, track_name text, track_short text, race_date date);
\ir ../supabase/migrations/001_league_identity_and_contracts.sql
\ir ../supabase/migrations/006_roster_invariants.sql
\ir ../supabase/migrations/007_commissioner_roster_transactions.sql
\ir ../supabase/migrations/009_draft_fixture_and_contract_cap.sql
\ir ../supabase/migrations/014_contract_invariants.sql
\ir ../supabase/migrations/017_atomic_contracts.sql
\ir ../supabase/migrations/018_contract_charge_required.sql
\ir ../supabase/migrations/023_roster_lock_enforcement.sql
\ir ../supabase/migrations/024_roster_trigger_delete_fix.sql
\ir ../supabase/migrations/20260909230500_contract_lifecycle.sql
\ir ../supabase/migrations/20260909231500_contract_market.sql
\ir ../supabase/migrations/20260909234213_roster_transfer_consents.sql
\ir ../supabase/migrations/20260909234726_contract_continuity.sql
\ir ../supabase/migrations/20260910006000_contract_annual_repricing.sql
\ir ../supabase/migrations/20260910019000_future_season_roster_continuity.sql
\ir ../supabase/migrations/20260910220000_starting_ovr_and_news.sql

do $$
declare
  ruleset uuid;
  season uuid;
  driver uuid;
  number_row record;
begin
  insert into public.n26_rulesets (version, name, points_by_position, rating_weights, config)
  values ('contract-test', 'Contract test', '{"1":55,"2":35}', '{}', '{"points_schedule_status":"approved"}')
  returning id into ruleset;
  insert into public.n26_seasons (season_number, name, ruleset_id)
  values (1, 'Contract test', ruleset) returning id into season;
  for number_row in
    select * from (select *, row_number() over (partition by team_id order by car_number::integer) as seat
      from public.n26_team_car_numbers) numbers where seat <= 3
  loop
    insert into public.n26_drivers (display_name) values ('Driver ' || number_row.car_number) returning id into driver;
    perform public.n26_assign_driver_to_seat(season, driver, number_row.team_id, number_row.car_number);
  end loop;
  -- Keep an existing valid contract: publication must create only missing ones.
  perform public.n26_create_contract(season, s.driver_id, s.team_id, s.id, 60)
  from public.n26_seat_assignments s where car_number = '5';
end;
$$;
create temporary table original_contract as select * from public.n26_contracts;
-- Initial seats predate the later transfer (now() is constant in this fixture's
-- single rollback transaction, unlike separate real commissioner requests).
update public.n26_seat_assignments set starts_at = now() - interval '1 day';
set constraints all immediate;

\ir ../supabase/migrations/20261027020000_season_contract_budget_consistency.sql

do $$
declare
  season uuid := (select id from public.n26_seasons where season_number = 1);
  ruleset uuid := (select ruleset_id from public.n26_seasons where id = season);
  outcome jsonb;
  transactions_before integer := (select count(*) from public.n26_transactions);
begin
  if (select to_jsonb(c) from public.n26_contracts c) is distinct from
    (select to_jsonb(c) from original_contract c) then
    raise exception 'Migration changed an existing contract';
  end if;
  -- With no explicit cap, all eight three-driver teams must publish at 60 each.
  outcome := public.n26_publish_season(season);
  if outcome->>'contracts_created' <> '23'
    or outcome->'season'->>'status' <> 'open'
    or outcome->'season'->>'roster_lock_at' is null
    or (select count(*) from public.n26_contracts) <> 24
    or exists (select 1 from public.n26_contracts where base_rating <> 60 or cap_charge_cents <> 6000
      or original_term_seasons <> 1 or term_discount_bps <> 0 or loyalty_discount_bps <> 0 or status <> 'introductory')
    or (select count(*) from (select team_id from public.n26_contracts group by team_id
      having count(*) = 3 and sum(cap_charge_cents) = 18000) teams) <> 8
    or (select count(*) from public.n26_transactions) <> transactions_before + 23 then
    raise exception 'Publishing failed to create 23 missing 60-credit contracts, eight 180-credit teams, signing audit, or roster lock';
  end if;
  begin
    perform public.n26_publish_season(season);
    raise exception 'Published season was published again';
  exception when insufficient_privilege then null;
  end;

  -- Existing contracts must not bypass cap checks. This is the exact boundary:
  -- 180 credits fits; 179 rejects, even if every contract already exists.
  update public.n26_seasons set status = 'draft', roster_lock_at = null where id = season;
  update public.n26_rulesets set config = config || '{"cap_credits":179}' where id = ruleset;
  begin
    perform public.n26_publish_season(season);
    raise exception 'Publishing accepted an over-budget team';
  exception when check_violation then
    if sqlerrm <> 'The roster exceeds the published team salary cap' then raise; end if;
  end;
  if not exists (select 1 from public.n26_seasons where id = season and status = 'draft' and roster_lock_at is null) then
    raise exception 'Rejected publication changed the season lock';
  end if;
  update public.n26_rulesets set config = config || '{"cap_credits":180}' where id = ruleset;
  outcome := public.n26_publish_season(season);
  if outcome->>'contracts_created' <> '0' then raise exception 'Publication duplicated existing contracts'; end if;

  -- Missing contracts plus an insufficient explicit cap: no partial signings,
  -- audit entries, or season transition may survive the failed publication.
  update public.n26_seasons set status = 'draft', roster_lock_at = null where id = season;
  delete from public.n26_transactions where contract_id not in (select id from original_contract);
  delete from public.n26_contracts where id not in (select id from original_contract);
  select count(*) into transactions_before from public.n26_transactions;
  update public.n26_rulesets set config = config || '{"cap_credits":120}' where id = ruleset;
  begin
    perform public.n26_publish_season(season);
    raise exception 'Publishing ignored the explicit signing cap';
  exception when check_violation then
    if sqlerrm <> 'Contract would exceed the team salary cap' then raise; end if;
  end;
  if (select count(*) from public.n26_contracts) <> 1
    or (select count(*) from public.n26_transactions) <> transactions_before
    or not exists (select 1 from public.n26_seasons where id = season and status = 'draft' and roster_lock_at is null) then
    raise exception 'Failed publication left partial contracts, audits, or a roster lock';
  end if;
  update public.n26_rulesets set config = config - 'cap_credits' where id = ruleset;

  -- Historical contracts are not repriced by this migration. Two existing
  -- 90-credit deals plus a new 60-credit signing must fit exactly at 240.
  perform public.n26_create_contract(season, s.driver_id, s.team_id, s.id, 60)
  from public.n26_seat_assignments s where car_number = '9';
  update public.n26_contracts set base_rating = 90, cap_charge_cents = 9000;
  perform public.n26_create_contract(season, s.driver_id, s.team_id, s.id, 60)
  from public.n26_seat_assignments s where car_number = '24';
  if (select sum(cap_charge_cents) from public.n26_contracts) <> 24000 then
    raise exception 'Signing did not respect the exact 240-credit inaugural fallback';
  end if;
  update public.n26_contracts set base_rating = 60, cap_charge_cents = 6000;
  perform public.n26_publish_season(season);
end;
$$;

do $$
declare
  season uuid := (select id from public.n26_seasons where season_number = 1);
  next_season public.n26_seasons;
  contract public.n26_contracts;
  seat public.n26_seat_assignments;
  invalid_cap integer;
  signature text;
begin
  update public.n26_seasons set status = 'certified' where id = season;
  foreach invalid_cap in array array[null, 180, 235, 241] loop
    begin
      perform public.n26_create_draft_season(season, 'Invalid', 'invalid', invalid_cap);
      raise exception 'Accepted an invalid future-season cap: %', invalid_cap;
    exception when check_violation then
      if sqlerrm <> 'The published equal cap must be at least 240 and a multiple of 5' then raise; end if;
    end;
  end loop;
  select * into next_season from public.n26_create_draft_season(season, 'Season 2', 'contract-test-s2', 240);
  if (select config->>'cap_credits' from public.n26_rulesets where id = next_season.ruleset_id) <> '240'
    or (select count(*) from public.n26_season_entries where season_id = next_season.id) <> 24
    or (select count(*) from public.n26_seat_assignments where season_id = next_season.id and assignment_status = 'active') <> 24 then
    raise exception 'Next draft did not preserve its 240-credit cap and full roster';
  end if;

  -- Full future roster, no current contracts: do not invent introductory deals.
  begin
    perform public.n26_publish_season(next_season.id);
    raise exception 'Future season published without contracts';
  exception when check_violation then
    if sqlerrm <> 'Every full-time driver needs exactly one current contract before publishing' then raise; end if;
  end;

  -- A 60-credit transfer fits two historical 90-credit deals at exactly 240;
  -- an explicit cap of 239 must reject the same transfer without moving it.
  update public.n26_seasons set status = 'draft', roster_lock_at = null where id = season;
  update public.n26_seat_assignments set assignment_status = 'released', ends_at = now()
  where season_id = season and car_number = '24';
  update public.n26_contracts set status = 'released' where driver_id =
    (select driver_id from public.n26_season_entries where season_id = season
      and driver_id not in (select driver_id from public.n26_seat_assignments where season_id = season and assignment_status = 'active'));
  update public.n26_contracts set base_rating = 90, cap_charge_cents = 9000
  where team_id = (select id from public.n26_teams where slug = 'hendrick') and status = 'introductory';
  select * into seat from public.n26_seat_assignments where season_id = season and car_number = '11';
  update public.n26_rulesets set config = config || '{"cap_credits":239}'
  where id = (select ruleset_id from public.n26_seasons where id = season);
  begin
    perform public.n26_transfer_driver_to_seat(season, seat.driver_id,
      (select id from public.n26_teams where slug = 'hendrick'), '24', true, true, true, 'Over budget');
    raise exception 'Transfer ignored the explicit team cap';
  exception when check_violation then
    if sqlerrm <> 'Carrying this contract would exceed the destination team salary cap' then raise; end if;
  end;
  if not exists (select 1 from public.n26_seat_assignments where id = seat.id and assignment_status = 'active') then
    raise exception 'Rejected transfer changed the original seat';
  end if;
  update public.n26_rulesets set config = config - 'cap_credits'
  where id = (select ruleset_id from public.n26_seasons where id = season);
  perform public.n26_transfer_driver_to_seat(season, seat.driver_id,
    (select id from public.n26_teams where slug = 'hendrick'), '24', true, true, true, 'Budget regression');
  select * into contract from public.n26_contracts where driver_id = seat.driver_id and status = 'introductory';
  if contract.team_id <> (select id from public.n26_teams where slug = 'hendrick') or contract.cap_charge_cents <> 6000 then
    raise exception 'Transfer did not carry the contract at its original charge';
  end if;

  foreach signature in array array[
    'public.n26_publish_season(uuid)',
    'public.n26_create_contract(uuid,uuid,uuid,uuid,numeric,integer,integer,integer)',
    'public.n26_transfer_driver_to_seat(uuid,uuid,uuid,text,boolean,boolean,boolean,text)',
    'public.n26_create_draft_season(uuid,text,text,integer)'
  ] loop
    if has_function_privilege('anon', signature, 'EXECUTE')
      or has_function_privilege('authenticated', signature, 'EXECUTE')
      or not has_function_privilege('service_role', signature, 'EXECUTE') then
      raise exception 'Contract/season RPC no longer service-role-only: %', signature;
    end if;
  end loop;
  raise notice 'Season contracts verified: 24-driver publication, 60-credit contracts, 240-credit fallback/floor, explicit caps, existing contracts, rollback, transfers, future-season guards, and RPC grants.';
end;
$$;
set constraints all immediate;
rollback;
