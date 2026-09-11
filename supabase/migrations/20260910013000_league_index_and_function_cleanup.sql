-- Remove avoidable advisor findings without changing league behavior.
create index if not exists n26_public_team_season_summary_team_idx
  on public.n26_public_team_season_summary (team_id, season_id);

-- The legacy table already has an equivalent unique constraint index.
drop index if exists public.n26_claims_car_number_unique;

-- Keep the webhook trigger's object lookup path deterministic.
alter function public.notify_discord_on_claim()
  set search_path = public, net, pg_temp;
