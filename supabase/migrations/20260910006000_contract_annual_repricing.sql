-- Reprice carried contracts from the newly certified prior-season OVR while
-- preserving their original term discount. Loyalty is recalculated each year.
create or replace function public.n26_reprice_contracts_for_season(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  previous_season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  contract_row public.n26_contracts;
  expected_rating numeric;
  loyalty_eligible boolean;
  loyalty_discount integer;
  charge_cents integer;
  cap_limit_cents integer;
  repriced_count integer := 0;
begin
  select * into season_row from public.n26_seasons where id=p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode='02000'; end if;
  if season_row.season_number = 1 then return jsonb_build_object('season_id', p_season_id, 'repriced_contracts', 0); end if;
  select * into previous_season_row from public.n26_seasons where season_number=season_row.season_number-1;
  if previous_season_row.id is null or previous_season_row.status not in ('certified','archived') then
    raise exception 'The prior season must be certified before repricing contracts' using errcode='42501';
  end if;
  select * into ruleset_row from public.n26_rulesets where id=season_row.ruleset_id;
  cap_limit_cents := case when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100 else null end;
  if cap_limit_cents is null then raise exception 'A published league cap is required before repricing contracts' using errcode='23514'; end if;

  for contract_row in
    select * from public.n26_contracts
    where start_season <= season_row.season_number
      and end_season >= season_row.season_number
      and status in ('active','introductory')
    order by id
    for update
  loop
    select snapshots.official_ovr into expected_rating
    from public.n26_rating_snapshots snapshots
    where snapshots.season_id=previous_season_row.id
      and snapshots.driver_id=contract_row.driver_id
      and snapshots.certification_status='certified'
    limit 1;
    if expected_rating is null then
      raise exception 'A carried contract is missing the driver''s certified prior-season OVR' using errcode='23514';
    end if;

    select exists (
      select 1
      from public.n26_season_entries entries
      join public.n26_seat_assignments assignments
        on assignments.season_id=entries.season_id
       and assignments.driver_id=entries.driver_id
       and assignments.team_id=contract_row.team_id
       and assignments.assignment_status='active'
      where entries.season_id=previous_season_row.id
        and entries.driver_id=contract_row.driver_id
        and entries.entry_status='full_time'
        and not exists (
          select 1 from public.n26_seat_assignments other_assignments
          where other_assignments.season_id=previous_season_row.id
            and other_assignments.driver_id=contract_row.driver_id
            and other_assignments.team_id<>contract_row.team_id
            and other_assignments.assignment_status in ('active','transferred','ended')
        )
    ) into loyalty_eligible;
    loyalty_discount := case when loyalty_eligible then 100 else 0 end;
    charge_cents := ceil((expected_rating * 100 * (10000 - contract_row.term_discount_bps - loyalty_discount)) / 10000);
    update public.n26_contracts
    set base_rating=expected_rating,
        loyalty_discount_bps=loyalty_discount,
        cap_charge_cents=charge_cents
    where id=contract_row.id;
    repriced_count := repriced_count + 1;
  end loop;

  if exists (
    select 1 from public.n26_contracts contracts
    where contracts.start_season <= season_row.season_number
      and contracts.end_season >= season_row.season_number
      and contracts.status in ('active','introductory')
    group by contracts.team_id
    having coalesce(sum(contracts.cap_charge_cents),0) > cap_limit_cents
  ) then
    raise exception 'Annual contract repricing puts a team over the published salary cap' using errcode='23514';
  end if;
  return jsonb_build_object('season_id', p_season_id, 'repriced_contracts', repriced_count);
end;
$$;

revoke execute on function public.n26_reprice_contracts_for_season(uuid) from public, anon, authenticated;
grant execute on function public.n26_reprice_contracts_for_season(uuid) to service_role;

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
  perform public.n26_reprice_contracts_for_season(p_season_id);
  update public.n26_seasons
  set contract_market_status='renewals', renewal_window_ends_at=now()+make_interval(hours=>p_renewal_hours), free_agency_closes_at=now()+make_interval(hours=>p_renewal_hours,days=>p_free_agency_days)
  where id=p_season_id returning * into season_row;
  return season_row;
end;
$$;

revoke execute on function public.n26_open_contract_market(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.n26_open_contract_market(uuid, integer, integer) to service_role;

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
  if not coalesce(p_driver_consented, false) or not coalesce(p_from_team_consented, false) or not coalesce(p_to_team_consented, false) then
    raise exception 'All three transfer consents are required' using errcode = '42501';
  end if;
  select * into season_row from public.n26_seasons where id=p_season_id for update;
  if season_row.id is null or season_row.status not in ('draft','open') then raise exception 'Roster changes are only allowed for draft or open seasons' using errcode='42501'; end if;
  if season_row.season_number > 1 then perform public.n26_reprice_contracts_for_season(p_season_id); end if;
  select * into current_assignment from public.n26_seat_assignments where season_id=p_season_id and driver_id=p_driver_id and assignment_status='active' order by starts_at desc limit 1 for update;
  if current_assignment.id is null then raise exception 'A transfer requires an existing active seat; use initial assignment instead' using errcode='23514'; end if;
  select * into current_contract
  from public.n26_contracts
  where driver_id=p_driver_id and team_id=current_assignment.team_id
    and start_season <= season_row.season_number and end_season >= season_row.season_number
    and status in ('introductory','active')
  order by start_season desc, created_at desc limit 1 for update;
  insert into public.n26_transaction_consents (
    season_id, driver_id, from_team_id, to_team_id, from_car_number, to_car_number,
    driver_consented, from_team_consented, to_team_consented, notes
  ) values (p_season_id,p_driver_id,current_assignment.team_id,p_team_id,current_assignment.car_number,p_car_number,true,true,true,nullif(trim(p_notes),''));
  select * into inserted_assignment from public.n26_assign_driver_to_seat(p_season_id,p_driver_id,p_team_id,p_car_number,true);
  if current_contract.id is not null then
    loyalty_discount := case when current_contract.team_id = p_team_id then current_contract.loyalty_discount_bps else 0 end;
    charge_cents := ceil((current_contract.base_rating * 100 * (10000 - current_contract.term_discount_bps - loyalty_discount)) / 10000);
    select * into ruleset_row from public.n26_rulesets where id=season_row.ruleset_id;
    cap_limit_cents := case when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100 when season_row.season_number=1 then 15500 else null end;
    if cap_limit_cents is null then raise exception 'A published league cap is required before transferring a contracted driver' using errcode='23514'; end if;
    select coalesce(sum(contracts.cap_charge_cents),0) into destination_cap_cents
    from public.n26_contracts contracts
    where contracts.team_id=p_team_id and contracts.id<>current_contract.id
      and contracts.start_season <= season_row.season_number and contracts.end_season >= season_row.season_number
      and contracts.status in ('introductory','active');
    if destination_cap_cents + charge_cents > cap_limit_cents then raise exception 'Carrying this contract would exceed the destination team salary cap' using errcode='23514'; end if;
    update public.n26_contracts set team_id=p_team_id, seat_assignment_id=inserted_assignment.id, loyalty_discount_bps=loyalty_discount, cap_charge_cents=charge_cents where id=current_contract.id;
    select id into trade_transaction_id from public.n26_transactions where season_id=p_season_id and driver_id=p_driver_id and transaction_type='trade' order by created_at desc limit 1;
    update public.n26_transactions set contract_id=current_contract.id where id=trade_transaction_id;
  end if;
  return inserted_assignment;
end;
$$;

revoke execute on function public.n26_transfer_driver_to_seat(uuid, uuid, uuid, text, boolean, boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.n26_transfer_driver_to_seat(uuid, uuid, uuid, text, boolean, boolean, boolean, text) to service_role;
