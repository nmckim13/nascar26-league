create table public.n26_storylines (
  id uuid primary key default gen_random_uuid(),
  season_id uuid references public.n26_seasons(id) on delete set null,
  story_type text not null default 'commissioner_spotlight'
    check (story_type in ('championship_watch', 'featured_rivalry', 'driver_on_the_rise', 'team_battle', 'contract_watch', 'commissioner_spotlight')),
  headline text not null check (char_length(btrim(headline)) between 3 and 120),
  summary text not null default '' check (char_length(summary) <= 500),
  primary_driver_id uuid references public.n26_drivers(id) on delete set null,
  secondary_driver_id uuid references public.n26_drivers(id) on delete set null,
  intensity text check (intensity is null or intensity in ('friendly', 'building', 'heated', 'must_watch')),
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  sort_order smallint not null default 1 check (sort_order between 1 and 99),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz
);

create index n26_storylines_public_feed_idx
  on public.n26_storylines (status, sort_order, published_at desc);
create index n26_storylines_season_idx on public.n26_storylines (season_id);
create index n26_storylines_primary_driver_idx on public.n26_storylines (primary_driver_id);
create index n26_storylines_secondary_driver_idx on public.n26_storylines (secondary_driver_id);
create index n26_storylines_created_by_idx on public.n26_storylines (created_by);

alter table public.n26_storylines enable row level security;
revoke all on table public.n26_storylines from anon, authenticated;
grant select on table public.n26_storylines to anon, authenticated;

create policy "Published storylines are public"
  on public.n26_storylines for select
  to anon, authenticated
  using (status = 'published');

comment on table public.n26_storylines is 'Commissioner-managed public BARL narratives and rivalry cards.';

insert into public.n26_storylines (season_id, story_type, headline, summary, intensity, status, sort_order, published_at)
select id, 'team_battle', 'The Trackhouse Garage Is Already Under Pressure', 'Nolan McKim and Brantley Culp enter Season 1 as teammates, but only one can establish himself as the early standard inside Trackhouse.', 'building', 'published', 1, now()
from public.n26_seasons order by season_number desc limit 1;

insert into public.n26_storylines (season_id, story_type, headline, summary, status, sort_order, published_at)
select id, 'driver_on_the_rise', 'Every Open Seat Could Produce A Contender', 'The inaugural BARL field is still taking shape. A late arrival could become the season’s first breakout driver.', 'published', 2, now()
from public.n26_seasons order by season_number desc limit 1;

insert into public.n26_storylines (season_id, story_type, headline, summary, status, sort_order, published_at)
select id, 'commissioner_spotlight', 'Season 1 Will Write The First Chapter', 'The first eight races will establish BARL’s original champion, team pecking order, rivalries, and records.', 'published', 3, now()
from public.n26_seasons order by season_number desc limit 1;
