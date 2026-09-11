-- Legacy compatibility tables are no longer public data sources. Keep them
-- available to server-side diagnostics without exposing them through the Data API.
alter table public.n26_races enable row level security;
alter table public.n26_results enable row level security;

revoke all on public.n26_races, public.n26_results from anon, authenticated;
grant all on public.n26_races, public.n26_results to service_role;
