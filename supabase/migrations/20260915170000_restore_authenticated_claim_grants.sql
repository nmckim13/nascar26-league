-- RLS still limits claims to the signed-in user's own row. These grants allow
-- PostgREST to reach that policy after the legacy table hardening migration.
grant select (user_id, car_number, gamertag, first_name, last_name)
  on public.n26_claims to authenticated;

grant insert (
  user_id,
  car_number,
  driver_name,
  team_name,
  gamertag,
  first_name,
  last_name,
  phone,
  discord_username,
  discord_user_id
)
  on public.n26_claims to authenticated;
