import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sharp = require(process.env.BARL_SHARP_PATH || 'sharp');

const ROOT = path.resolve(import.meta.dirname, '..');
const SCRAPE_DIR = path.join(ROOT, '.firecrawl');
const ASSET_DIR = path.join(ROOT, 'assets', 'driver-numbers');
const OUTPUT = path.join(ROOT, 'data', 'driver-number-styles.js');
const DEFAULTS_OUTPUT = path.join(ROOT, 'scripts', 'number-style-defaults.js');

const DRIVERS = {
  '1': 'ross-chastain', '2': 'austin-cindric', '5': 'kyle-larson', '6': 'brad-keselowski',
  '7': 'daniel-suarez', '9': 'chase-elliott', '11': 'denny-hamlin', '12': 'ryan-blaney',
  '17': 'chris-buescher', '19': 'chase-briscoe', '20': 'christopher-bell', '22': 'joey-logano',
  '23': 'bubba-wallace', '24': 'william-byron', '35': 'riley-herbst', '42': 'john-hunter-nemecheck',
  '43': 'erik-jones', '45': 'tyler-reddick', '48': 'alex-bowman', '54': 'ty-gibbs',
  '60': 'ryan-preece', '71': 'michael-mcdowell', '77': 'carson-hocevar', '84': 'jimmie-johnson',
  '88': 'connor-zilisch', '97': 'shane-van-gisbergen',
};

// A few cards use a full-field texture or a same-color background that cannot be
// cleanly separated from the numeral. Omit those instead of shipping a muddy cutout.
const EXCLUDED_KEYS = new Set([
  '1:jockey-ventracool-air',
  '1:jockey-folds-of-honor-military',
  '1:busch-light-farming',
  '6:solomon-plumbing-darlington-throwback-2009-greg-biffle-scotch-brite-fo',
  '7:coke-zero-sugar',
  '11:king-s-hawaiian-ube-cononut-rolls',
  '17:5-3-bank-darlington-throwback-2011-greg-biffle-scotch-blue-ford',
  '19:wix-filters',
  '20:interstate-batteries-camo',
  '23:xfinity',
  '23:chumba-casino-king-croc-fury',
  '24:raptor-coatings',
  '24:phorm-energy',
  '42:dollar-tree',
  '42:tristate-vacuum-and-rental',
  '43:dollar-tree',
  '45:jordan-brand',
  '54:interstate-batteries',
  '54:monster-energy-patriotic',
  '54:victory-junction-gang-cook-out',
  '71:katz-coffee',
  '88:tootsie-s-panama-city-beach',
  '88:very-good-ventures-ai',
  '97:superfile-mr-brainwash',
  '97:superfile-camo',
  '97:super-file-lefty-out-there',
]);

const slugify = value => value.toLowerCase().replace(/\\\|/g, ' ').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 70);
const colorDistance = (data, a, b) => {
  const dr = data[a] - data[b];
  const dg = data[a + 1] - data[b + 1];
  const db = data[a + 2] - data[b + 2];
  return dr * dr + dg * dg + db * db;
};

// The source cards place the number in the middle of a flat background. Removing
// only pixels connected to the outer edge preserves multicolor fills and outlines.
async function removeEdgeBackground(input) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  const count = width * height;
  const background = new Uint8Array(count);
  const queue = new Uint32Array(count);
  let head = 0;
  let tail = 0;
  const seed = pixel => {
    if (background[pixel]) return;
    background[pixel] = 1;
    queue[tail++] = pixel;
  };
  for (let x = 0; x < width; x += 1) { seed(x); seed((height - 1) * width + x); }
  for (let y = 1; y < height - 1; y += 1) { seed(y * width); seed(y * width + width - 1); }

  const threshold = 18 * 18;
  while (head < tail) {
    const pixel = queue[head++];
    const x = pixel % width;
    const offset = pixel * channels;
    const visit = neighbor => {
      if (background[neighbor]) return;
      if (colorDistance(data, offset, neighbor * channels) > threshold) return;
      background[neighbor] = 1;
      queue[tail++] = neighbor;
    };
    if (x > 0) visit(pixel - 1);
    if (x + 1 < width) visit(pixel + 1);
    if (pixel >= width) visit(pixel - width);
    if (pixel + width < count) visit(pixel + width);
  }

  let foreground = 0;
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let pixel = 0; pixel < count; pixel += 1) {
    const alphaOffset = pixel * channels + 3;
    if (background[pixel]) {
      data[alphaOffset] = 0;
      continue;
    }
    foreground += 1;
    const x = pixel % width;
    const y = Math.floor(pixel / width);
    minX = Math.min(minX, x);
    minY = Math.min(minY, y);
    maxX = Math.max(maxX, x);
    maxY = Math.max(maxY, y);
  }

  const ratio = foreground / count;
  const valid = ratio >= .08 && ratio <= .70;
  if (!valid) return { valid, ratio, output: null };

  const output = await sharp(data, { raw: info })
    .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .resize(512, 512, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
      withoutEnlargement: false,
    })
    .png({ compressionLevel: 9 })
    .toBuffer();
  return { valid, ratio, output };
}

async function mapLimit(items, limit, callback) {
  let cursor = 0;
  const results = new Array(items.length);
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await callback(items[index], index);
    }
  }));
  return results;
}

async function main() {
  await fs.rm(ASSET_DIR, { recursive: true, force: true });
  await fs.mkdir(ASSET_DIR, { recursive: true });
  const catalog = {};
  let rejected = 0;

  for (const [number, driver] of Object.entries(DRIVERS)) {
    const filename = `diecastcharv.com-2026-${driver}-cup-number-cards.md`;
    const markdown = await fs.readFile(path.join(SCRAPE_DIR, filename), 'utf8');
    const sourcePage = `https://diecastcharv.com/2026-${driver}-cup-number-cards/`;
    const matches = [...markdown.matchAll(/\*\*([^*\n]+)\*\*\s*\n+!\[\]\((https:\/\/diecastcharv\.com\/wp-content\/uploads\/[^)]+)\)SIDE!\[\]\((https:\/\/diecastcharv\.com\/wp-content\/uploads\/[^)]+)\)ROOF/g)];
    const used = new Map();
    const candidates = matches.map((match, index) => {
      const label = match[1].replace(/\\\|/g, '|').trim();
      const base = slugify(label) || `style-${index + 1}`;
      const suffix = (used.get(base) || 0) + 1;
      used.set(base, suffix);
      const slug = suffix === 1 ? base : `${base}-${suffix}`;
      return {
        number,
        label,
        key: `${number}:${slug}`,
        image: `assets/driver-numbers/${number}/${slug}.png`,
        sourceImage: match[3],
        sourcePage,
      };
    });

    const results = await mapLimit(candidates, 6, async item => {
      const response = await fetch(item.sourceImage);
      if (!response.ok) throw new Error(`${response.status} downloading ${item.sourceImage}`);
      const processed = await removeEdgeBackground(Buffer.from(await response.arrayBuffer()));
      return { item, ...processed };
    });

    const accepted = results.filter(result => result.valid && !EXCLUDED_KEYS.has(result.item.key));
    if (accepted.length < 2) {
      const rejectedDetails = results.filter(result => !result.valid).map(result => `${result.item.label}=${result.ratio.toFixed(3)}`).join(', ');
      process.stdout.write(`#${number} rejected: ${rejectedDetails}\n`);
    }
    catalog[number] = accepted.map(({ item }) => ({ key: item.key, label: item.label, image: item.image, sourcePage: item.sourcePage }));
    rejected += results.length - accepted.length;
    process.stdout.write(`#${number}: kept ${accepted.length}/${results.length}\n`);
    await mapLimit(accepted, 4, async ({ item, output }) => {
      const destination = path.join(ROOT, item.image);
      await fs.mkdir(path.dirname(destination), { recursive: true });
      await fs.writeFile(destination, output);
    });
  }

  const header = '// Generated from the public 2026 Cup number-card catalog. Rebuild with scripts/build-number-style-catalog.mjs.\n';
  await fs.writeFile(OUTPUT, `${header}export const NUMBER_STYLES = ${JSON.stringify(catalog, null, 2)};\n`);
  const defaults = Object.fromEntries(Object.entries(catalog).map(([number, styles]) => [number, styles[0].image]));
  await fs.writeFile(DEFAULTS_OUTPUT, `// Generated by scripts/build-number-style-catalog.mjs.\nwindow.BARL_NUMBER_IMAGES = ${JSON.stringify(defaults, null, 2)};\nwindow.BARLNumberImage = function (number) { return window.BARL_NUMBER_IMAGES[String(number)] || ''; };\n`);
  const total = Object.values(catalog).reduce((sum, styles) => sum + styles.length, 0);
  process.stdout.write(`Wrote ${total} transparent number styles across ${Object.keys(catalog).length} cars; rejected ${rejected} poor cutouts.\n`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
