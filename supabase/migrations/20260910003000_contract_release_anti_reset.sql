-- An early contract release blocks term discounts for the released driver and
-- releasing team in the immediately following season. The rule is enforced at
-- the table boundary so no signing path can bypass it.
create or replace function public.n26_validate_contract_release_anti_reset()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  signing_season_number integer;
begin
  if new.term_discount_bps = 0 then
    return new;
  end if;

  select season_number into signing_season_number
  from public.n26_seasons
  where id = new.season_id;

  if exists (
    select 1
    from public.n26_transactions transactions
    join public.n26_seasons release_seasons on release_seasons.id = transactions.season_id
    where transactions.transaction_type = 'release'
      and transactions.contract_id is not null
      and release_seasons.season_number = signing_season_number - 1
      and (transactions.driver_id = new.driver_id or transactions.from_team_id = new.team_id)
  ) then
    raise exception 'Term discounts are unavailable for a driver or releasing team in the season after an early contract release' using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists n26_contract_release_anti_reset_trigger on public.n26_contracts;
create trigger n26_contract_release_anti_reset_trigger
before insert on public.n26_contracts
for each row execute function public.n26_validate_contract_release_anti_reset();

revoke execute on function public.n26_validate_contract_release_anti_reset() from public, anon, authenticated;
