-- Create a safe draft season around the current real claims.
-- This season is not public or certified until the remaining 14 drivers and
-- the explicit 24-position points schedule are confirmed.

insert into public.n26_rulesets (
  version,
  name,
  season_length,
  team_size,
  driver_count,
  points_by_position,
  rating_weights,
  config
)
values (
  '2.0-24-driver-draft',
  'BARL Eight-Race Career Model - 24 Driver Draft',
  8,
  3,
  24,
  '{"1":55,"2":35,"3":34,"4":33,"5":32,"6":31,"7":30,"8":29,"9":28,"10":27,"11":26,"12":25,"13":24,"14":23,"15":22,"16":21,"17":20,"18":19,"19":18,"20":17,"21":16,"22":15,"23":14,"24":13}'::jsonb,
  '{"championshipFinish":0.50,"finishQuality":0.20,"wins":0.15,"attendance":0.10,"qualifying":0.05}'::jsonb,
  '{"points_schedule_status":"pending_24_position_extension","launch_field_size":24,"qualifying_required":true}'::jsonb
)
on conflict (version) do nothing;

insert into public.n26_seasons (season_number, name, ruleset_id, status)
select
  1,
  'Season 1 - Eight-Race Draft',
  rulesets.id,
  'draft'
from public.n26_rulesets rulesets
where rulesets.version = '2.0-24-driver-draft'
on conflict (season_number) do nothing;

insert into public.n26_season_entries (season_id, driver_id, entry_status)
select
  seasons.id,
  drivers.id,
  'full_time'
from public.n26_seasons seasons
join public.n26_drivers drivers on drivers.legacy_claim_id is not null
where seasons.season_number = 1
  and not exists (
    select 1
    from public.n26_season_entries entries
    where entries.season_id = seasons.id
      and entries.driver_id = drivers.id
  );

insert into public.n26_seat_assignments (
  season_id,
  driver_id,
  team_id,
  car_number,
  starts_at,
  assignment_status
)
select
  seasons.id,
  drivers.id,
  teams.id,
  claims.car_number,
  claims.claimed_at,
  'active'
from public.n26_seasons seasons
join public.n26_drivers drivers on drivers.legacy_claim_id is not null
join public.n26_claims claims on claims.id = drivers.legacy_claim_id
join public.n26_teams teams on lower(teams.name) = lower(claims.team_name)
where seasons.season_number = 1
  and not exists (
    select 1
    from public.n26_seat_assignments assignments
    where assignments.season_id = seasons.id
      and assignments.driver_id = drivers.id
      and assignments.assignment_status = 'active'
  );
