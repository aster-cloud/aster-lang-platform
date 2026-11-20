-- 词汇与别名导出（gate-scan.sh export --with-vocab 自动调用）：供 vocab-check.mjs 检查字面量触发词 / 别名与关键词的碰撞。
-- 用法（只读查询；用后删除导出文件）：
--   aster-api 库：psql -X -At -v ON_ERROR_STOP=1 -d aster_api   -f export-vocab.sql > api-vocab.jsonl
--   aster-cloud 库：psql -X -At -v ON_ERROR_STOP=1 -d aster_cloud -v cloud=1 -f export-vocab.sql > cloud-vocab.jsonl
-- 不导出源码：每行 {id, kind, lexicon, lexiconFrom, aliasSet, embedded, vocabularies}，只含检查需要的字段——
--   aliasSet      版本冻结的别名集原文（JSON 文本 kind→[别名,...]，可为 NULL；文本列，解析交给 vocab-check.mjs）
--   embedded      cloud 版本内嵌词汇原文（JSON 文本 {v, terms:[{kind, localized, canonical, parent?}]}，ADR 0060 §6.1）
--   vocabularies  [{source, id, locale, found, literalTriggers, triggers, values}]：冻结词汇快照 / aster-api 冻结词汇 /
--                 作者与团队的现行词条，只投影触发词（localized 与 aliases[]）与规范名（canonical），不导出描述与元数据
-- 三种行：
--   cloudv:<PolicyVersion.id>     cloud-policy-version  aliasSet、embeddedVocabulary、vocabularySnapshotIds → UserVocabularySnapshot
--   cloudterm:<UserDomainTerm.id> cloud-domain-term     未删除、未归档的作者 / 团队词条（DomainTerm 的 localized / aliases / canonical）
--   api:<policy_versions.id>      api-policy-version    alias_set、vocabulary_json、locale
-- lexicon（编译语言）：cloud 版本没有 locale 列，按 aster-cloud src/lib/policy-version-locale.ts 的前两级反推——
--   1. envelope：对候选 locale 重算 sourceEnvelopeSha256（长度前缀分帧 SHA-256，sourceScopesJson 非 NULL 为 5 段，否则 4 段），
--      源码取 content 与 coalesce(source, content) 两种，相等者即保存时所用值（lexiconFrom = "envelope"）；
--   2. 冻结快照引用的 locale 唯一时取之（lexiconFrom = "snapshot"）；
--   3. 否则为 NULL（第 3 级是按源码关键词识别，不在导出里做；vocab-check.mjs 对未知语言按全部 locale 从宽检查）。
-- 可选列（embeddedVocabulary、sourceScopesJson、vocabulary_json、locale 等较新迁移才有的列）一律经 to_jsonb(行) 读取：
-- 生产库若尚未迁移到该列，读到 NULL（=没有该数据），不会因列不存在而导出失败。
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
  SELECT pv.id, to_jsonb(pv) AS j FROM "PolicyVersion" pv
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
         jsonb_agg(jsonb_build_object(
           'source', 'snapshot',
           'id', ref.e->>'snapshotId',
           'locale', ref.e->>'locale',
           'found', s.id IS NOT NULL,
           'literalTriggers', coalesce(jsonb_path_query_array(s."vocabularyJson", 'lax $.literals[*].localized'), '[]')
                              || coalesce(jsonb_path_query_array(s."vocabularyJson", 'lax $.literals[*].aliases[*]'), '[]'),
           'triggers', coalesce(jsonb_path_query_array(s."vocabularyJson", 'lax $.*[*].localized'), '[]')
                       || coalesce(jsonb_path_query_array(s."vocabularyJson", 'lax $.*[*].aliases[*]'), '[]'),
           'values', coalesce(jsonb_path_query_array(s."vocabularyJson", 'lax $.*[*].canonical'), '[]')
         ) ORDER BY ref.ord) AS vocabularies,
         CASE WHEN count(DISTINCT nullif(ref.e->>'locale', '')) = 1 THEN min(nullif(ref.e->>'locale', '')) END AS locale
    FROM ver
   CROSS JOIN LATERAL jsonb_array_elements(
     CASE WHEN jsonb_typeof(ver.j->'vocabularySnapshotIds') = 'array' THEN ver.j->'vocabularySnapshotIds' ELSE '[]'::jsonb END
   ) WITH ORDINALITY AS ref(e, ord)
    LEFT JOIN "UserVocabularySnapshot" s ON s.id = ref.e->>'snapshotId'
   GROUP BY ver.id
),
src AS (
  SELECT json_build_object(
           'id', 'cloudv:' || ver.id,
           'kind', 'cloud-policy-version',
           'lexicon', coalesce(env.lexicon, snap.locale),
           'lexiconFrom', CASE WHEN env.lexicon IS NOT NULL THEN 'envelope' WHEN snap.locale IS NOT NULL THEN 'snapshot' END,
           'aliasSet', ver.j->>'aliasSet',
           'embedded', ver.j->>'embeddedVocabulary',
           'vocabularies', coalesce(snap.vocabularies, '[]'::jsonb)
         )::text AS line
    FROM ver
    LEFT JOIN env ON env.id = ver.id
    LEFT JOIN snap ON snap.id = ver.id
  UNION ALL
  SELECT json_build_object(
           'id', 'cloudterm:' || u.id,
           'kind', 'cloud-domain-term',
           'lexicon', d.locale,
           'lexiconFrom', 'term',
           'aliasSet', NULL,
           'embedded', NULL,
           'vocabularies', jsonb_build_array(jsonb_build_object(
             'source', 'term',
             'id', d.id,
             'locale', d.locale,
             'found', true,
             'literalTriggers', CASE WHEN d.kind = 'literal'
                                     THEN jsonb_build_array(d.localized) || coalesce(jsonb_path_query_array(d.aliases, 'lax $[*]'), '[]')
                                     ELSE '[]'::jsonb END,
             'triggers', jsonb_build_array(d.localized) || coalesce(jsonb_path_query_array(d.aliases, 'lax $[*]'), '[]'),
             'values', jsonb_build_array(d.canonical)
           ))
         )::text
    FROM "UserDomainTerm" u
    JOIN "DomainTerm" d ON d.id = u."termId"
   WHERE u."deletedAt" IS NULL
     AND u."archivedAt" IS NULL
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\else
WITH ver AS (
  SELECT pv.id, to_jsonb(pv) AS j FROM policy_versions pv
),
src AS (
  SELECT json_build_object(
           'id', 'api:' || ver.id,
           'kind', 'api-policy-version',
           'lexicon', ver.j->>'locale',
           'lexiconFrom', CASE WHEN ver.j->>'locale' IS NOT NULL THEN 'column' END,
           'aliasSet', ver.j->>'alias_set',
           'embedded', NULL,
           'vocabularies', CASE WHEN jsonb_typeof(ver.j->'vocabulary_json') = 'object' THEN jsonb_build_array(jsonb_build_object(
             'source', 'frozen',
             'id', NULL,
             'locale', ver.j->'vocabulary_json'->>'locale',
             'found', true,
             'literalTriggers', coalesce(jsonb_path_query_array(ver.j->'vocabulary_json', 'lax $.literals[*].localized'), '[]')
                                || coalesce(jsonb_path_query_array(ver.j->'vocabulary_json', 'lax $.literals[*].aliases[*]'), '[]'),
             'triggers', coalesce(jsonb_path_query_array(ver.j->'vocabulary_json', 'lax $.*[*].localized'), '[]')
                         || coalesce(jsonb_path_query_array(ver.j->'vocabulary_json', 'lax $.*[*].aliases[*]'), '[]'),
             'values', coalesce(jsonb_path_query_array(ver.j->'vocabulary_json', 'lax $.*[*].canonical'), '[]')
           )) ELSE '[]'::jsonb END
         )::text AS line
    FROM ver
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\endif

COMMIT;
