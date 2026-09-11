-- Make the private commissioner tables explicit in RLS and cover their FKs.

create policy "service role manages contracts"
  on public.n26_contracts for all to service_role using (true) with check (true);

create policy "service role manages transactions"
  on public.n26_transactions for all to service_role using (true) with check (true);

create policy "service role manages result corrections"
  on public.n26_result_corrections for all to service_role using (true) with check (true);

create index if not exists n26_seasons_ruleset_idx
  on public.n26_seasons (ruleset_id);

create index if not exists n26_result_corrections_driver_idx
  on public.n26_result_corrections (driver_id, created_at desc);

create index if not exists n26_result_corrections_result_idx
  on public.n26_result_corrections (result_id);

create index if not exists n26_result_corrections_corrected_by_idx
  on public.n26_result_corrections (corrected_by);
