#!/usr/bin/env node
// ============================================================================
// fetch_fixtures.mjs —— 端点哨兵（DESIGN §11.4 / §12-1 缓解）
//
// 职责：
//   1. 拉取真实端点响应刷新 assets/fixtures/ 下的夹具（录制优先）；
//   2. 与旧夹具 diff——字段漂移即报告并以非零码退出（每日/发版前哨兵，
//      是 EndpointDrift(E07) 守卫的对账依据）；
//   3. 每个场景按期望分类自检（video_ok 必须含 video 条目、photo_only 必须
//      无 video、sensitive 必须 possibly_sensitive=true 等），不匹配则继续
//      尝试候选 ID 列表中的下一个。
//
// 用法：
//   node tools/fetch_fixtures.mjs                     # 录制/刷新全部场景 + diff
//   node tools/fetch_fixtures.mjs --only=video_ok     # 仅刷新指定场景
//   node tools/fetch_fixtures.mjs --probe --id=<id>   # 探测单个 ID 的媒体形态
//   node tools/fetch_fixtures.mjs --allow-drift       # 漂移仅警告不失败
//
// 说明：
//   - 无 token 请求（200 + 空 {}）是 DESIGN §6.1 实测行为，作为 empty 夹具来源；
//   - 404 dogpage 用未来雪花 ID（尚未分配，必然 404）；
//   - 任一场景全部候选 ID 失败时，本脚本报告 FAIL_BY_NETWORK（或
//     FAIL_NO_MATCH），夹具由人工按 DESIGN §6.1/§6.3 记录的结构合成——
//     合成必须在提交 notes 中逐条申报。
// ============================================================================

import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const args = process.argv.slice(2);
const argOf = (name) => {
  const hit = args.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.split('=').slice(1).join('=') : null;
};
const only = argOf('only');
const allowDrift = args.includes('--allow-drift');
const probe = args.includes('--probe');
const probeId = argOf('id');

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36';
const SYNDICATION = (id, token, lang = 'en') =>
  `https://cdn.syndication.twimg.com/tweet-result?id=${id}&lang=${lang}${token ? `&token=${token}` : ''}`;
const FXTWITTER = (id) => `https://api.fxtwitter.com/status/${id}`;

// ---- token 算法：V8 参考实现（与 DESIGN §6.2 唯一权威实现一致）----
const tokenOf = (id) => ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '');

async function fetchBody(url, { timeoutMs = 12000 } = {}) {
  // 手动 AbortController + clearTimeout：规避 Node 24 Windows 下
  // AbortSignal.timeout 在进程退出阶段触发 libuv 断言的已知问题。
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetch(url, {
      headers: { 'User-Agent': UA, Accept: 'application/json,text/html;q=0.9,*/*;q=0.8' },
      redirect: 'follow',
      signal: ac.signal,
    });
    const contentType = res.headers.get('content-type') ?? '';
    const body = await res.text();
    return { status: res.status, contentType, body };
  } finally {
    clearTimeout(timer);
  }
}

// ---- 期望分类自检器（对账：响应必须真正属于该场景）----
const videoCountOf = (j) =>
  Array.isArray(j?.mediaDetails) ? j.mediaDetails.filter((m) => m?.type === 'video' || m?.type === 'animated_gif').length : 0;
const CHECKS = {
  video_ok: { expect: '单视频推文（mediaDetails 含 1 个 video，variants 有 mp4 档）', ok: (s, j) => s === 200 && videoCountOf(j) === 1 && j.mediaDetails.some((m) => (m.video_info?.variants ?? []).some((v) => v.content_type === 'video/mp4' && v.bitrate > 0)) },
  multi_video: { expect: '多视频推文（mediaDetails 含 >=2 个 video）', ok: (s, j) => s === 200 && videoCountOf(j) >= 2 },
  photo_only: { expect: '纯图推文（mediaDetails 全部为 photo，无 video/gif）', ok: (s, j) => s === 200 && Array.isArray(j?.mediaDetails) && j.mediaDetails.length > 0 && videoCountOf(j) === 0 },
  sensitive: { expect: '敏感推文（possibly_sensitive === true 且含 video）', ok: (s, j) => s === 200 && videoCountOf(j) >= 1 && j.possibly_sensitive === true },
  fxtwitter: { expect: 'fxtwitter 备源样本（code==200 且 tweet 含视频）', ok: (s, j) => s === 200 && j?.code === 200 && !!j?.tweet && JSON.stringify(j.tweet?.media ?? {}).includes('video') },
};

// ---- 场景定义：候选 ID 按优先级排列（失败自动降级到下一个候选）----
const SCENARIOS = [
  {
    name: 'video_ok',
    file: 'assets/fixtures/syndication_video_ok.json',
    url: (id) => SYNDICATION(id, tokenOf(id)),
    candidates: ['1790637656616943991', '1580389357947420672', '1605220334828646401'],
  },
  {
    name: 'multi_video',
    file: 'assets/fixtures/syndication_multi_video.json',
    url: (id) => SYNDICATION(id, tokenOf(id)),
    candidates: ['1600054672628676609', '1591128400376983552', '1616132006857586688'],
  },
  {
    name: 'photo_only',
    file: 'assets/fixtures/syndication_photo_only.json',
    url: (id) => SYNDICATION(id, tokenOf(id)),
    candidates: ['1590467417877884928', '1580389357947420672'],
  },
  {
    name: 'sensitive',
    file: 'assets/fixtures/syndication_sensitive.json',
    url: (id) => SYNDICATION(id, tokenOf(id)),
    candidates: ['1585226406419570688'],
  },
  {
    name: 'dogpage',
    file: 'assets/fixtures/syndication_404_dogpage.html',
    // 未来雪花 ID（尚未分配）：必然 404 + dogpage HTML（DESIGN §6.1）
    url: () => SYNDICATION('1999999999999999999', tokenOf('1999999999999999999')),
    candidates: ['1999999999999999999'],
    raw: true,
    expectStatus: 404,
  },
  {
    name: 'empty',
    file: 'assets/fixtures/syndication_empty.json',
    // 不带 token：200 + 空 {}（DESIGN §6.1 实测行为）
    url: (id) => SYNDICATION(id, ''),
    candidates: ['1790637656616943991'],
    raw: true,
    expectBody: '{}',
  },
  {
    name: 'fxtwitter',
    file: 'assets/fixtures/fxtwitter_status_ok.json',
    url: (id) => FXTWITTER(id),
    candidates: ['1790637656616943991'],
    altSource: 'fxtwitter',
  },
];

function pretty(body, isHtml) {
  if (isHtml) return body.replace(/\r\n/g, '\n');
  try {
    return JSON.stringify(JSON.parse(body), null, 2) + '\n';
  } catch {
    return body;
  }
}

function diffSummary(oldText, newText) {
  const a = oldText.split('\n');
  const b = newText.split('\n');
  let firstDiff = -1;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) { firstDiff = i; break; }
  }
  if (firstDiff === -1) return '内容一致';
  return [
    `首个差异行 ${firstDiff + 1}:`,
    `  旧: ${(a[firstDiff] ?? '<EOF>').slice(0, 160)}`,
    `  新: ${(b[firstDiff] ?? '<EOF>').slice(0, 160)}`,
    `  行数 旧=${a.length} 新=${b.length}`,
  ].join('\n');
}

async function recordOne(sc) {
  for (const id of sc.candidates) {
    const url = sc.url(id);
    let r;
    try {
      r = await fetchBody(url);
    } catch (e) {
      console.log(`  [${sc.name}] 候选 ${id} 网络失败: ${e.cause?.code ?? e.cause?.message ?? e.message}`);
      continue;
    }
    if (sc.expectStatus !== undefined && r.status !== sc.expectStatus) {
      console.log(`  [${sc.name}] 候选 ${id} 期望 HTTP ${sc.expectStatus} 实得 ${r.status}，尝试下一候选`);
      continue;
    }
    if (sc.expectBody !== undefined && r.body.trim() !== sc.expectBody) {
      console.log(`  [${sc.name}] 候选 ${id} 期望空 {} 实得: ${r.body.slice(0, 80)}，尝试下一候选`);
      continue;
    }
    if (sc.raw) {
      const text = pretty(r.body, sc.file.endsWith('.html') || !r.body.trim().startsWith('{'));
      return { id, url, text, note: `HTTP ${r.status} raw` };
    }
    let j = null;
    try { j = JSON.parse(r.body); } catch { /* fallthrough */ }
    if (!j || !CHECKS[sc.name]?.ok(r.status, j)) {
      console.log(`  [${sc.name}] 候选 ${id} 不满足期望（${CHECKS[sc.name]?.expect}；实得 typename=${j?.__typename ?? 'N/A'} videoCount=${videoCountOf(j)} sensitive=${j?.possibly_sensitive ?? 'N/A'}），尝试下一候选`);
      continue;
    }
    return { id, url, text: pretty(r.body, false), note: `HTTP ${r.status}，对账通过：${CHECKS[sc.name].expect}` };
  }
  return null;
}

// ---- 探测模式：--probe --id=<id> 报告该 ID 的媒体形态 ----
if (probe) {
  if (!probeId) { console.error('--probe 需要 --id=<tweetId>'); process.exit(2); }
  const r = await fetchBody(SYNDICATION(probeId, tokenOf(probeId)));
  let j = null;
  try { j = JSON.parse(r.body); } catch { /* html */ }
  console.log(`status=${r.status} content-type=${r.contentType}`);
  if (j) {
    console.log(`__typename=${j.__typename} possibly_sensitive=${j.possibly_sensitive} videoCount=${videoCountOf(j)}`);
    for (const m of j.mediaDetails ?? []) {
      console.log(`  media: type=${m.type} variants=${(m.video_info?.variants ?? []).map((v) => `${v.content_type ?? v.type}:${v.bitrate ?? '?'}`).join(',') || '-'}`);
    }
  } else {
    console.log(`body(前200)=${r.body.slice(0, 200)}`);
  }
  process.exit(0);
}

// ---- 录制/diff 主流程 ----
mkdirSync('assets/fixtures', { recursive: true });
const results = { recorded: [], unchanged: [], drifted: [], failed: [] };

for (const sc of SCENARIOS) {
  if (only && sc.name !== only) continue;
  console.log(`[${sc.name}] 目标: ${sc.file}`);
  const hit = await recordOne(sc);
  if (!hit) {
    console.log(`  => FAIL：全部候选失败（无网络或无匹配样本），需按 DESIGN §6.1/§6.3 合成并申报`);
    results.failed.push(sc.name);
    continue;
  }
  const abs = resolve(sc.file);
  const newText = hit.text;
  let status = 'NEW';
  if (existsSync(abs)) {
    const oldText = readFileSync(abs, 'utf8');
    status = oldText === newText ? 'UNCHANGED' : 'DRIFTED';
    if (status === 'DRIFTED') console.log(diffSummary(oldText, newText));
  }
  if (status !== 'UNCHANGED') writeFileSync(abs, newText, 'utf8');
  console.log(`  => ${status}（id=${hit.id}，${hit.note}）`);
  results[{ NEW: 'recorded', UNCHANGED: 'unchanged', DRIFTED: 'drifted' }[status]].push(sc.name);
}

console.log('\n========== fetch_fixtures 汇总 ==========');
console.log(`录制/刷新: ${results.recorded.join(', ') || '(无)'}`);
console.log(`未变化:    ${results.unchanged.join(', ') || '(无)'}`);
console.log(`漂移:      ${results.drifted.join(', ') || '(无)'}`);
console.log(`失败:      ${results.failed.join(', ') || '(无)'}`);

if (results.failed.length > 0) {
  console.log('\n存在失败场景：夹具需人工合成（按 DESIGN §6.1/§6.3 真实结构），并在交付 notes 中申报。');
  process.exitCode = 1;
} else if (results.drifted.length > 0 && !allowDrift) {
  console.log('\n检测到端点漂移（DRIFTED）！请人工核对差异后再提交；确认接受可加 --allow-drift。');
  process.exitCode = 1;
}
// 显式退出：规避 Node 24 Windows 在进程异步拆卸阶段的 libuv 断言
process.exit(process.exitCode ?? 0);
