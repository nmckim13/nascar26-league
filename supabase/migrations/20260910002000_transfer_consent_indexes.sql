-- Keep transfer-consent lookups and referential checks indexed as the market grows.
create index if not exists n26_transaction_consents_driver_idx
  on public.n26_transaction_consents (driver_id);

create index if not exists n26_transaction_consents_from_team_idx
  on public.n26_transaction_consents (from_team_id);

create index if not exists n26_transaction_consents_to_team_idx
  on public.n26_transaction_consents (to_team_id);

create index if not exists n26_transactions_consent_idx
  on public.n26_transactions (consent_id);
