-- Import a batch of new permanent identities and their initial seats without
-- leaving a partially populated roster if any row fails validation.

create or replace function public.n26_import_roster(
  p_season_id uuid,
  p_roster jsonb
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_status text;
  driver_limit integer;
  existing_full_time integer;
  requested_full_time integer;
  item jsonb;
  driver_row public.n26_drivers;
  team_id_value uuid;
  display_name_value text;
  gamertag_value text;
  first_name_value text;
  last_name_value text;
  driver_status text;
  entry_status_value text;
  car_number_value text;
  created_count integer := 0;
  assigned_count integer := 0;
  seen_cars text[] := '{}'::text[];
begin
  if p_roster is null or jsonb_typeof(p_roster) <> 'array' or jsonb_array_length(p_roster) = 0 then
    raise exception 'Roster import must be a non-empty JSON array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_roster) > 24 then
    raise exception 'Roster import cannot contain more than 24 rows' using errcode = '22023';
  end if;

  select seasons.status, rulesets.driver_count
  into season_status, driver_limit
  from public.n26_seasons seasons
  join public.n26_rulesets rulesets on rulesets.id = seasons.ruleset_id
  where seasons.id = p_season_id
  for update;
  if season_status is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_status <> 'draft' then
    raise exception 'Bulk roster import is only allowed for a draft season' using errcode = '42501';
  end if;

  select count(*) into existing_full_time
  from public.n26_season_entries
  where season_id = p_season_id and entry_status = 'full_time';
  select count(*) into requested_full_time
  from jsonb_array_elements(p_roster) row_data
  where coalesce(nullif(trim(row_data->>'entry_status'), ''), 'full_time') = 'full_time';
  if existing_full_time + requested_full_time > driver_limit then
    raise exception 'Roster import would exceed the % full-time driver limit', driver_limit using errcode = '23514';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_roster) row_data
    where row_data ? 'driver_id'
  ) then
    raise exception 'Bulk roster import accepts new identities only; use Seat Desk for existing drivers' using errcode = '22023';
  end if;

  for item in select element from jsonb_array_elements(p_roster) as elements(element) loop
    display_name_value := nullif(trim(item->>'display_name'), '');
    gamertag_value := nullif(trim(item->>'gamertag'), '');
    first_name_value := nullif(trim(item->>'first_name'), '');
    last_name_value := nullif(trim(item->>'last_name'), '');
    driver_status := coalesce(nullif(trim(item->>'status'), ''), 'active');
    entry_status_value := coalesce(nullif(trim(item->>'entry_status'), ''), 'full_time');
    car_number_value := nullif(trim(item->>'car_number'), '');

    if display_name_value is null then
      raise exception 'Every imported driver needs a display_name' using errcode = '22023';
    end if;
    if driver_status not in ('active', 'reserve') then
      raise exception 'Driver status must be active or reserve' using errcode = '23514';
    end if;
    if entry_status_value not in ('full_time', 'reserve') then
      raise exception 'Entry status must be full_time or reserve' using errcode = '23514';
    end if;
    if (entry_status_value = 'full_time' and driver_status <> 'active')
       or (entry_status_value = 'reserve' and driver_status <> 'reserve') then
      raise exception 'Active drivers must be full-time and reserve drivers must be reserve entries' using errcode = '23514';
    end if;

    select * into driver_row
    from public.n26_create_driver(
      display_name_value,
      gamertag_value,
      first_name_value,
      last_name_value,
      driver_status,
      p_season_id,
      entry_status_value
    );
    created_count := created_count + 1;

    if entry_status_value = 'full_time' then
      if car_number_value is null then
        raise exception 'Every full-time imported driver needs a car_number' using errcode = '22023';
      end if;
      if car_number_value = any(seen_cars) then
        raise exception 'Car number % appears more than once in the import', car_number_value using errcode = '23505';
      end if;
      seen_cars := array_append(seen_cars, car_number_value);

      team_id_value := null;
      if nullif(trim(item->>'team_id'), '') is not null then
        begin
          team_id_value := (item->>'team_id')::uuid;
        exception when invalid_text_representation then
          raise exception 'team_id must be a UUID; use team_slug for a readable import' using errcode = '22P02';
        end;
      elsif nullif(trim(item->>'team_slug'), '') is not null then
        select id into team_id_value
        from public.n26_teams
        where slug = lower(trim(item->>'team_slug')) and status = 'active';
      end if;
      if team_id_value is null then
        raise exception 'Every full-time imported driver needs an active team_slug or team_id' using errcode = '23503';
      end if;

      perform public.n26_assign_driver_to_seat(
        p_season_id,
        driver_row.id,
        team_id_value,
        car_number_value,
        false
      );
      assigned_count := assigned_count + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'season_id', p_season_id,
    'created_drivers', created_count,
    'assigned_seats', assigned_count
  );
end;
$$;

revoke execute on function public.n26_import_roster(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.n26_import_roster(uuid, jsonb) to service_role;
