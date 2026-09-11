-- Treat a contract as active for every season in its start/end range. This
-- keeps multi-season agreements visible for cap, publishing, renewal, and
-- expiration instead of limiting them to the season in which they were signed.

alter table public.n26_contracts
  add column if not exists base_rating numeric(6,2);

alter table public.n26_contracts
  drop constraint if exists n26_contracts_base_rating_check;

alter table public.n26_contracts
  add constraint n26_contracts_base_rating_check
  check (base_rating is null or (base_rating >= 40 and base_rating <= 100));

create or replace function public.n26_create_contract(
  p_season_id uuid,
  p_driver_id uuid,
  p_team_id uuid,
  p_seat_assignment_id uuid,
  p_rating numeric,
  p_original_term_seasons integer default 1,
  p_term_discount_bps integer default 0,
  p_loyalty_discount_bps integer default 0
)
returns public.n26_contracts
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  previous_season_row public.n26_seasons;
  seat_row public.n26_seat_assignments;
  contract_row public.n26_contracts;
  expected_rating numeric;
  expected_term_discount_bps integer;
  loyalty_eligible boolean;
  current_contract_count integer;
  current_cap_cents integer;
  cap_limit_cents integer;
  charge_cents integer;
  total_discount_bps integer;
begin
  select * into season_row
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_row.id is null or season_row.status not in ('draft', 'open') then
    raise exception 'Contracts can only be created for draft or open seasons' using errcode = '42501';
  end if;

  select * into ruleset_row from public.n26_rulesets where id = season_row.ruleset_id;
  if p_original_term_seasons not between 1 and 3 then
    raise exception 'Contract term must be 1, 2, or 3 seasons' using errcode = '23514';
  end if;
  if p_term_discount_bps not in (0, 200, 400) or p_loyalty_discount_bps not in (0, 100) then
    raise exception 'Contract discounts are outside the published options' using errcode = '23514';
  end if;
  expected_term_discount_bps := case p_original_term_seasons when 1 then 0 when 2 then 200 when 3 then 400 end;
  if p_term_discount_bps <> expected_term_discount_bps then
    raise exception 'Term discount must match the original contract term' using errcode = '23514';
  end if;
  total_discount_bps := p_term_discount_bps + p_loyalty_discount_bps;
  if total_discount_bps > 500 then
    raise exception 'Combined contract discounts cannot exceed 5 percent' using errcode = '23514';
  end if;
  if season_row.season_number = 1
     and (p_rating <> 50 or p_original_term_seasons <> 1 or total_discount_bps <> 0) then
    raise exception 'Season 1 contracts are one-season introductory contracts at 50 credits' using errcode = '23514';
  end if;
  if p_rating < 40 or p_rating > 100 then
    raise exception 'Rating must be between 40 and 100' using errcode = '23514';
  end if;

  if not exists (
    select 1 from public.n26_season_entries
    where season_id = p_season_id and driver_id = p_driver_id and entry_status = 'full_time'
  ) then
    raise exception 'Driver must be a full-time season entry before signing' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.n26_contracts contracts
    where contracts.driver_id = p_driver_id
      and contracts.start_season <= season_row.season_number
      and contracts.end_season >= season_row.season_number
      and contracts.status in ('introductory', 'active')
  ) then
    raise exception 'Driver already has a contract covering this season' using errcode = '23505';
  end if;

  select * into seat_row
  from public.n26_seat_assignments
  where id = p_seat_assignment_id
    and season_id = p_season_id
    and driver_id = p_driver_id
    and team_id = p_team_id
    and assignment_status = 'active'
  for update;
  if seat_row.id is null then
    raise exception 'Contract must reference the driver''s active destination seat' using errcode = '23514';
  end if;

  if season_row.season_number > 1 then
    select * into previous_season_row
    from public.n26_seasons
    where season_number = season_row.season_number - 1;
    select snapshots.official_ovr into expected_rating
    from public.n26_rating_snapshots snapshots
    where snapshots.season_id = previous_season_row.id
      and snapshots.driver_id = p_driver_id
      and snapshots.certification_status = 'certified'
    limit 1;
    if expected_rating is null then
      if exists (
        select 1 from public.n26_season_entries
        where season_id = previous_season_row.id and driver_id = p_driver_id and entry_status = 'full_time'
      ) then
        raise exception 'Returning drivers require a certified prior-season rating' using errcode = '23514';
      end if;
      expected_rating := 50;
    end if;
    select exists (
      select 1
      from public.n26_season_entries entries
      join public.n26_seat_assignments assignments
        on assignments.season_id = entries.season_id
       and assignments.driver_id = entries.driver_id
       and assignments.team_id = p_team_id
       and assignments.assignment_status = 'active'
      where entries.season_id = previous_season_row.id
        and entries.driver_id = p_driver_id
        and entries.entry_status = 'full_time'
        and not exists (
          select 1 from public.n26_seat_assignments other_assignments
          where other_assignments.season_id = previous_season_row.id
            and other_assignments.driver_id = p_driver_id
            and other_assignments.team_id <> p_team_id
            and other_assignments.assignment_status in ('active', 'transferred', 'ended')
        )
    ) into loyalty_eligible;
    if p_loyalty_discount_bps = 100 and not loyalty_eligible then
      raise exception 'Loyalty discount requires the same team for the entire prior season' using errcode = '23514';
    end if;
  else
    expected_rating := 50;
  end if;
  if p_rating <> expected_rating then
    raise exception 'Contract rating must match the authoritative prior-season OVR or newcomer value' using errcode = '23514';
  end if;

  cap_limit_cents := case
    when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100
    when season_row.season_number = 1 then 15500
    else null
  end;
  if cap_limit_cents is null then
    raise exception 'A published league cap is required before signing contracts' using errcode = '23514';
  end if;
  charge_cents := ceil((p_rating * 100 * (10000 - total_discount_bps)) / 10000);

  select count(*) into current_contract_count
  from public.n26_contracts contracts
  where contracts.team_id = p_team_id
    and contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory', 'active');
  select coalesce(sum(contracts.cap_charge_cents), 0) into current_cap_cents
  from public.n26_contracts contracts
  where contracts.team_id = p_team_id
    and contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory', 'active');
  if current_contract_count >= 3 then
    raise exception 'Team already has three current contracts' using errcode = '23514';
  end if;
  if current_cap_cents + charge_cents > cap_limit_cents then
    raise exception 'Contract would exceed the team salary cap' using errcode = '23514';
  end if;

  insert into public.n26_contracts (
    season_id, driver_id, team_id, seat_assignment_id, start_season, end_season,
    original_term_seasons, term_discount_bps, loyalty_discount_bps,
    cap_charge_cents, base_rating, status
  ) values (
    p_season_id, p_driver_id, p_team_id, p_seat_assignment_id,
    season_row.season_number, season_row.season_number + p_original_term_seasons - 1,
    p_original_term_seasons, p_term_discount_bps, p_loyalty_discount_bps,
    charge_cents, p_rating, case when season_row.season_number = 1 then 'introductory' else 'active' end
  ) returning * into contract_row;
  return contract_row;
end;
$$;

create or replace function public.n26_expire_contracts(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  contract_row public.n26_contracts;
  expired_count integer := 0;
begin
  select * into season_row from public.n26_seasons where id = p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode = '02000'; end if;
  if season_row.status not in ('certified', 'archived') then
    raise exception 'Contracts can only expire after season certification' using errcode = '42501';
  end if;
  for contract_row in
    select * from public.n26_contracts
    where end_season <= season_row.season_number and status in ('introductory', 'active')
    for update
  loop
    update public.n26_contracts set status = 'expired', expired_at = now() where id = contract_row.id;
    insert into public.n26_transactions (
      season_id, driver_id, from_team_id, transaction_type, contract_id, notes
    ) values (
      p_season_id, contract_row.driver_id, contract_row.team_id, 'expiration', contract_row.id,
      format('Contract expired after Season %s', season_row.season_number)
    );
    expired_count := expired_count + 1;
  end loop;
  return jsonb_build_object('season_id', p_season_id, 'expired_contracts', expired_count);
end;
$$;

create or replace function public.n26_release_contract_for_season(
  p_season_id uuid,
  p_contract_id uuid,
  p_reason text
)
returns public.n26_contracts
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  contract_row public.n26_contracts;
begin
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to release a contract' using errcode = '22023';
  end if;
  select * into season_row from public.n26_seasons where id = p_season_id for update;
  if season_row.id is null or season_row.status not in ('draft', 'open') or season_row.roster_lock_at is not null then
    raise exception 'Contracts can only be released before the current season roster lock' using errcode = '42501';
  end if;
  select * into contract_row from public.n26_contracts where id = p_contract_id for update;
  if contract_row.id is null then raise exception 'Contract not found' using errcode = '02000'; end if;
  if contract_row.status not in ('introductory', 'active') then
    raise exception 'Only a current contract can be released' using errcode = '23514';
  end if;
  if contract_row.start_season > season_row.season_number or contract_row.end_season < season_row.season_number then
    raise exception 'Contract does not cover the selected season' using errcode = '23514';
  end if;
  update public.n26_contracts
  set status = 'released', released_at = now(), release_reason = trim(p_reason)
  where id = p_contract_id
  returning * into contract_row;
  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, transaction_type, contract_id, notes
  ) values (
    p_season_id, contract_row.driver_id, contract_row.team_id, 'release', contract_row.id, trim(p_reason)
  );
  return contract_row;
end;
$$;

revoke execute on function public.n26_release_contract_for_season(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.n26_release_contract_for_season(uuid, uuid, text) to service_role;

create or replace function public.n26_publish_season(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  full_time_count integer;
  active_seat_count integer;
  current_contract_count integer;
  expected_driver_count integer;
  expected_team_size integer;
  cap_limit_cents integer;
  assignment_row record;
  updated_season public.n26_seasons;
begin
  select * into season_row from public.n26_seasons where id = p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode = '02000'; end if;
  if season_row.status <> 'draft' then raise exception 'Only a draft season can be published' using errcode = '42501'; end if;
  select * into ruleset_row from public.n26_rulesets where id = season_row.ruleset_id;
  if coalesce(ruleset_row.config->>'points_schedule_status', '') <> 'approved' then
    raise exception 'The 24-position points schedule must be approved before publishing' using errcode = '23514';
  end if;
  expected_driver_count := ruleset_row.driver_count;
  expected_team_size := ruleset_row.team_size;

  select count(*) into full_time_count from public.n26_season_entries where season_id=p_season_id and entry_status='full_time';
  if full_time_count <> expected_driver_count then raise exception 'Publishing requires % full-time drivers', expected_driver_count using errcode = '23514'; end if;
  select count(*) into active_seat_count
  from public.n26_seat_assignments assignments
  join public.n26_season_entries entries on entries.season_id=assignments.season_id and entries.driver_id=assignments.driver_id and entries.entry_status='full_time'
  where assignments.season_id=p_season_id and assignments.assignment_status='active';
  if active_seat_count <> expected_driver_count then raise exception 'Publishing requires % active full-time seats', expected_driver_count using errcode = '23514'; end if;
  if exists (
    select 1 from public.n26_season_entries entries
    where entries.season_id=p_season_id and entries.entry_status='full_time'
      and not exists (select 1 from public.n26_seat_assignments assignments where assignments.season_id=p_season_id and assignments.driver_id=entries.driver_id and assignments.assignment_status='active')
  ) then raise exception 'Every full-time driver must have an active seat' using errcode = '23514'; end if;
  if exists (
    select 1 from public.n26_seat_assignments assignments
    where assignments.season_id=p_season_id and assignments.assignment_status='active'
      and not exists (select 1 from public.n26_season_entries entries where entries.season_id=p_season_id and entries.driver_id=assignments.driver_id and entries.entry_status='full_time')
  ) then raise exception 'Reserve or inactive entries cannot occupy a full-time seat at publish' using errcode = '23514'; end if;
  if exists (
    select 1 from public.n26_teams teams
    left join public.n26_seat_assignments assignments on assignments.team_id=teams.id and assignments.season_id=p_season_id and assignments.assignment_status='active'
    where teams.status='active' group by teams.id, teams.seat_limit having count(assignments.id) <> expected_team_size
  ) then raise exception 'Every active team must have exactly % seats at publish', expected_team_size using errcode = '23514'; end if;

  select count(distinct contracts.driver_id) into current_contract_count
  from public.n26_contracts contracts
  where contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory','active');
  if season_row.season_number = 1 then
    for assignment_row in
      select assignments.* from public.n26_seat_assignments assignments
      where assignments.season_id=p_season_id and assignments.assignment_status='active'
        and not exists (
          select 1 from public.n26_contracts contracts
          where contracts.driver_id=assignments.driver_id
            and contracts.start_season <= season_row.season_number
            and contracts.end_season >= season_row.season_number
            and contracts.status in ('introductory','active')
        )
      order by assignments.id
    loop
      perform public.n26_create_contract(p_season_id, assignment_row.driver_id, assignment_row.team_id, assignment_row.id, 50, 1, 0, 0);
    end loop;
  elsif current_contract_count <> expected_driver_count then
    raise exception 'Every full-time driver needs a current contract before publishing' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.n26_season_entries entries
    join public.n26_seat_assignments assignments on assignments.season_id=entries.season_id and assignments.driver_id=entries.driver_id and assignments.assignment_status='active'
    where entries.season_id=p_season_id and entries.entry_status='full_time'
      and not exists (
        select 1 from public.n26_contracts contracts
        where contracts.driver_id=entries.driver_id and contracts.team_id=assignments.team_id
          and contracts.start_season <= season_row.season_number and contracts.end_season >= season_row.season_number
          and contracts.status in ('introductory','active')
      )
  ) then raise exception 'Each full-time seat must match its current contract team' using errcode = '23514'; end if;

  cap_limit_cents := case when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100 when season_row.season_number=1 then 15500 else null end;
  if cap_limit_cents is null then raise exception 'A published league cap is required before publishing this season' using errcode = '23514'; end if;
  if exists (
    select 1 from public.n26_contracts contracts
    where contracts.start_season <= season_row.season_number and contracts.end_season >= season_row.season_number
      and contracts.status in ('introductory','active')
    group by contracts.team_id having coalesce(sum(contracts.cap_charge_cents),0) > cap_limit_cents
  ) then raise exception 'The roster exceeds the published team salary cap' using errcode = '23514'; end if;

  update public.n26_seasons set status='open', roster_lock_at=now() where id=p_season_id returning * into updated_season;
  return jsonb_build_object('season',to_jsonb(updated_season),'contracts_created',case when season_row.season_number=1 then expected_driver_count-current_contract_count else 0 end);
end;
$$;

create or replace function public.n26_open_contract_market(
  p_season_id uuid,
  p_renewal_hours integer default 48,
  p_free_agency_days integer default 5
)
returns public.n26_seasons
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  previous_season_row public.n26_seasons;
begin
  if p_renewal_hours < 1 or p_free_agency_days < 1 then raise exception 'Contract market windows must be positive' using errcode='23514'; end if;
  select * into season_row from public.n26_seasons where id=p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode='02000'; end if;
  if season_row.season_number=1 then raise exception 'Season 1 uses introductory contracts and has no free-agency market' using errcode='42501'; end if;
  if season_row.status <> 'draft' then raise exception 'The contract market can only open for a draft season' using errcode='42501'; end if;
  if season_row.contract_market_status <> 'closed' then raise exception 'The contract market is already open' using errcode='23505'; end if;
  select * into previous_season_row from public.n26_seasons where season_number=season_row.season_number-1;
  if previous_season_row.id is null or previous_season_row.status not in ('certified','archived') then raise exception 'The prior season must be certified before opening contracts' using errcode='42501'; end if;
  update public.n26_seasons
  set contract_market_status='renewals', renewal_window_ends_at=now()+make_interval(hours=>p_renewal_hours), free_agency_closes_at=now()+make_interval(hours=>p_renewal_hours,days=>p_free_agency_days)
  where id=p_season_id returning * into season_row;
  return season_row;
end;
$$;

create or replace function public.n26_validate_contract_market()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  previous_season_row public.n26_seasons;
begin
  if new.start_season=1 then return new; end if;
  select * into season_row from public.n26_seasons where id=new.season_id;
  if season_row.contract_market_status='closed' or season_row.renewal_window_ends_at is null or season_row.free_agency_closes_at is null then
    raise exception 'Open the contract market before signing future-season contracts' using errcode='42501';
  end if;
  if now() > season_row.free_agency_closes_at then raise exception 'The free-agency period has closed for this season' using errcode='42501'; end if;
  if now() > season_row.renewal_window_ends_at and season_row.contract_market_status='renewals' then
    update public.n26_seasons set contract_market_status='free_agency' where id=season_row.id;
  end if;
  if now() <= season_row.renewal_window_ends_at then
    select * into previous_season_row from public.n26_seasons where season_number=season_row.season_number-1;
    if not exists (
      select 1 from public.n26_contracts previous_contracts
      where previous_contracts.driver_id=new.driver_id
        and previous_contracts.team_id=new.team_id
        and previous_contracts.start_season <= previous_season_row.season_number
        and previous_contracts.end_season >= previous_season_row.season_number
        and previous_contracts.status in ('expired','active','introductory')
    ) then raise exception 'Only the incumbent team may sign this driver during the renewal window' using errcode='42501'; end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.n26_publish_season(uuid) from public, anon, authenticated;
grant execute on function public.n26_publish_season(uuid) to service_role;
revoke execute on function public.n26_open_contract_market(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.n26_open_contract_market(uuid, integer, integer) to service_role;
revoke execute on function public.n26_validate_contract_market() from public, anon, authenticated;
grant execute on function public.n26_validate_contract_market() to service_role;

create or replace function public.n26_transfer_driver_to_seat(
  p_season_id uuid,
  p_driver_id uuid,
  p_team_id uuid,
  p_car_number text,
  p_driver_consented boolean,
  p_from_team_consented boolean,
  p_to_team_consented boolean,
  p_notes text default null
)
returns public.n26_seat_assignments
language plpgsql
set search_path = public
as $$
declare
  current_assignment public.n26_seat_assignments;
  inserted_assignment public.n26_seat_assignments;
  current_contract public.n26_contracts;
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  trade_transaction_id uuid;
  loyalty_discount integer;
  charge_cents integer;
  cap_limit_cents integer;
  destination_cap_cents integer;
begin
  if not coalesce(p_driver_consented, false)
     or not coalesce(p_from_team_consented, false)
     or not coalesce(p_to_team_consented, false) then
    raise exception 'All three transfer consents are required' using errcode = '42501';
  end if;

  select * into season_row from public.n26_seasons where id=p_season_id for update;
  if season_row.id is null or season_row.status not in ('draft','open') then
    raise exception 'Roster changes are only allowed for draft or open seasons' using errcode='42501';
  end if;
  select * into current_assignment
  from public.n26_seat_assignments
  where season_id=p_season_id and driver_id=p_driver_id and assignment_status='active'
  order by starts_at desc limit 1 for update;
  if current_assignment.id is null then
    raise exception 'A transfer requires an existing active seat; use initial assignment instead' using errcode='23514';
  end if;

  select * into current_contract
  from public.n26_contracts
  where driver_id=p_driver_id
    and team_id=current_assignment.team_id
    and start_season <= season_row.season_number
    and end_season >= season_row.season_number
    and status in ('introductory','active')
  order by start_season desc, created_at desc limit 1 for update;

  insert into public.n26_transaction_consents (
    season_id, driver_id, from_team_id, to_team_id,
    from_car_number, to_car_number,
    driver_consented, from_team_consented, to_team_consented, notes
  ) values (
    p_season_id, p_driver_id, current_assignment.team_id, p_team_id,
    current_assignment.car_number, p_car_number,
    true, true, true, nullif(trim(p_notes), '')
  );

  select * into inserted_assignment
  from public.n26_assign_driver_to_seat(p_season_id, p_driver_id, p_team_id, p_car_number, true);

  if current_contract.id is not null then
    if current_contract.base_rating is null then
      raise exception 'The carried contract is missing its authoritative base rating; reprice it before transfer' using errcode='23514';
    end if;
    loyalty_discount := case when current_contract.team_id = p_team_id then current_contract.loyalty_discount_bps else 0 end;
    charge_cents := ceil((current_contract.base_rating * 100 * (10000 - current_contract.term_discount_bps - loyalty_discount)) / 10000);
    select * into ruleset_row from public.n26_rulesets where id=season_row.ruleset_id;
    cap_limit_cents := case when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100 when season_row.season_number=1 then 15500 else null end;
    if cap_limit_cents is null then raise exception 'A published league cap is required before transferring a contracted driver' using errcode='23514'; end if;
    select coalesce(sum(contracts.cap_charge_cents),0) into destination_cap_cents
    from public.n26_contracts contracts
    where contracts.team_id=p_team_id
      and contracts.id <> current_contract.id
      and contracts.start_season <= season_row.season_number
      and contracts.end_season >= season_row.season_number
      and contracts.status in ('introductory','active');
    if destination_cap_cents + charge_cents > cap_limit_cents then
      raise exception 'Carrying this contract would exceed the destination team salary cap' using errcode='23514';
    end if;
    update public.n26_contracts
    set team_id=p_team_id,
        seat_assignment_id=inserted_assignment.id,
        loyalty_discount_bps=loyalty_discount,
        cap_charge_cents=charge_cents
    where id=current_contract.id;
    select id into trade_transaction_id
    from public.n26_transactions
    where season_id=p_season_id and driver_id=p_driver_id and transaction_type='trade'
    order by created_at desc limit 1;
    update public.n26_transactions set contract_id=current_contract.id where id=trade_transaction_id;
  end if;
  return inserted_assignment;
end;
$$;

revoke execute on function public.n26_transfer_driver_to_seat(uuid, uuid, uuid, text, boolean, boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.n26_transfer_driver_to_seat(uuid, uuid, uuid, text, boolean, boolean, boolean, text) to service_role;
