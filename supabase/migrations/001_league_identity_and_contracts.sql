-- BARL league foundation
-- This migration is additive. It does not alter the existing n26_claims,
-- n26_races, or n26_results tables used by the current public site.

create extension if not exists pgcrypto;

create table if not exists public.n26_drivers (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  gamertag text,
  first_name text,
  last_name text,
  status text not null default 'active'
    check (status in ('active', 'inactive', 'reserve')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists n26_drivers_gamertag_unique
  on public.n26_drivers (lower(gamertag))
  where gamertag is not null;

create table if not exists public.n26_teams (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  seat_limit integer not null default 3 check (seat_limit = 3),
  status text not null default 'active'
    check (status in ('active', 'inactive')),
  created_at timestamptz not null default now()
);

create table if not exists public.n26_team_car_numbers (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.n26_teams(id) on delete cascade,
  car_number text not null,
  is_available boolean not null default true,
  created_at timestamptz not null default now(),
  unique (team_id, car_number),
  unique (car_number)
);

create table if not exists public.n26_rulesets (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  name text not null,
  season_length integer not null default 8 check (season_length > 0),
  team_size integer not null default 3 check (team_size = 3),
  driver_count integer not null default 24 check (driver_count > 0),
  points_by_position jsonb not null,
  rating_weights jsonb not null,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.n26_seasons (
  id uuid primary key default gen_random_uuid(),
  season_number integer not null unique,
  name text not null,
  ruleset_id uuid not null references public.n26_rulesets(id),
  status text not null default 'draft'
    check (status in ('draft', 'open', 'in_progress', 'appeal_window', 'certified', 'archived')),
  roster_lock_at timestamptz,
  results_certified_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.n26_season_entries (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  entry_status text not null default 'full_time'
    check (entry_status in ('full_time', 'reserve', 'inactive')),
  registered_at timestamptz not null default now(),
  unique (season_id, driver_id)
);

create table if not exists public.n26_season_races (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  race_number integer not null check (race_number > 0),
  track_name text not null,
  track_short text not null,
  race_type text not null default 'regular'
    check (race_type in ('regular', 'chase', 'exhibition')),
  race_date date,
  status text not null default 'upcoming'
    check (status in ('upcoming', 'open', 'completed', 'voided')),
  starters_count integer check (starters_count >= 0),
  qualifying_field_count integer check (qualifying_field_count >= 0),
  qualifying_status text not null default 'not_recorded'
    check (qualifying_status in ('not_recorded', 'valid', 'canceled', 'incomplete', 'voided')),
  certification_status text not null default 'draft'
    check (certification_status in ('draft', 'published', 'appeal_window', 'certified')),
  created_at timestamptz not null default now(),
  unique (season_id, race_number)
);

create table if not exists public.n26_seat_assignments (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  team_id uuid not null references public.n26_teams(id),
  car_number text not null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  assignment_status text not null default 'active'
    check (assignment_status in ('active', 'released', 'transferred', 'ended')),
  unique (season_id, driver_id, starts_at),
  unique (season_id, car_number, starts_at)
);

create index if not exists n26_seat_assignments_current_idx
  on public.n26_seat_assignments (season_id, assignment_status, team_id);

create table if not exists public.n26_race_results (
  id uuid primary key default gen_random_uuid(),
  race_id uuid not null references public.n26_season_races(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  seat_assignment_id uuid references public.n26_seat_assignments(id),
  team_id uuid not null references public.n26_teams(id),
  car_number text not null,
  start_status text not null default 'started'
    check (start_status in ('started', 'dns')),
  finish_status text not null default 'classified'
    check (finish_status in ('classified', 'dnf')),
  finish_position integer check (finish_position > 0),
  qualifying_position integer check (qualifying_position > 0),
  qualifying_valid boolean not null default false,
  pole boolean not null default false,
  points_earned integer not null default 0,
  source_version text not null default 'manual-v1',
  certification_status text not null default 'draft'
    check (certification_status in ('draft', 'published', 'certified', 'superseded')),
  created_at timestamptz not null default now(),
  unique (race_id, driver_id),
  check ((start_status = 'dns' and finish_position is null) or
         (start_status = 'started' and finish_position is not null)),
  check ((qualifying_valid = true and qualifying_position is not null) or
         (qualifying_valid = false)),
  check ((pole = true and qualifying_valid = true and qualifying_position = 1) or
         (pole = false))
);

create index if not exists n26_race_results_race_position_idx
  on public.n26_race_results (race_id, finish_position);

create index if not exists n26_race_results_driver_idx
  on public.n26_race_results (driver_id, certification_status);

create table if not exists public.n26_contracts (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  team_id uuid not null references public.n26_teams(id),
  start_season integer not null,
  end_season integer not null,
  original_term_seasons integer not null
    check (original_term_seasons between 1 and 3),
  term_discount_bps integer not null default 0
    check (term_discount_bps in (0, 200, 400)),
  loyalty_discount_bps integer not null default 0
    check (loyalty_discount_bps in (0, 100)),
  status text not null default 'active'
    check (status in ('introductory', 'active', 'expired', 'released', 'traded')),
  created_at timestamptz not null default now(),
  check (end_season >= start_season),
  check (end_season - start_season + 1 = original_term_seasons)
);

create table if not exists public.n26_rating_snapshots (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  ruleset_id uuid not null references public.n26_rulesets(id),
  championship_finish numeric(12, 8) not null check (championship_finish between 40 and 100),
  finish_quality numeric(12, 8) not null check (finish_quality between 40 and 100),
  wins_rating numeric(12, 8) not null check (wins_rating between 40 and 100),
  attendance numeric(12, 8) not null check (attendance between 40 and 100),
  qualifying numeric(12, 8) not null check (qualifying between 40 and 100),
  overall_raw numeric(12, 8) not null check (overall_raw between 40 and 100),
  official_ovr integer not null check (official_ovr between 40 and 100),
  source_results_version text not null,
  certification_status text not null default 'provisional'
    check (certification_status in ('provisional', 'certified', 'superseded')),
  created_at timestamptz not null default now(),
  unique (season_id, driver_id, certification_status)
);

create table if not exists public.n26_transactions (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  from_team_id uuid references public.n26_teams(id),
  to_team_id uuid references public.n26_teams(id),
  from_car_number text,
  to_car_number text,
  transaction_type text not null
    check (transaction_type in ('signing', 'renewal', 'trade', 'release', 'withdrawal', 'correction')),
  effective_at timestamptz not null default now(),
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists n26_transactions_driver_idx
  on public.n26_transactions (driver_id, effective_at desc);

-- Explicit Data API grants for public-facing, published league data. RLS below
-- still controls which rows are visible. Contract and transaction tables stay
-- private until commissioner-facing access is implemented.
grant select on public.n26_drivers,
  public.n26_teams,
  public.n26_team_car_numbers,
  public.n26_rulesets,
  public.n26_seasons,
  public.n26_season_entries,
  public.n26_season_races,
  public.n26_race_results,
  public.n26_seat_assignments,
  public.n26_rating_snapshots
to anon, authenticated;

-- Seed the team and car-number catalog. The active driver assignment is stored
-- separately, so an available number can remain unowned or be chosen later.
insert into public.n26_teams (slug, name, seat_limit)
values
  ('hendrick', 'Hendrick Motorsports', 3),
  ('jgr', 'Joe Gibbs Racing', 3),
  ('penske', 'Team Penske', 3),
  ('23xi', '23XI Racing', 3),
  ('rfk', 'RFK Racing', 3),
  ('spire', 'Spire Motorsports', 3),
  ('trackhouse', 'Trackhouse Racing', 3),
  ('legacy', 'Legacy Motor Club', 3)
on conflict (slug) do update set name = excluded.name, seat_limit = excluded.seat_limit;

insert into public.n26_team_car_numbers (team_id, car_number)
select teams.id, numbers.car_number
from (values
  ('hendrick', '5'), ('hendrick', '9'), ('hendrick', '24'), ('hendrick', '48'),
  ('jgr', '11'), ('jgr', '19'), ('jgr', '20'), ('jgr', '54'),
  ('penske', '2'), ('penske', '12'), ('penske', '22'),
  ('23xi', '23'), ('23xi', '35'), ('23xi', '45'),
  ('rfk', '6'), ('rfk', '17'), ('rfk', '60'),
  ('spire', '7'), ('spire', '71'), ('spire', '77'),
  ('trackhouse', '1'), ('trackhouse', '88'), ('trackhouse', '97'),
  ('legacy', '42'), ('legacy', '43'), ('legacy', '84')
) as numbers(team_slug, car_number)
join public.n26_teams teams on teams.slug = numbers.team_slug
on conflict (car_number) do update set team_id = excluded.team_id;

alter table public.n26_drivers enable row level security;
alter table public.n26_teams enable row level security;
alter table public.n26_team_car_numbers enable row level security;
alter table public.n26_rulesets enable row level security;
alter table public.n26_seasons enable row level security;
alter table public.n26_season_entries enable row level security;
alter table public.n26_season_races enable row level security;
alter table public.n26_race_results enable row level security;
alter table public.n26_seat_assignments enable row level security;
alter table public.n26_contracts enable row level security;
alter table public.n26_rating_snapshots enable row level security;
alter table public.n26_transactions enable row level security;

create policy "public can read active league structure"
  on public.n26_teams for select using (status = 'active');

create policy "public can read available car numbers"
  on public.n26_team_car_numbers for select using (is_available = true);

create policy "public can read active drivers"
  on public.n26_drivers for select using (status = 'active');

create policy "public can read published seasons"
  on public.n26_seasons for select using (status <> 'draft');

create policy "public can read published entries"
  on public.n26_season_entries for select using (
    exists (
      select 1 from public.n26_seasons seasons
      where seasons.id = season_id and seasons.status <> 'draft'
    )
  );

create policy "public can read published races"
  on public.n26_season_races for select using (
    status <> 'upcoming' or certification_status <> 'draft'
  );

create policy "public can read published results"
  on public.n26_race_results for select using (
    certification_status in ('published', 'certified')
  );

create policy "public can read published assignments"
  on public.n26_seat_assignments for select using (
    exists (
      select 1 from public.n26_seasons seasons
      where seasons.id = season_id and seasons.status <> 'draft'
    )
  );

create policy "public can read certified ratings"
  on public.n26_rating_snapshots for select using (certification_status = 'certified');
