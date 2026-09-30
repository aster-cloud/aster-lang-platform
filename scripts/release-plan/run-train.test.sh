#!/usr/bin/env bash
# run-train.sh 的回归测试（issue #85）：等 tag 超时时，::error:: 必须出现在日志
# （stderr）里而不是被 `commit=$(wait_tag_commit ...)` 的命令替换吞掉。
#
# 做法：用假 gh 模拟「dispatch 成功但 tag 永不出现」（gh workflow run 成功，
# gh api 一律失败），把轮询压到 1 次 × 0s，断言脚本非零退出且 stderr 含超时注解。
# 只依赖 bash + jq；gh/npm 由本测试的 shim 顶替。
#
# 用法：bash scripts/release-plan/run-train.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/run-train.sh"
command -v jq >/dev/null || { echo "::error::jq not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
# gh shim：`gh workflow run` 视为 dispatch 成功；其余（gh api）一律失败 → tag 不存在、
# 制品不可见。npm shim 只为通过脚本开头的 command -v 检查。
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "workflow" ] && exit 0
exit 1
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/npm"
chmod +x "$TMP/bin/gh" "$TMP/bin/npm"

LAYERS='[[{"repo":"aster-lang-core","org":"aster-cloud","workflow":"release.yml","version":"9.9.9","artifactIds":["core:maven"],"kinds":["maven"],"artifacts":[{"id":"core:maven","kind":"maven","version":"9.9.9","mavenPackages":["cloud.aster-lang.aster-lang-core"]}]}]]'

set +e
PATH="$TMP/bin:$PATH" GH_TOKEN=dummy TRAIN_ID=test DRY_RUN=false \
  POLL_INTERVAL=0 POLL_MAX=1 LAYERS="$LAYERS" \
  bash "$SCRIPT" >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e

fail() { echo "FAIL: $*"; echo "--- stdout ---"; cat "$TMP/stdout"; echo "--- stderr ---"; cat "$TMP/stderr"; exit 1; }

[ "$rc" -ne 0 ] || fail "等 tag 超时应非零退出，实际 rc=0"
grep -q '::error::tag v9.9.9 在 aster-lang-core 未在超时内出现' "$TMP/stderr" \
  || fail "stderr 缺少等 tag 超时的 ::error:: 注解"
grep -q '::error::aster-lang-core/release.yml dispatch 后 v9.9.9 未出现' "$TMP/stderr" \
  || fail "stderr 缺少 run_step 的显式失败说明"
grep -q '::error::' "$TMP/stdout" && fail "::error:: 不应写到 stdout（会被命令替换捕获）"

echo "PASS: run-train.sh 等 tag 超时 → rc=${rc}，::error:: 已写入 stderr"
