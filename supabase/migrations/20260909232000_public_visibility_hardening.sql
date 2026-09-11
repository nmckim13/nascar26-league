-- A normalized row is public only when its parent season is public too.

drop policy if exists "public can read published results" on public.n26_race_results;
create policy "public can read published results"
  on public.n26_race_results for select using (
    certification_status in ('published', 'certified')
    and exists (
      select 1
      from public.n26_season_races races
      join public.n26_seasons seasons on seasons.id = races.season_id
      where races.id = race_id
        and seasons.status <> 'draft'
    )
  );

drop policy if exists "public can read certified ratings" on public.n26_rating_snapshots;
create policy "public can read certified ratings"
  on public.n26_rating_snapshots for select using (
    certification_status = 'certified'
    and exists (
      select 1
      from public.n26_seasons seasons
      where seasons.id = season_id
        and seasons.status <> 'draft'
    )
  );
