-- Restrict BARL commissioner authorization to Nolan's permanent Supabase account.
delete from public.n26_admin_users
where user_id <> '130733c5-8f1b-47bd-bd96-c5750f205065'::uuid;

insert into public.n26_admin_users (user_id)
values ('130733c5-8f1b-47bd-bd96-c5750f205065'::uuid)
on conflict (user_id) do nothing;

alter table public.n26_admin_users
  drop constraint if exists n26_admin_users_owner_only;

alter table public.n26_admin_users
  add constraint n26_admin_users_owner_only
  check (user_id = '130733c5-8f1b-47bd-bd96-c5750f205065'::uuid);

drop policy if exists "admins can verify their own access" on public.n26_admin_users;
revoke all on public.n26_admin_users from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) = '130733c5-8f1b-47bd-bd96-c5750f205065'::uuid
    and exists (
      select 1
      from public.n26_admin_users
      where user_id = '130733c5-8f1b-47bd-bd96-c5750f205065'::uuid
    );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

comment on table public.n26_admin_users is
  'Single-account commissioner allowlist. Changes require a database migration.';

comment on function public.is_admin() is
  'Returns true only for the permanent BARL commissioner account.';
