-- One-time number/livery correction, not a team transfer: RAM is artwork.
-- Preserve Ethan's #60 seat identity and all historical result snapshots.
do $$
declare
  driver_id_value constant uuid := 'e003c6e6-a363-4ef8-838d-00ea04e77b54';
  season_id_value constant uuid := '64004825-0c83-407e-8631-b0c0ca418ff9';
  team_id_value constant uuid := 'c87aef44-d41a-415b-92b1-318947c6de74';
  old_assignment_id constant uuid := '6f0ad0d9-7229-4b44-ae6c-ca415e85409b';
  audit_note constant text := '20261028030000: Ethan Tillema switches from #60 to RAM #14; RFK Racing and historical #60 results preserved.';
  driver_row public.n26_drivers;
  season_row public.n26_seasons;
  old_assignment public.n26_seat_assignments;
  new_assignment public.n26_seat_assignments;
  audit_row public.n26_transactions;
  prior_bypass text;
  correction_at timestamptz := clock_timestamp();
begin
  -- Fresh fixtures have different identities; never invent a production driver.
  if not exists (select 1 from public.n26_drivers where id = driver_id_value) then
    return;
  end if;

  lock table public.n26_seasons, public.n26_drivers, public.n26_teams,
    public.n26_team_car_numbers, public.n26_seat_assignments,
    public.n26_contracts, public.n26_claims, public.n26_transactions,
    public.n26_race_results in share row exclusive mode;

  select * into strict driver_row from public.n26_drivers where id = driver_id_value;
  select * into strict season_row from public.n26_seasons where id = season_id_value;
  select * into strict old_assignment from public.n26_seat_assignments where id = old_assignment_id;
  if driver_row.display_name <> 'Ethan Tillema'
     or season_row.season_number <> 1
     or old_assignment.season_id <> season_id_value
     or old_assignment.driver_id <> driver_id_value
     or old_assignment.team_id <> team_id_value
     or old_assignment.car_number <> '60'
     or not exists (
       select 1 from public.n26_teams
       where id = team_id_value and slug = 'rfk'
         and name = 'RFK Racing' and status = 'active'
     ) then
    raise exception 'Ethan #14 correction: unexpected identity, season, team or historical seat';
  end if;
  if not exists (
    select 1 from public.n26_team_car_numbers
    where team_id = team_id_value and car_number = '60'
  ) or exists (
    select 1 from public.n26_team_car_numbers
    where car_number = '14' and (team_id <> team_id_value or not is_available)
  ) then
    raise exception 'Ethan #14 correction: unexpected number catalog';
  end if;

  -- Production has no financial/account dependencies to move. Stop on drift
  -- rather than renegotiating a contract or rewriting a claim/account link.
  if driver_row.legacy_claim_id is not null
     or exists (select 1 from public.n26_claims where car_number in ('60', '14'))
     or exists (
       select 1 from public.n26_contracts
       where driver_id = driver_id_value or seat_assignment_id = old_assignment_id
     ) then
    raise exception 'Ethan #14 correction: unexpected claim or contract dependency';
  end if;
  if (select count(*) from public.n26_race_results where seat_assignment_id = old_assignment_id) <> 5
     or (select sum(points_earned) from public.n26_race_results where seat_assignment_id = old_assignment_id) is distinct from 124::bigint
     or exists (
       select 1 from public.n26_race_results results
       join public.n26_season_races races on races.id = results.race_id
       where results.seat_assignment_id = old_assignment_id
         and (results.driver_id <> driver_id_value or results.team_id <> team_id_value
              or results.car_number <> '60' or races.season_id <> season_id_value)
     ) then
    raise exception 'Ethan #14 correction: historical #60 results have drifted';
  end if;

  select * into new_assignment from public.n26_seat_assignments
  where season_id = season_id_value and driver_id = driver_id_value
    and assignment_status = 'active';
  if (select count(*) from public.n26_transactions where notes = audit_note) > 1 then
    raise exception 'Ethan #14 correction: duplicate correction audit';
  end if;
  select * into audit_row from public.n26_transactions where notes = audit_note;
  if audit_row.id is not null then
    if audit_row.season_id <> season_id_value or audit_row.driver_id <> driver_id_value
       or audit_row.transaction_type <> 'correction' or audit_row.contract_id is not null
       or audit_row.from_team_id is distinct from team_id_value
       or audit_row.to_team_id is distinct from team_id_value
       or audit_row.from_car_number is distinct from '60'
       or audit_row.to_car_number is distinct from '14'
       or old_assignment.assignment_status <> 'ended' or old_assignment.ends_at is null
       or new_assignment.id is null or new_assignment.car_number <> '14'
       or new_assignment.team_id <> team_id_value or new_assignment.ends_at is not null
       or new_assignment.starts_at <> old_assignment.ends_at
       or old_assignment.starts_at >= old_assignment.ends_at
       or audit_row.effective_at <> new_assignment.starts_at
       or not exists (
         select 1 from public.n26_team_car_numbers
         where team_id = team_id_value and car_number = '14' and is_available
       ) then
      raise exception 'Ethan #14 correction: audited state has drifted';
    end if;
    return;
  end if;

  if season_row.status <> 'in_progress' or season_row.roster_lock_at is not null
     or old_assignment.assignment_status <> 'active' or old_assignment.ends_at is not null
     or new_assignment.id is distinct from old_assignment_id
     or old_assignment.starts_at >= correction_at
     or exists (select 1 from public.n26_team_car_numbers where car_number = '14')
     or exists (
       select 1 from public.n26_seat_assignments
       where season_id = season_id_value and car_number = '14' and assignment_status = 'active'
     ) or exists (
       select 1 from public.n26_race_results results
       join public.n26_season_races races on races.id = results.race_id
       where results.driver_id = driver_id_value and races.season_id = season_id_value
         and results.seat_assignment_id <> old_assignment_id
     ) then
    raise exception 'Ethan #14 correction: expected original in-progress #60 roster state';
  end if;

  insert into public.n26_team_car_numbers (team_id, car_number, is_available)
  values (team_id_value, '14', true);

  prior_bypass := current_setting('n26.allow_midseason_replacement', true);
  perform set_config('n26.allow_midseason_replacement', 'on', true);
  update public.n26_seat_assignments
  set assignment_status = 'ended', ends_at = correction_at
  where id = old_assignment_id;
  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  ) values (
    season_id_value, driver_id_value, team_id_value, '14', correction_at, 'active'
  );
  perform set_config('n26.allow_midseason_replacement', coalesce(prior_bypass, ''), true);

  -- Retain the historical catalog entry; retire only when unused in ALL seasons.
  update public.n26_team_car_numbers set is_available = false
  where team_id = team_id_value and car_number = '60'
    and not exists (
      select 1 from public.n26_seat_assignments
      where car_number = '60' and assignment_status = 'active'
    )
    and not exists (select 1 from public.n26_claims where car_number = '60');

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id, from_car_number,
    to_car_number, transaction_type, effective_at, notes
  ) values (
    season_id_value, driver_id_value, team_id_value, team_id_value, '60',
    '14', 'correction', correction_at, audit_note
  );
end;
$$;
