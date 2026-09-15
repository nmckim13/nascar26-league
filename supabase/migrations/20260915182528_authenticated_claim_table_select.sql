-- PostgREST needs table-level SELECT to return an inserted claim row.
-- RLS still limits authenticated drivers to the row owned by auth.uid().
grant select on table public.n26_claims to authenticated;
