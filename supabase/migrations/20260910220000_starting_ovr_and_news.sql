-- Establish the commissioner-approved starting OVR and a moderated news pipeline.
alter table public.n26_drivers
  add column if not exists starting_ovr integer not null default 60;
alter table public.n26_drivers
  drop constraint if exists n26_drivers_starting_ovr_check;
alter table public.n26_drivers
  add constraint n26_drivers_starting_ovr_check check (starting_ovr between 40 and 100);
update public.n26_drivers set starting_ovr = 60 where starting_ovr is null;

create table if not exists public.n26_news_articles (
  id uuid primary key default gen_random_uuid(),
  season_id uuid references public.n26_seasons(id),
  race_id uuid references public.n26_season_races(id),
  headline text not null check (length(trim(headline)) between 3 and 160),
  dek text not null default '' check (length(dek) <= 500),
  body text not null default '',
  status text not null default 'draft' check (status in ('draft', 'published', 'archived')),
  published_at timestamptz,
  created_by uuid references auth.users(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table public.n26_news_articles enable row level security;
drop policy if exists "public can read published news" on public.n26_news_articles;
create policy "public can read published news" on public.n26_news_articles
  for select using (status = 'published');
create index if not exists n26_news_articles_public_idx
  on public.n26_news_articles (status, published_at desc);

-- Existing contract authority functions used 50 as the newcomer value. Keep the
-- function body authoritative while changing only those exact newcomer guards.
do $do$
declare
  definition text;
begin
  select pg_get_functiondef(p.oid) into definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'n26_create_contract'
  order by p.oid desc limit 1;
  if definition is not null then
    definition := replace(definition, 'p_rating <> 50', 'p_rating <> 60');
    definition := replace(definition, 'at 50 credits', 'at 60 credits');
    definition := replace(definition, 'expected_rating := 50', 'expected_rating := 60');
    execute definition;
  end if;
end $do$;

grant select on public.n26_news_articles to anon, authenticated;
