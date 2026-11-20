#!/usr/bin/env node
// 词汇 / 别名碰撞检查：读 export-vocab.sql 的导出（gate-scan.sh export --with-vocab），按 vocab-rules/*.json 的规则
// 判定每个版本 / 词条的字面量触发词、词汇触发词与规范名、aliasSet 别名是否与给定拼写（或该版本自己的 aliasSet）折叠相等。
// 只打印 id / kind / lexicon / 规则名，从不打印触发词、别名、词汇内容或源码（报错信息也只含文件名与行号）。
//
// 规则文件（JSON）：{ description, refs, provenance, spellings: { "<locale>" | "*": [拼写, ...] }, rules: [{ name, subject, against }] }
//   subject  被检查的字符串：aliasSet（版本 aliasSet 的全部别名）、literalTriggers（literal 词条的 localized 与 aliases[]）、
//            triggers（任意种类词条的 localized 与 aliases[]）、values（词条的 canonical；literal 为展开后的字符串）
//   against  spellings：该记录语言的拼写并上 "*"；语言未知时取全部 locale 的拼写（从宽，lexicon 打印为 ?）
//            aliasSet：该记录自己的 aliasSet 别名
// 折叠相等：两侧先 NFC，再用带 u + i 标志的正则比较——JS 在 u 模式下按 Unicode 简单大小写折叠（CaseFolding C+S）比较，
// 与引擎 foldKey 同一口径（PR 正文以 PCRE (*UCP)(?i) 近似）。
//
// 无法检查的记录也会报告（退出码 1），任何一处形状不符都整条判为不可读，不跳过：unreadable_aliasSet（aliasSet 不是
// kind→[字符串] 的 JSON）、unreadable_embedded（内嵌词汇不符合 ADR 0060 §6.1：v=1、terms 每项有已知 kind 与字符串
// localized / canonical）、unreadable_vocabulary（快照 / 冻结词汇投影出非字符串的触发词或规范名）、missing_snapshot（引用的快照不存在）。
//
// 用法：node vocab-check.mjs --sources <cloud-vocab.jsonl> --sources <api-vocab.jsonl> [--rules <json> ...] [--allow-empty-api]
//       缺省 --rules 为 vocab-rules/ 下全部 *.json。
// 输出：records / lexicons / rules 计数行；每个命中一行 `hit <id> <kind> <lexicon> <规则名>`；`per-rule:`；`result: PASS|HITS (...)`。
// 退出码：0 无命中；1 有命中；2 用法错误；3 导出 / 规则文件损坏或导出为空。
import { parseArgs } from 'node:util';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { invalidInput, readJsonl, runMain, usageError } from './common.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const RULES_DIR = join(HERE, 'vocab-rules');
const KINDS = { 'cloud-policy-version': 'cloudv:', 'cloud-domain-term': 'cloudterm:', 'api-policy-version': 'api:' };
const LEXICONS = ['en-US', 'zh-CN', 'de-DE', 'hi-IN'];
const UNKNOWN = '?';
const SUBJECTS = new Set(['aliasSet', 'literalTriggers', 'triggers', 'values']);
const AGAINST = new Set(['spellings', 'aliasSet']);
const PROBLEM_RULES = ['unreadable_aliasSet', 'unreadable_embedded', 'unreadable_vocabulary', 'missing_snapshot'];
const EMBEDDED_KINDS = new Set(['struct', 'field', 'function', 'enum_value', 'literal']);

const nfc = s => s.normalize('NFC');
const isStringArray = value => Array.isArray(value) && value.every(v => typeof v === 'string');
const isObject = value => typeof value === 'object' && value !== null && !Array.isArray(value);

/** 折叠相等的匹配器（见文件头）：u 模式只允许转义语法字符，因此只转义它们。 */
function foldMatcher(words) {
  const list = [...new Set(words.map(nfc))];
  if (!list.length) return () => false;
  const re = new RegExp(`^(?:${list.map(w => w.replace(/[\\^$.*+?()[\]{}|/]/g, '\\$&')).join('|')})$`, 'iu');
  return s => re.test(nfc(s));
}

/** 导出里的语言标签 → 支持的 lexicon；短码按 aster-cloud RECORDED_LOCALE_CANDIDATES 映射；其余视为未知。 */
function normalizeLexicon(tag) {
  if (typeof tag !== 'string') return UNKNOWN;
  return LEXICONS.find(id => id === tag || id.split('-')[0] === tag) ?? UNKNOWN;
}

function readRuleFile(file) {
  if (!existsSync(file)) throw usageError(`规则文件不存在：${file}`);
  let doc;
  try {
    doc = JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    throw invalidInput(`规则文件不是合法 JSON：${file}`);
  }
  const bad = what => invalidInput(`规则文件 ${file}：${what}`);
  if (!isObject(doc) || !Array.isArray(doc.rules) || doc.rules.length === 0) throw bad('缺少非空 rules 数组');
  const spellings = doc.spellings ?? {};
  if (!isObject(spellings)) throw bad('spellings 必须是对象');
  for (const [locale, words] of Object.entries(spellings)) {
    if (locale !== '*' && !LEXICONS.includes(locale)) throw bad(`spellings 含未知 locale ${locale}`);
    if (!Array.isArray(words) || words.some(w => typeof w !== 'string' || !w)) throw bad(`spellings.${locale} 必须是非空字符串数组`);
  }
  const matchers = new Map();
  const spellingMatcher = lexicon => {
    if (!matchers.has(lexicon)) {
      const words = lexicon === UNKNOWN ? Object.values(spellings).flat() : [...(spellings[lexicon] ?? []), ...(spellings['*'] ?? [])];
      matchers.set(lexicon, foldMatcher(words));
    }
    return matchers.get(lexicon);
  };
  return doc.rules.map((rule, i) => {
    if (!isObject(rule) || typeof rule.name !== 'string' || !/^\w+$/.test(rule.name)) throw bad(`rules[${i}].name 只能含字母、数字、下划线`);
    if (!SUBJECTS.has(rule.subject)) throw bad(`${rule.name}.subject 未知`);
    if (!AGAINST.has(rule.against)) throw bad(`${rule.name}.against 未知`);
    if (rule.against === 'spellings' && Object.keys(spellings).length === 0) throw bad(`${rule.name} 需要 spellings`);
    const against = rule.against === 'spellings' ? record => spellingMatcher(record.lexicon) : record => record.aliasMatcher;
    return { name: rule.name, subject: rule.subject, against };
  });
}

function loadRules(files) {
  const paths = files.length ? files : defaultRuleFiles();
  const rules = paths.flatMap(readRuleFile);
  const names = rules.map(r => r.name);
  const clash = names.find((n, i) => names.indexOf(n) !== i || PROBLEM_RULES.includes(n));
  if (clash) throw invalidInput(`规则名重复或与保留名冲突：${clash}`);
  return rules;
}

function defaultRuleFiles() {
  if (!existsSync(RULES_DIR)) throw invalidInput(`缺少规则目录 ${RULES_DIR}`);
  const files = readdirSync(RULES_DIR).filter(f => f.endsWith('.json')).sort().map(f => join(RULES_DIR, f));
  if (!files.length) throw invalidInput(`${RULES_DIR} 没有规则文件`);
  return files;
}

const parseJson = text => {
  try {
    return { doc: JSON.parse(text) };
  } catch {
    return undefined;
  }
};

/** aliasSet 原文 → 全部别名；不是 kind→[字符串] 的 JSON 时返回 undefined（不丢弃任何元素）。 */
function parseAliasSet(text) {
  if (text === null || text === undefined) return [];
  const parsed = parseJson(text);
  if (!parsed || !isObject(parsed.doc) || !Object.values(parsed.doc).every(isStringArray)) return undefined;
  return Object.values(parsed.doc).flat();
}

/** 内嵌词汇的一项是否符合 §6.1（aliases 不属于格式，出现时也须是字符串数组，以免漏查）。 */
const validTerm = term => isObject(term) && EMBEDDED_KINDS.has(term.kind) && typeof term.localized === 'string'
  && typeof term.canonical === 'string' && (term.aliases === undefined || isStringArray(term.aliases));

/** 内嵌词汇原文（ADR 0060 §6.1）→ 触发词与规范名；任一处形状不符时返回 undefined。 */
function parseEmbedded(text) {
  const out = { literalTriggers: [], triggers: [], values: [] };
  if (text === null || text === undefined) return out;
  const parsed = parseJson(text);
  const doc = parsed?.doc;
  if (!isObject(doc) || doc.v !== 1 || !Array.isArray(doc.terms) || !doc.terms.every(validTerm)) return undefined;
  for (const term of doc.terms) {
    const triggers = [term.localized, ...(term.aliases ?? [])];
    out.triggers.push(...triggers);
    if (term.kind === 'literal') out.literalTriggers.push(...triggers);
    out.values.push(term.canonical);
  }
  return out;
}

/** 导出的一行 → 待检查记录（字段不合要求时返回 undefined，由 readJsonl 报文件与行号）。 */
function toRecord(row) {
  if (!isObject(row) || typeof row.id !== 'string' || !(row.kind in KINDS) || !row.id.startsWith(KINDS[row.kind])) return undefined;
  if (!Array.isArray(row.vocabularies) || !row.vocabularies.every(isObject)) return undefined;
  for (const field of ['aliasSet', 'embedded']) {
    if (row[field] !== null && row[field] !== undefined && typeof row[field] !== 'string') return undefined;
  }
  const problems = [];
  const aliasValues = parseAliasSet(row.aliasSet);
  if (aliasValues === undefined) problems.push('unreadable_aliasSet');
  const embedded = parseEmbedded(row.embedded);
  if (embedded === undefined) problems.push('unreadable_embedded');
  const record = {
    id: row.id,
    kind: row.kind,
    lexicon: normalizeLexicon(row.lexicon),
    aliasSet: aliasValues ?? [],
    literalTriggers: [...(embedded?.literalTriggers ?? [])],
    triggers: [...(embedded?.triggers ?? [])],
    values: [...(embedded?.values ?? [])],
    problems,
  };
  for (const vocab of row.vocabularies) {
    if (vocab.found === false) problems.push('missing_snapshot');
    const lists = ['literalTriggers', 'triggers', 'values'].map(key => vocab[key] ?? []);
    if (!lists.every(isStringArray)) {
      problems.push('unreadable_vocabulary');
      continue;
    }
    record.literalTriggers.push(...lists[0]);
    record.triggers.push(...lists[1]);
    record.values.push(...lists[2]);
  }
  record.problems = [...new Set(problems)];
  record.aliasMatcher = foldMatcher(record.aliasSet);
  return record;
}

function readRecords(files, allowEmptyApi) {
  const records = files.flatMap(file => readJsonl(file, toRecord));
  const seen = new Set();
  for (const { id } of records) {
    if (seen.has(id)) throw invalidInput(`记录 id 重复：${id}——同一份导出给了两次，或导出损坏`);
    seen.add(id);
  }
  const counts = Object.fromEntries(Object.keys(KINDS).map(kind => [kind, 0]));
  for (const { kind } of records) counts[kind]++;
  console.log(`records: ${Object.entries(counts).map(([k, n]) => `${k}=${n}`).join(' ')}`);
  const lexicons = Object.fromEntries([...LEXICONS, UNKNOWN].map(id => [id, 0]));
  for (const { lexicon } of records) lexicons[lexicon]++;
  console.log(`lexicons: ${Object.entries(lexicons).map(([k, n]) => `${k}=${n}`).join(' ')}`);
  if (counts['cloud-policy-version'] === 0) {
    throw invalidInput('cloud-policy-version 为 0——导出有误（context / pod / 库名），检查结果不可信');
  }
  if (counts['api-policy-version'] === 0 && !allowEmptyApi) {
    throw invalidInput('api-policy-version 为 0——确属预期（生产 policy_versions 今天为 0 行）请加 --allow-empty-api');
  }
  return records;
}

function check(records, rules) {
  const hits = [];
  for (const record of records) {
    for (const problem of record.problems) hits.push([record, problem]);
    for (const rule of rules) {
      const matches = rule.against(record);
      if (record[rule.subject].some(matches)) hits.push([record, rule.name]);
    }
  }
  return hits;
}

async function main() {
  let args;
  try {
    args = parseArgs({
      options: {
        sources: { type: 'string', multiple: true, default: [] },
        rules: { type: 'string', multiple: true, default: [] },
        'allow-empty-api': { type: 'boolean', default: false },
      },
    }).values;
  } catch (error) {
    throw usageError(error.message);
  }
  if (!args.sources.length) throw usageError('需要至少一个 --sources <jsonl>（cloud-vocab.jsonl 与 api-vocab.jsonl）');
  const rules = loadRules(args.rules);
  console.log(`rules: ${rules.map(r => r.name).join(' ')}（${(args.rules.length ? args.rules : defaultRuleFiles()).map(f => basename(f)).join(', ')}）`);
  const records = readRecords(args.sources, args['allow-empty-api']);
  const hits = check(records, rules);
  for (const [record, rule] of hits) console.log(`hit ${record.id} ${record.kind} ${record.lexicon} ${rule}`);
  const perRule = [...PROBLEM_RULES, ...rules.map(r => r.name)].map(name => `${name}=${hits.filter(([, r]) => r === name).length}`);
  console.log(`per-rule: ${perRule.join(' ')}`);
  const ids = new Set(hits.map(([record]) => record.id)).size;
  console.log(hits.length ? `result: HITS (${hits.length} hits, ${ids} ids)` : 'result: PASS (0 hits)');
  return hits.length ? 1 : 0;
}

await runMain('vocab-check', main);
