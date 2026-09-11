-- Complete the contract audit trail and expose safe offseason lifecycle actions.

alter table public.n26_contracts
  add column if not exists released_at timestamptz,
  add column if not exists release_reason text,
  add column if not exists expired_at timestamptz;

alter table public.n26_transactions
  drop constraint if exists n26_transactions_transaction_type_check;

alter table public.n26_transactions
  add constraint n26_transactions_transaction_type_check
  check (transaction_type in ('signing', 'renewal', 'trade', 'release', 'expiration', 'withdrawal', 'correction'));

alter table public.n26_transactions
  add column if not exists contract_id uuid references public.n26_contracts(id);

create index if not exists n26_transactions_contract_idx
  on public.n26_transactions (contract_id, effective_at desc);

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
    'signing',
    new.id,
    format('Contract signed for %s season(s) at %s credits per season',
      new.original_term_seasons,
      to_char(new.cap_charge_cents / 100.0, 'FM999999990.00'))
  );
  return new;
end;
$$;

drop trigger if exists n26_contract_signing_transaction_trigger on public.n26_contracts;
create trigger n26_contract_signing_transaction_trigger
after insert on public.n26_contracts
for each row execute function public.n26_log_contract_signing();

create or replace function public.n26_release_contract(
  p_contract_id uuid,
  p_reason text default null
)
returns public.n26_contracts
language plpgsql
set search_path = public
as $$
declare
  contract_row public.n26_contracts;
  season_row public.n26_seasons;
begin
  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A release reason is required' using errcode = '23514';
  end if;

  select * into contract_row
  from public.n26_contracts
  where id = p_contract_id
  for update;
  if contract_row.id is null then
    raise exception 'Contract not found' using errcode = '02000';
  end if;

  select * into season_row
  from public.n26_seasons
  where id = contract_row.season_id
  for update;
  if season_row.status not in ('draft', 'open')
     or (season_row.status = 'open' and season_row.roster_lock_at is not null) then
    raise exception 'Contracts can only be released before roster lock' using errcode = '42501';
  end if;
  if contract_row.status not in ('introductory', 'active') then
    raise exception 'Only a current contract can be released' using errcode = '23514';
  end if;

  update public.n26_contracts
  set status = 'released', released_at = now(), release_reason = trim(p_reason)
  where id = p_contract_id
  returning * into contract_row;

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, transaction_type, contract_id, notes
  ) values (
    contract_row.season_id,
    contract_row.driver_id,
    contract_row.team_id,
    'release',
    contract_row.id,
    trim(p_reason)
  );

  return contract_row;
end;
$$;

create or replace function public.n26_expire_contracts(
  p_season_id uuid
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  contract_row public.n26_contracts;
  expired_count integer := 0;
begin
  select * into season_row
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.status not in ('certified', 'archived') then
    raise exception 'Contracts can only expire after season certification' using errcode = '42501';
  end if;

  for contract_row in
    select *
    from public.n26_contracts
    where season_id = p_season_id
      and end_season <= season_row.season_number
      and status in ('introductory', 'active')
    for update
  loop
    update public.n26_contracts
    set status = 'expired', expired_at = now()
    where id = contract_row.id;

    insert into public.n26_transactions (
      season_id, driver_id, from_team_id, transaction_type, contract_id, notes
    ) values (
      contract_row.season_id,
      contract_row.driver_id,
      contract_row.team_id,
      'expiration',
      contract_row.id,
      format('Contract expired after Season %s', season_row.season_number)
    );
    expired_count := expired_count + 1;
  end loop;

  return jsonb_build_object('season_id', p_season_id, 'expired_contracts', expired_count);
end;
$$;

revoke execute on function public.n26_release_contract(uuid, text) from public, anon, authenticated;
revoke execute on function public.n26_expire_contracts(uuid) from public, anon, authenticated;
grant execute on function public.n26_release_contract(uuid, text) to service_role;
grant execute on function public.n26_expire_contracts(uuid) to service_role;
