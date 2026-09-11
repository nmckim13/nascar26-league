-- Seed the next draft from the prior certified full-time roster. Contracts are
-- intentionally not copied: a multi-season contract already covers the new
-- season through its start/end range and keeps its original signing record.

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
begin
  if nullif(trim(p_name), '') is null or nullif(trim(p_ruleset_version), '') is null then
    raise exception 'Season name and ruleset version are required' using errcode = '22023';
  end if;
  if p_cap_credits < 155 or p_cap_credits % 5 <> 0 then
    raise exception 'The published equal cap must be at least 155 and a multiple of 5' using errcode = '23514';
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

  insert into public.n26_rulesets (
    version, name, season_length, team_size, driver_count,
    points_by_position, rating_weights, config
  ) values (
    trim(p_ruleset_version),
    trim(p_name) || ' - Rules',
    previous_ruleset.season_length,
    previous_ruleset.team_size,
    previous_ruleset.driver_count,
    previous_ruleset.points_by_position,
    previous_ruleset.rating_weights,
    previous_ruleset.config || jsonb_build_object(
      'cap_credits', p_cap_credits,
      'cap_basis', 'minimum_feasible_undiscounted'
    )
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

  insert into public.n26_season_races (
    season_id, race_number, track_name, track_short, race_type, race_date,
    status, qualifying_status, certification_status
  )
  select
    new_season.id,
    race.race_number,
    race.track_name,
    race.track_short,
    case when race.race_type = 'chase' then 'regular' else race.race_type end,
    null,
    'upcoming',
    'not_recorded',
    'draft'
  from public.n26_season_races race
  where race.season_id = previous_season.id
  order by race.race_number;

  insert into public.n26_season_entries (season_id, driver_id, entry_status)
  select new_season.id, entries.driver_id, 'full_time'
  from public.n26_season_entries entries
  where entries.season_id = previous_season.id
    and entries.entry_status = 'full_time'
  order by entries.registered_at, entries.id;

  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  )
  select
    new_season.id,
    assignments.driver_id,
    assignments.team_id,
    assignments.car_number,
    now(),
    'active'
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

create or replace function public.n26_publish_season(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  full_time_count integer;
  active_seat_count integer;
  current_contract_count integer;
  contracts_created_count integer := 0;
  expected_driver_count integer;
  expected_team_size integer;
  assignment_row record;
  updated_season public.n26_seasons;
begin
  select seasons.* into season_row
  from public.n26_seasons seasons
  where seasons.id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.status <> 'draft' then
    raise exception 'Only a draft season can be published' using errcode = '42501';
  end if;

  select rulesets.* into ruleset_row
  from public.n26_rulesets rulesets
  where rulesets.id = season_row.ruleset_id;
  if coalesce(ruleset_row.config->>'points_schedule_status', '') <> 'approved' then
    raise exception 'The 24-position points schedule must be approved before publishing' using errcode = '23514';
  end if;
  expected_driver_count := ruleset_row.driver_count;
  expected_team_size := ruleset_row.team_size;

  select count(*) into full_time_count
  from public.n26_season_entries
  where season_id = p_season_id and entry_status = 'full_time';
  if full_time_count <> expected_driver_count then
    raise exception 'Publishing requires % full-time drivers', expected_driver_count using errcode = '23514';
  end if;

  select count(*) into active_seat_count
  from public.n26_seat_assignments assignments
  join public.n26_season_entries entries
    on entries.season_id = assignments.season_id
   and entries.driver_id = assignments.driver_id
   and entries.entry_status = 'full_time'
  where assignments.season_id = p_season_id
    and assignments.assignment_status = 'active';
  if active_seat_count <> expected_driver_count then
    raise exception 'Publishing requires % active full-time seats', expected_driver_count using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_season_entries entries
    where entries.season_id = p_season_id
      and entries.entry_status = 'full_time'
      and not exists (
        select 1 from public.n26_seat_assignments assignments
        where assignments.season_id = p_season_id
          and assignments.driver_id = entries.driver_id
          and assignments.assignment_status = 'active'
      )
  ) then
    raise exception 'Every full-time driver must have an active seat' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_seat_assignments assignments
    where assignments.season_id = p_season_id
      and assignments.assignment_status = 'active'
      and not exists (
        select 1 from public.n26_season_entries entries
        where entries.season_id = p_season_id
          and entries.driver_id = assignments.driver_id
          and entries.entry_status = 'full_time'
      )
  ) then
    raise exception 'Reserve or inactive entries cannot occupy a full-time seat at publish' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_teams teams
    left join public.n26_seat_assignments assignments
      on assignments.team_id = teams.id
     and assignments.season_id = p_season_id
     and assignments.assignment_status = 'active'
    where teams.status = 'active'
    group by teams.id, teams.seat_limit
    having count(assignments.id) <> expected_team_size
  ) then
    raise exception 'Every active team must have exactly % seats at publish', expected_team_size using errcode = '23514';
  end if;

  select count(distinct contracts.driver_id) into current_contract_count
  from public.n26_contracts contracts
  where contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory', 'active');
  if season_row.season_number = 1 then
    contracts_created_count := expected_driver_count - current_contract_count;
    for assignment_row in
      select assignments.*
      from public.n26_seat_assignments assignments
      where assignments.season_id = p_season_id
        and assignments.assignment_status = 'active'
        and not exists (
          select 1 from public.n26_contracts contracts
          where contracts.driver_id = assignments.driver_id
            and contracts.start_season <= season_row.season_number
            and contracts.end_season >= season_row.season_number
            and contracts.status in ('introductory', 'active')
        )
      order by assignments.id
    loop
      perform public.n26_create_contract(
        p_season_id,
        assignment_row.driver_id,
        assignment_row.team_id,
        assignment_row.id,
        50,
        1,
        0,
        0
      );
    end loop;
  end if;

  select count(distinct contracts.driver_id) into current_contract_count
  from public.n26_contracts contracts
  where contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory', 'active');
  if current_contract_count <> expected_driver_count then
    raise exception 'Every full-time driver needs exactly one current contract before publishing' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_season_entries entries
    where entries.season_id = p_season_id
      and entries.entry_status = 'full_time'
      and (
        (select count(*)
         from public.n26_contracts contracts
         where contracts.driver_id = entries.driver_id
           and contracts.start_season <= season_row.season_number
           and contracts.end_season >= season_row.season_number
           and contracts.status in ('introductory', 'active')) <> 1
        or not exists (
          select 1
          from public.n26_seat_assignments assignments
          join public.n26_contracts contracts
            on contracts.driver_id = assignments.driver_id
           and contracts.team_id = assignments.team_id
           and contracts.start_season <= season_row.season_number
           and contracts.end_season >= season_row.season_number
           and contracts.status in ('introductory', 'active')
          where assignments.season_id = p_season_id
            and assignments.driver_id = entries.driver_id
            and assignments.assignment_status = 'active'
        )
      )
  ) then
    raise exception 'Every full-time driver needs one contract matching the active team before publishing' using errcode = '23514';
  end if;

  select * into updated_season
  from public.n26_seasons
  where id = p_season_id;
  update public.n26_seasons
  set status = 'open', roster_lock_at = now()
  where id = p_season_id
  returning * into updated_season;

  return jsonb_build_object(
    'season', to_jsonb(updated_season),
    'contracts_created', contracts_created_count
  );
end;
$$;

revoke execute on function public.n26_publish_season(uuid) from public, anon, authenticated;
grant execute on function public.n26_publish_season(uuid) to service_role;
