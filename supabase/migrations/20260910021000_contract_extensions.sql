-- Add offseason-only incumbent extensions without rewriting the original
-- agreement. The extension is a linked contract that starts after the prior
-- term and can never extend beyond three seasons from the current offseason.

alter table public.n26_contracts
  add column if not exists extension_of_contract_id uuid references public.n26_contracts(id);

create index if not exists n26_contracts_extension_idx
  on public.n26_contracts (extension_of_contract_id);

create or replace function public.n26_log_contract_signing()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  insert into public.n26_transactions (
    season_id, driver_id, to_team_id, transaction_type, contract_id, notes
  ) values (
    new.season_id,
    new.driver_id,
    new.team_id,
    case when new.extension_of_contract_id is null then 'signing' else 'renewal' end,
    new.id,
    format('%s for %s season(s) at %s credits per season',
      case when new.extension_of_contract_id is null then 'Contract signed' else 'Contract extended' end,
      new.original_term_seasons,
      to_char(new.cap_charge_cents / 100.0, 'FM999999990.00'))
  );
  return new;
end;
$$;

create or replace function public.n26_extend_contract(
  p_season_id uuid,
  p_contract_id uuid,
  p_additional_term_seasons integer
)
returns public.n26_contracts
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  previous_season_row public.n26_seasons;
  current_contract public.n26_contracts;
  active_seat public.n26_seat_assignments;
  ruleset_row public.n26_rulesets;
  extension_row public.n26_contracts;
  expected_rating numeric;
  loyalty_eligible boolean;
  term_discount_bps_value integer;
  loyalty_discount_bps_value integer;
  charge_cents integer;
  extension_start integer;
  extension_end integer;
begin
  if p_additional_term_seasons not between 1 and 3 then
    raise exception 'Contract extension must add 1, 2, or 3 seasons' using errcode = '23514';
  end if;

  select * into season_row
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.season_number = 1
     or season_row.status <> 'draft'
     or season_row.contract_market_status <> 'renewals'
     or season_row.renewal_window_ends_at is null
     or now() > season_row.renewal_window_ends_at then
    raise exception 'Extensions are available only during the incumbent renewal window' using errcode = '42501';
  end if;

  select * into current_contract
  from public.n26_contracts
  where id = p_contract_id
  for update;
  if current_contract.id is null then
    raise exception 'Contract not found' using errcode = '02000';
  end if;
  if current_contract.status not in ('introductory', 'active')
     or current_contract.start_season > season_row.season_number
     or current_contract.end_season < season_row.season_number then
    raise exception 'Only a current active contract can be extended' using errcode = '23514';
  end if;
  if current_contract.end_season <= season_row.season_number then
    raise exception 'A contract cannot be extended during its final season' using errcode = '23514';
  end if;

  extension_start := current_contract.end_season + 1;
  extension_end := current_contract.end_season + p_additional_term_seasons;
  if extension_end > season_row.season_number + 2 then
    raise exception 'An extension cannot extend beyond three seasons from the current offseason' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_contracts contracts
    where contracts.driver_id = current_contract.driver_id
      and contracts.status in ('introductory', 'active')
      and contracts.start_season <= extension_end
      and contracts.end_season >= extension_start
  ) then
    raise exception 'The driver already has a contract covering the proposed extension seasons' using errcode = '23505';
  end if;

  select * into active_seat
  from public.n26_seat_assignments assignments
  where assignments.season_id = p_season_id
    and assignments.driver_id = current_contract.driver_id
    and assignments.team_id = current_contract.team_id
    and assignments.assignment_status = 'active'
  order by assignments.starts_at desc
  limit 1
  for update;
  if active_seat.id is null then
    raise exception 'The driver must still hold the incumbent team seat in the draft' using errcode = '23514';
  end if;

  select * into previous_season_row
  from public.n26_seasons
  where season_number = season_row.season_number - 1;
  if previous_season_row.id is null or previous_season_row.status not in ('certified', 'archived') then
    raise exception 'The prior season must be certified before extending a contract' using errcode = '42501';
  end if;
  select snapshots.official_ovr into expected_rating
  from public.n26_rating_snapshots snapshots
  where snapshots.season_id = previous_season_row.id
    and snapshots.driver_id = current_contract.driver_id
    and snapshots.certification_status = 'certified'
  limit 1;
  if expected_rating is null then
    raise exception 'The driver needs a certified prior-season OVR before extension' using errcode = '23514';
  end if;

  select exists (
    select 1
    from public.n26_season_entries entries
    join public.n26_seat_assignments assignments
      on assignments.season_id = entries.season_id
     and assignments.driver_id = entries.driver_id
     and assignments.team_id = current_contract.team_id
     and assignments.assignment_status = 'active'
    where entries.season_id = previous_season_row.id
      and entries.driver_id = current_contract.driver_id
      and entries.entry_status = 'full_time'
      and not exists (
        select 1
        from public.n26_seat_assignments other_assignments
        where other_assignments.season_id = previous_season_row.id
          and other_assignments.driver_id = current_contract.driver_id
          and other_assignments.team_id <> current_contract.team_id
          and other_assignments.assignment_status in ('active', 'transferred', 'ended')
      )
  ) into loyalty_eligible;

  term_discount_bps_value := case p_additional_term_seasons when 1 then 0 when 2 then 200 when 3 then 400 end;
  loyalty_discount_bps_value := case when loyalty_eligible then 100 else 0 end;
  charge_cents := ceil((expected_rating * 100 * (10000 - term_discount_bps_value - loyalty_discount_bps_value)) / 10000);

  select * into ruleset_row
  from public.n26_rulesets
  where id = season_row.ruleset_id;
  if not (ruleset_row.config ? 'cap_credits') then
    raise exception 'A published league cap is required before extending a contract' using errcode = '23514';
  end if;

  insert into public.n26_contracts (
    season_id, driver_id, team_id, seat_assignment_id,
    start_season, end_season, original_term_seasons,
    term_discount_bps, loyalty_discount_bps, cap_charge_cents,
    base_rating, status, extension_of_contract_id
  ) values (
    p_season_id, current_contract.driver_id, current_contract.team_id, active_seat.id,
    extension_start, extension_end, p_additional_term_seasons,
    term_discount_bps_value, loyalty_discount_bps_value, charge_cents,
    expected_rating, 'active', current_contract.id
  ) returning * into extension_row;

  return extension_row;
end;
$$;

revoke execute on function public.n26_extend_contract(uuid, uuid, integer) from public, anon, authenticated;
grant execute on function public.n26_extend_contract(uuid, uuid, integer) to service_role;
