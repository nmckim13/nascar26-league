-- Publish official race results into a 48-hour appeal window before final
-- certification. Public pages can read published results, while ratings only
-- consume certified results.

alter table public.n26_season_races
  add column if not exists published_at timestamptz,
  add column if not exists appeal_ends_at timestamptz;

create or replace function public.n26_validate_race_ready(p_race_id uuid)
returns void
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  required_count integer;
  result_count integer;
begin
  select * into race_row from public.n26_season_races where id = p_race_id;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.status = 'voided' then
    raise exception 'A voided race cannot be published' using errcode = '42501';
  end if;
  if race_row.starters_count is null or race_row.starters_count < 1 then
    raise exception 'Starter count is required before publication' using errcode = '23514';
  end if;
  if race_row.race_type <> 'exhibition' and race_row.starters_count < 2 then
    raise exception 'A championship race needs at least two starters' using errcode = '23514';
  end if;
  if race_row.qualifying_status not in ('valid', 'canceled', 'voided') then
    raise exception 'Qualifying must be valid, canceled, or voided before publication' using errcode = '23514';
  end if;
  if race_row.qualifying_status = 'valid'
     and (race_row.qualifying_field_count is null or race_row.qualifying_field_count < 2) then
    raise exception 'A valid qualifying session needs at least two classified qualifiers' using errcode = '23514';
  end if;

  select count(*) into required_count
  from public.n26_season_entries entries
  where entries.season_id = race_row.season_id and entries.entry_status = 'full_time';
  select count(*) into result_count
  from public.n26_race_results results
  where results.race_id = race_row.id
    and exists (
      select 1 from public.n26_season_entries entries
      where entries.season_id = race_row.season_id
        and entries.driver_id = results.driver_id
        and entries.entry_status = 'full_time'
    );
  if result_count <> required_count then
    raise exception 'Every full-time driver needs a result row before publication' using errcode = '23514';
  end if;
  if race_row.qualifying_status = 'valid' and exists (
    select 1 from public.n26_season_entries entries
    where entries.season_id = race_row.season_id and entries.entry_status = 'full_time'
      and not exists (
        select 1 from public.n26_race_results results
        where results.race_id = race_row.id
          and results.driver_id = entries.driver_id
          and results.start_status <> 'dns'
          and results.qualifying_valid = true
          and results.qualifying_position is not null
      )
  ) then
    raise exception 'Valid qualifying data is missing for one or more starters' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.n26_race_results results
    where results.race_id = race_row.id and results.certification_status = 'superseded'
  ) then
    raise exception 'Superseded results must be corrected before publication' using errcode = '23514';
  end if;
end;
$$;

create or replace function public.n26_publish_race_results(
  p_race_id uuid,
  p_appeal_hours integer default 48
)
returns public.n26_season_races
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
begin
  if p_appeal_hours < 1 or p_appeal_hours > 168 then
    raise exception 'Appeal window must be between 1 and 168 hours' using errcode = '22023';
  end if;
  select * into race_row from public.n26_season_races where id = p_race_id for update;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.status <> 'open' or race_row.certification_status <> 'draft' then
    raise exception 'Only an open draft race can be published' using errcode = '42501';
  end if;
  perform public.n26_validate_race_ready(p_race_id);
  update public.n26_race_results
  set certification_status = 'published'
  where race_id = p_race_id;
  update public.n26_season_races
  set status = 'completed', certification_status = 'appeal_window',
      published_at = now(), appeal_ends_at = now() + make_interval(hours => p_appeal_hours)
  where id = p_race_id
  returning * into race_row;
  return race_row;
end;
$$;

create or replace function public.n26_finalize_race(p_race_id uuid)
returns public.n26_season_races
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
begin
  select * into race_row from public.n26_season_races where id = p_race_id for update;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.certification_status <> 'appeal_window' then
    raise exception 'Race must be in its appeal window before final certification' using errcode = '42501';
  end if;
  if race_row.appeal_ends_at is null or race_row.appeal_ends_at > now() then
    raise exception 'The race appeal window is still open' using errcode = '42501';
  end if;
  perform public.n26_validate_race_ready(p_race_id);
  update public.n26_race_results
  set certification_status = 'certified'
  where race_id = p_race_id;
  update public.n26_season_races
  set certification_status = 'certified'
  where id = p_race_id
  returning * into race_row;
  return race_row;
end;
$$;

-- Preserve the existing RPC name while removing the old one-click bypass.
create or replace function public.n26_certify_race(p_race_id uuid)
returns public.n26_season_races
language plpgsql
set search_path = public
as $$
begin
  return public.n26_finalize_race(p_race_id);
end;
$$;

revoke execute on function public.n26_validate_race_ready(uuid) from public, anon, authenticated;
revoke execute on function public.n26_publish_race_results(uuid, integer) from public, anon, authenticated;
revoke execute on function public.n26_finalize_race(uuid) from public, anon, authenticated;
revoke execute on function public.n26_certify_race(uuid) from public, anon, authenticated;
grant execute on function public.n26_publish_race_results(uuid, integer) to service_role;
grant execute on function public.n26_finalize_race(uuid) to service_role;
grant execute on function public.n26_certify_race(uuid) to service_role;
