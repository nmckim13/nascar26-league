-- Corrections during the appeal window reuse the authoritative upsert while
-- keeping the race publicly published and auditable.

create or replace function public.n26_correct_race_results(
  p_race_id uuid,
  p_results jsonb,
  p_source_version text default 'manual-correction-v1',
  p_corrected_by uuid default null
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  corrected_count integer;
begin
  select * into race_row from public.n26_season_races where id = p_race_id for update;
  if race_row.id is null then
    raise exception 'Race does not exist' using errcode = '23503';
  end if;
  if race_row.certification_status <> 'appeal_window'
     or race_row.appeal_ends_at is null
     or race_row.appeal_ends_at < now() then
    raise exception 'Corrections are only allowed during an open appeal window' using errcode = '42501';
  end if;

  -- The existing upsert intentionally rejects completed races. Temporarily
  -- reopen under the same row lock, then restore the public appeal state.
  update public.n26_season_races set status = 'open' where id = p_race_id;
  corrected_count := public.n26_upsert_race_results(p_race_id, p_results, p_source_version, p_corrected_by);
  update public.n26_race_results
  set certification_status = 'published'
  where race_id = p_race_id;
  update public.n26_season_races set status = 'completed' where id = p_race_id;
  return corrected_count;
end;
$$;

revoke execute on function public.n26_correct_race_results(uuid, jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.n26_correct_race_results(uuid, jsonb, text, uuid) to service_role;
