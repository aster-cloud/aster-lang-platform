#!/usr/bin/env node
// 发布列车门槛扫描（gate scan）：比较同一批策略源码在「当前已发布」与「候选」两个 aster-lang-ts 构建上的
// 诊断码集合，确认候选版本不会改变任何生产策略的编译结论。
//
// 用法：
//   node scan.mjs --old <ts dist> --new <ts dist> --sources <jsonl> [--sources <jsonl> ...] [--code E054]
//
//   --old / --new  aster-lang-ts 构建产物目录（含 src/browser.js 的 dist；也接受仓库根，自动取其 dist/）
//   --sources      export-policy-sources.sql 的输出：每行 {"id", "kind", "content"}，并且必须恰好有一行
//                  完成标记 {"_count": N}，N 等于源行数（防止截断的导出被当成完整导出）。可重复。
//   --code X       只看诊断码 X：报告「旧版无 X、新版有 X」的源（#250 判据）
//
// 报告组（任一组非空即 FAIL）：
//   throws-on-new           新版 compile() 在任一 lexicon 下抛异常的源（不论旧版如何）
//   lexicons-missing-in-new 旧版有、新版没有的 lexicon（新版多出的 lexicon 只告警）
//   不带 --code：
//     newly-failing         某个对比 lexicon 下旧版编译成功、新版失败
//     newly-passing         旧版失败、新版成功
//     changed-codes         成败不变但诊断码集合不同（含警告码）
//   带 --code X：
//     gains-X               某个对比 lexicon 下旧版无 X、新版有 X
//
// 诊断码来源（ts compile() 返回的全部带码诊断）：parseErrors、loweringDiagnostics、
// resolutionDiagnostics 的 code（去空白、转大写）；只有 loweringErrors（无码字符串）时记为 UNCODED；
// compile() 抛异常记为 THROW；新版缺少该 lexicon 记为 NO_LEXICON（视为编译失败）。
//
// lexicon 规则：生产库不存语言列，因此对每份源尝试**旧版**构建的全部 lexicon
// （顺序 en-US、zh-CN、de-DE，其后按名称排序的其余语言），新版用同名 lexicon：
//   - 旧版编译成功的**每一个** lexicon 都参与对比，任一个出现差异即报告；
//   - 旧版在所有 lexicon 下都失败时，只对比一个选定的 lexicon：新版编译成功的第一个（让「新版才通过」
//     可见）→ 旧版通过解析阶段（失败在名称解析/降级）的第一个 → 第一个（en-US）。
//
// 启动时在两个构建上各编译一份已知可编译的金丝雀源，失败即判定构建损坏（退出码 3），
// 避免「两边都抛异常 → 诊断码相同 → 假 PASS」。compile() 期间屏蔽 console 与 stdout/stderr，
// 防止解析器日志带出源码。输出只含 id、kind、lexicon 与诊断码，**绝不打印源码内容**。
//
// 退出码：0 = 报告集合为空；1 = 报告集合非空；2 = 用法错误或意外崩溃；
//         3 = 输入或构建不可信（JSONL 损坏、完成标记缺失/不符、金丝雀失败、lexicon 无法加载）。
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

const PREFERRED_LEXICONS = ['en-US', 'zh-CN', 'de-DE'];
const LOCALE_FILE = /^[a-z]{2}-[A-Z]{2}\.js$/;
const CODE_PATTERN = /^[A-Z][A-Z0-9_]*$/;
const CANARY = 'Module gate.canary.\n\nRule identity given x as Int, produce Int:\n  Return x.';
const MISSING_LEXICON = Object.freeze({ ok: false, parseClean: false, threw: false, codes: ['NO_LEXICON'] });
const CONSOLE_METHODS = ['log', 'info', 'warn', 'error', 'debug', 'trace', 'dir', 'table'];

class ScanError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.exitCode = exitCode;
  }
}
const usageError = message => new ScanError(message, 2);
const invalidInput = message => new ScanError(message, 3);

const normalizeCode = code => String(code).trim().toUpperCase();

function parseCli() {
  let values;
  try {
    ({ values } = parseArgs({
      options: {
        old: { type: 'string' },
        new: { type: 'string' },
        sources: { type: 'string', multiple: true },
        code: { type: 'string' },
        help: { type: 'boolean', short: 'h' },
      },
      strict: true,
    }));
  } catch (error) {
    throw usageError(error.message);
  }
  if (values.help) return { help: true };
  if (!values.old) throw usageError('缺少 --old');
  if (!values.new) throw usageError('缺少 --new');
  if (!values.sources?.length) throw usageError('缺少 --sources');
  if (values.code !== undefined) {
    values.code = normalizeCode(values.code);
    if (!CODE_PATTERN.test(values.code)) throw usageError(`--code 不是合法诊断码：${JSON.stringify(values.code)}`);
  }
  return values;
}

/** 接受 dist 目录或仓库根目录，返回含 src/browser.js 的 dist 绝对路径。 */
function resolveDist(path) {
  const abs = resolve(path);
  if (existsSync(join(abs, 'src/browser.js'))) return abs;
  if (existsSync(join(abs, 'dist/src/browser.js'))) return join(abs, 'dist');
  throw usageError(`${path} 不是 aster-lang-ts 构建产物（找不到 src/browser.js 或 dist/src/browser.js）`);
}

const importFrom = (dist, rel) => import(pathToFileURL(join(dist, rel)).href);

/** 读取构建目录下所有 xx-YY.js 词法表；找不到 lexicon 导出的文件直接判为构建不可信。 */
async function loadLexicons(dist) {
  const dir = join(dist, 'src/config/lexicons');
  if (!existsSync(dir)) throw invalidInput(`${dist} 缺少 src/config/lexicons`);
  const lexicons = new Map();
  for (const file of readdirSync(dir).filter(f => LOCALE_FILE.test(f)).sort()) {
    const mod = await importFrom(dist, `src/config/lexicons/${file}`);
    const lexicon = Object.values(mod).find(v => v && typeof v === 'object' && typeof v.id === 'string');
    if (!lexicon) throw invalidInput(`${dist}: ${file} 没有导出带 id 的 lexicon 对象`);
    lexicons.set(lexicon.id, lexicon);
  }
  if (lexicons.size === 0) throw invalidInput(`${dist} 没有任何 lexicon`);
  return lexicons;
}

/** lexicon id 排序：首选顺序在前，其余按名称。 */
const orderLexiconIds = ids => [
  ...PREFERRED_LEXICONS.filter(id => ids.includes(id)),
  ...ids.filter(id => !PREFERRED_LEXICONS.includes(id)).sort(),
];

async function loadBuild(path, label) {
  const dist = resolveDist(path);
  const pkgPath = join(dist, '../package.json');
  const version = existsSync(pkgPath) ? JSON.parse(readFileSync(pkgPath, 'utf8')).version : 'unknown';
  const ts = await importFrom(dist, 'src/browser.js');
  if (typeof ts.compile !== 'function') throw invalidInput(`${label} 构建 ${dist} 没有导出 compile()`);
  const lexicons = await loadLexicons(dist);
  const build = { label, dist, version, ts, lexicons, lexiconIds: orderLexiconIds([...lexicons.keys()]) };
  build.stats = { attempts: 0, ok: 0, threw: 0 };
  checkCanary(build);
  return build;
}

/** 金丝雀：已知可编译的源在 en-US（或第一个 lexicon）下必须编译成功，否则构建不可信。 */
function checkCanary(build) {
  const lexicon = build.lexicons.get('en-US') ?? build.lexicons.get(build.lexiconIds[0]);
  const result = diagnose(build.ts, CANARY, lexicon);
  if (!result.ok) {
    throw invalidInput(`${build.label} 构建（${build.dist}）连金丝雀源都编译失败 {${result.codes.join(',')}}——构建损坏，扫描结果不可信`);
  }
}

/** 同步执行 fn，期间屏蔽 console 与 stdout/stderr 写入，防止被扫描代码打印源码。 */
function silently(fn) {
  const savedConsole = CONSOLE_METHODS.map(name => [name, console[name]]);
  const savedOut = process.stdout.write;
  const savedErr = process.stderr.write;
  for (const name of CONSOLE_METHODS) console[name] = () => {};
  process.stdout.write = () => true;
  process.stderr.write = () => true;
  try {
    return fn();
  } finally {
    for (const [name, method] of savedConsole) console[name] = method;
    process.stdout.write = savedOut;
    process.stderr.write = savedErr;
  }
}

/** 编译一次，返回 { ok, parseClean, threw, codes }；codes 为规范化、去重排序后的诊断码数组。 */
function diagnose(ts, source, lexicon) {
  let result;
  try {
    result = silently(() => ts.compile(source, { lexicon }));
  } catch {
    return { ok: false, parseClean: false, threw: true, codes: ['THROW'] };
  }
  const parseErrors = result?.parseErrors ?? [];
  const diagnostics = [...parseErrors, ...(result?.loweringDiagnostics ?? []), ...(result?.resolutionDiagnostics ?? [])];
  const codes = diagnostics.map(d => (d?.code == null ? 'UNCODED' : normalizeCode(d.code)));
  if (result?.loweringErrors?.length && !result.loweringDiagnostics?.length) codes.push('UNCODED');
  const ok = result?.success === true;
  return { ok, parseClean: ok || parseErrors.length === 0, threw: false, codes: [...new Set(codes)].sort() };
}

function record(build, outcome) {
  build.stats.attempts++;
  if (outcome.ok) build.stats.ok++;
  if (outcome.threw) build.stats.threw++;
}

/** 在旧版的每个 lexicon 下编译新旧两边；新版缺该 lexicon 记为 NO_LEXICON。 */
function compileAll(oldBuild, newBuild, source) {
  return oldBuild.lexiconIds.map(id => {
    const old = diagnose(oldBuild.ts, source, oldBuild.lexicons.get(id));
    const newLexicon = newBuild.lexicons.get(id);
    const neu = newLexicon ? diagnose(newBuild.ts, source, newLexicon) : MISSING_LEXICON;
    record(oldBuild, old);
    if (newLexicon) record(newBuild, neu);
    return { lexicon: id, old, new: neu };
  });
}

/** 参与对比的 lexicon：旧版成功的全部；全失败时按文件头规则选一个。 */
function comparedRuns(runs) {
  const okRuns = runs.filter(r => r.old.ok);
  if (okRuns.length) return okRuns;
  return [runs.find(r => r.new.ok) ?? runs.find(r => r.old.parseClean) ?? runs[0]];
}

const outcomeKey = o => `${o.ok}:${o.codes.join(',')}`;

/** 把一份源归入某个报告组，返回 { group, shown }；不需要报告时返回 null。 */
function classify(runs, code) {
  const thrown = runs.filter(r => r.new.threw);
  if (thrown.length) return { group: 'throws-on-new', shown: thrown };
  const compared = comparedRuns(runs);
  if (code) {
    const hits = compared.filter(r => !r.old.codes.includes(code) && r.new.codes.includes(code));
    return hits.length ? { group: `gains-${code}`, shown: hits } : null;
  }
  const differing = compared.filter(r => outcomeKey(r.old) !== outcomeKey(r.new));
  if (!differing.length) return null;
  if (differing.some(r => r.old.ok && !r.new.ok)) return { group: 'newly-failing', shown: differing };
  if (differing.some(r => !r.old.ok && r.new.ok)) return { group: 'newly-passing', shown: differing };
  return { group: 'changed-codes', shown: differing };
}

/** 读取一个导出文件并校验完成标记；任何损坏都判为输入不可信。 */
function readSourceFile(file) {
  if (!existsSync(file)) throw invalidInput(`${file} 不存在`);
  const rows = [];
  const markers = [];
  readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
    if (!line.trim()) return;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      throw invalidInput(`${file} 第 ${index + 1} 行不是合法 JSON`);
    }
    if (row && typeof row === 'object' && '_count' in row) {
      markers.push(row._count);
      return;
    }
    if (typeof row?.id !== 'string' || typeof row?.content !== 'string') {
      throw invalidInput(`${file} 第 ${index + 1} 行缺少字符串字段 id / content`);
    }
    rows.push({ id: row.id, kind: typeof row.kind === 'string' ? row.kind : 'unknown', content: row.content });
  });
  if (markers.length !== 1) {
    throw invalidInput(`${file} 应恰好有 1 行完成标记 {"_count": N}，实际 ${markers.length} 行——导出可能被截断`);
  }
  if (markers[0] !== rows.length) {
    throw invalidInput(`${file} 完成标记 _count=${markers[0]} 与实际源行数 ${rows.length} 不符——导出被截断或损坏`);
  }
  return rows;
}

const fmtOutcome = o => `{${o.codes.join(',')}}${o.ok ? '' : '!'}`;
const fmtStats = s => `${s.ok} ok, ${s.threw} threw, ${s.attempts - s.ok} not ok / ${s.attempts} compiles`;

function printReport({ oldBuild, newBuild, args, sources, kinds, groups, newOnly }) {
  const reported = [...groups.values()].reduce((n, list) => n + list.length, 0);
  console.log(`gate scan: old=${oldBuild.version} (${oldBuild.dist})`);
  console.log(`           new=${newBuild.version} (${newBuild.dist})`);
  console.log(`mode: ${args.code ? `code ${args.code} (absent on old, present on new)` : 'diagnostic-code diff'}`);
  console.log(`lexicons tried (old): ${oldBuild.lexiconIds.join(', ')}`);
  if (newOnly.length) console.log(`WARNING: lexicons only in new (not scanned): ${newOnly.join(', ')}`);
  console.log(`scanned: ${sources.length} (${[...kinds].map(([k, n]) => `${k}=${n}`).join(', ') || 'none'})`);
  console.log(`old compiles: ${fmtStats(oldBuild.stats)}`);
  console.log(`new compiles: ${fmtStats(newBuild.stats)}`);
  for (const [name, list] of groups) {
    console.log(`${name}: ${list.length}`);
    for (const item of list) console.log(`  ${item}`);
  }
  console.log(`result: ${reported === 0 ? 'PASS' : 'FAIL'} (${reported} reported)`);
  return reported === 0 ? 0 : 1;
}

async function main() {
  const args = parseCli();
  if (args.help) {
    console.log('用法：node scan.mjs --old <ts dist> --new <ts dist> --sources <jsonl> [--sources <jsonl> ...] [--code E054]');
    return 0;
  }
  const sources = args.sources.flatMap(readSourceFile);
  const oldBuild = await loadBuild(args.old, 'old');
  const newBuild = await loadBuild(args.new, 'new');

  const contentGroups = args.code ? [`gains-${args.code}`] : ['newly-failing', 'newly-passing', 'changed-codes'];
  const groups = new Map(['throws-on-new', 'lexicons-missing-in-new', ...contentGroups].map(name => [name, []]));
  const missing = oldBuild.lexiconIds.filter(id => !newBuild.lexicons.has(id));
  const newOnly = newBuild.lexiconIds.filter(id => !oldBuild.lexicons.has(id));
  for (const id of missing) groups.get('lexicons-missing-in-new').push(`${id} [lexicon] present in old, missing in new`);

  const kinds = new Map();
  for (const row of sources) {
    kinds.set(row.kind, (kinds.get(row.kind) ?? 0) + 1);
    const verdict = classify(compileAll(oldBuild, newBuild, row.content), args.code);
    if (!verdict) continue;
    const detail = verdict.shown.map(r => `${r.lexicon} old=${fmtOutcome(r.old)} new=${fmtOutcome(r.new)}`).join('; ');
    groups.get(verdict.group).push(`${row.id} [${row.kind}] ${detail}`);
  }
  return printReport({ oldBuild, newBuild, args, sources, kinds, groups, newOnly });
}

try {
  process.exitCode = await main();
} catch (error) {
  if (error instanceof ScanError) {
    console.error(`scan.mjs: ${error.message}`);
    process.exitCode = error.exitCode;
  } else {
    // 意外崩溃只打印错误类型与消息，不打印堆栈里可能夹带的输入片段。
    console.error(`scan.mjs: 意外错误 ${error?.name ?? 'Error'}: ${error?.message ?? String(error)}`);
    process.exitCode = 2;
  }
}
