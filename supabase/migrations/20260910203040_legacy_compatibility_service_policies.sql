create policy "service role manages legacy races"
  on public.n26_races for all to service_role
  using (true) with check (true);

create policy "service role manages legacy results"
  on public.n26_results for all to service_role
  using (true) with check (true);
