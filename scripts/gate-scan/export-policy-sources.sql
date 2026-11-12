-- 导出生产策略源码供门槛扫描（gate scan）使用：每行一个 JSON 对象 {"id", "kind", "content"}。
-- 用法（只读查询；用后删除导出文件）：
--   aster-api 库：psql -At -v ON_ERROR_STOP=1 -d aster_api   -f export-policy-sources.sql > api-sources.jsonl
--   aster-cloud 库：psql -At -v ON_ERROR_STOP=1 -d aster_cloud -v cloud=1 -f export-policy-sources.sql > cloud-sources.jsonl
-- 设置了 cloud 变量时导出 cloud 的 "Policy"（未删除）与 "PolicyVersion"；否则导出 aster-api 的 policy_versions。
-- id 带来源前缀（api: / cloud: / cloudv:），扫描结果只打印 id，不打印源码。

\set QUIET on
\pset format unaligned
\pset tuples_only on
BEGIN TRANSACTION READ ONLY;

\if :{?cloud}
SELECT json_build_object('id', 'cloud:' || p.id, 'kind', 'cloud-policy', 'content', p.content)
  FROM "Policy" p
 WHERE p."deletedAt" IS NULL
   AND p.content IS NOT NULL
UNION ALL
SELECT json_build_object('id', 'cloudv:' || v.id, 'kind', 'cloud-policy-version', 'content', v.content)
  FROM "PolicyVersion" v
 WHERE v.content IS NOT NULL;
\else
SELECT json_build_object('id', 'api:' || pv.id, 'kind', 'api-policy-version', 'content', pv.content)
  FROM policy_versions pv
 WHERE pv.content IS NOT NULL;
\endif

COMMIT;
