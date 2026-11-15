#!/usr/bin/env bash
# ADR 0053 修订 A1 回归测试：列车在 L4 接管 aster-api 的 pin bump（run-train.sh 阶段 P / D）。
#
# 做法：
#   - 假 gh：`gh api <endpoint>` 读 $FIX/<endpoint 去掉 ?query、/ 换成 _>[.<METHOD>].json；
#     列车动作（开 PR、合并、重跑、dispatch）会给 fixture 加「状态」，状态变体 <key>.<state>
#     优先（后加的状态优先），用来模拟「合并之后才出现的 push run」等。每次调用连同所用令牌记入 ${CALLS}。
#   - 假远端：GIT_BASE 指向本地目录，$GIT_BASE/wontlost-ltd/aster-api.git 是 bare 仓，
#     main 上有 settings.gradle、setup-aster-build/action.yml 与 verify-sibling-ref-pin.sh（简化版）。
# 只依赖 bash + git + jq + python3。
#
# 用法：bash scripts/release-plan/train-api-pin.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run-train.sh"
CLEAN="$HERE/cleanup-train.sh"
command -v jq >/dev/null || { echo "::error::jq not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# 假 gh：只实现 run-train.sh 阶段 P/D 用到的子集。
echo "TOKEN=${GH_TOKEN:-} gh $*" >>"$CALLS"
addstate() { echo "$1" >>"$FIX/.states"; }
case "${1:-} ${2:-}" in
  "workflow run") addstate dispatched; exit 0 ;;
  "run rerun")    addstate rerun; exit 0 ;;
  "pr merge")
    addstate merge-attempted
    if [ -e "$FIX/.merge-fail" ]; then cat "$FIX/.merge-fail" >&2; exit 1; fi
    addstate merged; exit 0 ;;
esac
[ "${1:-}" = "api" ] || exit 1
shift
method=GET q="" ep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method|-X) method="$2"; shift 2 ;;
    -q|--jq) q="$2"; shift 2 ;;
    -f|-F) shift 2 ;;
    --paginate) shift ;;
    *) ep="$1"; shift ;;
  esac
done
ep="${ep%%\?*}"
if [ "$method" = "DELETE" ]; then echo "DELETE $ep" >>"$FIX/.deletes"; exit 0; fi
# PR head 的 SHA 由列车现做的 commit 决定（含时间戳），测试无法预知：check-runs 统一归一到 HEAD。
ep=$(sed -E 's#/commits/[0-9a-f]{40}/check-runs#/commits/HEAD/check-runs#' <<<"$ep")
key="$FIX/$(echo "$ep" | tr '/' '_').json"
[ "$method" = "GET" ] || key="$key.$method"
[ "$method" = "POST" ] && [ "${ep##*/}" = "pulls" ] && addstate pr
if [ -e "$FIX/.states" ]; then
  while read -r st; do
    { [ -e "$key.$st" ] || [ -e "$key.$st.seq.1" ]; } && { key="$key.$st"; break; }
  done < <(tac "$FIX/.states" 2>/dev/null || tail -r "$FIX/.states")
fi
# 按读取次数切换：<key>.seq.1、.seq.2 …（第 n 次读取用 .seq.n，超出则用最大的那个）。
if [ -e "$key.seq.1" ]; then
  n=$(( $(cat "$key.count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$key.count"
  while [ "$n" -gt 1 ] && [ ! -e "$key.seq.$n" ]; do n=$((n-1)); done
  key="$key.seq.$n"
fi
[ -e "$key" ] || exit 1
if [ -n "$q" ]; then jq -r "$q" "$key"; else cat "$key"; fi
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/npm"
chmod +x "$TMP/bin/gh" "$TMP/bin/npm"

fail() { echo "FAIL: $*"; echo "--- stderr ---"; cat "$TMP/stderr" 2>/dev/null || true; echo "--- calls ---"; cat "$CALLS" 2>/dev/null || true; exit 1; }

API='repos/wontlost-ltd/aster-api'
API_STEP='{"repo":"aster-api","org":"wontlost-ltd","workflow":"deploy.yml","version":null,"pinOwner":"train","pinVersion":"1.0.48","artifactIds":["aster-api:service"],"kinds":["service"],"artifacts":[{"id":"aster-api:service","kind":"service","version":null}]}'
GOOD_JOBS='{"jobs":[{"name":"deploy","conclusion":"success","steps":[]},
  {"name":"image-pin-pr","conclusion":"success","steps":[{"name":"Final stale gate (再确认 github.sha 仍是 origin/main tip)","conclusion":"success"},{"name":"Open/update image-pin PR to k3s","conclusion":"success"}]},
  {"name":"pin-closure-guard","conclusion":"success","steps":[]}]}'

fx() { echo "$2" >"$FIX/$(echo "$1" | tr '/' '_').json${3:-}"; }  # endpoint json [.变体]

# 造 aster-api 假远端：$1=settings pin $2=sibling-ref 默认值 $3=verify 脚本退出码（缺省按真比较）
mkremote() {
  local src="$FIX/src"
  rm -rf "$src" "$GIT_BASE"; mkdir -p "$src/.github/actions/setup-aster-build" "$src/scripts/ci" "$GIT_BASE/wontlost-ltd"
  printf "rootProject.name = 'aster-api'\ndependencyResolutionManagement {\n  versionCatalogs {\n    asterLibs {\n      from('cloud.aster-lang:aster-lang-platform:%s')\n    }\n  }\n}\n" "$1" >"$src/settings.gradle"
  printf 'name: setup\ninputs:\n  require-cross-repo-token:\n    required: false\n    default: "true"\n  sibling-ref:\n    description: x\n    required: false\n    default: "v%s"\nruns:\n  using: composite\n  steps: []\n' "$2" >"$src/.github/actions/setup-aster-build/action.yml"
  if [ -n "${3:-}" ]; then
    printf '#!/usr/bin/env bash\necho "verify stub exit %s"\nexit %s\n' "$3" "$3" >"$src/scripts/ci/verify-sibling-ref-pin.sh"
  else
    cat >"$src/scripts/ci/verify-sibling-ref-pin.sh" <<'V'
#!/usr/bin/env bash
s=$(sed -n "s/.*aster-lang-platform:\([0-9.]*\)'.*/\1/p" settings.gradle)
a=$(sed -n 's/.*default: "v\([0-9.]*\)".*/\1/p' .github/actions/setup-aster-build/action.yml)
echo "settings=$s sibling-ref=v$a"; [ -n "$s" ] && [ "$s" = "$a" ]
V
  fi
  echo "# aster-api" >"$src/README.md"
  git -C "$src" init -q -b main
  git -C "$src" add -A
  git -C "$src" -c user.name=t -c user.email=t@t commit -q -m init
  git clone -q --bare "$src" "$GIT_BASE/wontlost-ltd/aster-api.git"
  BASE=$(git -C "$src" rev-parse HEAD)
  fx "$API/commits/main" "{\"sha\":\"$BASE\"}"
}

newcase() {
  FIX="$TMP/fix-$1"; rm -rf "$FIX"; mkdir -p "$FIX"
  CALLS="$FIX/.calls"; : >"$CALLS"; : >"$FIX/.states"
  GIT_BASE="$FIX/remote"
  export FIX CALLS GIT_BASE
  export TRAIN_MANIFEST="$FIX/manifest.json"
  fx "$API" '{"full_name":"wontlost-ltd/aster-api"}'
}

run_train() {  # 其余 env 由调用方给
  local shas="{\"aster-api\":\"$BASE\"}"
  [ -n "${MAIN_SHAS_OVERRIDE:-}" ] && shas="$MAIN_SHAS_OVERRIDE"
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=cloud WONTLOST_TOKEN=pat PIN_TOKEN=app TRAIN_ID=T1 POLL_INTERVAL=0 \
    MAIN_SHAS="$shas" LAYERS="[[$API_STEP]]" \
    bash "$RUN" >"$TMP/stdout" 2>"$TMP/stderr"
  rc=$?
  set -e
}

remote_branch() { git -C "$GIT_BASE/wontlost-ltd/aster-api.git" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || true; }
# 必需检查 fixture：$1=ci-result 结论 $2=guard 结论 $3=build-hosted 结论 $4=id 起点
checks() {
  echo "{\"check_runs\":[
    {\"id\":$4,\"name\":\"build-hosted / build\",\"status\":\"completed\",\"conclusion\":\"$3\",\"app\":{\"id\":15368},\"details_url\":\"https://github.com/wontlost-ltd/aster-api/actions/runs/900/job/1\"},
    {\"id\":$(($4+1)),\"name\":\"Guard bypass suite (#466)\",\"status\":\"completed\",\"conclusion\":\"$2\",\"app\":{\"id\":15368}},
    {\"id\":$(($4+2)),\"name\":\"ci-result\",\"status\":\"completed\",\"conclusion\":\"$1\",\"app\":{\"id\":15368}}]}"
}
# 成功合并 + push deploy 闭环的 fixture
merged_fixtures() {
  fx "$API/pulls/42" '{"number":42,"merged":true,"merge_commit_sha":"m3rge000"}' .merged
  fx "$API/actions/workflows/deploy.yml/runs" '{"workflow_runs":[
    {"id":701,"event":"push","head_sha":"m3rge000","created_at":"2026-01-01T00:02:00Z"},
    {"id":700,"event":"push","head_sha":"m3rge000","created_at":"2026-01-01T00:01:00Z"},
    {"id":699,"event":"workflow_dispatch","head_sha":"m3rge000","created_at":"2026-01-01T00:00:00Z"}]}' .merged
  fx "$API/actions/runs/700" '{"id":700,"status":"completed","conclusion":"success","head_sha":"m3rge000"}'
  fx "$API/actions/runs/700/jobs" "$GOOD_JOBS"
}

# ── 0. bump-api-pin.py：锚点恰好命中一次才改；否则拒绝（退出 2），不猜着改 ─────────────────
BUMP="$HERE/bump-api-pin.py"
newcase bump
mkremote 1.0.47 1.0.47
B="$FIX/src"
[ "$(python3 "$BUMP" --repo-root "$B" --read)" = "1.0.47 1.0.47" ] || fail "bump：--read 应输出两处版本"
python3 "$BUMP" --repo-root "$B" --write 1.0.48 >/dev/null || fail "bump：--write 失败"
[ "$(python3 "$BUMP" --repo-root "$B" --read)" = "1.0.48 1.0.48" ] || fail "bump：--write 后两处应为 1.0.48"
grep -q 'default: "true"' "$B/.github/actions/setup-aster-build/action.yml" || fail "bump：不得改到其它输入的 default"
set +e
python3 "$BUMP" --repo-root "$B" --write v1.0.49 2>"$TMP/stderr"; r1=$?
printf "\nfrom('cloud.aster-lang:aster-lang-platform:1.0.1')\n" >>"$B/settings.gradle"
python3 "$BUMP" --repo-root "$B" --write 1.0.49 2>>"$TMP/stderr"; r2=$?
set -e
[ "$r1" -eq 2 ] || fail "bump：目标版本带 v 前缀应拒绝"
[ "$r2" -eq 2 ] || fail "bump：settings 锚点命中两次应拒绝"
grep -q '命中 2 次' "$TMP/stderr" || fail "bump：应报锚点命中次数"
echo "PASS: bump-api-pin.py 只改 sibling-ref 段与 settings 锚点；锚点多次命中 / 非 X.Y.Z 目标拒绝"

# ── 1. 主路径：开 PR → 等绿 → --match-head-commit 合并 → 跟随 push deploy（不再 dispatch）──
newcase open
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
merged_fixtures
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=2 SERVICE_FALLBACK_AFTER=2 run_train
[ "$rc" -eq 0 ] || fail "open：rc=$rc"
head=$(remote_branch train/aster-api-pin-1.0.48)
[ -n "$head" ] || fail "open：应推出分支 train/aster-api-pin-1.0.48"
[ "$(git -C "$GIT_BASE/wontlost-ltd/aster-api.git" rev-parse "$head^")" = "$BASE" ] || fail "open：pin commit 的 parent 必须是 preflight SHA"
files=$(git -C "$GIT_BASE/wontlost-ltd/aster-api.git" diff --name-only "$BASE" "$head" | sort | tr '\n' ' ')
[ "$files" = ".github/actions/setup-aster-build/action.yml settings.gradle " ] || fail "open：diff 应恰好两个文件，实际 $files"
git -C "$GIT_BASE/wontlost-ltd/aster-api.git" show "$head:settings.gradle" | grep -q "aster-lang-platform:1.0.48'" || fail "open：settings.gradle 未 bump"
git -C "$GIT_BASE/wontlost-ltd/aster-api.git" show "$head:.github/actions/setup-aster-build/action.yml" | grep -q 'default: "v1.0.48"' || fail "open：sibling-ref 未 bump"
grep -q "TOKEN=app gh api --method POST $API/pulls" "$CALLS" || fail "open：应用 App 令牌开 PR"
grep -q "TOKEN=app gh pr merge 42 --repo wontlost-ltd/aster-api --squash --match-head-commit $head" "$CALLS" || fail "open：应 --match-head-commit 合并 PR head"
grep -q 'gh workflow run' "$CALLS" && fail "open：pin 合并后不得再 dispatch deploy"
grep -q '多个 push deploy run（700 701）' "$TMP/stderr" || fail "open：多个 push run 应列出全部并取最早"
grep -q 'deploy run 700 success' "$TMP/stderr" || fail "open：应跟随最早的 push run 700"
jq -e '.steps[] | select(.repo=="aster-api" and .result=="deployed" and .run==700 and .pin=="merged" and .pinPr==42 and .pinCommit=="m3rge000")' \
  "$TRAIN_MANIFEST" >/dev/null || fail "open：manifest 缺 pin 字段：$(cat "$TRAIN_MANIFEST")"
echo "PASS: 开 PR（恰好两文件，base=preflight SHA）→ 必需检查绿 → --match-head-commit 合并 → 跟随最早的 push deploy run，不再 dispatch"

# ── 2. pin 已在 main（手工 pin / 续跑）：P 跳过 → dispatch，断言 run 的 head_sha 与闭环 ─────
newcase skip
mkremote 1.0.48 1.0.48
fx "$API/actions/workflows/deploy.yml/runs" "{\"workflow_runs\":[{\"id\":5,\"event\":\"workflow_dispatch\",\"display_title\":\"Deploy · train T1\",\"head_sha\":\"$BASE\",\"created_at\":\"2026-01-01T00:00:00Z\"}]}" .dispatched
fx "$API/actions/runs/5" "{\"id\":5,\"status\":\"completed\",\"conclusion\":\"success\",\"head_sha\":\"$BASE\"}"
fx "$API/actions/runs/5/jobs" "$GOOD_JOBS"
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=1 run_train
[ "$rc" -eq 0 ] || fail "skip：rc=$rc"
grep -q 'TOKEN=pat gh workflow run deploy.yml --repo wontlost-ltd/aster-api --ref main -f trainId=T1' "$CALLS" || fail "skip：P 跳过时应按现状 dispatch"
grep -q 'pulls' "$CALLS" && fail "skip：P 跳过时不应碰 PR"
[ -z "$(remote_branch train/aster-api-pin-1.0.48)" ] || fail "skip：不应推分支"
jq -e '.steps[] | select(.repo=="aster-api" and .result=="deployed" and .run==5 and .pin=="skipped")' "$TRAIN_MANIFEST" >/dev/null \
  || fail "skip：manifest 应记 pin=skipped：$(cat "$TRAIN_MANIFEST")"
# dispatch 的 run 部署的不是 preflight SHA → 停车
newcase skip-sha
mkremote 1.0.48 1.0.48
fx "$API/actions/workflows/deploy.yml/runs" '{"workflow_runs":[{"id":5,"event":"workflow_dispatch","display_title":"Deploy · train T1","head_sha":"0ther","created_at":"2026-01-01T00:00:00Z"}]}' .dispatched
fx "$API/actions/runs/5" '{"id":5,"status":"completed","conclusion":"success","head_sha":"0ther"}'
fx "$API/actions/runs/5/jobs" "$GOOD_JOBS"
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "skip-sha：dispatch run 的 head_sha 不等于 preflight SHA 应停车"
grep -q '^::error::.*head_sha 0ther' "$TMP/stderr" || fail "skip-sha：应报 head_sha 不符"
echo "PASS: pin 已在 main → P 跳过，dispatch 并断言 run head_sha == preflight SHA"

# ── 3. 半改（只有一处等于目标）→ 停车，不猜 ───────────────────────────────────
newcase half
mkremote 1.0.48 1.0.47
DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "half：半改应停车"
grep -q '^::error::.*半改' "$TMP/stderr" || fail "half：应报半改"
grep -qE 'pulls|workflow run' "$CALLS" && fail "half：半改时不得开 PR 或 dispatch"
echo "PASS: 两处 pin 半改 → 停车"

# ── 4. stale gate：main 已不是 preflight SHA → 不开 PR ───────────────────────────
newcase stale
mkremote 1.0.47 1.0.47
MAIN_SHAS_OVERRIDE='{"aster-api":"aaaaaaa"}' DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "stale：main 前进应停车"
grep -q "^::error::aster-api main 已从 preflight 的 aaaaaaa 前进到 $BASE" "$TMP/stderr" || fail "stale：缺 main 前进注解"
[ -z "$(remote_branch train/aster-api-pin-1.0.48)" ] || fail "stale：不得推分支"
echo "PASS: stale gate —— pin PR 的 base 必须是 preflight SHA"

# ── 5. 复用同名 open PR：head 内容一致 → 不 push、不新开；不一致 → force-push ──────────
newcase reuse
mkremote 1.0.47 1.0.47
# 先跑一趟（CI 一直 pending → 轮询上限停车），让列车自己推出 head；第二趟续跑时复用它。
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
DRY_RUN=false POLL_MAX=1 PIN_CI_POLL_MAX=0 run_train
[ "$rc" -ne 0 ] || fail "reuse：CI 未出结果时应在上限后停车"
grep -q '^::error::.*PR #42 的必需检查未在' "$TMP/stderr" || fail "reuse：应报必需检查等待超时"
head=$(remote_branch train/aster-api-pin-1.0.48)
tree=$(git -C "$GIT_BASE/wontlost-ltd/aster-api.git" rev-parse "$head^{tree}")
fx "$API/pulls" "[{\"number\":42,\"head\":{\"ref\":\"train/aster-api-pin-1.0.48\",\"sha\":\"$head\"}}]"
fx "$API/git/commits/$head" "{\"sha\":\"$head\",\"tree\":{\"sha\":\"$tree\"},\"parents\":[{\"sha\":\"$BASE\"}]}"
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
merged_fixtures
: >"$CALLS"; : >"$FIX/.states"
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=2 SERVICE_FALLBACK_AFTER=2 run_train
[ "$rc" -eq 0 ] || fail "reuse：续跑应复用 PR 并合并，rc=$rc"
grep -q 'POST' "$CALLS" && fail "reuse：不应再开 PR"
[ "$(remote_branch train/aster-api-pin-1.0.48)" = "$head" ] || fail "reuse：head 一致时不得 force-push"
grep -q "gh pr merge 42 .*--match-head-commit $head" "$CALLS" || fail "reuse：应合并原 head"
# 内容（tree）一致但 base 不是 preflight SHA → 也要在 preflight SHA 上重建并 force-push
fx "$API/git/commits/$head" "{\"sha\":\"$head\",\"tree\":{\"sha\":\"$tree\"},\"parents\":[{\"sha\":\"0ldbase\"}]}"
: >"$CALLS"; : >"$FIX/.states"
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=2 SERVICE_FALLBACK_AFTER=2 run_train
[ "$rc" -eq 0 ] || fail "reuse(旧 base)：rc=$rc"
[ "$(remote_branch train/aster-api-pin-1.0.48)" != "$head" ] || fail "reuse(旧 base)：base 不是 preflight SHA 时应 force-push"
# head 内容不一致（例如 base 已不是 preflight SHA）→ force-push 新 commit
newcase reuse-stale-head
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[{"number":42,"head":{"ref":"train/aster-api-pin-1.0.48","sha":"0ldhead"}}]'
fx "$API/git/commits/0ldhead" '{"sha":"0ldhead","tree":{"sha":"0ldtree"},"parents":[{"sha":"0ldbase"}]}'
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
merged_fixtures
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=2 SERVICE_FALLBACK_AFTER=2 run_train
[ "$rc" -eq 0 ] || fail "reuse-stale-head：rc=$rc"
new=$(remote_branch train/aster-api-pin-1.0.48)
[ -n "$new" ] && [ "$new" != 0ldhead ] || fail "reuse-stale-head：应 force-push 新 commit"
grep -q 'POST' "$CALLS" && fail "reuse-stale-head：已有 PR 时不应再开"
grep -q "gh pr merge 42 .*--match-head-commit $new" "$CALLS" || fail "reuse-stale-head：应合并新 head"
echo "PASS: 续跑复用同名 PR（内容一致不 push），内容不一致则 force-push"

# ── 6. CI 失败（非超时）→ 不重跑，停车，PR 留着 ──────────────────────────────────
newcase ci-fail
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks failure success failure 10)"
fx "$API/check-runs/10/annotations" '[{"message":"Process completed with exit code 1."}]'
DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "ci-fail：应停车"
grep -q '^::error::.*不是可证实的超时' "$TMP/stderr" || fail "ci-fail：应说明不是可证实超时"
grep -qE 'run rerun|pr merge' "$CALLS" && fail "ci-fail：不得重跑或合并"
# cancelled（人工取消/并发组取消）且注解无超时文案 → 同样不重跑
newcase ci-cancel
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks failure failure cancelled 10)"
fx "$API/check-runs/10/annotations" '[{"message":"The operation was canceled."}]'
DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "ci-cancel：应停车"
grep -q 'run rerun' "$CALLS" && fail "ci-cancel：cancelled 不得重跑"
echo "PASS: 必需检查失败 / cancelled 且无超时证据 → 不重跑、不合并，停车"

# ── 7. 可证实超时 → 只重跑一次（run_attempt==1）；attempt>=2 不再重跑 ─────────────────
for proof in timed_out annotation; do
  newcase "timeout-$proof"
  mkremote 1.0.47 1.0.47
  fx "$API/pulls" '[]'
  fx "$API/pulls" '{"number":42}' .POST
  if [ "$proof" = timed_out ]; then
    fx "$API/commits/HEAD/check-runs" "$(checks failure failure timed_out 10)"
  else
    fx "$API/commits/HEAD/check-runs" "$(checks failure failure cancelled 10)"
    fx "$API/check-runs/10/annotations" '[{"message":"The job running on runner GitHub Actions 7 has exceeded the maximum execution time of 40 minutes."}]'
  fi
  # 重跑后第一轮仍看到旧的失败结果（新 attempt 的 check-run 尚未建出），不得据此再判失败/再重跑。
  fx "$API/commits/HEAD/check-runs" "$(checks failure failure timed_out 10)" .rerun.seq.1
  fx "$API/commits/HEAD/check-runs" "$(checks success success success 20)" .rerun.seq.2
  fx "$API/actions/runs/900" '{"id":900,"run_attempt":1}'
  merged_fixtures
  DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=2 SERVICE_FALLBACK_AFTER=2 run_train
  [ "$rc" -eq 0 ] || fail "timeout-${proof}：重跑后变绿应合并，rc=$rc"
  [ "$(grep -c 'TOKEN=app gh run rerun 900 --failed --repo wontlost-ltd/aster-api' "$CALLS")" -eq 1 ] || fail "timeout-${proof}：应恰好重跑一次"
  grep -q 'gh pr merge 42' "$CALLS" || fail "timeout-${proof}：重跑变绿后应合并"
done
newcase timeout-attempt2
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks failure failure timed_out 10)"
fx "$API/actions/runs/900" '{"id":900,"run_attempt":2}'
DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "timeout-attempt2：已重跑过应停车"
grep -q 'run rerun' "$CALLS" && fail "timeout-attempt2：run_attempt>=2 不得再重跑"
grep -q '^::error::.*第 2 次尝试' "$TMP/stderr" || fail "timeout-attempt2：应说明已重跑过"
echo "PASS: 可证实超时（timed_out 或注解）且 run_attempt==1 → 重跑一次；attempt>=2 停车"

# ── 8. strict 拒绝合并（main 前进）→ 停车，不 update-branch ──────────────────────────
newcase strict
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
echo 'X Pull request wontlost-ltd/aster-api#42 is not mergeable: the base branch policy prohibits the merge.' >"$FIX/.merge-fail"
fx "$API/commits/main" '{"sha":"n3wtip"}' .merge-attempted
DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "strict：合并被拒应停车"
grep -q "^::error::.*main 已从 $BASE 前进到 n3wtip" "$TMP/stderr" || fail "strict：应报 main 前进"
grep -q 'fromLayer' "$TMP/stderr" || fail "strict：应提示 fromLayer 续跑"
grep -q 'update-branch' "$CALLS" && fail "strict：不得自动 update-branch"
jq -e '.steps[] | select(.repo=="aster-api")' "$TRAIN_MANIFEST" >/dev/null 2>&1 && fail "strict：未合并不应记 pin-merged"
echo "PASS: strict 拒绝合并 → 停车并提示续跑，不 update-branch"

# ── 9. push deploy run 判过时 / 未出现 → 停车；manifest 仍记下 pin 合并 ────────────────
newcase push-stale
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
merged_fixtures
fx "$API/actions/runs/700/jobs" '{"jobs":[{"name":"image-pin-pr","conclusion":"success","steps":[{"name":"Open/update image-pin PR to k3s","conclusion":"skipped"}]},{"name":"pin-closure-guard","conclusion":"success"}]}'
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=2 SERVICE_FALLBACK_AFTER=2 run_train
[ "$rc" -ne 0 ] || fail "push-stale：判过时应停车"
grep -q '^::error::.*判过时' "$TMP/stderr" || fail "push-stale：应报判过时"
jq -e '.steps[] | select(.repo=="aster-api" and .result=="pin-merged" and .pinCommit=="m3rge000" and .pinPr==42)' "$TRAIN_MANIFEST" >/dev/null \
  || fail "push-stale：D 失败时 manifest 仍应记下 pin 合并：$(cat "$TRAIN_MANIFEST" 2>/dev/null)"
newcase push-missing
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
fx "$API/pulls/42" '{"number":42,"merged":true,"merge_commit_sha":"m3rge000"}' .merged
fx "$API/actions/workflows/deploy.yml/runs" '{"workflow_runs":[{"id":9,"event":"workflow_dispatch","head_sha":"m3rge000","created_at":"2026-01-01T00:00:00Z"}]}'
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=5 SERVICE_FALLBACK_AFTER=2 run_train
[ "$rc" -ne 0 ] || fail "push-missing：push run 不出现应停车"
grep -q '^::error::.*push deploy run 在 2 轮内未出现' "$TMP/stderr" || fail "push-missing：应报 push run 未出现"
grep -q 'run 9' "$TMP/stderr" && fail "push-missing：不得回退关联到 dispatch run"
echo "PASS: push deploy run 判过时 / 未出现 → 停车；manifest 记下 pin 合并"

# ── 10. dry-run：只读令牌、只读调用；不推分支、不开 PR、不合并、不重跑、不 dispatch ─────
newcase dry
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
DRY_RUN=true POLL_MAX=1 run_train
[ "$rc" -eq 0 ] || fail "dry：rc=$rc"
grep -qE -- '--method (POST|PATCH|PUT|DELETE)|pr merge|run rerun|workflow run' "$CALLS" && fail "dry：不得有写调用：$(cat "$CALLS")"
[ -z "$(remote_branch train/aster-api-pin-1.0.48)" ] || fail "dry：不得推分支"
grep -q "TOKEN=app gh api $API -q" "$CALLS" || fail "dry：应用 App 令牌读仓（验证安装）"
grep -q "TOKEN=app gh api --method GET $API/pulls" "$CALLS" || fail "dry：应查询同名 PR"
grep -q '^+.*aster-lang-platform:1.0.48' "$TMP/stderr" || fail "dry：应打印本地生成的 diff"
jq -e '.steps[] | select(.repo=="aster-api" and .result=="dry-run" and .pinAction=="bump")' "$TRAIN_MANIFEST" >/dev/null \
  || fail "dry：manifest 应记 pinAction=bump：$(cat "$TRAIN_MANIFEST")"
newcase dry-skip
mkremote 1.0.48 1.0.48
DRY_RUN=true POLL_MAX=1 run_train
[ "$rc" -eq 0 ] || fail "dry-skip：rc=$rc"
jq -e '.steps[] | select(.repo=="aster-api" and .result=="dry-run" and .pinAction=="skip")' "$TRAIN_MANIFEST" >/dev/null \
  || fail "dry-skip：manifest 应记 pinAction=skip"
echo "PASS: dry-run 只读（App 令牌读仓 + 查 PR + 本地 diff），manifest 记 pinAction"

# ── 11. fail-closed：缺 App 令牌 / verify 失败 / 令牌将过期 ────────────────────────────
newcase no-token
mkremote 1.0.47 1.0.47
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=cloud WONTLOST_TOKEN=pat PIN_TOKEN='' TRAIN_ID=T1 POLL_INTERVAL=0 DRY_RUN=true POLL_MAX=1 \
  MAIN_SHAS="{\"aster-api\":\"$BASE\"}" LAYERS="[[$API_STEP]]" bash "$RUN" >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "no-token：缺 App 令牌应失败（dry-run 也要）"
grep -q '^::error::.*TRAIN_PIN_APP_CLIENT_ID' "$TMP/stderr" || fail "no-token：报错应指明要配的 var/secret"
newcase verify-fail
mkremote 1.0.47 1.0.47 1
fx "$API/pulls" '[]'
DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "verify-fail：verify-sibling-ref-pin.sh 失败应停车"
grep -q '^::error::.*verify-sibling-ref-pin.sh' "$TMP/stderr" || fail "verify-fail：应报 verify 未通过"
[ -z "$(remote_branch train/aster-api-pin-1.0.48)" ] || fail "verify-fail：不得推分支"
newcase token-expiry
mkremote 1.0.47 1.0.47
fx "$API/pulls" '[]'
fx "$API/pulls" '{"number":42}' .POST
fx "$API/commits/HEAD/check-runs" "$(checks success success success 10)"
PIN_TOKEN_ISSUED_AT=$(( $(date +%s) - 4000 )) DRY_RUN=false POLL_MAX=1 run_train
[ "$rc" -ne 0 ] || fail "token-expiry：令牌将过期应停车"
grep -q '^::error::.*令牌' "$TMP/stderr" || fail "token-expiry：应报令牌将过期"
grep -q 'pr merge' "$CALLS" && fail "token-expiry：令牌将过期时不得尝试合并"
echo "PASS: fail-closed —— 缺 App 令牌、verify 失败、令牌将过期"

# ── 12. TO_LAYER + 已有 manifest：分两段跑（L4 前签发令牌），manifest 合并两段 ─────────
newcase split
echo '{"trainId":"T1","steps":[{"repo":"aster-lang-core","org":"aster-cloud","workflow":"release.yml","artifactIds":["core:maven"],"tag":"v1.0.48","commit":"c0ffee","run":77,"result":"published"}]}' >"$TRAIN_MANIFEST"
mkremote 1.0.48 1.0.48
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=cloud WONTLOST_TOKEN=pat PIN_TOKEN=app TRAIN_ID=T1 POLL_INTERVAL=0 DRY_RUN=true POLL_MAX=1 \
  FROM_LAYER=0 TO_LAYER=-1 MAIN_SHAS="{\"aster-api\":\"$BASE\"}" LAYERS="[[$API_STEP]]" bash "$RUN" >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "split：TO_LAYER=-1 应不跑任何层，rc=$rc"
[ ! -s "$CALLS" ] || fail "split：TO_LAYER=-1 不应有任何调用"
DRY_RUN=true POLL_MAX=1 run_train
jq -e '[.steps[].repo] | sort == ["aster-api","aster-lang-core"]' "$TRAIN_MANIFEST" >/dev/null \
  || fail "split：第二段应保留第一段的 manifest 条目：$(cat "$TRAIN_MANIFEST")"
echo "PASS: TO_LAYER 分段执行，第二段合并已有 manifest"

# ── 13. cleanup-train.sh：按 manifest 的 run ID 补清 push deploy run 的中间制品 ────────
newcase cleanup-manifest
echo '{"trainId":"T1","steps":[{"repo":"aster-api","org":"wontlost-ltd","workflow":"deploy.yml","artifactIds":["aster-api:service"],"run":700,"result":"deployed","pin":"merged"}]}' >"$TRAIN_MANIFEST"
fx "$API/actions/workflows/deploy.yml/runs" '{"workflow_runs":[]}'
fx "$API/actions/runs/700/artifacts" '{"artifacts":[{"id":81,"name":"quarkus-app-k"}]}'
DELETES="$FIX/.deletes"; : >"$DELETES"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=cloud WONTLOST_TOKEN=pat TRAIN_ID=T1 DRY_RUN=false \
  LAYERS="[[$API_STEP]]" bash "$CLEAN" >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "cleanup-manifest：rc=$rc"
grep -qx "DELETE $API/actions/artifacts/81" "$DELETES" || fail "cleanup-manifest：应按 manifest 的 run 700 删除制品 81；实际：$(cat "$DELETES")"
: >"$DELETES"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=cloud WONTLOST_TOKEN=pat TRAIN_ID=T1 DRY_RUN=false KEEP_RESUME=true \
  LAYERS="[[$API_STEP]]" bash "$CLEAN" >"$TMP/stdout" 2>"$TMP/stderr"
set -e
[ ! -s "$DELETES" ] || fail "cleanup-manifest：KEEP_RESUME 时不得删 deploy 中间制品"
echo "PASS: cleanup-train.sh 按 manifest 的 run ID 补清 push deploy run 的中间制品"
