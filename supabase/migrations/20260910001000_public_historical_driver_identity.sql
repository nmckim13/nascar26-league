-- Preserve public driver identity for published season history without exposing drafts.
drop policy if exists "public can read active drivers" on public.n26_drivers;

create policy "public can read published driver identities"
  on public.n26_drivers for select using (
    status = 'active'
    or exists (
      select 1
      from public.n26_season_entries entries
      join public.n26_seasons seasons on seasons.id = entries.season_id
      where entries.driver_id = n26_drivers.id
        and seasons.status <> 'draft'
    )
  );
