-- Publish factual recaps atomically with results. No backfill: existing edited
-- reports stay intact unless their race is corrected or voided in the future.
create or replace function public.n26_sync_race_recap()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  track text := coalesce(nullif(new.track_name, ''), nullif(new.track_short, ''), 'Race ' || new.race_number);
  winner_name text;
  podium text;
  result_body text;
  recap_headline text;
  recap_dek text;
begin
  if new.status = 'voided' then
    update public.n26_news_articles
    set status = 'archived', updated_at = now()
    where race_id = new.id and generation_kind = 'race_recap';
    return new;
  end if;
  if new.status <> 'completed' or new.certification_status not in ('appeal_window', 'certified') then
    return new;
  end if;

  -- Positions are official: a DQ at P1 does not promote P2 to a winner.
  select coalesce(nullif(d.display_name, ''), nullif(d.gamertag, ''), 'Car #' || r.car_number)
  into winner_name
  from public.n26_race_results r join public.n26_drivers d on d.id = r.driver_id
  where r.race_id = new.id and r.finish_position = 1
    and r.start_status = 'started' and r.finish_status <> 'disqualified'
    and r.certification_status in ('published', 'certified');

  select string_agg(format('%s: %s (#%s)', r.finish_position,
    coalesce(nullif(d.display_name, ''), nullif(d.gamertag, ''), 'Car #' || r.car_number), r.car_number), '; ' order by r.finish_position)
  into podium
  from public.n26_race_results r join public.n26_drivers d on d.id = r.driver_id
  where r.race_id = new.id and r.finish_position between 1 and 3
    and r.start_status = 'started' and r.finish_status <> 'disqualified'
    and r.certification_status in ('published', 'certified');

  select string_agg(format('%s — %s — #%s — %s — %s points',
    case when r.start_status = 'dns' then 'DNS' else r.finish_position::text end,
    coalesce(nullif(d.display_name, ''), nullif(d.gamertag, ''), 'Car #' || r.car_number),
    r.car_number, case when r.start_status = 'dns' then 'dns' else r.finish_status end, r.points_earned),
    E'\n' order by r.finish_position nulls last, r.car_number)
  into result_body
  from public.n26_race_results r join public.n26_drivers d on d.id = r.driver_id
  where r.race_id = new.id and r.certification_status in ('published', 'certified');

  recap_headline := case when winner_name is not null
    then format('%s Wins at %s', winner_name, track)
    else format('Results Published at %s', track) end;
  recap_dek := format('Round %s at %s. %s', new.race_number, track,
    case when podium is not null then 'Official podium — ' || podium || '.'
    else 'See the published finishing order.' end);

  insert into public.n26_news_articles
    (season_id, race_id, headline, dek, body, status, published_at, generation_kind, generated_at, updated_at)
  values (new.season_id, new.id, left(recap_headline, 160), left(recap_dek, 500),
    recap_dek || E'\n\nPublished results:\n' || coalesce(result_body, ''),
    'published', coalesce(new.published_at, now()), 'race_recap', now(), now())
  on conflict (race_id, generation_kind) do update
    set season_id = excluded.season_id,
        headline = excluded.headline, dek = excluded.dek, body = excluded.body,
        status = 'published',
        published_at = coalesce(n26_news_articles.published_at, excluded.published_at),
        generated_at = excluded.generated_at, updated_at = excluded.updated_at;
  return new;
end;
$$;

revoke execute on function public.n26_sync_race_recap() from public, anon, authenticated;

-- Corrections temporarily reopen a race, then restore completed status after
-- updating all results. Generate only at that final transition, not per row.
-- Final certification does not rewrite an already published editorial recap.
create trigger n26_race_recap_publication
after update of status on public.n26_season_races
for each row
when (old.status is distinct from new.status)
execute function public.n26_sync_race_recap();
