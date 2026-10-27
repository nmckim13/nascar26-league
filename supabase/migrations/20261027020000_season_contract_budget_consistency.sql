-- Match the published rulebook: 60-credit introductory contracts, a 240-credit
-- inaugural cap, and a 240-credit floor for future equal caps. Preserve explicit
-- ruleset caps, existing contracts, and all unrelated signing/transfer guards.
-- As with the starting-OVR migration, update only the obsolete authority values.
do $do$
declare
  change_row record;
  definition text;
begin
  for change_row in
    select * from (values
      ('public.n26_create_contract(uuid,uuid,uuid,uuid,numeric,integer,integer,integer)',
       'then 15500', 'then 24000'),
      ('public.n26_transfer_driver_to_seat(uuid,uuid,uuid,text,boolean,boolean,boolean,text)',
       'then 15500', 'then 24000'),
      ('public.n26_create_draft_season(uuid,text,text,integer)',
       'p_cap_credits < 155', 'p_cap_credits is null or p_cap_credits < 240'),
      ('public.n26_create_draft_season(uuid,text,text,integer)',
       'at least 155', 'at least 240')
    ) as changes(signature, old_text, new_text)
  loop
    select pg_get_functiondef(change_row.signature::regprocedure) into definition;
    if strpos(definition, change_row.old_text) = 0 then
      raise exception 'Expected contract-budget definition not found in %', change_row.signature;
    end if;
    execute replace(definition, change_row.old_text, change_row.new_text);
  end loop;
end;
$do$;

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
  contracts_created_count integer := 0;
  expected_driver_count integer;
  expected_team_size integer;
  cap_limit_cents integer;
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

  select count(distinct contracts.driver_id) into current_contract_count
  from public.n26_contracts contracts
  where contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory', 'active');
  if season_row.season_number = 1 then
    contracts_created_count := expected_driver_count - current_contract_count;
    for assignment_row in
      select assignments.*
      from public.n26_seat_assignments assignments
      where assignments.season_id = p_season_id
        and assignments.assignment_status = 'active'
        and not exists (
          select 1 from public.n26_contracts contracts
          where contracts.driver_id = assignments.driver_id
            and contracts.start_season <= season_row.season_number
            and contracts.end_season >= season_row.season_number
            and contracts.status in ('introductory', 'active')
        )
      order by assignments.id
    loop
      perform public.n26_create_contract(
        p_season_id,
        assignment_row.driver_id,
        assignment_row.team_id,
        assignment_row.id,
        60,
        1,
        0,
        0
      );
    end loop;
  end if;

  select count(distinct contracts.driver_id) into current_contract_count
  from public.n26_contracts contracts
  where contracts.start_season <= season_row.season_number
    and contracts.end_season >= season_row.season_number
    and contracts.status in ('introductory', 'active');
  if current_contract_count <> expected_driver_count then
    raise exception 'Every full-time driver needs exactly one current contract before publishing' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.n26_season_entries entries
    where entries.season_id = p_season_id
      and entries.entry_status = 'full_time'
      and (
        (select count(*)
         from public.n26_contracts contracts
         where contracts.driver_id = entries.driver_id
           and contracts.start_season <= season_row.season_number
           and contracts.end_season >= season_row.season_number
           and contracts.status in ('introductory', 'active')) <> 1
        or not exists (
          select 1
          from public.n26_seat_assignments assignments
          join public.n26_contracts contracts
            on contracts.driver_id = assignments.driver_id
           and contracts.team_id = assignments.team_id
           and contracts.start_season <= season_row.season_number
           and contracts.end_season >= season_row.season_number
           and contracts.status in ('introductory', 'active')
          where assignments.season_id = p_season_id
            and assignments.driver_id = entries.driver_id
            and assignments.assignment_status = 'active'
        )
      )
  ) then
    raise exception 'Every full-time driver needs one contract matching the active team before publishing' using errcode = '23514';
  end if;

  cap_limit_cents := case
    when ruleset_row.config ? 'cap_credits' then (ruleset_row.config->>'cap_credits')::integer * 100
    when season_row.season_number = 1 then 24000
    else null
  end;
  if cap_limit_cents is null then
    raise exception 'A published league cap is required before publishing this season' using errcode = '23514';
  end if;
  if exists (
    select 1 from public.n26_contracts contracts
    where contracts.start_season <= season_row.season_number
      and contracts.end_season >= season_row.season_number
      and contracts.status in ('introductory', 'active')
    group by contracts.team_id
    having sum(contracts.cap_charge_cents) > cap_limit_cents
  ) then
    raise exception 'The roster exceeds the published team salary cap' using errcode = '23514';
  end if;

  update public.n26_seasons
  set status = 'open', roster_lock_at = now()
  where id = p_season_id
  returning * into updated_season;

  return jsonb_build_object(
    'season', to_jsonb(updated_season),
    'contracts_created', contracts_created_count
  );
end;
$$;

revoke execute on function public.n26_publish_season(uuid) from public, anon, authenticated;
grant execute on function public.n26_publish_season(uuid) to service_role;
