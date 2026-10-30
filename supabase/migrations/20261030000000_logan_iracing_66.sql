-- One-time black/green/blue iRacing truck #66 correction, not a team transfer.
-- Preserve Logan's historical #20 seat and every result, including NULL teams.
-- Apply only after the matching artwork is deployed and explicitly approved.
do $$
declare
  driver_id_value constant uuid := '082c49cb-c904-4c0a-9ac5-258e99174cee';
  season_id_value constant uuid := '64004825-0c83-407e-8631-b0c0ca418ff9';
  team_id_value constant uuid := 'f618d5a0-cda1-4d62-bc7e-a77931bea7d3';
  old_assignment_id constant uuid := '677ced8a-2a34-49c7-8c5b-504b03aaee6f';
  old_catalog_id constant uuid := 'b78968b2-4360-4ba8-a3e0-05b0223cfd70';
  entry_id_value constant uuid := 'e81887da-f667-4b27-8624-1ca17f4e8c77';
  old_starts_at constant timestamptz := '2026-09-10T21:24:29.32465+00:00';
  audit_note constant text := '20261030000000: Logan Boone switches from #20 to black/green/blue iRacing truck #66; Joe Gibbs Racing, historical #20 seat and all result snapshots preserved.';
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

  -- Serialize checked state, including inserts into the currently empty #66 slot.
  lock table public.n26_seasons, public.n26_drivers, public.n26_teams,
    public.n26_team_car_numbers, public.n26_seat_assignments,
    public.n26_contracts, public.n26_claims, public.n26_transactions,
    public.n26_race_results, public.n26_season_races, public.n26_season_entries,
    public.n26_driver_number_styles in share row exclusive mode;

  select * into strict driver_row from public.n26_drivers where id = driver_id_value;
  select * into strict season_row from public.n26_seasons where id = season_id_value;
  select * into strict old_assignment from public.n26_seat_assignments where id = old_assignment_id;
  if driver_row.display_name <> 'Logan Boone' or driver_row.status <> 'active'
     or season_row.season_number <> 1 or season_row.status <> 'in_progress'
     or season_row.roster_lock_at is not null
     or old_assignment.season_id <> season_id_value
     or old_assignment.driver_id <> driver_id_value
     or old_assignment.team_id <> team_id_value or old_assignment.car_number <> '20'
     or old_assignment.starts_at <> old_starts_at
     or not exists (
       select 1 from public.n26_teams
       where id = team_id_value and slug = 'jgr' and name = 'Joe Gibbs Racing'
         and status = 'active' and seat_limit = 3
     ) or not exists (
       select 1 from public.n26_season_entries
       where id = entry_id_value and season_id = season_id_value
         and driver_id = driver_id_value and entry_status = 'full_time'
     ) then
    raise exception 'Logan #66 correction: unexpected identity, team, season or historical roster';
  end if;
  if not exists (
    select 1 from public.n26_team_car_numbers
    where id = old_catalog_id and team_id = team_id_value and car_number = '20'
  ) or exists (
    select 1 from public.n26_team_car_numbers
    where car_number = '66' and (team_id <> team_id_value or not is_available)
  ) then
    raise exception 'Logan #66 correction: unexpected number catalog';
  end if;

  -- Stop on account, financial or style drift; do not migrate these dependencies.
  if driver_row.legacy_claim_id is not null
     or exists (select 1 from public.n26_claims where car_number in ('20', '66'))
     or exists (
       select 1 from public.n26_contracts contracts
       where contracts.driver_id = driver_id_value or contracts.seat_assignment_id in (
         select id from public.n26_seat_assignments where driver_id = driver_id_value
       )
     ) or exists (
       select 1 from public.n26_driver_number_styles where driver_id = driver_id_value
     ) then
    raise exception 'Logan #66 correction: unexpected claim, contract or number style dependency';
  end if;
  if (select count(*) from public.n26_race_results
      where driver_id = driver_id_value or seat_assignment_id = old_assignment_id) <> 5
     or (select sum(points_earned) from public.n26_race_results
         where seat_assignment_id = old_assignment_id) is distinct from 145::bigint
     or (select array_agg(points_earned order by points_earned) from public.n26_race_results
         where seat_assignment_id = old_assignment_id) is distinct from array[0, 33, 36, 36, 40]
     or (select count(*) from public.n26_race_results
         where seat_assignment_id = old_assignment_id and start_status = 'started') <> 4
     or (select count(*) from public.n26_race_results
         where seat_assignment_id = old_assignment_id and start_status = 'dns') <> 1
     or exists (
       select 1 from public.n26_race_results results
       join public.n26_season_races races on races.id = results.race_id
       where (results.driver_id = driver_id_value or results.seat_assignment_id = old_assignment_id)
         and (results.seat_assignment_id is distinct from old_assignment_id
              or results.driver_id <> driver_id_value
              -- Existing NULL team snapshots are valid and must stay NULL.
              or (results.team_id is not null and results.team_id <> team_id_value)
              or results.car_number <> '20' or races.season_id <> season_id_value
              or results.certification_status <> 'published')
     ) then
    raise exception 'Logan #66 correction: historical #20 results have drifted';
  end if;

  select * into new_assignment from public.n26_seat_assignments
  where season_id = season_id_value and driver_id = driver_id_value
    and assignment_status = 'active';
  if (select count(*) from public.n26_seat_assignments
      where driver_id = driver_id_value and assignment_status = 'active') <> 1 then
    raise exception 'Logan #66 correction: expected exactly one active Logan seat globally';
  end if;
  if (select count(*) from public.n26_transactions where notes = audit_note) > 1 then
    raise exception 'Logan #66 correction: duplicate correction audit';
  end if;
  select * into audit_row from public.n26_transactions where notes = audit_note;
  if audit_row.id is not null then
    if audit_row.season_id <> season_id_value or audit_row.driver_id <> driver_id_value
       or audit_row.transaction_type <> 'correction' or audit_row.contract_id is not null
       or audit_row.from_team_id is distinct from team_id_value
       or audit_row.to_team_id is distinct from team_id_value
       or audit_row.from_car_number is distinct from '20'
       or audit_row.to_car_number is distinct from '66'
       or old_assignment.assignment_status <> 'ended' or old_assignment.ends_at is null
       or new_assignment.id is null or new_assignment.car_number <> '66'
       or new_assignment.team_id <> team_id_value or new_assignment.ends_at is not null
       or new_assignment.starts_at <> old_assignment.ends_at
       or old_assignment.starts_at >= old_assignment.ends_at
       or audit_row.effective_at <> new_assignment.starts_at
       or (select count(*) from public.n26_seat_assignments
           where season_id = season_id_value and driver_id = driver_id_value) <> 2
       or not exists (
         select 1 from public.n26_team_car_numbers
         where team_id = team_id_value and car_number = '66' and is_available
       ) or exists (
         select 1 from public.n26_team_car_numbers numbers
         where numbers.id = old_catalog_id and numbers.is_available is distinct from exists (
           select 1 from public.n26_seat_assignments
           where car_number = '20' and assignment_status = 'active'
         )
       ) then
      raise exception 'Logan #66 correction: audited state has drifted';
    end if;
    return;
  end if;

  if old_assignment.assignment_status <> 'active' or old_assignment.ends_at is not null
     or new_assignment.id is distinct from old_assignment_id
     or old_assignment.starts_at >= correction_at
     or (select count(*) from public.n26_seat_assignments
         where season_id = season_id_value and driver_id = driver_id_value) <> 1
     or exists (select 1 from public.n26_team_car_numbers where car_number = '66')
     or not exists (select 1 from public.n26_team_car_numbers where id = old_catalog_id and is_available)
     or exists (
       select 1 from public.n26_seat_assignments
       where car_number = '66' and assignment_status = 'active'
     ) then
    raise exception 'Logan #66 correction: expected original in-progress #20 roster state';
  end if;

  insert into public.n26_team_car_numbers (team_id, car_number, is_available)
  values (team_id_value, '66', true);

  prior_bypass := current_setting('n26.allow_midseason_replacement', true);
  perform set_config('n26.allow_midseason_replacement', 'on', true);
  update public.n26_seat_assignments
  set assignment_status = 'ended', ends_at = correction_at
  where id = old_assignment_id;
  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  ) values (
    season_id_value, driver_id_value, team_id_value, '66', correction_at, 'active'
  );
  perform set_config('n26.allow_midseason_replacement', coalesce(prior_bypass, ''), true);

  -- Retain the historical catalog row; retire only if unused across ALL seasons.
  update public.n26_team_car_numbers set is_available = false
  where id = old_catalog_id
    and not exists (
      select 1 from public.n26_seat_assignments
      where car_number = '20' and assignment_status = 'active'
    )
    and not exists (select 1 from public.n26_claims where car_number = '20');

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id, from_car_number,
    to_car_number, transaction_type, effective_at, notes
  ) values (
    season_id_value, driver_id_value, team_id_value, team_id_value, '20',
    '66', 'correction', correction_at, audit_note
  );
end;
$$;
