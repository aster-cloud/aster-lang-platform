-- input-refs 子命令的影响面导出（gate-scan.sh input-refs 自动调用）：每行一个 JSON 对象，只含 id / 租户 / 计数，不含源码。
-- 用法（只读查询；用后删除导出文件）：
--   aster-cloud 库：psql -X -At -v ON_ERROR_STOP=1 -d aster_cloud -v cloud=1 -f export-profile-impact.sql > cloud-impact.jsonl
--   aster-api 库：  psql -X -At -v ON_ERROR_STOP=1 -d aster_api            -f export-profile-impact.sql > api-impact.jsonl
-- 设置了 cloud 变量时：选取条件与 export-policy-sources.sql 相同（"Policy" 未删除且 content 非空；"PolicyVersion"
--   content 非空），每行 {"id":"cloud:<policyId>"|"cloudv:<versionId>","tenant":<teamId，个人策略为 userId；
--   版本所属策略行不存在时为 null>,"gatedExecutions30d":<近 30 天 decision 为 require_approval / escalate 的执行数>}。
--   cloud:<policyId> 计该策略全部执行；cloudv:<versionId> 只计该版本的执行（policyVersionRowId 等于版本 id，
--   或旧行该列为空而 policyVersion 等于版本号）。
-- 未设置 cloud 变量时：aster-api 的签名事实签发方 guard_fact_issuers，每行
--   {"tenant","issuer","kid","enabled","notAfter"}（不导出公钥）。
-- 最后一行是完成标记 {"_count" : N}，与数据行出自同一条语句（同一快照）。

\set QUIET on
\pset format unaligned
\pset tuples_only on
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;

\if :{?cloud}
WITH pol AS (
  SELECT 'cloud:' || p.id AS id, p.id AS policy_id, COALESCE(p."teamId", p."userId") AS tenant,
         NULL::text AS version_id, NULL::integer AS version
    FROM "Policy" p
   WHERE p."deletedAt" IS NULL
     AND p.content IS NOT NULL
  UNION ALL
  SELECT 'cloudv:' || v.id, v."policyId", COALESCE(p."teamId", p."userId"), v.id, v.version
    FROM "PolicyVersion" v
    LEFT JOIN "Policy" p ON p.id = v."policyId"
   WHERE v.content IS NOT NULL
),
src AS (
  SELECT json_build_object(
           'id', pol.id,
           'tenant', pol.tenant,
           'gatedExecutions30d', (
             SELECT count(*)
               FROM "Execution" e
              WHERE e."policyId" = pol.policy_id
                AND e."createdAt" >= now() - interval '30 days'
                AND e.decision IN ('require_approval', 'escalate')
                AND (pol.version_id IS NULL
                     OR e."policyVersionRowId" = pol.version_id
                     OR (e."policyVersionRowId" IS NULL AND e."policyVersion" = pol.version))
           )
         )::text AS line
    FROM pol
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\else
WITH src AS (
  SELECT json_build_object(
           'tenant', i.tenant_id,
           'issuer', i.issuer,
           'kid', i.kid,
           'enabled', i.enabled,
           'notAfter', i.not_after
         )::text AS line
    FROM guard_fact_issuers i
)
SELECT line FROM (
  SELECT line, 0 AS ord FROM src
  UNION ALL
  SELECT json_build_object('_count', count(*))::text, 1 FROM src
) t
ORDER BY ord;
\endif

COMMIT;
