-- A driver may have one current contract per season. Historical contracts
-- remain available after they become released, traded, or expired.

create unique index if not exists n26_contracts_current_driver_unique
  on public.n26_contracts (season_id, driver_id)
  where status in ('introductory', 'active');
