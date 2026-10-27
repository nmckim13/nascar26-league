-- Run only against an empty, disposable PostgreSQL database as a superuser:
-- psql -X -v ON_ERROR_STOP=1 -d league_test -f scripts/verify-race-results.sql
-- The transaction rolls back all fixture objects and data.
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

-- Load the actual result-entry schema and final relevant RPC definitions.
\ir ../supabase/migrations/001_league_identity_and_contracts.sql
\ir ../supabase/migrations/008_results_certification_and_audit.sql
\ir ../supabase/migrations/015_result_seat_identity.sql
\ir ../supabase/migrations/020_race_appeal_window.sql
\ir ../supabase/migrations/021_appeal_corrections.sql
\ir ../supabase/migrations/20260909231741_race_result_integrity.sql
\ir ../supabase/migrations/20260910004000_disqualification_policy.sql
\ir ../supabase/migrations/20260910007000_disqualification_integrity.sql
\ir ../supabase/migrations/20260910213000_stage_points.sql

-- Seed under the old schema to verify migration does not rewrite past awards.
do $$
declare
  ruleset uuid;
  season uuid;
  race uuid;
  team uuid := (select id from public.n26_teams where slug = 'hendrick');
  driver uuid;
  car text;
  payload jsonb := '[]';
begin
  insert into public.n26_rulesets (version, name, points_by_position, rating_weights)
  values ('test-v1', 'Test', '{"1":55,"2":39,"3":31}', '{}') returning id into ruleset;
  insert into public.n26_seasons (season_number, name, ruleset_id, status, roster_lock_at)
  values (1, 'Test', ruleset, 'in_progress', now()) returning id into season;
  insert into public.n26_season_races (season_id, race_number, track_name, track_short, status, starters_count, qualifying_status)
  values (season, 1, 'Test Speedway', 'Test', 'open', 2, 'canceled') returning id into race;
  foreach car in array array['5', '9', '24'] loop
    insert into public.n26_drivers (display_name) values ('Driver ' || car) returning id into driver;
    insert into public.n26_season_entries (season_id, driver_id) values (season, driver);
    insert into public.n26_seat_assignments (season_id, driver_id, team_id, car_number) values (season, driver, team, car);
    payload := payload || jsonb_build_array(jsonb_build_object(
      'driver_id', driver, 'team_id', team, 'car_number', car,
      'start_status', case when car = '24' then 'dns' else 'started' end,
      'finish_position', case car when '5' then 1 when '9' then 2 else null end
    ));
  end loop;
  perform public.n26_upsert_race_results(race, payload, 'legacy', null);
  update public.n26_race_results set points_earned = 46, stage2_points = 7
  where race_id = race and car_number = '9';
end;
$$;

\ir ../supabase/migrations/20261027000000_finish_only_results.sql

do $$
declare
  race uuid := (select id from public.n26_season_races where track_name = 'Test Speedway');
  payload jsonb;
  corrected jsonb;
  first_total integer;
  repeat_total integer;
  correction_total integer;
  before_results jsonb;
  audit_count integer;
  field text;
  rejected boolean;
begin
  if not exists (select 1 from public.n26_race_results where race_id = race
    and car_number = '9' and points_earned = 46 and stage2_points = 7) then
    raise exception 'Migration rewrote historical awards';
  end if;
  select jsonb_agg(jsonb_build_object(
    'driver_id', driver_id, 'team_id', team_id, 'car_number', car_number,
    'start_status', start_status, 'finish_position', finish_position
  ) order by case car_number when '5' then 0 when '9' then 1 else 2 end)
  into payload from public.n26_race_results where race_id = race;

  perform public.n26_upsert_race_results(race, payload, 'test-v1', null);
  select points_earned into first_total from public.n26_race_results where race_id = race and car_number = '5';
  perform public.n26_upsert_race_results(race, payload, 'test-v1', null);
  select points_earned into repeat_total from public.n26_race_results where race_id = race and car_number = '5';
  perform public.n26_publish_race_results(race, 48);

  corrected := jsonb_set(jsonb_set(payload, '{0,finish_position}', '2'), '{1,finish_position}', '1');
  perform public.n26_correct_race_results(race, corrected, 'test-correction', null);
  select points_earned into correction_total from public.n26_race_results where race_id = race and car_number = '5';
  if first_total is distinct from 55 or repeat_total is distinct from 55 or correction_total is distinct from 39 then
    raise exception 'Finish scoring regression: first=%, repeated=% (both expected 55), corrected=% (expected 39)', first_total, repeat_total, correction_total;
  end if;
  if exists (select 1 from public.n26_race_results where race_id = race and (stage1_points <> 0 or stage2_points <> 0)) then
    raise exception 'Result entry retained legacy stage awards';
  end if;
  if not exists (select 1 from public.n26_race_results where race_id = race and car_number = '9' and points_earned = 55) then
    raise exception 'Corrected winner did not receive finish points';
  end if;
  if not exists (select 1 from public.n26_result_corrections
    where race_id = race and previous_result->>'car_number' = '5'
      and previous_result->>'points_earned' = '55' and corrected_result->>'points_earned' = '39')
    or not exists (select 1 from public.n26_result_corrections where race_id = race
      and previous_result->>'car_number' = '9' and previous_result->>'points_earned' = '46'
      and previous_result->>'stage2_points' = '7' and corrected_result->>'points_earned' = '39'
      and corrected_result->>'stage2_points' = '0') then
    raise exception 'Correction audit does not capture the actual before/after awarded totals';
  end if;

  -- DQ and DNS remain zero, even though an ordinary starter earns finish points.
  corrected := jsonb_set(corrected, '{1,finish_status}', '"disqualified"');
  perform public.n26_correct_race_results(race, corrected, 'test-dq', null);
  if exists (select 1 from public.n26_race_results where race_id = race and car_number in ('9', '24')
    and (points_earned <> 0 or stage1_points <> 0 or stage2_points <> 0)) then
    raise exception 'DQ or DNS retained awarded points';
  end if;
  if not exists (select 1 from public.n26_season_races where id = race and status = 'completed' and certification_status = 'appeal_window')
    or exists (select 1 from public.n26_race_results where race_id = race and certification_status <> 'published') then
    raise exception 'Correction did not preserve published appeal state';
  end if;

  select jsonb_agg(to_jsonb(r) order by car_number) into before_results from public.n26_race_results r where race_id = race;
  select count(*) into audit_count from public.n26_result_corrections where race_id = race;
  foreach field in array array['stage1_points', 'stage2_points'] loop
    rejected := false;
    begin
      -- Change the first driver before rejecting the second: no partial write
      -- or audit row may survive the failed correction transaction.
      perform public.n26_correct_race_results(race,
        jsonb_set(jsonb_set(corrected, '{0,finish_status}', '"dnf"'), array['1', field], '0'), 'test-invalid', null);
    exception when check_violation then
      if sqlerrm not like 'Stage points are no longer awarded%' then raise; end if;
      rejected := true;
    end;
    if not rejected then raise exception 'Retired stage field accepted: %', field; end if;
  end loop;
  if (select jsonb_agg(to_jsonb(r) order by car_number) from public.n26_race_results r where race_id = race) <> before_results
    or (select count(*) from public.n26_result_corrections where race_id = race) <> audit_count then
    raise exception 'Failed correction changed results or audit history';
  end if;
  if not exists (select 1 from public.n26_season_races where id = race and status = 'completed') then
    raise exception 'Failed correction left the race reopened';
  end if;

  -- A partial DNF correction still earns finish points, not a DQ's zero,
  -- without modifying any other driver's result.
  perform public.n26_correct_race_results(race,
    jsonb_build_array(jsonb_set(corrected->0, '{finish_status}', '"dnf"')), 'test-dnf', null);
  if not exists (select 1 from public.n26_race_results where race_id = race and car_number = '5'
    and finish_status = 'dnf' and points_earned = 39 and stage1_points = 0 and stage2_points = 0)
    or not exists (select 1 from public.n26_race_results where race_id = race and car_number = '9' and points_earned = 0) then
    raise exception 'Partial DNF correction failed or changed another driver';
  end if;

  -- Existing appeal and service-only boundaries must survive the migration.
  update public.n26_season_races set appeal_ends_at = now() - interval '1 second' where id = race;
  rejected := false;
  begin
    perform public.n26_correct_race_results(race, payload, 'test-expired', null);
  exception when insufficient_privilege then rejected := true;
  end;
  if not rejected then raise exception 'Expired appeal accepted a correction'; end if;
  if has_function_privilege('anon', 'public.n26_upsert_race_results(uuid,jsonb,text,uuid)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.n26_upsert_race_results(uuid,jsonb,text,uuid)', 'EXECUTE')
    or not has_function_privilege('service_role', 'public.n26_upsert_race_results(uuid,jsonb,text,uuid)', 'EXECUTE')
    or to_regprocedure('public.n26_upsert_race_results_with_stages(uuid,jsonb,text,uuid)') is not null then
    raise exception 'Result-entry RPC permissions changed';
  end if;
  raise notice 'Race results verified: finish-only saves/corrections, historical awards, audits, DQ/DNS/DNF, retired-stage rejection, rollback, appeal deadline, and RPC grants.';
end;
$$;
set constraints all immediate;
rollback;
