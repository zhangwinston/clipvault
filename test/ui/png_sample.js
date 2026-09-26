// PNG pixel sampler: node png_sample.js <file> <x,y> [<x,y>...]  (physical px)
// Also: --row <y> prints run-length color segments for that row.
const fs = require('fs');
const zlib = require('zlib');

const args = process.argv.slice(2);
const file = args[0];
const buf = fs.readFileSync(file);

let pos = 8, width = 0, height = 0, colorType = 0;
const idat = [];
while (pos < buf.length) {
  const len = buf.readUInt32BE(pos);
  const type = buf.toString('ascii', pos + 4, pos + 8);
  const data = buf.subarray(pos + 8, pos + 8 + len);
  if (type === 'IHDR') { width = data.readUInt32BE(0); height = data.readUInt32BE(4); colorType = data[9]; }
  else if (type === 'IDAT') idat.push(data);
  else if (type === 'IEND') break;
  pos += 12 + len;
}
const channels = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 }[colorType];
const raw = zlib.inflateSync(Buffer.concat(idat));
const stride = width * channels;
const pixels = Buffer.alloc(height * stride);
const bpp = channels;
for (let y = 0; y < height; y++) {
  const f = raw[y * (stride + 1)];
  const off = y * (stride + 1) + 1;
  const L = (x) => (x >= bpp ? pixels[y * stride + x - bpp] : 0);
  const U = (x) => (y > 0 ? pixels[(y - 1) * stride + x] : 0);
  const UL = (x) => (y > 0 && x >= bpp ? pixels[(y - 1) * stride + x - bpp] : 0);
  for (let x = 0; x < stride; x++) {
    const v = raw[off + x];
    let o = v;
    if (f === 1) o = (v + L(x)) & 0xff;
    else if (f === 2) o = (v + U(x)) & 0xff;
    else if (f === 3) o = (v + ((L(x) + U(x)) >> 1)) & 0xff;
    else if (f === 4) {
      const p = L(x) + U(x) - UL(x);
      const pa = Math.abs(p - L(x)), pb = Math.abs(p - U(x)), pc = Math.abs(p - UL(x));
      o = (v + (pa <= pb && pa <= pc ? L(x) : pb <= pc ? U(x) : UL(x))) & 0xff;
    }
    pixels[y * stride + x] = o;
  }
}
function px(x, y) {
  const o = y * stride + x * channels;
  return colorType === 6 ? [pixels[o], pixels[o + 1], pixels[o + 2]] : [pixels[o], pixels[o], pixels[o]];
}
const hex = (p) => '#' + p.map((v) => v.toString(16).padStart(2, '0')).join('').toUpperCase();

const rowIdx = args.indexOf('--row');
if (rowIdx >= 0) {
  const y = parseInt(args[rowIdx + 1], 10);
  let segs = [], start = 0, cur = hex(px(0, y));
  for (let x = 1; x < width; x++) {
    const h = hex(px(x, y));
    if (h !== cur) { segs.push([start, x - 1, cur]); start = x; cur = h; }
  }
  segs.push([start, width - 1, cur]);
  // merge tiny segments into readable run-length summary
  const merged = [];
  for (const s of segs) {
    const last = merged[merged.length - 1];
    if (last && last[2] === s[2]) last[1] = s[1];
    else merged.push([...s]);
  }
  const out = merged.filter((s) => s[1] - s[0] >= 3).map((s) => `${s[0]}-${s[1]}:${s[2]}`).join('  ');
  console.log(`row y=${y}: ` + (out.length < 3000 ? out : out.slice(0, 3000) + '...'));
} else {
  for (const pt of args.slice(1)) {
    const [x, y] = pt.split(',').map(Number);
    console.log(`(${x},${y}) = ${hex(px(x, y))}`);
  }
}
