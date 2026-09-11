-- Explicit commissioner allowlist for the admin API.
create table if not exists public.n26_admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.n26_admin_users enable row level security;

revoke all on public.n26_admin_users from anon;
grant select on public.n26_admin_users to authenticated;

drop policy if exists "admins can verify their own access" on public.n26_admin_users;
create policy "admins can verify their own access"
  on public.n26_admin_users
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

create or replace function public.is_admin()
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select exists (
    select 1
    from public.n26_admin_users
    where user_id = (select auth.uid())
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

insert into public.n26_admin_users (user_id)
values ('130733c5-8f1b-47bd-bd96-c5750f205065')
on conflict (user_id) do nothing;
