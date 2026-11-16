#!/usr/bin/env node
// 把 aster-lang-test 的全部 .aster 语料写成 gate-scan 导出格式，供门禁工具在不碰生产数据的前提下自测：
//   <out>/cloud.jsonl：{id, kind:"cloud-policy", content}，末行完成标记 {"_count": N}；
//   <out>/api.jsonl：只有 {"_count": 0}（对应生产 aster_api 为空，扫描时配 --allow-empty-api-db）。
// 用法：node corpus-to-jsonl.mjs <aster-lang-test 根> <输出目录>
import { readdirSync, readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
const [root, out] = process.argv.slice(2);
if (!root || !out) { console.error('用法：corpus-to-jsonl.mjs <aster-lang-test 根> <输出目录>'); process.exit(2); }
const files = [];
(function walk(d) {
  for (const e of readdirSync(d).sort()) {
    const p = join(d, e);
    if (statSync(p).isDirectory()) walk(p); else if (p.endsWith('.aster')) files.push(p);
  }
})(join(root, 'corpus'));
mkdirSync(out, { recursive: true, mode: 0o700 });
const lines = files.map(f => JSON.stringify({ id: relative(root, f), kind: 'cloud-policy', content: readFileSync(f, 'utf8') }));
lines.push(JSON.stringify({ _count: files.length }));
writeFileSync(join(out, 'cloud.jsonl'), lines.join('\n') + '\n', { mode: 0o600 });
writeFileSync(join(out, 'api.jsonl'), JSON.stringify({ _count: 0 }) + '\n', { mode: 0o600 });
console.log(`cloud.jsonl: ${files.length} sources; api.jsonl: 0`);
