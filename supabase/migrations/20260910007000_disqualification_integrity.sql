-- Keep direct writes consistent with the published disqualification policy.
alter table public.n26_race_results
  drop constraint if exists n26_race_results_disqualification_integrity_check;

alter table public.n26_race_results
  add constraint n26_race_results_disqualification_integrity_check
  check (
    finish_status <> 'disqualified'
    or (start_status = 'started' and points_earned = 0)
  );
