-- 导出生产策略源码供门槛扫描（gate scan）使用：每行一个 JSON 对象 {"id", "kind", "content"}。
-- 用法（只读查询；用后删除导出文件）：
--   aster-api 库：psql -X -At -v ON_ERROR_STOP=1 -d aster_api   -f export-policy-sources.sql > api.jsonl
--   aster-cloud 库：psql -X -At -v ON_ERROR_STOP=1 -d aster_cloud -v cloud=1 -f export-policy-sources.sql > cloud.jsonl
-- 设置了 cloud 变量时导出 cloud 的 "Policy"（未删除）与 "PolicyVersion"；否则导出 aster-api 的 policy_versions。
-- id 带来源前缀（api: / cloud: / cloudv:），扫描结果只打印 id，不打印源码。
-- 最后一行是完成标记 {"_count" : N}：N 与源行出自同一条语句（同一快照），
-- 扫描端据此校验导出没有被截断（行数不符即判失败）。

\set QUIET on
\pset format unaligned
\pset tuples_only on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

\if :{?cloud}
WITH src AS (
  SELECT json_build_object('id', 'cloud:' || p.id, 'kind', 'cloud-policy', 'content', p.content)::text AS line
    FROM "Policy" p
   WHERE p."deletedAt" IS NULL
     AND p.content IS NOT NULL
  UNION ALL
  SELECT json_build_object('id', 'cloudv:' || v.id, 'kind', 'cloud-policy-version', 'content', v.content)::text
    FROM "PolicyVersion" v
   WHERE v.content IS NOT NULL
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\else
WITH src AS (
  SELECT json_build_object('id', 'api:' || pv.id, 'kind', 'api-policy-version', 'content', pv.content)::text AS line
    FROM policy_versions pv
   WHERE pv.content IS NOT NULL
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\endif

COMMIT;
