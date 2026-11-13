-- input-refs 子命令的独立对账集合（gate-scan.sh input-refs 自动调用；只用于 aster-cloud 库）：
-- 不经编译器，按源码头部正则选出「声明了治理档案」的 cloud 策略 / 版本 id，每行 {"id":"cloud:<policyId>"|"cloudv:<versionId>"}。
-- 用法（只读查询）：psql -X -At -v ON_ERROR_STOP=1 -d aster_cloud -v cloud=1 -f export-profile-ids.sql > profile-ids.jsonl
-- 选取条件与 export-policy-sources.sql 相同（"Policy" 未删除且 content 非空；"PolicyVersion" content 非空），再加：
--   某行（行首可有空格 / 制表符）以档案关键字开头，后跟可选空白与引号 " “ 「。
--   四个关键字取自 aster-lang-ts src/config/lexicons/*.ts 的 SemanticTokenKind.PROFILE：
--   en-US Profile、de-DE Profil、zh-CN 档案、hi-IN प्रोफ़ाइल（生产源码形如 Profile "eu-ai-act-high-risk". / 档案 "eu-ai-act-high-risk"。）。
-- input-refs.mjs 把它与「任一 lexicon 编译成功且 Core IR profile 非空」的 id 集合逐 id 比较，不等即退出码 4。
-- 最后一行是完成标记 {"_count" : N}，与数据行出自同一条语句（同一快照）。

\set QUIET on
\pset format unaligned
\pset tuples_only on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

\if :{?cloud}
WITH src AS (
  SELECT json_build_object('id', 'cloud:' || p.id)::text AS line
    FROM "Policy" p
   WHERE p."deletedAt" IS NULL
     AND p.content IS NOT NULL
     AND p.content ~ '(^|\n)[ \t]*(Profile|Profil|档案|प्रोफ़ाइल)[ \t]*["“「]'
  UNION ALL
  SELECT json_build_object('id', 'cloudv:' || v.id)::text
    FROM "PolicyVersion" v
   WHERE v.content IS NOT NULL
     AND v.content ~ '(^|\n)[ \t]*(Profile|Profil|档案|प्रोफ़ाइल)[ \t]*["“「]'
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\else
-- 未设置 cloud 变量：拒绝执行（aster-api 库没有这两张表），ON_ERROR_STOP 使 psql 非零退出
DO $$ BEGIN RAISE EXCEPTION 'export-profile-ids.sql 只用于 aster-cloud 库（-v cloud=1）'; END $$;
\endif

COMMIT;
