-- Trades require an auditable attestation from the driver, releasing team,
-- and destination team. Initial assignments do not require trade consent.

create table if not exists public.n26_transaction_consents (
  id uuid primary key default gen_random_uuid(),
  season_id uuid not null references public.n26_seasons(id) on delete cascade,
  driver_id uuid not null references public.n26_drivers(id),
  from_team_id uuid not null references public.n26_teams(id),
  to_team_id uuid not null references public.n26_teams(id),
  from_car_number text not null,
  to_car_number text not null,
  driver_consented boolean not null default false,
  from_team_consented boolean not null default false,
  to_team_consented boolean not null default false,
  notes text,
  applied_at timestamptz,
  created_at timestamptz not null default now(),
  check (from_team_id <> to_team_id or from_car_number <> to_car_number)
);

alter table public.n26_transaction_consents enable row level security;
create policy "service role manages transaction consents"
  on public.n26_transaction_consents for all to service_role using (true) with check (true);

alter table public.n26_transactions
  add column if not exists consent_id uuid references public.n26_transaction_consents(id);

create index if not exists n26_transaction_consents_season_idx
  on public.n26_transaction_consents (season_id, driver_id, created_at desc);

create or replace function public.n26_assign_driver_to_seat(
  p_season_id uuid,
  p_driver_id uuid,
  p_team_id uuid,
  p_car_number text,
  p_allow_transfer boolean default false
)
returns public.n26_seat_assignments
language plpgsql
set search_path = public
as $$
declare
  current_assignment public.n26_seat_assignments;
  inserted_assignment public.n26_seat_assignments;
  consent_id_value uuid;
  transaction_id_value uuid;
  season_status text;
begin
  select status into season_status
  from public.n26_seasons
  where id = p_season_id
  for update;

  if season_status is null or season_status not in ('draft', 'open') then
    raise exception 'Roster changes are only allowed for draft or open seasons' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.n26_drivers where id = p_driver_id and status in ('active', 'reserve')
  ) then
    raise exception 'Driver does not exist or is not active' using errcode = '23503';
  end if;

  insert into public.n26_season_entries (season_id, driver_id, entry_status)
  values (p_season_id, p_driver_id, 'full_time')
  on conflict (season_id, driver_id) do update set entry_status = 'full_time';

  select * into current_assignment
  from public.n26_seat_assignments
  where season_id = p_season_id
    and driver_id = p_driver_id
    and assignment_status = 'active'
  for update;

  if current_assignment.id is not null then
    if not p_allow_transfer then
      raise exception 'Driver already has an active seat; enable transfer to move them' using errcode = '23505';
    end if;
    select id into consent_id_value
    from public.n26_transaction_consents
    where season_id = p_season_id
      and driver_id = p_driver_id
      and from_team_id = current_assignment.team_id
      and to_team_id = p_team_id
      and from_car_number = current_assignment.car_number
      and to_car_number = p_car_number
      and driver_consented
      and from_team_consented
      and to_team_consented
      and applied_at is null
    order by created_at desc
    limit 1
    for update;
    if consent_id_value is null then
      raise exception 'A driver, releasing team, and destination team consent is required for a transfer' using errcode = '42501';
    end if;
    update public.n26_seat_assignments
    set assignment_status = 'transferred', ends_at = now()
    where id = current_assignment.id;
  end if;

  insert into public.n26_seat_assignments (
    season_id, driver_id, team_id, car_number, starts_at, assignment_status
  )
  values (
    p_season_id, p_driver_id, p_team_id, p_car_number, now(), 'active'
  )
  returning * into inserted_assignment;

  insert into public.n26_transactions (
    season_id, driver_id, from_team_id, to_team_id,
    from_car_number, to_car_number, transaction_type, consent_id, notes
  )
  values (
    p_season_id,
    p_driver_id,
    current_assignment.team_id,
    p_team_id,
    current_assignment.car_number,
    p_car_number,
    case when current_assignment.id is null then 'signing' else 'trade' end,
    consent_id_value,
    case when current_assignment.id is null then 'Initial seat assignment' else 'Seat transfer with recorded consent' end
  )
  returning id into transaction_id_value;

  if consent_id_value is not null then
    update public.n26_transaction_consents
    set applied_at = now()
    where id = consent_id_value;
  end if;

  return inserted_assignment;
end;
$$;

create or replace function public.n26_transfer_driver_to_seat(
  p_season_id uuid,
  p_driver_id uuid,
  p_team_id uuid,
  p_car_number text,
  p_driver_consented boolean,
  p_from_team_consented boolean,
  p_to_team_consented boolean,
  p_notes text default null
)
returns public.n26_seat_assignments
language plpgsql
set search_path = public
as $$
declare
  current_assignment public.n26_seat_assignments;
  season_status text;
  inserted_consent public.n26_transaction_consents;
  inserted_assignment public.n26_seat_assignments;
begin
  if not coalesce(p_driver_consented, false)
     or not coalesce(p_from_team_consented, false)
     or not coalesce(p_to_team_consented, false) then
    raise exception 'All three transfer consents are required' using errcode = '42501';
  end if;

  select status into season_status
  from public.n26_seasons
  where id = p_season_id
  for update;
  if season_status is null or season_status not in ('draft', 'open') then
    raise exception 'Roster changes are only allowed for draft or open seasons' using errcode = '42501';
  end if;

  select * into current_assignment
  from public.n26_seat_assignments
  where season_id = p_season_id
    and driver_id = p_driver_id
    and assignment_status = 'active'
  for update;
  if current_assignment.id is null then
    raise exception 'A transfer requires an existing active seat; use initial assignment instead' using errcode = '23514';
  end if;

  insert into public.n26_transaction_consents (
    season_id, driver_id, from_team_id, to_team_id,
    from_car_number, to_car_number,
    driver_consented, from_team_consented, to_team_consented, notes
  ) values (
    p_season_id, p_driver_id, current_assignment.team_id, p_team_id,
    current_assignment.car_number, p_car_number,
    true, true, true, nullif(trim(p_notes), '')
  ) returning * into inserted_consent;

  select * into inserted_assignment
  from public.n26_assign_driver_to_seat(
    p_season_id, p_driver_id, p_team_id, p_car_number, true
  );
  return inserted_assignment;
end;
$$;

revoke execute on function public.n26_assign_driver_to_seat(uuid, uuid, uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.n26_transfer_driver_to_seat(uuid, uuid, uuid, text, boolean, boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.n26_assign_driver_to_seat(uuid, uuid, uuid, text, boolean) to service_role;
grant execute on function public.n26_transfer_driver_to_seat(uuid, uuid, uuid, text, boolean, boolean, boolean, text) to service_role;
