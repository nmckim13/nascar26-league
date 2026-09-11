-- Use the current NASCAR Cup Series race scale for BARL's 24-driver field.
update public.n26_rulesets
set points_by_position = '{"1":55,"2":35,"3":34,"4":33,"5":32,"6":31,"7":30,"8":29,"9":28,"10":27,"11":26,"12":25,"13":24,"14":23,"15":22,"16":21,"17":20,"18":19,"19":18,"20":17,"21":16,"22":15,"23":14,"24":13}'::jsonb,
    config = config || '{"points_schedule_status":"approved","points_scale":"nascar_cup_2026","stage_points":"10_to_1_top_10"}'::jsonb
where version = '2.0-24-driver-draft';
