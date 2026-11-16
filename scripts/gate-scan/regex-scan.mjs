#!/usr/bin/env node
// 门禁扫描的正则预筛（通用）：对导出里的每份源逐行跑一组 PCRE 规则，只打印 id / kind / 规则名，从不打印源码或命中的文本。
// 规则来自某次变更的 ADR / PR 列出的风险写法（例如 ADR 0056 修订 A3 §6），命中的 id 与 Java / ts 的 IR 差异交叉核对。
//
// - 规则文件：每条规则两行，「# <规则名> <说明>」+ 下一行正则（规则名为字母、数字、下划线）。空行忽略。
// - 正则是 PCRE（所有格量词、行内 (?i)、\p{..} 在 JS 里语义不同或不支持），所以匹配交给系统 perl
//   （同一进程，字符串按 UTF-8 解码，Unicode 语义），与 grep -P 一样逐行匹配（^ / $ 是行首行尾）。
//
// 用法：node regex-scan.mjs --rules <文件> --sources <jsonl> [--sources <jsonl> ...]
// 输出：每个命中一行 `hit <id> <kind> <规则名>`，`per-rule:` 计数，最后 `result: PASS|HITS (N hits, M ids)`。
// 退出码：0 无命中；1 有命中；2 用法错误；3 环境错误（规则文件 / 导出损坏、perl 失败）。
import { parseArgs } from 'node:util';
import { readFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const SOURCE_KINDS = ['api-policy-version', 'cloud-policy', 'cloud-policy-version'];

class EnvError extends Error {}

// perl 侧：第一行是规则 [[名, 正则], ...]，之后每行一份源 {"i": 序号, "c": 源码}；每个命中输出「序号\t规则名」。
const PERL = String.raw`
use strict; use warnings; use feature 'unicode_strings'; use JSON::PP;
binmode STDIN, ':raw'; binmode STDOUT, ':raw';
my $json = JSON::PP->new->utf8;
my $first = <STDIN>; defined $first or die "no rules\n";
my @rules = map { [ $_->[0], qr/$_->[1]/ ] } @{ $json->decode($first) };
print "READY\n";
while (my $line = <STDIN>) {
  my $row = $json->decode($line);
  my @lines = split /\n/, $row->{c}, -1;
  for my $r (@rules) {
    for my $l (@lines) { if ($l =~ $r->[1]) { print "$row->{i}\t$r->[0]\n"; last; } }
  }
}
print "DONE\n";
`;

/** 解析规则文件：每条规则 = 「# 名字 说明」+ 下一行正则。 */
function readRules(file) {
  if (!existsSync(file)) throw new EnvError(`规则文件不存在：${file}`);
  const lines = readFileSync(file, 'utf8').split('\n').filter(l => l.length);
  const rules = [];
  for (let i = 0; i < lines.length; i += 2) {
    const m = /^# (\w+)(\s|$)/.exec(lines[i]);
    if (!m || i + 1 >= lines.length || lines[i + 1].startsWith('#')) throw new EnvError(`规则文件第 ${i / 2 + 1} 条格式不对`);
    rules.push([m[1], lines[i + 1]]);
  }
  if (!rules.length) throw new EnvError(`规则文件没有任何规则：${file}`);
  if (new Set(rules.map(r => r[0])).size !== rules.length) throw new EnvError(`规则名重复：${file}`);
  return rules;
}

/** 读导出 JSONL 并校验完成标记（格式同 gate-scan 的 common.mjs）。 */
function readSources(files) {
  const rows = [];
  for (const file of files) {
    if (!existsSync(file)) throw new EnvError(`${file} 不存在`);
    const own = [];
    const markers = [];
    readFileSync(file, 'utf8').split('\n').forEach((line, n) => {
      if (!line.trim()) return;
      let row;
      try { row = JSON.parse(line); } catch { throw new EnvError(`${file} 第 ${n + 1} 行不是合法 JSON`); }
      if (row && typeof row === 'object' && '_count' in row) { markers.push(row._count); return; }
      if (typeof row?.id !== 'string' || typeof row?.content !== 'string' || !SOURCE_KINDS.includes(row.kind)) {
        throw new EnvError(`${file} 第 ${n + 1} 行字段不合要求`);
      }
      own.push({ id: row.id, kind: row.kind, content: row.content });
    });
    if (markers.length !== 1 || markers[0] !== own.length) {
      throw new EnvError(`${file} 完成标记缺失或与行数不符（markers=${markers.length}，rows=${own.length}）`);
    }
    rows.push(...own);
  }
  return rows;
}

function main() {
  const { values: args } = parseArgs({
    options: { rules: { type: 'string' }, sources: { type: 'string', multiple: true } },
    strict: true,
  });
  if (!args.rules || !args.sources?.length) {
    console.error('用法：regex-scan.mjs --rules <文件> --sources <jsonl> [--sources <jsonl> ...]');
    return 2;
  }
  const rules = readRules(args.rules);
  const sources = readSources(args.sources);
  const input = [JSON.stringify(rules), ...sources.map((s, i) => JSON.stringify({ i, c: s.content }))].join('\n') + '\n';
  const p = spawnSync('perl', ['-e', PERL], { input, maxBuffer: 1 << 28, stdio: ['pipe', 'pipe', 'pipe'] });
  const out = (p.stdout ?? Buffer.alloc(0)).toString('utf8').split('\n').filter(Boolean);
  // perl 的 stderr 可能含正则编译错误；只回显 perl 自己的行（不含源码：源码只经 stdin 传入，perl 不回显）。
  if (p.status !== 0 || out[0] !== 'READY' || out.at(-1) !== 'DONE') {
    throw new EnvError(`perl 匹配失败（exit=${p.status}）：${(p.stderr ?? '').toString().split('\n')[0]}`);
  }
  const hits = out.slice(1, -1).map(l => {
    const [i, rule] = l.split('\t');
    return { ...sources[Number(i)], rule };
  });
  const kinds = {};
  for (const s of sources) kinds[s.kind] = (kinds[s.kind] ?? 0) + 1;
  console.log(`regex-scan: ${sources.length} sources (${Object.entries(kinds).map(([k, n]) => `${k}=${n}`).join(' ') || 'none'})`);
  console.log(`rules: ${rules.map(r => r[0]).join(' ')} (PCRE via perl, per line)`);
  const perRule = Object.fromEntries(rules.map(r => [r[0], 0]));
  for (const h of hits) { perRule[h.rule]++; console.log(`hit ${h.id} ${h.kind} ${h.rule}`); }
  console.log(`per-rule: ${Object.entries(perRule).map(([k, n]) => `${k}=${n}`).join(' ')}`);
  const ids = new Set(hits.map(h => h.id)).size;
  console.log(`result: ${hits.length ? 'HITS' : 'PASS'} (${hits.length} hits, ${ids} ids)`);
  return hits.length ? 1 : 0;
}

try {
  process.exitCode = main();
} catch (e) {
  console.error(`regex-scan.mjs：${e instanceof EnvError ? '' : '意外错误 '}${e.message}`);
  process.exitCode = 3;
}
