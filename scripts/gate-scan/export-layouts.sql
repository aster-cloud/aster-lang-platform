-- 显示排版导出（gate-scan.sh export --with-layouts 自动调用）：供 layout-check.mjs 检查 ADR 0059 修订 5 L10 / ADR 0064
-- 转义规则会影响的存量排版（Wave D G5）。
-- 用法（只读查询；用后删除导出文件）：
--   aster-cloud 库：psql -X -At -v ON_ERROR_STOP=1 -d aster_cloud -v cloud=1 -f export-layouts.sql > cloud-layouts.jsonl
-- 只有 aster-cloud 存排版：aster-api 不落库（排版随导出请求 PackageExportRequest.layout 传入，ADR 0059 修订 4 D12），
-- 因此不带 -v cloud=1 时直接报错，避免对 aster_api 跑出一份「0 行」的假导出。
-- 数据来源：aster-cloud src/db/schema.ts 的 policyVersionLayouts（表 "PolicyVersionLayout"，迁移 drizzle/0068，ADR 0058 §7.2），
--   layout 列是 serializeLayout 的逐字节输出 {"v":1,"spans":[{"text"}|{"canonical","display"}]}。display 文本与 canonical
--   文本都不另外存列：二者是各 span 的 display / canonical 侧依次拼接（ts ./layout 的 toDisplay / toCanonical），由
--   layout-check.mjs 从 layout 推出，所以只导出 layout 原文。
-- 不导出源码（"PolicyVersion".content）：每行只有 {id, kind, lexicon, layout}——
--   id        cloudv:<PolicyVersion.id>（与 export-vocab.sql / export-policy-sources.sql 的版本 id 同形）
--   kind      cloud-policy-version-layout
--   lexicon   编译语言，与 export-vocab.sql 同法反推（cloud 版本没有 locale 列）：
--             1. envelope：对候选 locale 重算 sourceEnvelopeSha256；
--             2. 否则取冻结快照引用的唯一 locale；
--             3. 否则为 NULL（layout-check.mjs 打印为 ?）。
--   layout    "PolicyVersionLayout".layout 原文（文本，解析交给 layout-check.mjs）
-- 较新迁移才有的 "PolicyVersion" 列（sourceScopesJson 等）经 to_jsonb(行) 读取，未迁移时读到 NULL。
-- "PolicyVersionLayout" 表本身必须存在：不存在说明连错了库或 cloud 版本过旧，导出失败（不当作 0 行）。
-- 最后一行是完成标记 {"_count" : N}，与数据行出自同一条语句（同一快照）。

\set QUIET on
\pset format unaligned
\pset tuples_only on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

\if :{?cloud}
WITH cand(tag, lexicon) AS (
  -- aster-cloud RECORDED_LOCALE_CANDIDATES：CNL_LOCALES 及其短码
  VALUES ('en-US', 'en-US'), ('zh-CN', 'zh-CN'), ('de-DE', 'de-DE'), ('hi-IN', 'hi-IN'),
         ('en', 'en-US'), ('zh', 'zh-CN'), ('de', 'de-DE'), ('hi', 'hi-IN')
),
ver AS (
  SELECT pv.id, to_jsonb(pv) AS j, l.layout
    FROM "PolicyVersionLayout" l
    JOIN "PolicyVersion" pv ON pv.id = l."policyVersionId"
),
env AS (
  SELECT ver.id, min(cand.lexicon) AS lexicon
    FROM ver
   CROSS JOIN cand
   CROSS JOIN LATERAL (
     SELECT DISTINCT s FROM unnest(ARRAY[ver.j->>'content', coalesce(ver.j->>'source', ver.j->>'content')]) AS u(s)
   ) src
   CROSS JOIN LATERAL (
     -- 每段 `<UTF-8 字节数>:<内容>|`，NULL 记为空串（policy-alias.ts lengthPrefixedSha256）
     SELECT string_agg(octet_length(coalesce(f, ''))::text || ':' || coalesce(f, '') || '|', '' ORDER BY ord) AS framed
       FROM unnest(
              ARRAY[src.s, ver.j->>'aliasSet', cand.tag, ver.j->>'sourceToolchainId']
              || CASE WHEN ver.j->>'sourceScopesJson' IS NOT NULL THEN ARRAY[ver.j->>'sourceScopesJson'] ELSE ARRAY[]::text[] END
            ) WITH ORDINALITY AS u(f, ord)
   ) frame
   WHERE ver.j->>'sourceEnvelopeSha256' = encode(sha256(convert_to(frame.framed, 'UTF8')), 'hex')
   GROUP BY ver.id
),
snap AS (
  SELECT ver.id,
         CASE WHEN count(DISTINCT nullif(ref.e->>'locale', '')) = 1 THEN min(nullif(ref.e->>'locale', '')) END AS locale
    FROM ver
   CROSS JOIN LATERAL jsonb_array_elements(
     CASE WHEN jsonb_typeof(ver.j->'vocabularySnapshotIds') = 'array' THEN ver.j->'vocabularySnapshotIds' ELSE '[]'::jsonb END
   ) AS ref(e)
   GROUP BY ver.id
),
src AS (
  SELECT json_build_object(
           'id', 'cloudv:' || ver.id,
           'kind', 'cloud-policy-version-layout',
           'lexicon', coalesce(env.lexicon, snap.locale),
           'layout', ver.layout
         )::text AS line
    FROM ver
    LEFT JOIN env ON env.id = ver.id
    LEFT JOIN snap ON snap.id = ver.id
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\else
DO $$ BEGIN RAISE EXCEPTION 'export-layouts.sql 只用于 aster_cloud 库（-v cloud=1）：aster-api 不存排版'; END $$;
\endif

COMMIT;
