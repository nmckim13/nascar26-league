-- Permit only the dedicated replacement workflow to alter a locked roster.
-- The setting is transaction-local and can only be enabled by the
-- service-only replacement function below.
create or replace function public.n26_reject_locked_roster_change()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  season_id_value uuid;
  season_row public.n26_seasons;
begin
  season_id_value := case when tg_op = 'DELETE' then old.season_id else new.season_id end;
  select * into season_row from public.n26_seasons where id = season_id_value for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if current_setting('n26.allow_midseason_replacement', true) = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if season_row.status not in ('draft', 'open')
     or (season_row.status = 'open' and season_row.roster_lock_at is not null) then
    raise exception 'Roster changes are blocked after the season roster lock' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.n26_replace_driver_midseason(
  p_season_id uuid,
  p_departing_driver_id uuid,
  p_replacement_driver_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  departing_assignment public.n26_seat_assignments;
  replacement_assignment public.n26_seat_assignments;
  replacement_entry public.n26_season_entries;
  replacement_status text;
begin
  if p_departing_driver_id = p_replacement_driver_id then
    raise exception 'The departing and replacement drivers must be different' using errcode = '22023';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'A documented withdrawal or replacement reason is required' using errcode = '22023';
  end if;

  select * into season_row
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.status not in ('open', 'in_progress', 'appeal_window')
     or season_row.roster_lock_at is null then
    raise exception 'Midseason replacement requires a published locked season' using errcode = '42501';
  end if;

  select * into departing_assignment
  from public.n26_seat_assignments
  where season_id = p_season_id
    and driver_id = p_departing_driver_id
    and assignment_status = 'active'
  for update;
  if departing_assignment.id is null then
    raise exception 'The departing driver has no active seat in this season' using errcode = '23514';
  end if;

  select status into replacement_status
  from public.n26_drivers
  where id = p_replacement_driver_id
  for update;
  if replacement_status is null or replacement_status not in ('active', 'reserve') then
    raise exception 'The replacement driver must be an active or reserve identity' using errcode = '23503';
  end if;
  if exists (
    select 1 from public.n26_seat_assignments
    where season_id = p_season_id
      and driver_id = p_replacement_driver_id
      and assignment_status = 'active'
  ) then
    raise exception 'The replacement driver already occupies an active seat in this season' using errcode = '23505';
  end if;

  perform set_config('n26.allow_midseason_replacement', 'on', true);
  select * into replacement_entry
  from public.n26_season_entries
  where season_id = p_season_id and driver_id = p_replacement_driver_id
  for update;
  if replacement_entry.id is null then
    insert into public.n26_season_entries (season_id, driver_id, entry_status)
    values (p_season_id, p_replacement_driver_id, 'reserve')
    returning * into replacement_entry;
  elsif replacement_entry.entry_status = 'inactive' then
    update public.n26_season_entries
    set entry_status = 'reserve'
    where id = replacement_entry.id
    returning * into replacement_entry;
  elsif replacement_entry.entry_status = 'full_time' then
    raise exception 'A full-time entrant cannot be used as a reserve replacement' using errcode = '23514';
  end if;

  update public.n26_seat_assignments
  set assignment_status = 'ended', ends_at = now()
  where id = departing_assignment.id;

  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  ) values (
    p_season_id, p_replacement_driver_id, departing_assignment.team_id,
    departing_assignment.car_number, now(), 'active'
  ) returning * into replacement_assignment;

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, from_car_number,
    transaction_type, notes
  ) values (
    p_season_id, p_departing_driver_id, departing_assignment.team_id,
    departing_assignment.car_number, 'withdrawal', trim(p_reason)
  );
  insert into public.n26_transactions (
    season_id, driver_id, to_team_id, to_car_number,
    transaction_type, notes
  ) values (
    p_season_id, p_replacement_driver_id, replacement_assignment.team_id,
    replacement_assignment.car_number, 'signing',
    format('Midseason replacement for driver %s: %s', p_departing_driver_id, trim(p_reason))
  );

  return jsonb_build_object(
    'season_id', p_season_id,
    'departing_driver_id', p_departing_driver_id,
    'replacement_driver_id', p_replacement_driver_id,
    'team_id', replacement_assignment.team_id,
    'car_number', replacement_assignment.car_number,
    'reason', trim(p_reason)
  );
end;
$$;

revoke execute on function public.n26_replace_driver_midseason(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.n26_replace_driver_midseason(uuid, uuid, uuid, text) to service_role;
