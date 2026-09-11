-- Every contract must retain the exact integer-cent cap charge used at signing.

alter table public.n26_contracts
  alter column cap_charge_cents set not null;
