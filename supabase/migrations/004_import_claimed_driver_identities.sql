-- Promote existing claims into permanent league driver identities.
-- This is intentionally limited to real claims already present in the legacy
-- table; open seats and future drivers are not invented here.

alter table public.n26_drivers
  add column if not exists legacy_claim_id uuid;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.n26_drivers'::regclass
      and conname = 'n26_drivers_legacy_claim_id_fkey'
  ) then
    alter table public.n26_drivers
      add constraint n26_drivers_legacy_claim_id_fkey
      foreign key (legacy_claim_id)
      references public.n26_claims (id)
      on delete set null;
  end if;
end
$$;

create unique index if not exists n26_drivers_legacy_claim_unique
  on public.n26_drivers (legacy_claim_id)
  where legacy_claim_id is not null;

insert into public.n26_drivers (
  display_name,
  gamertag,
  first_name,
  last_name,
  legacy_claim_id,
  status
)
select
  coalesce(nullif(trim(concat_ws(' ', claims.first_name, claims.last_name)), ''), claims.gamertag),
  claims.gamertag,
  claims.first_name,
  claims.last_name,
  claims.id,
  'active'
from public.n26_claims claims
where not exists (
  select 1
  from public.n26_drivers drivers
  where drivers.legacy_claim_id = claims.id
);

create index if not exists n26_drivers_legacy_claim_lookup_idx
  on public.n26_drivers (legacy_claim_id);
