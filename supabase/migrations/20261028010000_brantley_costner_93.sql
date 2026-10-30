-- One-time livery/number correction, not a transfer or a contract renegotiation.
-- Keep the #97 assignment and all result snapshots intact for historical scoring.
do $$
declare
  driver_id_value constant uuid := 'e278f293-e476-4797-b6ff-a6c0bfb21733';
  season_id_value constant uuid := '64004825-0c83-407e-8631-b0c0ca418ff9';
  team_id_value constant uuid := '68dd5c40-4225-458c-bc89-1cd47e7240f9';
  old_assignment_id constant uuid := '0728e3dc-9f16-4fd4-abac-549bcf868086';
  audit_note constant text := '20261028010000: Brantley Culp switches from #97 to Caleb Costner #93; historical #97 results and contract financials preserved.';
  driver_row public.n26_drivers;
  season_row public.n26_seasons;
  old_assignment public.n26_seat_assignments;
  new_assignment public.n26_seat_assignments;
  contract_row public.n26_contracts;
  claim_row public.n26_claims;
  audit_row public.n26_transactions;
  prior_bypass text;
  correction_at timestamptz := clock_timestamp();
begin
  -- Fresh fixtures have different identities; do not create a production driver.
  if not exists (select 1 from public.n26_drivers where id = driver_id_value) then
    return;
  end if;

  -- Serialize this short maintenance operation with roster/claim/catalog writes,
  -- including inserts into currently empty #93 slots. No schema or guard changes.
  lock table public.n26_seasons, public.n26_drivers, public.n26_teams,
    public.n26_team_car_numbers, public.n26_seat_assignments,
    public.n26_contracts, public.n26_claims, public.n26_transactions
    in share row exclusive mode;

  select * into strict driver_row from public.n26_drivers where id = driver_id_value;
  select * into strict season_row from public.n26_seasons where id = season_id_value;
  select * into strict old_assignment from public.n26_seat_assignments where id = old_assignment_id;
  if season_row.season_number <> 1
     or old_assignment.season_id <> season_id_value
     or old_assignment.driver_id <> driver_id_value
     or old_assignment.team_id <> team_id_value
     or old_assignment.car_number <> '97'
     or not exists (
       select 1 from public.n26_teams
       where id = team_id_value and slug = 'trackhouse'
         and name = 'Trackhouse Racing' and status = 'active'
     ) then
    raise exception 'Brantley #93 correction: unexpected season, team or historical seat';
  end if;
  if not exists (
    select 1 from public.n26_team_car_numbers
    where team_id = team_id_value and car_number = '97'
  ) or exists (
    select 1 from public.n26_team_car_numbers
    where car_number = '93' and (team_id <> team_id_value or not is_available)
  ) then
    raise exception 'Brantley #93 correction: unexpected number catalog';
  end if;

  select * into new_assignment from public.n26_seat_assignments
  where season_id = season_id_value and driver_id = driver_id_value
    and assignment_status = 'active';

  if driver_row.legacy_claim_id is not null then
    select * into strict claim_row from public.n26_claims where id = driver_row.legacy_claim_id;
    if claim_row.car_number not in ('97', '93')
       or lower(btrim(claim_row.team_name)) is distinct from 'trackhouse racing' then
      raise exception 'Brantley #93 correction: unexpected linked claim';
    end if;
  end if;
  if exists (
    select 1 from public.n26_claims
    where car_number in ('97', '93') and id is distinct from driver_row.legacy_claim_id
  ) then
    raise exception 'Brantley #93 correction: another claim uses #97 or #93';
  end if;

  if (select count(*) from public.n26_contracts
      where driver_id = driver_id_value and status in ('introductory', 'active')
        and start_season <= season_row.season_number
        and end_season >= season_row.season_number) > 1 then
    raise exception 'Brantley #93 correction: multiple current contracts';
  end if;
  select * into contract_row from public.n26_contracts
  where driver_id = driver_id_value and status in ('introductory', 'active')
    and start_season <= season_row.season_number and end_season >= season_row.season_number;
  if contract_row.id is not null and (
    contract_row.team_id <> team_id_value
    or (contract_row.seat_assignment_id is not null
        and contract_row.seat_assignment_id <> old_assignment_id
        and contract_row.seat_assignment_id is distinct from new_assignment.id)
  ) then
    raise exception 'Brantley #93 correction: unexpected current contract seat/team';
  end if;

  -- An exact audit marker plus the resulting seat state makes reruns no-ops.
  if (select count(*) from public.n26_transactions where notes = audit_note) > 1 then
    raise exception 'Brantley #93 correction: duplicate correction audit';
  end if;
  select * into audit_row from public.n26_transactions where notes = audit_note;
  if audit_row.id is not null then
    if audit_row.season_id <> season_id_value or audit_row.driver_id <> driver_id_value
       or audit_row.transaction_type <> 'correction'
       or audit_row.from_team_id is distinct from team_id_value
       or audit_row.to_team_id is distinct from team_id_value
       or audit_row.from_car_number is distinct from '97'
       or audit_row.to_car_number is distinct from '93'
       or old_assignment.assignment_status <> 'ended' or old_assignment.ends_at is null
       or new_assignment.id is null or new_assignment.car_number <> '93'
       or new_assignment.team_id <> team_id_value or new_assignment.ends_at is not null
       or new_assignment.starts_at <> old_assignment.ends_at
       or claim_row.car_number = '97'
       or (contract_row.id is not null and contract_row.seat_assignment_id is distinct from new_assignment.id)
       or not exists (
         select 1 from public.n26_team_car_numbers
         where team_id = team_id_value and car_number = '93' and is_available
       ) then
      raise exception 'Brantley #93 correction: audited state has drifted';
    end if;
    return;
  end if;

  if season_row.status <> 'in_progress' or season_row.roster_lock_at is not null
     or old_assignment.assignment_status <> 'active' or old_assignment.ends_at is not null
     or new_assignment.id is distinct from old_assignment_id
     or old_assignment.starts_at >= correction_at
     or claim_row.car_number = '93'
     or exists (
       select 1 from public.n26_seat_assignments
       where season_id = season_id_value and car_number = '93' and assignment_status = 'active'
     ) then
    raise exception 'Brantley #93 correction: expected original in-progress #97 roster state';
  end if;

  insert into public.n26_team_car_numbers (team_id, car_number, is_available)
  values (team_id_value, '93', true)
  on conflict (car_number) do nothing;

  prior_bypass := current_setting('n26.allow_midseason_replacement', true);
  perform set_config('n26.allow_midseason_replacement', 'on', true);
  update public.n26_seat_assignments
  set assignment_status = 'ended', ends_at = correction_at
  where id = old_assignment_id;
  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  ) values (
    season_id_value, driver_id_value, team_id_value, '93', correction_at, 'active'
  ) returning * into new_assignment;
  perform set_config('n26.allow_midseason_replacement', coalesce(prior_bypass, ''), true);

  -- Only the seat pointer changes: no repricing, release, signing or term reset.
  if contract_row.id is not null then
    update public.n26_contracts set seat_assignment_id = new_assignment.id
    where id = contract_row.id;
  end if;
  if claim_row.id is not null then
    update public.n26_claims set car_number = '93' where id = claim_row.id;
    -- The existing approved-claim sync removes the old public roster row but
    -- leaves its availability projection; remove only this now-unused key.
    delete from public.n26_claim_availability where car_number = '97'
      and not exists (
        select 1 from public.n26_claims
        where car_number = '97' and approval_status in ('pending', 'approved')
      );
  end if;

  -- Keep #97's catalog row for history; retire only if no season or claim uses it.
  update public.n26_team_car_numbers set is_available = false
  where team_id = team_id_value and car_number = '97'
    and not exists (
      select 1 from public.n26_seat_assignments
      where car_number = '97' and assignment_status = 'active'
    )
    and not exists (select 1 from public.n26_claims where car_number = '97');

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id, from_car_number,
    to_car_number, transaction_type, effective_at, contract_id, notes
  ) values (
    season_id_value, driver_id_value, team_id_value, team_id_value, '97',
    '93', 'correction', correction_at, contract_row.id, audit_note
  );
end;
$$;
