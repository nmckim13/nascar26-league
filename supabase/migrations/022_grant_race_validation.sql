-- Internal validation is callable only by the commissioner RPC chain.

grant execute on function public.n26_validate_race_ready(uuid) to service_role;
