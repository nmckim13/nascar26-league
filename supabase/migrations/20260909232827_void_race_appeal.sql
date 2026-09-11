-- A published race may be voided during its open appeal window, but not
-- after final certification.

create or replace function public.n26_void_race(
  p_race_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  race_row public.n26_season_races;
  updated_race public.n26_season_races;
begin
  if nullif(trim(p_reason), '') is null then
    raise exception 'A reason is required to void a race' using errcode = '22023';
  end if;

  select * into race_row
  from public.n26_season_races
  where id = p_race_id
  for update;
  if race_row.id is null then
    raise exception 'Race not found' using errcode = '02000';
  end if;
  if not (
    (race_row.status in ('upcoming', 'open') and race_row.certification_status = 'draft')
    or (race_row.status = 'completed'
        and race_row.certification_status = 'appeal_window'
        and race_row.appeal_ends_at > now())
  ) then
    raise exception 'Only an upcoming/open draft race or a race in its appeal window can be voided' using errcode = '42501';
  end if;

  update public.n26_season_races
  set status = 'voided',
      certification_status = 'certified',
      voided_at = now(),
      void_reason = trim(p_reason),
      published_at = null,
      appeal_ends_at = null
  where id = p_race_id
  returning * into updated_race;

  return jsonb_build_object(
    'race_id', updated_race.id,
    'status', updated_race.status,
    'certification_status', updated_race.certification_status,
    'void_reason', updated_race.void_reason
  );
end;
$$;

revoke execute on function public.n26_void_race(uuid, text) from public, anon, authenticated;
grant execute on function public.n26_void_race(uuid, text) to service_role;
