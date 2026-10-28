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
\ir ../supabase/migrations/20260910018000_freeze_rated_field_size.sql
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
  values ('contract-test', 'Contract test', '{"1":55,"2":35}', '{}',
    '{"points_schedule_status":"approved","drop_rule":"lowest_finish","drop_count":1,"qualifying_required":true}')
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

-- A pre-existing Season 2 draft must survive migration byte-for-byte. Give the
-- old copying path a schedule unlike Season 2's to catch accidental backfills.
insert into public.n26_season_races (season_id, race_number, track_name, track_short, race_type, race_date)
select id, 1, 'Old exhibition', 'Old', 'exhibition', date '2026-01-01'
from public.n26_seasons where season_number = 1;
update public.n26_seasons set status = 'certified' where season_number = 1;
select public.n26_create_draft_season(
  (select id from public.n26_seasons where season_number = 1), 'Existing draft', 'existing-draft', 245);
create temporary table before_chase_rulesets as select * from public.n26_rulesets;
create temporary table before_chase_seasons as select * from public.n26_seasons;
create temporary table before_chase_races as select * from public.n26_season_races;
create temporary table before_chase_contracts as select * from public.n26_contracts;

\ir ../supabase/migrations/20261028000000_season_two_chase.sql

do $$
begin
  if exists ((select * from public.n26_rulesets except select * from before_chase_rulesets)
    union all (select * from before_chase_rulesets except select * from public.n26_rulesets))
    or exists ((select * from public.n26_seasons except select * from before_chase_seasons)
    union all (select * from before_chase_seasons except select * from public.n26_seasons))
    or exists ((select * from public.n26_season_races except select * from before_chase_races)
    union all (select * from before_chase_races except select * from public.n26_season_races))
    or exists ((select * from public.n26_contracts except select * from before_chase_contracts)
    union all (select * from before_chase_contracts except select * from public.n26_contracts)) then
    raise exception 'Chase migration rewrote existing league data';
  end if;
  begin
    perform public.n26_create_draft_season(
      (select id from public.n26_seasons where season_number = 1), 'Duplicate', 'duplicate', 240);
    raise exception 'Existing Season 2 was silently replaced';
  exception when unique_violation then
    if sqlerrm <> 'The next season already exists' then raise; end if;
  end;
end;
$$;
-- Disposable fixture cleanup only, so the following test exercises creation.
delete from public.n26_seat_assignments where season_id = (select id from public.n26_seasons where season_number = 2);
delete from public.n26_season_entries where season_id = (select id from public.n26_seasons where season_number = 2);
delete from public.n26_seasons where season_number = 2;
delete from public.n26_rulesets where version = 'existing-draft';
create temporary table prior_roster as
select driver_id, team_id, car_number from public.n26_seat_assignments
where season_id = (select id from public.n26_seasons where season_number = 1) and assignment_status = 'active';

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

do $$
declare
  season public.n26_seasons := (select s from public.n26_seasons s where season_number = 2);
  ruleset public.n26_rulesets;
  later_season public.n26_seasons;
  bad_ruleset uuid;
  scenario integer;
  outcome jsonb;
begin
  select * into ruleset from public.n26_rulesets where id = season.ruleset_id;
  if ruleset.season_length <> 10 or ruleset.config->>'championship_format' <> 'chase_12_7_3'
    or ruleset.config ?| array['drop_rule','drop_count']
    or ruleset.config->>'qualifying_required' <> 'true'
    or ruleset.config->>'cap_basis' <> 'minimum_feasible_undiscounted'
    or ruleset.points_by_position <> '{"1":55,"2":35}'::jsonb
    or ruleset.rating_weights <> '{}'::jsonb
    or season.contract_market_status <> 'closed'
    or exists (select 1 from public.n26_contracts where season_id = season.id) then
    raise exception 'Season 2 rules, unrelated settings, or contract continuity changed';
  end if;
  if (select array_agg(track_short order by race_number) from public.n26_season_races where season_id = season.id)
    is distinct from array['Daytona','Iowa','Dover','Watkins Glen','Rockingham','Bristol','Nashville','Phoenix','Charlotte','Chicagoland']
    or exists (select 1 from public.n26_season_races where season_id = season.id
      and (race_date is not null or status <> 'upcoming' or qualifying_status <> 'not_recorded'
        or certification_status <> 'draft'
        or race_type <> case when race_number <= 7 then 'regular' else 'chase' end)) then
    raise exception 'Season 2 did not get its date-free ten-round 7/3 schedule';
  end if;
  if exists ((select driver_id, team_id, car_number from public.n26_seat_assignments where season_id = season.id
      except select * from prior_roster)
    union all (select * from prior_roster except select driver_id, team_id, car_number
      from public.n26_seat_assignments where season_id = season.id)) then
    raise exception 'Season 2 changed a copied driver/team/car identity';
  end if;
  if (select to_jsonb(r) from public.n26_rulesets r where version = 'contract-test') is distinct from
    (select to_jsonb(r) from before_chase_rulesets r where version = 'contract-test') then
    raise exception 'Draft creation changed its prior immutable ruleset';
  end if;

  -- Clone rulesets instead of editing historical versions. These direct status
  -- transitions isolate the trigger; the successful RPC publication below also
  -- exercises it through the real contract authority.
  for scenario in 1..4 loop
    insert into public.n26_rulesets (version, name, season_length, points_by_position, rating_weights, config)
    values ('bad-chase-' || scenario, 'Invalid Chase', case when scenario = 1 then 8 else 10 end,
      ruleset.points_by_position, ruleset.rating_weights,
      case when scenario = 2 then ruleset.config - 'championship_format'
        when scenario = 3 then ruleset.config || '{"drop_count":1}'::jsonb
        when scenario = 4 then ruleset.config || '{"championship_format":"wrong_format"}'::jsonb
        else ruleset.config end)
    returning id into bad_ruleset;
    update public.n26_seasons set ruleset_id = bad_ruleset where id = season.id;
    begin
      update public.n26_seasons set status = 'open', roster_lock_at = now() where id = season.id;
      raise exception 'Season 2 accepted malformed rules, scenario %', scenario;
    exception when check_violation then
      if sqlerrm <> 'Season 2 requires the ten-race chase_12_7_3 ruleset with no drop rules' then raise; end if;
    end;
  end loop;
  update public.n26_seasons set ruleset_id = ruleset.id where id = season.id;

  for scenario in 1..5 loop
    begin
      case scenario
        when 1 then delete from public.n26_season_races where season_id = season.id and race_number = 10;
        when 2 then update public.n26_season_races set race_type = 'regular' where season_id = season.id and race_number = 8;
        when 3 then update public.n26_season_races set track_name = 'Wrong track' where season_id = season.id and race_number = 3;
        when 4 then update public.n26_season_races set race_number = 11 where season_id = season.id and race_number = 10;
        when 5 then insert into public.n26_season_races (season_id, race_number, track_name, track_short)
          values (season.id, 11, 'Extra race', 'Extra');
      end case;
      update public.n26_seasons set status = 'open', roster_lock_at = now() where id = season.id;
      raise exception 'Season 2 accepted malformed schedule, scenario %', scenario;
    exception when check_violation then
      if sqlerrm <> 'Season 2 requires its approved ten-round schedule with seven regular and three Chase races' then raise; end if;
      -- Exception subtransaction restores each schedule mutation.
    end;
  end loop;
  if not exists (select 1 from public.n26_seasons where id = season.id and status = 'draft' and roster_lock_at is null) then
    raise exception 'Rejected Season 2 publication changed status or lock';
  end if;

  -- Replace the disposable fixture's expired one-year deals with carried
  -- two-season contracts without bypassing any signing triggers.
  update public.n26_contracts set status = 'expired' where start_season = 1;
  insert into public.n26_contracts (
    season_id, driver_id, team_id, seat_assignment_id, base_rating, cap_charge_cents,
    start_season, end_season, status, original_term_seasons
  )
  select (select id from public.n26_seasons where season_number = 1), driver_id, team_id,
    id, 60, 6000, 1, 2, 'active', 2
  from public.n26_seat_assignments where season_id = season.id and assignment_status = 'active';
  -- Dates are editable, not a publication prohibition.
  update public.n26_season_races set race_date = date '2027-01-01' where season_id = season.id;
  update public.n26_season_races set race_type = 'regular' where season_id = season.id and race_number = 8;
  begin
    perform public.n26_publish_season(season.id);
    raise exception 'Publication RPC bypassed the Season 2 schedule guard';
  exception when check_violation then
    if sqlerrm <> 'Season 2 requires its approved ten-round schedule with seven regular and three Chase races' then raise; end if;
  end;
  if not exists (select 1 from public.n26_seasons where id = season.id and status = 'draft' and roster_lock_at is null) then
    raise exception 'Rejected publication RPC changed the season status or roster lock';
  end if;
  update public.n26_season_races set race_type = 'chase' where season_id = season.id and race_number = 8;
  outcome := public.n26_publish_season(season.id);
  if outcome->>'contracts_created' <> '0' or outcome->'season'->>'status' <> 'open'
    or outcome->'season'->>'rated_field_size' <> '24' then
    raise exception 'Valid Chase season did not publish with carried contracts';
  end if;
  update public.n26_seasons set status = 'certified' where id = season.id;
  select * into later_season from public.n26_create_draft_season(season.id, 'Season 3', 'contract-test-s3', 245);
  if (select config ? 'championship_format' or config->>'cap_credits' <> '245' or season_length <> 10
      from public.n26_rulesets where id = later_season.ruleset_id)
    or (select count(*) from public.n26_season_races where season_id = later_season.id) <> 10
    or exists (select 1 from public.n26_season_races where season_id = later_season.id
      and (race_type <> 'regular' or race_date is not null))
    or (select count(*) from public.n26_seat_assignments where season_id = later_season.id and assignment_status = 'active') <> 24 then
    raise exception 'Season 3 inherited Chase scoring or lost ordinary cloning/cap/roster behavior';
  end if;
  raise notice 'Season 2 Chase verified: no backfill, ten date-free rounds, 7/3 split, no drops, publish guards, carried contracts, and Season 3 format reset.';
end;
$$;
set constraints all immediate;
rollback;
