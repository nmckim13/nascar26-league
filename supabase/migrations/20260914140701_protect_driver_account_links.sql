revoke all on table public.n26_drivers from anon, authenticated;
grant select (id, display_name, gamertag, first_name, last_name, status)
  on public.n26_drivers to anon, authenticated;
