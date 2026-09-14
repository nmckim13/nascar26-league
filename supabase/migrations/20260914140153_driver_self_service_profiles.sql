alter table public.n26_drivers
  add column if not exists auth_user_id uuid references auth.users (id) on delete set null;

create unique index if not exists n26_drivers_auth_user_id_unique
  on public.n26_drivers (auth_user_id)
  where auth_user_id is not null;

update public.n26_drivers drivers
set auth_user_id = claims.user_id
from public.n26_claims claims
where drivers.legacy_claim_id = claims.id
  and claims.approval_status = 'approved'
  and claims.user_id is not null
  and drivers.auth_user_id is null;

create or replace function public.n26_review_claim(
  p_claim_id uuid,
  p_decision text,
  p_reviewer uuid,
  p_season_id uuid default null
)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  claim_row public.n26_claims;
  sync_result jsonb := null;
begin
  if p_decision not in ('approved', 'rejected') then raise exception 'Decision must be approved or rejected' using errcode = '22023'; end if;
  select * into claim_row from public.n26_claims where id = p_claim_id for update;
  if claim_row.id is null then raise exception 'Application not found' using errcode = '02000'; end if;
  if claim_row.approval_status <> 'pending' then raise exception 'This application is no longer pending' using errcode = '23514'; end if;
  if p_decision = 'approved' and p_season_id is null then raise exception 'A draft season is required for approval' using errcode = '22023'; end if;

  update public.n26_claims set approval_status = p_decision, reviewed_at = now(), reviewed_by = p_reviewer
  where id = p_claim_id returning * into claim_row;

  if p_decision = 'approved' then
    sync_result := public.n26_sync_claims_to_draft(p_season_id);
    update public.n26_drivers set auth_user_id = claim_row.user_id
    where legacy_claim_id = claim_row.id;
  end if;
  return jsonb_build_object('application', to_jsonb(claim_row), 'sync', sync_result);
end;
$$;

revoke execute on function public.n26_review_claim(uuid, text, uuid, uuid) from public, anon, authenticated;
grant execute on function public.n26_review_claim(uuid, text, uuid, uuid) to service_role;
