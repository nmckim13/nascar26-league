-- Require commissioner approval before a claim becomes a public roster seat.
alter table public.n26_claims
  add column if not exists approval_status text not null default 'pending',
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users (id) on delete set null;

update public.n26_claims
set approval_status = 'approved',
    reviewed_at = coalesce(reviewed_at, claimed_at)
where approval_status = 'pending';

alter table public.n26_claims
  drop constraint if exists n26_claims_approval_status_check;
alter table public.n26_claims
  add constraint n26_claims_approval_status_check
  check (approval_status in ('pending', 'approved', 'rejected'));

drop index if exists public.n26_claims_car_number_unique;
drop index if exists public.n26_claims_user_id_unique;
create unique index n26_claims_open_car_number_unique
  on public.n26_claims (car_number)
  where approval_status in ('pending', 'approved');
create unique index n26_claims_open_user_id_unique
  on public.n26_claims (user_id)
  where user_id is not null and approval_status in ('pending', 'approved');

create or replace function public.n26_validate_claim_roster()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  matched_team_id uuid;
  existing_claim_count integer;
begin
  select teams.id into matched_team_id
  from public.n26_teams teams
  join public.n26_team_car_numbers numbers on numbers.team_id = teams.id
  where teams.status = 'active'
    and numbers.car_number = new.car_number
    and lower(teams.name) = lower(btrim(new.team_name))
  for update of teams;
  if matched_team_id is null then raise exception 'The selected car does not belong to the selected active team' using errcode = '23514'; end if;

  select count(*) into existing_claim_count
  from public.n26_claims claims
  where lower(btrim(claims.team_name)) = lower(btrim(new.team_name))
    and claims.approval_status in ('pending', 'approved')
    and claims.id is distinct from new.id;
  if new.approval_status in ('pending', 'approved') and existing_claim_count >= 3 then
    raise exception 'A team may have no more than three active or pending drivers' using errcode = '23514';
  end if;
  return new;
end;
$$;

grant select (approval_status) on public.n26_claims to authenticated;

create table if not exists public.n26_claim_availability (
  car_number text primary key,
  approval_status text not null check (approval_status in ('pending', 'approved'))
);
alter table public.n26_claim_availability enable row level security;
revoke all on public.n26_claim_availability from anon, authenticated;
grant select on public.n26_claim_availability to anon, authenticated;
grant all on public.n26_claim_availability to service_role;
create policy "public can read claim availability"
  on public.n26_claim_availability for select to anon, authenticated using (true);
create policy "service manages claim availability"
  on public.n26_claim_availability for all to service_role using (true) with check (true);

create or replace function public.n26_sync_public_claim_roster()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.n26_claim_roster where car_number = old.car_number;
    delete from public.n26_claim_availability where car_number = old.car_number;
    return old;
  end if;

  if new.approval_status <> 'approved' then
    delete from public.n26_claim_roster
    where car_number in (new.car_number, case when tg_op = 'UPDATE' then old.car_number else new.car_number end);
    if new.approval_status = 'pending' then
      insert into public.n26_claim_availability (car_number, approval_status)
      values (new.car_number, 'pending')
      on conflict (car_number) do update set approval_status = excluded.approval_status;
    else
      delete from public.n26_claim_availability where car_number = new.car_number;
    end if;
    return new;
  end if;

  insert into public.n26_claim_availability (car_number, approval_status)
  values (new.car_number, 'approved')
  on conflict (car_number) do update set approval_status = excluded.approval_status;

  insert into public.n26_claim_roster (
    car_number, team_name, gamertag, first_name, last_name, claimed_at
  ) values (
    new.car_number, new.team_name, new.gamertag, new.first_name,
    new.last_name, new.claimed_at
  )
  on conflict (car_number) do update set
    team_name = excluded.team_name,
    gamertag = excluded.gamertag,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    claimed_at = excluded.claimed_at;

  if tg_op = 'UPDATE' and old.car_number <> new.car_number then
    delete from public.n26_claim_roster where car_number = old.car_number;
  end if;
  return new;
end;
$$;

delete from public.n26_claim_roster;
insert into public.n26_claim_roster (
  car_number, team_name, gamertag, first_name, last_name, claimed_at
)
select car_number, team_name, gamertag, first_name, last_name, claimed_at
from public.n26_claims
where approval_status = 'approved';

delete from public.n26_claim_availability;
insert into public.n26_claim_availability (car_number, approval_status)
select car_number, approval_status
from public.n26_claims
where approval_status in ('pending', 'approved');

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
      insert into public.n26_drivers (display_name, gamertag, first_name, last_name, legacy_claim_id, status)
      values (display_name_value, nullif(trim(claim_row.gamertag), ''), nullif(trim(claim_row.first_name), ''), nullif(trim(claim_row.last_name), ''), claim_row.id, 'active')
      returning * into driver_row;
      created_count := created_count + 1;
    end if;
    if not exists (select 1 from public.n26_seat_assignments assignments where assignments.season_id = p_season_id and assignments.driver_id = driver_row.id and assignments.assignment_status = 'active') then
      perform public.n26_assign_driver_to_seat(p_season_id, driver_row.id, team_id_value, claim_row.car_number, false);
      assigned_count := assigned_count + 1;
    end if;
  end loop;
  return jsonb_build_object('season_id', p_season_id, 'created_drivers', created_count, 'assigned_seats', assigned_count);
end;
$$;

revoke execute on function public.n26_sync_claims_to_draft(uuid) from public, anon, authenticated;
grant execute on function public.n26_sync_claims_to_draft(uuid) to service_role;

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
  if p_decision not in ('approved', 'rejected') then
    raise exception 'Decision must be approved or rejected' using errcode = '22023';
  end if;
  select * into claim_row from public.n26_claims where id = p_claim_id for update;
  if claim_row.id is null then raise exception 'Application not found' using errcode = '02000'; end if;
  if claim_row.approval_status <> 'pending' then raise exception 'This application is no longer pending' using errcode = '23514'; end if;
  if p_decision = 'approved' and p_season_id is null then raise exception 'A draft season is required for approval' using errcode = '22023'; end if;

  update public.n26_claims
  set approval_status = p_decision, reviewed_at = now(), reviewed_by = p_reviewer
  where id = p_claim_id
  returning * into claim_row;

  if p_decision = 'approved' then
    sync_result := public.n26_sync_claims_to_draft(p_season_id);
  end if;
  return jsonb_build_object('application', to_jsonb(claim_row), 'sync', sync_result);
end;
$$;

revoke execute on function public.n26_review_claim(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.n26_review_claim(uuid, text, uuid, uuid) to service_role;
