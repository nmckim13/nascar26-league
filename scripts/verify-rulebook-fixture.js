'use strict';

const assert = require('node:assert/strict');
const fixture = require('../data/rulebook-fixture.json');
const {
  calculateEqualLeagueCap,
  calculateMinimumFeasibleCap,
  calculateSeasonStandings,
  calculateRating,
} = require('./league-rules');

const driverById = new Map(fixture.drivers.map(driver => [driver.driverId, driver]));
const entries = fixture.drivers.map(driver => ({
  driverId: driver.driverId,
  teamId: driver.teamId,
  entryStatus: 'full_time',
}));
const races = fixture.races.map(race => ({
  id: race.id,
  status: 'completed',
  startersCount: race.startersCount,
  qualifyingStatus: 'valid',
  qualifyingFieldCount: race.qualifyingFieldCount,
}));
const results = fixture.races.flatMap(race => race.results.map(result => {
  const driver = driverById.get(result.d);
  assert.ok(driver, `Unknown fixture driver ${result.d}`);
  return {
    raceId: race.id,
    driverId: driver.driverId,
    teamId: driver.teamId,
    carNumber: driver.carNumber,
    startStatus: result.dns ? 'dns' : 'started',
    finishStatus: result.dnf ? 'dnf' : 'classified',
    finishPosition: result.dns ? null : result.f,
    pointsEarned: result.dns ? 0 : fixture.pointsByPosition[String(result.f)],
    qualifyingPosition: result.q || null,
    qualifyingValid: Boolean(result.q),
    pole: result.q === 1,
  };
}));

const standings = calculateSeasonStandings({
  entries,
  races,
  results,
  pointsByPosition: fixture.pointsByPosition,
  strict: true,
});
const byDriver = new Map(standings.drivers.map(driver => [driver.driverId, driver]));
const expectedPoints = { d88:330, d97:312, d24:250, d5:200, d54:188, d20:246, d1:261, d19:235, d17:232, d9:234, d60:226, d6:214 };
const expectedRatings = { d5:68, d9:77, d24:87, d20:81, d19:78, d54:66, d1:87, d88:95, d97:93, d6:67, d17:75, d60:72 };

assert.equal(standings.completedRaces.length, 8);
assert.equal(results.length, 96);
assert.equal(results.filter(result => result.startStatus !== 'dns').length, 90);
assert.equal(results.filter(result => result.finishPosition === 1).length, 8);
assert.equal(standings.drivers.reduce((sum, driver) => sum + driver.points, 0), 2928);
Object.entries(expectedPoints).forEach(([driverId, points]) => assert.equal(byDriver.get(driverId).points, points));
assert.equal(byDriver.get('d88').points, 330);
assert.equal(byDriver.get('d97').points, 312);
assert.equal(standings.teams.find(team => team.teamId === 'trackhouse').points, 903);

Object.entries(expectedRatings).forEach(([driverId, expected]) => {
  const driver = byDriver.get(driverId);
  const rating = calculateRating({
    rank: driver.ratingRank,
    fieldSize: fixture.drivers.length,
    seasonLength: standings.completedRaces.length,
    starts: driver.starts,
    wins: driver.wins,
    finishCredits: driver.finishCredits,
    qualifyingCredits: driver.qualifyingCredits,
    qualifyingRounds: driver.qualifyingRounds,
  });
  assert.equal(rating.overall, expected, `${driverId} rating`);
});

assert.equal(Object.values(expectedRatings).reduce((sum, rating) => sum + rating, 0), 946);
const cap = calculateMinimumFeasibleCap(Object.values(expectedRatings));
assert.equal(cap.minimumMax, 237);
assert.equal(calculateEqualLeagueCap(cap.minimumMax), 240);

console.log('Rulebook fixture verified: 330/#88, 312/#97, 903 Trackhouse, 90 starts, 2,928 points, 946 OVR credits, 237/240 cap.');
