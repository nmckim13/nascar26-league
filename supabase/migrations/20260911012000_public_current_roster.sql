-- The current Season 1 roster is intentionally public before the season opens.
-- Future draft seasons remain private until they are published.
drop policy if exists "public can read published seasons" on public.n26_seasons;
create policy "public can read current or published seasons"
  on public.n26_seasons for select using (
    status <> 'draft'
    or season_number = 1
  );

drop policy if exists "public can read published entries" on public.n26_season_entries;
create policy "public can read current or published entries"
  on public.n26_season_entries for select using (
    exists (
      select 1 from public.n26_seasons seasons
      where seasons.id = season_id
        and (seasons.status <> 'draft' or seasons.season_number = 1)
    )
  );

drop policy if exists "public can read published assignments" on public.n26_seat_assignments;
create policy "public can read current or published assignments"
  on public.n26_seat_assignments for select using (
    exists (
      select 1 from public.n26_seasons seasons
      where seasons.id = season_id
        and (seasons.status <> 'draft' or seasons.season_number = 1)
    )
  );
