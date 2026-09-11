-- Protect the claim flow with Supabase Auth.
-- Existing public pages can still read roster data, but creating a claim now
-- requires an authenticated user whose claim row is tied to auth.users.

do $$
declare
  existing_policy record;
begin
  if to_regclass('public.n26_claims') is null then
    raise exception 'public.n26_claims must exist before applying auth claim protection';
  end if;

  for existing_policy in
    select policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = 'n26_claims'
  loop
    execute format('drop policy if exists %I on public.n26_claims', existing_policy.policyname);
  end loop;
end
$$;

alter table public.n26_claims
  add column if not exists user_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.n26_claims'::regclass
      and conname = 'n26_claims_user_id_fkey'
  ) then
    alter table public.n26_claims
      add constraint n26_claims_user_id_fkey
      foreign key (user_id)
      references auth.users (id)
      on delete set null;
  end if;
end
$$;

create unique index if not exists n26_claims_car_number_unique
  on public.n26_claims (car_number);

create unique index if not exists n26_claims_user_id_unique
  on public.n26_claims (user_id)
  where user_id is not null;

alter table public.n26_claims enable row level security;

create or replace view public.n26_claim_roster as
select
  car_number,
  team_name,
  gamertag,
  first_name,
  last_name,
  claimed_at
from public.n26_claims;

revoke all on public.n26_claims from anon, authenticated;
grant select on public.n26_claim_roster to anon, authenticated;
grant select (user_id, car_number, gamertag, first_name, last_name) on public.n26_claims to authenticated;
grant insert (
  user_id,
  car_number,
  driver_name,
  team_name,
  gamertag,
  first_name,
  last_name,
  phone,
  discord_username,
  discord_user_id
) on public.n26_claims to authenticated;

create policy "authenticated users can read their own claim"
  on public.n26_claims
  for select
  to authenticated
  using (
    (select auth.uid()) is not null
    and user_id = (select auth.uid())
  );

create policy "authenticated users can create one claim for themselves"
  on public.n26_claims
  for insert
  to authenticated
  with check (
    (select auth.uid()) is not null
    and
    user_id = (select auth.uid())
  );
