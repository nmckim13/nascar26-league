-- BARL Season 1 follows the approved eight-race schedule.
update public.n26_season_races as r
set track_name = v.track_name,
    track_short = v.track_short
from public.n26_seasons as s
join (values
  (1, 'Daytona International Speedway', 'Daytona'),
  (2, 'Nashville Superspeedway', 'Nashville'),
  (3, 'Bristol Motor Speedway', 'Bristol'),
  (4, 'Watkins Glen International', 'Watkins Glen'),
  (5, 'Charlotte Motor Speedway', 'Charlotte'),
  (6, 'Iowa Speedway', 'Iowa'),
  (7, 'Talladega Superspeedway', 'Talladega'),
  (8, 'Chicagoland Speedway', 'Chicagoland')
) as v(race_number, track_name, track_short)
where r.season_id = s.id
  and v.race_number = r.race_number
  and s.season_number = 1;

-- Keep the legacy race table aligned for older public fallbacks.
update public.n26_races as r
set track_name = v.track_name,
    track_short = v.track_short
from (values
  (1, 'Daytona International Speedway', 'Daytona'),
  (2, 'Nashville Superspeedway', 'Nashville'),
  (3, 'Bristol Motor Speedway', 'Bristol'),
  (4, 'Watkins Glen International', 'Watkins Glen'),
  (5, 'Charlotte Motor Speedway', 'Charlotte'),
  (6, 'Iowa Speedway', 'Iowa'),
  (7, 'Talladega Superspeedway', 'Talladega'),
  (8, 'Chicagoland Speedway', 'Chicagoland')
) as v(race_number, track_name, track_short)
where r.race_number = v.race_number;
