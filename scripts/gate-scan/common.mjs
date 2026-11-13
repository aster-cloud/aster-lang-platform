// scan.mjs 与 input-refs.mjs 共用的部件：错误与退出码、ts 构建与 lexicon 加载、静默编译、导出 JSONL 的读取与校验、
// 按 kind 的源计数与空导出判定。只用 Node 内建模块。
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const PREFERRED_LEXICONS = ['en-US', 'zh-CN', 'de-DE'];
const LOCALE_FILE = /^[a-z]{2}-[A-Z]{2}\.js$/;
const CONSOLE_METHODS = ['log', 'info', 'warn', 'error', 'debug', 'trace', 'dir', 'table'];
/** export-policy-sources.sql 产出的三种源；计数行按此顺序打印。 */
export const SOURCE_KINDS = ['cloud-policy', 'cloud-policy-version', 'api-policy-version'];

export class ScanError extends Error {
  constructor(message, exitCode) {
    super(message);
    this.exitCode = exitCode;
  }
}
export const usageError = message => new ScanError(message, 2);
export const invalidInput = message => new ScanError(message, 3);

/** 接受 dist 目录或仓库根目录，返回含 src/browser.js 的 dist 绝对路径。 */
export function resolveDist(path) {
  const abs = resolve(path);
  if (existsSync(join(abs, 'src/browser.js'))) return abs;
  if (existsSync(join(abs, 'dist/src/browser.js'))) return join(abs, 'dist');
  throw usageError(`${path} 不是 aster-lang-ts 构建产物（找不到 src/browser.js 或 dist/src/browser.js）`);
}

export const importFrom = (dist, rel) => import(pathToFileURL(join(dist, rel)).href);

/** dist 上一级的 package.json 版本（git worktree 构建与本地仓库都有）；缺失时为 unknown。 */
export function buildVersion(dist) {
  const pkgPath = join(dist, '../package.json');
  return existsSync(pkgPath) ? JSON.parse(readFileSync(pkgPath, 'utf8')).version : 'unknown';
}

/** 读取构建目录下所有 xx-YY.js 词法表；找不到 lexicon 导出的文件直接判为构建不可信。 */
export async function loadLexicons(dist) {
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
export const orderLexiconIds = ids => [
  ...PREFERRED_LEXICONS.filter(id => ids.includes(id)),
  ...ids.filter(id => !PREFERRED_LEXICONS.includes(id)).sort(),
];

/** 同步执行 fn，期间屏蔽 console 与 stdout/stderr 写入，防止被扫描代码打印源码。 */
export function silently(fn) {
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

/**
 * 读取一份带完成标记的导出 JSONL：每个非空行是 JSON 对象，恰有一行 {"_count": N} 且 N 等于数据行数。
 * toRow(row, where) 校验并转换数据行，不合格时返回 undefined（报错信息只含文件名与行号，不含行内容）。
 */
export function readJsonl(file, toRow) {
  if (!existsSync(file)) throw invalidInput(`${file} 不存在`);
  const rows = [];
  const markers = [];
  readFileSync(file, 'utf8').split('\n').forEach((line, index) => {
    if (!line.trim()) return;
    const where = `${file} 第 ${index + 1} 行`;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      throw invalidInput(`${where}不是合法 JSON`);
    }
    if (row && typeof row === 'object' && '_count' in row) {
      markers.push(row._count);
      return;
    }
    const converted = toRow(row, where);
    if (converted === undefined) throw invalidInput(`${where}字段不合要求`);
    rows.push(converted);
  });
  if (markers.length !== 1) {
    throw invalidInput(`${file} 应恰好有 1 行完成标记 {"_count": N}，实际 ${markers.length} 行——导出可能被截断`);
  }
  if (markers[0] !== rows.length) {
    throw invalidInput(`${file} 完成标记 _count=${markers[0]} 与实际行数 ${rows.length} 不符——导出被截断或损坏`);
  }
  return rows;
}

/** export-policy-sources.sql 的一行：{id, kind, content}，kind 必须是三种源之一。 */
function toSourceRow(row) {
  if (typeof row?.id !== 'string' || typeof row?.content !== 'string') return undefined;
  if (!SOURCE_KINDS.includes(row.kind)) return undefined;
  return { id: row.id, kind: row.kind, content: row.content };
}

/** 读取全部源导出；id 重复（同一份导出读了两次等）判为输入不可信。 */
export function readSources(files) {
  const sources = files.flatMap(file => readJsonl(file, toSourceRow));
  const seen = new Set();
  for (const { id } of sources) {
    if (seen.has(id)) throw invalidInput(`源 id 重复：${id}——同一份导出给了两次，或导出损坏`);
    seen.add(id);
  }
  return sources;
}

/**
 * 打印 `sources: cloud-policy=N cloud-policy-version=M api-policy-version=K`，再做空导出判定：
 * cloud 两种合计为 0 → 退出码 3（除非 allowEmptyCloud，仅供旧旗标 --allow-empty-db 的单边放行）；
 * api 为 0 → 退出码 3（除非 allowEmptyApi）。
 */
export function checkSourceCounts(sources, { allowEmptyApi = false, allowEmptyCloud = false } = {}) {
  const counts = Object.fromEntries(SOURCE_KINDS.map(kind => [kind, 0]));
  for (const { kind } of sources) counts[kind]++;
  console.log(`sources: ${SOURCE_KINDS.map(kind => `${kind}=${counts[kind]}`).join(' ')}`);
  if (counts['cloud-policy'] + counts['cloud-policy-version'] === 0 && !allowEmptyCloud) {
    throw invalidInput('cloud 源（cloud-policy + cloud-policy-version）为 0——导出有误（context / pod / 库名），扫描结果不可信');
  }
  if (counts['api-policy-version'] === 0 && !allowEmptyApi) {
    throw invalidInput('api 源（api-policy-version）为 0——确属预期（生产 policy_versions 今天为 0 行）请加 --allow-empty-api');
  }
  if (sources.length === 0) throw invalidInput('源合计为 0——空扫描不算通过');
  return counts;
}

/** 运行 main 并把结果写入 process.exitCode；意外崩溃只打印错误类型与消息，不打印可能夹带输入片段的堆栈。 */
export async function runMain(name, main) {
  try {
    process.exitCode = await main();
  } catch (error) {
    if (error instanceof ScanError) {
      console.error(`${name}: ${error.message}`);
      process.exitCode = error.exitCode;
    } else {
      console.error(`${name}: 意外错误 ${error?.name ?? 'Error'}: ${error?.message ?? String(error)}`);
      process.exitCode = 2;
    }
  }
}
