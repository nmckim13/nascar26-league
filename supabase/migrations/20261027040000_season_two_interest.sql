-- A private recruitment list, independent of accounts and season publication.
create table public.n26_season_interest (
  season_number integer not null default 2 check (season_number = 2),
  email text primary key check (
    email = lower(btrim(email)) and char_length(email) <= 254
    and email ~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
    and char_length(split_part(email, '@', 1)) <= 64
    and split_part(email, '@', 1) !~ '(^\.|\.$|\.\.)'
  ),
  platform text not null check (platform in ('playstation', 'xbox', 'pc')),
  created_at timestamptz not null default now()
);
create index n26_season_interest_newest on public.n26_season_interest (created_at desc);

-- One rolling window per HMAC, never the raw client IP. Duplicate attempts
-- consume the same budget as new submissions but never modify the interest row.
create table public.n26_season_interest_rate_limits (
  client_hash text primary key check (client_hash ~ '^[0-9a-f]{64}$'),
  window_started_at timestamptz not null,
  submissions integer not null check (submissions between 1 and 10)
);

alter table public.n26_season_interest enable row level security;
alter table public.n26_season_interest_rate_limits enable row level security;
revoke all on public.n26_season_interest, public.n26_season_interest_rate_limits from public, anon, authenticated, service_role;
grant select, insert on public.n26_season_interest to service_role;
grant select, insert, update on public.n26_season_interest_rate_limits to service_role;
create policy "service role reads interest" on public.n26_season_interest
  for select to service_role using (true);
create policy "service role inserts interest" on public.n26_season_interest
  for insert to service_role with check (true);
create policy "service role manages interest rate windows" on public.n26_season_interest_rate_limits
  for all to service_role using (true) with check (true);

create function public.n26_submit_season_interest(p_email text, p_platform text, p_client_hash text)
returns boolean
language plpgsql
security invoker
set search_path = public
as $$
declare
  normalized_email text := lower(btrim(p_email));
  request_time timestamptz := clock_timestamp();
  counted integer;
begin
  -- Validate even for service callers, before consuming any rate budget.
  if normalized_email is null or char_length(normalized_email) > 254
    or normalized_email !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
    or char_length(split_part(normalized_email, '@', 1)) > 64
    or split_part(normalized_email, '@', 1) ~ '(^\.|\.$|\.\.)'
    or p_platform is null or p_platform not in ('playstation', 'xbox', 'pc')
    or p_client_hash is null or p_client_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid interest submission' using errcode = '22023';
  end if;

  -- ON CONFLICT takes a row lock: concurrent requests cannot exceed ten.
  -- Exhausted windows return no row and do not extend their reset time.
  insert into public.n26_season_interest_rate_limits as limits (client_hash, window_started_at, submissions)
  values (p_client_hash, request_time, 1)
  on conflict (client_hash) do update
    set window_started_at = case when limits.window_started_at <= request_time - interval '10 minutes'
          then request_time else limits.window_started_at end,
        submissions = case when limits.window_started_at <= request_time - interval '10 minutes'
          then 1 else limits.submissions + 1 end
    where limits.window_started_at <= request_time - interval '10 minutes' or limits.submissions < 10
  returning submissions into counted;
  if counted is null then return false; end if;

  insert into public.n26_season_interest (email, platform)
  values (normalized_email, p_platform)
  on conflict (email) do nothing;
  return true;
end;
$$;
revoke execute on function public.n26_submit_season_interest(text, text, text) from public, anon, authenticated;
grant execute on function public.n26_submit_season_interest(text, text, text) to service_role;
