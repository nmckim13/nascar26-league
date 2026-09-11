-- DNS drivers may have no qualifying classification. They receive no
-- qualifying credit, while starters still require a complete valid session.

create or replace function public.n26_upsert_race_results(
  p_race_id uuid,
  p_results jsonb,
  p_source_version text default 'manual-v1',
  p_corrected_by uuid default null
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  season_status text;
  ruleset_points jsonb;
  item jsonb;
  driver_id_value uuid;
  team_id_value uuid;
  car_number_value text;
  seat_assignment_id_value uuid;
  requested_seat_assignment_id uuid;
  start_status_value text;
  finish_status_value text;
  finish_position_value integer;
  qualifying_position_value integer;
  qualifying_valid_value boolean;
  pole_value boolean;
  points_value integer;
  existing_row public.n26_race_results;
  inserted_count integer := 0;
begin
  if jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) = 0 then
    raise exception 'Results must be a non-empty JSON array' using errcode = '22023';
  end if;

  select * into race_row from public.n26_season_races where id = p_race_id for update;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.status in ('voided', 'completed') then
    raise exception 'Cannot edit a voided or completed race' using errcode = '42501';
  end if;

  select seasons.status, rulesets.points_by_position
  into season_status, ruleset_points
  from public.n26_seasons seasons
  join public.n26_rulesets rulesets on rulesets.id = seasons.ruleset_id
  where seasons.id = race_row.season_id;
  if season_status not in ('open', 'in_progress') then
    raise exception 'Results can only be entered for an open or in-progress season' using errcode = '42501';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_results) values
    group by nullif(values->>'finish_position', '')::integer
    having nullif(values->>'finish_position', '') is not null and count(*) > 1
  ) then
    raise exception 'Started drivers cannot share a finishing position' using errcode = '23514';
  end if;

  for item in select value from jsonb_array_elements(p_results)
  loop
    begin
      driver_id_value := (item->>'driver_id')::uuid;
      requested_seat_assignment_id := nullif(item->>'seat_assignment_id', '')::uuid;
    exception when invalid_text_representation then
      raise exception 'Each result needs valid driver_id and seat_assignment_id values' using errcode = '22P02';
    end;
    team_id_value := (item->>'team_id')::uuid;
    car_number_value := item->>'car_number';
    start_status_value := coalesce(item->>'start_status', 'started');
    finish_status_value := coalesce(item->>'finish_status', 'classified');
    finish_position_value := nullif(item->>'finish_position', '')::integer;
    qualifying_position_value := nullif(item->>'qualifying_position', '')::integer;
    qualifying_valid_value := coalesce((item->>'qualifying_valid')::boolean, false);
    pole_value := coalesce((item->>'pole')::boolean, false);

    if start_status_value not in ('started', 'dns') then
      raise exception 'Invalid start status for %', driver_id_value using errcode = '23514';
    end if;
    if finish_status_value not in ('classified', 'dnf') then
      raise exception 'Invalid finish status for %', driver_id_value using errcode = '23514';
    end if;
    if not exists (
      select 1 from public.n26_season_entries entries
      where entries.season_id = race_row.season_id
        and entries.driver_id = driver_id_value
        and entries.entry_status in ('full_time', 'reserve')
    ) then
      raise exception 'Driver % is not entered in this season', driver_id_value using errcode = '23503';
    end if;
    if team_id_value is null or car_number_value is null or not exists (
      select 1 from public.n26_team_car_numbers numbers
      where numbers.team_id = team_id_value and numbers.car_number = car_number_value
    ) then
      raise exception 'Result seat is not in the team car catalog for %', driver_id_value using errcode = '23514';
    end if;

    if requested_seat_assignment_id is not null then
      select assignments.id into seat_assignment_id_value
      from public.n26_seat_assignments assignments
      where assignments.id = requested_seat_assignment_id
        and assignments.season_id = race_row.season_id
        and assignments.driver_id = driver_id_value
        and assignments.team_id = team_id_value
        and assignments.car_number = car_number_value;
    else
      select assignments.id into seat_assignment_id_value
      from public.n26_seat_assignments assignments
      where assignments.season_id = race_row.season_id
        and assignments.driver_id = driver_id_value
        and assignments.team_id = team_id_value
        and assignments.car_number = car_number_value
      order by assignments.starts_at desc
      limit 1;
    end if;
    if seat_assignment_id_value is null then
      raise exception 'Result must reference a matching historical seat assignment for %', driver_id_value using errcode = '23514';
    end if;

    if start_status_value = 'dns' then
      if finish_position_value is not null or finish_status_value <> 'classified' then
        raise exception 'DNS results cannot have a finish position or DNF status' using errcode = '23514';
      end if;
      points_value := 0;
    else
      if finish_position_value is null or finish_position_value < 1 then
        raise exception 'Started results need a positive finish position' using errcode = '23514';
      end if;
      if race_row.starters_count is not null and finish_position_value > race_row.starters_count then
        raise exception 'Finish position exceeds the race starter count' using errcode = '23514';
      end if;
      if ruleset_points ? finish_position_value::text = false then
        raise exception 'No points value is defined for finishing position %', finish_position_value using errcode = '23514';
      end if;
      points_value := (ruleset_points->>finish_position_value::text)::integer;
    end if;

    if race_row.qualifying_status = 'valid' and start_status_value <> 'dns' then
      if not qualifying_valid_value or qualifying_position_value is null then
        raise exception 'Valid qualifying is required for every starter result' using errcode = '23514';
      end if;
      if race_row.qualifying_field_count is not null
         and qualifying_position_value > race_row.qualifying_field_count then
        raise exception 'Qualifying position exceeds the qualifying field' using errcode = '23514';
      end if;
    elsif race_row.qualifying_status <> 'valid' and qualifying_valid_value then
      raise exception 'Qualifying cannot be marked valid when the race qualifying session is not valid' using errcode = '23514';
    end if;
    if pole_value and (not qualifying_valid_value or qualifying_position_value <> 1) then
      raise exception 'Pole requires valid qualifying in position 1' using errcode = '23514';
    end if;

    select * into existing_row
    from public.n26_race_results
    where race_id = race_row.id and driver_id = driver_id_value
    for update;

    if existing_row.id is not null then
      insert into public.n26_result_corrections (
        race_id, driver_id, result_id, previous_result, corrected_result, reason, corrected_by
      ) values (
        race_row.id,
        driver_id_value,
        existing_row.id,
        to_jsonb(existing_row),
        item || jsonb_build_object('points_earned', points_value, 'seat_assignment_id', seat_assignment_id_value),
        coalesce(item->>'correction_reason', 'Commissioner result correction'),
        p_corrected_by
      );
    end if;

    insert into public.n26_race_results (
      race_id, driver_id, seat_assignment_id, team_id, car_number,
      start_status, finish_status, finish_position, qualifying_position,
      qualifying_valid, pole, points_earned, source_version, certification_status
    ) values (
      race_row.id, driver_id_value, seat_assignment_id_value, team_id_value,
      car_number_value, start_status_value, finish_status_value, finish_position_value,
      qualifying_position_value, qualifying_valid_value, pole_value, points_value,
      p_source_version, 'draft'
    )
    on conflict (race_id, driver_id) do update set
      seat_assignment_id = excluded.seat_assignment_id,
      team_id = excluded.team_id,
      car_number = excluded.car_number,
      start_status = excluded.start_status,
      finish_status = excluded.finish_status,
      finish_position = excluded.finish_position,
      qualifying_position = excluded.qualifying_position,
      qualifying_valid = excluded.qualifying_valid,
      pole = excluded.pole,
      points_earned = excluded.points_earned,
      source_version = excluded.source_version,
      certification_status = 'draft';
    inserted_count := inserted_count + 1;
  end loop;
  return inserted_count;
end;
$$;

create or replace function public.n26_certify_race(p_race_id uuid)
returns public.n26_season_races
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  required_count integer;
  result_count integer;
begin
  select * into race_row from public.n26_season_races where id = p_race_id for update;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.status = 'voided' then
    raise exception 'A voided race cannot be certified' using errcode = '42501';
  end if;
  if race_row.starters_count is null or race_row.starters_count < 1 then
    raise exception 'Starter count is required before certification' using errcode = '23514';
  end if;
  if race_row.race_type <> 'exhibition' and race_row.starters_count < 2 then
    raise exception 'A championship race needs at least two starters' using errcode = '23514';
  end if;
  if race_row.qualifying_status not in ('valid', 'canceled', 'voided') then
    raise exception 'Qualifying must be valid, canceled, or voided before certification' using errcode = '23514';
  end if;
  if race_row.qualifying_status = 'valid'
     and (race_row.qualifying_field_count is null or race_row.qualifying_field_count < 2) then
    raise exception 'A valid qualifying session needs at least two classified qualifiers' using errcode = '23514';
  end if;
  if race_row.qualifying_status = 'valid' and exists (
    select 1 from public.n26_season_entries entries
    where entries.season_id = race_row.season_id and entries.entry_status = 'full_time'
      and not exists (
        select 1 from public.n26_race_results results
        where results.race_id = race_row.id and results.driver_id = entries.driver_id
          and results.start_status <> 'dns'
          and results.qualifying_valid = true and results.qualifying_position is not null
      )
  ) then
    raise exception 'Valid qualifying data is missing for one or more starters' using errcode = '23514';
  end if;

  select count(*) into required_count
  from public.n26_season_entries entries
  where entries.season_id = race_row.season_id and entries.entry_status = 'full_time';
  select count(*) into result_count
  from public.n26_race_results results
  where results.race_id = race_row.id
    and exists (
      select 1 from public.n26_season_entries entries
      where entries.season_id = race_row.season_id
        and entries.driver_id = results.driver_id
        and entries.entry_status = 'full_time'
    );
  if result_count <> required_count then
    raise exception 'Every full-time driver needs a result row before certification' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.n26_race_results results
    where results.race_id = race_row.id and results.certification_status = 'superseded'
  ) then
    raise exception 'Superseded results must be corrected before certification' using errcode = '23514';
  end if;

  update public.n26_race_results set certification_status = 'certified' where race_id = race_row.id;
  update public.n26_season_races
  set status = 'completed', certification_status = 'certified'
  where id = race_row.id
  returning * into race_row;
  return race_row;
end;
$$;

revoke execute on function public.n26_upsert_race_results(uuid, jsonb, text, uuid) from public, anon, authenticated;
revoke execute on function public.n26_certify_race(uuid) from public, anon, authenticated;
grant execute on function public.n26_upsert_race_results(uuid, jsonb, text, uuid) to service_role;
grant execute on function public.n26_certify_race(uuid) to service_role;
