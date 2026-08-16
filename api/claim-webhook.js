// Supabase → Discord webhook handler
// Fires on new n26_claims INSERT
// 1. Posts claim announcement to #announcements
// 2. Looks up Discord user by username
// 3. Assigns their team role automatically

const DISCORD_TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = "1537572693837217873";
const ANNOUNCEMENTS_CHANNEL = "1537577565093502987";
const WEBHOOK_SECRET = process.env.SUPABASE_WEBHOOK_SECRET;
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
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/n26_claims?select=car_number`,
    { headers: { 'apikey': process.env.SUPABASE_ANON_KEY, 'Authorization': `Bearer ${process.env.SUPABASE_ANON_KEY}` } }
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

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  if (WEBHOOK_SECRET && req.headers['x-webhook-secret'] !== WEBHOOK_SECRET) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  try {
    const payload = req.body;
    if (payload.type !== 'INSERT' || !payload.record) {
      return res.status(200).json({ message: 'Ignored' });
    }

    const { car_number, gamertag, team_name, discord_username, discord_user_id } = payload.record;
    if (!car_number || !gamertag) return res.status(200).json({ message: 'Missing fields' });

    const team = team_name || TEAM_MAP[car_number] || 'Unknown Team';
    const emoji = TEAM_EMOJI[team] || '🏁';
    const totalClaims = await getTotalClaims();
    const spotsLeft = totalClaims !== null ? 21 - totalClaims : null;

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

    const spotsText = spotsLeft !== null ? `\n**${spotsLeft} spot${spotsLeft !== 1 ? 's' : ''} remaining out of 23**` : '';
    const finalCall = spotsLeft === 0
      ? `\n\n🏁 **The roster is FULL. Season 1 is locked.**`
      : spotsLeft === 1 ? `\n⚠️ **Last spot — one car left!**` : '';

    const message = [
      `**🚗 New Driver Claimed**`,
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
