-- Promote first-party claims into the normalized draft only after a
-- commissioner explicitly runs the sync. The legacy claims table remains the
-- public intake surface and is never overwritten.
create or replace function public.n26_sync_claims_to_draft(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  claim_row record;
  driver_row public.n26_drivers;
  team_id_value uuid;
  display_name_value text;
  created_count integer := 0;
  assigned_count integer := 0;
begin
  select * into season_row
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.status <> 'draft' then
    raise exception 'Claims can only be synced into a draft season' using errcode = '42501';
  end if;

  for claim_row in
    select claims.*
    from public.n26_claims claims
    order by claims.claimed_at, claims.id
  loop
    select numbers.team_id into team_id_value
    from public.n26_team_car_numbers numbers
    where numbers.car_number = claim_row.car_number
      and numbers.is_available = true;
    if team_id_value is null then
      raise exception 'Claimed car number % is not in the active league catalog', claim_row.car_number using errcode = '23514';
    end if;

    select * into driver_row
    from public.n26_drivers
    where legacy_claim_id = claim_row.id
    for update;

    if driver_row.id is null then
      display_name_value := coalesce(
        nullif(trim(concat_ws(' ', claim_row.first_name, claim_row.last_name)), ''),
        nullif(trim(claim_row.gamertag), '')
      );
      if display_name_value is null then
        raise exception 'Claim % is missing a usable driver name', claim_row.id using errcode = '22023';
      end if;
      insert into public.n26_drivers (
        display_name, gamertag, first_name, last_name, legacy_claim_id, status
      ) values (
        display_name_value,
        nullif(trim(claim_row.gamertag), ''),
        nullif(trim(claim_row.first_name), ''),
        nullif(trim(claim_row.last_name), ''),
        claim_row.id,
        'active'
      ) returning * into driver_row;
      created_count := created_count + 1;
    end if;

    if not exists (
      select 1 from public.n26_seat_assignments assignments
      where assignments.season_id = p_season_id
        and assignments.driver_id = driver_row.id
        and assignments.assignment_status = 'active'
    ) then
      perform public.n26_assign_driver_to_seat(
        p_season_id, driver_row.id, team_id_value, claim_row.car_number, false
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

revoke execute on function public.n26_sync_claims_to_draft(uuid) from public, anon, authenticated;
grant execute on function public.n26_sync_claims_to_draft(uuid) to service_role;
