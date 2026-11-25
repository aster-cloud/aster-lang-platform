#!/usr/bin/env node
// 存量显示排版检查（Wave D G5）：读 export-layouts.sql 的导出（gate-scan.sh export --with-layouts），找出会被
// ADR 0059 修订 5 的 L10（隐藏转义定界符）或 ADR 0064 的转义规则影响的排版。
// 只打印 id / kind / lexicon / 规则名，从不打印排版、display 或 canonical 文本（报错信息也只含文件名与行号）。
//
// 排版按 ts ./layout 的 readLayout 口径解析：恰为 {v:1, spans:[...]}，spans 非空，每个 span 恰为内容 span {text}（非空串）或
// 结构 span {canonical（非空串）, display（串）}。canonical 文本 = 各 span 的 canonical 侧（内容 span 取 text）依次拼接，
// display 文本 = 各 span 的 display 侧依次拼接；内容 span 同时属于两侧。反引号指 U+0060，全角反引号指 U+FF40。
//
// 门禁规则（hit，退出码 1；期望 0）：
//   G5a_structural_backtick  结构 span 的 canonical 含反引号（L10a 第 2 条只允许恰为 "`" 且 display 为 "" 的三元组形状；
//                            今天任何这种 span 都会在 L10 上线后被重新判定）
//   G5b_display_backtick     结构 span 的 display 含反引号（L10a 第 1 条：结构 span 不能把任何东西显示成转义名）
//   unreadable_layout        layout 不是合法 JSON 或不符合上面的形状（整条不可检查，不静默跳过）
// 分诊规则（note，不影响退出码；逐条人工确认）：
//   content_backtick         内容 span 含反引号：canonical 与 display 文本里已有的反引号（今天只可能在字符串 / 注释里），
//                            E1 的转义不透明性（ADR 0064 §3–§5）必须让它们保持原义；L10a 第 6 条不限制它们
//   fullwidth_backtick       任何 span 的 canonical 或 display 含全角反引号 U+FF40：两个引擎的 canonicalizer 今天会把它
//                            折叠成反引号（Wave D 探针 F2），zh 的 ｀x｀ 不得成为转义定界符
//
// 用法：node layout-check.mjs --sources <cloud-layouts.jsonl> [--allow-empty]
// 输出：records / lexicons 计数行；每个门禁命中一行 `hit <id> <kind> <lexicon> <规则名>`，每个分诊项一行
//       `note <id> <kind> <lexicon> <规则名>`；`per-rule:`；`result: PASS|HITS (...)`。
// 退出码：0 无门禁命中；1 有门禁命中；2 用法错误；3 导出损坏，或导出为 0 行且未给 --allow-empty。
import { parseArgs } from 'node:util';
import { invalidInput, readJsonl, runMain, usageError } from './common.mjs';

const KIND = 'cloud-policy-version-layout';
const ID_PREFIX = 'cloudv:';
const LEXICONS = ['en-US', 'zh-CN', 'de-DE', 'hi-IN'];
const UNKNOWN = '?';
const BACKTICK = '`';
const FULLWIDTH_BACKTICK = '｀';
const GATE_RULES = ['unreadable_layout', 'G5a_structural_backtick', 'G5b_display_backtick'];
const NOTE_RULES = ['content_backtick', 'fullwidth_backtick'];

const isObject = value => typeof value === 'object' && value !== null && !Array.isArray(value);
const hasExactKeys = (obj, keys) => Object.keys(obj).length === keys.length && keys.every(k => Object.hasOwn(obj, k));

/** 导出里的语言标签 → 支持的 lexicon；短码按 aster-cloud RECORDED_LOCALE_CANDIDATES 映射；其余视为未知。 */
function normalizeLexicon(tag) {
  if (typeof tag !== 'string') return UNKNOWN;
  return LEXICONS.find(id => id === tag || id.split('-')[0] === tag) ?? UNKNOWN;
}

/** 一个 span → {content} 或 {canonical, display}；形状不符返回 undefined（与 ts readSpan 同口径）。 */
function readSpan(raw) {
  if (isObject(raw) && hasExactKeys(raw, ['text'])) {
    return typeof raw.text === 'string' && raw.text !== '' ? { content: raw.text } : undefined;
  }
  if (isObject(raw) && hasExactKeys(raw, ['canonical', 'display'])) {
    const ok = typeof raw.canonical === 'string' && raw.canonical !== '' && typeof raw.display === 'string';
    return ok ? { canonical: raw.canonical, display: raw.display } : undefined;
  }
  return undefined;
}

/** layout 原文 → span 列表；不是恰为 {v:1, spans:[非空]} 或任一 span 形状不符时返回 undefined。 */
function parseLayout(text) {
  let doc;
  try {
    doc = JSON.parse(text);
  } catch {
    return undefined;
  }
  if (!isObject(doc) || !hasExactKeys(doc, ['v', 'spans']) || doc.v !== 1 || !Array.isArray(doc.spans) || doc.spans.length === 0) {
    return undefined;
  }
  const spans = doc.spans.map(readSpan);
  return spans.every(Boolean) ? spans : undefined;
}

/** 一个排版命中的规则名（门禁与分诊混在一起，由调用方按名字分类）。 */
function layoutRules(spans) {
  if (spans === undefined) return ['unreadable_layout'];
  const structural = spans.filter(s => s.content === undefined);
  const texts = spans.flatMap(s => (s.content === undefined ? [s.canonical, s.display] : [s.content]));
  const rules = [];
  if (structural.some(s => s.canonical.includes(BACKTICK))) rules.push('G5a_structural_backtick');
  if (structural.some(s => s.display.includes(BACKTICK))) rules.push('G5b_display_backtick');
  if (spans.some(s => s.content?.includes(BACKTICK))) rules.push('content_backtick');
  if (texts.some(t => t.includes(FULLWIDTH_BACKTICK))) rules.push('fullwidth_backtick');
  return rules;
}

/** 导出的一行 → 待检查记录（字段不合要求时返回 undefined，由 readJsonl 报文件与行号）。 */
function toRecord(row) {
  if (!isObject(row) || row.kind !== KIND || typeof row.id !== 'string' || !row.id.startsWith(ID_PREFIX)) return undefined;
  if (typeof row.layout !== 'string') return undefined;
  return { id: row.id, kind: row.kind, lexicon: normalizeLexicon(row.lexicon), rules: layoutRules(parseLayout(row.layout)) };
}

function readRecords(files, allowEmpty) {
  const records = files.flatMap(file => readJsonl(file, toRecord));
  const seen = new Set();
  for (const { id } of records) {
    if (seen.has(id)) throw invalidInput(`记录 id 重复：${id}——同一份导出给了两次，或导出损坏`);
    seen.add(id);
  }
  console.log(`records: ${KIND}=${records.length}`);
  const lexicons = Object.fromEntries([...LEXICONS, UNKNOWN].map(id => [id, 0]));
  for (const { lexicon } of records) lexicons[lexicon]++;
  console.log(`lexicons: ${Object.entries(lexicons).map(([k, n]) => `${k}=${n}`).join(' ')}`);
  if (records.length === 0 && !allowEmpty) {
    throw invalidInput('排版记录为 0——确认生产确实没有保存过排版（同一次 export 的 cloud.jsonl 非空）后加 --allow-empty');
  }
  return records;
}

async function main() {
  let args;
  try {
    args = parseArgs({
      options: {
        sources: { type: 'string', multiple: true, default: [] },
        'allow-empty': { type: 'boolean', default: false },
      },
    }).values;
  } catch (error) {
    throw usageError(error.message);
  }
  if (!args.sources.length) throw usageError('需要至少一个 --sources <jsonl>（cloud-layouts.jsonl）');
  const records = readRecords(args.sources, args['allow-empty']);
  const found = records.flatMap(record => record.rules.map(rule => [record, rule]));
  const hits = found.filter(([, rule]) => GATE_RULES.includes(rule));
  const notes = found.filter(([, rule]) => NOTE_RULES.includes(rule));
  for (const [record, rule] of hits) console.log(`hit ${record.id} ${record.kind} ${record.lexicon} ${rule}`);
  for (const [record, rule] of notes) console.log(`note ${record.id} ${record.kind} ${record.lexicon} ${rule}`);
  const perRule = [...GATE_RULES, ...NOTE_RULES].map(name => `${name}=${found.filter(([, r]) => r === name).length}`);
  console.log(`per-rule: ${perRule.join(' ')}`);
  const ids = new Set(hits.map(([record]) => record.id)).size;
  console.log(hits.length
    ? `result: HITS (${hits.length} hits, ${ids} ids, ${notes.length} notes)`
    : `result: PASS (0 hits, ${notes.length} notes)`);
  return hits.length ? 1 : 0;
}

await runMain('layout-check', main);
