-- Preserve the legacy public roster endpoint without a SECURITY DEFINER view.
drop view if exists public.n26_claim_roster;

create table if not exists public.n26_claim_roster (
  car_number text primary key,
  team_name text,
  gamertag text,
  first_name text,
  last_name text,
  claimed_at timestamptz
);

alter table public.n26_claim_roster enable row level security;

drop policy if exists "public can read claim roster" on public.n26_claim_roster;
create policy "public can read claim roster"
  on public.n26_claim_roster
  for select to anon, authenticated
  using (true);

drop policy if exists "service manages claim roster" on public.n26_claim_roster;
create policy "service manages claim roster"
  on public.n26_claim_roster
  for all to service_role
  using (true)
  with check (true);

revoke all on public.n26_claim_roster from anon, authenticated;
grant select on public.n26_claim_roster to anon, authenticated;
grant all on public.n26_claim_roster to service_role;

create or replace function public.n26_sync_public_claim_roster()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.n26_claim_roster where car_number = old.car_number;
    return old;
  end if;

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

drop trigger if exists n26_sync_public_claim_roster_trigger on public.n26_claims;
create trigger n26_sync_public_claim_roster_trigger
after insert or update or delete on public.n26_claims
for each row execute function public.n26_sync_public_claim_roster();

delete from public.n26_claim_roster;
insert into public.n26_claim_roster (
  car_number, team_name, gamertag, first_name, last_name, claimed_at
)
select car_number, team_name, gamertag, first_name, last_name, claimed_at
from public.n26_claims;

revoke execute on function public.n26_sync_public_claim_roster() from public, anon, authenticated;
