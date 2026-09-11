-- Create the next season without copying mutable roster state. The previous
-- season remains immutable, while its schedule and approved rules are cloned
-- into a new draft with an explicitly published equal cap.

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

  return new_season;
end;
$$;

revoke execute on function public.n26_create_draft_season(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public.n26_create_draft_season(uuid, text, text, integer) to service_role;
