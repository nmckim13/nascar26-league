-- Validate the merged result set, including unchanged rows during corrections.

create or replace function public.n26_validate_race_result_integrity(
  p_race_id uuid,
  p_require_complete boolean default false
)
returns void
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  started_count integer;
  qualifying_count integer;
begin
  select * into race_row
  from public.n26_season_races
  where id = p_race_id;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;

  if exists (
    select 1
    from public.n26_race_results results
    where results.race_id = p_race_id
      and results.start_status <> 'dns'
    group by results.finish_position
    having count(*) > 1
  ) then
    raise exception 'Started drivers cannot share a finishing position' using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.n26_race_results results
    where results.race_id = p_race_id
      and results.qualifying_valid = true
    group by results.qualifying_position
    having count(*) > 1
  ) then
    raise exception 'Drivers cannot share a valid qualifying position' using errcode = '23514';
  end if;

  if not p_require_complete then
    return;
  end if;

  select count(*) into started_count
  from public.n26_race_results
  where race_id = p_race_id and start_status <> 'dns';
  if started_count <> race_row.starters_count then
    raise exception 'Starter count does not match the entered started results' using errcode = '23514';
  end if;

  if race_row.qualifying_status = 'valid' then
    select count(*) into qualifying_count
    from public.n26_race_results
    where race_id = p_race_id and qualifying_valid = true;
    if qualifying_count <> race_row.qualifying_field_count then
      raise exception 'Qualifying field count does not match the valid qualifying results' using errcode = '23514';
    end if;
  end if;
end;
$$;

create or replace function public.n26_deferred_result_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  perform public.n26_validate_race_result_integrity(coalesce(new.race_id, old.race_id), false);
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists n26_deferred_result_integrity_trigger on public.n26_race_results;
create constraint trigger n26_deferred_result_integrity_trigger
after insert or update or delete on public.n26_race_results
deferrable initially deferred
for each row execute function public.n26_deferred_result_integrity();

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

  perform public.n26_validate_race_result_integrity(p_race_id, true);

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

revoke execute on function public.n26_validate_race_result_integrity(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.n26_deferred_result_integrity() from public, anon, authenticated;
revoke execute on function public.n26_validate_race_ready(uuid) from public, anon, authenticated;
grant execute on function public.n26_validate_race_ready(uuid) to service_role;
