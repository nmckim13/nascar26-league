-- Race 6 moved from Iowa Speedway to Dover Motor Speedway.
update public.n26_season_races as race
set track_name = 'Dover Motor Speedway',
    track_short = 'Dover'
from public.n26_seasons as season
where race.season_id = season.id
  and race.race_number = 6
  and season.season_number = 1;

-- Keep the legacy public schedule aligned for older fallbacks.
update public.n26_races
set track_name = 'Dover Motor Speedway',
    track_short = 'Dover'
where race_number = 6;
