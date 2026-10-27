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
  points_earned: i === 0 ? 30 : 25, stage1_points: i === 0 ? 10 : 0,
}));
const dropInput = { entries: [{ driverId: 'drop-driver', teamId: 'drop-team' }],
  races: dropRaces, results: dropResults, pointsByPosition: { 1: 25, 2: 20 } };
const droppedSeason = calculateSeasonStandings(dropInput);
assert.equal(droppedSeason.drivers[0].rawPoints, 205);
assert.equal(droppedSeason.drivers[0].points, 180); // Stage points keep the P2 ahead of a P1.
assert.equal(droppedSeason.drivers[0].droppedPoints, 25);
assert.equal(droppedSeason.drivers[0].droppedRaceIds.length, 1);
assert.equal(droppedSeason.drivers[0].starts, 8);
assert.equal(droppedSeason.drivers[0].wins, 7);
assert.equal(droppedSeason.teams[0].points, 205);
const dnsRow = { ...dropResults[0], start_status: 'dns', finish_position: null, points_earned: 0, stage1_points: 0 };
assert.equal(calculateChampionshipPoints(dropRaces, [dnsRow, ...dropResults.slice(1)]).points, 175);
assert.equal(calculateChampionshipPoints(dropRaces, dropResults.slice(1)).points, 175);
assert.equal(calculateChampionshipPoints(dropRaces, dropResults.slice(2)).points, 150); // Two absences: only one zero is discarded.
assert.equal(calculateChampionshipPoints(dropRaces.slice(0, 7), dropResults).points, 155);
assert.equal(calculateChampionshipPoints(dropRaces.slice(0, 1), dropResults).points, 0);
assert.equal(calculateChampionshipPoints([], dropResults).points, 0);
for (const excluded of [{ status: 'scheduled' }, { status: 'voided' }, { race_type: 'exhibition' }, { starters_count: 1 }]) {
  assert.equal(calculateChampionshipPoints([{ ...dropRaces[0], ...excluded }, ...dropRaces.slice(1)], dropResults).points, 150);
}
assert.equal(calculateChampionshipPoints(dropRaces, [...dropResults.slice(0, 7), { ...dropResults[7], finish_status: 'disqualified' }]).points, 180);
const corrected = dropResults.map((row, i) => i === 0 ? { ...row, points_earned: 10 } : row);
assert.equal(calculateChampionshipPoints(dropRaces, corrected).points, 175);
assert.deepEqual(calculateChampionshipPoints([...dropRaces].reverse(), [...dropResults].reverse()), calculateChampionshipPoints(dropRaces, dropResults));
assert.throws(() => calculateSeasonStandings({ ...dropInput, results: dropResults.slice(1) }), /Missing result row/);
console.log('Best-seven scoring verified: stages, DNS, two absences, exclusions, corrections and unchanged team totals.');

// Running standings always show N-1 counting scores, including the opener.
for (let rounds = 1; rounds <= 8; rounds += 1) {
  const running = calculateSeasonStandings({ ...dropInput, races: dropRaces.slice(0, rounds) }).drivers[0];
  assert.equal(running.countedRaces, rounds - 1);
  assert.equal(running.droppedRaceIds.length, 1);
  assert.equal(running.points, rounds === 1 ? 0 : 30 + (rounds - 2) * 25);
  const absent = calculateChampionshipPoints(dropRaces.slice(0, rounds), dropResults.slice(1));
  assert.equal(absent.points, (rounds - 1) * 25);
  assert.equal(absent.droppedPoints, 0);
}
const fiveRounds = dropRaces.slice(0, 5);
assert.equal(calculateChampionshipPoints(fiveRounds, dropResults.slice(2)).points, 75);
assert.equal(calculateChampionshipPoints([...fiveRounds, { id: 'future', status: 'scheduled' }], dropResults).points, 105);
console.log('Running standings verified after every round: best N-1 scores, exactly one drop.');
