-- Create a permanent identity and optionally register it in a season atomically.

create or replace function public.n26_create_driver(
  p_display_name text,
  p_gamertag text default null,
  p_first_name text default null,
  p_last_name text default null,
  p_status text default 'active',
  p_season_id uuid default null,
  p_entry_status text default 'full_time'
)
returns public.n26_drivers
language plpgsql
set search_path = public
as $$
declare
  driver_row public.n26_drivers;
  season_status text;
begin
  if nullif(trim(p_display_name), '') is null then
    raise exception 'Display name is required' using errcode = '22023';
  end if;
  if p_status not in ('active', 'reserve') then
    raise exception 'Driver status must be active or reserve' using errcode = '23514';
  end if;
  if p_entry_status not in ('full_time', 'reserve') then
    raise exception 'Entry status must be full_time or reserve' using errcode = '23514';
  end if;
  if p_season_id is not null then
    select status into season_status from public.n26_seasons where id = p_season_id for update;
    if season_status is null or season_status not in ('draft', 'open') then
      raise exception 'Drivers can only be registered in a draft or open season' using errcode = '42501';
    end if;
  end if;

  insert into public.n26_drivers (display_name, gamertag, first_name, last_name, status)
  values (trim(p_display_name), nullif(trim(p_gamertag), ''), nullif(trim(p_first_name), ''), nullif(trim(p_last_name), ''), p_status)
  returning * into driver_row;

  if p_season_id is not null then
    insert into public.n26_season_entries (season_id, driver_id, entry_status)
    values (p_season_id, driver_row.id, p_entry_status);
  end if;
  return driver_row;
end;
$$;

revoke execute on function public.n26_create_driver(text, text, text, text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.n26_create_driver(text, text, text, text, text, uuid, text) to service_role;
