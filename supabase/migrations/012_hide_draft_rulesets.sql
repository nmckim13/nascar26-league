-- Draft seasons and their unfinished scoring rules stay private.

drop policy if exists "public can read rulesets" on public.n26_rulesets;
create policy "public can read published rulesets"
  on public.n26_rulesets for select using (
    exists (
      select 1 from public.n26_seasons seasons
      where seasons.ruleset_id = id and seasons.status <> 'draft'
    )
  );
