import { createHmac } from 'node:crypto';
import { isIP } from 'node:net';

const MAX_BODY_BYTES = 2048;
const PLATFORMS = new Set(['playstation', 'xbox', 'pc']);
const EMAIL = /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/;

async function readBody(req) {
  const length = req.headers?.['content-length'];
  if (length !== undefined && (!/^\d+$/.test(String(length)) || Number(length) > MAX_BODY_BYTES)) throw new Error('Invalid body');
  const type = req.headers?.['content-type'];
  if (type && type.split(';')[0].trim().toLowerCase() !== 'application/json') throw new Error('Invalid body');
  let body = req.body;
  if (body === undefined) {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
      const buffer = Buffer.from(chunk);
      size += buffer.length;
      if (size > MAX_BODY_BYTES) throw new Error('Invalid body');
      chunks.push(buffer);
    }
    body = Buffer.concat(chunks).toString('utf8');
  }
  if (Buffer.isBuffer(body)) body = body.toString('utf8');
  if (Buffer.byteLength(typeof body === 'string' ? body : JSON.stringify(body) || '') > MAX_BODY_BYTES) throw new Error('Invalid body');
  if (typeof body === 'string') body = JSON.parse(body);
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('Invalid body');
  return body;
}

function clientAddress(req) {
  // Vercel overwrites this header at its edge. Never trust caller-supplied
  // X-Forwarded-For, or proxy headers when running outside Vercel.
  const forwarded = process.env.VERCEL === '1' && req.headers?.['x-vercel-forwarded-for'];
  const address = typeof forwarded === 'string' ? forwarded.split(',')[0].trim() : '';
  if (isIP(address)) return address;
  return isIP(req.socket?.remoteAddress || '') ? req.socket.remoteAddress : 'unknown';
}

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ ok: false, error: 'Method not allowed.' });
  }
  let email;
  let platform;
  try {
    const body = await readBody(req);
    if (body.website !== undefined && typeof body.website !== 'string') throw new Error('Invalid body');
    // Bots receive the same success response, even without database config.
    if (body.website?.trim()) return res.status(200).json({ ok: true });
    email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
    platform = body.platform;
    const local = email.split('@')[0];
    if (email.length > 254 || !EMAIL.test(email) || local.length > 64 || local.startsWith('.') || local.endsWith('.') || local.includes('..') || !PLATFORMS.has(platform)) {
      throw new Error('Invalid submission');
    }
  } catch {
    return res.status(400).json({ ok: false, error: 'Enter a valid email and platform.' });
  }

  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  try {
    if (!url || !key) throw new Error('Unavailable');
    const clientHash = createHmac('sha256', key).update(clientAddress(req)).digest('hex');
    const response = await fetch(`${url}/rest/v1/rpc/n26_submit_season_interest`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_email: email, p_platform: platform, p_client_hash: clientHash }),
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error('Unavailable');
    const accepted = await response.json();
    if (accepted === false) {
      res.setHeader('Retry-After', '600');
      return res.status(429).json({ ok: false, error: 'Too many submissions. Please try again later.' });
    }
    if (accepted !== true) throw new Error('Unavailable');
    return res.status(200).json({ ok: true });
  } catch {
    // Do not expose or log submitted emails, service credentials, or DB errors.
    return res.status(503).json({ ok: false, error: 'Interest signup is temporarily unavailable. Please try again later.' });
  }
}
