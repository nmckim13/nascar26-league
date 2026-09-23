-- The Season 1 championship finale moved from Chicagoland to Rockingham.
update public.n26_season_races as race
set track_name = 'Rockingham Speedway',
    track_short = 'Rockingham'
from public.n26_seasons as season
where race.season_id = season.id
  and race.race_number = 8
  and season.season_number = 1;

-- Keep the legacy public schedule aligned for older fallbacks.
update public.n26_races
set track_name = 'Rockingham Speedway',
    track_short = 'Rockingham'
where race_number = 8;
