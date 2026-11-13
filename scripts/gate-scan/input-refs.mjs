#!/usr/bin/env node
// 档案模块的规则输入引用清单（ADR 0046 §11.4 ⑦ 翻转前的生产只读扫描，X4 计划 Task P1）：用一个 aster-lang-ts
// 构建（≥ 1.5.0，Core IR 写 Func.inputRefs）编译生产策略源码，列出声明了 --profile 的模块中每条 Verdict 规则的
// inputRefs，标出 `*`（STAR，附 E708 的 construct）与 `""`（ROOT），并按需合入租户影响面与独立对账。
//
// 用法：
//   node input-refs.mjs --ts <ts dist> --profile <id> --sources <jsonl> [--sources <jsonl> ...]
//                       [--impact <jsonl> ...] [--profile-ids <jsonl>] [--allow-empty-api]
//
//   --ts           aster-lang-ts 构建产物目录（含 src/browser.js 的 dist；也接受仓库根）
//   --profile      只报告 Core IR profile 等于该 id 的模块；编译时注入「该档案 verifiedInputs 置 true」的注册表副本，
//                  以便取得 E708 的 construct
//   --sources      export-policy-sources.sql 的输出（同 scan.mjs）
//   --impact       export-profile-impact.sql 的输出，可重复：cloud 库行 {id, tenant, gatedExecutions30d}，
//                  aster_api 库行 {tenant, issuer, kid, enabled, notAfter}
//   --profile-ids  export-profile-ids.sql 的输出 {id}：按源码头部正则选出的「声明了档案」的 cloud id 集合，
//                  与本扫描「任一 lexicon 编译成功且 Core IR profile 非空」的 id 集合逐 id 比较
//   --allow-empty-api  允许 api-policy-version 源为 0（cloud 源为 0 一律退出码 3）
//
// lexicon：每份源依 en-US → zh-CN → de-DE → 其余（按名称）找第一个编译成功的 lexicon，只用它的结果。
// 金丝雀：启动时编译两份声明 --profile 的已知模块——字面路径规则的 IR 必须带 inputRefs ["context.amount"]
// （否则构建低于 1.5.0），动态 Map 键规则必须报 E708 dynamic-map-key（否则注册表注入无效）；任一不符即退出码 3。
// 编译期间屏蔽 console 与 stdout/stderr。输出只含 id、kind、lexicon、模块名、规则名、引用路径、租户 id 与计数，
// **绝不打印源码内容**。
//
// 退出码：0 = 无 STAR 规则；1 = 有 STAR 规则；2 = 用法错误或意外崩溃；
//         3 = 输入或构建不可信（导出损坏 / 截断 / 为空、金丝雀失败、影响面缺行）；4 = 对账不等（G3 不通过）。
import { parseArgs } from 'node:util';
import {
  buildVersion, checkSourceCounts, importFrom, invalidInput, loadLexicons, orderLexiconIds, readJsonl, readSources,
  resolveDist, runMain, silently, usageError,
} from './common.mjs';

// 与档案 id 形态一致（ts governance/controls.ts PROFILE_ID），同时保证可以安全拼进金丝雀源码
const PROFILE_ID = /^[a-z][a-z0-9-]{0,63}$/;
const STAR = '*';
const ROOT = '';
// 单列汇总的 construct（ADR 0046 §11.6 第 16 条的裁定依据）
const WHOLE_INPUT = 'whole-input-serialized';
const EXIT_STAR = 1;
const EXIT_RECONCILE = 4;

const canaryHead = profile => [
  'Module gate.canary.',
  `Profile "${profile}".`,
  '',
  'Define GuardContext has amount as Decimal, tier as Text, band as Text, meta as Map Text to Text.',
  'Define GuardRequest has principal_roles as List of Text, action as Text, context as GuardContext.',
  '',
  '@id("R-1")',
  '@control("EU_AI_ACT:ART14")',
  'Rule decide given req as GuardRequest, produce Verdict:',
].join('\n');
const CANARY_LITERAL = profile => `${canaryHead(profile)}
  If req.context.amount at least 50000:
    Return Verdict.escalate("large").
  Return Verdict.allow().
`;
const CANARY_DYNAMIC = profile => `${canaryHead(profile)}
  Let k be req.action.
  If Maybe.withDefault(Map.get(req.context.meta, k), "") equals to "EU":
    Return Verdict.escalate("eu").
  Return Verdict.allow().
`;

function parseCli() {
  let values;
  try {
    ({ values } = parseArgs({
      options: {
        ts: { type: 'string' },
        profile: { type: 'string' },
        sources: { type: 'string', multiple: true },
        impact: { type: 'string', multiple: true },
        'profile-ids': { type: 'string' },
        'allow-empty-api': { type: 'boolean' },
        help: { type: 'boolean', short: 'h' },
      },
      strict: true,
    }));
  } catch (error) {
    throw usageError(error.message);
  }
  if (values.help) return { help: true };
  if (!values.ts) throw usageError('缺少 --ts');
  if (!values.profile) throw usageError('缺少 --profile');
  if (!PROFILE_ID.test(values.profile)) throw usageError(`--profile 不是合法档案 id：${JSON.stringify(values.profile)}`);
  if (!values.sources?.length) throw usageError('缺少 --sources');
  return values;
}

/** 加载构建，并构造「--profile 的 verifiedInputs 置 true」的注册表；构建缺少所需导出即不可信。 */
async function loadBuild(path, profile) {
  const dist = resolveDist(path);
  const ts = await importFrom(dist, 'src/browser.js');
  for (const name of ['compileAndTypecheck', 'controlRegistryFrom']) {
    if (typeof ts[name] !== 'function') throw invalidInput(`构建 ${dist} 没有导出 ${name}()——需要 aster-lang-ts ≥ 1.5.0`);
  }
  if (!Array.isArray(ts.CONTROLS_REGISTRY?.profiles)) {
    throw invalidInput(`构建 ${dist} 没有导出带 profiles 的 CONTROLS_REGISTRY——需要 aster-lang-ts ≥ 1.5.0`);
  }
  const data = structuredClone(ts.CONTROLS_REGISTRY);
  const def = data.profiles.find(p => p?.id === profile);
  if (!def) {
    const known = data.profiles.map(p => p?.id).join(', ');
    throw usageError(`构建的注册表 ${data.version} 没有档案 ${profile}（已登记：${known}）`);
  }
  def.requires = { ...def.requires, verifiedInputs: true };
  const lexicons = await loadLexicons(dist);
  const build = {
    dist, ts, lexicons, version: buildVersion(dist), registryVersion: data.version,
    lexiconIds: orderLexiconIds([...lexicons.keys()]), controls: ts.controlRegistryFrom(data),
  };
  checkCanaries(build, profile);
  return build;
}

/** 编译一次；抛异常与编译失败同样视为「此 lexicon 不可用」。 */
function compileWith(build, source, lexicon) {
  try {
    const result = silently(() => build.ts.compileAndTypecheck(source, { lexicon, controls: build.controls }));
    return result?.success === true && result.core ? result : undefined;
  } catch {
    return undefined;
  }
}

const verdictRules = core => (core.decls ?? []).filter(d => d?.kind === 'Func' && Array.isArray(d.inputRefs));
const e708Construct = (result, rule) =>
  (result.typeErrors ?? []).find(e => e?.code === 'E708' && e?.data?.rule === rule)?.data?.construct;

function checkCanaries(build, profile) {
  const lexicon = build.lexicons.get('en-US');
  if (!lexicon) throw invalidInput(`构建 ${build.dist} 没有 en-US lexicon，无法运行金丝雀`);
  const literal = compileWith(build, CANARY_LITERAL(profile), lexicon);
  const refs = literal?.core?.profile === profile ? verdictRules(literal.core).find(f => f.name === 'decide')?.inputRefs : undefined;
  if (JSON.stringify(refs) !== JSON.stringify(['context.amount'])) {
    throw invalidInput(`构建 ${build.dist}（${build.version}）的金丝雀模块 Core IR 没有 inputRefs ["context.amount"]——需要 aster-lang-ts ≥ 1.5.0，扫描结果不可信`);
  }
  const dynamic = compileWith(build, CANARY_DYNAMIC(profile), lexicon);
  if (!dynamic || e708Construct(dynamic, 'decide') !== 'dynamic-map-key') {
    throw invalidInput(`构建 ${build.dist} 的金丝雀动态键规则没有报 E708 dynamic-map-key——注入的注册表未生效，construct 不可信`);
  }
}

/** 依 lexicon 顺序找第一个编译成功的结果。 */
function firstCompiled(build, source) {
  for (const id of build.lexiconIds) {
    const result = compileWith(build, source, build.lexicons.get(id));
    if (result) return { lexicon: id, result };
  }
  return undefined;
}

const isNonEmptyString = v => typeof v === 'string' && v.length > 0;

/** 影响面行：cloud 库 {id, tenant, gatedExecutions30d} 或 aster_api 库 {tenant, issuer, kid, enabled, notAfter}。 */
function toImpactRow(row) {
  if (isNonEmptyString(row?.id)) {
    const tenantOk = row.tenant === null || isNonEmptyString(row.tenant);
    return tenantOk && Number.isSafeInteger(row.gatedExecutions30d) && row.gatedExecutions30d >= 0
      ? { type: 'policy', id: row.id, tenant: row.tenant, gated: row.gatedExecutions30d } : undefined;
  }
  if (isNonEmptyString(row?.tenant) && isNonEmptyString(row?.issuer) && isNonEmptyString(row?.kid)) {
    const notAfterOk = row.notAfter === null || (typeof row.notAfter === 'string' && !Number.isNaN(Date.parse(row.notAfter)));
    return typeof row.enabled === 'boolean' && notAfterOk
      ? { type: 'issuer', tenant: row.tenant, enabled: row.enabled, notAfter: row.notAfter } : undefined;
  }
  return undefined;
}

function readImpact(files) {
  const policies = new Map();
  const enabledTenants = new Set();
  const now = Date.now();
  for (const row of files.flatMap(file => readJsonl(file, toImpactRow))) {
    if (row.type === 'issuer') {
      if (row.enabled && (row.notAfter === null || Date.parse(row.notAfter) > now)) enabledTenants.add(row.tenant);
      continue;
    }
    if (policies.has(row.id)) throw invalidInput(`影响面导出 id 重复：${row.id}`);
    policies.set(row.id, row);
  }
  return { policies, enabledTenants };
}

function readProfileIds(file) {
  const ids = readJsonl(file, row => (isNonEmptyString(row?.id) ? row.id : undefined));
  const set = new Set(ids);
  if (set.size !== ids.length) throw invalidInput(`${file} 有重复 id`);
  return set;
}

/** 扫描全部源：返回报告行、档案模块、编译失败的 id，以及「IR profile 非空」的 id 集合（对账用）。 */
function scanSources(build, sources, profile) {
  const rules = [];
  const modules = [];
  const failed = [];
  const profiled = new Set();
  for (const row of sources) {
    const compiled = firstCompiled(build, row.content);
    if (!compiled) {
      failed.push(row.id);
      continue;
    }
    const { lexicon, result } = compiled;
    if (typeof result.core.profile === 'string' && result.core.profile !== '') profiled.add(row.id);
    if (result.core.profile !== profile) continue;
    const funcs = verdictRules(result.core);
    modules.push({ id: row.id, rules: funcs.length });
    for (const func of funcs) {
      const refs = func.inputRefs;
      const flag = refs.includes(STAR) ? 'STAR' : refs.includes(ROOT) ? 'ROOT' : '-';
      const construct = flag === 'STAR' ? (e708Construct(result, func.name) ?? 'unknown') : '-';
      rules.push({ id: row.id, kind: row.kind, lexicon, module: result.core.name, rule: func.name, refs, flag, construct });
    }
  }
  return { rules, modules, failed, profiled };
}

const fmtIds = ids => `[${[...ids].sort().join(',')}]`;

function printList(name, items) {
  console.log(`${name}: ${items.length}`);
  for (const item of items) console.log(`  ${item}`);
}

/** 按 construct 计数，whole-input-serialized 另起一行（即使为 0）。 */
function printStarSummary(rules) {
  const byConstruct = new Map();
  for (const r of rules.filter(r => r.flag === 'STAR')) byConstruct.set(r.construct, (byConstruct.get(r.construct) ?? 0) + 1);
  const total = [...byConstruct.values()].reduce((a, b) => a + b, 0);
  const detail = [...byConstruct].sort(([a], [b]) => a.localeCompare(b)).map(([c, n]) => `${c}=${n}`).join(', ');
  console.log(`star-rules: ${total}${detail ? ` (${detail})` : ''}`);
  console.log(`${WHOLE_INPUT}: ${byConstruct.get(WHOLE_INPUT) ?? 0}`);
  return total;
}

function impactColumns(impact, id) {
  if (!impact) return 'tenant=- gatedExecutions30d=- tenantHasEnabledIssuer=-';
  const row = impact.policies.get(id);
  const tenant = row.tenant ?? '-';
  const enabled = row.tenant === null ? '-' : impact.enabledTenants.has(row.tenant) ? 'yes' : 'no';
  return `tenant=${tenant} gatedExecutions30d=${row.gated} tenantHasEnabledIssuer=${enabled}`;
}

function printTenants(impact, modules) {
  if (!impact) {
    console.log('tenants: - (no --impact)');
    return;
  }
  const tenants = new Set(modules.map(m => impact.policies.get(m.id).tenant).filter(t => t !== null));
  const without = [...tenants].filter(t => !impact.enabledTenants.has(t)).length;
  console.log(`tenants: ${tenants.size} (without enabled issuer: ${without})`);
}

/** 对账：返回是否相等；未给 --profile-ids 时标为 SKIPPED（不能用于 G3）。 */
function printReconcile(sqlIds, scanIds) {
  if (!sqlIds) {
    console.log('reconcile: SKIPPED (no --profile-ids; not valid for G3)');
    return true;
  }
  const onlyInSql = [...sqlIds].filter(id => !scanIds.has(id));
  const onlyInScan = [...scanIds].filter(id => !sqlIds.has(id));
  console.log(`reconcile: sql=${sqlIds.size} scan=${scanIds.size} onlyInSql=${fmtIds(onlyInSql)} onlyInScan=${fmtIds(onlyInScan)}`);
  return onlyInSql.length === 0 && onlyInScan.length === 0;
}

async function main() {
  const args = parseCli();
  if (args.help) {
    console.log('用法：node input-refs.mjs --ts <ts dist> --profile <id> --sources <jsonl> [--sources <jsonl> ...] [--impact <jsonl> ...] [--profile-ids <jsonl>] [--allow-empty-api]');
    return 0;
  }
  const sources = readSources(args.sources);
  checkSourceCounts(sources, { allowEmptyApi: args['allow-empty-api'] });
  const impact = args.impact?.length ? readImpact(args.impact) : undefined;
  const sqlIds = args['profile-ids'] ? readProfileIds(args['profile-ids']) : undefined;
  const build = await loadBuild(args.ts, args.profile);

  const { rules, modules, failed, profiled } = scanSources(build, sources, args.profile);
  const missing = impact ? modules.filter(m => !impact.policies.has(m.id)).map(m => m.id) : [];
  if (missing.length) throw invalidInput(`影响面导出缺少档案模块 ${fmtIds(missing)}——导出之间源集合有变化，重新导出`);

  console.log(`input-refs scan: ts=${build.version} (${build.dist})`);
  console.log(`profile: ${args.profile} (verifiedInputs forced true on registry ${build.registryVersion})`);
  console.log(`lexicons tried: ${build.lexiconIds.join(', ')}`);
  printList('compile-failed', failed);
  printList('input-refs', rules.map(r =>
    `${r.id} kind=${r.kind} lexicon=${r.lexicon} module=${r.module} rule=${r.rule} inputRefs=${JSON.stringify(r.refs)} `
    + `flags=${r.flag} construct=${r.construct} ${impactColumns(impact, r.id)}`));
  printList('modules-without-verdict-rules', modules.filter(m => m.rules === 0).map(m => m.id));
  console.log(`modules: ${modules.length}`);
  console.log(`rules: ${rules.length}`);
  const stars = printStarSummary(rules);
  console.log(`root-rules: ${rules.filter(r => r.flag === 'ROOT').length}`);
  printTenants(impact, modules);
  const reconciled = printReconcile(sqlIds, profiled);
  if (!reconciled) {
    console.log(`result: RECONCILE-MISMATCH (${stars} STAR rules)`);
    return EXIT_RECONCILE;
  }
  console.log(`result: ${stars === 0 ? 'PASS' : 'STAR'} (${stars} STAR rules)`);
  return stars === 0 ? 0 : EXIT_STAR;
}

await runMain('input-refs.mjs', main);
