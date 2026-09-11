-- Approve a complete scoring schedule by creating a new immutable ruleset
-- version and moving the draft season to it atomically.

create or replace function public.n26_approve_points_schedule(
  p_season_id uuid,
  p_version text,
  p_points_by_position jsonb
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  current_ruleset public.n26_rulesets;
  approved_ruleset public.n26_rulesets;
  key_count integer;
  driver_limit integer;
  position_value integer;
  score_value integer;
  previous_score integer;
  key_value text;
begin
  if nullif(trim(p_version), '') is null then
    raise exception 'A ruleset version is required' using errcode = '22023';
  end if;
  if p_points_by_position is null or jsonb_typeof(p_points_by_position) <> 'object' then
    raise exception 'Points schedule must be a JSON object' using errcode = '22023';
  end if;

  select seasons.* into season_row
  from public.n26_seasons seasons
  where seasons.id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.status <> 'draft' then
    raise exception 'Points schedule can only be approved for a draft season' using errcode = '42501';
  end if;

  select rulesets.* into current_ruleset
  from public.n26_rulesets rulesets
  where rulesets.id = season_row.ruleset_id
  for update;
  driver_limit := current_ruleset.driver_count;

  select count(*) into key_count from jsonb_object_keys(p_points_by_position);
  if key_count <> driver_limit then
    raise exception 'Points schedule must define exactly positions 1 through %', driver_limit using errcode = '23514';
  end if;

  for key_value in select jsonb_object_keys(p_points_by_position) loop
    begin
      position_value := key_value::integer;
    exception when invalid_text_representation then
      raise exception 'Points schedule keys must be finishing positions' using errcode = '22P02';
    end;
    if position_value < 1 or position_value > driver_limit then
      raise exception 'Points schedule contains invalid position %', position_value using errcode = '23514';
    end if;
    if (p_points_by_position ->> key_value) !~ '^[0-9]+$' then
      raise exception 'Points for position % must be a non-negative integer', position_value using errcode = '22P02';
    end if;
  end loop;

  previous_score := null;
  for position_value in 1..driver_limit loop
    key_value := position_value::text;
    if not (p_points_by_position ? key_value) then
      raise exception 'Points schedule is missing position %', position_value using errcode = '23514';
    end if;
    score_value := (p_points_by_position ->> key_value)::integer;
    if position_value <= 12
       and score_value <> (current_ruleset.points_by_position ->> key_value)::integer then
      raise exception 'Positions 1 through 12 must retain the published launch schedule' using errcode = '23514';
    end if;
    if previous_score is not null and score_value > previous_score then
      raise exception 'Points must be non-increasing by finishing position' using errcode = '23514';
    end if;
    previous_score := score_value;
  end loop;

  insert into public.n26_rulesets (
    version,
    name,
    season_length,
    team_size,
    driver_count,
    points_by_position,
    rating_weights,
    config
  )
  values (
    trim(p_version),
    current_ruleset.name || ' - Approved',
    current_ruleset.season_length,
    current_ruleset.team_size,
    current_ruleset.driver_count,
    p_points_by_position,
    current_ruleset.rating_weights,
    (current_ruleset.config - 'points_schedule_status' - 'points_schedule_version')
      || jsonb_build_object('points_schedule_status', 'approved', 'points_schedule_version', trim(p_version))
  )
  returning * into approved_ruleset;

  update public.n26_seasons
  set ruleset_id = approved_ruleset.id
  where id = p_season_id;

  return jsonb_build_object(
    'season_id', p_season_id,
    'ruleset_id', approved_ruleset.id,
    'version', approved_ruleset.version,
    'points_by_position', approved_ruleset.points_by_position
  );
end;
$$;

revoke execute on function public.n26_approve_points_schedule(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.n26_approve_points_schedule(uuid, text, jsonb) to service_role;
