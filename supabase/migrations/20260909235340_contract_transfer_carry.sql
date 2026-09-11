-- Carry an active multi-season contract when an attested roster transfer
-- changes the driver's destination team or seat.

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
