-- A published season is open for racing but its roster is locked. Enforce the
-- distinction for direct service-role writes as well as the commissioner UI.

create or replace function public.n26_reject_locked_roster_change()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  season_row public.n26_seasons;
begin
  select * into season_row
  from public.n26_seasons
  where id = coalesce(new.season_id, old.season_id)
  for update;
  if season_row.id is null
     or season_row.status not in ('draft', 'open')
     or (season_row.status = 'open' and season_row.roster_lock_at is not null) then
    raise exception 'Roster changes are blocked after the season roster lock' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists n26_roster_lock_seat_trigger on public.n26_seat_assignments;
create trigger n26_roster_lock_seat_trigger
before insert or update or delete on public.n26_seat_assignments
for each row execute function public.n26_reject_locked_roster_change();

drop trigger if exists n26_roster_lock_entry_trigger on public.n26_season_entries;
create trigger n26_roster_lock_entry_trigger
before insert or update or delete on public.n26_season_entries
for each row execute function public.n26_reject_locked_roster_change();

revoke execute on function public.n26_reject_locked_roster_change() from public, anon, authenticated;
