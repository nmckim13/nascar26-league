'use strict';

const assert = require('node:assert/strict');
const structure = require('../data/league-structure.json');
const {
  calculateCapChargeCents,
  calculateEqualLeagueCap,
  calculateMinimumFeasibleCap,
  calculateRating,
  calculateChampionshipPoints,
  calculateSeasonStats,
  calculateSeasonStandings,
  calculateStandings,
  calculateTeamStandings,
  rankDrivers,
  roundHalfUp,
  requireValidStructure,
  validateRosterAssignments,
  validatePointsSchedule,
} = require('./league-rules');

requireValidStructure(structure);

const complete24PointSchedule = Object.fromEntries(Array.from({ length: 24 }, (_, index) => [String(index + 1), Math.max(0, 25 - index)]));
assert.deepEqual(validatePointsSchedule(complete24PointSchedule), []);
assert.match(validatePointsSchedule({ '1': 25, '2': 20 }).join(' '), /exactly positions 1 through 24/);
assert.match(validatePointsSchedule({ ...complete24PointSchedule, '13': -1 }).join(' '), /non-negative integer/);
assert.match(validatePointsSchedule({ ...complete24PointSchedule, '13': 20 }).join(' '), /non-increasing/);

assert.equal(structure.teams.length, 8);
assert.equal(structure.teams.flatMap(team => team.carNumbers).length, 26);

const assignments = structure.teams.flatMap((team, teamIndex) => (
  team.carNumbers.slice(0, 3).map((carNumber, seatIndex) => ({
    driverId: `driver-${teamIndex}-${seatIndex}`,
    teamId: team.id,
    carNumber,
  }))
));
assert.equal(validateRosterAssignments(structure, assignments).valid, true);
assert.equal(validateRosterAssignments(structure, [
  ...assignments.filter(assignment => assignment.carNumber !== '9'),
  { driverId: 'new-driver', teamId: 'hendrick', carNumber: '48' },
]).valid, true);

const raceStarts = [12, 10, 12, 11, 12, 12, 11, 10];
const finishes = [6, 1, 3, 3, 6, 2, 1, 1];
const qualifyingFields = [12, 10, 12, 11, 12, 12, 11, 10];
const qualifyingPositions = [2, 3, 4, 5, 3, 1, 2, 2];
const finishCredits = finishes.reduce((total, finish, index) => (
  total + ((raceStarts[index] + 1 - finish) / raceStarts[index])
), 0);
const qualifyingCredits = qualifyingPositions.reduce((total, position, index) => (
  total + ((qualifyingFields[index] + 1 - position) / qualifyingFields[index])
), 0);

const rating = calculateRating({
  rank: 1,
  fieldSize: 12,
  seasonLength: 8,
  starts: 8,
  wins: 3,
  finishCredits,
  qualifyingCredits,
  qualifyingRounds: 8,
});

assert.equal(rating.overall, 95);
assert.equal(calculateCapChargeCents(88, 200, 100), 8536);
assert.equal(calculateCapChargeCents(82, 0, 100), 8118);

const capSearch = calculateMinimumFeasibleCap([95, 93, 88, 82, 82, 80, 81, 75, 73, 70, 66, 61]);
assert.equal(capSearch.minimumMax, 237);
assert.equal(calculateEqualLeagueCap(capSearch.minimumMax), 240);
assert.equal(capSearch.combinationsChecked > 0, true);
assert.equal(calculateEqualLeagueCap(180), 240);
assert.equal(calculateEqualLeagueCap(240), 240);
assert.equal(calculateEqualLeagueCap(241), 245);

assert.equal(roundHalfUp(82.5), 83);
assert.equal(calculateRating({ starts: 0 }).overall, 40);
assert.equal(calculateRating({
  rank: 12,
  fieldSize: 12,
  seasonLength: 8,
  starts: 8,
  wins: 0,
  finishCredits: 8 / 12,
  qualifyingCredits: 8 / 12,
  qualifyingRounds: 8,
}).overall, 59);
assert.equal(calculateRating({
  rank: 1,
  fieldSize: 12,
  seasonLength: 8,
  starts: 8,
  wins: 8,
  finishCredits: 8,
  qualifyingCredits: 8,
  qualifyingRounds: 8,
}).overall, 100);
const oneRaceRinger = calculateRating({
  rank: 1,
  fieldSize: 12,
  seasonLength: 8,
  starts: 1,
  wins: 1,
  finishCredits: 1,
  qualifyingCredits: 1,
  qualifyingRounds: 1,
});
assert.equal(oneRaceRinger.attendance, 47.5);
assert.equal(oneRaceRinger.overall >= 40 && oneRaceRinger.overall <= 100, true);
assert.equal(calculateCapChargeCents(95, 400, 100), 9025);

const edgeEntries = [
  { driverId: 'a', entryStatus: 'full_time' },
  { driverId: 'b', entryStatus: 'full_time' },
];
const edgeRaces = [
  { id: 'valid', status: 'completed', startersCount: 2, qualifyingStatus: 'canceled' },
  { id: 'voided', status: 'voided', startersCount: 2, qualifyingStatus: 'valid' },
];
const edgeResults = [
  { raceId: 'valid', driverId: 'a', startStatus: 'started', finishPosition: 1, finishStatus: 'classified' },
  { raceId: 'valid', driverId: 'b', startStatus: 'dns', finishPosition: null, finishStatus: 'classified' },
  { raceId: 'voided', driverId: 'a', startStatus: 'started', finishPosition: 1, finishStatus: 'classified' },
];
const edgeStats = calculateSeasonStats({
  entries: edgeEntries,
  races: edgeRaces,
  results: edgeResults,
  pointsByPosition: { '1': 25, '2': 20 },
  strict: true,
});
assert.equal(edgeStats.completedRaces.length, 1);
assert.equal(edgeStats.stats.find(driver => driver.driverId === 'a').points, 25);
assert.equal(edgeStats.stats.find(driver => driver.driverId === 'b').starts, 0);

const excludedRoundStats = calculateSeasonStats({
  entries: [{ driverId: 'a', entryStatus: 'full_time' }],
  races: [
    { id: 'exhibition', status: 'completed', raceType: 'exhibition', startersCount: 2, qualifyingStatus: 'canceled' },
    { id: 'undersized', status: 'completed', startersCount: 1, qualifyingStatus: 'canceled' },
  ],
  results: [
    { raceId: 'exhibition', driverId: 'a', startStatus: 'started', finishPosition: 1 },
    { raceId: 'undersized', driverId: 'a', startStatus: 'started', finishPosition: 1 },
  ],
  pointsByPosition: { '1': 25 },
  strict: true,
});
assert.equal(excludedRoundStats.completedRaces.length, 0);
assert.equal(excludedRoundStats.stats[0].starts, 0);
assert.equal(excludedRoundStats.stats[0].points, 0);

const qualifyingDenominator = calculateSeasonStats({
  entries: [{ driverId: 'a', entryStatus: 'full_time' }],
  races: [
    { id: 'q1', status: 'completed', startersCount: 2, qualifyingStatus: 'valid', qualifyingFieldCount: 2 },
    { id: 'q2', status: 'completed', startersCount: 2, qualifyingStatus: 'valid', qualifyingFieldCount: 2 },
  ],
  results: [
    { raceId: 'q1', driverId: 'a', startStatus: 'started', finishPosition: 1, qualifyingValid: true, qualifyingPosition: 1 },
    { raceId: 'q2', driverId: 'a', startStatus: 'dns', finishPosition: null, finishStatus: 'classified', qualifyingValid: false },
  ],
  pointsByPosition: { '1': 25 },
  strict: true,
}).stats[0];
assert.equal(qualifyingDenominator.qualifyingRounds, 2);
assert.equal(qualifyingDenominator.qualifyingCredits, 1);

const canceledQualifying = calculateSeasonStats({
  entries: [{ driverId: 'canceled-driver', entryStatus: 'full_time' }],
  races: [{ id: 'canceled', status: 'completed', startersCount: 2, qualifyingStatus: 'canceled' }],
  results: [{
    raceId: 'canceled', driverId: 'canceled-driver', startStatus: 'started',
    finishStatus: 'dnf', finishPosition: 1,
  }],
  pointsByPosition: { '1': 25 },
  strict: true,
}).stats[0];
assert.equal(canceledQualifying.qualifyingRounds, 0);
assert.equal(calculateRating({
  rank: 1,
  fieldSize: 1,
  seasonLength: 1,
  starts: canceledQualifying.starts,
  wins: canceledQualifying.wins,
  finishCredits: canceledQualifying.finishCredits,
  qualifyingCredits: canceledQualifying.qualifyingCredits,
  qualifyingRounds: canceledQualifying.qualifyingRounds,
}).qualifying, 40);

const reserveAndDisconnect = calculateSeasonStats({
  entries: [
    { driverId: 'full-time', entryStatus: 'full_time' },
    { driverId: 'reserve', entryStatus: 'reserve' },
  ],
  races: [{ id: 'disconnect', status: 'completed', startersCount: 2, qualifyingStatus: 'canceled' }],
  results: [
    { raceId: 'disconnect', driverId: 'full-time', startStatus: 'started', finishStatus: 'dnf', finishPosition: 2 },
    { raceId: 'disconnect', driverId: 'reserve', startStatus: 'dns', finishStatus: 'classified', finishPosition: null },
  ],
  pointsByPosition: { '1': 25, '2': 20 },
  strict: true,
}).stats;
assert.equal(reserveAndDisconnect.find(driver => driver.driverId === 'full-time').starts, 1);
assert.equal(reserveAndDisconnect.find(driver => driver.driverId === 'full-time').dnfs, 1);
assert.equal(reserveAndDisconnect.find(driver => driver.driverId === 'reserve').starts, 0);

const reserveTeamStandings = calculateSeasonStandings({
  entries: [
    { driverId: 'full-time', teamId: 'team-a', entryStatus: 'full_time' },
    { driverId: 'reserve', teamId: 'team-a', entryStatus: 'reserve' },
  ],
  races: [{ id: 'reserve-race', status: 'completed', startersCount: 2, qualifyingStatus: 'canceled' }],
  results: [
    { raceId: 'reserve-race', driverId: 'full-time', teamId: 'team-a', startStatus: 'started', finishStatus: 'classified', finishPosition: 1, pointsEarned: 25 },
    { raceId: 'reserve-race', driverId: 'reserve', teamId: 'team-a', startStatus: 'started', finishStatus: 'classified', finishPosition: 2, pointsEarned: 20 },
  ],
  pointsByPosition: { '1': 25, '2': 20 },
  strict: true,
});
assert.equal(reserveTeamStandings.drivers.find(driver => driver.driverId === 'reserve').points, 0);
assert.equal(reserveTeamStandings.teams.find(team => team.teamId === 'team-a').points, 45);

const incompleteSourceData = calculateSeasonStats({
  entries: [{ driverId: 'incomplete-driver', entryStatus: 'full_time' }],
  races: [{ id: 'incomplete-race', status: 'completed', qualifyingStatus: 'canceled' }],
  results: [{ raceId: 'incomplete-race', driverId: 'incomplete-driver', startStatus: 'started', finishStatus: 'classified', finishPosition: 1 }],
  pointsByPosition: { '1': 25 },
  strict: false,
}).stats[0];
assert.equal(incompleteSourceData.points, 25);
assert.equal(Number.isNaN(incompleteSourceData.finishCredits), false);
assert.equal(incompleteSourceData.finishCredits, 0);

const disqualificationStats = calculateSeasonStats({
  entries: [
    { driverId: 'dq-driver', entryStatus: 'full_time' },
    { driverId: 'classified-driver', entryStatus: 'full_time' },
  ],
  races: [{
    id: 'dq-race', status: 'completed', startersCount: 2,
    qualifyingStatus: 'valid', qualifyingFieldCount: 2,
  }],
  results: [
    {
      raceId: 'dq-race', driverId: 'dq-driver', startStatus: 'started',
      finishStatus: 'disqualified', finishPosition: 1,
      qualifyingValid: true, qualifyingPosition: 1,
    },
    {
      raceId: 'dq-race', driverId: 'classified-driver', startStatus: 'started',
      finishStatus: 'classified', finishPosition: 2,
      qualifyingValid: true, qualifyingPosition: 2,
    },
  ],
  pointsByPosition: { '1': 25, '2': 20 },
  strict: true,
}).stats;
const disqualified = disqualificationStats.find(driver => driver.driverId === 'dq-driver');
assert.equal(disqualified.starts, 1);
assert.equal(disqualified.points, 0);
assert.equal(disqualified.wins, 0);
assert.equal(disqualified.topFives, 0);
assert.equal(disqualified.finishCredits, 0);
assert.equal(disqualified.qualifyingCredits, 1);

const tieDrivers = rankDrivers([
  { driverId: 'a', points: 0, wins: 0, finishes: [], raceResults: new Map() },
  { driverId: 'b', points: 0, wins: 0, finishes: [], raceResults: new Map() },
], []);
assert.equal(tieDrivers[0].ratingRank, 1.5);
assert.equal(tieDrivers[1].ratingRank, 1.5);

const tiedTeams = calculateTeamStandings([
  { driverId: 'a', teamId: 'team-a', points: 25, wins: 1, finishes: [1], raceResults: new Map([['r1', { teamId: 'team-a', finishPosition: 1, pointsEarned: 25 }]]) },
  { driverId: 'b', teamId: 'team-b', points: 25, wins: 1, finishes: [1], raceResults: new Map([['r1', { teamId: 'team-b', finishPosition: 1, pointsEarned: 25 }]]) },
], [{ id: 'r1' }]);
assert.equal(tiedTeams[0].rank, 1);
assert.equal(tiedTeams[1].rank, 1);
assert.equal(calculateMinimumFeasibleCap(Array(24).fill(50)).minimumMax, 150);

const transferTeams = calculateTeamStandings([
  {
    driverId: 'transferred-driver',
    teamId: 'team-b',
    points: 45,
    wins: 2,
    finishes: [1, 2],
    raceResults: new Map([
      ['r1', { teamId: 'team-a', finishPosition: 1, pointsEarned: 25 }],
      ['r2', { teamId: 'team-b', finishPosition: 2, pointsEarned: 20 }],
    ]),
  },
], [{ id: 'r1' }, { id: 'r2' }]);
assert.equal(transferTeams.find(team => team.teamId === 'team-a').points, 25);
assert.equal(transferTeams.find(team => team.teamId === 'team-b').points, 20);

console.log('League model verified: 8 teams, 24 seats, #88 OVR 95, cap charges exact.');


// Eight rounds, one lowest score removed. Missing rows and DNS are equivalent.
const dropRaces = Array.from({ length: 8 }, (_, i) => ({
  id: `drop-${i + 1}`, status: 'completed', starters_count: 2, qualifying_status: 'canceled',
}));
const dropResults = dropRaces.map((race, i) => ({
  race_id: race.id, driver_id: 'drop-driver', team_id: 'drop-team',
  start_status: 'started', finish_position: i === 0 ? 2 : 1,
  points_earned: i === 0 ? 20 : 25,
}));
const dropInput = { entries: [{ driverId: 'drop-driver', teamId: 'drop-team' }],
  races: dropRaces, results: dropResults, pointsByPosition: { 1: 25, 2: 20 } };
const droppedSeason = calculateSeasonStandings(dropInput);
assert.equal(droppedSeason.drivers[0].rawPoints, 195);
assert.equal(droppedSeason.drivers[0].points, 175); // Drop P2, retain all seven wins.
assert.equal(droppedSeason.drivers[0].droppedPoints, 20);
assert.equal(droppedSeason.drivers[0].droppedRaceIds.length, 1);
assert.equal(droppedSeason.drivers[0].starts, 8);
assert.equal(droppedSeason.drivers[0].wins, 7);
assert.equal(droppedSeason.teams[0].points, 195);
const dnsRow = { ...dropResults[0], start_status: 'dns', finish_position: null, points_earned: 0 };
assert.equal(calculateChampionshipPoints(dropRaces, [dnsRow, ...dropResults.slice(1)]).points, 175);
assert.equal(calculateChampionshipPoints(dropRaces, dropResults.slice(1)).points, 175);
assert.equal(calculateChampionshipPoints(dropRaces, dropResults.slice(2)).points, 150); // Two absences: only one zero is discarded.
assert.equal(calculateChampionshipPoints(dropRaces.slice(0, 7), dropResults).points, 150);
assert.equal(calculateChampionshipPoints(dropRaces.slice(0, 1), dropResults).points, 0);
assert.equal(calculateChampionshipPoints([], dropResults).points, 0);
for (const excluded of [{ status: 'scheduled' }, { status: 'voided' }, { race_type: 'exhibition' }, { starters_count: 1 }]) {
  assert.equal(calculateChampionshipPoints([{ ...dropRaces[0], ...excluded }, ...dropRaces.slice(1)], dropResults).points, 150);
}
assert.equal(calculateChampionshipPoints(dropRaces, [...dropResults.slice(0, 7), { ...dropResults[7], finish_status: 'disqualified' }]).points, 170);
const corrected = dropResults.map((row, i) => i === 0 ? { ...row, points_earned: 10 } : row);
assert.equal(calculateChampionshipPoints(dropRaces, corrected).points, 175);
assert.deepEqual(calculateChampionshipPoints([...dropRaces].reverse(), [...dropResults].reverse()), calculateChampionshipPoints(dropRaces, dropResults));
assert.throws(() => calculateSeasonStandings({ ...dropInput, results: dropResults.slice(1) }), /Missing result row/);
// Legacy stage fields cannot inflate finish-only rules or pass certification.
const legacyStageResults = dropResults.map(row => ({ ...row, stage1_points: 10, stage2_points: 6 }));
assert.equal(calculateSeasonStandings({ ...dropInput, results: legacyStageResults }).drivers[0].points, 175);
assert.throws(() => calculateSeasonStandings({ ...dropInput,
  results: legacyStageResults.map(row => ({ ...row, points_earned: row.points_earned + 16 })),
}), /Stored points do not match/);
assert.equal(calculateStandings([{ driverId: 'drop-driver' }], [{
  driverId: 'drop-driver', finishPosition: 2, stage1Points: 10, stage2Points: 6,
}], { 1: 25, 2: 20 })[0].points, 20);
console.log('Best-seven scoring verified: finish-only awards, DNS, two absences, exclusions, corrections and unchanged team totals.');

// Running standings always show N-1 counting scores, including the opener.
for (let rounds = 1; rounds <= 8; rounds += 1) {
  const running = calculateSeasonStandings({ ...dropInput, races: dropRaces.slice(0, rounds) }).drivers[0];
  assert.equal(running.countedRaces, rounds - 1);
  assert.equal(running.droppedRaceIds.length, 1);
  assert.equal(running.points, (rounds - 1) * 25);
  const absent = calculateChampionshipPoints(dropRaces.slice(0, rounds), dropResults.slice(1));
  assert.equal(absent.points, (rounds - 1) * 25);
  assert.equal(absent.droppedPoints, 0);
}
const fiveRounds = dropRaces.slice(0, 5);
assert.equal(calculateChampionshipPoints(fiveRounds, dropResults.slice(2)).points, 75);
assert.equal(calculateChampionshipPoints([...fiveRounds, { id: 'future', status: 'scheduled' }], dropResults).points, 100);
console.log('Running standings verified after every round: best N-1 scores, exactly one drop.');

// Public results may use a historical points version. Display awarded totals,
// hide DNS-only/draft-only drivers, and keep commissioner certification strict.
const publicInput = {
  entries: ['a', 'b', 'dns-only', 'draft-only', 'dq'].map(driverId => ({ driverId })),
  races: [{ id: 'p1', race_number: 1, status: 'completed', qualifying_status: 'canceled' },
    { id: 'p2', race_number: 2, status: 'completed', qualifying_status: 'canceled' },
    { id: 'p3', race_number: 3, status: 'upcoming' }],
  results: [
    { race_id: 'p1', driver_id: 'a', start_status: 'started', finish_position: 1, points_earned: 45, stage1_points: 3, certification_status: 'published' },
    { race_id: 'p2', driver_id: 'a', start_status: 'started', finish_position: 1, points_earned: 35, certification_status: 'certified' },
    { race_id: 'p2', driver_id: 'b', start_status: 'started', finish_position: 2, points_earned: 40, certification_status: 'published' },
    { race_id: 'p1', driver_id: 'dq', start_status: 'started', finish_status: 'disqualified', finish_position: 2, points_earned: 0, certification_status: 'published' },
    { race_id: 'p1', driver_id: 'dns-only', start_status: 'dns', finish_position: null, points_earned: 0, certification_status: 'published' },
    { race_id: 'p2', driver_id: 'draft-only', start_status: 'started', finish_position: 1, points_earned: 55, certification_status: 'draft' },
    { race_id: 'p3', driver_id: 'dns-only', start_status: 'started', finish_position: 1, points_earned: 55, certification_status: 'published' },
  ], pointsByPosition: { 1: 55, 2: 35 },
};
const publicStandings = require('./league-rules').calculatePublicSeasonStandings(publicInput);
assert.deepEqual(publicStandings.drivers.map(driver => driver.driverId), ['a', 'b', 'dq']);
assert.equal(publicStandings.drivers[0].points, 45);
assert.equal(publicStandings.drivers[0].rawPoints, 80);
assert.equal(publicStandings.drivers[1].points, 40);
assert.equal(publicStandings.drivers[2].starts, 1);
assert.equal(publicStandings.completedRaces.length, 2);
assert.throws(() => calculateSeasonStandings({ ...publicInput, strict: false }), /Stored points do not match/);
assert.throws(() => calculateSeasonStandings({ ...publicInput, pointsSource: 'published' }), /Certification must validate/);
console.log('Published standings verified: historical awarded points, starter-only eligibility and strict certification preserved.');

// A 16-driver field puts full-time starters on both sides of the Chase cutoff.
// The reserve wins the regular season but cannot take a qualifying place.
const chaseEntries = Array.from({ length: 16 }, (_, index) => ({
  driverId: `chase-${String(index + 1).padStart(2, '0')}`,
  teamId: 'chase-team', entryStatus: index === 14 ? 'reserve' : 'full_time',
}));
const chaseRaces = Array.from({ length: 10 }, (_, index) => ({
  id: `chase-r${index + 1}`, race_number: index + 1,
  status: 'completed', starters_count: 15, qualifying_status: 'canceled',
  race_type: index < 7 ? 'regular' : 'chase',
}));
const chaseSchedule = Object.fromEntries(Array.from({ length: 24 }, (_, index) => [index + 1, index === 0 ? 55 : 36 - index]));
const chaseResults = chaseRaces.flatMap((race, raceIndex) => chaseEntries.map((entry, index) => {
  let position = index === 14 ? 1 : index + 2;
  if (raceIndex >= 7) {
    // Round 8: #13 wins, #2 second, #1 third. Round 9: #2 wins,
    // #1 DNS. Round 10: #13 wins, #1 twelfth, #2 DNS.
    const orders = [
      [12, 1, 0, 3, 4, 5, 6, 2, 7, 8, 9, 10, 11, 13, 14],
      [1, 12, 3, 4, 5, 6, 7, 2, 8, 9, 10, 11, 13, 14],
      [12, 3, 4, 5, 6, 7, 8, 2, 9, 10, 11, 0, 13, 14],
    ];
    position = orders[raceIndex - 7].indexOf(index) + 1;
  }
  const dns = index === 15 || position === 0;
  return { race_id: race.id, driver_id: entry.driverId, team_id: 'chase-team',
    start_status: dns ? 'dns' : 'started', finish_position: dns ? null : position,
    points_earned: dns ? 0 : chaseSchedule[position], certification_status: 'certified' };
}));
const chaseInput = { entries: chaseEntries, races: chaseRaces, results: chaseResults,
  pointsByPosition: chaseSchedule, championshipFormat: 'chase_12_7_3' };
const chaseAt = rounds => calculateSeasonStandings({ ...chaseInput,
  races: chaseRaces.map((race, index) => ({ ...race, status: index < rounds ? 'completed' : 'upcoming' })) });
assert.equal(chaseAt(6).drivers.find(driver => driver.driverId === 'chase-01').points, 210);
assert.equal(chaseAt(6).chaseActive, false);
const reset = chaseAt(7);
assert.equal(reset.chaseActive, true);
assert.deepEqual(reset.drivers.filter(driver => driver.chaseQualified).map(driver => driver.driverId),
  chaseEntries.slice(0, 12).map(entry => entry.driverId));
assert.deepEqual(reset.drivers.slice(0, 12).map(driver => driver.points),
  [2100, 2075, 2065, 2060, 2055, 2050, 2045, 2040, 2035, 2030, 2025, 2020]);
assert.equal(reset.drivers.find(driver => driver.driverId === 'chase-15').chaseQualified, false);
assert.equal(reset.drivers.find(driver => driver.driverId === 'chase-16').chaseQualified, false);
assert.equal(chaseAt(8).drivers.find(driver => driver.driverId === 'chase-01').points, 2134);
const chaseFinal = chaseAt(10);
assert.equal(chaseFinal.drivers[0].driverId, 'chase-02');
assert.equal(chaseFinal.drivers[0].points, 2165); // 2075 + 35 + 55 + DNS.
assert.equal(chaseFinal.drivers.find(driver => driver.driverId === 'chase-01').points, 2159); // 2100 + 34 + DNS + 25.
assert.equal(chaseFinal.drivers.find(driver => driver.driverId === 'chase-13').chaseQualified, false);
assert.equal(chaseFinal.drivers.find(driver => driver.driverId === 'chase-13').rank > 12, true);
assert.equal(chaseFinal.drivers.every(driver => driver.droppedPoints === 0 && driver.droppedRaceIds.length === 0), true);
assert.equal(chaseFinal.teams[0].points, chaseResults.reduce((sum, result) => sum + result.points_earned, 0));
assert.equal(chaseFinal.drivers.find(driver => driver.driverId === 'chase-01').rawPoints, 304); // 7×35 + 34 + 25.
const publicChase = require('./league-rules').calculatePublicSeasonStandings(chaseInput);
assert.deepEqual(publicChase.drivers.map(driver => [driver.driverId, driver.points, driver.rank]),
  chaseFinal.drivers.filter(driver => driver.starts).map(driver => [driver.driverId, driver.points, driver.rank]));
const correctedChase = calculateSeasonStandings({ ...chaseInput, results: chaseResults.map(result => {
  if (result.race_id !== 'chase-r10') return result;
  if (result.driver_id === 'chase-02') return { ...result, start_status: 'started', finish_position: 2, points_earned: 35 };
  return result.finish_position >= 2 ? { ...result, finish_position: result.finish_position + 1,
    points_earned: chaseSchedule[result.finish_position + 1] } : result;
}) });
assert.equal(correctedChase.drivers[0].points, 2200); // Correction adds to the original seed, never resets again.
const correctedCutoff = calculateSeasonStandings({ ...chaseInput, results: chaseResults.map(result => {
  if (result.race_id !== 'chase-r7') return result;
  if (result.driver_id === 'chase-13') return { ...result, finish_position: 1, points_earned: 55 };
  if (result.driver_id === 'chase-15') return { ...result, finish_position: 14, points_earned: 23 };
  return result;
}) });
assert.equal(correctedCutoff.drivers.find(driver => driver.driverId === 'chase-13').chaseSeed, 9);
assert.equal(correctedCutoff.drivers.find(driver => driver.driverId === 'chase-13').points, 2180); // 2035 + 55 + 35 + 55.
assert.equal(correctedCutoff.drivers.find(driver => driver.driverId === 'chase-12').chaseQualified, false);
const dqChase = calculateSeasonStandings({ ...chaseInput, results: chaseResults.map(result =>
  result.race_id === 'chase-r9' && result.driver_id === 'chase-02'
    ? { ...result, finish_status: 'disqualified', points_earned: 0 } : result) });
assert.equal(dqChase.drivers[0].driverId, 'chase-04');
assert.equal(dqChase.drivers.find(driver => driver.driverId === 'chase-02').points, 2110);
const unresolved = chaseRaces.map((race, index) => index === 6 ? { ...race, status: 'upcoming' } : race);
assert.throws(() => calculateSeasonStandings({ ...chaseInput, races: unresolved }), /regular-season rounds must be resolved/);
const voidedRegular = chaseRaces.map((race, index) => index === 6 ? { ...race, status: 'voided' } : race);
assert.equal(calculateSeasonStandings({ ...chaseInput, races: voidedRegular }).chaseActive, true);
const smallField = calculateSeasonStandings({ ...chaseInput, entries: chaseEntries.slice(0, 2),
  results: chaseResults.filter(result => ['chase-01', 'chase-02'].includes(result.driver_id)) });
assert.deepEqual(smallField.drivers.map(driver => driver.chaseSeed), [2, 1]);
assert.equal(calculateSeasonStandings({ ...chaseInput, championshipFormat: undefined }).drivers.find(driver => driver.driverId === 'chase-01').points, 304);
console.log('Season 2 Chase verified: no drops, top-12 full-time cutoff, NASCAR seeds, one reset, all three races, DNS/DQ, corrections, public/certified agreement and unchanged team totals.');
