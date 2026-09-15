-- Notify the BARL Discord integration only after the commissioner approves a claim.
-- The shared secret is stored separately in Supabase Vault under this name:
-- n26_discord_webhook_secret
create extension if not exists pg_net with schema extensions;

create or replace function public.notify_discord_on_claim()
returns trigger
language plpgsql
security definer
set search_path = public, net, vault, pg_temp
as $$
declare
  webhook_secret text;
  request_id bigint;
begin
  if new.approval_status <> 'approved'
     or old.approval_status is not distinct from new.approval_status then
    return new;
  end if;

  select decrypted_secret
    into webhook_secret
  from vault.decrypted_secrets
  where name = 'n26_discord_webhook_secret'
  limit 1;

  if coalesce(webhook_secret, '') = '' then
    raise exception 'BARL Discord webhook secret is not configured';
  end if;

  select net.http_post(
    url := 'https://nascar26-league.vercel.app/api/claim-webhook',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', webhook_secret
    ),
    body := jsonb_build_object(
      'type', 'UPDATE',
      'table', 'n26_claims',
      'schema', 'public',
      'record', jsonb_build_object(
        'id', new.id,
        'car_number', new.car_number,
        'gamertag', new.gamertag,
        'team_name', new.team_name,
        'discord_username', new.discord_username,
        'discord_user_id', new.discord_user_id,
        'approval_status', new.approval_status
      ),
      'old_record', jsonb_build_object(
        'approval_status', old.approval_status
      )
    ),
    timeout_milliseconds := 10000
  ) into request_id;

  if request_id is null then
    raise exception 'BARL Discord webhook could not be queued';
  end if;

  return new;
end;
$$;

revoke all on function public.notify_discord_on_claim() from public;

drop trigger if exists n26_notify_discord_on_approval on public.n26_claims;
create trigger n26_notify_discord_on_approval
after update of approval_status on public.n26_claims
for each row
when (
  old.approval_status is distinct from new.approval_status
  and new.approval_status = 'approved'
)
execute function public.notify_discord_on_claim();
