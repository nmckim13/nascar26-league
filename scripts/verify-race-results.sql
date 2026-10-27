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
\ir ../supabase/migrations/20260909225836_void_race_workflow.sql
\ir ../supabase/migrations/20260909232827_void_race_appeal.sql
\ir ../supabase/migrations/20260910220000_starting_ovr_and_news.sql
\ir ../supabase/migrations/20260914182239_homepage_storylines.sql
\ir ../supabase/migrations/20260914183415_generated_race_content.sql
\ir ../supabase/migrations/20261027030000_automatic_race_recaps.sql

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
  recap_id uuid;
  recap_published_at timestamptz := '2026-09-27T18:00:00Z';
  before_recap jsonb;
  other_race uuid;
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
  if exists (select 1 from public.n26_news_articles) then
    raise exception 'Draft results appeared in public news';
  end if;
  -- Existing generated drafts upgrade in place, rather than duplicating.
  insert into public.n26_news_articles (race_id, headline, generation_kind)
  values (race, 'Old draft', 'race_recap') returning id into recap_id;
  perform public.n26_publish_race_results(race, 48);
  if not exists (select 1 from public.n26_news_articles where id = recap_id and status = 'published'
    and season_id = (select season_id from public.n26_season_races where id = race)
    and published_at = (select published_at from public.n26_season_races where id = race)
    and headline = 'Driver 5 Wins at Test Speedway'
    and dek = 'Round 1 at Test Speedway. Official podium — 1: Driver 5 (#5); 2: Driver 9 (#9).'
    and body like '%1 — Driver 5 — #5 — classified — 55 points%'
    and body like '%DNS — Driver 24 — #24 — dns — 0 points%') then
    raise exception 'Publication did not publish a factual recap with awarded points and DNS';
  end if;

  -- Use a distinct historical publication date: now() is constant within this
  -- transaction and would otherwise conceal accidental date resets.
  update public.n26_news_articles set published_at = recap_published_at where id = recap_id;
  corrected := jsonb_set(jsonb_set(payload, '{0,finish_position}', '2'), '{1,finish_position}', '1');
  perform public.n26_correct_race_results(race, corrected, 'test-correction', null);
  if (select count(*) from public.n26_news_articles where race_id = race and generation_kind = 'race_recap') <> 1
    or not exists (select 1 from public.n26_news_articles where id = recap_id and status = 'published'
      and headline = 'Driver 9 Wins at Test Speedway' and published_at = recap_published_at
      and body like '%1 — Driver 9 — #9 — classified — 55 points%'
      and body like '%2 — Driver 5 — #5 — classified — 39 points%') then
    raise exception 'Correction did not update the same public recap or changed its publication date';
  end if;
  -- A failed news write must roll back the sporting update, not strand stale news.
  select jsonb_agg(to_jsonb(r) order by car_number) into before_results from public.n26_race_results r where race_id = race;
  select to_jsonb(n) into before_recap from public.n26_news_articles n where id = recap_id;
  select count(*) into audit_count from public.n26_result_corrections where race_id = race;
  alter table public.n26_news_articles add constraint test_recap_failure
    check (headline <> 'Driver 5 Wins at Test Speedway');
  rejected := false;
  begin
    perform public.n26_correct_race_results(race, payload, 'test-news-failure', null);
  exception when check_violation then rejected := true;
  end;
  alter table public.n26_news_articles drop constraint test_recap_failure;
  if not rejected
    or (select jsonb_agg(to_jsonb(r) order by car_number) from public.n26_race_results r where race_id = race) <> before_results
    or (select to_jsonb(n) from public.n26_news_articles n where id = recap_id) <> before_recap
    or (select count(*) from public.n26_result_corrections where race_id = race) <> audit_count
    or not exists (select 1 from public.n26_season_races where id = race and status = 'completed') then
    raise exception 'Failed recap write did not roll back results, audit, news, and race state together';
  end if;
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
  if not exists (select 1 from public.n26_news_articles where id = recap_id and status = 'published'
    and headline = 'Results Published at Test Speedway'
    and dek = 'Round 1 at Test Speedway. Official podium — 2: Driver 5 (#5).'
    and body like '%1 — Driver 9 — #9 — disqualified — 0 points%') then
    raise exception 'Recap invented a winner after P1 was disqualified, or omitted the DQ';
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

  -- Final certification preserves editorial changes and does not duplicate news.
  update public.n26_news_articles set headline = 'Commissioner edited recap' where id = recap_id;
  select to_jsonb(n) into before_recap from public.n26_news_articles n where id = recap_id;
  perform public.n26_finalize_race(race);
  if (select to_jsonb(n) from public.n26_news_articles n where id = recap_id) <> before_recap then
    raise exception 'Final certification rewrote an existing published article';
  end if;

  -- A second publication proves isolation and the void/archive lifecycle.
  insert into public.n26_season_races (season_id, race_number, track_name, track_short, status, starters_count, qualifying_status)
  select season_id, 2, 'Other Speedway', 'Other', 'open', 2, 'canceled'
  from public.n26_season_races where id = race returning id into other_race;
  perform public.n26_upsert_race_results(other_race, payload, 'test-other', null);
  insert into public.n26_news_articles (race_id, headline, status, published_at)
  values (other_race, 'Manual announcement', 'published', now());
  perform public.n26_publish_race_results(other_race, 48);
  if not exists (select 1 from public.n26_news_articles where race_id = other_race
    and generation_kind = 'race_recap' and headline = 'Driver 5 Wins at Other Speedway' and status = 'published') then
    raise exception 'Another race did not get its own recap';
  end if;
  perform public.n26_void_race(other_race, 'test cancellation');
  if not exists (select 1 from public.n26_news_articles where race_id = other_race and generation_kind = 'race_recap' and status = 'archived')
    or not exists (select 1 from public.n26_news_articles where race_id = other_race and headline = 'Manual announcement' and status = 'published')
    or (select to_jsonb(n) from public.n26_news_articles n where id = recap_id) <> before_recap then
    raise exception 'Voiding did not archive only that race recap';
  end if;
  if has_function_privilege('anon', 'public.n26_upsert_race_results(uuid,jsonb,text,uuid)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.n26_upsert_race_results(uuid,jsonb,text,uuid)', 'EXECUTE')
    or not has_function_privilege('service_role', 'public.n26_upsert_race_results(uuid,jsonb,text,uuid)', 'EXECUTE')
    or to_regprocedure('public.n26_upsert_race_results_with_stages(uuid,jsonb,text,uuid)') is not null then
    raise exception 'Result-entry RPC permissions changed';
  end if;
  raise notice 'Race results verified: scoring, audits, automatic recap publication/correction, stable identity/date, DNS/DQ, atomic rollback, finalization, and void archival.';
end;
$$;
set constraints all immediate;
rollback;
