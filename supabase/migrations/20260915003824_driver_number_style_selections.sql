create table if not exists public.n26_driver_number_styles (
  driver_id uuid not null references public.n26_drivers(id) on delete cascade,
  car_number text not null check (car_number ~ '^[0-9]{1,3}$'),
  style_key text not null check (char_length(style_key) between 3 and 120),
  updated_at timestamptz not null default now(),
  primary key (driver_id, car_number)
);

alter table public.n26_driver_number_styles enable row level security;

revoke all on table public.n26_driver_number_styles from anon, authenticated;
grant select on table public.n26_driver_number_styles to anon, authenticated;
grant all on table public.n26_driver_number_styles to service_role;

drop policy if exists "public can read driver number styles" on public.n26_driver_number_styles;
create policy "public can read driver number styles"
  on public.n26_driver_number_styles
  for select
  to anon, authenticated
  using (true);

comment on table public.n26_driver_number_styles is
  'Driver-selected number artwork by permanent driver identity and car number.';
