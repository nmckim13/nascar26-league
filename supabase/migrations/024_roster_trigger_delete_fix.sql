-- Return OLD for deletes so the lock trigger does not accidentally suppress
-- an allowed draft-season delete.

create or replace function public.n26_reject_locked_roster_change()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  season_id_value uuid;
  season_row public.n26_seasons;
begin
  season_id_value := case when tg_op = 'DELETE' then old.season_id else new.season_id end;
  select * into season_row from public.n26_seasons where id = season_id_value for update;
  if season_row.id is null
     or season_row.status not in ('draft', 'open')
     or (season_row.status = 'open' and season_row.roster_lock_at is not null) then
    raise exception 'Roster changes are blocked after the season roster lock' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke execute on function public.n26_reject_locked_roster_change() from public, anon, authenticated;
