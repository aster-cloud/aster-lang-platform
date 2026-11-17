#!/usr/bin/env node
// 门禁扫描的 ts 侧补充：同一批源在新旧两个 aster-lang-ts 构建上各跑一次 compileAndTypecheck，比较：
//   · 编译结论（旧版成功的 lexicon 上新版失败 → newly-failing；其中带 E064(',')——E064 且 params.construct 为 "','"——
//     的单列 newly-failing-E064，对应 ADR 0056 修订 A1 §2.3 括号类型表里的歧义逗号）；
//   · 类型检查诊断码（含 severity）集合；
//   · 规范 coreJson 是否逐字节相同，不同则列出差异处最近的 IR 键名（只打印 schema 键名，不打印任何取值）。
// e064-prefilter-hits：ADR 0056 修订 A1 §4 的预筛正则命中的 id（有误报，只用于与编译结论交叉核对）。
// scan.mjs 只比较 compile() 的诊断码；本脚本补上 IR 与类型检查。复用 common.mjs 的导出读取、lexicon 加载与静默编译，
// 与 scan.mjs 一样从不打印源码。
//
// 用法：node ir-diff.mjs [--common <common.mjs>] --old <ts dist 或仓库根> --new <同上>
//                        --sources <jsonl> [--sources <jsonl> ...] [--allow-empty-api]
// 退出码：0 = 无需复核项；1 = 有需复核项（newly-failing* / typecheck-new-errors / throws-on-new）；2 / 3 同 scan.mjs。
// ir-changed、typecheck-changed（无新增 error）、e064-prefilter-hits 为信息项。
import { parseArgs } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const { values: args } = parseArgs({
  options: {
    common: { type: 'string' },
    old: { type: 'string' },
    new: { type: 'string' },
    sources: { type: 'string', multiple: true },
    'allow-empty-api': { type: 'boolean' },
  },
  strict: true,
});
const c = await import(pathToFileURL(args.common ?? join(dirname(fileURLToPath(import.meta.url)), 'common.mjs')).href);

// ADR 0056 修订 A1 §4：策略源码预筛正则（函数类型参数表里开放元数 X of 之后的逗号）。
const E064_PREFILTER = /\(\s*[^()]*\b(?:result|[A-Z]\w*)\s+of\s+[^(),]+,/;
const CANARY = 'Module gate.canary.\n\nRule ping given x as Int, produce Int:\n  Return x.\n';

async function loadBuild(path, label) {
  const dist = c.resolveDist(path);
  const ts = await c.importFrom(dist, 'src/browser.js');
  if (typeof ts.compileAndTypecheck !== 'function') throw c.invalidInput(`${label} 构建没有导出 compileAndTypecheck()`);
  const lexicons = await c.loadLexicons(dist);
  const build = { label, dist, version: c.buildVersion(dist), ts, lexicons, ids: c.orderLexiconIds([...lexicons.keys()]) };
  const canary = run(build, CANARY, lexicons.get('en-US'));
  if (!canary.ok) throw c.invalidInput(`${label} 构建的金丝雀源编译失败（${canary.all.join(',')}）：构建损坏`);
  return build;
}

const code = d => (d?.code == null ? 'UNCODED' : String(d.code).trim().toUpperCase());
// E064 是通用的「Unexpected {construct}」；ADR 0056 修订 A1 §2.3 的歧义逗号是 construct == "','" 的那一种，单独标成 E064(',')。
const frontCode = d => (code(d) === 'E064' && d?.params?.construct === "','" ? "E064(',')" : code(d));

/** 编译 + 类型检查一次；返回 { ok, all: ['E064', ...], tc: ['E123:error', ...], json } 或 { threw: true }。 */
function run(build, source, lexicon) {
  try {
    const r = c.silently(() => build.ts.compileAndTypecheck(source, { lexicon }));
    const front = [...(r.parseErrors ?? []), ...(r.loweringDiagnostics ?? []), ...(r.resolutionDiagnostics ?? [])].map(frontCode);
    if (r.loweringErrors?.length && !r.loweringDiagnostics?.length) front.push('UNCODED');
    const tc = [...new Set((r.typeErrors ?? []).map(d => `${code(d)}:${d.severity}`))].sort();
    const all = [...new Set([...front, ...tc.map(t => t.split(':')[0])])].sort();
    return { ok: r.success === true, all, tc, json: r.coreJson ?? null };
  } catch {
    return { threw: true, ok: false, all: ['THROW'], tc: ['THROW'], json: null };
  }
}

/** 递归比较两棵 IR，收集取值不同处最近的对象键名（数组元素继承其所在数组的键名）。 */
function diffKeys(a, b, key, out) {
  if (a === b) return;
  const bothObj = a && b && typeof a === 'object' && typeof b === 'object';
  if (!bothObj || Array.isArray(a) !== Array.isArray(b)) { out.add(key); return; }
  if (Array.isArray(a)) {
    if (a.length !== b.length) { out.add(key); return; }
    a.forEach((x, i) => diffKeys(x, b[i], key, out));
    return;
  }
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) diffKeys(a[k], b[k], k, out);
}

async function main() {
  const sources = c.readSources(args.sources);
  c.checkSourceCounts(sources, { allowEmptyApi: args['allow-empty-api'] });
  const oldB = await loadBuild(args.old, 'old');
  const newB = await loadBuild(args.new, 'new');
  const groups = {
    'newly-failing-E064': [], 'newly-failing': [], 'throws-on-new': [], 'typecheck-new-errors': [],
    'typecheck-changed': [], 'ir-changed': [], 'e064-prefilter-hits': [],
  };
  const keyCounts = new Map();
  let compared = 0;
  for (const row of sources) {
    if (E064_PREFILTER.test(row.content)) groups['e064-prefilter-hits'].push(`${row.id} [${row.kind}]`);
    for (const id of oldB.ids) {
      const o = run(oldB, row.content, oldB.lexicons.get(id));
      if (!o.ok) continue;                      // 只比较旧版成功的 lexicon（旧版就失败的源由 scan.mjs 的 changed-codes 覆盖）
      const nl = newB.lexicons.get(id);
      const n = nl ? run(newB, row.content, nl) : { threw: true, ok: false, all: ['NO_LEXICON'], tc: ['NO_LEXICON'], json: null };
      compared++;
      const tag = `${row.id} [${row.kind}] ${id}`;
      if (n.threw) { groups['throws-on-new'].push(`${tag} ${n.all.join(',')}`); continue; }
      if (!n.ok) {
        groups[n.all.includes("E064(',')") ? 'newly-failing-E064' : 'newly-failing'].push(`${tag} new={${n.all.join(',')}}`);
        continue;
      }
      const oldErr = o.tc.filter(t => t.endsWith(':error'));
      const newErr = n.tc.filter(t => t.endsWith(':error') && !oldErr.includes(t));
      if (newErr.length) groups['typecheck-new-errors'].push(`${tag} old={${o.tc.join(',')}} new={${n.tc.join(',')}}`);
      else if (o.tc.join() !== n.tc.join()) groups['typecheck-changed'].push(`${tag} old={${o.tc.join(',')}} new={${n.tc.join(',')}}`);
      if (o.json !== n.json) {
        const keys = new Set();
        if (o.json && n.json) diffKeys(JSON.parse(o.json), JSON.parse(n.json), '(root)', keys);
        else keys.add('(coreJson missing)');
        for (const k of keys) keyCounts.set(k, (keyCounts.get(k) ?? 0) + 1);
        groups['ir-changed'].push(`${tag} keys=[${[...keys].sort().join(',')}]`);
      }
    }
  }
  console.log(`ir-diff (ts): old=${oldB.version} new=${newB.version}`);
  console.log(`compared (source × old-ok lexicon): ${compared}`);
  for (const [name, list] of Object.entries(groups)) {
    console.log(`${name}: ${list.length}`);
    for (const line of list) console.log(`  ${line}`);
  }
  console.log(`ir-changed key histogram: ${[...keyCounts].sort((x, y) => y[1] - x[1]).map(([k, v]) => `${k}=${v}`).join(' ') || 'none'}`);
  const bad = groups['newly-failing-E064'].length + groups['newly-failing'].length
    + groups['typecheck-new-errors'].length + groups['throws-on-new'].length;
  console.log(`result: ${bad ? 'REVIEW' : 'OK'} (${bad} need review; ir-changed / typecheck-changed / e064-prefilter-hits are informational)`);
  return bad ? 1 : 0;
}

await c.runMain('ir-diff.mjs', main);
