#!/usr/bin/env bash
# preflight-main-ci.sh 的回归测试（ADR 0053 修订 A2）：参与仓的筛选（service 不查）、过渡期没有
# 门禁配置的仓不拦、任一仓不绿即整体失败、非 dryRun 才自动重跑一次、forceTests 整体跳过、缺 SHA fail-closed。
# 门禁判定本身的细节由 .github/actions/require-main-ci-green/require-main-ci-green.test.sh 覆盖。
#
# 用法：bash scripts/release-plan/preflight-main-ci.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE="$HERE/preflight-main-ci.sh"
command -v jq >/dev/null || { echo "::error::jq not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $* token=$GH_TOKEN" >>"$CALLS"
if [ "${1:-}" = "run" ]; then echo "rerun $3 $6" >>"$RERUNS"; exit 0; fi
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

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
LAYERS='[[{"repo":"aster-lang-core","org":"aster-cloud","kinds":["maven"]},{"repo":"aster-lang-test","org":"aster-cloud","kinds":["maven"]},{"repo":"aster-lang-test","org":"aster-cloud","kinds":["npm"]}],
         [{"repo":"aster-lang-ts","kinds":["npm"]},{"repo":"aster-api","org":"wontlost-ltd","kinds":["service"]}]]'
SHAS="{\"aster-lang-core\":\"$A\",\"aster-lang-test\":\"$B\",\"aster-lang-ts\":\"$C\",\"aster-api\":\"$A\"}"

newcase() {
  FIX="$TMP/fix-$1"; rm -rf "$FIX"; mkdir -p "$FIX/clones"
  CALLS="$FIX/.calls"; RERUNS="$FIX/.reruns"; : >"$CALLS"; : >"$RERUNS"
  export FIX CALLS RERUNS
  CASE="$1"
}
fx() { printf '%s\n' "$2" >"$FIX/$(printf '%s' "$1" | tr '/?&=' '____')${3:-}"; }
gate_cfg() {  # repo jobs-json
  mkdir -p "$FIX/clones/$1/.github"
  echo "{\"workflow\":\"ci.yml\",\"requiredJobs\":$2}" >"$FIX/clones/$1/.github/main-ci-gate.json"
}
green() {  # repo sha job [attempt]
  fx "repos/aster-cloud/$1/actions/workflows/ci.yml/runs" \
    "{\"workflow_runs\":[{\"id\":5,\"status\":\"completed\",\"conclusion\":\"success\",\"run_attempt\":${4:-1},\"head_sha\":\"$2\",\"event\":\"push\",\"head_branch\":\"main\",\"path\":\".github/workflows/ci.yml\",\"head_repository\":{\"full_name\":\"aster-cloud/$1\"},\"html_url\":\"u\"}]}" ${5:-}
  fx "repos/aster-cloud/$1/actions/runs/5/jobs?filter=latest&per_page=100" "{\"jobs\":[{\"name\":\"$3\",\"conclusion\":\"success\"}]}" ${5:-}
}
red() {  # repo sha job
  fx "repos/aster-cloud/$1/actions/workflows/ci.yml/runs" \
    "{\"workflow_runs\":[{\"id\":5,\"status\":\"completed\",\"conclusion\":\"failure\",\"run_attempt\":1,\"head_sha\":\"$2\",\"event\":\"push\",\"head_branch\":\"main\",\"path\":\".github/workflows/ci.yml\",\"head_repository\":{\"full_name\":\"aster-cloud/$1\"},\"html_url\":\"u\"}]}" ${4:-}
  fx "repos/aster-cloud/$1/actions/runs/5/jobs?filter=latest&per_page=100" "{\"jobs\":[{\"name\":\"$3\",\"conclusion\":\"failure\"}]}" ${4:-}
}
pre() {
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=cloudtok WONTLOST_TOKEN=wltok LAYERS="${L:-$LAYERS}" MAIN_SHAS="${S:-$SHAS}" \
    CLONE_ROOT="$FIX/clones" DRY_RUN="${DRY:-false}" GATE_POLL=0 GATE_MAX_POLLS=4 GATE_APPEAR_MAX_POLLS=2 \
    GITHUB_STEP_SUMMARY="$FIX/.summary" bash "$PRE" >"$FIX/.out" 2>&1
  rc=$?
  set -e
}
fail() { echo "FAIL [$CASE]: $*"; echo "--- out ---"; cat "$FIX/.out"; echo "--- calls ---"; cat "$CALLS"; exit 1; }

# 1. 全绿：core/test/ts 各查一次（test 两个 step 只查一次），aster-api（service）不查。
newcase all-green
gate_cfg aster-lang-core '["build"]'; gate_cfg aster-lang-test '["Build & test (JDK)"]'; gate_cfg aster-lang-ts '["test (24)"]'
gate_cfg aster-api '["ci-result"]'   # 即使 aster-api 有配置，service 也不查
green aster-lang-core "$A" build; green aster-lang-test "$B" "Build & test (JDK)"; green aster-lang-ts "$C" "test (24)"
pre; [ "$rc" = 0 ] || fail "全绿应通过，rc=$rc"
[ "$(grep -c 'actions/workflows/ci.yml/runs' "$CALLS")" = "3" ] || fail "应恰好查 3 个仓"
grep -q 'aster-api' "$CALLS" && fail "service（aster-api）不应查 main CI"
grep -q 'token=cloudtok' "$CALLS" || fail "aster-cloud 仓应使用 GH_TOKEN"

# 2. 过渡期：没有门禁配置的仓不查也不拦。
newcase legacy
gate_cfg aster-lang-core '["build"]'; green aster-lang-core "$A" build
pre; [ "$rc" = 0 ] || fail "未接入门禁的仓不应拦，rc=$rc"
grep -q 'aster-lang-test/actions' "$CALLS" && fail "未接入门禁的仓不应查"
grep -q '未接入门禁' "$FIX/.summary" || fail "summary 应注明未接入门禁的仓"

# 3. 任一仓红 → 整体失败；非 dryRun 自动重跑一次，重跑后仍红。
newcase one-red
gate_cfg aster-lang-core '["build"]'; gate_cfg aster-lang-ts '["test (24)"]'
red aster-lang-core "$A" build; green aster-lang-ts "$C" "test (24)"
pre; [ "$rc" = 1 ] || fail "core 红应失败，rc=$rc"
grep -qx 'rerun 5 aster-cloud/aster-lang-core' "$RERUNS" || fail "非 dryRun 应重跑 core 一次：$(cat "$RERUNS")"
grep -q '^::error::.*aster-lang-core' "$FIX/.out" || fail "失败仓的 ::error:: 应在组外出现"

# 4. lockstep pin 竞态：attempt 1 红，重跑后 attempt 2 绿 → 通过。
newcase race-heals
gate_cfg aster-lang-core '["build"]'
red aster-lang-core "$A" build .seq.1
green aster-lang-core "$A" build 2 .seq.2
pre; [ "$rc" = 0 ] || fail "重跑变绿应通过，rc=$rc"
[ "$(wc -l <"$RERUNS" | tr -d ' ')" = "1" ] || fail "应恰好重跑一次"

# 5. dryRun：只读，红就报，不重跑。
newcase dry
gate_cfg aster-lang-core '["build"]'; red aster-lang-core "$A" build
DRY=true pre; [ "$rc" = 1 ] || fail "dryRun 下红也应失败"
[ -s "$RERUNS" ] && fail "dryRun 不得重跑"

# 6. forceTests：整体跳过，不调 API。
newcase force
gate_cfg aster-lang-core '["build"]'; red aster-lang-core "$A" build
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=x LAYERS="$LAYERS" MAIN_SHAS="$SHAS" CLONE_ROOT="$FIX/clones" FORCE_TESTS=true \
  bash "$PRE" >"$FIX/.out" 2>&1; rc=$?
set -e
[ "$rc" = 0 ] || fail "forceTests 应跳过，rc=$rc"; [ -s "$CALLS" ] && fail "forceTests 不应调 API"

# 7. MAIN_SHAS 缺该仓 → fail-closed；LAYERS 非法 → fail-closed。
newcase no-sha
gate_cfg aster-lang-core '["build"]'
S='{}' pre; [ "$rc" = 1 ] || fail "缺 SHA 应失败"
grep -q 'MAIN_SHAS 里没有它' "$FIX/.out" || fail "应说明缺 SHA"
newcase bad-layers
L='nope' pre; [ "$rc" = 1 ] || fail "非法 LAYERS 应失败"

echo "preflight-main-ci.test.sh: all cases passed"
