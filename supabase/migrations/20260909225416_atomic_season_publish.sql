-- Publish a season atomically. Season 1 introductory contracts are created
-- here so a published roster can never be missing its required contracts.

create or replace function public.n26_publish_season(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  full_time_count integer;
  active_seat_count integer;
  current_contract_count integer;
  expected_driver_count integer;
  expected_team_size integer;
  assignment_row record;
  updated_season public.n26_seasons;
begin
  select seasons.* into season_row
  from public.n26_seasons seasons
  where seasons.id = p_season_id
  for update;
  if season_row.id is null then
    raise exception 'Season not found' using errcode = '02000';
  end if;
  if season_row.status <> 'draft' then
    raise exception 'Only a draft season can be published' using errcode = '42501';
  end if;

  select rulesets.* into ruleset_row
  from public.n26_rulesets rulesets
  where rulesets.id = season_row.ruleset_id;
  if coalesce(ruleset_row.config->>'points_schedule_status', '') <> 'approved' then
    raise exception 'The 24-position points schedule must be approved before publishing' using errcode = '23514';
  end if;
  expected_driver_count := ruleset_row.driver_count;
  expected_team_size := ruleset_row.team_size;

  select count(*) into full_time_count
  from public.n26_season_entries
  where season_id = p_season_id and entry_status = 'full_time';
  if full_time_count <> expected_driver_count then
    raise exception 'Publishing requires % full-time drivers', expected_driver_count using errcode = '23514';
  end if;

  select count(*) into active_seat_count
  from public.n26_seat_assignments assignments
  join public.n26_season_entries entries
    on entries.season_id = assignments.season_id
   and entries.driver_id = assignments.driver_id
   and entries.entry_status = 'full_time'
  where assignments.season_id = p_season_id
    and assignments.assignment_status = 'active';
  if active_seat_count <> expected_driver_count then
    raise exception 'Publishing requires % active full-time seats', expected_driver_count using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_season_entries entries
    where entries.season_id = p_season_id
      and entries.entry_status = 'full_time'
      and not exists (
        select 1 from public.n26_seat_assignments assignments
        where assignments.season_id = p_season_id
          and assignments.driver_id = entries.driver_id
          and assignments.assignment_status = 'active'
      )
  ) then
    raise exception 'Every full-time driver must have an active seat' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_seat_assignments assignments
    where assignments.season_id = p_season_id
      and assignments.assignment_status = 'active'
      and not exists (
        select 1 from public.n26_season_entries entries
        where entries.season_id = p_season_id
          and entries.driver_id = assignments.driver_id
          and entries.entry_status = 'full_time'
      )
  ) then
    raise exception 'Reserve or inactive entries cannot occupy a full-time seat at publish' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_teams teams
    left join public.n26_seat_assignments assignments
      on assignments.team_id = teams.id
     and assignments.season_id = p_season_id
     and assignments.assignment_status = 'active'
    where teams.status = 'active'
    group by teams.id, teams.seat_limit
    having count(assignments.id) <> expected_team_size
  ) then
    raise exception 'Every active team must have exactly % seats at publish', expected_team_size using errcode = '23514';
  end if;

  select count(*) into current_contract_count
  from public.n26_contracts
  where season_id = p_season_id and status in ('introductory', 'active');
  if season_row.season_number = 1 then
    for assignment_row in
      select assignments.*
      from public.n26_seat_assignments assignments
      where assignments.season_id = p_season_id
        and assignments.assignment_status = 'active'
        and not exists (
          select 1 from public.n26_contracts contracts
          where contracts.season_id = p_season_id
            and contracts.driver_id = assignments.driver_id
            and contracts.status in ('introductory', 'active')
        )
      order by assignments.id
    loop
      perform public.n26_create_contract(
        p_season_id,
        assignment_row.driver_id,
        assignment_row.team_id,
        assignment_row.id,
        50,
        1,
        0,
        0
      );
    end loop;
  elsif current_contract_count <> expected_driver_count then
    raise exception 'Every full-time driver needs a current contract before publishing' using errcode = '23514';
  end if;

  select * into updated_season
  from public.n26_seasons
  where id = p_season_id;
  update public.n26_seasons
  set status = 'open', roster_lock_at = now()
  where id = p_season_id
  returning * into updated_season;

  return jsonb_build_object(
    'season', to_jsonb(updated_season),
    'contracts_created', case when season_row.season_number = 1 then expected_driver_count - current_contract_count else 0 end
  );
end;
$$;

revoke execute on function public.n26_publish_season(uuid) from public, anon, authenticated;
grant execute on function public.n26_publish_season(uuid) to service_role;
