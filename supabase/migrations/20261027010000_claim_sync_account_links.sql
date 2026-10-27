-- Claim promotion owns account linking for both standalone sync and approval.
-- Never overwrite an existing login; the unique account index also prevents
-- assigning one login to two driver identities.
create or replace function public.n26_sync_claims_to_draft(p_season_id uuid)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
  claim_row record;
  driver_row public.n26_drivers;
  team_id_value uuid;
  display_name_value text;
  created_count integer := 0;
  assigned_count integer := 0;
begin
  select * into season_row from public.n26_seasons where id = p_season_id for update;
  if season_row.id is null then raise exception 'Season not found' using errcode = '02000'; end if;
  if season_row.status <> 'draft' then raise exception 'Claims can only be synced into a draft season' using errcode = '42501'; end if;

  for claim_row in
    select claims.* from public.n26_claims claims
    where claims.approval_status = 'approved'
    order by claims.claimed_at, claims.id
  loop
    select numbers.team_id into team_id_value
    from public.n26_team_car_numbers numbers
    where numbers.car_number = claim_row.car_number and numbers.is_available = true;
    if team_id_value is null then raise exception 'Claimed car number % is not in the active league catalog', claim_row.car_number using errcode = '23514'; end if;

    select * into driver_row from public.n26_drivers where legacy_claim_id = claim_row.id for update;
    if driver_row.id is null then
      display_name_value := coalesce(nullif(trim(concat_ws(' ', claim_row.first_name, claim_row.last_name)), ''), nullif(trim(claim_row.gamertag), ''));
      if display_name_value is null then raise exception 'Claim % is missing a usable driver name', claim_row.id using errcode = '22023'; end if;
      insert into public.n26_drivers (display_name, gamertag, first_name, last_name, legacy_claim_id, status, auth_user_id)
      values (display_name_value, nullif(trim(claim_row.gamertag), ''), nullif(trim(claim_row.first_name), ''), nullif(trim(claim_row.last_name), ''), claim_row.id, 'active', claim_row.user_id)
      returning * into driver_row;
      created_count := created_count + 1;
    elsif claim_row.user_id is not null then
      if driver_row.auth_user_id is not null and driver_row.auth_user_id <> claim_row.user_id then
        raise exception 'Approved claim % conflicts with the driver''s existing login; resolve the account link before syncing', claim_row.id using errcode = '23505';
      end if;
      if driver_row.auth_user_id is null then
        update public.n26_drivers set auth_user_id = claim_row.user_id
        where id = driver_row.id returning * into driver_row;
      end if;
    end if;
    if not exists (select 1 from public.n26_seat_assignments assignments where assignments.season_id = p_season_id and assignments.driver_id = driver_row.id and assignments.assignment_status = 'active') then
      perform public.n26_assign_driver_to_seat(p_season_id, driver_row.id, team_id_value, claim_row.car_number, false);
      assigned_count := assigned_count + 1;
    end if;
  end loop;
  return jsonb_build_object('season_id', p_season_id, 'created_drivers', created_count, 'assigned_seats', assigned_count);
end;
$$;

-- Approval relies on the same conflict-safe linker instead of overwriting the
-- reviewed driver's login after sync has completed.
create or replace function public.n26_review_claim(
  p_claim_id uuid,
  p_decision text,
  p_reviewer uuid,
  p_season_id uuid default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  claim_row public.n26_claims;
  sync_result jsonb := null;
begin
  if p_decision not in ('approved', 'rejected') then raise exception 'Decision must be approved or rejected' using errcode = '22023'; end if;
  select * into claim_row from public.n26_claims where id = p_claim_id for update;
  if claim_row.id is null then raise exception 'Application not found' using errcode = '02000'; end if;
  if claim_row.approval_status <> 'pending' then raise exception 'This application is no longer pending' using errcode = '23514'; end if;
  if p_decision = 'approved' and p_season_id is null then raise exception 'A draft season is required for approval' using errcode = '22023'; end if;

  update public.n26_claims set approval_status = p_decision, reviewed_at = now(), reviewed_by = p_reviewer
  where id = p_claim_id returning * into claim_row;

  if p_decision = 'approved' then
    sync_result := public.n26_sync_claims_to_draft(p_season_id);
  end if;
  return jsonb_build_object('application', to_jsonb(claim_row), 'sync', sync_result);
end;
$$;

-- Repair drivers created after the original one-time account-link backfill.
-- A login already assigned to another driver causes a unique-constraint error,
-- rather than transferring ownership or silently leaving an approved user out.
update public.n26_drivers drivers
set auth_user_id = claims.user_id
from public.n26_claims claims
where drivers.legacy_claim_id = claims.id
  and claims.approval_status = 'approved'
  and claims.user_id is not null
  and drivers.auth_user_id is null;

revoke execute on function public.n26_sync_claims_to_draft(uuid) from public, anon, authenticated;
revoke execute on function public.n26_review_claim(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.n26_sync_claims_to_draft(uuid) to service_role;
grant execute on function public.n26_review_claim(uuid, text, uuid, uuid) to service_role;
