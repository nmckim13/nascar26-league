-- Contracts retain the exact seat relationship they were signed against.

alter table public.n26_contracts
  add column if not exists seat_assignment_id uuid references public.n26_seat_assignments(id);

create index if not exists n26_contracts_seat_assignment_idx
  on public.n26_contracts (seat_assignment_id);

alter table public.n26_contracts
  alter column seat_assignment_id set not null;

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
  seat_row public.n26_seat_assignments;
  contract_row public.n26_contracts;
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

  select * into ruleset_row
  from public.n26_rulesets
  where id = season_row.ruleset_id;

  if p_original_term_seasons not between 1 and 3 then
    raise exception 'Contract term must be 1, 2, or 3 seasons' using errcode = '23514';
  end if;
  if p_term_discount_bps not in (0, 200, 400)
     or p_loyalty_discount_bps not in (0, 100) then
    raise exception 'Contract discounts are outside the published options' using errcode = '23514';
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
    select 1 from public.n26_season_entries entries
    where entries.season_id = p_season_id
      and entries.driver_id = p_driver_id
      and entries.entry_status = 'full_time'
  ) then
    raise exception 'Driver must be a full-time season entry before signing' using errcode = '23514';
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

  charge_cents := ceil((p_rating * 100 * (10000 - total_discount_bps)) / 10000);
  cap_limit_cents := case
    when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100
    when season_row.season_number = 1 then 15500
    else null
  end;
  if cap_limit_cents is null then
    raise exception 'A published league cap is required before signing contracts' using errcode = '23514';
  end if;

  select count(*) into current_contract_count
  from public.n26_contracts contracts
  where contracts.season_id = p_season_id
    and contracts.team_id = p_team_id
    and contracts.status in ('introductory', 'active');
  select coalesce(sum(contracts.cap_charge_cents), 0) into current_cap_cents
  from public.n26_contracts contracts
  where contracts.season_id = p_season_id
    and contracts.team_id = p_team_id
    and contracts.status in ('introductory', 'active');
  if current_contract_count >= 3 then
    raise exception 'Team already has three current contracts' using errcode = '23514';
  end if;
  if current_cap_cents + charge_cents > cap_limit_cents then
    raise exception 'Contract would exceed the team salary cap' using errcode = '23514';
  end if;

  insert into public.n26_contracts (
    season_id, driver_id, team_id, seat_assignment_id,
    start_season, end_season, original_term_seasons,
    term_discount_bps, loyalty_discount_bps, cap_charge_cents, status
  ) values (
    p_season_id, p_driver_id, p_team_id, p_seat_assignment_id,
    season_row.season_number,
    season_row.season_number + p_original_term_seasons - 1,
    p_original_term_seasons,
    p_term_discount_bps,
    p_loyalty_discount_bps,
    charge_cents,
    case when season_row.season_number = 1 then 'introductory' else 'active' end
  ) returning * into contract_row;
  return contract_row;
end;
$$;

revoke execute on function public.n26_create_contract(uuid, uuid, uuid, uuid, numeric, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.n26_create_contract(uuid, uuid, uuid, uuid, numeric, integer, integer, integer) to service_role;
