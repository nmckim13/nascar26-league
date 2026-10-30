-- Apply after the Hendrick red artwork is deployed. Change only Nolan's
-- saved #88 artwork, not his driver identity, roster, results or other choices.
insert into public.n26_driver_number_styles (driver_id, car_number, style_key)
select id, '88', '88:hendrick-red'
from public.n26_drivers
where id = '4a926a39-ea23-47c0-a493-f070567dfa6a'
on conflict (driver_id, car_number) do update
set style_key = excluded.style_key, updated_at = now()
where n26_driver_number_styles.style_key is distinct from excluded.style_key;
