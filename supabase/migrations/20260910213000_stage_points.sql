-- Store official NASCAR-style stage points separately from finish points.
alter table public.n26_race_results
  add column if not exists stage1_points integer not null default 0,
  add column if not exists stage2_points integer not null default 0;

alter table public.n26_race_results
  drop constraint if exists n26_race_results_stage_points_check;

alter table public.n26_race_results
  add constraint n26_race_results_stage_points_check
  check (stage1_points between 0 and 10 and stage2_points between 0 and 10);

comment on column public.n26_race_results.stage1_points is 'Official NASCAR stage points, 10 through 1 for the top ten.';
comment on column public.n26_race_results.stage2_points is 'Official NASCAR stage points, 10 through 1 for the top ten.';

create or replace function public.n26_upsert_race_results_with_stages(
  p_race_id uuid,
  p_results jsonb,
  p_source_version text,
  p_corrected_by uuid
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  item jsonb;
  stage1 integer;
  stage2 integer;
  saved integer;
begin
  for item in select value from jsonb_array_elements(p_results)
  loop
    stage1 := coalesce(nullif(item->>'stage1_points', '')::integer, 0);
    stage2 := coalesce(nullif(item->>'stage2_points', '')::integer, 0);
    if stage1 not between 0 and 10 or stage2 not between 0 and 10 then
      raise exception 'Stage points must be between 0 and 10' using errcode = '23514';
    end if;
  end loop;

  saved := public.n26_upsert_race_results(p_race_id, p_results, p_source_version, p_corrected_by);

  update public.n26_race_results result_row
  set stage1_points = coalesce(nullif(item->>'stage1_points', '')::integer, 0),
      stage2_points = coalesce(nullif(item->>'stage2_points', '')::integer, 0),
      points_earned = result_row.points_earned
        - result_row.stage1_points
        - result_row.stage2_points
        + coalesce(nullif(item->>'stage1_points', '')::integer, 0)
        + coalesce(nullif(item->>'stage2_points', '')::integer, 0)
  from jsonb_array_elements(p_results) item
  where result_row.race_id = p_race_id
    and result_row.driver_id = (item->>'driver_id')::uuid;

  return saved;
end;
$$;

revoke execute on function public.n26_upsert_race_results_with_stages(uuid, jsonb, text, uuid) from public, anon, authenticated;
grant execute on function public.n26_upsert_race_results_with_stages(uuid, jsonb, text, uuid) to service_role;
