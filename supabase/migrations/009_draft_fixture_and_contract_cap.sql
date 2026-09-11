-- Seed the eight-race draft fixture from the existing published track plan.
-- The old ten-race tables remain unchanged for backwards compatibility.

alter table public.n26_contracts
  add column if not exists cap_charge_cents integer;

alter table public.n26_contracts
  drop constraint if exists n26_contracts_cap_charge_cents_check;

alter table public.n26_contracts
  add constraint n26_contracts_cap_charge_cents_check
  check (cap_charge_cents is null or cap_charge_cents >= 0);

create index if not exists n26_contracts_active_driver_idx
  on public.n26_contracts (season_id, driver_id, status);

insert into public.n26_season_races (
  season_id, race_number, track_name, track_short, race_type, race_date,
  status, qualifying_status, certification_status
)
select
  seasons.id,
  legacy.race_number,
  legacy.track_name,
  legacy.track_short,
  'regular',
  legacy.race_date,
  'upcoming',
  'not_recorded',
  'draft'
from public.n26_seasons seasons
join public.n26_races legacy on legacy.race_number between 1 and 8
where seasons.season_number = 1
on conflict (season_id, race_number) do nothing;

drop policy if exists "public can read published races" on public.n26_season_races;
create policy "public can read published races"
  on public.n26_season_races for select using (
    exists (
      select 1 from public.n26_seasons seasons
      where seasons.id = season_id and seasons.status <> 'draft'
    )
  );
