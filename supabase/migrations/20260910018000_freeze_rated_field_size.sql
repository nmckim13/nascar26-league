-- Preserve the rated entrant denominator used by championship rank ratings.
alter table public.n26_seasons
  add column if not exists rated_field_size integer;

alter table public.n26_seasons
  drop constraint if exists n26_seasons_rated_field_size_check;

alter table public.n26_seasons
  add constraint n26_seasons_rated_field_size_check
  check (rated_field_size is null or rated_field_size > 0);

alter table public.n26_rating_snapshots
  add column if not exists rated_field_size integer;

alter table public.n26_rating_snapshots
  drop constraint if exists n26_rating_snapshots_rated_field_size_check;

alter table public.n26_rating_snapshots
  add constraint n26_rating_snapshots_rated_field_size_check
  check (rated_field_size is null or rated_field_size > 0);

update public.n26_seasons seasons
set rated_field_size = rulesets.driver_count
from public.n26_rulesets rulesets
where seasons.ruleset_id = rulesets.id
  and seasons.roster_lock_at is not null
  and seasons.rated_field_size is null;

update public.n26_rating_snapshots snapshots
set rated_field_size = seasons.rated_field_size
from public.n26_seasons seasons
where snapshots.season_id = seasons.id
  and snapshots.rated_field_size is null
  and seasons.rated_field_size is not null;

create or replace function public.n26_freeze_rated_field_size()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  full_time_count integer;
begin
  if old.rated_field_size is not null
     and new.rated_field_size is distinct from old.rated_field_size then
    raise exception 'The rated field size is immutable after the season opens' using errcode = '23514';
  end if;

  if old.status = 'draft'
     and new.status <> 'draft' then
    select count(*) into full_time_count
    from public.n26_season_entries
    where season_id = new.id and entry_status = 'full_time';
    if full_time_count < 1 then
      raise exception 'A season needs full-time entries before opening' using errcode = '23514';
    end if;
    new.rated_field_size := full_time_count;
  end if;

  return new;
end;
$$;

drop trigger if exists n26_freeze_rated_field_size_trigger on public.n26_seasons;
create trigger n26_freeze_rated_field_size_trigger
before update on public.n26_seasons
for each row execute function public.n26_freeze_rated_field_size();

revoke execute on function public.n26_freeze_rated_field_size() from public, anon, authenticated;
