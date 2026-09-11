-- Trigger-only functions are implementation details, not Data API endpoints.
revoke execute on function public.n26_log_contract_signing() from public, anon, authenticated;
revoke execute on function public.n26_validate_contract_market() from public, anon, authenticated;
