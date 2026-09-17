import fs from 'node:fs/promises';
import path from 'node:path';
import zlib from 'node:zlib';
import { NUMBER_STYLES } from '../data/driver-number-styles.js';

const ROOT = path.resolve(import.meta.dirname, '..');
const APPROVED_NUMBERS = ['1', '2', '5', '6', '7', '9', '11', '12', '17', '19', '20', '22', '23', '24', '35', '42', '43', '45', '48', '54', '60', '71', '77', '84', '88', '97'];

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
  if (width !== 512 || height !== 512) throw new Error(`${label}: expected 512x512, received ${width}x${height}`);
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

process.stdout.write(`Number-art check passed: ${styleCount} approved transparent PNGs across ${APPROVED_NUMBERS.length} cars; all site references are vetted.\n`);
