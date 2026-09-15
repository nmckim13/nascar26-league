-- Keep the authorization check security-invoker so RLS remains the enforcement layer.
grant select on public.n26_admin_users to authenticated;

drop policy if exists "admins can verify their own access" on public.n26_admin_users;
create policy "admins can verify their own access"
  on public.n26_admin_users
  for select
  to authenticated
  using (
    (select auth.uid()) is not null
    and (select auth.uid()) = user_id
    and user_id = '130733c5-8f1b-47bd-bd96-c5750f205065'::uuid
  );

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
      and user_id = '130733c5-8f1b-47bd-bd96-c5750f205065'::uuid
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;
