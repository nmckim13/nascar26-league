-- The trigger owner can execute this function without exposing it as an RPC.
revoke execute on function public.notify_discord_on_claim() from public;
revoke execute on function public.notify_discord_on_claim() from anon;
revoke execute on function public.notify_discord_on_claim() from authenticated;
