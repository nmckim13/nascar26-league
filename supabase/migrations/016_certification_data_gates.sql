-- A race cannot become official while required source data is missing.

create or replace function public.n26_certify_race(p_race_id uuid)
returns public.n26_season_races
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  required_count integer;
  result_count integer;
begin
  select * into race_row
  from public.n26_season_races
  where id = p_race_id
  for update;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.status = 'voided' then
    raise exception 'A voided race cannot be certified' using errcode = '42501';
  end if;
  if race_row.starters_count is null or race_row.starters_count < 1 then
    raise exception 'Starter count is required before certification' using errcode = '23514';
  end if;
  if race_row.race_type <> 'exhibition' and race_row.starters_count < 2 then
    raise exception 'A championship race needs at least two starters' using errcode = '23514';
  end if;
  if race_row.qualifying_status not in ('valid', 'canceled', 'voided') then
    raise exception 'Qualifying must be valid, canceled, or voided before certification' using errcode = '23514';
  end if;
  if race_row.qualifying_status = 'valid'
     and (race_row.qualifying_field_count is null or race_row.qualifying_field_count < 2) then
    raise exception 'A valid qualifying session needs at least two classified qualifiers' using errcode = '23514';
  end if;
  if race_row.qualifying_status = 'valid' and exists (
    select 1 from public.n26_season_entries entries
    where entries.season_id = race_row.season_id and entries.entry_status = 'full_time'
      and not exists (
        select 1 from public.n26_race_results results
        where results.race_id = race_row.id and results.driver_id = entries.driver_id
          and results.qualifying_valid = true and results.qualifying_position is not null
      )
  ) then
    raise exception 'Valid qualifying data is missing for one or more full-time drivers' using errcode = '23514';
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
    raise exception 'Every full-time driver needs a result row before certification' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.n26_race_results results
    where results.race_id = race_row.id and results.certification_status = 'superseded'
  ) then
    raise exception 'Superseded results must be corrected before certification' using errcode = '23514';
  end if;

  update public.n26_race_results
  set certification_status = 'certified'
  where race_id = race_row.id;
  update public.n26_season_races
  set status = 'completed', certification_status = 'certified'
  where id = race_row.id
  returning * into race_row;
  return race_row;
end;
$$;

revoke execute on function public.n26_certify_race(uuid) from public, anon, authenticated;
grant execute on function public.n26_certify_race(uuid) to service_role;
