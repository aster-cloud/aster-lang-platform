#!/usr/bin/env bash
# 判定「本次变更是否只动了仓库文档」，供各仓 CI / 部署 workflow 跳过重活。
#
# 为什么不用 workflow 级 paths-ignore：被整体跳过的 workflow 不产出任何检查，分支保护登记的
# 必需检查永远不报告，PR 卡在 BLOCKED；main 上也就没有「CI 通过」的 run，发布门禁
# require-main-ci-green 拦车。所以 workflow 照常触发，由本脚本在第一个 job 里给出结论，
# 重活按结论跳过，必需检查照样以 success 收尾。
#
# ── 比较区间（head 相对哪个 base）────────────────────────────────────────
#   pull_request / pull_request_target：base = PR 的 base.sha，head = PR 的 head.sha，
#     走 compare 的三点语义（merge-base..head）＝ 这个 PR 自己带来的改动。
#   push / workflow_run：必须配置「基线」（BASELINE_WORKFLOW + BASELINE_JOBS），
#     base = 该 workflow 在同一分支上**最近一次真正跑完重活且成功**的 run 的 head_sha。
#     判据：该 run 最新 attempt 满足 BASELINE_JOBS 的**每一行**——`<job 名 ERE>` 表示有名字匹配的
#     job 成功；`<job 名 ERE> :: <步骤名>` 还要求该 job 里这一步成功（job 内按步骤跳过、job 仍
#     success 的场景，如部署的 stale 闸门、docs-only 跳过的构建步骤）。docs-only 跳过的 job / 步骤
#     是 skipped，不会被当成基线；run 整体结论不看（非必需 job 的红不影响「重活已验证」）。
#     并要求 head 严格领先于 base。
#     ★为什么不用 push 事件的 before：
#       - 发布门禁认「main CI 对 SHA X 通过」。代码提交 A 的 CI 红了，紧跟一个 docs 提交 B，
#         若 B 只和 A 比，B 的 CI 会「空跑成功」，门禁据此放行一个含红代码的 commit。
#       - 部署：A 的部署被 concurrency 挤掉（pending 被取消）或判过时跳过，B 若只和 A 比就不部署，
#         A 的代码永远不上线（aster-api deploy.yml 文件头记录的死角）。
#     和「最近一次真正验证 / 部署过的 commit」比，上面两种情况的 diff 都含代码 → 完整运行。
#     未配置基线的 push → 一律完整运行。
#   其它事件（tag、workflow_dispatch、schedule、merge_group …）→ 一律完整运行。
#   BASE / HEAD 显式给出时覆盖上面的推导（BASE 支持 `<sha>~1` 这类 compare 认的写法）。
#
# ── 什么算文档（保守：任何不认识的文件 = 不是文档 = 完整运行）─────────────
#   先看「绝不算文档」：DEFAULT_NON_DOCS + NON_DOCS（调用方追加，如随 npm 包发布的 README/CHANGELOG、
#   被测试读取的 markdown）。命中即整个变更不是 docs-only。
#   再看「文档」：DEFAULT_DOCS + EXTRA_DOCS。每个文件都命中才是 docs-only。
#   模式是 bash `[[ path == pattern ]]` 的 glob：`*` 可以跨越 `/`（所以 `docs/*` 覆盖整棵 docs 树，
#   `*.md` 覆盖任意深度）。重命名同时检查新旧两个路径。
#   空 diff、文件数达到 compare 上限（300）、任何 API 失败 → 完整运行（fail-safe）。
#
# 输入（env）：
#   GH_TOKEN                contents:read；用基线时还要 actions:read
#   DOCS_REPO               owner/name（缺省 ${GITHUB_REPOSITORY}）
#   GITHUB_EVENT_NAME / GITHUB_EVENT_PATH / GITHUB_REF / GITHUB_SHA  runner 自带
#   BASE / HEAD             可选，覆盖推导
#   BASELINE_WORKFLOW       基线 workflow 文件名（如 ci.yml）
#   BASELINE_JOBS           换行分隔，每行 `<job 名 ERE>` 或 `<job 名 ERE> :: <步骤名>`（ERE 用 jq test，
#                           整名匹配请自带 ^$；步骤名精确匹配）
#   BASELINE_MAX_RUNS       最多回看多少个已完成的 run，缺省 30
#   BASELINE_SHA_FROM       基线 commit 取自 run 的哪里：head_sha（缺省）或 title（run 标题里最后一个
#                           40 位 SHA）。workflow_run 触发的 run，其 head_sha 是**触发时默认分支的 tip**，
#                           不一定是它实际部署的 commit——这类 workflow 用 run-name 写出实际 commit，再用 title。
#   EXTRA_DOCS / NON_DOCS   换行分隔的追加模式
# 输出（追加到 ${GITHUB_OUTPUT}）：docs-only=true|false、base、head、reason
# 退出码：恒为 0（判不出来就是 false），只有输入非法才非 0。
set -euo pipefail

REPO="${DOCS_REPO:-${GITHUB_REPOSITORY:-}}"
EVENT="${GITHUB_EVENT_NAME:-}"
EVENT_PATH="${GITHUB_EVENT_PATH:-/dev/null}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
MAX_RUNS="${BASELINE_MAX_RUNS:-30}"
SHA_FROM="${BASELINE_SHA_FROM:-head_sha}"
COMPARE_FILE_CAP=300

DEFAULT_DOCS='docs/*
*.md
*.markdown
LICENSE
LICENSE.*
LICENSE-*
LICENCE
LICENCE.*
NOTICE
NOTICE.*
.github/ISSUE_TEMPLATE/*'

# 源码 / 测试 / 资源 / 站点内容树下的任何文件都不算文档，哪怕是 .md（可能被构建、测试或产品读取）。
DEFAULT_NON_DOCS='src/*
*/src/*
test/*
*/test/*
tests/*
*/tests/*
__tests__/*
*/__tests__/*
fixtures/*
*/fixtures/*
resources/*
*/resources/*
corpus/*
*/corpus/*
content/*
*/content/*
messages/*
*/messages/*
public/*
*/public/*
app/*
*/app/*'

log() { echo "[docs-only] $*" >&2; }
emit() { echo "$1=$2" >>"$OUT"; }

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "::error::[docs-only] 仓库名非法：'$REPO'"; exit 1; }
[[ "$MAX_RUNS" =~ ^[1-9][0-9]{0,2}$ ]] || { echo "::error::[docs-only] BASELINE_MAX_RUNS 必须是 1–999：'$MAX_RUNS'"; exit 1; }
[[ "$SHA_FROM" =~ ^(head_sha|title)$ ]] || { echo "::error::[docs-only] BASELINE_SHA_FROM 只能是 head_sha / title：'$SHA_FROM'"; exit 1; }

BASE_OUT="" HEAD_OUT=""
# 给出结论并退出（恒 0）。
verdict() {  # true|false 原因
  emit docs-only "$1"
  emit base "$BASE_OUT"
  emit head "$HEAD_OUT"
  emit reason "$2"
  if [ "$1" = "true" ]; then
    log "docs-only：$2"
    echo "- 📄 docs-only（\`${BASE_OUT:0:12}...${HEAD_OUT:0:12}\`）：$2 → 跳过重活" >>"$SUMMARY"
  else
    log "完整运行：$2"
    echo "- 🔧 完整运行：$2" >>"$SUMMARY"
  fi
  exit 0
}

ev() { jq -r "$1 // empty" "$EVENT_PATH" 2>/dev/null || true; }

# ── 基线：最近一次真正跑完重活且成功的 run ─────────────────────────────────
find_baseline() {  # branch → 输出 head_sha，找不到返回 1
  local branch="$1" runs id sha jobs ok n=0
  [[ "$BASELINE_WORKFLOW" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || { log "BASELINE_WORKFLOW 非法：'$BASELINE_WORKFLOW'"; return 1; }
  runs=$(gh api --method GET "repos/$REPO/actions/workflows/$BASELINE_WORKFLOW/runs" \
           -f branch="$branch" -f status=completed -f per_page="$MAX_RUNS" 2>/dev/null) || { log "查询 $BASELINE_WORKFLOW 的 run 失败"; return 1; }
  while IFS=$'\t' read -r id sha; do
    [ -n "$id" ] || continue
    n=$((n+1))
    jobs=$(gh api "repos/$REPO/actions/runs/$id/jobs?filter=latest&per_page=100" 2>/dev/null) || { log "查询 run $id 的 job 失败"; return 1; }
    ok=$(jq -r --arg spec "$BASELINE_JOBS" '
      . as $r
      | [$spec | split("\n")[] | select(test("\\S"))
         | (if test(" :: ") then (split(" :: ") | {j: (.[0] | gsub("^\\s+|\\s+$"; "")), s: (.[1:] | join(" :: ") | gsub("^\\s+|\\s+$"; ""))})
            else {j: gsub("^\\s+|\\s+$"; ""), s: ""} end)]
      | length > 0 and all(.[]; . as $c
          | [$r.jobs[]? | select((.name | test($c.j)) and .conclusion == "success")
              | select($c.s == "" or ([(.steps // [])[] | select(.name == $c.s and .conclusion == "success")] | length > 0))]
          | length > 0)' <<<"$jobs") || ok=false
    if [ "$ok" = "true" ]; then
      log "基线：$BASELINE_WORKFLOW run ${id}（${sha:0:12}，回看第 $n 个）"
      echo "$sha"; return 0
    fi
  done < <(jq -r --arg repo "$REPO" --arg br "$branch" --arg from "$SHA_FROM" '
      [.workflow_runs[]? | select(.head_branch == $br and .head_repository.full_name == $repo)]
      | sort_by(.id) | reverse | .[]
      | [.id, (if $from == "title" then ((.display_title // "") | [scan("[0-9a-f]{40}")] | last // "") else .head_sha end)]
      | select(.[1] != "") | @tsv' <<<"$runs")
  log "最近 $MAX_RUNS 个已完成 run 里没有满足基线条件的：$(tr '\n' ';' <<<"$BASELINE_JOBS")"
  return 1
}

# ── 推导 base / head ──────────────────────────────────────────────────────
MODE=pr
case "$EVENT" in
  pull_request|pull_request_target)
    BASE_OUT="${BASE:-$(ev .pull_request.base.sha)}"
    HEAD_OUT="${HEAD:-$(ev .pull_request.head.sha)}" ;;
  push|workflow_run)
    MODE=baseline
    if [ "$EVENT" = "push" ]; then
      [[ "${GITHUB_REF:-}" == refs/heads/* ]] || verdict false "push 的不是分支（${GITHUB_REF:-?}）"
      BRANCH="${GITHUB_REF#refs/heads/}"
      HEAD_OUT="${HEAD:-${GITHUB_SHA:-}}"
    else
      BRANCH="$(ev .workflow_run.head_branch)"
      HEAD_OUT="${HEAD:-$(ev .workflow_run.head_sha)}"
    fi
    if [ -n "${BASE:-}" ]; then
      BASE_OUT="$BASE"
    else
      [ -n "${BASELINE_WORKFLOW:-}" ] && [ -n "$(tr -d '[:space:]' <<<"${BASELINE_JOBS:-}")" ] \
        || verdict false "$EVENT 事件未配置基线（baseline-workflow / baseline-jobs），不能证明之前的改动已验证"
      BASE_OUT=$(find_baseline "$BRANCH") || verdict false "找不到 $BRANCH 上真正跑过且成功的基线 run"
    fi ;;
  *)
    if [ -n "${BASE:-}" ] && [ -n "${HEAD:-}" ]; then
      BASE_OUT="$BASE"; HEAD_OUT="$HEAD"
    else
      verdict false "事件 ${EVENT:-?} 一律完整运行"
    fi ;;
esac
[ -n "$BASE_OUT" ] && [ -n "$HEAD_OUT" ] || verdict false "推导不出比较区间（base='$BASE_OUT' head='$HEAD_OUT'）"
[[ "$BASE_OUT$HEAD_OUT" =~ ^[0-9A-Za-z._~^/-]+$ ]] || verdict false "比较区间含非法字符"
[[ "$BASE_OUT" =~ ^0+$ ]] && verdict false "base 是全零 SHA（新建分支）"

# ── 取变更文件 ────────────────────────────────────────────────────────────
CMP=$(gh api "repos/$REPO/compare/${BASE_OUT}...${HEAD_OUT}" 2>/dev/null) || verdict false "compare ${BASE_OUT}...${HEAD_OUT} 查询失败"
STATUS=$(jq -r '.status // empty' <<<"$CMP")
if [ "$MODE" = "baseline" ]; then
  # 基线必须是 head 的祖先：diverged（force-push / 回滚）时三点 diff 会漏掉基线上有、head 上没有的代码。
  [ "$STATUS" = "ahead" ] || verdict false "head 不严格领先基线（compare status=${STATUS:-?}）"
fi
COUNT=$(jq -r '(.files // []) | length' <<<"$CMP")
[ "$COUNT" -gt 0 ] || verdict false "没有变更文件"
[ "$COUNT" -lt "$COMPARE_FILE_CAP" ] || verdict false "变更文件数达到 compare 上限 ${COMPARE_FILE_CAP}，无法看全"

# ── 分类 ──────────────────────────────────────────────────────────────────
NON_DOCS_ALL="$DEFAULT_NON_DOCS"$'\n'"${NON_DOCS:-}"
DOCS_ALL="$DEFAULT_DOCS"$'\n'"${EXTRA_DOCS:-}"
matches() {  # path 模式列表
  local p
  while IFS= read -r p; do
    p="${p%$'\r'}"
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] || continue
    # shellcheck disable=SC2053  # 有意按 glob 匹配
    [[ "$1" == $p ]] && return 0
  done <<<"$2"
  return 1
}
while IFS= read -r f; do
  [ -n "$f" ] || continue
  matches "$f" "$NON_DOCS_ALL" && verdict false "$f 不算文档（源码 / 测试 / 制品内容）"
  matches "$f" "$DOCS_ALL" || verdict false "$f 不是文档"
done < <(jq -r '.files[] | .filename, (.previous_filename // empty)' <<<"$CMP")
verdict true "$COUNT 个文件全是文档"
