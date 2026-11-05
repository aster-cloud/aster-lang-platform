#!/usr/bin/env bash
# ADR 0053 回归测试：层内并行、stale gate（防列车中途合并）、按 trainId 关联 deploy run、
# 列车清单（train manifest）、列车清理（cleanup-train.sh）。
#
# 做法：用 fixture 驱动的假 gh——`gh api <endpoint>` 读 $FIX/<endpoint 把 / 换成 _>.json，
# 若 dispatch 已发生（$FIX/.dispatched 存在）且有同名 .after 文件则优先读 .after（模拟
# 「发布后才出现的 tag / 制品」）；-q 用真 jq 执行；DELETE 只记录不执行。
# 只依赖 bash + jq + python3。
#
# 用法：bash scripts/release-plan/train-reuse.test.sh
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
# 假 gh：只实现 run-train.sh / cleanup-train.sh 用到的子集。
echo "gh $*" >>"$CALLS"
[ -n "${GH_SLEEP:-}" ] && sleep "$GH_SLEEP"
if [ "${1:-}" = "workflow" ]; then : >"$FIX/.dispatched"; exit 0; fi
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
if [ "$method" = "DELETE" ]; then echo "DELETE $ep" >>"$DELETES"; exit 0; fi
key="$FIX/$(echo "$ep" | tr '/' '_').json"
[ -e "$FIX/.dispatched" ] && [ -e "$key.after" ] && key="$key.after"
[ -e "$key" ] || exit 1
if [ -n "$q" ]; then jq -r "$q" "$key"; else cat "$key"; fi
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/npm"
chmod +x "$TMP/bin/gh" "$TMP/bin/npm"

fail() { echo "FAIL: $*"; echo "--- stderr ---"; cat "$TMP/stderr" 2>/dev/null || true; exit 1; }

# 每个用例一个干净的 fixture 目录。
newcase() {
  FIX="$TMP/fix-$1"; rm -rf "$FIX"; mkdir -p "$FIX"
  CALLS="$FIX/.calls"; DELETES="$FIX/.deletes"; : >"$CALLS"; : >"$DELETES"
  export FIX CALLS DELETES
}
fx() { echo "$2" >"$FIX/$(echo "$1" | tr '/' '_').json${3:-}"; }  # endpoint json [.after]

core_step() {  # $1=version
  echo "{\"repo\":\"aster-lang-core\",\"org\":\"aster-cloud\",\"workflow\":\"release.yml\",\"version\":\"$1\",\"artifactIds\":[\"core:maven\"],\"kinds\":[\"maven\"],\"artifacts\":[{\"id\":\"core:maven\",\"kind\":\"maven\",\"version\":\"$1\",\"mavenPackages\":[\"cloud.aster-lang.aster-lang-core\"]}]}"
}
runtime_step() {
  echo "{\"repo\":\"aster-lang-runtime\",\"org\":\"aster-cloud\",\"workflow\":\"release.yml\",\"version\":\"$1\",\"artifactIds\":[\"runtime:maven\"],\"kinds\":[\"maven\"],\"artifacts\":[{\"id\":\"runtime:maven\",\"kind\":\"maven\",\"version\":\"$1\",\"mavenPackages\":[\"cloud.aster-lang.aster-lang-runtime\"]}]}"
}
API_STEP='{"repo":"aster-api","org":"wontlost-ltd","workflow":"deploy.yml","version":null,"artifactIds":["aster-api:service"],"kinds":["service"],"artifacts":[{"id":"aster-api:service","kind":"service","version":null}]}'

run_train() {  # 其余 env 由调用方给
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=dummy TRAIN_ID=T1 POLL_INTERVAL=0 \
    bash "$RUN" >"$TMP/stdout" 2>"$TMP/stderr"
  rc=$?
  set -e
}

# ── 1. 层内并行：同层两个 step 并发执行，且一个失败不阻止另一个跑完 ──────────────
newcase parallel
# 每次 gh 调用 sleep 3s；每个 step 失败前约 3 次 gh 调用（可见性/tag 存在/等 tag）。
# 串行 ≥ 18s，并行 ≈ 9–12s。
start=$(date +%s)
GH_SLEEP=3 DRY_RUN=false POLL_MAX=1 \
  LAYERS="[[$(core_step 9.9.9),$(runtime_step 9.9.9)]]" run_train
elapsed=$(( $(date +%s) - start ))
[ "$rc" -ne 0 ] || fail "parallel：两个 step 都应失败，实际 rc=0"
grep -q '::error::tag v9.9.9 在 aster-lang-core 未在超时内出现' "$TMP/stderr" || fail "parallel：缺 core 的失败注解"
grep -q '::error::tag v9.9.9 在 aster-lang-runtime 未在超时内出现' "$TMP/stderr" || fail "parallel：缺 runtime 的失败注解（失败 step 不应拖住同层其他 step）"
[ "$elapsed" -lt 16 ] || fail "parallel：同层 step 应并发执行，耗时 ${elapsed}s（串行下限 18s）"
grep -q '::error::Layer 0 失败' "$TMP/stderr" || fail "parallel：应在层末汇总失败并停车"
echo "PASS: 层内并行（${elapsed}s，串行下限 18s），失败 step 不阻塞同层其他 step，层末停车"

# ── 2. stale gate：preflight 记录的 main SHA 与 dispatch 前的 tip 不一致 → 停车 ─────
newcase stale
fx repos/aster-cloud/aster-lang-core/commits/main '{"sha":"bbbbbbb"}'
DRY_RUN=true POLL_MAX=1 MAIN_SHAS='{"aster-lang-core":"aaaaaaa"}' \
  LAYERS="[[$(core_step 9.9.9)]]" run_train
[ "$rc" -ne 0 ] || fail "stale：main 已前进应失败"
grep -q '^::error::aster-lang-core main 已从 preflight 的 aaaaaaa 前进到 bbbbbbb' "$TMP/stderr" \
  || fail "stale：缺 main 前进的注解"
grep -q 'gh workflow run' "$CALLS" && fail "stale：stale 时不得 dispatch"
newcase stale-ok
fx repos/aster-cloud/aster-lang-core/commits/main '{"sha":"aaaaaaa"}'
DRY_RUN=true POLL_MAX=1 MAIN_SHAS='{"aster-lang-core":"aaaaaaa"}' \
  LAYERS="[[$(core_step 9.9.9)]]" run_train
[ "$rc" -eq 0 ] || fail "stale-ok：tip 未变应通过 dry-run，rc=$rc"
echo "PASS: stale gate —— main 前进即停车且不 dispatch；未前进放行"

# ── 3. 成功路径 + train manifest（repo/tag/commit/publishRun 留痕，供下游复用与审计）──
newcase manifest
fx orgs/aster-cloud/packages/maven/cloud.aster-lang.aster-lang-core/versions '[{"name":"9.9.8"}]'
fx orgs/aster-cloud/packages/maven/cloud.aster-lang.aster-lang-core/versions '[{"name":"9.9.9"},{"name":"9.9.8"}]' .after
fx repos/aster-cloud/aster-lang-core/git/refs/tags/v9.9.9 '{"ref":"refs/tags/v9.9.9","object":{"type":"commit","sha":"c0ffee1"}}' .after
fx repos/aster-cloud/aster-lang-core/actions/workflows/release.yml/runs '{"workflow_runs":[{"id":77,"created_at":"2026-01-01T00:00:00Z","head_sha":"c0ffee1"}]}' .after
fx repos/aster-cloud/aster-lang-core/actions/runs/77 '{"id":77,"status":"completed","conclusion":"success"}' .after
export TRAIN_MANIFEST="$FIX/manifest.json"
DRY_RUN=false POLL_MAX=2 LAYERS="[[$(core_step 9.9.9)]]" run_train
[ "$rc" -eq 0 ] || fail "manifest：成功路径 rc=$rc"
jq -e '.steps[] | select(.repo=="aster-lang-core" and .tag=="v9.9.9" and .commit=="c0ffee1" and .run==77 and .result=="published")' \
  "$TRAIN_MANIFEST" >/dev/null || fail "manifest：缺 core v9.9.9 的条目：$(cat "$TRAIN_MANIFEST" 2>/dev/null)"
jq -e '.trainId=="T1"' "$TRAIN_MANIFEST" >/dev/null || fail "manifest：缺 trainId"
unset TRAIN_MANIFEST
echo "PASS: 成功路径写出 train manifest（repo/tag/commit/run）"

# ── 4. service deploy：按 trainId 关联 run（不是「最新一个 dispatch run」）+ 独立上限 ──
newcase service
fx repos/wontlost-ltd/aster-api/actions/workflows/deploy.yml/runs '{"workflow_runs":[
  {"id":2,"display_title":"Deploy","status":"in_progress","created_at":"2026-01-01T00:05:00Z"},
  {"id":1,"display_title":"Deploy · train T1","status":"completed","conclusion":"success","created_at":"2026-01-01T00:01:00Z"}]}' .after
fx repos/wontlost-ltd/aster-api/actions/runs/1 '{"id":1,"status":"completed","conclusion":"success"}' .after
fx repos/wontlost-ltd/aster-api/actions/runs/2 '{"id":2,"status":"in_progress","conclusion":null}' .after
export TRAIN_MANIFEST="$FIX/manifest.json"
DRY_RUN=false POLL_MAX=1 SERVICE_POLL_MAX=1 WONTLOST_TOKEN=w LAYERS="[[$API_STEP]]" run_train
[ "$rc" -eq 0 ] || fail "service：应关联到 display_title 含 trainId 的 run 1（success），rc=$rc"
grep -q 'deploy run 1 success' "$TMP/stderr" || fail "service：应报告 run 1 成功"
jq -e '.steps[] | select(.repo=="aster-api" and .run==1 and .result=="deployed")' "$TRAIN_MANIFEST" >/dev/null \
  || fail "service：manifest 缺 aster-api 条目"
unset TRAIN_MANIFEST
echo "PASS: service deploy 按 trainId 关联正确的 run（忽略更新的无关 run）"

# ── 5. cleanup-train.sh：dry-run 只列不删；实删覆盖 tag 缓存 / 列车 deploy 制品 / 列车自身制品 ──
newcase cleanup
fx repos/aster-cloud/aster-lang-core/actions/caches '{"actions_caches":[{"id":11,"key":"setup-java-Linux-gradle-x","ref":"refs/tags/v9.9.9"}]}'
fx repos/wontlost-ltd/aster-api/actions/workflows/deploy.yml/runs '{"workflow_runs":[
  {"id":1,"display_title":"Deploy · train T1"},{"id":3,"display_title":"Deploy"}]}'
fx repos/wontlost-ltd/aster-api/actions/runs/1/artifacts '{"artifacts":[{"id":21,"name":"quarkus-app-abc"}]}'
fx repos/wontlost-ltd/aster-api/actions/runs/3/artifacts '{"artifacts":[{"id":99,"name":"quarkus-app-zzz"}]}'
fx repos/aster-cloud/aster-lang-platform/actions/runs/500/artifacts '{"artifacts":[{"id":31,"name":"train-T1-manifest"},{"id":32,"name":"unrelated"}]}'
LAYERS2="[[$(core_step 9.9.9)],[$API_STEP]]"
for mode in true false; do
  : >"$DELETES"
  set +e
  PATH="$TMP/bin:$PATH" GH_TOKEN=dummy WONTLOST_TOKEN=w TRAIN_ID=T1 TRAIN_RUN_ID=500 \
    PLATFORM_REPO=aster-cloud/aster-lang-platform DRY_RUN=$mode LAYERS="$LAYERS2" \
    bash "$CLEAN" >"$TMP/stdout" 2>"$TMP/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "cleanup(dry=$mode)：rc=$rc"
  if [ "$mode" = true ]; then
    [ ! -s "$DELETES" ] || fail "cleanup dry-run 不得删除：$(cat "$DELETES")"
    grep -q 'would delete cache 11' "$TMP/stderr" || fail "cleanup dry-run 应列出 cache 11"
  else
    for want in repos/aster-cloud/aster-lang-core/actions/caches/11 \
                repos/wontlost-ltd/aster-api/actions/artifacts/21 \
                repos/aster-cloud/aster-lang-platform/actions/artifacts/31; do
      grep -qx "DELETE $want" "$DELETES" || fail "cleanup 应删除 $want；实际：$(cat "$DELETES")"
    done
    grep -q 'artifacts/99\|artifacts/32' "$DELETES" && fail "cleanup 不得删除非本列车的制品：$(cat "$DELETES")"
  fi
done
# 列车失败（KEEP_RESUME=true）：保留 service deploy 中间制品（续跑复用源），其余照删。
: >"$DELETES"
set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=dummy WONTLOST_TOKEN=w TRAIN_ID=T1 TRAIN_RUN_ID=500 KEEP_RESUME=true \
  DRY_RUN=false LAYERS="$LAYERS2" bash "$CLEAN" >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "cleanup(keep-resume)：rc=$rc"
grep -q 'artifacts/21' "$DELETES" && fail "cleanup(keep-resume)：列车失败时不得删 deploy 中间制品"
grep -qx 'DELETE repos/aster-cloud/aster-lang-core/actions/caches/11' "$DELETES" || fail "cleanup(keep-resume)：tag 缓存仍应删除"
echo "PASS: cleanup-train.sh —— dry-run 只列；实删 tag 缓存 + 本列车 deploy 制品 + 列车自身制品，不误删"
