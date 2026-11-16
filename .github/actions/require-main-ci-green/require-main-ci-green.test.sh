#!/usr/bin/env bash
# require-main-ci-green.sh 的回归测试（ADR 0053 修订 A2）。
#
# 做法：假 gh——`gh api <endpoint>` 读 $FIX/<endpoint 中 /?&= 换成 _>；存在 <key>.seq.1、.seq.2 …
# 时按读取次数切换（超出则用最大的那个），模拟「run 从 in_progress 变 completed」「重跑后出现 attempt 2」。
# `gh run rerun` 只记录。-q 用真 jq 执行。只依赖 bash + jq。
#
# 用法：bash .github/actions/require-main-ci-green/require-main-ci-green.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/require-main-ci-green.sh"
command -v jq >/dev/null || { echo "::error::jq not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$CALLS"
if [ "${1:-}" = "run" ]; then
  [ "${2:-}" = "rerun" ] || exit 1
  echo "rerun $3" >>"$RERUNS"; exit "${RERUN_RC:-0}"
fi
[ "${1:-}" = "api" ] || exit 1
shift
q="" ep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X) shift 2 ;;
    -q|--jq) q="$2"; shift 2 ;;
    -f|-F) shift 2 ;;
    *) ep="$1"; shift ;;
  esac
done
key="$FIX/$(printf '%s' "$ep" | tr '/?&=' '____')"
if [ -e "$key.seq.1" ]; then
  n=$(( $(cat "$key.count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$key.count"
  while [ "$n" -gt 1 ] && [ ! -e "$key.seq.$n" ]; do n=$((n-1)); done
  key="$key.seq.$n"
fi
[ -e "$key" ] || exit 1
if [ -n "$q" ]; then jq -r "$q" "$key"; else cat "$key"; fi
EOF
chmod +x "$TMP/bin/gh"

REPO=aster-cloud/aster-lang-x
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
TAGOBJ=3333333333333333333333333333333333333333
RUNS_EP="repos/$REPO/actions/workflows/ci.yml/runs"

newcase() {
  FIX="$TMP/fix-$1"; rm -rf "$FIX"; mkdir -p "$FIX"
  CALLS="$FIX/.calls"; RERUNS="$FIX/.reruns"; : >"$CALLS"; : >"$RERUNS"
  export FIX CALLS RERUNS
  CONFIG="$FIX/gate.json"
  echo '{"workflow":"ci.yml","requiredJobs":["build","test (24)"]}' >"$CONFIG"
  unset GATE_TAG GATE_FORCE_TESTS GATE_RERUN_ONCE
  CASE="$1"
}
# fixture 写入：$1=endpoint，$2=内容，$3=可选后缀（如 .seq.2）
fx() { printf '%s\n' "$2" >"$FIX/$(printf '%s' "$1" | tr '/?&=' '____')${3:-}"; }
# 一个 workflow run：id status conclusion attempt [sha event branch repo path]
run() {
  jq -cn --argjson id "$1" --arg st "$2" --arg c "$3" --argjson a "$4" \
    --arg sha "${5:-$SHA}" --arg ev "${6:-push}" --arg br "${7:-main}" --arg repo "${8:-$REPO}" \
    --arg path "${9:-.github/workflows/ci.yml}" \
    '{id:$id, status:$st, conclusion:(if $c=="" then null else $c end), run_attempt:$a, head_sha:$sha,
      event:$ev, head_branch:$br, path:$path, head_repository:{full_name:$repo},
      html_url:("https://github.com/x/runs/" + ($id|tostring))}'
}
runs() { local IFS=,; echo "{\"workflow_runs\":[$*]}"; }
# job 列表：name=conclusion ...（conclusion 写 null 表示未结束）
jobs() {
  local out="" kv n c
  for kv in "$@"; do
    n="${kv%=*}"; c="${kv##*=}"
    out+="$(jq -cn --arg n "$n" --arg c "$c" '{name:$n, conclusion:(if $c=="null" then null else $c end), status:"completed"}'),"
  done
  echo "{\"jobs\":[${out%,}]}"
}
jobs_ep() { echo "repos/$REPO/actions/runs/$1/jobs?filter=latest&per_page=100"; }

gate() {
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=dummy GATE_REPO="$REPO" GATE_SHA="${GATE_SHA_OVERRIDE:-$SHA}" \
    GATE_CONFIG="${GATE_CONFIG_OVERRIDE-$CONFIG}" GATE_POLL=0 GATE_MAX_POLLS="${MAXP:-4}" GATE_APPEAR_MAX_POLLS="${APPEARP:-3}" \
    GITHUB_OUTPUT="$FIX/.out" GITHUB_STEP_SUMMARY="$FIX/.summary" \
    bash "$GATE" >"$FIX/.stdout" 2>"$FIX/.stderr"
  rc=$?
  set -e
}
fail() { echo "FAIL [$CASE]: $*"; echo "--- stderr ---"; cat "$FIX/.stderr"; echo "--- calls ---"; cat "$CALLS"; exit 1; }
expect_rc() { [ "$rc" = "$1" ] || fail "rc=${rc}，期望 $1"; }
expect_err() { grep -qF -- "$1" "$FIX/.stderr" || fail "stderr 缺少：$1"; }
expect_out() { grep -qxF -- "$1" "$FIX/.out" || fail "GITHUB_OUTPUT 缺少：$1（实际：$(tr '\n' ' ' <"$FIX/.out")）"; }
reruns() { wc -l <"$RERUNS" | tr -d ' '; }

# 1. 正常放行：最新 run 已结束，两个必需 job 都 success；输出 run-id/run-url。
newcase pass
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')"
gate; expect_rc 0; expect_out "force-tests=false"; expect_out "run-id=10"; expect_out "run-url=https://github.com/x/runs/10"

# 2. 必需 job skipped 不算通过。
newcase skipped
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=skipped')"
gate; expect_rc 1; expect_err "test (24)=skipped"

# 3. 必需 job 缺失（改名、条件未满足）不算通过；重名也不算。
newcase missing
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success)"
gate; expect_rc 1; expect_err "test (24)=missing"
newcase ambiguous
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success build=success 'test (24)=success')"
gate; expect_rc 1; expect_err "build=ambiguous"

# 4. 必需 job 红 → 拦；只有非必需 job 红 → 放行并告警（run 结论 failure 也放行）。
newcase required-red
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success' parity=success)"
gate; expect_rc 1; expect_err "build=failure"
newcase optional-red
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success' 'Strict tier1 parity=failure' notify=skipped)"
gate; expect_rc 0; expect_err "::warning::"; expect_err "Strict tier1 parity=failure"
grep -qF "notify=skipped" "$FIX/.stderr" && fail "非必需 job skipped 不应告警"

# 5. run 未结束 → 等；变 completed 后放行。
newcase wait-then-pass
fx "$RUNS_EP" "$(runs "$(run 10 in_progress '' 1)")" .seq.1
fx "$RUNS_EP" "$(runs "$(run 10 in_progress '' 1)")" .seq.2
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")" .seq.3
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')"
gate; expect_rc 0

# 6. 一直不结束 → 超时拦截。
newcase timeout
fx "$RUNS_EP" "$(runs "$(run 10 queued '' 1)")"
MAXP=3 gate; expect_rc 1; expect_err "未在上限内结束"

# 7. 没有 run 且 SHA 不在 main 上 → 立即拦（不等）。
newcase not-on-main
fx "$RUNS_EP" "$(runs)"
fx "repos/$REPO/compare/main...$SHA" '{"status":"ahead"}'
gate; expect_rc 1; expect_err "不在 main 上"
[ "$(grep -c 'compare' "$CALLS")" = "1" ] || fail "不在 main 上应只查一次就拦"

newcase diverged
fx "$RUNS_EP" "$(runs)"
fx "repos/$REPO/compare/main...$SHA" '{"status":"diverged"}'
gate; expect_rc 1; expect_err "不在 main 上"
newcase compare-fails
fx "$RUNS_EP" "$(runs)"
gate; expect_rc 1; expect_err "找不到 ci.yml"   # compare 查询失败 = 不确定 → 按「还没出现」有界等待后拦

# 8. 没有 run、SHA 在 main 上 → 等到出现上限后拦；中途出现则放行。
newcase never-appears
fx "$RUNS_EP" "$(runs)"
fx "repos/$REPO/compare/main...$SHA" '{"status":"identical"}'
gate; expect_rc 1; expect_err "找不到 ci.yml"
newcase appears-later
fx "$RUNS_EP" "$(runs)" .seq.1
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")" .seq.2
fx "repos/$REPO/compare/main...$SHA" '{"status":"behind"}'
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')"
gate; expect_rc 0

# 9. 多个 run：只看最新（id 最大）的，不在历史里挑绿的。
newcase newest-red
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)" "$(run 12 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')"
fx "$(jobs_ep 12)" "$(jobs build=failure 'test (24)=success')"
gate; expect_rc 1; expect_err "build=failure"
newcase newest-green
fx "$RUNS_EP" "$(runs "$(run 12 completed success 1)" "$(run 10 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')"
fx "$(jobs_ep 12)" "$(jobs build=success 'test (24)=success')"
gate; expect_rc 0; expect_out "run-id=12"

# 10. 不相干的 run 一律忽略：别的 SHA、pull_request、别的分支、fork、别的 workflow 文件。
newcase filtered
fx "$RUNS_EP" "$(runs "$(run 20 completed success 1 "$OTHER")" "$(run 21 completed success 1 "$SHA" pull_request)" \
  "$(run 22 completed success 1 "$SHA" push feature)" "$(run 23 completed success 1 "$SHA" push main evil/fork)" \
  "$(run 24 completed success 1 "$SHA" push main "$REPO" .github/workflows/other.yml)")"
fx "repos/$REPO/compare/main...$SHA" '{"status":"identical"}'
for i in 20 21 22 23 24; do fx "$(jobs_ep $i)" "$(jobs build=success 'test (24)=success')"; done
gate; expect_rc 1; expect_err "找不到 ci.yml"

# 11. 自动重跑一次（仅 GATE_RERUN_ONCE=true 且 attempt 1）：重跑后 attempt 2 绿 → 放行。
#     发起重跑后 API 仍短暂返回 attempt 1 的旧结论 → 继续等，不据此判红。
newcase rerun-pass
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")" .seq.1
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")" .seq.2
fx "$RUNS_EP" "$(runs "$(run 10 in_progress '' 2)")" .seq.3
fx "$RUNS_EP" "$(runs "$(run 10 completed success 2)")" .seq.4
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')" .seq.1
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')" .seq.2
GATE_RERUN_ONCE=true MAXP=6 gate; expect_rc 0; [ "$(reruns)" = "1" ] || fail "应重跑恰好一次（实际 $(reruns)）"
grep -qx "rerun 10" "$RERUNS" || fail "应重跑 run 10"
grep -q -- "--failed" "$CALLS" || fail "重跑应只跑失败的 job（--failed）"

# 12. 重跑后仍红 → 拦，且不再重跑；attempt 已 ≥2（续跑）→ 直接拦不重跑；未开 RERUN_ONCE → 不重跑。
newcase rerun-still-red
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")" .seq.1
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 2)")" .seq.2
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')"
GATE_RERUN_ONCE=true MAXP=6 gate; expect_rc 1; [ "$(reruns)" = "1" ] || fail "只应重跑一次"
newcase attempt2-no-rerun
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 2)")"
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')"
GATE_RERUN_ONCE=true gate; expect_rc 1; [ "$(reruns)" = "0" ] || fail "attempt 2 不应再重跑"
newcase no-rerun-flag
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')"
gate; expect_rc 1; [ "$(reruns)" = "0" ] || fail "未开 GATE_RERUN_ONCE 不应重跑"
newcase rerun-api-fails
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')"
RERUN_RC=1 GATE_RERUN_ONCE=true gate; expect_rc 1; expect_err "重跑 run 10 失败"

# 13. force-tests：annotated tag 带标记 → 放行且不查 CI；不带标记 / lightweight → 照常走门禁。
newcase force-tag
fx "repos/$REPO/git/ref/tags/v1.0.49" "{\"object\":{\"type\":\"tag\",\"sha\":\"$TAGOBJ\"}}"
fx "repos/$REPO/git/tags/$TAGOBJ" "{\"object\":{\"sha\":\"$SHA\"},\"message\":\"列车 eco-1.0.49\nrelease-gate: force-tests\n\"}"
GATE_TAG=v1.0.49 gate; expect_rc 0; expect_out "force-tests=true"
grep -q 'actions/workflows' "$CALLS" && fail "force-tests 不应再查 CI run"
newcase annotated-no-mark
fx "repos/$REPO/git/ref/tags/v1.0.49" "{\"object\":{\"type\":\"tag\",\"sha\":\"$TAGOBJ\"}}"
fx "repos/$REPO/git/tags/$TAGOBJ" "{\"object\":{\"sha\":\"$SHA\"},\"message\":\"release-gate: force-tests please\n\"}"
fx "$RUNS_EP" "$(runs "$(run 10 completed failure 1)")"
fx "$(jobs_ep 10)" "$(jobs build=failure 'test (24)=success')"
GATE_TAG=v1.0.49 gate; expect_rc 1; expect_out "force-tests=false"
newcase lightweight
fx "repos/$REPO/git/ref/tags/v1.0.49" "{\"object\":{\"type\":\"commit\",\"sha\":\"$SHA\"}}"
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')"
GATE_TAG=v1.0.49 gate; expect_rc 0; expect_out "force-tests=false"

# 13b. GATE_SHA 是 annotated tag 对象本身 → 归一到它指向的 commit，按 commit 查 CI。
newcase tag-object-sha
fx "repos/$REPO/git/ref/tags/v1.0.49" "{\"object\":{\"type\":\"tag\",\"sha\":\"$TAGOBJ\"}}"
fx "repos/$REPO/git/tags/$TAGOBJ" "{\"object\":{\"sha\":\"$SHA\"},\"message\":\"plain\n\"}"
fx "$RUNS_EP" "$(runs "$(run 10 completed success 1)")"
fx "$(jobs_ep 10)" "$(jobs build=success 'test (24)=success')"
GATE_SHA_OVERRIDE=$TAGOBJ GATE_TAG=v1.0.49 gate; expect_rc 0; expect_out "run-id=10"
grep -q "head_sha=$SHA" "$CALLS" || fail "应按 tag 指向的 commit 查 CI"

# 14. tag 异常 fail-closed：读不到 tag；annotated / lightweight tag 指向别的 commit。
newcase lightweight-other
fx "repos/$REPO/git/ref/tags/v1.0.49" "{\"object\":{\"type\":\"commit\",\"sha\":\"$OTHER\"}}"
GATE_TAG=v1.0.49 gate; expect_rc 1; expect_err "不是本次发布的"
newcase tag-unreadable
GATE_TAG=v1.0.49 gate; expect_rc 1; expect_err "读不到 tag v1.0.49"
newcase tag-other-commit
fx "repos/$REPO/git/ref/tags/v1.0.49" "{\"object\":{\"type\":\"tag\",\"sha\":\"$TAGOBJ\"}}"
fx "repos/$REPO/git/tags/$TAGOBJ" "{\"object\":{\"sha\":\"$OTHER\"},\"message\":\"release-gate: force-tests\n\"}"
GATE_TAG=v1.0.49 gate; expect_rc 1; expect_err "不是本次发布的"

# 15. 输入 force-tests=true → 放行，不查任何 API。
newcase force-input
GATE_FORCE_TESTS=true gate; expect_rc 0; expect_out "force-tests=true"; [ ! -s "$CALLS" ] || fail "force 输入不应调 API"

# 16. 配置 fail-closed：缺文件、空 requiredJobs、非法 SHA。
newcase no-config
GATE_CONFIG_OVERRIDE="$FIX/nope.json" gate; expect_rc 1; expect_err "缺少门禁配置"
newcase empty-jobs
echo '{"workflow":"ci.yml","requiredJobs":[]}' >"$CONFIG"
gate; expect_rc 1; expect_err "必需 job 列表为空"
newcase bad-sha
GATE_SHA_OVERRIDE=main gate; expect_rc 1; expect_err "40 位 commit SHA"

# 17. 查询持续失败 → 有界后拦（不会无限等，也不会误放行）。
newcase query-fails
MAXP=2 gate; expect_rc 1; expect_err "持续失败"

echo "require-main-ci-green.test.sh: all cases passed"
