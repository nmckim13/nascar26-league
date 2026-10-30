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
const PREFERRED_DEFAULTS = {
  '2': '2:ppg-paints',
  '3': '3:arthur-tiger',
  '12': '12:dent-wizard',
  '14': '14:mini-tyrrell-ram',
  '23': '23:shadyrays',
  '42': '42:travis-pastrana-brunt',
  '43': '43:advent-health',
  '48': '48:ally-bank',
  '60': '60:ryan-preece-chrome',
  '84': '84:carvana-sunset',
  '88': '88:hendrick-red',
  '93': '93:caleb-costner-piedmont-realtree',
};

// Verified background regions, measured on the normalized 512px artwork.
// Preserve the original filled interiors of #6, #60, and the zero in #20;
// only #20's gap between the two digits is background.
const COUNTER_SEEDS = {
  '9': [[280, 190]],
  '17': [[240, 290]],
  '19': [[360, 200]],
  '20': [[234, 285]],
  '24': [[350, 255]],
  '42': [[145, 255]],
  '43': [[130, 260]],
  '45': [[140, 260]],
  '48': [[145, 240], [380, 185], [350, 325]],
  '54': [[340, 260]],
  '84': [[150, 200], [130, 315], [370, 255]],
  '88': [[170, 200], [145, 310], [370, 200], [345, 310]],
  '97': [[150, 200]],
};

const CUSTOM_STYLES = [
  {
    "key": "3:arthur-tiger",
    "label": "ARTHUR | TIGER STRIPE TRUCK",
    "image": "assets/driver-numbers/3/arthur-tiger.png",
    "sourcePage": "https://diecastcharv.com/2025-austin-dillon-cup-number-cards/",
    "sourceImage": "https://diecastcharv.com/wp-content/uploads/2025/02/slide28-1.jpg"
  },
  {
    "key": "14:mini-tyrrell-ram",
    "label": "MINI TYRRELL | RAM TRUCK",
    "image": "assets/driver-numbers/14/mini-tyrrell-ram.png",
    "sourcePage": "https://diecastcharv.com/2026-mini-tyrrell-truck-number-cards/",
    "sourceImage": "https://diecastcharv.com/wp-content/uploads/2026/02/slide35.jpg"
  },
  {
    "key": "88:hendrick-red",
    "label": "HENDRICK 88 | RED / WHITE",
    "image": "assets/driver-numbers/88/hendrick-red.png",
    "sourcePage": "https://diecastcharv.com/dale-earnhardt-jr-cup-number-cards/",
    "sourceImage": "https://diecastcharv.com/wp-content/uploads/2017/08/slide567.jpg"
  },
  {
    "key": "42:travis-pastrana-brunt",
    "label": "TRAVIS PASTRANA | BRUNT TRUCK",
    "image": "assets/driver-numbers/42/travis-pastrana-brunt.png",
    "sourcePage": "https://diecastcharv.com/2026-travis-pastrana-truck-number-cards/"
  },
  {
    "key": "60:ryan-preece-chrome",
    "label": "RYAN PREECE | CHROME",
    "image": "assets/driver-numbers/60/ryan-preece-chrome.png",
    "sourcePage": "https://www.nascar.com/drivers/ryan-preece",
    "sourceImage": "https://www.nascar.com/wp-content/uploads/sites/7/2026/01/26/60@10x.png"
  },
  {
    "key": "93:caleb-costner-piedmont-realtree",
    "label": "CALEB COSTNER | PIEDMONT / REALTREE TRUCK",
    "image": "assets/driver-numbers/93/caleb-costner-piedmont-realtree.png",
    "sourcePage": "https://diecastcharv.com/2026-caleb-costner-truck-number-cards/",
    "sourceImage": "https://diecastcharv.com/wp-content/uploads/2026/04/slide298-1.jpg"
  }
];

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
  // Superseded by Brantley's requested white/camo Piedmont/Realtree scheme.
  '93:caleb-costner-lickety-lews',
  // A detached star column makes the actual #2 shorter than its artwork bounds.
  '2:ppg-paints-patriotic',
  // Both digits must share a coherent fill and outline. Ovals are badges,
  // not transparent number marks, so they do not belong in this picker either.
  '12:wurth',
  '12:wabash-ryan-newman-throwback',
  '23:hardee-s',
  '23:columbia-sportswear',
  '23:hardee-s-coca-cola',
  '23:coca-cola-soccer',
  '42:pyre-barker-fire-and-safety-patriotic',
  '43:dollar-tree-patriotic',
  '43:advent-health-patriotic',
  '43:advent-health-darlington-throwback-1994-wally-dallenbach-stp-pontiac',
  '43:dollar-tree-throwback',
  '45:xfinity',
  '45:supply-house',
  '71:nefco',
  '71:modo-casino-lone-star',
  '71:garner-trucking',
  '77:chili-s-ride-the-dente-white',
  // Their inner backgrounds join a diagonal stripe or outer field. Cutting
  // those out would damage the mark; retain the clean variants of these fonts.
  '88:superfile-trackhouse-moto',
  '97:superfile',
  '97:weathertech',
  '97:tootsie-s-orchid-lounge',
  '97:mitti-by-safety-culture',
  '97:superfile-trackhouse-moto',
  // Black-filled and low-contrast numbers disappear on BARL's black panels.
  // Retire them rather than trying to rescue them with a CSS outline.
  '1:busch-light',
  '1:busch-light-music-city',
  '1:jockey-150th-anniversary',
  '1:wendy-s-watermelon-lemonade',
  '2:discount-tire',
  '2:autotrader',
  '2:menards-dark-green',
  '2:menards-black',
  '2:menards-menards-blue',
  '2:menards-yellow-green',
  '2:menards-medium-blue',
  '2:menards-red',
  '2:menards-dark-marine-blue',
  '6:graza',
  '6:trimble',
  '6:modelo',
  '9:unifirst',
  '11:sport-clips',
  '11:national-debt-relief',
  '12:menards-black',
  '12:menards-blue',
  '12:menards-peacock-blue',
  '12:pennzoil-menards',
  '12:discount-tire',
  '12:menards-spruce-green',
  '12:menards-azure-blue',
  '12:menards-green',
  '12:menards-royal-blue',
  '12:menards-grass',
  '12:menards-cardinal-red',
  '12:bodyarmor-flash-i-v-patriotic',
  '17:trimble',
  '17:thomas-high-protein',
  '17:oscar-mayer-rustik-oven',
  '17:kleenex',
  '19:bass-pro-shops-patriotic',
  '22:pennzoil-ultra-platinum',
  '22:discount-tire',
  '22:shell-pennzoil-patriotic',
  '22:hunt-brothers-pizza-patriotic',
  '23:robinhood',
  '23:wwe-chumba-casino',
  '23:chumba-casino',
  '23:columbia-pfg-2',
  '23:columbia-sportswear-patriotic',
  '24:hp',
  '24:valvoline-restore-and-protect',
  '42:dollar-tree-4',
  '42:raid',
  '45:comparion-insurance',
  '45:jordan-brand-space-jam-30th',
  '48:ally-bank-patriotic',
  '54:ampm',
  '54:siriusxm',
  '60:trimble',
  '60:force-factor',
  '60:international-delight',
  '88:jockey-150th-anniversary',
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
  // These source cards have artwork physically joined to the number. Automated
  // background removal cannot separate it without damaging the authentic mark.
  '6:castrol-greg-biffle-tribute',
  '17:fastenal-body-guard-greg-biffle-tribute',
  '24:anduril-industrie-patriotic',
  '35:gogo-swueez',
  '42:dollar-tree-40th-anniversary',
  '42:dollar-tree-white',
  '42:drive-value',
  '42:rexel',
  '43:dollar-tree-dorito-s',
  '43:ziploc',
  '48:ally-bank-best-friends',
  '48:ally-bank-dragon',
  '48:ally-bank-rebrand',
  '48:ally-bank-uso',
  '60:heinz-oscar-mayer-darlington-throwback-2009-greg-biffle-3m-ford',
  '60:kroger-viva-paper-towels-greg-biffle-tribute',
  '71:fly-alliance',
  '77:spectrum',
  '88:trackhouse-racing',
  '97:trackhouse-racing',
]);

const slugify = value => value.toLowerCase().replace(/\\\|/g, ' ').replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 70);
const colorDistance = (data, a, b) => {
  const dr = data[a] - data[b];
  const dg = data[a + 1] - data[b + 1];
  const db = data[a + 2] - data[b + 2];
  return dr * dr + dg * dg + db * db;
};

async function clearNumberCounters(input, number) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  for (const [x, y] of COUNTER_SEEDS[number] || []) {
    const start = y * width + x;
    if (data[start * channels + 3] < 128) continue;
    const seen = new Uint8Array(width * height);
    const queue = new Uint32Array(width * height);
    let head = 0;
    let tail = 1;
    let touchesTransparency = false;
    queue[0] = start;
    seen[start] = 1;
    while (head < tail) {
      const pixel = queue[head++];
      const px = pixel % width;
      const visit = neighbor => {
        if (seen[neighbor]) return;
        if (data[neighbor * channels + 3] < 128) {
          touchesTransparency = true;
          return;
        }
        if (colorDistance(data, start * channels, neighbor * channels) > 96 * 96) return;
        seen[neighbor] = 1;
        queue[tail++] = neighbor;
      };
      if (px > 0) visit(pixel - 1);
      if (px + 1 < width) visit(pixel + 1);
      if (pixel >= width) visit(pixel - width);
      if (pixel + width < width * height) visit(pixel + width);
    }
    // Never let a seed erase the digit itself or an exposed outer outline.
    if (touchesTransparency || tail < 30 || tail > 15000) continue;
    for (let i = 0; i < tail; i += 1) data[queue[i] * channels + 3] = 0;
  }
  return sharp(data, { raw: info }).png({ compressionLevel: 9 }).toBuffer();
}

async function normalizeNumberSize(input) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let left = info.width;
  let top = info.height;
  let right = 0;
  let bottom = 0;
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      if (data[(y * info.width + x) * info.channels + 3] < 128) continue;
      left = Math.min(left, x);
      top = Math.min(top, y);
      right = Math.max(right, x);
      bottom = Math.max(bottom, y);
    }
  }
  // Equal visible height, not equal maximum dimension: a wide #17 must not
  // become shorter than #19, and a narrow #1 must not tower over either one.
  const height = 288;
  const width = Math.round((right - left + 1) * height / (bottom - top + 1));
  if (width > 608) throw new Error('Number artwork is too wide for the shared display canvas.');
  return sharp(data, { raw: info })
    .extract({ left, top, width: right - left + 1, height: bottom - top + 1 })
    .resize(width, height)
    .extend({ top: 48, bottom: 48, left: Math.floor((640 - width) / 2), right: Math.ceil((640 - width) / 2), background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png({ compressionLevel: 9 })
    .toBuffer();
}

// Remove detached specks, crop marks, and background decoration while keeping
// every substantial connected part of the number. A 1.2% floor is conservative
// enough to retain intentional patriotic stars but removes the random dots and
// hairline fragments found on several source cards.
function removeDetachedArtifacts(data, info) {
  const { width, height, channels } = info;
  const count = width * height;
  const labels = new Uint32Array(count);
  const queue = new Uint32Array(count);
  const sizes = [0];
  let nextLabel = 0;
  let totalForeground = 0;

  for (let pixel = 0; pixel < count; pixel += 1) {
    if (labels[pixel] || data[pixel * channels + 3] < 24) continue;
    const label = ++nextLabel;
    let head = 0;
    let tail = 0;
    let size = 0;
    labels[pixel] = label;
    queue[tail++] = pixel;

    while (head < tail) {
      const current = queue[head++];
      const x = current % width;
      size += 1;
      const visit = neighbor => {
        if (labels[neighbor] || data[neighbor * channels + 3] < 24) return;
        labels[neighbor] = label;
        queue[tail++] = neighbor;
      };
      if (x > 0) visit(current - 1);
      if (x + 1 < width) visit(current + 1);
      if (current >= width) visit(current - width);
      if (current + width < count) visit(current + width);
    }

    sizes[label] = size;
    totalForeground += size;
  }

  const minimumSize = Math.max(80, Math.floor(totalForeground * .012));
  let keptForeground = 0;
  for (let pixel = 0; pixel < count; pixel += 1) {
    const alphaOffset = pixel * channels + 3;
    if (!labels[pixel] || sizes[labels[pixel]] < minimumSize) {
      data[alphaOffset] = 0;
    } else {
      keptForeground += 1;
    }
  }
  return keptForeground / count;
}

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

  for (let pixel = 0; pixel < count; pixel += 1) {
    const alphaOffset = pixel * channels + 3;
    if (background[pixel]) {
      data[alphaOffset] = 0;
    }
  }

  const ratio = removeDetachedArtifacts(data, info);
  const valid = ratio >= .08 && ratio <= .70;
  if (!valid) return { valid, ratio, output: null };

  const output = await sharp(data, { raw: info })
    .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .resize(464, 464, {
      fit: 'contain',
      background: { r: 0, g: 0, b: 0, alpha: 0 },
      withoutEnlargement: false,
    })
    .extend({
      top: 24,
      bottom: 24,
      left: 24,
      right: 24,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png({ compressionLevel: 9 })
    .toBuffer();
  return { valid, ratio, output };
}

// The standard Ally #48 roof card uses a complex purple field, so edge-color
// removal cannot separate it cleanly. Isolate its two near-white numeral
// components and rebuild only the original dark-purple outline.
async function extractLightNumber(input) {
  const { data, info } = await sharp(input).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  const count = width * height;
  const number = Buffer.alloc(count * 4);

  for (let pixel = 0; pixel < count; pixel += 1) {
    const source = pixel * channels;
    const red = data[source];
    const green = data[source + 1];
    const blue = data[source + 2];
    const minimum = Math.min(red, green, blue);
    const maximum = Math.max(red, green, blue);
    if (minimum >= 225 && maximum - minimum <= 22) {
      const target = pixel * 4;
      number[target] = 255;
      number[target + 1] = 255;
      number[target + 2] = 255;
      number[target + 3] = 255;
    }
  }

  const cleanInfo = { width, height, channels: 4 };
  const ratio = removeDetachedArtifacts(number, cleanInfo);
  if (ratio < .08 || ratio > .35) return { valid: false, ratio, output: null };

  const radius = 12;
  const horizontal = new Uint8Array(count);
  const outline = new Uint8Array(count);
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (number[(y * width + x) * 4 + 3] < 24) continue;
      for (let dx = -radius; dx <= radius; dx += 1) {
        const neighborX = x + dx;
        if (neighborX >= 0 && neighborX < width) horizontal[y * width + neighborX] = 255;
      }
    }
  }
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (!horizontal[y * width + x]) continue;
      for (let dy = -radius; dy <= radius; dy += 1) {
        const neighborY = y + dy;
        if (neighborY >= 0 && neighborY < height) outline[neighborY * width + x] = 255;
      }
    }
  }

  const outlined = Buffer.alloc(count * 4);
  for (let pixel = 0; pixel < count; pixel += 1) {
    if (!outline[pixel]) continue;
    const target = pixel * 4;
    if (number[target + 3] >= 24) {
      outlined[target] = 255;
      outlined[target + 1] = 255;
      outlined[target + 2] = 255;
    } else {
      outlined[target] = 58;
      outlined[target + 1] = 35;
      outlined[target + 2] = 91;
    }
    outlined[target + 3] = 255;
  }

  const output = await sharp(outlined, { raw: cleanInfo })
    .blur(.7)
    .trim({ background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .resize(464, 464, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .extend({ top: 24, bottom: 24, left: 24, right: 24, background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png({ compressionLevel: 9 })
    .toBuffer();
  return { valid: true, ratio, output };
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
  // Re-curate checked-in artwork without downloading or reprocessing the source cards.
  if (process.argv.includes('--local')) {
    const { NUMBER_STYLES } = await import('../data/driver-number-styles.js');
    const catalog = {};
    for (const [number, styles] of Object.entries(NUMBER_STYLES)) {
      catalog[number] = styles.filter(style => !EXCLUDED_KEYS.has(style.key));
      for (const style of styles.filter(style => EXCLUDED_KEYS.has(style.key))) {
        await fs.rm(path.join(ROOT, style.image));
      }
    }
    await writeCatalog(catalog);
    return;
  }

  // Preserve curated artwork that isn't part of the downloaded Cup catalog.
  const customArtwork = await Promise.all(CUSTOM_STYLES.map(async style => ({
    style, buffer: await fs.readFile(path.join(ROOT, style.image)),
  })));
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
      const source = Buffer.from(await response.arrayBuffer());
      const processed = item.key === '48:ally-bank' ? await extractLightNumber(source) : await removeEdgeBackground(source);
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
      await fs.writeFile(destination, await clearNumberCounters(output, number));
    });
  }

  for (const { style, buffer } of customArtwork) {
    const destination = path.join(ROOT, style.image);
    await fs.mkdir(path.dirname(destination), { recursive: true });
    await fs.writeFile(destination, buffer);
  }

  await writeCatalog(catalog);
  process.stdout.write(`Rejected ${rejected} unsuitable source cards.\n`);
}

async function writeCatalog(catalog) {
  for (const style of CUSTOM_STYLES) {
    const number = style.key.split(':')[0];
    catalog[number] = [style, ...(catalog[number] || []).filter(item => item.key !== style.key)];
  }
  for (const [number, styles] of Object.entries(catalog)) {
    if (!styles.length) throw new Error(`No readable styles remain for #${number}.`);
    const preferred = styles.find(style => style.key === PREFERRED_DEFAULTS[number]);
    if (preferred) catalog[number] = [preferred, ...styles.filter(style => style !== preferred)];
    for (const style of styles) {
      const destination = path.join(ROOT, style.image);
      await fs.writeFile(destination, await normalizeNumberSize(await fs.readFile(destination)));
    }
  }
  const header = '// Generated from the public 2026 Cup number-card catalog. Rebuild with scripts/build-number-style-catalog.mjs.\n';
  await fs.writeFile(OUTPUT, `${header}export const NUMBER_STYLES = ${JSON.stringify(catalog, null, 2)};\n`);
  const defaults = Object.fromEntries(Object.entries(catalog).map(([number, styles]) => [number, styles[0].image]));
  const approvedKeys = Object.values(catalog).flat().map(style => style.key);
  await fs.writeFile(DEFAULTS_OUTPUT, `// Generated by scripts/build-number-style-catalog.mjs.\nwindow.BARL_NUMBER_IMAGES = ${JSON.stringify(defaults, null, 2)};\nwindow.BARL_NUMBER_STYLE_KEYS = new Set(${JSON.stringify(approvedKeys, null, 2)});\nwindow.BARL_SELECTED_NUMBER_STYLES = Object.create(null);\nwindow.BARLSetNumberStyles = function (rows) {\n  window.BARL_SELECTED_NUMBER_STYLES = Object.create(null);\n  (rows || []).forEach(function (row) {\n    const number = String(row.car_number || '');\n    const driverId = String(row.driver_id || '');\n    const key = String(row.style_key || '');\n    const prefix = number + ':';\n    const slug = key.startsWith(prefix) ? key.slice(prefix.length) : '';\n    if (driverId && slug && window.BARL_NUMBER_STYLE_KEYS.has(key)) {\n      window.BARL_SELECTED_NUMBER_STYLES[driverId + ':' + number] = slug;\n    }\n  });\n};\nwindow.BARLNumberImage = function (number, driverId) {\n  const normalizedNumber = String(number || '');\n  const selectedSlug = driverId ? window.BARL_SELECTED_NUMBER_STYLES[String(driverId) + ':' + normalizedNumber] : '';\n  return selectedSlug\n    ? 'assets/driver-numbers/' + normalizedNumber + '/' + selectedSlug + '.png'\n    : (window.BARL_NUMBER_IMAGES[normalizedNumber] || '');\n};\nwindow.BARLApplyNumberImage = function (image, number, driverId) {\n  if (!image) return;\n  const normalizedNumber = String(number || '');\n  image.dataset.barlNumber = normalizedNumber;\n  image.dataset.barlFallbackApplied = '';\n  image.src = window.BARLNumberImage(normalizedNumber, driverId);\n};\ndocument.addEventListener('error', function (event) {\n  const image = event.target;\n  if (!(image instanceof HTMLImageElement) || !image.dataset.barlNumber || image.dataset.barlFallbackApplied) return;\n  const fallback = window.BARL_NUMBER_IMAGES[image.dataset.barlNumber] || '';\n  if (fallback && image.src !== new URL(fallback, document.baseURI).href) {
    image.dataset.barlFallbackApplied = 'true';\n    image.src = fallback;\n  }\n}, true);\n`);
  const total = Object.values(catalog).reduce((sum, styles) => sum + styles.length, 0);
  process.stdout.write(`Wrote ${total} readable transparent number styles across ${Object.keys(catalog).length} cars.\n`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
