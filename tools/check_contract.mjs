#!/usr/bin/env node
// ============================================================================
// check_contract.mjs —— fixtures ↔ contracts/resolve.schema.json 契约校验
// （DESIGN §11.3：与 Dart 侧 test/parse/contract_test.dart 双向防漂移）
//
// 做三件事：
//   1. 用 schema 驱动的小型校验器（无第三方依赖，不 npm install）验证
//      "原始夹具 → ResolveResult" 的 JS 侧映射结果符合 contracts/resolve.schema.json；
//   2. 程序化断言 schema 无法表达的契约：variants 仅 mp4、bitrate>0、按 bitrate 降序、
//      estBytes = bitrate × duration_millis / 8、videoCount 一致性；
//   3. 断言错误夹具的分类符合 contracts/error_codes.md 的对照表：
//      photo_only→E05、404 dogpage→E04、空{}→E04、sensitive→E06。
//
// JS 侧映射是 Dart TweetParser 契约的镜像实现（仅用于对账，不进 App）。
// 用法：node tools/check_contract.mjs   （退出码 0=全部通过，1=存在违约）
// ============================================================================

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = (...p) => resolve(process.cwd(), ...p);
const schema = JSON.parse(readFileSync(root('contracts/resolve.schema.json'), 'utf8'));

// ---------------------------------------------------------------------------
// 最小 JSON Schema 校验器（支持本仓库 schema 用到的关键字子集：
// type / enum / required / properties / additionalProperties / pattern /
// format(date-time,uri) / minimum / exclusiveMinimum / minItems / items / $ref）
// ---------------------------------------------------------------------------
function deref(node) {
  if (node && typeof node.$ref === 'string' && node.$ref.startsWith('#/')) {
    let cur = schema;
    for (const seg of node.$ref.slice(2).split('/')) cur = cur[seg];
    return cur;
  }
  return node;
}

function validate(node, inst, path) {
  const errors = [];
  const s = deref(node);
  if (s === false) return [`${path}: schema 不允许该值`];

  if (s.type) {
    const types = Array.isArray(s.type) ? s.type : [s.type];
    const ok = types.some((t) => {
      switch (t) {
        case 'object': return typeof inst === 'object' && inst !== null && !Array.isArray(inst);
        case 'array': return Array.isArray(inst);
        case 'string': return typeof inst === 'string';
        case 'integer': return typeof inst === 'number' && Number.isInteger(inst);
        case 'number': return typeof inst === 'number';
        case 'boolean': return typeof inst === 'boolean';
        case 'null': return inst === null;
        default: return false;
      }
    });
    if (!ok) errors.push(`${path}: 期望 type=${types.join('|')}，实得 ${JSON.stringify(inst)?.slice(0, 60)}`);
    if (errors.length) return errors; // 类型不符则后续关键字无意义
  }
  if (s.enum !== undefined && !s.enum.includes(inst)) {
    errors.push(`${path}: 不在 enum ${JSON.stringify(s.enum)} 中（实得 ${JSON.stringify(inst)}）`);
  }
  if (s.pattern !== undefined && typeof inst === 'string' && !new RegExp(s.pattern).test(inst)) {
    errors.push(`${path}: 不匹配 pattern ${s.pattern}`);
  }
  if (typeof inst === 'string') {
    if (s.format === 'uri' && !/^https?:\/\/[^\s]+$/.test(inst)) errors.push(`${path}: 非法 URI`);
    if (s.format === 'date-time' && !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$/.test(inst)) {
      errors.push(`${path}: 非法 date-time`);
    }
  }
  if (typeof inst === 'number') {
    if (s.minimum !== undefined && inst < s.minimum) errors.push(`${path}: ${inst} < minimum ${s.minimum}`);
    if (s.exclusiveMinimum !== undefined && inst <= s.exclusiveMinimum) errors.push(`${path}: ${inst} <= exclusiveMinimum ${s.exclusiveMinimum}`);
  }
  if (Array.isArray(inst)) {
    if (s.minItems !== undefined && inst.length < s.minItems) errors.push(`${path}: 元素数 ${inst.length} < minItems ${s.minItems}`);
    if (s.items !== undefined) inst.forEach((v, i) => errors.push(...validate(s.items, v, `${path}[${i}]`)));
  }
  if (typeof inst === 'object' && inst !== null && !Array.isArray(inst)) {
    for (const key of s.required ?? []) {
      if (!(key in inst)) errors.push(`${path}: 缺少必填字段 ${key}`);
    }
    if (s.properties) {
      for (const [k, sub] of Object.entries(s.properties)) {
        if (k in inst) errors.push(...validate(sub, inst[k], `${path}.${k}`));
      }
      if (s.additionalProperties === false) {
        for (const k of Object.keys(inst)) {
          if (!(k in s.properties)) errors.push(`${path}.${k}: schema 未定义（additionalProperties:false）`);
        }
      }
    }
  }
  return errors;
}

// ---------------------------------------------------------------------------
// JS 侧解析映射（Dart TweetParser 契约的镜像，仅覆盖契约相关字段）
// ---------------------------------------------------------------------------
const QUALITY_BY_HEIGHT = (h) =>
  h >= 1080 ? '1080p (Full HD)' : h >= 720 ? '720p (HD)' : h >= 480 ? '480p (SD)' : '360p';
// 分辨率缺失时的码率兜底映射（DESIGN §4.2/§5.1）
const QUALITY_BY_BITRATE = (b) =>
  b >= 3000000 ? '1080p (Full HD)' : b >= 1200000 ? '720p (HD)' : b >= 600000 ? '480p (SD)' : '360p';

class ContractError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

function variantFrom(url, bitrate, durationMillis) {
  const m = /\/vid\/[^/]*\/(\d+)x(\d+)\//.exec(url);
  const width = m ? Number(m[1]) : null;
  const height = m ? Number(m[2]) : null;
  return {
    contentType: 'mp4',
    bitrate,
    url,
    width,
    height,
    estimatedBytes: Math.round((bitrate * durationMillis) / 8),
    qualityLabel: height !== null ? QUALITY_BY_HEIGHT(height) : QUALITY_BY_BITRATE(bitrate),
  };
}

function sortVariants(vs) {
  return vs.sort((a, b) => b.bitrate - a.bitrate);
}

// syndication 原始响应 → ResolveResult（镜像 SyndicationParser 契约）
function parseSyndication(raw) {
  if (raw.trim() === '{}' || raw.trim() === '') throw new ContractError('E04');
  let j;
  try { j = JSON.parse(raw); } catch { throw new ContractError('E04'); } // dogpage HTML 等
  if (j.__typename !== 'Tweet') throw new ContractError('E07');
  if (!j.user?.screen_name) throw new ContractError('E07');
  const details = Array.isArray(j.mediaDetails) ? j.mediaDetails : [];
  const videoEntries = details.filter((m) => m?.type === 'video' || m?.type === 'animated_gif');
  if (j.possibly_sensitive === true) throw new ContractError('E06');
  if (videoEntries.length === 0) throw new ContractError('E05');

  const selected = videoEntries[0]; // 多视频默认选中第 1 个（UI Chip 可切换）
  const durationMillis = selected.video_info?.duration_millis ?? 0;
  const variants = (selected.video_info?.variants ?? [])
    .filter((v) => v.content_type === 'video/mp4' && typeof v.bitrate === 'number' && v.bitrate > 0)
    .map((v) => variantFrom(v.url, v.bitrate, durationMillis));
  if (variants.length === 0) throw new ContractError('E05');
  return {
    tweet: {
      tweetId: j.id_str,
      userName: j.user.name ?? '',
      screenName: j.user.screen_name,
      avatarUrl: j.user.profile_image_url_https ?? '',
      text: j.text ?? '',
      createdAt: j.created_at,
      thumbnailUrl: selected.media_url_https ?? '',
      durationMillis,
      possiblySensitive: j.possibly_sensitive === true,
      videoCount: videoEntries.length,
      variants: sortVariants(variants),
    },
    parserVersion: 'syndication-v1',
  };
}

// fxtwitter 原始响应 → ResolveResult（镜像 FxTwitterParser 防御性契约，§6.4）
function parseFxTwitter(raw) {
  let j;
  try { j = JSON.parse(raw); } catch { throw new ContractError('E04'); }
  if (j.code !== 200 || !j.tweet) throw new ContractError('E04');
  const t = j.tweet;
  const video = t.media?.videos?.[0];
  if (!video) throw new ContractError('E05');
  // 防御性双形态：formats[] 多码率优先，退化到 variants[]，再退化到单 url 直链
  let rawVariants;
  if (Array.isArray(video.formats) && video.formats.some((f) => f.container === 'mp4' && f.bitrate > 0)) {
    rawVariants = video.formats.filter((f) => f.container === 'mp4' && f.bitrate > 0).map((f) => ({ url: f.url, bitrate: f.bitrate }));
  } else if (Array.isArray(video.variants) && video.variants.some((v) => v.content_type === 'video/mp4' && v.bitrate > 0)) {
    rawVariants = video.variants.filter((v) => v.content_type === 'video/mp4' && v.bitrate > 0).map((v) => ({ url: v.url, bitrate: v.bitrate }));
  } else if (video.url) {
    rawVariants = [{ url: video.url, bitrate: video.bitrate ?? 0 }];
    if (rawVariants[0].bitrate <= 0) rawVariants[0].bitrate = 1; // 单直链无码率：占位避免 bitrate>0 过滤全灭
  }
  if (!rawVariants?.length) throw new ContractError('E05');
  const durationMillis = Math.round((video.duration ?? 0) * 1000);
  return {
    tweet: {
      tweetId: String(t.id),
      userName: t.author?.name ?? '',
      screenName: t.author?.screen_name ?? '',
      avatarUrl: t.author?.avatar_url ?? '',
      text: t.text ?? '',
      createdAt: new Date(t.created_at ?? 0).toISOString(),
      thumbnailUrl: video.thumbnail_url ?? '',
      durationMillis,
      possiblySensitive: t.possibly_sensitive === true,
      videoCount: t.media?.videos?.length ?? 1,
      variants: sortVariants(rawVariants.map((v) => variantFrom(v.url, v.bitrate, durationMillis))),
    },
    parserVersion: 'fxtwitter-v1',
  };
}

// ---------------------------------------------------------------------------
// 契约断言（schema 表达不了的部分）
// ---------------------------------------------------------------------------
function assertContractExtras(rr, label, errors) {
  const { variants } = rr.tweet;
  for (let i = 0; i < variants.length; i++) {
    const v = variants[i];
    if (v.contentType !== 'mp4') errors.push(`${label}: variants[${i}].contentType=${v.contentType}（仅允许 mp4）`);
    if (v.bitrate <= 0) errors.push(`${label}: variants[${i}].bitrate=${v.bitrate}（必须 >0）`);
    if (i > 0 && variants[i - 1].bitrate < v.bitrate) errors.push(`${label}: variants 未按 bitrate 降序（[${i - 1}]=${variants[i - 1].bitrate} < [${i}]=${v.bitrate}）`);
    const expectBytes = Math.round((v.bitrate * rr.tweet.durationMillis) / 8);
    if (v.estimatedBytes !== expectBytes) errors.push(`${label}: variants[${i}].estimatedBytes=${v.estimatedBytes}，契约值=${expectBytes}`);
  }
  if (rr.tweet.videoCount < 1) errors.push(`${label}: videoCount=${rr.tweet.videoCount}（>=1）`);
}

// ---------------------------------------------------------------------------
// 主流程：七夹具逐一对账
// ---------------------------------------------------------------------------
const FIXTURES = [
  { file: 'assets/fixtures/syndication_video_ok.json', parser: parseSyndication, expect: 'ok' },
  { file: 'assets/fixtures/syndication_multi_video.json', parser: parseSyndication, expect: 'ok' },
  { file: 'assets/fixtures/syndication_photo_only.json', parser: parseSyndication, expect: 'E05' },
  { file: 'assets/fixtures/syndication_404_dogpage.html', parser: parseSyndication, expect: 'E04' },
  { file: 'assets/fixtures/syndication_empty.json', parser: parseSyndication, expect: 'E04' },
  { file: 'assets/fixtures/syndication_sensitive.json', parser: parseSyndication, expect: 'E06' },
  { file: 'assets/fixtures/fxtwitter_status_ok.json', parser: parseFxTwitter, expect: 'ok' },
];

let failed = 0;
for (const f of FIXTURES) {
  const raw = readFileSync(root(f.file), 'utf8');
  const label = f.file.split('/').pop();
  const errors = [];
  let rr = null;
  try {
    rr = f.parser(raw);
  } catch (e) {
    if (e instanceof ContractError) {
      if (f.expect === e.code) {
        console.log(`PASS  ${label} -> ${e.code}（按 contracts/error_codes.md 分类正确）`);
      } else {
        console.log(`FAIL  ${label} -> ${e.code}，期望 ${f.expect}`);
        failed++;
      }
      continue;
    }
    throw e;
  }
  if (f.expect !== 'ok') {
    console.log(`FAIL  ${label} -> 解析成功，但期望错误 ${f.expect}`);
    failed++;
    continue;
  }
  errors.push(...validate(schema, rr, '$'));
  assertContractExtras(rr, label, errors);
  if (errors.length === 0) {
    const desc = `${rr.tweet.screenName} / ${rr.tweet.variants.length} 个 mp4 档（顶档 ${rr.tweet.variants[0].qualityLabel} @ ${rr.tweet.variants[0].bitrate}bps）/ videoCount=${rr.tweet.videoCount}`;
    console.log(`PASS  ${label} -> ResolveResult(${rr.parserVersion}) ${desc}`);
  } else {
    console.log(`FAIL  ${label}`);
    for (const e of errors) console.log(`      ${e}`);
    failed++;
  }
}

console.log(failed === 0 ? '\n契约校验全部通过（fixtures ↔ resolve.schema.json ↔ error_codes.md）' : `\n${failed} 个夹具契约校验失败`);
process.exit(failed === 0 ? 0 : 1);
