#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const sourceDir = process.argv[2] || '/tmp/barl-track-svgs';
const selectedSlug = process.argv[3] || null;
const outputDir = path.resolve('assets/schedule/tracks');

const tracks = [
  { slug: 'daytona', source: 'daytona.svg', id: 'path2463', viewBox: '0 0 1254.986 672.37732', transform: 'translate(-586.22587 -976.27039)', mode: 'fill', colors: ['#dbe9ff', '#556f91'] },
  { slug: 'nashville', source: 'nashville.svg', id: 'path421', viewBox: '0 0 1024 768', mode: 'stroke', colors: ['#fff1a8', '#b56b22'] },
  { slug: 'bristol', source: 'bristol.svg', className: 'cls-1', viewBox: '0 0 3000 2013.2', mode: 'fill', colors: ['#ffcf91', '#a8311d'] },
  { slug: 'watkins-glen', source: 'watkins-glen.svg', className: 'cls-1', viewBox: '0 0 3000 1572.9', mode: 'fill', colors: ['#b9e7ff', '#2476a7'] },
  { slug: 'charlotte', source: 'charlotte.svg', id: 'path19', viewBox: '0 0 1024 768', mode: 'stroke', colors: ['#edf2ff', '#5267a3'] },
  { slug: 'dover', source: 'dover.svg', className: 'cls-1', viewBox: '0 0 3000 1947.2', mode: 'fill', colors: ['#d8dfdc', '#3e6d4b'] },
  { slug: 'iowa', source: 'iowa.svg', className: 'cls-1', viewBox: '0 0 3000 2130.6', mode: 'fill', colors: ['#ffe9a6', '#aa7721'] },
  { slug: 'talladega', source: 'talladega.svg', id: 'path7029', viewBox: '0 0 1338 668.70202', transform: 'translate(-7.2028672 -303.34213) matrix(1.0775928 0 0 1.0775928 -0.55889043 -75.423601)', mode: 'stroke', colors: ['#ffe09c', '#a45224'] },
  { slug: 'chicagoland', source: 'chicagoland.svg', id: 'path5', viewBox: '0 0 1024 768', mode: 'stroke', colors: ['#dce9ff', '#5e6f94'] },
];

function getPathData(svg, track) {
  const paths = [...svg.matchAll(/<path\b([\s\S]*?)\bd="([\s\S]*?)"([\s\S]*?)\/?\s*>/g)].map(match => ({
    attrs: `${match[1]} ${match[3]}`,
    d: match[2].trim(),
  }));
  const match = paths.find(item => track.id
    ? new RegExp(`id="${track.id}"`).test(item.attrs)
    : new RegExp(`class="[^"]*\\b${track.className}\\b`).test(item.attrs));
  if (!match) throw new Error(`Could not find track path for ${track.slug}.`);
  return match.d;
}

function buildSvg(track, d) {
  const [light, dark] = track.colors;
  const transform = track.transform ? ` transform="${track.transform}"` : '';
  const shadowTransform = track.transform
    ? `${track.transform} translate(0 18)`
    : 'translate(0 18)';
  const pathMarkup = track.mode === 'fill'
    ? `
    <path d="${d}" transform="${shadowTransform}" fill="#020307" fill-rule="evenodd" opacity=".9"/>
    <path d="${d}"${transform} fill="url(#track)" fill-rule="evenodd" stroke="rgba(255,255,255,.24)" stroke-width="8"/>
    <path d="${d}"${transform} fill="none" fill-rule="evenodd" stroke="rgba(255,255,255,.38)" stroke-width="3"/>`
    : `
    <path d="${d}" transform="${shadowTransform}" fill="none" stroke="#020307" stroke-width="76" stroke-linecap="round" stroke-linejoin="round" opacity=".92"/>
    <path d="${d}"${transform} fill="none" stroke="url(#track)" stroke-width="60" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="${d}"${transform} fill="none" stroke="rgba(255,255,255,.42)" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${track.viewBox}" role="img" aria-label="Accurate ${track.slug.replace('-', ' ')} track layout">
  <defs>
    <linearGradient id="track" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="${light}"/>
      <stop offset=".46" stop-color="#626873"/>
      <stop offset="1" stop-color="${dark}"/>
    </linearGradient>
    <filter id="glow" x="-30%" y="-30%" width="160%" height="170%">
      <feGaussianBlur stdDeviation="12" result="blur"/>
      <feColorMatrix in="blur" type="matrix" values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 .55 0"/>
    </filter>
  </defs>
  <g opacity=".42" filter="url(#glow)">${pathMarkup}</g>
  <g>${pathMarkup}</g>
</svg>`;
}

const tracksToBuild = selectedSlug ? tracks.filter(track => track.slug === selectedSlug) : tracks;
if (!tracksToBuild.length) throw new Error(`Unknown track slug: ${selectedSlug}`);

fs.mkdirSync(outputDir, { recursive: true });
for (const track of tracksToBuild) {
  const source = fs.readFileSync(path.join(sourceDir, track.source), 'utf8');
  const d = getPathData(source, track);
  fs.writeFileSync(path.join(outputDir, `${track.slug}.svg`), buildSvg(track, d));
}

console.log(`Built ${tracksToBuild.length} reference-derived track assets in ${outputDir}`);
