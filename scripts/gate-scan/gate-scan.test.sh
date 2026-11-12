#!/usr/bin/env bash
# gate-scan.sh / scan.mjs 的本地回归测试。不连集群：kubectl 由本测试的 shim 顶替，
# 按 psql 的 -d 参数返回合成的 JSONL。
#
# 始终运行：--help、用法错误、--dry-run（不得调用 kubectl）。
# 需要两份已构建的 aster-lang-ts（仓库根或 dist）才运行的端到端部分：
#   GATE_SCAN_OLD_TS=<v1.4.0 构建> GATE_SCAN_NEW_TS=<fix/250 构建> bash scripts/gate-scan/gate-scan.test.sh
# 合成源为类型嵌套深度 2/64/65/300；#250 的候选把上限降到 64，期望 depth65、depth300 被报告。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/gate-scan.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/tmp"

fail() { echo "FAIL: $*"; for f in "$TMP"/out "$TMP"/err; do [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; }; done; exit 1; }

# kubectl shim：校验 SQL 走 stdin 且为只读事务，按库名返回对应的合成导出，并记录调用。
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_KUBECTL_LOG"
sql="$(cat)"
grep -q 'BEGIN TRANSACTION READ ONLY' <<<"$sql" || { echo "shim: SQL 不是只读事务" >&2; exit 9; }
case " $* " in
  *" -d aster_api "*) cat "$FAKE_API_JSONL" ;;
  *" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_JSONL" ;;
  *) echo "shim: 未知库 $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
export FAKE_KUBECTL_LOG="$TMP/kubectl.log" FAKE_API_JSONL="$TMP/api.jsonl" FAKE_CLOUD_JSONL="$TMP/cloud.jsonl"
: >"$FAKE_KUBECTL_LOG"

run_script() {  # 期望退出码, 参数...
  local want="$1"; shift
  local rc=0
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmp" bash "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "gate-scan.sh $* 期望 rc=${want}，实际 rc=$rc"
}

# 1. --help / 用法错误
run_script 0 --help
grep -q -- '--old-ts' "$TMP/out" || fail "--help 未列出 --old-ts"
run_script 2 --old-ts v1.4.0
run_script 2 --old-ts v1.4.0 --new-ts x --bogus

# 2. --dry-run：打印两次导出命令与扫描命令，不调用 kubectl
run_script 0 --old-ts v1.4.0 --new-ts fix/250-type-nesting-guard --code E054 --kube-context ctx --dry-run
grep -q 'kubectl --context ctx -n data-services exec -i shared-postgres-1 -- psql -X -At -v ON_ERROR_STOP=1 -d aster_api -f -' "$TMP/out" \
  || fail "dry-run 缺少 aster_api 导出命令"
grep -q -- '-d aster_cloud -v cloud=1 -f -' "$TMP/out" || fail "dry-run 缺少 aster_cloud 导出命令"
grep -q -- 'scan.mjs --old .* --code E054' "$TMP/out" || fail "dry-run 缺少扫描命令"
[ ! -s "$FAKE_KUBECTL_LOG" ] || fail "dry-run 不应调用 kubectl"
[ -z "$(ls -A "$TMP/tmp")" ] || fail "dry-run 退出后临时目录未删除"

if [ -z "${GATE_SCAN_OLD_TS:-}" ] || [ -z "${GATE_SCAN_NEW_TS:-}" ]; then
  echo "SKIP: 未设置 GATE_SCAN_OLD_TS / GATE_SCAN_NEW_TS，跳过端到端扫描"
  echo "PASS (dry-run / 用法)"
  exit 0
fi

# 3. 端到端：合成源（深度 2/64 在 api 库，65/300 在 cloud 库 + 一份两边都失败的坏源）
node -e '
const fs = require("fs");
const src = d => `Module m.t.\n\nRule f given x as ${"list of ".repeat(d - 1)}Int, produce Int:\n  Return 1.`;
const row = (id, kind, content) => JSON.stringify({ id, kind, content });
fs.writeFileSync(process.argv[1], [row("api:depth2", "api-policy-version", src(2)), row("api:depth64", "api-policy-version", src(64))].join("\n") + "\n");
fs.writeFileSync(process.argv[2], [row("cloud:depth65", "cloud-policy", src(65)), row("cloudv:depth300", "cloud-policy-version", src(300)),
  row("cloud:broken", "cloud-policy", "Module m.t.\n\nRule f given x as, produce:")].join("\n") + "\n");
' "$FAKE_API_JSONL" "$FAKE_CLOUD_JSONL"

flagged() { grep -E '^  [^ ]+ \[' "$TMP/out" | awk '{print $1}' | sort | tr '\n' ' '; }

run_script 1 --old-ts "$GATE_SCAN_OLD_TS" --new-ts "$GATE_SCAN_NEW_TS" --code E054
[ "$(flagged)" = "cloud:depth65 cloudv:depth300 " ] || fail "--code E054 应只报告 depth65/depth300，实际：$(flagged)"
grep -q '^gains-E054: 2$' "$TMP/out" || fail "--code E054 计数不对"
grep -q 'list of' "$TMP/out" "$TMP/err" && fail "输出泄露了源码内容"
[ -z "$(ls -A "$TMP/tmp")" ] || fail "退出后导出临时目录未删除"

run_script 1 --old-ts "$GATE_SCAN_OLD_TS" --new-ts "$GATE_SCAN_NEW_TS"
[ "$(flagged)" = "cloud:depth65 cloudv:depth300 " ] || fail "diff 模式应只报告 depth65/depth300，实际：$(flagged)"
grep -q '^newly-failing: 2$' "$TMP/out" || fail "diff 模式应把两者归入 newly-failing"
grep -q '^scanned: 5 ' "$TMP/out" || fail "应扫描 5 份源（两库合并）"

run_script 0 --old-ts "$GATE_SCAN_OLD_TS" --new-ts "$GATE_SCAN_OLD_TS"
grep -q '^result: PASS (0 reported)$' "$TMP/out" || fail "同一构建自比应 PASS"

# 4. 导出为空必须失败（空扫描不算通过）
: >"$FAKE_API_JSONL"; : >"$FAKE_CLOUD_JSONL"
run_script 3 --old-ts "$GATE_SCAN_OLD_TS" --new-ts "$GATE_SCAN_OLD_TS"
[ -z "$(ls -A "$TMP/tmp")" ] || fail "失败退出后导出临时目录未删除"

echo "PASS"
