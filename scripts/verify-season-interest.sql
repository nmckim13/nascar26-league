-- Run only in an empty, disposable local PostgreSQL database as a superuser.
-- All fixture objects and data roll back, matching the other SQL checks.
\set ON_ERROR_STOP on
begin;
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role bypassrls; end if;
end;
$$;
\ir ../supabase/migrations/20261027040000_season_two_interest.sql

-- Check ACLs independently of RLS (including PUBLIC's implicit membership).
do $$
declare
  role_name text;
  relation_name text;
  operation text;
begin
  foreach role_name in array array['anon', 'authenticated'] loop
    foreach relation_name in array array['n26_season_interest', 'n26_season_interest_rate_limits'] loop
      foreach operation in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'] loop
        if has_table_privilege(role_name, 'public.' || relation_name, operation) then
          raise exception 'Public PII/rate table privilege: % % %', role_name, relation_name, operation;
        end if;
      end loop;
      if not (select relrowsecurity from pg_class where oid = ('public.' || relation_name)::regclass) then
        raise exception 'Missing RLS';
      end if;
    end loop;
    if has_function_privilege(role_name, 'public.n26_submit_season_interest(text,text,text)', 'EXECUTE') then
      raise exception 'Public RPC execution';
    end if;
  end loop;
end;
$$;

set local role anon;
do $$
begin
  begin
    perform email from public.n26_season_interest;
    raise exception 'Anonymous email read allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform public.n26_submit_season_interest('anon@example.com', 'pc', repeat('a', 64));
    raise exception 'Anonymous RPC allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;
set local role authenticated;
do $$
begin
  begin
    insert into public.n26_season_interest (email, platform) values ('user@example.com', 'pc');
    raise exception 'Authenticated direct write allowed';
  exception when insufficient_privilege then null; end;
  begin
    perform client_hash from public.n26_season_interest_rate_limits;
    raise exception 'Authenticated rate table read allowed';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;

set local role service_role;
do $$
declare
  hash text := repeat('a', 64);
  original_row jsonb;
  original_window timestamptz;
  invalid text;
  i integer;
begin
  if not public.n26_submit_season_interest('  Racer@Example.COM  ', 'playstation', hash) then
    raise exception 'First submission rejected';
  end if;
  select to_jsonb(s) into original_row from public.n26_season_interest s where email = 'racer@example.com';
  if original_row is null or original_row->>'platform' <> 'playstation' or original_row->>'season_number' <> '2' then
    raise exception 'Normalization, fixed season, or platform failed';
  end if;
  if not public.n26_submit_season_interest('RACER@example.com', 'xbox', hash) then
    raise exception 'Duplicate was rejected';
  end if;
  if (select count(*) from public.n26_season_interest) <> 1
    or (select to_jsonb(s) from public.n26_season_interest s where email = 'racer@example.com') <> original_row then
    raise exception 'Duplicate mutated first platform/timestamp';
  end if;
  foreach invalid in array array['', 'PC', 'ps5', 'xbox ', 'switch', null] loop
    begin
      perform public.n26_submit_season_interest('invalid@example.com', invalid, hash);
      raise exception 'Invalid platform accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  foreach invalid in array array['', 'not-email', 'x@example', 'a..b@example.com', '.a@example.com', 'a.@example.com', 'a@-example.com', repeat('a', 65) || '@example.com', repeat('a', 250) || '@x.com', null] loop
    begin
      perform public.n26_submit_season_interest(invalid, 'pc', hash);
      raise exception 'Invalid email accepted';
    exception when invalid_parameter_value then null; end;
  end loop;
  begin
    perform public.n26_submit_season_interest('invalid@example.com', 'pc', '127.0.0.1');
    raise exception 'Raw IP accepted as hash';
  exception when invalid_parameter_value then null; end;
  if (select submissions from public.n26_season_interest_rate_limits where client_hash = hash) <> 2 then
    raise exception 'Invalid submissions consumed rate budget';
  end if;
  for i in 3..10 loop
    if not public.n26_submit_season_interest('racer' || i || '@example.com', case when i % 2 = 0 then 'xbox' else 'pc' end, hash) then
      raise exception 'Rate limit before ten attempts';
    end if;
  end loop;
  select window_started_at into original_window from public.n26_season_interest_rate_limits where client_hash = hash;
  for i in 11..20 loop
    if public.n26_submit_season_interest('blocked' || i || '@example.com', 'pc', hash) then
      raise exception 'Rate limit exceeded';
    end if;
  end loop;
  if (select count(*) from public.n26_season_interest) <> 9
    or (select count(*) from public.n26_season_interest_rate_limits) <> 1
    or (select window_started_at from public.n26_season_interest_rate_limits where client_hash = hash) <> original_window then
    raise exception 'Rate limit wrote entries/extra rows or extended window';
  end if;
  if not public.n26_submit_season_interest('independent@example.com', 'pc', repeat('b', 64)) then
    raise exception 'Independent client blocked';
  end if;
  update public.n26_season_interest_rate_limits set window_started_at = clock_timestamp() - interval '10 minutes' where client_hash = hash;
  if not public.n26_submit_season_interest('after-reset@example.com', 'xbox', hash) then
    raise exception 'Submission after reset rejected';
  end if;
  if (select submissions from public.n26_season_interest_rate_limits where client_hash = hash) <> 1
    or (select window_started_at from public.n26_season_interest_rate_limits where client_hash = hash) <= original_window then
    raise exception 'Rate window did not reset';
  end if;
end;
$$;
reset role;

-- Table constraints protect direct service-role inserts as well as the RPC.
do $$
begin
  begin
    insert into public.n26_season_interest (email, platform, season_number) values ('wrong-season@example.com', 'pc', 3);
    raise exception 'Season is not fixed to 2';
  exception when check_violation then null; end;
  begin
    insert into public.n26_season_interest (email, platform) values ('UPPER@example.com', 'pc');
    raise exception 'Unnormalized direct email accepted';
  exception when check_violation then null; end;
  begin
    insert into public.n26_season_interest (email, platform) values ('wrong-platform@example.com', 'PS5');
    raise exception 'Invalid direct platform accepted';
  exception when check_violation then null; end;
end;
$$;
rollback;
\echo 'Season interest migration verified: private ACL/RLS/RPC, normalization, duplicate immutability, validation, atomic rate budget and reset.'
