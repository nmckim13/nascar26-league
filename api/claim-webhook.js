// Supabase → Discord webhook handler
// Fires when a new row is inserted into n26_claims
// Posts a claim announcement to the BARL Discord #announcements channel

const DISCORD_TOKEN = process.env.DISCORD_BOT_TOKEN;
const DISCORD_CHANNEL_ID = "1537577565093502987"; // #announcements
const WEBHOOK_SECRET = process.env.SUPABASE_WEBHOOK_SECRET;

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
  'Hendrick Motorsports': '🔵',
  'Joe Gibbs Racing': '🟠',
  'Team Penske': '🔴',
  '23XI Racing': '🟥',
  'RFK Racing': '⚪',
  'Spire Motorsports': '🟡',
  'Trackhouse Racing': '💙',
};

async function postToDiscord(content) {
  const res = await fetch(`https://discord.com/api/v10/channels/${DISCORD_CHANNEL_ID}/messages`, {
    method: 'POST',
    headers: {
      'Authorization': `Bot ${DISCORD_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ content }),
  });
  if (!res.ok) {
    const err = await res.text();
    console.error('Discord error:', err);
  }
  return res.ok;
}

async function getTotalClaims() {
  const res = await fetch(
    `${process.env.SUPABASE_URL}/rest/v1/n26_claims?select=car_number`,
    {
      headers: {
        'apikey': process.env.SUPABASE_ANON_KEY,
        'Authorization': `Bearer ${process.env.SUPABASE_ANON_KEY}`,
      }
    }
  );
  if (!res.ok) return null;
  const data = await res.json();
  return data.length;
}

export default async function handler(req, res) {
  // Only accept POST
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  // Verify webhook secret if set
  if (WEBHOOK_SECRET) {
    const secret = req.headers['x-webhook-secret'];
    if (secret !== WEBHOOK_SECRET) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  }

  try {
    const payload = req.body;

    // Supabase sends { type: 'INSERT', record: {...}, ... }
    if (payload.type !== 'INSERT' || !payload.record) {
      return res.status(200).json({ message: 'Not an insert, ignored' });
    }

    const claim = payload.record;
    const { car_number, gamertag, team_name, first_name } = claim;

    if (!car_number || !gamertag) {
      return res.status(200).json({ message: 'Missing fields, ignored' });
    }

    const team = team_name || TEAM_MAP[car_number] || 'Unknown Team';
    const emoji = TEAM_EMOJI[team] || '🏁';
    const totalClaims = await getTotalClaims();
    const spotsLeft = totalClaims !== null ? 21 - totalClaims : null;
    const spotsText = spotsLeft !== null
      ? `${spotsLeft} spot${spotsLeft !== 1 ? 's' : ''} remaining`
      : '';

    const message = [
      `**🚗 New Driver Claimed**`,
      `**#${car_number}** — ${emoji} ${team}`,
      `**Gamertag:** ${gamertag}`,
      spotsText ? `**${spotsText} out of 21**` : '',
      spotsLeft === 0 ? `\n🏁 **The roster is FULL. Season 1 is set.**` : '',
      spotsLeft === 1 ? `\n⚠️ **Last spot — one car left!**` : '',
    ].filter(Boolean).join('\n');

    await postToDiscord(message);

    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error('Webhook error:', err);
    return res.status(500).json({ error: 'Internal error' });
  }
}
