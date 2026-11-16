#!/usr/bin/env bash
# 发布门禁（ADR 0053 修订 A2）：要发布的 commit 必须已经在 main 的 CI 上通过，发布时不再重跑测试。
#
# 「main CI 对 SHA X 通过」的定义（全部成立才放行）：
#   1. 取 <workflow> 在 event=push、head_branch=<branch>、head_sha=X、本仓（非 fork）下的 run，
#      多个时取 id 最大（最新）的一个；只看它，不在历史 run 里挑一个绿的。
#   2. 该 run 已结束（status=completed）。未结束（含正在重跑）就等，有界。
#   3. 读该 run **最新一次 attempt** 的 job：配置里列出的每个必需 job 都恰好出现一次且
#      conclusion=success。skipped / neutral / cancelled / failure / timed_out / 缺失 / 重名一律不算通过。
#      必需 job = 该仓 main 分支保护登记的必需检查（见各仓 .github/main-ci-gate.json）。
#      其它 job 失败只告警，不拦（它们本来也不拦合并）。
#   4. 重跑：GitHub 的重跑沿用同一个 run id，attempt 递增，所以「最新 attempt」自然覆盖
#      flake 后重跑变绿、或重跑变红两种情况。本脚本只在 GATE_RERUN_ONCE=true 时（列车 preflight，
#      持有 Actions 写权限）对 run_attempt==1 的红 run 自动 `rerun --failed` 一次；发布 workflow
#      里只读，不重跑。
#
# 逃生口：tag 是 annotated tag 且消息里有一行恰为 `release-gate: force-tests`，或 GATE_FORCE_TESTS=true
# → 不查 main CI，输出 force-tests=true，由调用方在发布 run 里跑完整测试（与 ADR 0053 的 forceRebuild 对称）。
#
# 输入（env）：
#   GATE_REPO       owner/name（必填）
#   GATE_SHA        要发布的 commit（必填，40 位十六进制）
#   GATE_CONFIG     JSON 配置路径：{"workflow":"ci.yml","requiredJobs":["build"]}
#                   未给时用 GATE_WORKFLOW + GATE_REQUIRED_JOBS（换行分隔）
#   GATE_BRANCH     缺省 main
#   GATE_TAG        本次发布的 tag 名（读 force-tests 标记；空 = 不读）
#   GATE_FORCE_TESTS  true/false，缺省 false
#   GATE_POLL       轮询间隔秒，缺省 20
#   GATE_TIMEOUT    等 run 结束的上限秒，缺省 1800
#   GATE_APPEAR_TIMEOUT  run 还没出现时的等待上限秒，缺省 300
#   GATE_MAX_POLLS / GATE_APPEAR_MAX_POLLS  直接给轮数（测试用，覆盖上面两个）
#   GATE_RERUN_ONCE true 时允许对 attempt 1 的红 run 自动重跑一次
#   GH_TOKEN        对 GATE_REPO 有 actions:read + contents:read（重跑需 actions:write）
# 输出（追加到 $GITHUB_OUTPUT，未设置时只打日志）：force-tests、run-id、run-url
# 退出码：0 放行（含 force-tests），1 拦截。
set -euo pipefail

REPO="${GATE_REPO:-}"
SHA="${GATE_SHA:-}"
BRANCH="${GATE_BRANCH:-main}"
TAG="${GATE_TAG:-}"
FORCE="${GATE_FORCE_TESTS:-false}"
POLL="${GATE_POLL:-20}"
RERUN_ONCE="${GATE_RERUN_ONCE:-false}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
FORCE_MARK='release-gate: force-tests'

log() { echo "[main-ci-gate${REPO:+ $REPO}] $*" >&2; }
# ::error:: 必须在行首，runner 才识别为注解。
err() { echo "::error::[main-ci-gate${REPO:+ $REPO}] $*" >&2; }
warn() { echo "::warning::[main-ci-gate${REPO:+ $REPO}] $*" >&2; }
deny() { err "$*"; echo "- ❌ \`$REPO\` @ \`${SHA:0:12}\`：$*" >>"$SUMMARY"; exit 1; }
emit() { echo "$1=$2" >>"$OUT"; }

# 数值输入先校验再参与算术：$(( )) 会对非数字做表达式求值。
for _v in "$POLL" "${GATE_TIMEOUT:-0}" "${GATE_APPEAR_TIMEOUT:-0}" "${GATE_MAX_POLLS:-0}" "${GATE_APPEAR_MAX_POLLS:-0}"; do
  [[ "$_v" =~ ^[0-9]{1,6}$ ]] || { echo "::error::[main-ci-gate] 轮询/超时参数必须是非负整数：'$_v'" >&2; exit 1; }
done

# polls_for 秒数 → 轮数（至少 1 轮）。
polls_for() { local p="$POLL"; [ "$p" -gt 0 ] || p=1; echo $(( ($1 + p - 1) / p )); }
MAX_POLLS="${GATE_MAX_POLLS:-$(polls_for "${GATE_TIMEOUT:-1800}")}"
APPEAR_MAX_POLLS="${GATE_APPEAR_MAX_POLLS:-$(polls_for "${GATE_APPEAR_TIMEOUT:-300}")}"

[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || deny "GATE_REPO 非法：'$REPO'"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || deny "GATE_SHA 必须是 40 位 commit SHA：'$SHA'"

# ── 配置：workflow 与必需 job ─────────────────────────────────────────────
WORKFLOW="${GATE_WORKFLOW:-}"
REQUIRED="${GATE_REQUIRED_JOBS:-}"
if [ -n "${GATE_CONFIG:-}" ]; then
  [ -f "$GATE_CONFIG" ] || deny "缺少门禁配置 ${GATE_CONFIG}（fail-closed）"
  WORKFLOW=$(jq -r '.workflow // empty' "$GATE_CONFIG") || deny "门禁配置不是合法 JSON：$GATE_CONFIG"
  REQUIRED=$(jq -r '.requiredJobs[]? // empty' "$GATE_CONFIG")
fi
[[ "$WORKFLOW" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || deny "workflow 非法或缺失：'$WORKFLOW'"
[ -n "$(tr -d '[:space:]' <<<"$REQUIRED")" ] || deny "必需 job 列表为空（fail-closed：空列表等于不设门禁）"

emit run-id ""
emit run-url ""

# ── 逃生口：force-tests ───────────────────────────────────────────────────
# 解析本次发布的 tag：确认它指向要发布的 commit，并读出 force-tests 标记。
# GATE_SHA 可以是 tag 指向的 commit，也可以是 annotated tag 对象本身（两种取值都见过），统一归一到 commit。
# 设置全局 TAG_FORCE=true|false；任何读取失败或指向别的 commit 都直接拦（fail-closed）。
TAG_FORCE=false
resolve_tag() {
  local typ obj target msg=""
  typ=$(gh api "repos/$REPO/git/ref/tags/$TAG" -q '.object.type' 2>/dev/null) \
    || deny "读不到 tag ${TAG}（fail-closed：无法确认它指向的 commit 与 force-tests 标记）"
  obj=$(gh api "repos/$REPO/git/ref/tags/$TAG" -q '.object.sha') || deny "读不到 tag $TAG 的对象"
  case "$typ" in
    commit) target="$obj" ;;
    tag)
      target=$(gh api "repos/$REPO/git/tags/$obj" -q '.object.sha') || deny "读不到 annotated tag $TAG"
      msg=$(gh api "repos/$REPO/git/tags/$obj" -q '.message') || deny "读不到 annotated tag $TAG 的消息" ;;
    *) deny "tag $TAG 的对象类型 '$typ' 不是 commit / tag" ;;
  esac
  [ "$SHA" = "$target" ] || [ "$SHA" = "$obj" ] || deny "tag $TAG 指向 ${target}，不是本次发布的 $SHA"
  SHA="$target"
  if [ -n "$msg" ] && grep -qxF "$FORCE_MARK" <<<"$msg"; then TAG_FORCE=true; fi
}

if [ "$FORCE" != "true" ] && [ -n "$TAG" ]; then
  resolve_tag
  if [ "$TAG_FORCE" = "true" ]; then
    FORCE=true
    log "tag $TAG 带「${FORCE_MARK}」标记"
  fi
fi
if [ "$FORCE" = "true" ]; then
  warn "force-tests：跳过 main CI 门禁，本次发布 run 必须自己跑完整测试"
  echo "- ⚠️ \`$REPO\` @ \`${SHA:0:12}\`：force-tests，门禁跳过，发布 run 跑完整测试" >>"$SUMMARY"
  emit force-tests true
  exit 0
fi
emit force-tests false

# ── 查询 ──────────────────────────────────────────────────────────────────
# 最新的匹配 run → "id<TAB>status<TAB>conclusion<TAB>attempt<TAB>url"，无则空。
latest_run() {
  local json
  json=$(gh api --method GET "repos/$REPO/actions/workflows/$WORKFLOW/runs" \
           -f head_sha="$SHA" -f event=push -f branch="$BRANCH" -f per_page=100 2>/dev/null) || return 1
  jq -r --arg sha "$SHA" --arg br "$BRANCH" --arg repo "$REPO" --arg path ".github/workflows/$WORKFLOW" '
    [.workflow_runs[]?
      | select(.head_sha == $sha and .event == "push" and .head_branch == $br
               and (.path == $path or (.path | startswith($path + "@")))
               and .head_repository.full_name == $repo)]
    | sort_by(.id) | last
    | if . == null then "" else [.id, .status, (.conclusion // ""), .run_attempt, .html_url] | @tsv end' <<<"$json"
}

# SHA 是否在 main 上（main 的祖先或就是 tip）。查询失败按「不确定」处理（返回 2）。
on_branch() {
  local st
  st=$(gh api "repos/$REPO/compare/$BRANCH...$SHA" -q '.status' 2>/dev/null) || return 2
  case "$st" in identical|behind) return 0 ;; ahead|diverged) return 1 ;; *) return 2 ;; esac
}

# 判定最新 attempt 的必需 job。全部 success → 输出空；否则输出不通过的「job=结论」列表。
job_failures() {  # run id
  local json name c bad=()
  json=$(gh api "repos/$REPO/actions/runs/$1/jobs?filter=latest&per_page=100" 2>/dev/null) \
    || { echo "<jobs 查询失败>"; return 0; }
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [ -n "$(tr -d '[:space:]' <<<"$name")" ] || continue
    c=$(jq -r --arg n "$name" '[.jobs[]? | select(.name == $n)]
          | if length == 0 then "missing" elif length > 1 then "ambiguous"
            else (.[0].conclusion // .[0].status // "unknown") end' <<<"$json")
    [ "$c" = "success" ] || bad+=("$name=$c")
  done <<<"$REQUIRED"
  # 非必需 job 的红只告警：它们不在分支保护里，本来也不拦合并。
  jq -r --arg req "$REQUIRED" '($req | split("\n")) as $r
     | .jobs[]? | select(.name as $n | ($r | any(. == $n)) | not)
     | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")
     | "\(.name)=\(.conclusion)"' <<<"$json" | while IFS= read -r x; do
       warn "非必需 job ${x}（不拦发布）"; done
  [ "${#bad[@]}" -eq 0 ] || printf '%s; ' "${bad[@]}"
}

# ── 主循环 ────────────────────────────────────────────────────────────────
log "要求 $WORKFLOW 在 $BRANCH 上对 ${SHA:0:12} 通过；必需 job：$(tr '\n' ',' <<<"$REQUIRED" | sed 's/,$//')"
appear=0 polls=0 reran=false
while :; do
  row=$(latest_run) || row="<query-failed>"
  if [ "$row" = "<query-failed>" ]; then
    polls=$((polls+1))
    [ "$polls" -lt "$MAX_POLLS" ] || deny "查询 $WORKFLOW 的 run 持续失败（fail-closed）"
    sleep "$POLL"; continue
  fi
  if [ -z "$row" ]; then
    set +e; on_branch; onb=$?; set -e
    [ "$onb" -ne 1 ] || deny "${SHA:0:12} 不在 $BRANCH 上：只有 main 上 CI 通过的 commit 才能发布（要发别的 commit 请用 force-tests）"
    appear=$((appear+1))
    [ "$appear" -lt "$APPEAR_MAX_POLLS" ] \
      || deny "$BRANCH 上找不到 $WORKFLOW 对 ${SHA:0:12} 的 push run（等了 $appear 轮）。确认 CI 已触发；或用 force-tests"
    log "还没有 run，等待（$appear/${APPEAR_MAX_POLLS}）"
    sleep "$POLL"; continue
  fi
  IFS=$'\t' read -r id status concl attempt url <<<"$row"
  emit run-id "$id"
  emit run-url "$url"
  if [ "$status" != "completed" ]; then
    polls=$((polls+1))
    [ "$polls" -lt "$MAX_POLLS" ] || deny "run $url 未在上限内结束（status=${status}）"
    log "run $id attempt $attempt 状态 ${status}，等待（$polls/${MAX_POLLS}）"
    sleep "$POLL"; continue
  fi
  # 刚发起重跑时 API 可能还返回 attempt 1 的旧结论：继续等新 attempt 出现，不据此判红。
  if [ "$reran" = "true" ] && [ "$attempt" = "1" ]; then
    polls=$((polls+1))
    [ "$polls" -lt "$MAX_POLLS" ] || deny "已请求重跑 run ${id}，但新 attempt 未在上限内出现"
    sleep "$POLL"; continue
  fi
  bad=$(job_failures "$id")
  if [ -z "$bad" ]; then
    log "通过：run ${url}（attempt ${attempt}，run 结论 ${concl}）"
    echo "- ✅ \`$REPO\` @ \`${SHA:0:12}\`：[$WORKFLOW run $id]($url) attempt $attempt" >>"$SUMMARY"
    exit 0
  fi
  # 自动重跑一次：只看 GitHub 上的 attempt（续跑不会重复重跑），本进程内也只重跑一次。
  if [ "$RERUN_ONCE" = "true" ] && [ "$attempt" = "1" ] && [ "$reran" = "false" ]; then
    warn "run $url 的必需 job 未通过（${bad}），attempt 1 → 自动重跑失败的 job 一次"
    gh run rerun "$id" --failed -R "$REPO" >&2 || deny "重跑 run $id 失败"
    reran=true
    polls=$((polls+1))
    sleep "$POLL"; continue
  fi
  deny "run ${url}（attempt ${attempt}）的必需 job 未通过：$bad 修复后重跑 CI，或用 force-tests"
done
