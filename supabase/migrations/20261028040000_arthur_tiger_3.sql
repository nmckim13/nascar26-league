-- One-time orange/black tiger #3 correction, not a team transfer.
-- Keep both historical seat identities and every #9 result/point unchanged.
do $$
declare
  driver_id_value constant uuid := 'e4e29f51-00a4-4bf9-a1f0-3214823aac12';
  season_id_value constant uuid := '64004825-0c83-407e-8631-b0c0ca418ff9';
  team_id_value constant uuid := '2ed48a26-acaa-4ea2-b169-a5b64bb8ec10';
  old_assignment_id constant uuid := 'a6f9dbb2-6c6e-47c8-8857-0571e97fab55';
  earlier_assignment_id constant uuid := '41664392-4b0a-45e6-b0a6-386f8ebe7613';
  old_catalog_id constant uuid := '8b64ac03-2076-44ee-b04f-18218661cb5c';
  old_starts_at constant timestamptz := '2026-09-10T21:29:20.952778Z';
  audit_note constant text := '20261028040000: Arthur Walstra switches from #9 to orange/black tiger #3; Hendrick Motorsports, historical #5/#9 seats and #9 results preserved.';
  driver_row public.n26_drivers;
  season_row public.n26_seasons;
  old_assignment public.n26_seat_assignments;
  earlier_assignment public.n26_seat_assignments;
  new_assignment public.n26_seat_assignments;
  audit_row public.n26_transactions;
  prior_bypass text;
  correction_at timestamptz := clock_timestamp();
begin
  -- Fresh databases have different identities; never invent this driver.
  if not exists (select 1 from public.n26_drivers where id = driver_id_value) then
    return;
  end if;

  -- Serialize all checked state, including inserts into an empty #3 slot.
  lock table public.n26_seasons, public.n26_drivers, public.n26_teams,
    public.n26_team_car_numbers, public.n26_seat_assignments,
    public.n26_contracts, public.n26_claims, public.n26_transactions,
    public.n26_race_results, public.n26_season_races, public.n26_season_entries
    in share row exclusive mode;

  select * into strict driver_row from public.n26_drivers where id = driver_id_value;
  select * into strict season_row from public.n26_seasons where id = season_id_value;
  select * into strict old_assignment from public.n26_seat_assignments where id = old_assignment_id;
  select * into strict earlier_assignment from public.n26_seat_assignments where id = earlier_assignment_id;
  if driver_row.display_name <> 'Arthur Walstra' or driver_row.status <> 'active'
     or season_row.season_number <> 1 or season_row.status <> 'in_progress'
     or season_row.roster_lock_at is not null
     or old_assignment.season_id <> season_id_value
     or old_assignment.driver_id <> driver_id_value
     or old_assignment.team_id <> team_id_value or old_assignment.car_number <> '9'
     or old_assignment.starts_at <> old_starts_at
     or earlier_assignment.season_id <> season_id_value
     or earlier_assignment.driver_id <> driver_id_value
     or earlier_assignment.team_id <> team_id_value or earlier_assignment.car_number <> '5'
     or earlier_assignment.assignment_status <> 'transferred'
     or earlier_assignment.ends_at is distinct from old_starts_at
     or earlier_assignment.starts_at >= old_starts_at
     or not exists (
       select 1 from public.n26_teams
       where id = team_id_value and slug = 'hendrick' and name = 'Hendrick Motorsports'
         and status = 'active' and seat_limit = 3
     ) or not exists (
       select 1 from public.n26_season_entries
       where season_id = season_id_value and driver_id = driver_id_value
         and entry_status in ('full_time', 'reserve')
     ) then
    raise exception 'Arthur #3 correction: unexpected identity, team, season or historical roster';
  end if;
  if not exists (
    select 1 from public.n26_team_car_numbers
    where id = old_catalog_id and team_id = team_id_value and car_number = '9'
  ) or exists (
    select 1 from public.n26_team_car_numbers
    where car_number = '3' and (team_id <> team_id_value or not is_available)
  ) then
    raise exception 'Arthur #3 correction: unexpected number catalog';
  end if;

  -- Stop on account/financial drift rather than moving or editing dependencies.
  if driver_row.legacy_claim_id is not null
     or exists (select 1 from public.n26_claims where car_number in ('9', '3'))
     or exists (
       select 1 from public.n26_contracts contracts
       where contracts.driver_id = driver_id_value or contracts.seat_assignment_id in (
         select id from public.n26_seat_assignments where driver_id = driver_id_value
       )
     ) then
    raise exception 'Arthur #3 correction: unexpected claim or contract dependency';
  end if;
  if (select count(*) from public.n26_race_results
      where driver_id = driver_id_value or seat_assignment_id = old_assignment_id) <> 5
     or (select sum(points_earned) from public.n26_race_results
         where seat_assignment_id = old_assignment_id) is distinct from 54::bigint
     or exists (
       select 1 from public.n26_race_results results
       join public.n26_season_races races on races.id = results.race_id
       where (results.driver_id = driver_id_value or results.seat_assignment_id = old_assignment_id)
         and (results.seat_assignment_id is distinct from old_assignment_id
              or results.driver_id <> driver_id_value or results.team_id <> team_id_value
              or results.car_number <> '9' or races.season_id <> season_id_value)
     ) then
    raise exception 'Arthur #3 correction: historical #9 results have drifted';
  end if;

  select * into new_assignment from public.n26_seat_assignments
  where season_id = season_id_value and driver_id = driver_id_value
    and assignment_status = 'active';
  if (select count(*) from public.n26_transactions where notes = audit_note) > 1 then
    raise exception 'Arthur #3 correction: duplicate correction audit';
  end if;
  select * into audit_row from public.n26_transactions where notes = audit_note;
  if audit_row.id is not null then
    if audit_row.season_id <> season_id_value or audit_row.driver_id <> driver_id_value
       or audit_row.transaction_type <> 'correction' or audit_row.contract_id is not null
       or audit_row.from_team_id is distinct from team_id_value
       or audit_row.to_team_id is distinct from team_id_value
       or audit_row.from_car_number is distinct from '9'
       or audit_row.to_car_number is distinct from '3'
       or old_assignment.assignment_status <> 'ended' or old_assignment.ends_at is null
       or new_assignment.id is null or new_assignment.car_number <> '3'
       or new_assignment.team_id <> team_id_value or new_assignment.ends_at is not null
       or new_assignment.starts_at <> old_assignment.ends_at
       or old_assignment.starts_at >= old_assignment.ends_at
       or audit_row.effective_at <> new_assignment.starts_at
       or (select count(*) from public.n26_seat_assignments
           where season_id = season_id_value and driver_id = driver_id_value) <> 3
       or not exists (
         select 1 from public.n26_team_car_numbers
         where team_id = team_id_value and car_number = '3' and is_available
       ) or exists (
         select 1 from public.n26_team_car_numbers numbers
         where numbers.id = old_catalog_id and numbers.is_available is distinct from exists (
           select 1 from public.n26_seat_assignments
           where car_number = '9' and assignment_status = 'active'
         )
       ) then
      raise exception 'Arthur #3 correction: audited state has drifted';
    end if;
    return;
  end if;

  if old_assignment.assignment_status <> 'active' or old_assignment.ends_at is not null
     or new_assignment.id is distinct from old_assignment_id
     or old_assignment.starts_at >= correction_at
     or (select count(*) from public.n26_seat_assignments
         where season_id = season_id_value and driver_id = driver_id_value) <> 2
     or exists (select 1 from public.n26_team_car_numbers where car_number = '3')
     or not exists (select 1 from public.n26_team_car_numbers where id = old_catalog_id and is_available)
     or exists (
       select 1 from public.n26_seat_assignments
       where season_id = season_id_value and car_number = '3' and assignment_status = 'active'
     ) then
    raise exception 'Arthur #3 correction: expected original in-progress #9 roster state';
  end if;

  insert into public.n26_team_car_numbers (team_id, car_number, is_available)
  values (team_id_value, '3', true);

  prior_bypass := current_setting('n26.allow_midseason_replacement', true);
  perform set_config('n26.allow_midseason_replacement', 'on', true);
  update public.n26_seat_assignments
  set assignment_status = 'ended', ends_at = correction_at
  where id = old_assignment_id;
  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  ) values (
    season_id_value, driver_id_value, team_id_value, '3', correction_at, 'active'
  );
  perform set_config('n26.allow_midseason_replacement', coalesce(prior_bypass, ''), true);

  -- Retain the historical catalog row; retire only if unused across ALL seasons.
  update public.n26_team_car_numbers set is_available = false
  where id = old_catalog_id
    and not exists (
      select 1 from public.n26_seat_assignments
      where car_number = '9' and assignment_status = 'active'
    )
    and not exists (select 1 from public.n26_claims where car_number = '9');

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id, from_car_number,
    to_car_number, transaction_type, effective_at, notes
  ) values (
    season_id_value, driver_id_value, team_id_value, team_id_value, '9',
    '3', 'correction', correction_at, audit_note
  );
end;
$$;
