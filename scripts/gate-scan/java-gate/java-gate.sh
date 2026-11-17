#!/usr/bin/env bash
# 发布列车门禁扫描的 Java 侧（生产编译路径）。两个子命令：
#
#   classpath --api <aster-api 检出> --out <文件>
#       在 aster-api 检出里（同级目录放好 aster-lang-core / -runtime / -truffle / -validation / -hi / -locales 的目标版本，
#       aster-api 的 settings.gradle 会 composite 替换它们）构建 :replay，把测试运行时 classpath 写到 <文件>。
#       用 gate-cp.init.gradle 注入任务，不改 aster-api 仓的任何文件。旧版、新版各建一份。
#
#   scan --old-cp <文件> --new-cp <文件> --sources <jsonl> [--sources …]
#        [--ts-scan <scan 输出> | --ts-old-sources-ok N --ts-sources-total M] [--max-gap-pct P]
#       用新版 classpath 编译 Main / Worker，再在两侧各自的隔离类加载器里编译每份源 × 每个 lexicon，报告差异。
#       --ts-scan 给 gate-scan.sh scan 的输出文件（取其中 `old sources ok in any lexicon: N / M`），或直接给 N 与 M：
#       M 必须等于本次的源数（同一份导出），Java 旧版在任一 lexicon 下能编译的源数与 N 差距超过 P%（缺省 5）即退出码 3
#       （Java 结果作废，通常是缺语言包）。不给时打印 `sanity: SKIPPED`，只靠四个 lexicon 的预检。
#
# 只打印 id / kind / lexicon / 诊断码 / IR 键路径，从不打印源码。
# 退出码：0 = PASS；1 = REVIEW（有需复核项）；2 = 用法错误；3 = 环境错误 / 结果不可信——只有 0 算通过。
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DONE=0
TMP=""
finish() {
  local rc=$?
  [ -n "$TMP" ] && rm -rf "$TMP"
  # 非正常路径的中止（含 set -e / set -u）一律按 3 处理，避免被当成 1（REVIEW）或 0
  if [ "$DONE" != 1 ] && [ "$rc" -ne 2 ] && [ "$rc" -ne 3 ]; then echo "result: ERROR (java-gate.sh aborted, rc=$rc)"; exit 3; fi
}
trap finish EXIT
trap 'exit 3' INT TERM HUP

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "java-gate.sh：$*" >&2; exit 3; }
# 取选项的值：缺值或下一个仍是选项 = 用法错误（退出码 2），不能落到 set -u 的中止（那会变成 3）
need() { if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#--}" != "$2" ]; then echo "$1 缺少取值" >&2; usage; fi; }

java_home() {
  if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then echo "$JAVA_HOME"; return; fi
  if [ -x /usr/libexec/java_home ]; then /usr/libexec/java_home -v 25 2>/dev/null && return; fi
  local javac; javac="$(command -v javac || true)"
  [ -n "$javac" ] || die "找不到 JDK 25（设 JAVA_HOME）"
  dirname "$(dirname "$(readlink -f "$javac" 2>/dev/null || echo "$javac")")"
}

cmd_classpath() {
  local api="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --api) need "$@"; api="$2"; shift 2 ;;
      --out) need "$@"; out="$2"; shift 2 ;;
      *) echo "未知参数：$1" >&2; usage ;;
    esac
  done
  [ -n "$api" ] && [ -n "$out" ] || usage
  [ -x "$api/gradlew" ] || die "$api 不是 aster-api 检出（缺 gradlew）"
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  (cd "$api" && ./gradlew -q -I "$HERE/gate-cp.init.gradle" :replay:printGateClasspath "-PgateCpOut=$out") \
    || die "构建 classpath 失败（看上面的 Gradle 输出）"
  check_cp "$out"
  echo "classpath: $out ($(tr ':' '\n' <"$out" | grep -c .) entries)"
}

check_cp() {
  local cp="$1" entry
  [ -s "$cp" ] || die "classpath 文件不存在或为空：$cp"
  local -a entries=()
  IFS=: read -r -a entries <"$cp" || true
  [ ${#entries[@]} -gt 0 ] || die "classpath 文件为空：$cp"
  for entry in "${entries[@]}"; do
    [ -z "$entry" ] || [ -e "$entry" ] || die "classpath 条目不存在：${entry}（${cp} 需要重建）"
  done
}

cmd_scan() {
  local old_cp="" new_cp="" ts_scan="" ts_ok="" ts_total="" gap=""
  local -a sources=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --old-cp) need "$@"; old_cp="$2"; shift 2 ;;
      --new-cp) need "$@"; new_cp="$2"; shift 2 ;;
      --sources) need "$@"; sources+=("$2"); shift 2 ;;
      --ts-scan) need "$@"; ts_scan="$2"; shift 2 ;;
      --ts-old-sources-ok) need "$@"; ts_ok="$2"; shift 2 ;;
      --ts-sources-total) need "$@"; ts_total="$2"; shift 2 ;;
      --max-gap-pct) need "$@"; gap="$2"; shift 2 ;;
      *) echo "未知参数：$1" >&2; usage ;;
    esac
  done
  [ -n "$old_cp" ] && [ -n "$new_cp" ] && [ ${#sources[@]} -gt 0 ] || usage
  if [ -n "$ts_scan" ]; then
    [ -z "$ts_ok$ts_total" ] || { echo "--ts-scan 与 --ts-old-sources-ok / --ts-sources-total 只能二选一" >&2; exit 2; }
    [ -f "$ts_scan" ] || die "ts 扫描输出不存在：$ts_scan"
    local line
    line="$(grep -E '^old sources ok in any lexicon: [0-9]+ / [0-9]+$' "$ts_scan" | head -n 1 || true)"
    [ -n "$line" ] || die "${ts_scan} 里没有 'old sources ok in any lexicon: N / M' 行（不是 gate-scan.sh scan 的输出？）"
    line="${line#old sources ok in any lexicon: }"
    ts_ok="${line%% /*}"
    ts_total="${line##*/ }"
  fi
  check_cp "$old_cp"
  check_cp "$new_cp"
  local jh; jh="$(java_home)"
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/java-gate.XXXXXX")"
  "$jh/bin/javac" -encoding UTF-8 -nowarn -d "$TMP/classes" -cp "$(cat "$new_cp")" \
    "$HERE/src/gate/Main.java" "$HERE/src/gate/Worker.java" >"$TMP/javac.log" 2>&1 \
    || { grep -E 'error:' "$TMP/javac.log" | head -n 5 >&2; die "编译门禁工具失败（新版 classpath 缺 aster-api replay / core / jackson？）"; }
  local -a args=(--old-cp "$old_cp" --new-cp "$new_cp")
  local s
  for s in "${sources[@]}"; do args+=(--sources "$s"); done
  [ -z "$ts_ok" ] || args+=(--ts-old-sources-ok "$ts_ok")
  [ -z "$ts_total" ] || args+=(--ts-sources-total "$ts_total")
  [ -z "$gap" ] || args+=(--max-gap-pct "$gap")
  local rc=0
  "$jh/bin/java" -Xss8m -cp "$TMP/classes" gate.Main "${args[@]}" >"$TMP/out" || rc=$?
  cat "$TMP/out"
  # 只有 0 / 1 且带对应 result 行才是有效结论；JVM 被杀、崩溃等其它退出码一律 3
  case "$rc" in
    0) grep -q '^result: PASS ' "$TMP/out" || rc=3 ;;
    1) grep -q '^result: REVIEW ' "$TMP/out" || rc=3 ;;
    2|3) ;;
    *) rc=3 ;;
  esac
  [ "$rc" -ne 3 ] || grep -q '^result: ' "$TMP/out" || echo "result: ERROR (java exited abnormally)"
  DONE=1
  exit "$rc"
}

[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  classpath) cmd_classpath "$@"; DONE=1 ;;
  scan) cmd_scan "$@" ;;
  -h|--help) usage ;;
  *) echo "未知子命令：$sub" >&2; usage ;;
esac
