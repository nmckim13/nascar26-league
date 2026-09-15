// Supabase → Discord webhook handler
// Fires on new n26_claims INSERT
// 1. Posts claim announcement to #announcements
// 2. Looks up Discord user by username
// 3. Assigns their team role automatically

const DISCORD_TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = "1537572693837217873";
const ANNOUNCEMENTS_CHANNEL = "1537577565093502987";
const WEBHOOK_SECRET = process.env.SUPABASE_WEBHOOK_SECRET;
const ROSTER_SIZE = 24;
// Commissioner Discord user ID — tagged when a role can't be auto-assigned
// so failures are never silent. Nolan (nmckim13).
const COMMISSIONER_ID = process.env.COMMISSIONER_DISCORD_ID || "759986368972980235";

// Team → Discord role ID
const TEAM_ROLES = {
  'Hendrick Motorsports': '1537581458774954085',
  'Joe Gibbs Racing':     '1537581461480149026',
  'Team Penske':          '1537581465036918884',
  '23XI Racing':          '1537581468140830750',
  'RFK Racing':           '1537581471219581019',
  'Spire Motorsports':    '1537581474990260294',
  'Trackhouse Racing':    '1537581478270206024',
  'Legacy Motor Club':     '1537875081672532058',
};

const TEAM_MAP = {
  '1':'Trackhouse Racing','2':'Team Penske','5':'Hendrick Motorsports',
  '6':'RFK Racing','7':'Spire Motorsports','9':'Hendrick Motorsports',
  '11':'Joe Gibbs Racing','12':'Team Penske','17':'RFK Racing',
  '19':'Joe Gibbs Racing','20':'Joe Gibbs Racing','22':'Team Penske',
  '23':'23XI Racing','24':'Hendrick Motorsports','35':'23XI Racing',
  '45':'23XI Racing','48':'Hendrick Motorsports','54':'Joe Gibbs Racing',
  '60':'RFK Racing','71':'Spire Motorsports','77':'Spire Motorsports',
  '88':'Trackhouse Racing','97':'Trackhouse Racing',
  '42':'Legacy Motor Club',
  '43':'Legacy Motor Club',
  '84':'Legacy Motor Club',
};

const TEAM_EMOJI = {
  'Hendrick Motorsports':'🔵','Joe Gibbs Racing':'🟠','Team Penske':'🔴',
  '23XI Racing':'🟥','RFK Racing':'⚪','Spire Motorsports':'🟡',
  'Trackhouse Racing':'💙',
  'Legacy Motor Club': '💚',
};

async function discordAPI(method, path, body) {
  const res = await fetch(`https://discord.com/api/v10${path}`, {
    method,
    headers: {
      'Authorization': `Bot ${DISCORD_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 204) return { ok: true, status: 204 };
  const data = await res.json().catch(() => null);
  // If the response body is an array (e.g. member search / list), return it
  // directly — spreading it into an object would corrupt it and break
  // Array.isArray checks downstream.
  if (Array.isArray(data)) {
    data.ok = res.ok;
    data.status = res.status;
    return data;
  }
  return { ok: res.ok, status: res.status, ...(data || {}) };
}

async function getTotalClaims() {
  const supabaseKey = process.env.SUPABASE_ANON_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!process.env.SUPABASE_URL || !supabaseKey) return null;
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/n26_claim_roster?select=car_number`,
    { headers: { 'apikey': supabaseKey, 'Authorization': `Bearer ${supabaseKey}` } }
  );
  if (!res.ok) return null;
  return (await res.json()).length;
}

// Find a guild member by a typed name. Uses the member-SEARCH endpoint
// (matches by username prefix on Discord's side, works without needing the
// full member list), then matches the typed string against username,
// global_name (display name) and per-guild nick — case-insensitive.
// This catches the common case where a claimant types their DISPLAY name
// (e.g. "Dirt Eater") instead of their real username ("casual_dirt_enjoyer").
async function findMemberByUsername(username) {
  const clean = String(username).toLowerCase().replace(/^@/, '').trim();
  if (!clean) return null;

  // Discord's search matches the START of username/nick. Query the first
  // token so a typed display name like "Dirt Eater" still returns candidates.
  const firstToken = clean.split(/\s+/)[0];
  const queries = [clean, firstToken].filter((v, i, a) => v && a.indexOf(v) === i);

  const candidates = [];
  for (const q of queries) {
    const res = await discordAPI(
      'GET',
      `/guilds/${GUILD_ID}/members/search?query=${encodeURIComponent(q)}&limit=100`
    );
    if (Array.isArray(res)) candidates.push(...res);
  }

  const norm = (s) => (s ? String(s).toLowerCase().trim() : '');
  // Prefer an exact match on any name field, then fall back to a prefix match.
  const exact = candidates.find((m) => {
    const u = m.user || {};
    return [u.username, u.global_name, m.nick].map(norm).includes(clean);
  });
  if (exact) return exact;

  const prefix = candidates.find((m) => {
    const u = m.user || {};
    return [u.username, u.global_name, m.nick]
      .map(norm)
      .some((n) => n && (n.startsWith(clean) || clean.startsWith(n)));
  });
  return prefix || null;
}

async function assignRole(userId, roleId) {
  return discordAPI('PUT', `/guilds/${GUILD_ID}/members/${userId}/roles/${roleId}`);
}

async function postToDiscord(content) {
  return discordAPI('POST', `/channels/${ANNOUNCEMENTS_CHANNEL}/messages`, { content });
}

function permissionBit(bit) {
  return 1n << BigInt(bit);
}

function applyOverwrite(permissions, overwrite) {
  if (!overwrite) return permissions;
  return (permissions & ~BigInt(overwrite.deny || 0)) | BigInt(overwrite.allow || 0);
}

async function checkDiscordConfiguration() {
  const [bot, member, roles, channel, memberSearch] = await Promise.all([
    discordAPI('GET', '/users/@me'),
    discordAPI('GET', `/guilds/${GUILD_ID}/members/@me`),
    discordAPI('GET', `/guilds/${GUILD_ID}/roles`),
    discordAPI('GET', `/channels/${ANNOUNCEMENTS_CHANNEL}`),
    discordAPI('GET', `/guilds/${GUILD_ID}/members/search?query=a&limit=1`),
  ]);

  if (!bot.ok || !member.ok || !roles.ok || !channel.ok || !memberSearch.ok) {
    return {
      ok: false,
      authenticated: bot.ok,
      guildMember: member.ok,
      rolesReadable: roles.ok,
      channelReadable: channel.ok,
      memberSearchAvailable: memberSearch.ok,
    };
  }

  const rolesById = Object.fromEntries(roles.map(role => [role.id, role]));
  let permissions = BigInt(rolesById[GUILD_ID]?.permissions || 0);
  member.roles.forEach(roleId => {
    permissions |= BigInt(rolesById[roleId]?.permissions || 0);
  });

  const administrator = Boolean(permissions & permissionBit(3));
  const canManageRoles = administrator || Boolean(permissions & permissionBit(28));
  let channelPermissions = permissions;
  channelPermissions = applyOverwrite(
    channelPermissions,
    channel.permission_overwrites?.find(overwrite => overwrite.id === GUILD_ID),
  );

  let roleAllow = 0n;
  let roleDeny = 0n;
  (channel.permission_overwrites || []).forEach(overwrite => {
    if (overwrite.type === 0 && member.roles.includes(overwrite.id)) {
      roleAllow |= BigInt(overwrite.allow || 0);
      roleDeny |= BigInt(overwrite.deny || 0);
    }
  });
  channelPermissions = (channelPermissions & ~roleDeny) | roleAllow;
  channelPermissions = applyOverwrite(
    channelPermissions,
    channel.permission_overwrites?.find(overwrite => overwrite.type === 1 && overwrite.id === bot.id),
  );

  const configuredRoleIds = Object.values(TEAM_ROLES);
  const missingRoleIds = configuredRoleIds.filter(roleId => !rolesById[roleId]);
  const botHighestPosition = Math.max(0, ...member.roles.map(roleId => rolesById[roleId]?.position || 0));
  const hierarchyBlockedRoleIds = configuredRoleIds.filter(roleId => (
    rolesById[roleId] && rolesById[roleId].position >= botHighestPosition
  ));
  const canViewChannel = administrator || Boolean(channelPermissions & permissionBit(10));
  const canSendMessages = administrator || Boolean(channelPermissions & permissionBit(11));
  const channelMatchesGuild = channel.guild_id === GUILD_ID;
  const botMatchesMember = member.user?.id === bot.id;
  const ok = canManageRoles && canViewChannel && canSendMessages && channelMatchesGuild
    && botMatchesMember && missingRoleIds.length === 0 && hierarchyBlockedRoleIds.length === 0;

  return {
    ok,
    authenticated: true,
    guildMember: botMatchesMember,
    channelMatchesGuild,
    canViewChannel,
    canSendMessages,
    canManageRoles,
    memberSearchAvailable: true,
    configuredTeamRoles: configuredRoleIds.length,
    missingTeamRoles: missingRoleIds.length,
    rolesBlockedByHierarchy: hierarchyBlockedRoleIds.length,
  };
}

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (!WEBHOOK_SECRET || !DISCORD_TOKEN) {
    console.error('Discord webhook configuration is incomplete');
    return res.status(503).json({ error: 'Webhook configuration is incomplete' });
  }

  if (req.headers['x-webhook-secret'] !== WEBHOOK_SECRET) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  try {
    const payload = req.body;
    if (payload?.type === 'PING') {
      const health = await checkDiscordConfiguration();
      return res.status(health.ok ? 200 : 502).json(health);
    }

    const wasApproved = payload.old_record?.approval_status === 'approved';
    const isNewApproval = payload.record?.approval_status === 'approved' && !wasApproved;
    if (!isNewApproval) {
      return res.status(200).json({ message: 'Ignored' });
    }

    const { car_number, gamertag, team_name, discord_username, discord_user_id } = payload.record;
    if (!car_number || !gamertag) return res.status(200).json({ message: 'Missing fields' });

    const team = team_name || TEAM_MAP[car_number] || 'Unknown Team';
    const emoji = TEAM_EMOJI[team] || '🏁';
    const totalClaims = await getTotalClaims();
    const spotsLeft = totalClaims !== null ? Math.max(0, ROSTER_SIZE - totalClaims) : null;

    let roleStatus = '';
    let memberId = null;
    let roleAssigned = false;
    const roleId = TEAM_ROLES[team];
    const manualTag = COMMISSIONER_ID ? `<@${COMMISSIONER_ID}>` : 'the commissioner';

    // Preferred path: assign role directly by numeric Discord user ID.
    if (discord_user_id && /^\d{5,}$/.test(String(discord_user_id))) {
      const uid = String(discord_user_id);
      if (roleId) {
        const roleResult = await assignRole(uid, roleId);
        if (roleResult.ok) {
          memberId = uid;
          roleAssigned = true;
          roleStatus = `\n✅ **${team} role assigned** to <@${uid}>`;
        } else {
          roleStatus = `\n⚠️ Role assignment failed for <@${uid}> (status ${roleResult.status}) — ${manualTag} will assign it`;
        }
      }
    } else if (discord_username) {
      // Fallback: resolve by typed name (username / display name / nick).
      const member = await findMemberByUsername(discord_username);
      if (member && roleId) {
        const uid = member.user.id;
        const roleResult = await assignRole(uid, roleId);
        if (roleResult.ok) {
          memberId = uid;
          roleAssigned = true;
          roleStatus = `\n✅ **${team} role assigned** to <@${uid}>`;
        } else {
          roleStatus = `\n⚠️ Found ${discord_username} but role assignment failed (status ${roleResult.status}) — ${manualTag} will assign it`;
        }
      } else if (!member) {
        roleStatus = `\n⚠️ Couldn't match **${discord_username}** to a server member — ${manualTag} will assign the ${team} role manually`;
      }
    } else {
      roleStatus = `\n⚠️ No Discord username provided — ${manualTag} will assign your role`;
    }

    const spotsText = spotsLeft !== null ? `\n**${spotsLeft} spot${spotsLeft !== 1 ? 's' : ''} remaining out of ${ROSTER_SIZE}**` : '';
    const finalCall = spotsLeft === 0
      ? `\n\n🏁 **The roster is FULL. Season 1 is locked.**`
      : spotsLeft === 1 ? `\n⚠️ **Last spot — one car left!**` : '';

    const message = [
      `**✅ Driver Application Approved**`,
      `**#${car_number}** — ${emoji} ${team}`,
      `**Gamertag:** ${gamertag}`,
      spotsText,
      roleStatus,
      finalCall,
    ].filter(Boolean).join('\n');

    const postResult = await postToDiscord(message);
    if (!postResult.ok) {
      console.error('Announcement post FAILED', { car_number, status: postResult.status, body: postResult });
      return res.status(502).json({ ok: false, posted: false, roleAssigned, status: postResult.status });
    }

    return res.status(200).json({ ok: true, posted: true, roleAssigned });
  } catch (err) {
    console.error('Webhook error:', err);
    return res.status(500).json({ error: 'Internal error' });
  }
}
