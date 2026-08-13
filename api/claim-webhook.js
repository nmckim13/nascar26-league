// Supabase → Discord webhook handler
// Fires on new n26_claims INSERT
// 1. Posts claim announcement to #announcements
// 2. Looks up Discord user by username
// 3. Assigns their team role automatically

const DISCORD_TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = "1537572693837217873";
const ANNOUNCEMENTS_CHANNEL = "1537577565093502987";
const WEBHOOK_SECRET = process.env.SUPABASE_WEBHOOK_SECRET;

// Team → Discord role ID
const TEAM_ROLES = {
  'Hendrick Motorsports': '1537581458774954085',
  'Joe Gibbs Racing':     '1537581461480149026',
  'Team Penske':          '1537581465036918884',
  '23XI Racing':          '1537581468140830750',
  'RFK Racing':           '1537581471219581019',
  'Spire Motorsports':    '1537581474990260294',
  'Trackhouse Racing':    '1537581478270206024',
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
};

const TEAM_EMOJI = {
  'Hendrick Motorsports':'🔵','Joe Gibbs Racing':'🟠','Team Penske':'🔴',
  '23XI Racing':'🟥','RFK Racing':'⚪','Spire Motorsports':'🟡',
  'Trackhouse Racing':'💙',
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
  if (res.status === 204) return { ok: true };
  const data = await res.json().catch(() => ({}));
  return { ok: res.ok, status: res.status, ...data };
}

async function getTotalClaims() {
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/n26_claims?select=car_number`,
    { headers: { 'apikey': process.env.SUPABASE_ANON_KEY, 'Authorization': `Bearer ${process.env.SUPABASE_ANON_KEY}` } }
  );
  if (!res.ok) return null;
  return (await res.json()).length;
}

// Search guild members for a username match
async function findMemberByUsername(username) {
  const clean = username.toLowerCase().replace(/^@/, '');

  // Search the guild members (up to 1000)
  const result = await discordAPI('GET', `/guilds/${GUILD_ID}/members?limit=1000`);
  if (!Array.isArray(result)) return null;

  // Match on username or global_name or display name
  const member = result.find(m => {
    const u = m.user;
    return (
      u.username?.toLowerCase() === clean ||
      u.global_name?.toLowerCase() === clean ||
      u.display_name?.toLowerCase() === clean ||
      // also try partial match on the discriminator-less username
      u.username?.toLowerCase().startsWith(clean)
    );
  });

  return member || null;
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

    const { car_number, gamertag, team_name, discord_username } = payload.record;
    if (!car_number || !gamertag) return res.status(200).json({ message: 'Missing fields' });

    const team = team_name || TEAM_MAP[car_number] || 'Unknown Team';
    const emoji = TEAM_EMOJI[team] || '🏁';
    const totalClaims = await getTotalClaims();
    const spotsLeft = totalClaims !== null ? 21 - totalClaims : null;

    let roleStatus = '';
    let memberId = null;

    // Try to find and assign role
    if (discord_username) {
      const member = await findMemberByUsername(discord_username);
      if (member) {
        memberId = member.user.id;
        const roleId = TEAM_ROLES[team];
        if (roleId) {
          const roleResult = await assignRole(memberId, roleId);
          roleStatus = roleResult.ok
            ? `\n✅ **${team} role assigned** to <@${memberId}>`
            : `\n⚠️ Found ${discord_username} but role assignment failed — assign manually`;
        }
      } else {
        roleStatus = `\n⚠️ **${discord_username}** not found in server — join BARL Discord to get your team role`;
      }
    } else {
      roleStatus = `\n⚠️ No Discord username provided — DM Nolan to get your role`;
    }

    const spotsText = spotsLeft !== null ? `\n**${spotsLeft} spot${spotsLeft !== 1 ? 's' : ''} remaining out of 21**` : '';
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

    await postToDiscord(message);

    return res.status(200).json({ ok: true, roleAssigned: !!memberId });
  } catch (err) {
    console.error('Webhook error:', err);
    return res.status(500).json({ error: 'Internal error' });
  }
}
