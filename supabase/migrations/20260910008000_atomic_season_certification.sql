-- Final rating and season certification must be atomic database transitions.
create or replace function public.n26_certify_ratings(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  full_time_count integer;
  certified_race_count integer;
  provisional_count integer;
  certified_count integer;
begin
  select * into season_row from public.n26_seasons where id=p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode='02000'; end if;
  if season_row.status not in ('open','in_progress','appeal_window') then
    raise exception 'Ratings can only be certified for an active season' using errcode='42501';
  end if;
  select * into ruleset_row from public.n26_rulesets where id=season_row.ruleset_id;
  if coalesce(ruleset_row.config->>'points_schedule_status','') <> 'approved' then
    raise exception 'The points schedule must be approved before certifying ratings' using errcode='23514';
  end if;
  select count(*) into full_time_count from public.n26_season_entries where season_id=p_season_id and entry_status='full_time';
  if full_time_count <> ruleset_row.driver_count then raise exception 'Ratings require % full-time entries', ruleset_row.driver_count using errcode='23514'; end if;
  select count(*) into certified_race_count
  from public.n26_season_races
  where season_id=p_season_id and status in ('completed','voided') and certification_status='certified';
  if certified_race_count <> ruleset_row.season_length then raise exception 'Every scheduled race must be certified before ratings' using errcode='23514'; end if;
  select count(*) into provisional_count from public.n26_rating_snapshots where season_id=p_season_id and certification_status='provisional';
  select count(*) into certified_count from public.n26_rating_snapshots where season_id=p_season_id and certification_status='certified';
  if provisional_count <> full_time_count and certified_count <> full_time_count then
    raise exception 'Every full-time driver needs a provisional rating before certification' using errcode='23514';
  end if;
  update public.n26_rating_snapshots
  set certification_status='certified'
  where season_id=p_season_id and certification_status='provisional';
  select count(*) into certified_count from public.n26_rating_snapshots where season_id=p_season_id and certification_status='certified';
  if certified_count <> full_time_count then raise exception 'Every full-time driver needs a certified rating' using errcode='23514'; end if;
  return jsonb_build_object('season_id',p_season_id,'certified',certified_count);
end;
$$;

revoke execute on function public.n26_certify_ratings(uuid) from public, anon, authenticated;
grant execute on function public.n26_certify_ratings(uuid) to service_role;

create or replace function public.n26_certify_season(p_season_id uuid)
returns public.n26_seasons
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  ruleset_row public.n26_rulesets;
  full_time_count integer;
  active_seat_count integer;
  certified_race_count integer;
  certified_rating_count integer;
  updated_season public.n26_seasons;
begin
  select * into season_row from public.n26_seasons where id=p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode='02000'; end if;
  if season_row.status not in ('open','in_progress','appeal_window') then raise exception 'Only an active season can be certified' using errcode='42501'; end if;
  select * into ruleset_row from public.n26_rulesets where id=season_row.ruleset_id;
  if coalesce(ruleset_row.config->>'points_schedule_status','') <> 'approved' then raise exception 'The points schedule must be approved before certifying the season' using errcode='23514'; end if;
  select count(*) into full_time_count from public.n26_season_entries where season_id=p_season_id and entry_status='full_time';
  if full_time_count <> ruleset_row.driver_count then raise exception 'Season certification requires % full-time entries', ruleset_row.driver_count using errcode='23514'; end if;
  select count(*) into active_seat_count
  from public.n26_seat_assignments
  where season_id=p_season_id and assignment_status='active';
  if active_seat_count <> ruleset_row.driver_count then raise exception 'Season certification requires % active seats', ruleset_row.driver_count using errcode='23514'; end if;
  if exists (
    select 1 from public.n26_teams teams
    left join public.n26_seat_assignments assignments
      on assignments.team_id=teams.id and assignments.season_id=p_season_id and assignments.assignment_status='active'
    where teams.status='active'
    group by teams.id, teams.seat_limit
    having count(assignments.id) <> teams.seat_limit
  ) then raise exception 'Every active team must have exactly three seats before certification' using errcode='23514'; end if;
  select count(*) into certified_race_count
  from public.n26_season_races
  where season_id=p_season_id and status in ('completed','voided') and certification_status='certified';
  if certified_race_count <> ruleset_row.season_length then raise exception 'Every scheduled race must be certified first' using errcode='23514'; end if;
  select count(*) into certified_rating_count from public.n26_rating_snapshots where season_id=p_season_id and certification_status='certified';
  if certified_rating_count <> full_time_count then raise exception 'Every full-time driver needs a certified rating first' using errcode='23514'; end if;
  update public.n26_seasons set status='certified', results_certified_at=coalesce(results_certified_at,now()) where id=p_season_id returning * into updated_season;
  return updated_season;
end;
$$;

revoke execute on function public.n26_certify_season(uuid) from public, anon, authenticated;
grant execute on function public.n26_certify_season(uuid) to service_role;
