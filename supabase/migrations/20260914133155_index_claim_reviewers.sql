create index if not exists n26_claims_reviewed_by_idx
  on public.n26_claims (reviewed_by)
  where reviewed_by is not null;
