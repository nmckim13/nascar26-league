-- Keep release operations consistent with assignment operations.

create or replace function public.n26_release_driver_from_seat(
  p_season_id uuid,
  p_driver_id uuid,
  p_notes text default null
)
returns public.n26_seat_assignments
language plpgsql
set search_path = public
as $$
declare
  released_assignment public.n26_seat_assignments;
  season_status text;
begin
  select status into season_status
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_status is null or season_status not in ('draft', 'open') then
    raise exception 'Roster changes are only allowed for draft or open seasons' using errcode = '42501';
  end if;

  update public.n26_seat_assignments
  set assignment_status = 'released', ends_at = now()
  where season_id = p_season_id
    and driver_id = p_driver_id
    and assignment_status = 'active'
  returning * into released_assignment;
  if released_assignment.id is null then
    raise exception 'Driver has no active seat in this season' using errcode = '02000';
  end if;

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, from_car_number,
    transaction_type, notes
  ) values (
    p_season_id,
    p_driver_id,
    released_assignment.team_id,
    released_assignment.car_number,
    'release',
    p_notes
  );
  return released_assignment;
end;
$$;

revoke execute on function public.n26_release_driver_from_seat(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.n26_release_driver_from_seat(uuid, uuid, text) to service_role;
