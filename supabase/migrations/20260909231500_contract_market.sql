-- Make the renewal window and free-agency period explicit for future seasons.

alter table public.n26_seasons
  add column if not exists contract_market_status text not null default 'closed',
  add column if not exists renewal_window_ends_at timestamptz,
  add column if not exists free_agency_closes_at timestamptz;

alter table public.n26_seasons
  drop constraint if exists n26_seasons_contract_market_status_check;

alter table public.n26_seasons
  add constraint n26_seasons_contract_market_status_check
  check (contract_market_status in ('closed', 'renewals', 'free_agency'));

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
  if p_renewal_hours < 1 or p_free_agency_days < 1 then
    raise exception 'Contract market windows must be positive' using errcode = '23514';
  end if;

  select * into season_row
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.season_number = 1 then
    raise exception 'Season 1 uses introductory contracts and has no free-agency market' using errcode = '42501';
  end if;
  if season_row.status <> 'draft' then
    raise exception 'The contract market can only open for a draft season' using errcode = '42501';
  end if;
  if season_row.contract_market_status <> 'closed' then
    raise exception 'The contract market is already open' using errcode = '23505';
  end if;

  select * into previous_season_row
  from public.n26_seasons
  where season_number = season_row.season_number - 1;
  if previous_season_row.id is null or previous_season_row.status not in ('certified', 'archived') then
    raise exception 'The prior season must be certified before opening contracts' using errcode = '42501';
  end if;

  update public.n26_seasons
  set contract_market_status = 'renewals',
      renewal_window_ends_at = now() + make_interval(hours => p_renewal_hours),
      free_agency_closes_at = now() + make_interval(hours => p_renewal_hours, days => p_free_agency_days)
  where id = p_season_id
  returning * into season_row;
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
  if new.start_season = 1 then
    return new;
  end if;

  select * into season_row
  from public.n26_seasons
  where id = new.season_id;
  if season_row.contract_market_status = 'closed'
     or season_row.renewal_window_ends_at is null
     or season_row.free_agency_closes_at is null then
    raise exception 'Open the contract market before signing future-season contracts' using errcode = '42501';
  end if;
  if now() > season_row.free_agency_closes_at then
    raise exception 'The free-agency period has closed for this season' using errcode = '42501';
  end if;

  if now() <= season_row.renewal_window_ends_at then
    select * into previous_season_row
    from public.n26_seasons
    where season_number = season_row.season_number - 1;
    if not exists (
      select 1
      from public.n26_contracts previous_contracts
      where previous_contracts.season_id = previous_season_row.id
        and previous_contracts.driver_id = new.driver_id
        and previous_contracts.team_id = new.team_id
        and previous_contracts.end_season >= previous_season_row.season_number
        and previous_contracts.status in ('expired', 'active', 'introductory')
    ) then
      raise exception 'Only the incumbent team may sign this driver during the renewal window' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists n26_contract_market_trigger on public.n26_contracts;
create trigger n26_contract_market_trigger
before insert on public.n26_contracts
for each row execute function public.n26_validate_contract_market();

revoke execute on function public.n26_open_contract_market(uuid, integer, integer) from public, anon, authenticated;
grant execute on function public.n26_open_contract_market(uuid, integer, integer) to service_role;
