-- Enforce the roster rules at the database boundary as well as in the UI.

create unique index if not exists n26_active_driver_per_season_unique
  on public.n26_seat_assignments (season_id, driver_id)
  where assignment_status = 'active';

create unique index if not exists n26_active_car_per_season_unique
  on public.n26_seat_assignments (season_id, car_number)
  where assignment_status = 'active';

create or replace function public.n26_validate_active_assignment()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  team_limit integer;
  team_car_exists boolean;
  active_team_count integer;
  entry_exists boolean;
begin
  if new.assignment_status <> 'active' then
    return new;
  end if;

  select exists (
    select 1
    from public.n26_team_car_numbers numbers
    where numbers.team_id = new.team_id
      and numbers.car_number = new.car_number
      and numbers.is_available = true
  ) into team_car_exists;

  if not team_car_exists then
    raise exception 'Car number % is not available for the selected team', new.car_number
      using errcode = '23514';
  end if;

  select teams.seat_limit
  into team_limit
  from public.n26_teams teams
  where teams.id = new.team_id
    and teams.status = 'active';

  if team_limit is null then
    raise exception 'Selected team is not active' using errcode = '23514';
  end if;

  select exists (
    select 1
    from public.n26_season_entries entries
    where entries.season_id = new.season_id
      and entries.driver_id = new.driver_id
      and entries.entry_status in ('full_time', 'reserve')
  ) into entry_exists;

  if not entry_exists then
    raise exception 'Driver must be entered in the season before receiving a seat'
      using errcode = '23514';
  end if;

  select count(*)
  into active_team_count
  from public.n26_seat_assignments assignments
  where assignments.season_id = new.season_id
    and assignments.team_id = new.team_id
    and assignments.assignment_status = 'active'
    and assignments.id <> coalesce(new.id, '00000000-0000-0000-0000-000000000000'::uuid);

  if active_team_count >= team_limit then
    raise exception 'Team already has its maximum of % active drivers', team_limit
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists n26_validate_active_assignment_trigger
  on public.n26_seat_assignments;

create constraint trigger n26_validate_active_assignment_trigger
after insert or update on public.n26_seat_assignments
deferrable initially deferred
for each row execute function public.n26_validate_active_assignment();

revoke execute on function public.n26_validate_active_assignment() from public, anon, authenticated;
