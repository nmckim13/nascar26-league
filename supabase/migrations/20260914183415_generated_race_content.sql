alter table public.n26_news_articles
  add column if not exists generation_kind text,
  add column if not exists generated_at timestamptz;

alter table public.n26_storylines
  add column if not exists source_race_id uuid references public.n26_season_races(id) on delete cascade,
  add column if not exists generation_kind text,
  add column if not exists generated_at timestamptz;

create unique index if not exists n26_news_articles_generated_race_idx
  on public.n26_news_articles (race_id, generation_kind);

create unique index if not exists n26_storylines_generated_race_idx
  on public.n26_storylines (source_race_id, generation_kind);

create index if not exists n26_storylines_source_race_idx
  on public.n26_storylines (source_race_id);

create index if not exists n26_news_articles_season_idx
  on public.n26_news_articles (season_id);

create index if not exists n26_news_articles_created_by_idx
  on public.n26_news_articles (created_by);
