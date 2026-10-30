import fs from 'node:fs/promises';
import path from 'node:path';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { NUMBER_STYLES } from '../data/driver-number-styles.js';

const ROOT = path.resolve(import.meta.dirname, '..');
const APPROVED_NUMBERS = ['1', '2', '3', '5', '6', '7', '9', '11', '12', '14', '17', '19', '20', '22', '23', '24', '35', '42', '43', '45', '48', '54', '60', '66', '71', '77', '84', '88', '93', '94', '97'];

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : (pb <= pc ? b : c);
}

function decodeRgbaPng(buffer, label) {
  if (buffer.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') throw new Error(`${label}: invalid PNG signature`);
  let offset = 8;
  let width;
  let height;
  let bitDepth;
  let colorType;
  let interlace;
  const compressed = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.subarray(offset + 4, offset + 8).toString('ascii');
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === 'IDAT') compressed.push(data);
    else if (type === 'IEND') break;
    offset += length + 12;
  }
  if (width !== 640 || height !== 384) throw new Error(`${label}: expected 640x384, received ${width}x${height}`);
  if (bitDepth !== 8 || colorType !== 6 || interlace !== 0) throw new Error(`${label}: expected non-interlaced 8-bit RGBA PNG`);

  const raw = zlib.inflateSync(Buffer.concat(compressed));
  const bytesPerPixel = 4;
  const stride = width * bytesPerPixel;
  const pixels = Buffer.alloc(stride * height);
  let sourceOffset = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = raw[sourceOffset];
    sourceOffset += 1;
    for (let x = 0; x < stride; x += 1) {
      const value = raw[sourceOffset + x];
      const left = x >= bytesPerPixel ? pixels[y * stride + x - bytesPerPixel] : 0;
      const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
      const upperLeft = y > 0 && x >= bytesPerPixel ? pixels[(y - 1) * stride + x - bytesPerPixel] : 0;
      const decoded = filter === 0 ? value
        : filter === 1 ? value + left
          : filter === 2 ? value + up
            : filter === 3 ? value + Math.floor((left + up) / 2)
              : filter === 4 ? value + paeth(left, up, upperLeft)
                : NaN;
      if (Number.isNaN(decoded)) throw new Error(`${label}: unsupported PNG filter ${filter}`);
      pixels[y * stride + x] = decoded & 255;
    }
    sourceOffset += stride;
  }
  return { width, height, pixels };
}

function assertTransparentBorder(image, label) {
  const { width, height, pixels } = image;
  const alphaAt = (x, y) => pixels[(y * width + x) * 4 + 3];
  for (let x = 0; x < width; x += 1) {
    if (alphaAt(x, 0) > 0 || alphaAt(x, height - 1) > 0) throw new Error(`${label}: artwork touches the top or bottom edge`);
  }
  for (let y = 0; y < height; y += 1) {
    if (alphaAt(0, y) > 0 || alphaAt(width - 1, y) > 0) throw new Error(`${label}: artwork touches the left or right edge`);
  }
}

function assertUniformNumberSize(image, label) {
  const { width, height, pixels } = image;
  let left = width;
  let right = 0;
  let top = height;
  let bottom = 0;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (pixels[(y * width + x) * 4 + 3] < 128) continue;
      left = Math.min(left, x);
      right = Math.max(right, x);
      top = Math.min(top, y);
      bottom = Math.max(bottom, y);
    }
  }
  assert.equal(bottom - top + 1, 288, `${label}: visible number height must match every other style`);
  assert.equal(top, 48, `${label}: number must share the common top and baseline`);
  assert.ok(Math.abs((left + right) / 2 - 319.5) <= .5, `${label}: number must be horizontally centered`);
}

function assertTransparentCounters(image, number, label) {
  // RFK's #6/#60 and Bell's #20 have intentional filled interiors in the
  // source artwork, not background holes. Other vetted counters stay cut out.
  if (['6', '60', '20'].includes(number)) return;
  const expected = [...number].reduce((sum, digit) => sum + (digit === '8' ? 2 : '0469'.includes(digit) ? 1 : 0), 0);
  if (!expected) return;
  const { width, height, pixels } = image;
  const seen = new Uint8Array(width * height);
  const queue = new Uint32Array(width * height);
  let counters = 0;
  for (let start = 0; start < seen.length; start += 1) {
    if (seen[start] || pixels[start * 4 + 3] >= 128) continue;
    let head = 0;
    let tail = 1;
    let touchesEdge = false;
    queue[0] = start;
    seen[start] = 1;
    while (head < tail) {
      const pixel = queue[head++];
      const x = pixel % width;
      const y = Math.floor(pixel / width);
      if (!x || x === width - 1 || !y || y === height - 1) touchesEdge = true;
      const visit = neighbor => {
        if (seen[neighbor] || pixels[neighbor * 4 + 3] >= 128) return;
        seen[neighbor] = 1;
        queue[tail++] = neighbor;
      };
      if (x > 0) visit(pixel - 1);
      if (x + 1 < width) visit(pixel + 1);
      if (y > 0) visit(pixel - width);
      if (y + 1 < height) visit(pixel + width);
    }
    if (!touchesEdge && tail > 30) counters += 1;
  }
  assert.ok(counters >= expected, `${label}: expected at least ${expected} transparent counters, found ${counters}`);
}

const catalogNumbers = Object.keys(NUMBER_STYLES).sort((a, b) => Number(a) - Number(b));
if (catalogNumbers.join(',') !== APPROVED_NUMBERS.join(',')) {
  throw new Error(`Approved catalog mismatch: ${catalogNumbers.join(', ')}`);
}

const approvedPaths = new Set();
let styleCount = 0;
for (const number of APPROVED_NUMBERS) {
  const styles = NUMBER_STYLES[number];
  if (!styles?.length) throw new Error(`#${number}: no approved styles`);
  const keys = new Set();
  for (const style of styles) {
    if (keys.has(style.key)) throw new Error(`#${number}: duplicate style key ${style.key}`);
    keys.add(style.key);
    if (!style.key.startsWith(`${number}:`)) throw new Error(`#${number}: mismatched style key ${style.key}`);
    if (!style.image.startsWith(`assets/driver-numbers/${number}/`)) throw new Error(`#${number}: misplaced image ${style.image}`);
    const absolutePath = path.join(ROOT, style.image);
    const png = decodeRgbaPng(await fs.readFile(absolutePath), style.image);
    assertTransparentBorder(png, style.image);
    assertUniformNumberSize(png, style.image);
    assertTransparentCounters(png, number, style.image);
    // Sample the actual interiors, not the white outer outlines. These source
    // landmarks catch accidental hole-punching without depending on the builder.
    const whiteInteriors = {
      '6:solomon-plumbing': [[295, 245]],
      '60:coca-cola': [[210, 237], [412, 191]],
      '20:mobil-1': [[406, 194]],
    }[style.key] || [];
    for (const [x, y] of whiteInteriors) {
      const rgba = png.pixels.subarray((y * png.width + x) * 4, (y * png.width + x) * 4 + 4);
      assert.ok(rgba[3] === 255 && rgba[0] >= 240 && rgba[1] >= 240 && rgba[2] >= 240, `${style.key}: original white interior must remain opaque white`);
    }
    if (style.key === '20:mobil-1') {
      assert.equal(png.pixels[(227 * png.width + 295) * 4 + 3], 0, '#20: background gap between digits must remain transparent');
    }
    if (style.key === '93:caleb-costner-piedmont-realtree') {
      assert.equal(png.pixels[(190 * png.width + 350) * 4 + 3], 0, '#93: source-card background between digits must remain transparent');
    }
    approvedPaths.add(style.image);
    styleCount += 1;
  }
}

const sourceFiles = (await fs.readdir(ROOT)).filter(file => file.endsWith('.html'));
sourceFiles.push('scripts/number-style-defaults.js');
for (const sourceFile of sourceFiles) {
  const source = await fs.readFile(path.join(ROOT, sourceFile), 'utf8');
  const references = source.match(/assets\/driver-numbers\/[a-z0-9/.-]+\.png/g) || [];
  for (const reference of references) {
    if (!approvedPaths.has(reference)) throw new Error(`${sourceFile}: unapproved number artwork reference ${reference}`);
  }
}

const assetRoot = path.join(ROOT, 'assets', 'driver-numbers');
const diskPaths = [];
for (const number of await fs.readdir(assetRoot)) {
  const directory = path.join(assetRoot, number);
  if (!(await fs.stat(directory)).isDirectory()) continue;
  for (const file of await fs.readdir(directory)) {
    if (file.endsWith('.png')) diskPaths.push(path.posix.join('assets/driver-numbers', number, file));
    if (file.endsWith('.svg')) throw new Error(`Legacy SVG remains in number-art library: ${path.posix.join(number, file)}`);
  }
}
for (const diskPath of diskPaths) {
  if (!approvedPaths.has(diskPath)) throw new Error(`Uncatalogued number artwork remains on disk: ${diskPath}`);
}

// Old saved black styles must render a bright replacement immediately, not a
// missing image or an invisible numeral. Readable personal choices stay intact.
const context = vm.createContext({ window: {}, document: { addEventListener() {} } });
vm.runInContext(await fs.readFile(path.join(ROOT, 'scripts/number-style-defaults.js'), 'utf8'), context);
const numbers = context.window;
numbers.BARLSetNumberStyles([
  { driver_id: 'max', car_number: '23', style_key: '23:robinhood' },
  { driver_id: 'two', car_number: '2', style_key: '2:menards-black' },
  { driver_id: 'twelve', car_number: '12', style_key: '12:menards-black' },
  { driver_id: 'nolan', car_number: '88', style_key: '88:wendy-s' },
  { driver_id: '4a926a39-ea23-47c0-a493-f070567dfa6a', car_number: '88', style_key: '88:hendrick-red' },
  { driver_id: 'wrong-car', car_number: '23', style_key: '88:wendy-s' },
]);
assert.equal(numbers.BARLNumberImage('23', 'max'), 'assets/driver-numbers/23/shadyrays.png');
assert.equal(numbers.BARLNumberImage('2', 'two'), 'assets/driver-numbers/2/ppg-paints.png');
assert.equal(numbers.BARLNumberImage('12', 'twelve'), 'assets/driver-numbers/12/dent-wizard.png');
assert.equal(numbers.BARLNumberImage('60'), 'assets/driver-numbers/60/ryan-preece-chrome.png');
assert.equal(numbers.BARLNumberImage('88', 'nolan'), 'assets/driver-numbers/88/wendy-s.png');
assert.equal(numbers.BARLNumberImage('88', '4a926a39-ea23-47c0-a493-f070567dfa6a'), 'assets/driver-numbers/88/hendrick-red.png');
assert.equal(numbers.BARLNumberImage('23', 'wrong-car'), 'assets/driver-numbers/23/shadyrays.png');
for (const [number, styles] of Object.entries(NUMBER_STYLES)) {
  assert.equal(numbers.BARLNumberImage(number), styles[0].image, `Default differs between public pages and the driver portal for #${number}`);
}
vm.runInContext(await fs.readFile(path.join(ROOT, 'data/car-art.js'), 'utf8'), context);
vm.runInContext(await fs.readFile(path.join(ROOT, 'scripts/profile-car-card.js'), 'utf8'), context);
const maxHistoricalCard = numbers.BARLCarCards.render({ driverId: 'max', name: 'Max Hunter', number: '23', season: 1 });
assert.ok(maxHistoricalCard.includes('src="assets/driver-numbers/23/shadyrays.png"'));
assert.ok(maxHistoricalCard.includes('src="assets/trucks/23.webp"'), 'Historical #23 must retain its own artwork');
const maxCard = numbers.BARLCarCards.render({ driverId: 'max', name: 'Max Hunter', number: '94', season: 1 });
assert.ok(maxCard.includes('src="assets/driver-numbers/94/max-iracing.png"'), 'An old #23 selection must not leak into Max’s new #94');
assert.ok(maxCard.includes('src="assets/trucks/94.webp"'));
await fs.access(path.join(ROOT, 'assets/trucks/94.webp'));
const nolanCard = numbers.BARLCarCards.render({ driverId: '4a926a39-ea23-47c0-a493-f070567dfa6a', name: 'Nolan McKim', number: '88', season: 1 });
assert.ok(nolanCard.includes('src="assets/driver-numbers/88/hendrick-red.png"'));
assert.ok(nolanCard.includes('src="assets/trucks/88.webp"'));
const brantleyCard = numbers.BARLCarCards.render({ driverId: 'brantley', name: 'Brantley Culp', number: '93', season: 1 });
assert.ok(brantleyCard.includes('src="assets/driver-numbers/93/caleb-costner-piedmont-realtree.png"'));
assert.ok(brantleyCard.includes('src="assets/trucks/93.webp"'), 'Brantley’s #93 badge must accompany the #93 truck');
await fs.access(path.join(ROOT, 'assets/trucks/93.webp'));
const ethanCard = numbers.BARLCarCards.render({ driverId: 'ethan', name: 'Ethan Tillema', number: '14', season: 1 });
assert.ok(ethanCard.includes('src="assets/driver-numbers/14/mini-tyrrell-ram.png"'));
assert.ok(ethanCard.includes('src="assets/trucks/14.webp"'), 'Ethan’s #14 badge must accompany the Ram truck');
await fs.access(path.join(ROOT, 'assets/trucks/14.webp'));
const arthurCard = numbers.BARLCarCards.render({ driverId: 'arthur', name: 'Arthur Walstra', number: '3', season: 1 });
assert.ok(arthurCard.includes('src="assets/driver-numbers/3/arthur-tiger.png"'));
assert.ok(arthurCard.includes('src="assets/trucks/3.webp"'), 'Arthur’s #3 badge must accompany the tiger-stripe truck');
assert.ok(arthurCard.includes('<span>Chevrolet Silverado</span>'), 'Sponsor-free trucks must not show an empty sponsor separator');
assert.ok(!arthurCard.includes('NAPA'), 'Arthur’s sponsor must be removed from labels as well as artwork');
await fs.access(path.join(ROOT, 'assets/trucks/3.webp'));

const loganCard = numbers.BARLCarCards.render({ driverId: 'logan', name: 'Logan Boone', number: '66', season: 1 });
assert.ok(loganCard.includes('src="assets/driver-numbers/66/logan-iracing.png"'));
assert.ok(loganCard.includes('src="assets/trucks/66.webp"'));
assert.ok(loganCard.includes('Chevrolet Silverado / iRacing'));
assert.ok(!loganCard.includes('Toyota'), 'Logan’s card manufacturer must match his Chevrolet truck');
await fs.access(path.join(ROOT, 'assets/trucks/66.webp'));
assert.ok(maxCard.includes('Toyota Tundra / iRacing'), 'Max’s card sponsor must match his iRacing paint scheme');
assert.ok(!maxCard.includes('Hardee'), 'Max’s old sponsor must not remain in the card label');

process.stdout.write(`Number-art check passed: ${styleCount} approved transparent PNGs across ${APPROVED_NUMBERS.length} cars; all site references are vetted.\n`);
process.stdout.write('Uniform sizing verified: every style has 288px visible height, matching baseline, and centered artwork on a 640x384 canvas.\n');
process.stdout.write('Number display verified: retired black selections fall back to bright artwork, readable personal choices are preserved, and driver cards match public number marks.\n');
