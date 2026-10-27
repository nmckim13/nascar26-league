-- Run only against an empty, disposable PostgreSQL database as a superuser.
-- psql -X -v ON_ERROR_STOP=1 -d league_test -f scripts/verify-claim-sync.sql
-- All fixture objects, account links, and roster writes roll back.
\set ON_ERROR_STOP on
begin;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role bypassrls; end if;
end;
$$;
create schema auth;
create table auth.users (id uuid primary key);
\ir ../supabase/migrations/001_league_identity_and_contracts.sql

-- Minimal legacy intake prerequisites; all promotion and approval functions,
-- account constraints, roster writes, and claim triggers come from migrations.
create table public.n26_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id),
  car_number text not null,
  team_name text,
  gamertag text,
  first_name text,
  last_name text,
  claimed_at timestamptz not null default now()
);
\ir ../supabase/migrations/004_import_claimed_driver_identities.sql
\ir ../supabase/migrations/006_roster_invariants.sql
\ir ../supabase/migrations/007_commissioner_roster_transactions.sql
\ir ../supabase/migrations/20260910015000_public_claim_roster_table.sql
\ir ../supabase/migrations/20260910017000_claim_roster_integrity.sql
\ir ../supabase/migrations/20260914132559_commissioner_join_approval.sql
\ir ../supabase/migrations/20260914140153_driver_self_service_profiles.sql
\ir ../supabase/migrations/20260914140701_protect_driver_account_links.sql

insert into auth.users (id)
select ('00000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid from generate_series(1, 20) i;
insert into public.n26_rulesets (version, name, points_by_position, rating_weights)
values ('claim-test', 'Claim test', '{}', '{}');
insert into public.n26_seasons (season_number, name, ruleset_id)
select 1, 'Claim test', id from public.n26_rulesets;

insert into public.n26_claims (car_number, team_name, gamertag, user_id, approval_status)
select car, teams.name, 'Driver ' || car,
  case when account is not null then ('00000000-0000-0000-0000-' || lpad(account::text, 12, '0'))::uuid end,
  approval
from (values ('5', 1, 'approved'), ('9', 2, 'approved'), ('11', null, 'approved'),
  ('19', 4, 'pending'), ('20', 5, 'rejected')) as fixture(car, account, approval)
join public.n26_team_car_numbers numbers on numbers.car_number = car
join public.n26_teams teams on teams.id = numbers.team_id;
insert into public.n26_drivers (display_name, legacy_claim_id, auth_user_id)
select gamertag, id, case car_number
  when '9' then '00000000-0000-0000-0000-000000000002'::uuid
  when '11' then '00000000-0000-0000-0000-000000000003'::uuid end
from public.n26_claims;

\ir ../supabase/migrations/20261027010000_claim_sync_account_links.sql

do $$
declare
  season uuid := (select id from public.n26_seasons where name = 'Claim test');
  claim uuid;
  outcome jsonb;
  drivers_before jsonb;
  seats_before jsonb;
  transactions_before integer;
begin
  if not exists (select 1 from public.n26_drivers d join public.n26_claims c on c.id = d.legacy_claim_id
    where c.car_number = '5' and d.auth_user_id = c.user_id) then
    raise exception 'Backfill did not repair an approved driver created after the old backfill';
  end if;
  if exists (select 1 from public.n26_drivers d join public.n26_claims c on c.id = d.legacy_claim_id
    where c.car_number in ('19', '20') and d.auth_user_id is not null) then
    raise exception 'Backfill linked a pending or rejected claimant';
  end if;

  -- New promotion plus a driver who needs repair after this migration ran.
  insert into public.n26_claims (car_number, team_name, gamertag, user_id, approval_status)
  values ('24', 'Hendrick Motorsports', 'New driver', '00000000-0000-0000-0000-000000000006', 'approved'),
    ('88', 'Trackhouse Racing', 'Unlinked driver', '00000000-0000-0000-0000-000000000007', 'approved');
  insert into public.n26_drivers (display_name, legacy_claim_id)
  select gamertag, id from public.n26_claims where car_number = '88';
  outcome := public.n26_sync_claims_to_draft(season);
  if outcome->>'created_drivers' <> '1' or outcome->>'assigned_seats' <> '5'
    or (select count(*) from public.n26_drivers d join public.n26_claims c on c.id = d.legacy_claim_id
      where c.car_number in ('24', '88') and d.auth_user_id = c.user_id) <> 2 then
    raise exception 'Standalone sync failed to link a promoted or existing driver';
  end if;
  if not exists (select 1 from public.n26_drivers d join public.n26_claims c on c.id = d.legacy_claim_id
    where c.car_number = '9' and d.auth_user_id = '00000000-0000-0000-0000-000000000002')
    or not exists (select 1 from public.n26_drivers d join public.n26_claims c on c.id = d.legacy_claim_id
      where c.car_number = '11' and d.auth_user_id = '00000000-0000-0000-0000-000000000003')
    or exists (select 1 from public.n26_seat_assignments s join public.n26_drivers d on d.id = s.driver_id
      join public.n26_claims c on c.id = d.legacy_claim_id where c.car_number in ('19', '20')) then
    raise exception 'Sync changed an existing login or promoted an unapproved claim';
  end if;
  select jsonb_agg(to_jsonb(d) order by id) into drivers_before from public.n26_drivers d;
  select jsonb_agg(to_jsonb(s) order by id) into seats_before from public.n26_seat_assignments s;
  select count(*) into transactions_before from public.n26_transactions;
  outcome := public.n26_sync_claims_to_draft(season);
  if outcome->>'created_drivers' <> '0' or outcome->>'assigned_seats' <> '0'
    or (select jsonb_agg(to_jsonb(d) order by id) from public.n26_drivers d) <> drivers_before
    or (select jsonb_agg(to_jsonb(s) order by id) from public.n26_seat_assignments s) <> seats_before
    or (select count(*) from public.n26_transactions) <> transactions_before then
    raise exception 'Repeat sync changed identities, links, seats, or transaction history';
  end if;

  -- Normal approval still links; a claim without a login must not erase a
  -- commissioner's manually assigned login on its existing driver.
  select id into claim from public.n26_claims where car_number = '19';
  perform public.n26_review_claim(claim, 'approved', null, season);
  if not exists (select 1 from public.n26_drivers where legacy_claim_id = claim
    and auth_user_id = '00000000-0000-0000-0000-000000000004') then
    raise exception 'Approval failed to link its driver';
  end if;
  insert into public.n26_claims (car_number, team_name, gamertag)
  values ('35', '23XI Racing', 'Manual login') returning id into claim;
  insert into public.n26_drivers (display_name, legacy_claim_id, auth_user_id)
  values ('Manual login', claim, '00000000-0000-0000-0000-000000000008');
  perform public.n26_review_claim(claim, 'approved', null, season);
  if not exists (select 1 from public.n26_drivers where legacy_claim_id = claim
    and auth_user_id = '00000000-0000-0000-0000-000000000008') then
    raise exception 'Approval erased a manually assigned login';
  end if;

  -- A different existing login is not reassigned, and failed approval rolls
  -- back the decision as well as any roster work.
  insert into public.n26_claims (car_number, team_name, gamertag, user_id)
  values ('2', 'Team Penske', 'Conflicting login', '00000000-0000-0000-0000-000000000009') returning id into claim;
  insert into public.n26_drivers (display_name, legacy_claim_id, auth_user_id)
  values ('Conflicting login', claim, '00000000-0000-0000-0000-000000000010');
  begin
    perform public.n26_review_claim(claim, 'approved', null, season);
    raise exception 'Approval overwrote a conflicting login';
  exception when unique_violation then
    if sqlerrm not like 'Approved claim % conflicts with the driver%' then raise; end if;
  end;
  if not exists (select 1 from public.n26_claims where id = claim and approval_status = 'pending' and reviewed_at is null)
    or not exists (select 1 from public.n26_drivers where legacy_claim_id = claim
      and auth_user_id = '00000000-0000-0000-0000-000000000010') then
    raise exception 'Failed approval changed the claim or driver login';
  end if;

  -- Account uniqueness must reject a claimant whose login belongs to a
  -- different driver. An earlier promotion in the same sync must roll back.
  insert into public.n26_drivers (display_name, auth_user_id)
  values ('Other identity', '00000000-0000-0000-0000-000000000011');
  insert into public.n26_claims (car_number, team_name, gamertag, user_id, approval_status, claimed_at)
  values ('17', 'RFK Racing', 'Earlier promotion', '00000000-0000-0000-0000-000000000012', 'approved', now() + interval '1 day'),
    ('12', 'Team Penske', 'Already linked elsewhere', '00000000-0000-0000-0000-000000000011', 'approved', now() + interval '2 days');
  select jsonb_agg(to_jsonb(d) order by id) into drivers_before from public.n26_drivers d;
  select jsonb_agg(to_jsonb(s) order by id) into seats_before from public.n26_seat_assignments s;
  select count(*) into transactions_before from public.n26_transactions;
  begin
    perform public.n26_sync_claims_to_draft(season);
    raise exception 'Sync assigned one login to a second driver';
  exception when unique_violation then null;
  end;
  if (select jsonb_agg(to_jsonb(d) order by id) from public.n26_drivers d) <> drivers_before
    or (select jsonb_agg(to_jsonb(s) order by id) from public.n26_seat_assignments s) <> seats_before
    or (select count(*) from public.n26_transactions) <> transactions_before then
    raise exception 'Failed sync left partial identities, links, seats, or transactions';
  end if;

  update public.n26_seasons set status = 'in_progress' where id = season;
  begin
    perform public.n26_sync_claims_to_draft(season);
    raise exception 'Sync accepted a running season';
  exception when insufficient_privilege then null;
  end;
  if has_function_privilege('anon', 'public.n26_sync_claims_to_draft(uuid)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.n26_sync_claims_to_draft(uuid)', 'EXECUTE')
    or not has_function_privilege('service_role', 'public.n26_sync_claims_to_draft(uuid)', 'EXECUTE')
    or has_function_privilege('anon', 'public.n26_review_claim(uuid,text,uuid,uuid)', 'EXECUTE')
    or has_function_privilege('authenticated', 'public.n26_review_claim(uuid,text,uuid,uuid)', 'EXECUTE')
    or not has_function_privilege('service_role', 'public.n26_review_claim(uuid,text,uuid,uuid)', 'EXECUTE') then
    raise exception 'Claim promotion or approval is no longer service-role-only';
  end if;
  raise notice 'Claim linking verified: backfill, new/existing drivers, repeat sync, approval, manual links, conflicts, atomic rollback, draft-only gate, and RPC grants.';
end;
$$;
set constraints all immediate;
rollback;
