#!/usr/bin/env node
// ============================================================================
// token_corpus.mjs —— token 算法三重验证之第一重：V8 参考实现语料生成
//
// 依据 DESIGN §6.2 / §11.1：
//   语料由 Node 的 V8 引擎原生 Number.prototype.toString(36) 生成——端点 token
//   算法本身即 JS 语义，V8 就是该算法的参考实现（并非 Dart 同公式自我对照）。
//   Dart 侧 test/core/js_radix36_test.dart 与 test/core/token_test.dart 逐条对照本语料断言。
//
// 输出 CSV 格式（UTF-8，无 BOM，\n 换行）：
//   首行为表头：tweetId,radix36,token
//   tweetId  —— 原始推文 ID 字符串（超 2^53，保留完整十进制，不丢精度）
//   radix36  —— ((Number(tweetId) / 1e15) * Math.PI).toString(36) 的 V8 原生输出
//               （可能含 "." 与 "0"；小数 radix 表示从不用科学计数法）
//   token    —— radix36.replace(/(0+|\.)/g, '') 的最终 token（可能为空串，如 id=0）
//
// 采样策略（DESIGN §11.1）：
//   1) 2010-2026 真实雪花 ID 区间（1e18 ~ 2e18）均匀随机采样（默认 100000 条）；
//   2) 边界向量：0/1/2、2^53±1、全 0/全 9 尾数、1e18/2e18 区间端点、
//      36 进制进位链压力值、(id/1e15)*π 落在整数边界两侧的值、已知向量
//      1790637656616943991 -> 4c9gcitu1vq。
//   随机数用固定种子的确定性 PRNG，语料可复现。
//
// 用法：
//   node tools/token_corpus.mjs [--count=100000] [--seed=42] [--out=test/resources/token_corpus.csv]
// ============================================================================

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const args = process.argv.slice(2);
const argOf = (name, fallback) => {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.split('=').slice(1).join('=') : fallback;
};

const count = Number(argOf('count', '100000'));
const seed = Number(argOf('seed', '42'));
const outPath = resolve(argOf('out', 'test/resources/token_corpus.csv'));

// ---- token 算法（与官方嵌入组件及 yt-dlp _generate_syndication_token 逐字一致）----
function syndicationToken(idStr) {
  const radix36 = ((Number(idStr) / 1e15) * Math.PI).toString(36);
  const token = radix36.replace(/(0+|\.)/g, '');
  return { radix36, token };
}

// ---- 确定性 PRNG（mulberry32）：语料可复现，重跑同种子结果一致 ----
function mulberry32(a) {
  return function () {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---- 边界向量构造 ----
// 重要：超 2^53 的整数绝不能用 Number 字面量传入（会被 IEEE754 舍入失真，
// 如 1790637656616943991 会变成 1790637656616944000）——一律用字符串或
// BigInt 精确构造，保证 CSV 中的 tweetId 逐位正确。
function boundaryIds() {
  const ids = new Set();
  const add = (n) => ids.add(String(n)); // n: string | bigint | number(仅小值)

  // 基础边界
  add(0n); add(1n); add(2n); add(3n);
  // 2^53 ± 邻域（IEEE754 双精度整数边界，Number() 舍入压力点）
  add((1n << 53n) - 2n);
  add((1n << 53n) - 1n); // 9007199254740991（2^53-1，精确）
  add(1n << 53n);        // 9007199254740992（2^53，精确）
  add((1n << 53n) + 1n); // 9007199254740993（舍入为 2^53）
  add((1n << 53n) + 2n);
  add((1n << 53n) + 3n);
  // 采样区间端点
  add(10n ** 18n);        // 1e18
  add(2n * 10n ** 18n);   // 2e18
  // 全 0 / 全 9 尾数（字符串->double 舍入 + radix36 尾链压力）
  add(1500000000000000000n);
  add(1999999999999999999n);
  add(10n ** 18n + 1n);
  add(2n * 10n ** 18n + 1n);
  add(1777777777777777777n);
  // 已知向量（DESIGN §6.2 评委复现值）——必须字符串化，见函数头注释
  add('1790637656616943991'); // -> 4c9gcitu1vq

  // (id/1e15)*π 落在整数边界两侧：id ≈ n*1e15/π，取 n=3..6 与 1800..1803，
  // 各取 Math.round 及 ±1、±2 邻域（BigInt 保证十进制逐位精确，经 Number()
  // 舍入后覆盖整数两侧最近可表示值）
  for (const n of [3, 4, 5, 6, 1800, 1801, 1802, 1803]) {
    const center = BigInt(Math.round((n * 1e15) / Math.PI));
    for (const d of [-2n, -1n, 0n, 1n, 2n]) add(center + d);
  }

  // 36 进制进位链压力：尾数构造使 radix36 小数部分出现长 0 串 / 进位传播。
  // 枚举 1e18 附近 (id/1e15)*π 的小数部分最接近 0/1 的若干值。
  // 注意：必须用偏移量 d 驱动循环——1e18 尺度下 double ULP=128，直接 id++ 会
  // 舍入回原值造成死循环（已踩坑）。id 塌缩为可表示 double 由 Set 去重兜住。
  const nearZero = [];
  for (let d = 0; d < 1000; d++) {
    const id = (10n ** 18n + BigInt(d)).toString();
    const v = (Number(id) / 1e15) * Math.PI;
    const frac = v - Math.floor(v);
    nearZero.push([id, Math.min(frac, 1 - frac)]);
  }
  nearZero.sort((a, b) => a[1] - b[1]);
  for (const [id] of nearZero.slice(0, 16)) add(id);

  // 2 的幂压力（二进制尾数全 0，radix36 转换进位链）
  for (let k = 50; k <= 60; k++) {
    const p = 2n ** BigInt(k);
    if (p >= 10n ** 18n) { add(p - 1n); add(p); add(p + 1n); }
  }
  return ids;
}

// ---- 生成 ----
const rand = mulberry32(seed);
// 雪花 ID 区间 [1e18, 2e18)：逐位十进制随机生成 19 位数字串。
// 不用 rand()*1e18 映射——该尺度下 double ULP=128，会退化为 256 对齐的
// 尾数模式；逐位构造保证字符串->double 舍入路径（进位/舍位双向）被充分覆盖。
const randomId = () => {
  let s = '1';
  for (let i = 0; i < 18; i++) s += Math.floor(rand() * 10);
  return s;
};
const seen = boundaryIds();
const boundaries = [...seen].sort((a, b) => (a.length - b.length) || (a < b ? -1 : 1));
let generated = 0;
while (generated < count) {
  const s = randomId();
  if (seen.has(s)) continue; // 去重（碰撞概率极低，防御即可）
  seen.add(s);
  generated++;
}
const randomIds = [...seen].filter((s) => !boundaries.includes(s));

const lines = ['tweetId,radix36,token'];
for (const id of [...boundaries, ...randomIds]) {
  const { radix36, token } = syndicationToken(id);
  lines.push(`${id},${radix36},${token}`);
}

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, lines.join('\n') + '\n', 'utf8');

const known = syndicationToken('1790637656616943991');
const knownOk = known.token === '4c9gcitu1vq';
console.log(`[token_corpus] 语料已生成: ${outPath}`);
console.log(`[token_corpus] 随机采样 ${randomIds.length} 条 + 边界向量 ${boundaries.length} 条 = 共 ${lines.length - 1} 行（seed=${seed}）`);
console.log(`[token_corpus] 已知向量自检 1790637656616943991 -> ${known.token} ${knownOk ? 'OK' : 'MISMATCH!'}`);
if (!knownOk) {
  process.exitCode = 1;
}
