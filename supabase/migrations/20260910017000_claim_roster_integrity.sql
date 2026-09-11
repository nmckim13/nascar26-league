-- Keep the public claim intake aligned with the normalized eight-team roster.
-- The team-row lock makes the three-seat check safe for concurrent claims.
create or replace function public.n26_validate_claim_roster()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  matched_team_id uuid;
  existing_claim_count integer;
begin
  select teams.id
  into matched_team_id
  from public.n26_teams teams
  join public.n26_team_car_numbers numbers on numbers.team_id = teams.id
  where teams.status = 'active'
    and numbers.car_number = new.car_number
    and lower(teams.name) = lower(btrim(new.team_name))
  for update of teams;

  if matched_team_id is null then
    raise exception 'The selected car does not belong to the selected active team' using errcode = '23514';
  end if;

  select count(*)
  into existing_claim_count
  from public.n26_claims claims
  where lower(btrim(claims.team_name)) = lower(btrim(new.team_name))
    and claims.id is distinct from new.id;

  if existing_claim_count >= 3 then
    raise exception 'A team may have no more than three claimed drivers' using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists n26_validate_claim_roster_trigger on public.n26_claims;
create trigger n26_validate_claim_roster_trigger
before insert or update on public.n26_claims
for each row execute function public.n26_validate_claim_roster();

revoke execute on function public.n26_validate_claim_roster() from public, anon, authenticated;
