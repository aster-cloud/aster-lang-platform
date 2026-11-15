#!/usr/bin/env bash
# check-artifact.py 的 pinOwner 回归测试（ADR 0053 修订 A1 §3），表驱动。
#
# pinOwner=train 时，aster-api:service 的 pin 允许两种取值：== platformVersion（阶段 P 跳过），
# 或严格小于且 aster-lang-platform 上存在 v<pin> tag（阶段 P 负责 bump）；其余判漂移。
# 无论哪种取值，settings.gradle 与 setup-aster-build 的 sibling-ref 默认值都必须一致。
#
# 做法：每个用例造一个最小的「aster-api 仓根」（两处 pin）+ 一份最小 plan，
# 用本地 bare 仓顶替 https://github.com/aster-cloud/aster-lang-platform（--platform-remote），
# tag 是否存在由本地仓决定。只依赖 bash + git + python3。
#
# 用法：bash scripts/release-plan/check-artifact.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-artifact.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 本地「platform 远端」：已发布的旧版本 tag。
REMOTE="$TMP/platform.git"
git init -q --bare "$REMOTE"
git -C "$TMP" init -q seed
git -C "$TMP/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m seed
for t in v1.0.9 v1.9.0 v1.0.46; do git -C "$TMP/seed" tag "$t"; done
git -C "$TMP/seed" push -q "$REMOTE" --tags

fail() { echo "FAIL: $*"; echo "--- stdout ---"; cat "$TMP/out" 2>/dev/null || true; echo "--- stderr ---"; cat "$TMP/err" 2>/dev/null || true; exit 1; }

# $1=目标 platformVersion $2=settings pin $3=sibling-ref 默认值（不带 v）$4=pinOwner（空=不写字段）
mkcase() {
  ROOT="$TMP/repo"; rm -rf "$ROOT"; mkdir -p "$ROOT/.github/actions/setup-aster-build"
  printf "dependencyResolutionManagement {\n  versionCatalogs {\n    asterLibs {\n      from('cloud.aster-lang:aster-lang-platform:%s')\n    }\n  }\n}\n" "$2" >"$ROOT/settings.gradle"
  cat >"$ROOT/.github/actions/setup-aster-build/action.yml" <<EOF
name: setup
inputs:
  require-cross-repo-token:
    required: false
    default: "true"
  sibling-ref:
    description: x
    required: false
    default: "v$3"
runs:
  using: composite
  steps: []
EOF
  local owner=""
  [ -n "$4" ] && owner="\"pinOwner\": \"$4\","
  cat >"$TMP/plan.json" <<EOF
{"platformVersion":"$1","ecosystemVersion":"$1","artifacts":[
 {"id":"aster-api:service","repo":"aster-api","org":"wontlost-ltd","kind":"service",$owner
  "versionSource":"none","expectedVersion":null,"expectedPlatformPin":"$1","releaseWorkflow":"deploy.yml"}]}
EOF
  : >"$TMP/actions"
}

check() {  # 其余参数透传给 check-artifact.py
  set +e
  python3 "$CHECK" --plan "$TMP/plan.json" --artifact aster-api:service --repo-root "$ROOT" \
    --platform-remote "${PLATFORM_REMOTE:-$REMOTE}" --pin-action-file "$TMP/actions" "$@" >"$TMP/out" 2>"$TMP/err"
  rc=$?
  set -e
}

# ── 1. 表驱动：pinOwner=train ───────────────────────────────────────────────
# 目标 | settings pin | sibling-ref | 期望 rc | 期望 api_pin_action（漂移时为空）| stderr 关键词
CASES=(
  "1.0.47|1.0.47|1.0.47|0|skip|"
  "1.0.47|1.0.46|1.0.46|0|bump|"
  "1.0.10|1.0.9|1.0.9|0|bump|"
  "1.10.0|1.9.0|1.9.0|0|bump|"
  "1.0.47|1.0.45|1.0.45|1||tag v1.0.45 不存在"
  "1.0.47|1.0.48|1.0.48|1||高于目标"
  "1.0.47|1.0.47-rc1|1.0.47|1||无法解析"
  "1.0.47|1.0.46|1.0.47|1||不一致"
  "1.0.47|1.0.47|1.0.46|1||不一致"
  "1.0.47-rc1|1.0.46|1.0.46|1||无法解析"
)
for c in "${CASES[@]}"; do
  IFS='|' read -r tgt pin sib want_rc want_action want_err <<<"$c"
  mkcase "$tgt" "$pin" "$sib" train
  check
  [ "$rc" = "$want_rc" ] || fail "[$c] rc=${rc}，期望 $want_rc"
  got_action=$(sed -n 's/^aster-api:service=//p' "$TMP/actions")
  [ "$got_action" = "$want_action" ] || fail "[$c] api_pin_action=${got_action}，期望 $want_action"
  if [ -n "$want_err" ]; then
    grep -q "^::error::.*$want_err" "$TMP/err" || fail "[$c] stderr 缺「${want_err}」"
  fi
done
echo "PASS: pinOwner=train 表驱动 ${#CASES[@]} 例（整数三元组比较、tag 校验、两处一致、无法解析判漂移）"

# bump 时打印两处「旧 → 新」。
mkcase 1.0.47 1.0.46 1.0.46 train
check
grep -q 'settings.gradle 1.0.46 → 1.0.47' "$TMP/out" || fail "bump 时应打印 settings.gradle 旧 → 新"
grep -q 'sibling-ref v1.0.46 → v1.0.47' "$TMP/out" || fail "bump 时应打印 sibling-ref 旧 → 新"
echo "PASS: bump 时打印两处旧 → 新"

# ── 2. tag 查询失败（网络/鉴权）→ fail-closed，且与「tag 不存在」区分 ──────────────
mkcase 1.0.47 1.0.46 1.0.46 train
PLATFORM_REMOTE="$TMP/no-such-remote.git" check
[ "$rc" -ne 0 ] || fail "tag 查询失败应 fail-closed"
grep -q '^::error::.*查询失败' "$TMP/err" || fail "查询失败应报「查询失败」"
grep -q '不存在' "$TMP/err" && fail "查询失败不得报成「tag 不存在」"
[ ! -s "$TMP/actions" ] || fail "失败时不得写 api_pin_action"
echo "PASS: tag 查询失败 fail-closed，报错区分「查询失败」与「不存在」"

# ── 3. pinOwner 缺省（human）：保持现行断言，旧版本 pin 判漂移，不查 sibling-ref ─────
mkcase 1.0.47 1.0.46 1.0.46 ""
check
[ "$rc" -ne 0 ] || fail "human：pin != platformVersion 应判漂移"
grep -q "platform pin '1.0.46' != expected '1.0.47'" "$TMP/err" || fail "human：应沿用原报错文案"
[ ! -s "$TMP/actions" ] || fail "human：不应写 api_pin_action"
mkcase 1.0.47 1.0.47 1.0.40 human
check
[ "$rc" -eq 0 ] || fail "human：现行断言只看 settings pin，rc=$rc"
echo "PASS: pinOwner 缺省/human 行为与现行一致"

# ── 4. 非法 pinOwner / pinOwner=train 用在非 service 制品 → 失败 ───────────────────
mkcase 1.0.47 1.0.47 1.0.47 robot
check
[ "$rc" -ne 0 ] || fail "非法 pinOwner 应失败"
grep -q "^::error::.*pinOwner" "$TMP/err" || fail "非法 pinOwner 应报 pinOwner 错误"
mkcase 1.0.47 1.0.47 1.0.47 train
python3 - "$TMP/plan.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["artifacts"][0].update(kind="maven", versionSource="catalog-derived", expectedVersion="1.0.47")
json.dump(d, open(p, "w"))
PY
check
[ "$rc" -ne 0 ] || fail "pinOwner=train 只适用于 service 制品"
grep -q "^::error::.*pinOwner=train" "$TMP/err" || fail "非 service 的 pinOwner=train 应报错"
echo "PASS: 非法 pinOwner / 非 service 制品的 pinOwner=train 被拒"

# ── 5. coalesce 带出 pinOwner（缺省 human）与 pinVersion：用 fixture plan，不依赖仓里 plan 的取值 ─────
for owner in train human ""; do
  mkcase 1.0.48 1.0.47 1.0.47 "$owner"
  python3 - "$TMP/plan.json" <<'PY2'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["artifacts"].append({"id": "core:maven", "repo": "aster-lang-core", "kind": "maven",
    "versionSource": "catalog-derived", "expectedVersion": "1.0.48", "expectedPlatformPin": "1.0.48",
    "releaseWorkflow": "release.yml", "mavenPackages": ["cloud.aster-lang.aster-lang-core"]})
d["releaseOrder"] = [["core:maven"], ["aster-api:service"]]
json.dump(d, open(p, "w"))
PY2
  STEPS="$(python3 "$HERE/coalesce.py" --plan "$TMP/plan.json")"
  want="${owner:-human}"
  [ "$(jq -r '.[1][0].pinOwner' <<<"$STEPS")" = "$want" ] || fail "coalesce(pinOwner=${owner:-缺省})：aster-api 的 pinOwner 应为 $want"
  [ "$(jq -r '.[1][0].pinVersion' <<<"$STEPS")" = "1.0.48" ] || fail "coalesce：aster-api 的 pinVersion 应为 expectedPlatformPin"
  [ "$(jq -r '.[0][0].pinOwner' <<<"$STEPS")" = "human" ] || fail "coalesce：未声明 pinOwner 的制品应缺省 human"
done
echo "PASS: coalesce 带出 pinOwner（train / human / 缺省 human）与 pinVersion（fixture plan）"
