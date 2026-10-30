-- One-time #23 -> #94 correction; retain the red/white/blue iRacing Toyota truck.
-- Not a team transfer: preserve the historical seat, results and account identity.
-- Apply only after matching artwork is deployed and explicitly approved.
do $$
declare
  driver_id_value constant uuid := 'e5767203-aa21-435a-97b3-b8dc1c0e4681';
  claim_id_value constant uuid := 'e93e7066-03b0-4dd9-8315-3f6cb92a6722';
  season_id_value constant uuid := '64004825-0c83-407e-8631-b0c0ca418ff9';
  team_id_value constant uuid := '094c1d5c-46bf-40ed-a5f8-1f388820eda1';
  old_assignment_id constant uuid := '331f4d57-f66f-4ae4-95e3-c44dfda881fb';
  old_catalog_id constant uuid := '4416b63a-4ee5-4293-9451-67e5bc6945e2';
  entry_id_value constant uuid := 'b0553a7f-b9e1-4fa5-8266-8b232d693512';
  old_starts_at constant timestamptz := '2026-09-19T16:35:35.027382Z';
  claimed_at_value constant timestamptz := '2026-09-19T16:34:39.944675Z';
  audit_note constant text := '20261030010000: Max Hunter switches from #23 to #94, retaining the red/white/blue iRacing Toyota truck; 23XI Racing, historical #23 seat/results and claim/account identity preserved.';
  driver_row public.n26_drivers;
  season_row public.n26_seasons;
  claim_row public.n26_claims;
  updated_claim public.n26_claims;
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
    public.n26_race_results, public.n26_season_races, public.n26_season_entries,
    public.n26_driver_number_styles, public.n26_claim_roster,
    public.n26_claim_availability in share row exclusive mode;

  select * into strict driver_row from public.n26_drivers where id = driver_id_value;
  select * into strict season_row from public.n26_seasons where id = season_id_value;
  select * into strict old_assignment from public.n26_seat_assignments where id = old_assignment_id;
  select * into strict claim_row from public.n26_claims where id = claim_id_value;
  if driver_row.display_name <> 'Max Hunter' or driver_row.status <> 'active'
     or driver_row.legacy_claim_id is distinct from claim_id_value
     or season_row.season_number <> 1 or season_row.status <> 'in_progress'
     or season_row.roster_lock_at is not null
     or old_assignment.season_id <> season_id_value
     or old_assignment.driver_id <> driver_id_value
     or old_assignment.team_id <> team_id_value or old_assignment.car_number <> '23'
     or old_assignment.starts_at <> old_starts_at
     or not exists (
       select 1 from public.n26_teams
       where id = team_id_value and slug = '23xi' and name = '23XI Racing'
         and status = 'active' and seat_limit = 3
     ) or not exists (
       select 1 from public.n26_season_entries
       where id = entry_id_value and season_id = season_id_value
         and driver_id = driver_id_value and entry_status = 'full_time'
     ) then
    raise exception 'Max #94 correction: unexpected identity, team, season or historical roster';
  end if;
  -- The login UUID is deliberately not embedded; require the existing links to agree.
  if claim_row.car_number not in ('23', '94')
     or claim_row.team_name is distinct from '23XI Racing'
     or claim_row.approval_status <> 'approved'
     or claim_row.gamertag is distinct from 'xxmessymax'
     or claim_row.first_name is distinct from 'Max' or claim_row.last_name is distinct from 'Hunter'
     or claim_row.claimed_at is distinct from claimed_at_value
     or claim_row.created_at is distinct from claimed_at_value
     or claim_row.reviewed_at is distinct from old_starts_at
     or claim_row.user_id is null or driver_row.auth_user_id is distinct from claim_row.user_id
     or exists (
       select 1 from public.n26_claims
       where car_number in ('23', '94') and id <> claim_id_value
     ) then
    raise exception 'Max #94 correction: unexpected linked claim or account dependency';
  end if;
  -- Verify both projections before moving their keys; never overwrite stale #94 data.
  if not exists (
    select 1 from public.n26_claim_roster roster
    where roster.car_number = claim_row.car_number and to_jsonb(roster) = jsonb_build_object(
      'car_number', claim_row.car_number, 'team_name', claim_row.team_name,
      'gamertag', claim_row.gamertag, 'first_name', claim_row.first_name,
      'last_name', claim_row.last_name, 'claimed_at', claim_row.claimed_at
    )
  ) or not exists (
    select 1 from public.n26_claim_availability
    where car_number = claim_row.car_number and approval_status = 'approved'
  ) or exists (
    select 1 from public.n26_claim_roster
    where car_number in ('23', '94') and car_number <> claim_row.car_number
  ) or exists (
    select 1 from public.n26_claim_availability
    where car_number in ('23', '94') and car_number <> claim_row.car_number
  ) then
    raise exception 'Max #94 correction: public claim projections have drifted';
  end if;
  if not exists (
    select 1 from public.n26_team_car_numbers
    where id = old_catalog_id and team_id = team_id_value and car_number = '23'
  ) or exists (
    select 1 from public.n26_team_car_numbers
    where car_number = '94' and (team_id <> team_id_value or not is_available)
  ) then
    raise exception 'Max #94 correction: unexpected number catalog';
  end if;
  if exists (
    select 1 from public.n26_contracts contracts
    where contracts.driver_id = driver_id_value or contracts.seat_assignment_id in (
      select id from public.n26_seat_assignments where driver_id = driver_id_value
    )
  ) or exists (
    select 1 from public.n26_driver_number_styles where driver_id = driver_id_value
  ) then
    raise exception 'Max #94 correction: unexpected contract or number style dependency';
  end if;
  if (select count(*) from public.n26_race_results
      where driver_id = driver_id_value or seat_assignment_id = old_assignment_id) <> 5
     or (select sum(points_earned) from public.n26_race_results
         where seat_assignment_id = old_assignment_id) is distinct from 123::bigint
     or (select array_agg(points_earned order by points_earned) from public.n26_race_results
         where seat_assignment_id = old_assignment_id) is distinct from array[0, 30, 30, 30, 33]
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
              or (results.team_id is not null and results.team_id <> team_id_value)
              or results.car_number <> '23' or races.season_id <> season_id_value
              or results.certification_status <> 'published')
     ) then
    raise exception 'Max #94 correction: historical #23 results have drifted';
  end if;

  select * into new_assignment from public.n26_seat_assignments
  where season_id = season_id_value and driver_id = driver_id_value and assignment_status = 'active';
  if (select count(*) from public.n26_seat_assignments
      where driver_id = driver_id_value and assignment_status = 'active') <> 1 then
    raise exception 'Max #94 correction: expected exactly one active Max seat globally';
  end if;
  if (select count(*) from public.n26_transactions where notes = audit_note) > 1 then
    raise exception 'Max #94 correction: duplicate correction audit';
  end if;
  select * into audit_row from public.n26_transactions where notes = audit_note;
  if audit_row.id is not null then
    if audit_row.season_id <> season_id_value or audit_row.driver_id <> driver_id_value
       or audit_row.transaction_type <> 'correction' or audit_row.contract_id is not null
       or audit_row.from_team_id is distinct from team_id_value
       or audit_row.to_team_id is distinct from team_id_value
       or audit_row.from_car_number is distinct from '23'
       or audit_row.to_car_number is distinct from '94'
       or old_assignment.assignment_status <> 'ended' or old_assignment.ends_at is null
       or new_assignment.id is null or new_assignment.car_number <> '94'
       or new_assignment.team_id <> team_id_value or new_assignment.ends_at is not null
       or new_assignment.starts_at <> old_assignment.ends_at
       or old_assignment.starts_at >= old_assignment.ends_at
       or audit_row.effective_at <> new_assignment.starts_at or claim_row.car_number <> '94'
       or (select count(*) from public.n26_seat_assignments
           where season_id = season_id_value and driver_id = driver_id_value) <> 2
       or not exists (
         select 1 from public.n26_team_car_numbers
         where team_id = team_id_value and car_number = '94' and is_available
       ) or exists (
         select 1 from public.n26_team_car_numbers numbers
         where numbers.id = old_catalog_id and numbers.is_available is distinct from exists (
           select 1 from public.n26_seat_assignments
           where car_number = '23' and assignment_status = 'active'
         )
       ) then
      raise exception 'Max #94 correction: audited state has drifted';
    end if;
    return;
  end if;

  if old_assignment.assignment_status <> 'active' or old_assignment.ends_at is not null
     or new_assignment.id is distinct from old_assignment_id or claim_row.car_number <> '23'
     or old_assignment.starts_at >= correction_at
     or (select count(*) from public.n26_seat_assignments
         where season_id = season_id_value and driver_id = driver_id_value) <> 1
     or exists (select 1 from public.n26_team_car_numbers where car_number = '94')
     or not exists (select 1 from public.n26_team_car_numbers where id = old_catalog_id and is_available)
     or exists (
       select 1 from public.n26_seat_assignments where car_number = '94' and assignment_status = 'active'
     ) then
    raise exception 'Max #94 correction: expected original in-progress #23 roster state';
  end if;

  insert into public.n26_team_car_numbers (team_id, car_number, is_available)
  values (team_id_value, '94', true);

  prior_bypass := current_setting('n26.allow_midseason_replacement', true);
  perform set_config('n26.allow_midseason_replacement', 'on', true);
  update public.n26_seat_assignments
  set assignment_status = 'ended', ends_at = correction_at where id = old_assignment_id;
  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  ) values (
    season_id_value, driver_id_value, team_id_value, '94', correction_at, 'active'
  );
  perform set_config('n26.allow_midseason_replacement', coalesce(prior_bypass, ''), true);

  -- Existing approval triggers move the public roster and create #94 availability.
  -- Update no approval/account/contact/timestamp fields, and verify that contract.
  update public.n26_claims set car_number = '94' where id = claim_id_value
  returning * into updated_claim;
  if (to_jsonb(updated_claim) - 'car_number') is distinct from (to_jsonb(claim_row) - 'car_number') then
    raise exception 'Max #94 correction: non-number claim fields changed';
  end if;
  -- The approved-claim trigger leaves old availability behind on a number change.
  delete from public.n26_claim_availability where car_number = '23'
    and not exists (
      select 1 from public.n26_claims
      where car_number = '23' and approval_status in ('pending', 'approved')
    );

  -- Retain the historical catalog identity; retire only if globally unused.
  update public.n26_team_car_numbers set is_available = false
  where id = old_catalog_id
    and not exists (
      select 1 from public.n26_seat_assignments where car_number = '23' and assignment_status = 'active'
    )
    and not exists (select 1 from public.n26_claims where car_number = '23');

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id, from_car_number,
    to_car_number, transaction_type, effective_at, notes
  ) values (
    season_id_value, driver_id_value, team_id_value, team_id_value, '23',
    '94', 'correction', correction_at, audit_note
  );
end;
$$;
