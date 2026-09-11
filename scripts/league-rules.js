'use strict';

const DEFAULT_WEIGHTS = {
  championshipFinish: 0.50,
  finishQuality: 0.20,
  wins: 0.15,
  attendance: 0.10,
  qualifying: 0.05,
};

function validateLeagueStructure(structure) {
  const errors = [];
  const teams = structure.teams || [];
  const allCarNumbers = teams.flatMap(team => team.carNumbers || []);
  const carNumbers = new Set();

  if (structure.seasonLength !== 8) errors.push('The league model must contain 8 races.');
  if (structure.teamCount !== 8) errors.push('The league model must contain 8 teams.');
  if (structure.teamSize !== 3) errors.push('Every team must contain 3 seats.');
  if (structure.driverCount !== 24) errors.push('The league model must contain 24 driver seats.');
  if (teams.length !== structure.teamCount) errors.push('teamCount does not match the teams array.');
  if (allCarNumbers.length < structure.driverCount) errors.push('There must be at least 24 available car numbers.');

  teams.forEach(team => {
    if (!team.id || !team.name) errors.push('Every team needs an id and name.');
    if (team.seatLimit !== structure.teamSize) {
      errors.push(`${team.id || 'Unknown team'} must have a 3-driver seat limit.`);
    }
    if ((team.carNumbers || []).length < team.seatLimit) {
      errors.push(`${team.id || 'Unknown team'} needs at least 3 available car numbers.`);
    }
    (team.carNumbers || []).forEach(carNumber => {
      if (carNumbers.has(carNumber)) errors.push(`Duplicate car number: ${carNumber}.`);
      carNumbers.add(carNumber);
    });
  });

  return { valid: errors.length === 0, errors };
}

function validateRosterAssignments(structure, assignments) {
  const errors = [];
  const teamsById = new Map(structure.teams.map(team => [team.id, team]));
  const activeDrivers = new Set();
  const activeCars = new Set();
  const teamCounts = new Map();

  assignments.forEach(assignment => {
    const team = teamsById.get(assignment.teamId);
    if (!team) {
      errors.push(`Unknown team: ${assignment.teamId}.`);
      return;
    }
    if (activeDrivers.has(assignment.driverId)) errors.push(`Driver is assigned twice: ${assignment.driverId}.`);
    if (activeCars.has(assignment.carNumber)) errors.push(`Car number is assigned twice: ${assignment.carNumber}.`);
    if (!team.carNumbers.includes(String(assignment.carNumber))) {
      errors.push(`#${assignment.carNumber} is not in the ${team.name} car catalog.`);
    }
    const count = (teamCounts.get(team.id) || 0) + 1;
    if (count > team.seatLimit) errors.push(`${team.name} exceeds its ${team.seatLimit}-driver limit.`);
    activeDrivers.add(assignment.driverId);
    activeCars.add(String(assignment.carNumber));
    teamCounts.set(team.id, count);
  });

  if (assignments.length !== structure.driverCount) {
    errors.push(`Roster lock requires ${structure.driverCount} active drivers.`);
  }
  return { valid: errors.length === 0, errors };
}

function requireValidStructure(structure) {
  const result = validateLeagueStructure(structure);
  if (!result.valid) throw new Error(result.errors.join(' '));
}

function validatePointsSchedule(pointsByPosition, fieldSize = 24) {
  const errors = [];
  if (!Number.isInteger(fieldSize) || fieldSize < 1) return ['Field size must be a positive integer.'];
  if (!pointsByPosition || typeof pointsByPosition !== 'object' || Array.isArray(pointsByPosition)) {
    return ['Points schedule must be an object.'];
  }
  const keys = Object.keys(pointsByPosition);
  if (keys.length !== fieldSize) errors.push(`Points schedule must define exactly positions 1 through ${fieldSize}.`);
  let previous = null;
  for (let position = 1; position <= fieldSize; position += 1) {
    const key = String(position);
    if (!Object.prototype.hasOwnProperty.call(pointsByPosition, key)) {
      errors.push(`Points schedule is missing position ${position}.`);
      continue;
    }
    const value = pointsByPosition[key];
    if (!Number.isInteger(value) || value < 0) {
      errors.push(`Points for position ${position} must be a non-negative integer.`);
      continue;
    }
    if (previous !== null && value > previous) errors.push('Points must be non-increasing by finishing position.');
    previous = value;
  }
  return [...new Set(errors)];
}

function pointsForPosition(position, pointsByPosition) {
  const points = pointsByPosition[String(position)];
  if (points === undefined) {
    throw new Error(`No points value is defined for finishing position ${position}.`);
  }
  return points;
}

function stagePoints(result) {
  return (resultValue(result, 'stage1Points', 'stage1_points') || 0)
    + (resultValue(result, 'stage2Points', 'stage2_points') || 0);
}

function calculateStandings(entries, results, pointsByPosition) {
  const drivers = new Map(entries.map(entry => [entry.driverId, {
    driverId: entry.driverId,
    teamId: entry.teamId,
    points: 0,
    starts: 0,
    wins: 0,
    finishes: [],
    positions: [],
  }]));

  results.forEach(result => {
    const driver = drivers.get(result.driverId);
    if (!driver) throw new Error(`Unknown driver in result: ${result.driverId}.`);
    if (resultValue(result, 'startStatus', 'start_status') === 'dns') return;
    const isDisqualified = resultValue(result, 'finishStatus', 'finish_status') === 'disqualified';
    driver.starts += 1;
    driver.finishes.push(result.finishPosition);
    driver.positions.push(result.finishPosition);
    driver.points += isDisqualified ? 0 : pointsForPosition(result.finishPosition, pointsByPosition) + stagePoints(result);
    if (result.finishPosition === 1 && !isDisqualified) driver.wins += 1;
  });

  return [...drivers.values()].sort((a, b) => {
    if (b.points !== a.points) return b.points - a.points;
    if (b.wins !== a.wins) return b.wins - a.wins;
    for (let position = 2; position <= 24; position += 1) {
      const aCount = a.finishes.filter(finish => finish === position).length;
      const bCount = b.finishes.filter(finish => finish === position).length;
      if (bCount !== aCount) return bCount - aCount;
    }
    return a.driverId.localeCompare(b.driverId);
  }).map((driver, index) => ({ ...driver, rank: index + 1 }));
}

function resultValue(result, camelName, snakeName) {
  return result[camelName] === undefined ? result[snakeName] : result[camelName];
}

function compareRaceResult(a, b) {
  const aStart = resultValue(a, 'startStatus', 'start_status') !== 'dns';
  const bStart = resultValue(b, 'startStatus', 'start_status') !== 'dns';
  if (aStart !== bStart) return aStart ? -1 : 1;
  if (!aStart) return 0;
  return resultValue(a, 'finishPosition', 'finish_position') - resultValue(b, 'finishPosition', 'finish_position');
}

function isChampionshipRound(race) {
  if (race.status !== 'completed') return false;
  if ((race.raceType || race.race_type || 'regular') === 'exhibition') return false;
  const startersCount = race.startersCount ?? race.starters_count;
  return startersCount === undefined || startersCount === null || startersCount >= 2;
}

function calculateSeasonStats({ entries, races, results, pointsByPosition, strict = true }) {
  const completedRaces = races.filter(isChampionshipRound);
  const raceById = new Map(races.map(race => [race.id, race]));
  const stats = new Map(entries.map(entry => [entry.driverId, {
    driverId: entry.driverId,
    teamId: entry.teamId || null,
    entryStatus: entry.entryStatus || entry.entry_status || 'full_time',
    points: 0,
    starts: 0,
    wins: 0,
    poles: 0,
    topFives: 0,
    dnfs: 0,
    finishes: [],
    raceResults: new Map(),
    finishCredits: 0,
    qualifyingCredits: 0,
    qualifyingRounds: 0,
  }]));

  results.forEach(result => {
    const race = raceById.get(result.raceId || result.race_id);
    if (!race || !isChampionshipRound(race)) return;
    const driver = stats.get(result.driverId || result.driver_id);
    if (!driver) throw new Error(`Unknown driver in result: ${result.driverId || result.driver_id}.`);
    const startStatus = resultValue(result, 'startStatus', 'start_status') || 'started';
    const finishPosition = resultValue(result, 'finishPosition', 'finish_position');
    const qualifyingPosition = resultValue(result, 'qualifyingPosition', 'qualifying_position');
    const points = resultValue(result, 'pointsEarned', 'points_earned');
    const stage1Points = resultValue(result, 'stage1Points', 'stage1_points') || 0;
    const stage2Points = resultValue(result, 'stage2Points', 'stage2_points') || 0;
    const raceKey = race.id;
    const isDisqualified = resultValue(result, 'finishStatus', 'finish_status') === 'disqualified';

    if (startStatus === 'dns') {
      if (finishPosition !== null && finishPosition !== undefined) {
        throw new Error(`DNS result cannot have a finish position for ${driver.driverId}.`);
      }
      driver.raceResults.set(raceKey, result);
      return;
    }

    if (!Number.isInteger(finishPosition) || finishPosition < 1) {
      throw new Error(`Started result needs a valid finish position for ${driver.driverId}.`);
    }
    const startersCount = race.startersCount || race.starters_count;
    if (!Number.isInteger(startersCount) || startersCount < 1) {
      if (strict) throw new Error(`Race ${race.id} is missing a valid starters count.`);
    } else if (finishPosition > startersCount) {
      throw new Error(`Finish position ${finishPosition} exceeds the starter count for race ${race.id}.`);
    }

    const expectedFinishPoints = isDisqualified ? 0 : pointsForPosition(finishPosition, pointsByPosition);
    const expectedPoints = expectedFinishPoints + (isDisqualified ? 0 : stage1Points + stage2Points);
    if ([stage1Points, stage2Points].some(value => !Number.isInteger(value) || value < 0)) {
      throw new Error(`Stage points must be non-negative integers for ${driver.driverId}.`);
    }
    if (points !== undefined && points !== null && points !== expectedPoints) {
      throw new Error(`Stored points do not match the rules for race ${race.id}, position ${finishPosition}.`);
    }
    driver.starts += 1;
    driver.finishes.push(finishPosition);
    driver.points += expectedPoints;
    driver.stage1Points = (driver.stage1Points || 0) + (isDisqualified ? 0 : stage1Points);
    driver.stage2Points = (driver.stage2Points || 0) + (isDisqualified ? 0 : stage2Points);
    if (finishPosition === 1 && !isDisqualified) driver.wins += 1;
    if (finishPosition <= 5 && !isDisqualified) driver.topFives += 1;
    if (resultValue(result, 'finishStatus', 'finish_status') === 'dnf' || result.dnf === true) driver.dnfs += 1;
    if (resultValue(result, 'pole', 'pole') === true) driver.poles += 1;
    if (!isDisqualified && Number.isInteger(startersCount) && startersCount >= 1) {
      driver.finishCredits += (startersCount + 1 - finishPosition) / startersCount;
    }
    driver.raceResults.set(raceKey, result);

    const qualifyingStatus = race.qualifyingStatus || race.qualifying_status || 'not_recorded';
    if (qualifyingStatus === 'valid' && resultValue(result, 'qualifyingValid', 'qualifying_valid') === true) {
      const qualifyingCount = race.qualifyingFieldCount || race.qualifying_field_count;
      if (!Number.isInteger(qualifyingCount) || qualifyingCount < 2 || !Number.isInteger(qualifyingPosition)) {
        if (strict) throw new Error(`Race ${race.id} is missing a valid qualifying field.`);
      } else {
        if (qualifyingPosition < 1 || qualifyingPosition > qualifyingCount) {
          throw new Error(`Qualifying position is invalid for race ${race.id}.`);
        }
        driver.qualifyingCredits += (qualifyingCount + 1 - qualifyingPosition) / qualifyingCount;
        driver.qualifyingRounds += 1;
      }
    } else if (strict && !['canceled', 'voided'].includes(qualifyingStatus)) {
      throw new Error(`Missing qualifying data blocks certification for ${driver.driverId} in race ${race.id}.`);
    }
  });

  const qualifyingRounds = completedRaces.filter(race => {
    const status = race.qualifyingStatus || race.qualifying_status;
    const fieldCount = race.qualifyingFieldCount || race.qualifying_field_count;
    return status === 'valid' && Number.isInteger(fieldCount) && fieldCount >= 2;
  }).length;
  stats.forEach(driver => { driver.qualifyingRounds = qualifyingRounds; });

  if (strict) {
    const requiredEntries = entries.filter(entry => (entry.entryStatus || entry.entry_status || 'full_time') === 'full_time');
    completedRaces.forEach(race => {
      requiredEntries.forEach(entry => {
        const driver = stats.get(entry.driverId || entry.driver_id);
        if (!driver || !driver.raceResults.has(race.id)) {
          throw new Error(`Missing result row blocks certification for ${entry.driverId || entry.driver_id} in race ${race.id}.`);
        }
      });
    });
  }

  return { completedRaces, stats: [...stats.values()] };
}

function compareDriverStandings(a, b, races) {
  if (b.points !== a.points) return b.points - a.points;
  if (b.wins !== a.wins) return b.wins - a.wins;
  const maxPosition = Math.max(a.finishes.length ? Math.max(...a.finishes) : 0, b.finishes.length ? Math.max(...b.finishes) : 0, 24);
  for (let position = 2; position <= maxPosition; position += 1) {
    const aCount = a.finishes.filter(finish => finish === position).length;
    const bCount = b.finishes.filter(finish => finish === position).length;
    if (bCount !== aCount) return bCount - aCount;
  }
  for (let index = races.length - 1; index >= 0; index -= 1) {
    const aResult = a.raceResults.get(races[index].id);
    const bResult = b.raceResults.get(races[index].id);
    const comparison = compareRaceResult(aResult || { startStatus: 'dns' }, bResult || { startStatus: 'dns' });
    if (comparison !== 0) return comparison;
  }
  return a.driverId.localeCompare(b.driverId);
}

function sameDriverSportingRecord(a, b, races) {
  if (a.points !== b.points || a.wins !== b.wins) return false;
  const maxPosition = Math.max(a.finishes.length ? Math.max(...a.finishes) : 0, b.finishes.length ? Math.max(...b.finishes) : 0, 24);
  for (let position = 2; position <= maxPosition; position += 1) {
    if (a.finishes.filter(finish => finish === position).length !== b.finishes.filter(finish => finish === position).length) return false;
  }
  return races.every(race => compareRaceResult(
    a.raceResults.get(race.id) || { startStatus: 'dns' },
    b.raceResults.get(race.id) || { startStatus: 'dns' },
  ) === 0);
}

function rankDrivers(stats, races) {
  const ordered = [...stats].sort((a, b) => compareDriverStandings(a, b, races));
  let index = 0;
  return ordered.map((driver, position) => {
    if (position > 0 && !sameDriverSportingRecord(driver, ordered[position - 1], races)) index = position;
    const tieEnd = ordered.findIndex((candidate, candidateIndex) => (
      candidateIndex >= position && !sameDriverSportingRecord(candidate, driver, races)
    ));
    const end = tieEnd === -1 ? ordered.length : tieEnd;
    const ratingRank = (index + 1 + end) / 2;
    return { ...driver, rank: index + 1, ratingRank };
  });
}

function calculateTeamStandings(stats, races) {
  const byTeam = new Map();
  const ensureTeam = teamId => {
    if (!byTeam.has(teamId)) byTeam.set(teamId, {
      teamId,
      points: 0,
      wins: 0,
      finishes: [],
      raceResults: new Map(),
    });
    return byTeam.get(teamId);
  };

  stats.forEach(driver => {
    // A reserve keeps separate driver statistics, but the occupied seat's
    // result still belongs to its team championship total.
    const resultRows = [...driver.raceResults.entries()];
    if (!resultRows.length) ensureTeam(driver.teamId || 'unassigned');
    resultRows.forEach(([raceId, result]) => {
      const teamId = resultValue(result, 'teamId', 'team_id') || driver.teamId || 'unassigned';
      const team = ensureTeam(teamId);
      const finishPosition = resultValue(result, 'finishPosition', 'finish_position');
      const points = resultValue(result, 'pointsEarned', 'points_earned') || 0;
      const isDisqualified = resultValue(result, 'finishStatus', 'finish_status') === 'disqualified';
      team.points += points;
      if (finishPosition === 1 && !isDisqualified) team.wins += 1;
      if (Number.isInteger(finishPosition)) team.finishes.push(finishPosition);
      if (!team.raceResults.has(raceId)) team.raceResults.set(raceId, []);
      team.raceResults.get(raceId).push(result);
    });
  });

  const compareTeamSportingRecord = (a, b) => {
    if (b.points !== a.points) return b.points - a.points;
    for (let position = 1; position <= 24; position += 1) {
      const aCount = a.finishes.filter(finish => finish === position).length;
      const bCount = b.finishes.filter(finish => finish === position).length;
      if (bCount !== aCount) return bCount - aCount;
    }
    for (let index = races.length - 1; index >= 0; index -= 1) {
      const aResults = (a.raceResults.get(races[index].id) || []).map(result => resultValue(result, 'finishPosition', 'finish_position') || 999).sort((x, y) => x - y);
      const bResults = (b.raceResults.get(races[index].id) || []).map(result => resultValue(result, 'finishPosition', 'finish_position') || 999).sort((x, y) => x - y);
      for (let resultIndex = 0; resultIndex < Math.max(aResults.length, bResults.length); resultIndex += 1) {
        const aPosition = aResults[resultIndex] || 999;
        const bPosition = bResults[resultIndex] || 999;
        if (aPosition !== bPosition) return aPosition - bPosition;
      }
    }
    return 0;
  };

  const compareTeams = (a, b) => compareTeamSportingRecord(a, b) || a.teamId.localeCompare(b.teamId);

  const ordered = [...byTeam.values()].sort(compareTeams);
  let previousSportingRank = null;
  return ordered.map((team, index) => {
    const previous = ordered[index - 1];
    const sportingTie = previous && compareTeamSportingRecord(team, previous) === 0
      ? previousSportingRank
      : index + 1;
    previousSportingRank = sportingTie;
    return { ...team, rank: sportingTie };
  });
}

function calculateSeasonStandings(input) {
  const { completedRaces, stats } = calculateSeasonStats(input);
  const drivers = rankDrivers(stats, completedRaces);
  const teams = calculateTeamStandings(drivers, completedRaces);
  return { completedRaces, drivers, teams };
}

function calculateMinimumFeasibleCap(ratings, teamSize = 3) {
  if (!Array.isArray(ratings) || ratings.length === 0 || ratings.length % teamSize !== 0) {
    throw new Error('Ratings must contain a non-empty multiple of the team size.');
  }
  const ordered = ratings.map((rating, index) => ({ id: String(index), rating })).sort((a, b) => b.rating - a.rating);
  const groupCount = ordered.length / teamSize;
  let combinationsChecked = 0;

  if (teamSize !== 3 || ordered.length > 30) {
    throw new Error('Exact cap search currently supports up to 30 drivers in three-driver teams.');
  }

  const fullMask = (1 << ordered.length) - 1;
  function findGroups(cap) {
    const memo = new Map();
    function search(mask) {
      if (mask === 0) return [];
      if (memo.has(mask)) return memo.get(mask);
      const firstBit = mask & -mask;
      const firstIndex = Math.log2(firstBit);
      const remainder = mask ^ firstBit;
      for (let partnerBit = remainder; partnerBit; partnerBit &= partnerBit - 1) {
        const partnerChoice = partnerBit & -partnerBit;
        const partnerIndex = Math.log2(partnerChoice);
        for (let lastBit = remainder ^ partnerChoice; lastBit; lastBit &= lastBit - 1) {
          const lastChoice = lastBit & -lastBit;
          const lastIndex = Math.log2(lastChoice);
          combinationsChecked += 1;
          const total = ordered[firstIndex].rating + ordered[partnerIndex].rating + ordered[lastIndex].rating;
          if (total > cap) continue;
          const nextMask = remainder ^ partnerChoice ^ lastChoice;
          const rest = search(nextMask);
          if (rest) {
            const solution = [[ordered[firstIndex].id, ordered[partnerIndex].id, ordered[lastIndex].id], ...rest];
            memo.set(mask, solution);
            return solution;
          }
        }
      }
      memo.set(mask, null);
      return null;
    }
    return search(fullMask);
  }

  let low = Math.ceil(ordered.reduce((sum, driver) => sum + driver.rating, 0) / groupCount);
  let high = ordered.slice(0, teamSize).reduce((sum, driver) => sum + driver.rating, 0);
  let bestGroups = null;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const groups = findGroups(middle);
    if (groups) {
      high = middle - 1;
      bestGroups = groups;
    } else {
      low = middle + 1;
    }
  }
  return { minimumMax: low, groups: bestGroups, combinationsChecked };
}

function calculateEqualLeagueCap(minimumMax, floorCap = 155) {
  if (!Number.isFinite(minimumMax) || minimumMax < 0) throw new Error('Minimum feasible cap must be a non-negative number.');
  return Math.max(floorCap, 5 * Math.ceil(minimumMax / 5));
}

function ratingCurve(fraction) {
  if (fraction < 0 || fraction > 1) throw new Error(`Rating fraction is outside 0-1: ${fraction}.`);
  return 40 + (60 * Math.sqrt(fraction));
}

function roundHalfUp(value) {
  return Math.floor(value + 0.5);
}

function calculateRating({ rank, fieldSize, seasonLength, starts, wins, finishCredits, qualifyingCredits, qualifyingRounds }, weights = DEFAULT_WEIGHTS) {
  if (starts === 0) {
    return {
      championshipFinish: 40,
      finishQuality: 40,
      wins: 40,
      attendance: 40,
      qualifying: 40,
      overallRaw: 40,
      overall: 40,
    };
  }

  const championshipFinish = ratingCurve((fieldSize + 1 - rank) / fieldSize);
  const finishQuality = ratingCurve(finishCredits / seasonLength);
  const winRating = ratingCurve(wins / seasonLength);
  const attendance = 40 + (60 * starts / seasonLength);
  const qualifying = qualifyingRounds > 0
    ? ratingCurve(qualifyingCredits / qualifyingRounds)
    : 40;
  const overallRaw =
    (weights.championshipFinish * championshipFinish) +
    (weights.finishQuality * finishQuality) +
    (weights.wins * winRating) +
    (weights.attendance * attendance) +
    (weights.qualifying * qualifying);

  return {
    championshipFinish,
    finishQuality,
    wins: winRating,
    attendance,
    qualifying,
    overallRaw,
    overall: Math.min(100, Math.max(40, roundHalfUp(overallRaw))),
  };
}

function calculateCapChargeCents(rating, termDiscountBps = 0, loyaltyDiscountBps = 0) {
  const totalDiscountBps = termDiscountBps + loyaltyDiscountBps;
  if (totalDiscountBps < 0 || totalDiscountBps > 500) {
    throw new Error('Combined contract discounts must be between 0% and 5%.');
  }
  return Math.ceil((rating * 100 * (10000 - totalDiscountBps)) / 10000);
}

const exportedRules = {
  DEFAULT_WEIGHTS,
  validateLeagueStructure,
  validateRosterAssignments,
  validatePointsSchedule,
  requireValidStructure,
  calculateStandings,
  calculateSeasonStats,
  calculateSeasonStandings,
  calculateTeamStandings,
  rankDrivers,
  calculateMinimumFeasibleCap,
  calculateEqualLeagueCap,
  ratingCurve,
  calculateRating,
  calculateCapChargeCents,
  roundHalfUp,
};

if (typeof module !== 'undefined' && module.exports) module.exports = exportedRules;
if (typeof window !== 'undefined') window.N26LeagueRules = exportedRules;
