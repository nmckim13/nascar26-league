-- Atomic commissioner operations for adding, transferring, and releasing seats.
-- The API checks the authenticated user with public.is_admin() before calling
-- these functions. The functions are invoker-security and are not public RPCs.

create or replace function public.n26_assign_driver_to_seat(
  p_season_id uuid,
  p_driver_id uuid,
  p_team_id uuid,
  p_car_number text,
  p_allow_transfer boolean default false
)
returns public.n26_seat_assignments
language plpgsql
set search_path = public
as $$
declare
  current_assignment public.n26_seat_assignments;
  inserted_assignment public.n26_seat_assignments;
  season_status text;
begin
  select status into season_status
  from public.n26_seasons
  where id = p_season_id
  for update;

  if season_status is null or season_status not in ('draft', 'open') then
    raise exception 'Roster changes are only allowed for draft or open seasons' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.n26_drivers where id = p_driver_id and status in ('active', 'reserve')
  ) then
    raise exception 'Driver does not exist or is not active' using errcode = '23503';
  end if;

  insert into public.n26_season_entries (season_id, driver_id, entry_status)
  values (p_season_id, p_driver_id, 'full_time')
  on conflict (season_id, driver_id) do update set entry_status = 'full_time';

  select * into current_assignment
  from public.n26_seat_assignments
  where season_id = p_season_id
    and driver_id = p_driver_id
    and assignment_status = 'active'
  for update;

  if current_assignment.id is not null then
    if not p_allow_transfer then
      raise exception 'Driver already has an active seat; enable transfer to move them' using errcode = '23505';
    end if;
    update public.n26_seat_assignments
    set assignment_status = 'transferred', ends_at = now()
    where id = current_assignment.id;
  end if;

  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  )
  values (
    p_season_id, p_driver_id, p_team_id, p_car_number, now(), 'active'
  )
  returning * into inserted_assignment;

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id,
    from_car_number, to_car_number, transaction_type, notes
  )
  values (
    p_season_id,
    p_driver_id,
    current_assignment.team_id,
    p_team_id,
    current_assignment.car_number,
    p_car_number,
    case when current_assignment.id is null then 'signing' else 'trade' end,
    case when current_assignment.id is null then 'Initial seat assignment' else 'Seat transfer' end
  );

  return inserted_assignment;
end;
$$;

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
begin
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
  )
  values (
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

revoke execute on function public.n26_assign_driver_to_seat(uuid, uuid, uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.n26_release_driver_from_seat(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.n26_assign_driver_to_seat(uuid, uuid, uuid, text, boolean) to service_role;
grant execute on function public.n26_release_driver_from_seat(uuid, uuid, text) to service_role;
