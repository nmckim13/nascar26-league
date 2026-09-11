-- A documented midseason withdrawal also ends the departing driver's current
-- contract. This prevents an empty seat from carrying salary into the next
-- season while preserving the contract release and withdrawal audit rows.

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
  contract_row public.n26_contracts;
  replacement_status text;
  released_contract_count integer := 0;
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
  if exists (
    select 1
    from public.n26_contracts contracts
    where contracts.driver_id = p_replacement_driver_id
      and contracts.start_season <= season_row.season_number
      and contracts.end_season >= season_row.season_number
      and contracts.status in ('introductory', 'active')
  ) then
    raise exception 'The replacement driver already has a current contract' using errcode = '23505';
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

  for contract_row in
    select *
    from public.n26_contracts
    where driver_id = p_departing_driver_id
      and start_season <= season_row.season_number
      and end_season >= season_row.season_number
      and status in ('introductory', 'active')
    for update
  loop
    update public.n26_contracts
    set status = 'released', released_at = now(), release_reason = trim(p_reason)
    where id = contract_row.id;
    insert into public.n26_transactions (
      season_id, driver_id, from_team_id, transaction_type, contract_id, notes
    ) values (
      p_season_id, p_departing_driver_id, contract_row.team_id, 'release', contract_row.id,
      format('Midseason withdrawal: %s', trim(p_reason))
    );
    released_contract_count := released_contract_count + 1;
  end loop;

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
    'reason', trim(p_reason),
    'released_contracts', released_contract_count
  );
end;
$$;

revoke execute on function public.n26_replace_driver_midseason(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.n26_replace_driver_midseason(uuid, uuid, uuid, text) to service_role;
