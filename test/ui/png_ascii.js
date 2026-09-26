// Minimal PNG decoder -> ASCII luminance map (for golden inspection).
// Usage: node png_ascii.js <file.png> [cols]
const fs = require('fs');
const zlib = require('zlib');

const file = process.argv[2];
const cols = parseInt(process.argv[3] || '72', 10);
const buf = fs.readFileSync(file);

// --- parse chunks ---
let pos = 8; // skip signature
let width = 0, height = 0, bitDepth = 0, colorType = 0;
const idat = [];
while (pos < buf.length) {
  const len = buf.readUInt32BE(pos);
  const type = buf.toString('ascii', pos + 4, pos + 8);
  const data = buf.subarray(pos + 8, pos + 8 + len);
  if (type === 'IHDR') {
    width = data.readUInt32BE(0);
    height = data.readUInt32BE(4);
    bitDepth = data[8];
    colorType = data[9];
  } else if (type === 'IDAT') {
    idat.push(data);
  } else if (type === 'IEND') break;
  pos += 12 + len;
}
if (bitDepth !== 8) { console.error('unsupported bitDepth', bitDepth); process.exit(1); }
const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
if (!channels) { console.error('unsupported colorType', colorType); process.exit(1); }

const raw = zlib.inflateSync(Buffer.concat(idat));
const stride = width * channels;
// un-filter
const pixels = Buffer.alloc(height * stride);
const bpp = channels;
for (let y = 0; y < height; y++) {
  const f = raw[y * (stride + 1)];
  const rowStart = y * (stride + 1) + 1;
  const src = raw.subarray(rowStart, rowStart + stride);
  const dstOff = y * stride;
  const left = (x) => (x >= bpp ? pixels[dstOff + x - bpp] : 0);
  const up = (x) => (y > 0 ? pixels[dstOff - stride + x] : 0);
  const ul = (x) => (y > 0 && x >= bpp ? pixels[dstOff - stride + x - bpp] : 0);
  for (let x = 0; x < stride; x++) {
    const v = src[x];
    let out = v;
    if (f === 1) out = (v + left(x)) & 0xff;
    else if (f === 2) out = (v + up(x)) & 0xff;
    else if (f === 3) out = (v + ((left(x) + up(x)) >> 1)) & 0xff;
    else if (f === 4) {
      const p = left(x) + up(x) - ul(x);
      const pa = Math.abs(p - left(x)), pb = Math.abs(p - up(x)), pc = Math.abs(p - ul(x));
      const pr = (pa <= pb && pa <= pc) ? left(x) : (pb <= pc ? up(x) : ul(x));
      out = (v + pr) & 0xff;
    }
    pixels[dstOff + x] = out;
  }
}
console.error(`${file}: ${width}x${height} ct=${colorType} ch=${channels}`);

// palette for colorType 3
let palette = null;
{
  let p = 8;
  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString('ascii', p + 4, p + 8);
    if (type === 'PLTE') palette = buf.subarray(p + 8, p + 8 + len);
    p += 12 + len;
  }
}

function px(x, y) {
  const o = y * stride + x * channels;
  if (colorType === 3) { const idx = pixels[o]; return [palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2], 255]; }
  if (channels === 4) return [pixels[o], pixels[o + 1], pixels[o + 2], pixels[o + 3]];
  if (channels === 3) return [pixels[o], pixels[o + 1], pixels[o + 2], 255];
  if (channels === 2) return [pixels[o], pixels[o], pixels[o], pixels[o + 1]];
  return [pixels[o], pixels[o], pixels[o], 255];
}

// ASCII luminance map: rows scaled to keep aspect (each cell ~ 2:1)
const cellW = Math.floor(width / cols);
const cellH = cellW * 2;
const rows = Math.floor(height / cellH);
const chars = ' .:-=+*#%@'; // dark -> dense
let out = '';
for (let r = 0; r < rows; r++) {
  for (let c = 0; c < cols; c++) {
    // min luminance over cell (text strokes) + mean
    let minL = 255, sumL = 0, n = 0;
    for (let y = r * cellH; y < (r + 1) * cellH; y += 2) {
      for (let x = c * cellW; x < (c + 1) * cellW; x += 2) {
        const [R, G, B] = px(x, y);
        const L = (R * 299 + G * 587 + B * 114) / 1000;
        if (L < minL) minL = L;
        sumL += L; n++;
      }
    }
    const meanL = sumL / n;
    // use contrast: dark strokes on light bg -> show as dense
    const v = Math.min(minL + (meanL - minL) * 0.3, 255);
    const idx = Math.min(chars.length - 1, Math.floor((255 - v) / (256 / chars.length)));
    out += chars[idx];
  }
  out += '\n';
}
process.stdout.write(out);
