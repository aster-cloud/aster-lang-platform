#!/usr/bin/env node
// 发布列车门槛扫描（gate scan）：比较同一批策略源码在「当前已发布」与「候选」两个 aster-lang-ts 构建上的
// 诊断码集合，确认候选版本不会改变任何生产策略的编译结论。
//
// 用法：
//   node scan.mjs --old <ts dist> --new <ts dist> --sources <jsonl> [--code E054]
//
//   --old / --new  aster-lang-ts 构建产物目录（含 src/browser.js 的 dist；也接受仓库根，自动取其 dist/）
//   --sources      每行一个 JSON 对象 {"id", "kind", "content"}（export-policy-sources.sql 的输出）
//   --code X       只看诊断码 X：报告「旧版无 X、新版有 X」的源（#250 判据）
//
// 不带 --code：报告诊断码集合在新旧之间不同的源，分三组：
//   newly-failing  旧版编译成功、新版失败
//   newly-passing  旧版失败、新版成功
//   changed-codes  成败不变但诊断码集合不同（含警告码变化）
//
// 诊断码来源（ts compile() 返回的全部带码诊断）：parseErrors、loweringDiagnostics、
// resolutionDiagnostics 的 code；只有 loweringErrors（无码字符串）时记为 UNCODED；
// compile() 本身抛异常记为 THROW。
//
// 词法表（lexicon）规则：生产库不存语言列，因此对每份源依次尝试两边构建都有的 lexicon
// （顺序 en-US、zh-CN、de-DE，其后按名称排序的其余 xx-YY），并为该源选定**一个** lexicon，
// 新旧两边都按它比较：
//   1. 旧版编译成功的第一个 lexicon；
//   2. 否则：新版编译成功的第一个 lexicon（让「新版才通过」的源能被看到）；
//   3. 否则：旧版通过了解析阶段（无 parseErrors，失败在名称解析/降级）的第一个 lexicon；
//   4. 否则：第一个 lexicon（en-US）。
//
// 输出只含 id、kind、选定的 lexicon 与诊断码集合，**绝不打印源码内容**。
// 退出码：0 = 报告集合为空；1 = 报告集合非空；2 = 用法或输入错误。
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const PREFERRED_LEXICONS = ['en-US', 'zh-CN', 'de-DE'];
const LOCALE_FILE = /^[a-z]{2}-[A-Z]{2}\.js$/;

function die(message) {
  console.error(`scan.mjs: ${message}`);
  process.exit(2);
}

function parseCli() {
  let values;
  try {
    ({ values } = parseArgs({
      options: {
        old: { type: 'string' },
        new: { type: 'string' },
        sources: { type: 'string' },
        code: { type: 'string' },
        help: { type: 'boolean', short: 'h' },
      },
      strict: true,
    }));
  } catch (error) {
    die(error.message);
  }
  if (values.help) {
    console.log('用法：node scan.mjs --old <ts dist> --new <ts dist> --sources <jsonl> [--code E054]');
    process.exit(0);
  }
  for (const key of ['old', 'new', 'sources']) {
    if (!values[key]) die(`缺少 --${key}`);
  }
  return values;
}

/** 接受 dist 目录或仓库根目录，返回含 src/browser.js 的 dist 绝对路径。 */
function resolveDist(path) {
  const abs = resolve(path);
  if (existsSync(join(abs, 'src/browser.js'))) return abs;
  if (existsSync(join(abs, 'dist/src/browser.js'))) return join(abs, 'dist');
  die(`${path} 不是 aster-lang-ts 构建产物（找不到 src/browser.js 或 dist/src/browser.js）`);
}

const importFrom = (dist, rel) => import(pathToFileURL(join(dist, rel)).href);

/** 读取构建目录下所有 xx-YY.js 词法表，返回 Map<id, lexicon>。 */
async function loadLexicons(dist) {
  const dir = join(dist, 'src/config/lexicons');
  const lexicons = new Map();
  for (const file of readdirSync(dir).filter(f => LOCALE_FILE.test(f))) {
    const mod = await importFrom(dist, `src/config/lexicons/${file}`);
    const lexicon = Object.values(mod).find(v => v && typeof v === 'object' && v.id && v.keywords);
    if (lexicon) lexicons.set(lexicon.id, lexicon);
  }
  return lexicons;
}

async function loadBuild(path) {
  const dist = resolveDist(path);
  const pkgPath = join(dist, '../package.json');
  const version = existsSync(pkgPath) ? JSON.parse(readFileSync(pkgPath, 'utf8')).version : 'unknown';
  return { dist, version, ts: await importFrom(dist, 'src/browser.js'), lexicons: await loadLexicons(dist) };
}

/** 两边都有的 lexicon id，按首选顺序 + 其余按名称排序。 */
function commonLexiconIds(oldBuild, newBuild) {
  const shared = [...oldBuild.lexicons.keys()].filter(id => newBuild.lexicons.has(id));
  const rest = shared.filter(id => !PREFERRED_LEXICONS.includes(id)).sort();
  return [...PREFERRED_LEXICONS.filter(id => shared.includes(id)), ...rest];
}

/** 编译一次，返回 { ok, parseClean, codes }；codes 为去重排序后的诊断码数组。 */
function diagnose(ts, source, lexicon) {
  let result;
  try {
    result = ts.compile(source, { lexicon });
  } catch {
    return { ok: false, parseClean: false, codes: ['THROW'] };
  }
  const diagnostics = [
    ...(result.parseErrors ?? []),
    ...(result.loweringDiagnostics ?? []),
    ...(result.resolutionDiagnostics ?? []),
  ];
  const codes = diagnostics.map(d => d.code ?? 'UNCODED');
  if (result.loweringErrors?.length && !result.loweringDiagnostics?.length) codes.push('UNCODED');
  const parseClean = !(result.parseErrors ?? []).length || result.success === true;
  return { ok: result.success === true, parseClean, codes: [...new Set(codes)].sort() };
}

/** 按文件头注释的四条规则为一份源选定 lexicon，返回 { lexicon, old, new }。 */
function compareSource(oldBuild, newBuild, lexiconIds, source) {
  const runs = lexiconIds.map(id => ({
    lexicon: id,
    old: diagnose(oldBuild.ts, source, oldBuild.lexicons.get(id)),
    new: diagnose(newBuild.ts, source, newBuild.lexicons.get(id)),
  }));
  return runs.find(r => r.old.ok)
    ?? runs.find(r => r.new.ok)
    ?? runs.find(r => r.old.parseClean)
    ?? runs[0];
}

function readSources(file) {
  const rows = [];
  readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
    if (!line.trim()) return;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      die(`${file} 第 ${index + 1} 行不是合法 JSON`);
    }
    if (typeof row?.id !== 'string' || typeof row?.content !== 'string') {
      die(`${file} 第 ${index + 1} 行缺少字符串字段 id / content`);
    }
    rows.push({ id: row.id, kind: typeof row.kind === 'string' ? row.kind : 'unknown', content: row.content });
  });
  return rows;
}

/** 把一份源的比较结果归入某个报告组；不需要报告时返回 null。 */
function classify(cmp, code) {
  const sameCodes = cmp.old.codes.join(',') === cmp.new.codes.join(',');
  if (code) return !cmp.old.codes.includes(code) && cmp.new.codes.includes(code) ? `gains-${code}` : null;
  if (cmp.old.ok && !cmp.new.ok) return 'newly-failing';
  if (!cmp.old.ok && cmp.new.ok) return 'newly-passing';
  return sameCodes ? null : 'changed-codes';
}

const fmtCodes = codes => `{${codes.join(',')}}`;

async function main() {
  const args = parseCli();
  const oldBuild = await loadBuild(args.old);
  const newBuild = await loadBuild(args.new);
  const lexiconIds = commonLexiconIds(oldBuild, newBuild);
  if (lexiconIds.length === 0) die('两个构建没有共同的 lexicon');
  const sources = readSources(args.sources);

  const groupNames = args.code ? [`gains-${args.code}`] : ['newly-failing', 'newly-passing', 'changed-codes'];
  const groups = new Map(groupNames.map(name => [name, []]));
  const kinds = new Map();
  for (const row of sources) {
    kinds.set(row.kind, (kinds.get(row.kind) ?? 0) + 1);
    const cmp = compareSource(oldBuild, newBuild, lexiconIds, row.content);
    const group = classify(cmp, args.code);
    if (group) groups.get(group).push({ row, cmp });
  }

  const reported = [...groups.values()].reduce((n, list) => n + list.length, 0);
  const kindSummary = [...kinds].map(([k, n]) => `${k}=${n}`).join(', ') || 'none';
  console.log(`gate scan: old=${oldBuild.version} (${oldBuild.dist})`);
  console.log(`           new=${newBuild.version} (${newBuild.dist})`);
  console.log(`mode: ${args.code ? `code ${args.code} (absent on old, present on new)` : 'diagnostic-code diff'}`);
  console.log(`lexicons tried: ${lexiconIds.join(', ')}`);
  console.log(`scanned: ${sources.length} (${kindSummary})`);
  for (const [name, list] of groups) {
    console.log(`${name}: ${list.length}`);
    for (const { row, cmp } of list) {
      console.log(`  ${row.id} [${row.kind}] lexicon=${cmp.lexicon} old=${fmtCodes(cmp.old.codes)}${cmp.old.ok ? '' : '!'}`
        + ` new=${fmtCodes(cmp.new.codes)}${cmp.new.ok ? '' : '!'}`);
    }
  }
  console.log(`result: ${reported === 0 ? 'PASS' : 'FAIL'} (${reported} reported)`);
  process.exit(reported === 0 ? 0 : 1);
}

await main();
