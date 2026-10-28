-- Future creation only: never rewrite an existing Season 2 draft, ruleset,
-- schedule, or results. An existing draft needs a separately reviewed repair
-- (and a new ruleset version), not an implicit backfill from this migration.
-- chase_12_7_3 is the application scoring contract: top 12 eligible full-time
-- starters after seven regular races, seeds 2100,2075,2065,2060,2055,2050,
-- 2045,2040,2035,2030,2025,2020, then three Chase races with no drops.

create or replace function public.n26_create_draft_season(
  p_previous_season_id uuid,
  p_name text,
  p_ruleset_version text,
  p_cap_credits integer
)
returns public.n26_seasons
language plpgsql
set search_path = public
as $$
declare
  previous_season public.n26_seasons;
  previous_ruleset public.n26_rulesets;
  new_ruleset public.n26_rulesets;
  new_season public.n26_seasons;
  next_config jsonb;
begin
  if nullif(trim(p_name), '') is null or nullif(trim(p_ruleset_version), '') is null then
    raise exception 'Season name and ruleset version are required' using errcode = '22023';
  end if;
  if p_cap_credits is null or p_cap_credits < 240 or p_cap_credits % 5 <> 0 then
    raise exception 'The published equal cap must be at least 240 and a multiple of 5' using errcode = '23514';
  end if;

  select * into previous_season
  from public.n26_seasons
  where id = p_previous_season_id
  for update;
  if previous_season.id is null then
    raise exception 'Previous season not found' using errcode = '02000';
  end if;
  if previous_season.status not in ('certified', 'archived') then
    raise exception 'The previous season must be certified before creating the next draft' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.n26_seasons
    where season_number = previous_season.season_number + 1
  ) then
    raise exception 'The next season already exists' using errcode = '23505';
  end if;

  select * into previous_ruleset
  from public.n26_rulesets
  where id = previous_season.ruleset_id;
  if previous_ruleset.id is null or previous_ruleset.config->>'points_schedule_status' <> 'approved' then
    raise exception 'The previous season does not have an approved ruleset' using errcode = '23514';
  end if;

  -- Explicit championship formats require approval for each new season. In
  -- particular, Season 3 must not silently inherit Season 2's Chase scoring.
  next_config := (previous_ruleset.config - 'championship_format') || jsonb_build_object(
    'cap_credits', p_cap_credits,
    'cap_basis', 'minimum_feasible_undiscounted'
  );
  if previous_season.season_number = 1 then
    -- No drop-prefixed season rule may contradict the no-drops format. There
    -- are currently no such keys in the baseline; cover older custom rulesets.
    next_config := (next_config - array(
      select key from jsonb_object_keys(next_config) as keys(key)
      where key ~ '^(drop|dropped)(_|$)'
    )) || jsonb_build_object('championship_format', 'chase_12_7_3');
  end if;

  insert into public.n26_rulesets (
    version, name, season_length, team_size, driver_count,
    points_by_position, rating_weights, config
  ) values (
    trim(p_ruleset_version),
    trim(p_name) || ' - Rules',
    case when previous_season.season_number = 1 then 10 else previous_ruleset.season_length end,
    previous_ruleset.team_size,
    previous_ruleset.driver_count,
    previous_ruleset.points_by_position,
    previous_ruleset.rating_weights,
    next_config
  ) returning * into new_ruleset;

  insert into public.n26_seasons (
    season_number, name, ruleset_id, status, contract_market_status
  ) values (
    previous_season.season_number + 1,
    trim(p_name),
    new_ruleset.id,
    'draft',
    'closed'
  ) returning * into new_season;

  if previous_season.season_number = 1 then
    insert into public.n26_season_races (
      season_id, race_number, track_name, track_short, race_type, race_date,
      status, qualifying_status, certification_status
    )
    select new_season.id, schedule.race_number, schedule.track_name, schedule.track_short,
      case when schedule.race_number <= 7 then 'regular' else 'chase' end,
      null, 'upcoming', 'not_recorded', 'draft'
    from (values
      (1, 'Daytona International Speedway', 'Daytona'),
      (2, 'Iowa Speedway', 'Iowa'),
      (3, 'Dover Motor Speedway', 'Dover'),
      (4, 'Watkins Glen International', 'Watkins Glen'),
      (5, 'Rockingham Speedway', 'Rockingham'),
      (6, 'Bristol Motor Speedway', 'Bristol'),
      (7, 'Nashville Superspeedway', 'Nashville'),
      (8, 'Phoenix Raceway', 'Phoenix'),
      (9, 'Charlotte Motor Speedway', 'Charlotte'),
      (10, 'Chicagoland Speedway', 'Chicagoland')
    ) as schedule(race_number, track_name, track_short)
    order by schedule.race_number;
  else
    insert into public.n26_season_races (
      season_id, race_number, track_name, track_short, race_type, race_date,
      status, qualifying_status, certification_status
    )
    select new_season.id, race.race_number, race.track_name, race.track_short,
      case when race.race_type = 'chase' then 'regular' else race.race_type end,
      null, 'upcoming', 'not_recorded', 'draft'
    from public.n26_season_races race
    where race.season_id = previous_season.id
    order by race.race_number;
  end if;

  insert into public.n26_season_entries (season_id, driver_id, entry_status)
  select new_season.id, entries.driver_id, 'full_time'
  from public.n26_season_entries entries
  where entries.season_id = previous_season.id
    and entries.entry_status = 'full_time'
  order by entries.registered_at, entries.id;

  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  )
  select new_season.id, assignments.driver_id, assignments.team_id,
    assignments.car_number, now(), 'active'
  from public.n26_seat_assignments assignments
  join public.n26_season_entries entries
    on entries.season_id = previous_season.id
   and entries.driver_id = assignments.driver_id
   and entries.entry_status = 'full_time'
  where assignments.season_id = previous_season.id
    and assignments.assignment_status = 'active'
  order by assignments.starts_at, assignments.id;

  return new_season;
end;
$$;

revoke execute on function public.n26_create_draft_season(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public.n26_create_draft_season(uuid, text, text, integer) to service_role;

-- Validate at the existing draft-to-published boundary without replacing the
-- contract publication authority. Dates may be assigned while editing a draft.
-- This also rejects a malformed pre-existing Season 2 draft, without repairing
-- it or changing any already-published season.
create or replace function public.n26_validate_season_two_chase()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  ruleset public.n26_rulesets;
begin
  if new.season_number = 2 and old.status = 'draft' and new.status <> 'draft' then
    select * into ruleset from public.n26_rulesets where id = new.ruleset_id;
    if ruleset.season_length is distinct from 10
      or (ruleset.config->>'championship_format') is distinct from 'chase_12_7_3'
      or exists (select 1 from jsonb_object_keys(ruleset.config) as keys(key)
        where key ~ '^(drop|dropped)(_|$)') then
      raise exception 'Season 2 requires the ten-race chase_12_7_3 ruleset with no drop rules' using errcode = '23514';
    end if;

    if (select array_agg(track_name order by race_number)
        from public.n26_season_races where season_id = new.id) is distinct from array[
          'Daytona International Speedway', 'Iowa Speedway', 'Dover Motor Speedway',
          'Watkins Glen International', 'Rockingham Speedway', 'Bristol Motor Speedway',
          'Nashville Superspeedway', 'Phoenix Raceway', 'Charlotte Motor Speedway', 'Chicagoland Speedway'
        ]::text[]
      or (select array_agg(race_number order by race_number)
          from public.n26_season_races where season_id = new.id) is distinct from array[1,2,3,4,5,6,7,8,9,10]
      or exists (
        select 1 from public.n26_season_races where season_id = new.id
          and race_type <> case when race_number <= 7 then 'regular' else 'chase' end
      ) then
      raise exception 'Season 2 requires its approved ten-round schedule with seven regular and three Chase races' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

create trigger n26_validate_season_two_chase_trigger
before update on public.n26_seasons
for each row execute function public.n26_validate_season_two_chase();

revoke execute on function public.n26_validate_season_two_chase() from public, anon, authenticated;
