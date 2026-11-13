#!/usr/bin/env node
// 发布列车门槛扫描（gate scan）：比较同一批策略源码在「当前已发布」与「候选」两个 aster-lang-ts 构建上的
// 诊断码集合，确认候选版本不会改变任何生产策略的编译结论。
//
// 用法：
//   node scan.mjs --old <ts dist> --new <ts dist> --sources <jsonl> [--sources <jsonl> ...] [--code E054]
//                 [--allow-empty-api] [--allow-empty-cloud]
//
//   --old / --new  aster-lang-ts 构建产物目录（含 src/browser.js 的 dist；也接受仓库根，自动取其 dist/）
//   --sources      export-policy-sources.sql 的输出：每行 {"id", "kind", "content"}，并且必须恰好有一行
//                  完成标记 {"_count": N}，N 等于源行数（防止截断的导出被当成完整导出）。可重复。
//   --code X       只看诊断码 X：报告「旧版无 X、新版有 X」的源（#250 判据）
//   --allow-empty-api    允许 api-policy-version 源为 0（gate-scan.sh 的 --allow-empty-api-db）
//   --allow-empty-cloud  允许 cloud 源为 0（只由旧旗标 --allow-empty-db 传入，保留其单边放行的原义）
//
// 开头打印按 kind 的源计数 `sources: cloud-policy=N cloud-policy-version=M api-policy-version=K`；
// 未放行时 cloud 两种合计为 0 或 api 为 0 → 退出码 3（空扫描不算通过）。
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
//         3 = 输入或构建不可信（JSONL 损坏、完成标记缺失/不符、未放行的空导出、金丝雀失败、lexicon 无法加载）。
import { parseArgs } from 'node:util';
import {
  buildVersion, checkSourceCounts, importFrom, invalidInput, loadLexicons, orderLexiconIds, readSources,
  resolveDist, runMain, silently, usageError,
} from './common.mjs';

const CODE_PATTERN = /^[A-Z][A-Z0-9_]*$/;
const CANARY = 'Module gate.canary.\n\nRule identity given x as Int, produce Int:\n  Return x.';
const MISSING_LEXICON = Object.freeze({ ok: false, parseClean: false, threw: false, codes: ['NO_LEXICON'] });

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
        'allow-empty-api': { type: 'boolean' },
        'allow-empty-cloud': { type: 'boolean' },
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

async function loadBuild(path, label) {
  const dist = resolveDist(path);
  const ts = await importFrom(dist, 'src/browser.js');
  if (typeof ts.compile !== 'function') throw invalidInput(`${label} 构建 ${dist} 没有导出 compile()`);
  const lexicons = await loadLexicons(dist);
  const build = { label, dist, version: buildVersion(dist), ts, lexicons, lexiconIds: orderLexiconIds([...lexicons.keys()]) };
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
    console.log('用法：node scan.mjs --old <ts dist> --new <ts dist> --sources <jsonl> [--sources <jsonl> ...] [--code E054] [--allow-empty-api] [--allow-empty-cloud]');
    return 0;
  }
  const sources = readSources(args.sources);
  checkSourceCounts(sources, { allowEmptyApi: args['allow-empty-api'], allowEmptyCloud: args['allow-empty-cloud'] });
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

await runMain('scan.mjs', main);
