#!/usr/bin/env bash
# docs-only.sh 的回归测试。
#
# 做法：假 gh——`gh api <endpoint>` 读 $FIX/<endpoint 中 /?&=. 换成 _>，不存在则失败（模拟 API 错误）。
# 只依赖 bash + jq。
#
# 用法：bash .github/actions/docs-only/docs-only.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/docs-only.sh"
command -v jq >/dev/null || { echo "::error::jq not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$CALLS"
[ "${1:-}" = "api" ] || exit 1
shift
ep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X|-f|-F|-q|--jq) shift 2 ;;
    *) ep="$1"; shift ;;
  esac
done
key="$FIX/$(printf '%s' "$ep" | tr '/?&=.' '_____')"
[ -e "$key" ] || exit 1
cat "$key"
EOF
chmod +x "$TMP/bin/gh"

REPO=aster-cloud/aster-lang-x
BASE=1111111111111111111111111111111111111111
HEAD=2222222222222222222222222222222222222222
B2=3333333333333333333333333333333333333333
ZERO=0000000000000000000000000000000000000000
RUNS_EP="repos/$REPO/actions/workflows/ci.yml/runs"

newcase() {
  CASE="$1"
  FIX="$TMP/fix-$1"; rm -rf "$FIX"; mkdir -p "$FIX"
  CALLS="$FIX/.calls"; : >"$CALLS"
  export FIX CALLS
  EVENT_NAME=pull_request REF=refs/pull/1/merge SHA_ENV="$HEAD"
  echo "{\"pull_request\":{\"base\":{\"sha\":\"$BASE\"},\"head\":{\"sha\":\"$HEAD\"}}}" >"$FIX/event.json"
  unset EXTRA_DOCS NON_DOCS BASELINE_WORKFLOW BASELINE_JOBS BASELINE_SHA_FROM BASE_IN HEAD_IN
}
fx() { printf '%s\n' "$2" >"$FIX/$(printf '%s' "$1" | tr '/?&=.' '_____')"; }
# compare 结果：status 文件…（文件写成 path 或 old=>new 表示重命名）
cmp() {
  local st="$1" out="" f; shift
  for f in "$@"; do
    if [[ "$f" == *"=>"* ]]; then
      out+="$(jq -cn --arg o "${f%%=>*}" --arg n "${f##*=>}" '{filename:$n, previous_filename:$o, status:"renamed"}'),"
    else
      out+="$(jq -cn --arg n "$f" '{filename:$n, status:"modified"}'),"
    fi
  done
  echo "{\"status\":\"$st\",\"files\":[${out%,}]}"
}
# run：id head_sha [branch] [repo]
run() { jq -cn --argjson id "$1" --arg sha "$2" --arg br "${3:-main}" --arg repo "${4:-$REPO}" --arg title "${5:-CI}" \
  '{id:$id, head_sha:$sha, head_branch:$br, status:"completed", conclusion:"success", head_repository:{full_name:$repo}, display_title:$title}'; }
runs() { local IFS=,; echo "{\"workflow_runs\":[$*]}"; }
# job：name conclusion [step=conclusion ...]
job() {
  local n="$1" c="$2" steps="" kv; shift 2
  for kv in "$@"; do steps+="$(jq -cn --arg n "${kv%=*}" --arg c "${kv##*=}" '{name:$n, conclusion:$c}'),"; done
  jq -cn --arg n "$n" --arg c "$c" --argjson s "[${steps%,}]" '{name:$n, conclusion:$c, steps:$s}'
}
jobs() { local IFS=,; echo "{\"jobs\":[$*]}"; }
jobs_ep() { echo "repos/$REPO/actions/runs/$1/jobs?filter=latest&per_page=100"; }

detect() {
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=dummy DOCS_REPO="$REPO" \
    GITHUB_EVENT_NAME="$EVENT_NAME" GITHUB_EVENT_PATH="$FIX/event.json" GITHUB_REF="$REF" GITHUB_SHA="$SHA_ENV" \
    GITHUB_OUTPUT="$FIX/.out" GITHUB_STEP_SUMMARY="$FIX/.summary" \
    EXTRA_DOCS="${EXTRA_DOCS:-}" NON_DOCS="${NON_DOCS:-}" \
    BASELINE_WORKFLOW="${BASELINE_WORKFLOW:-}" BASELINE_JOBS="${BASELINE_JOBS:-}" BASELINE_SHA_FROM="${BASELINE_SHA_FROM:-}" \
    BASE="${BASE_IN:-}" HEAD="${HEAD_IN:-}" \
    bash "$SUT" >"$FIX/.stdout" 2>"$FIX/.stderr"
  rc=$?
  set -e
  [ "$rc" = 0 ] || fail "退出码 $rc"
}
fail() { echo "FAIL [$CASE]: $*"; echo "--- stderr ---"; cat "$FIX/.stderr"; echo "--- out ---"; cat "$FIX/.out" 2>/dev/null; echo "--- calls ---"; cat "$CALLS"; exit 1; }
expect() { grep -qxF -- "docs-only=$1" "$FIX/.out" || fail "期望 docs-only=$1"; }
expect_out() { grep -qxF -- "$1" "$FIX/.out" || fail "GITHUB_OUTPUT 缺少：$1"; }
expect_reason() { grep -F -- "reason=" "$FIX/.out" | grep -qF -- "$1" || fail "reason 缺少：$1"; }
no_calls() { [ ! -s "$CALLS" ] || fail "不应调用 gh"; }

# ── PR：分类 ──────────────────────────────────────────────────────────────
newcase pr-docs
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp diverged docs/adr/0057.md README.md docs/img/a.png LICENSE .github/ISSUE_TEMPLATE/bug.yml CONTRIBUTING.md)"
detect; expect true; expect_out "base=$BASE"; expect_out "head=$HEAD"

newcase pr-code
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md src/main/java/A.java)"
detect; expect false; expect_reason "src/main/java/A.java"

newcase pr-workflow
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md .github/workflows/ci.yml)"
detect; expect false

for f in src/app/docs/page.md packages/x/src/README.md test/corpus/README.md src/test/resources/a.md \
         content/docs/intro.md messages/en.json public/robots.txt docs/../src/a.md app/docs/x.md docs/test/fixture.md; do
  newcase "non-docs-$(echo "$f" | tr '/.' '__')"
  fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md "$f")"
  detect; expect false
done

newcase pr-unknown-root-file
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead README.md package.json)"
detect; expect false

newcase caller-non-docs
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md CHANGELOG.md)"
NON_DOCS=$'README.md\nCHANGELOG.md' detect; expect false; expect_reason "CHANGELOG.md"

newcase caller-extra-docs
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md .claude/plan/a.json)"
detect; expect false
EXTRA_DOCS=' .claude/* ' detect; expect true

newcase rename-from-src
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead 'src/a.md=>docs/a.md')"
detect; expect false
newcase rename-docs
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead 'docs/a.md=>docs/b/a.md')"
detect; expect true

newcase empty-diff
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp identical)"
detect; expect false; expect_reason "没有变更文件"

newcase compare-cap
files=(); for i in $(seq 1 300); do files+=("docs/$i.md"); done
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead "${files[@]}")"
detect; expect false; expect_reason "上限"

newcase compare-fails
detect; expect false; expect_reason "查询失败"

newcase base-override
fx "repos/$REPO/compare/$HEAD~1...$HEAD" "$(cmp ahead docs/x.md)"
BASE_IN="$HEAD~1" detect; expect true; expect_out "base=$HEAD~1"

# ── 不比较的事件 ──────────────────────────────────────────────────────────
for e in workflow_dispatch schedule merge_group repository_dispatch; do
  newcase "event-$e"; EVENT_NAME=$e; REF=refs/heads/main
  detect; expect false; no_calls
done
newcase tag-push; EVENT_NAME=push; REF=refs/tags/v1.0.0
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build$' detect; expect false; no_calls

# ── push：必须有基线 ──────────────────────────────────────────────────────
newcase push-no-baseline; EVENT_NAME=push; REF=refs/heads/main
echo "{\"before\":\"$BASE\",\"after\":\"$HEAD\"}" >"$FIX/event.json"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md)"
detect; expect false; expect_reason "未配置基线"; no_calls

# 最新 run 是 docs-only（Build 步骤 skipped）→ 跳过它，取更早的真跑 run 为基线。
newcase push-baseline; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 5 "$B2")" "$(run 4 "$BASE")" "$(run 6 "$B2" main evil/fork)")"
fx "$(jobs_ep 5)" "$(jobs "$(job build success Build=skipped)")"
fx "$(jobs_ep 4)" "$(jobs "$(job build success Build=success)")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md)"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build$ :: Build' detect; expect true; expect_out "base=$BASE"
grep -q "runs/6/jobs" "$CALLS" && fail "fork 的 run 不应被考察"

# 基线到 head 之间有代码（例如红掉的代码提交后面跟一个 docs 提交）→ 完整运行。
newcase push-baseline-includes-code; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 4 "$BASE")")"
fx "$(jobs_ep 4)" "$(jobs "$(job build success Build=success)")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md src/A.java)"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build$ :: Build' detect; expect false

# job 红、步骤红、job 名不符 → 都不是基线；回看完仍无 → 完整运行。
newcase push-no-valid-baseline; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 7 "$B2")" "$(run 8 "$B2")" "$(run 9 "$B2")" "$(run 10 "$B2" feature)")"
fx "$(jobs_ep 7)" "$(jobs "$(job build failure Build=success)")"
fx "$(jobs_ep 8)" "$(jobs "$(job build success Build=failure)")"
fx "$(jobs_ep 9)" "$(jobs "$(job lint success Build=success)")"
fx "$(jobs_ep 10)" "$(jobs "$(job build success Build=success)")"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build$ :: Build' detect; expect false; expect_reason "找不到"

# 基线不是 head 的祖先（force-push / 回滚）→ 完整运行。
newcase push-baseline-diverged; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 4 "$BASE")")"
fx "$(jobs_ep 4)" "$(jobs "$(job build success Build=success)")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp diverged docs/x.md)"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build$ :: Build' detect; expect false; expect_reason "status=diverged"

# 基线 job 用 ERE 匹配多个候选（如 aster-api 的 build-local / build-hosted），不要求步骤。
newcase push-baseline-regex; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 4 "$BASE")")"
fx "$(jobs_ep 4)" "$(jobs "$(job 'build-local / unit' skipped)" "$(job 'build-hosted / unit' success)")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md)"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build-(local|hosted) / unit$' detect; expect true

# 多行基线：每一行都要满足（部署：deploy 成功且 pin 步骤真的开了 PR；stale 闸门跳过 pin 的 run 不算）。
newcase push-baseline-multi; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 6 "$B2")" "$(run 5 "$B2")" "$(run 4 "$BASE")")"
fx "$(jobs_ep 6)" "$(jobs "$(job deploy skipped)" "$(job image-pin-pr skipped)")"
fx "$(jobs_ep 5)" "$(jobs "$(job deploy success)" "$(job image-pin-pr success 'Open PR=skipped')")"
fx "$(jobs_ep 4)" "$(jobs "$(job deploy success)" "$(job image-pin-pr success 'Open PR=success')")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md)"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS=$'^deploy$\n  ^image-pin-pr$ :: Open PR  \n' detect; expect true; expect_out "base=$BASE"

newcase push-baseline-bad-regex; EVENT_NAME=push; REF=refs/heads/main
fx "$RUNS_EP" "$(runs "$(run 4 "$BASE")")"
fx "$(jobs_ep 4)" "$(jobs "$(job build success)")"
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^(build$' detect; expect false

newcase push-runs-query-fails; EVENT_NAME=push; REF=refs/heads/main
BASELINE_WORKFLOW=ci.yml BASELINE_JOBS='^build$' detect; expect false

newcase push-bad-workflow-name; EVENT_NAME=push; REF=refs/heads/main
BASELINE_WORKFLOW='../x.yml' BASELINE_JOBS='^build$' detect; expect false; no_calls

# ── workflow_run：head 与分支取自触发它的 run ─────────────────────────────
newcase workflow-run; EVENT_NAME=workflow_run; REF=refs/heads/main; SHA_ENV="$B2"
echo "{\"workflow_run\":{\"head_sha\":\"$HEAD\",\"head_branch\":\"main\"}}" >"$FIX/event.json"
fx "repos/$REPO/actions/workflows/deploy-worker.yml/runs" "$(runs "$(run 4 "$BASE")")"
fx "$(jobs_ep 4)" "$(jobs "$(job deploy success 'Build + deploy=success')")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md)"
BASELINE_WORKFLOW=deploy-worker.yml BASELINE_JOBS='^deploy$ :: Build + deploy' detect
expect true; expect_out "head=$HEAD"

# workflow_run 触发的 run：head_sha 是触发时的默认分支 tip（这里故意给成 $HEAD），实际部署的 commit
# 写在标题里。按 head_sha 取会把基线错认成 head（diff 为空 → 完整运行）；按 title 取得到真正部署过的 $BASE。
newcase workflow-run-title; EVENT_NAME=workflow_run; REF=refs/heads/main
echo "{\"workflow_run\":{\"head_sha\":\"$HEAD\",\"head_branch\":\"main\"}}" >"$FIX/event.json"
fx "repos/$REPO/actions/workflows/deploy-worker.yml/runs" "$(runs "$(run 5 "$HEAD" main "$REPO" 'Deploy Worker')" "$(run 4 "$HEAD" main "$REPO" "Deploy Worker · $BASE")")"
fx "$(jobs_ep 5)" "$(jobs "$(job deploy success 'Build + deploy=success')")"
fx "$(jobs_ep 4)" "$(jobs "$(job deploy success 'Build + deploy=success')")"
fx "repos/$REPO/compare/$BASE...$HEAD" "$(cmp ahead docs/x.md)"
BASELINE_SHA_FROM=title BASELINE_WORKFLOW=deploy-worker.yml BASELINE_JOBS='^deploy$ :: Build + deploy' detect
expect true; expect_out "base=$BASE"
grep -q "runs/5/jobs" "$CALLS" && fail "标题里没有 SHA 的 run 不应被考察"
newcase bad-sha-from
set +e; PATH="$TMP/bin:$PATH" DOCS_REPO="$REPO" BASELINE_SHA_FROM=tip GITHUB_EVENT_NAME=push bash "$SUT" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" = 1 ] || fail "非法 BASELINE_SHA_FROM 应以 1 退出"

# ── 非法输入 / 新分支 ─────────────────────────────────────────────────────
newcase zero-base
BASE_IN="$ZERO" detect; expect false; no_calls
newcase bad-chars
BASE_IN='a;rm -rf /' detect; expect false; no_calls

echo "docs-only.test.sh: all cases passed"
