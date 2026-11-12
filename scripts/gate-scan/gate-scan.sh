#!/usr/bin/env bash
# 发布列车门槛扫描（gate scan）入口：把生产库里的策略源码分别用「当前已发布」与「候选」两个
# aster-lang-ts 构建编译一遍，报告编译结论发生变化的策略（只打印 id / kind / 诊断码，不打印源码）。
#
# 三种模式：
#   （缺省）一体化：构建 → 导出 → 扫描，同一台机器上需要 kubectl 与 Node 24。
#   export     只导出（只需 kubectl + psql，不需要 Node）：写 api.jsonl / cloud.jsonl 到 --out 目录。
#   scan       只扫描（不需要 kubectl）：读 --sources 目录里的导出，退出时删除它们（除非 --keep）。
#   kubectl 与 Node 不在同一台机器时用 export + scan 两步，中间用 scp 搬运（见 README）。
#   --ssh-host <host> 可让导出经 ssh 在远端执行 kubectl（本机无 kubeconfig 时）。
#
# 导出由 export-policy-sources.sql 在 READ ONLY 事务里生成，末行是完成标记 {"_count" : N}；
# 本脚本与 scan.mjs 都校验标记与行数一致，任一库导出为空也判失败（--allow-empty-db 可放行单边为空，两库合计为空仍失败）。
# 一体化模式的导出与构建都在 umask 077 的 mktemp 目录里，EXIT trap 必删；正常退出路径与
# INT / TERM / HUP 都会清理（SIGKILL 无法清理）。不读取任何密钥，不写任何库。
#
# 退出码：0 = 无报告项；1 = 有报告项（需人工确认）；2 = 用法错误；3 = 环境 / 构建 / 导出 / 扫描失败。
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SQL="$HERE/export-policy-sources.sql"
SCAN="$HERE/scan.mjs"
TS_REPO="${ASTER_TS_REPO:-$REPO_ROOT/../aster-lang-ts}"

MODE="all"
OLD_TS=""; NEW_TS=""; CODE=""; KUBE_CONTEXT=""; SSH_HOST=""
NAMESPACE="data-services"; POD="shared-postgres-1"
API_DB="aster_api"; CLOUD_DB="aster_cloud"
OUT=""; SOURCES_DIR=""; KEEP=false; ALLOW_EMPTY=false; DRY_RUN=false

# 清理状态（EXIT trap 读取）
WORK=""; FETCHED=""; BUILT_ANY=""; PARTIAL_EXPORT=""; DELETE_SOURCES=""
BUILT_DIST=""; RESOLVED_COMMIT=""; EXPORT_COUNT=""; TOTAL_ROWS=0

usage() {
  cat <<EOF
用法：
  scripts/gate-scan/gate-scan.sh [run] --old-ts <ts> --new-ts <ts> [--code X] [导出选项]   一体化（缺省）
  scripts/gate-scan/gate-scan.sh export --out <dir> [导出选项]                             只导出（kubectl 主机）
  scripts/gate-scan/gate-scan.sh scan --sources <dir> --old-ts <ts> --new-ts <ts> [--code X] [--keep]   只扫描

  <ts>                  aster-lang-ts 的 git ref（tag / 分支 / commit，如 v1.4.0），或本地已构建目录：
                        以 path: 前缀、/、./ 或 ../ 开头的视为路径（仓库根或 dist），否则一律视为 git ref
  --code <CODE>         只报告「旧版无 CODE、新版有 CODE」的策略（如 E054）；缺省报告全部诊断码变化
  --out <dir>           export：导出目录（写入 api.jsonl / cloud.jsonl，文件不得已存在）
  --sources <dir>       scan：含 api.jsonl / cloud.jsonl 的目录；扫描结束（含失败）后删除这两个文件
  --keep                scan：扫描后保留导出文件
导出选项：
  --kube-context <ctx>  kubectl context（缺省用当前 context）
  --ssh-host <host>     本机没有 kubeconfig 时，经 ssh -o BatchMode=yes <host> 在远端执行 kubectl（stdin 原样转发）
  --namespace <ns>      Postgres 所在 namespace（缺省 ${NAMESPACE}）
  --pod <pod>           Postgres pod（缺省 ${POD}）
  --api-db <db>         aster-api 库名（缺省 ${API_DB}）
  --cloud-db <db>       aster-cloud 库名（缺省 ${CLOUD_DB}）
  --allow-empty-db      允许某个库导出 0 行（缺省视为失败；两个库都为 0 行仍然失败）
通用：
  --dry-run             只打印将执行的命令，不构建、不连集群、不删文件
  -h, --help            显示本帮助

环境变量：ASTER_TS_REPO  aster-lang-ts 克隆路径（缺省 ${TS_REPO}），git ref 模式需要。
退出码：0 无报告项；1 有报告项；2 用法错误；3 环境 / 构建 / 导出 / 扫描失败。
EOF
}

log() { echo "[gate-scan] $*" >&2; }
fail() { echo "[gate-scan] 错误：$*" >&2; exit 3; }
usage_error() { echo "[gate-scan] 用法错误：$*" >&2; echo "运行 --help 查看用法" >&2; exit 2; }
on_err() { echo "[gate-scan] 错误：第 $2 行命令意外失败（rc=$1）" >&2; exit 3; }

# 打印（dry-run）或执行一条命令。
run() {
  if [ "$DRY_RUN" = true ]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

parse_args() {
  case "${1:-}" in
    export|scan|run) MODE="$1"; shift ;;
  esac
  [ "$MODE" = run ] && MODE=all
  while [ $# -gt 0 ]; do
    case "$1" in
      --old-ts|--new-ts|--code|--kube-context|--ssh-host|--namespace|--pod|--api-db|--cloud-db|--out|--sources)
        [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 需要一个值"
        case "$1" in
          --old-ts) OLD_TS="$2" ;;
          --new-ts) NEW_TS="$2" ;;
          --code) CODE="$2" ;;
          --kube-context) KUBE_CONTEXT="$2" ;;
          --ssh-host) SSH_HOST="$2" ;;
          --namespace) NAMESPACE="$2" ;;
          --pod) POD="$2" ;;
          --api-db) API_DB="$2" ;;
          --cloud-db) CLOUD_DB="$2" ;;
          --out) OUT="$2" ;;
          --sources) SOURCES_DIR="$2" ;;
        esac
        shift 2 ;;
      --keep) KEEP=true; shift ;;
      --allow-empty-db) ALLOW_EMPTY=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "未知参数 $1" ;;
    esac
  done
  validate_args
}

validate_args() {
  if [ -n "$SSH_HOST" ]; then
    [ "$MODE" != scan ] || usage_error "--ssh-host 只用于导出（一体化 / export）"
    case "$SSH_HOST" in -*) usage_error "--ssh-host 不能以 - 开头：$SSH_HOST" ;; esac
  fi
  if [ "$MODE" = export ]; then
    [ -n "$OUT" ] || usage_error "export 需要 --out"
    [ -z "$OLD_TS$NEW_TS$CODE$SOURCES_DIR" ] && [ "$KEEP" = false ] \
      || usage_error "export 只接受 --out 与导出选项"
    return 0
  fi
  [ -n "$OLD_TS" ] || usage_error "缺少 --old-ts"
  [ -n "$NEW_TS" ] || usage_error "缺少 --new-ts"
  [ -z "$OUT" ] || usage_error "--out 只用于 export"
  if [ -n "$CODE" ]; then
    CODE="$(printf '%s' "$CODE" | tr '[:lower:]' '[:upper:]')"
    [[ "$CODE" =~ ^[A-Z][A-Z0-9_]*$ ]] || usage_error "--code 不是合法诊断码：$CODE"
  fi
  if [ "$MODE" = scan ]; then
    [ -n "$SOURCES_DIR" ] || usage_error "scan 需要 --sources"
  else
    [ -z "$SOURCES_DIR" ] && [ "$KEEP" = false ] || usage_error "--sources / --keep 只用于 scan"
  fi
}

require_node() {
  [ "$DRY_RUN" = true ] && return 0
  command -v node >/dev/null || fail "找不到 node（需要 Node 24，如 export PATH=/opt/homebrew/opt/node@24/bin:\${PATH}）"
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$major" -ge 24 ] || fail "需要 Node 24+，当前 $(node -v)（如 export PATH=/opt/homebrew/opt/node@24/bin:\${PATH}）"
}

require_kubectl() {
  [ "$DRY_RUN" = true ] && return 0
  if [ -n "$SSH_HOST" ]; then
    command -v ssh >/dev/null || fail "找不到 ssh"
  else
    command -v kubectl >/dev/null || fail "找不到 kubectl"
  fi
}

# ---------- 构建 ----------

# git ref → commit，写入 RESOLVED_COMMIT：远端分支优先（取最新），其次 tag / 本地分支 / commit。
resolve_ref() {
  local ref="$1"
  if RESOLVED_COMMIT="$(git -C "$TS_REPO" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}")"; then return 0; fi
  if RESOLVED_COMMIT="$(git -C "$TS_REPO" rev-parse --verify --quiet "$ref^{commit}")"; then return 0; fi
  fail "在 $TS_REPO 找不到 ref ${ref}（已尝试 fetch origin）"
}

# 在临时 worktree 构建 ref，结果 dist 路径写到 BUILT_DIST。
build_ref() {
  local label="$1" ref="$2" dir="$WORK/ts-$1"
  if [ "$DRY_RUN" = true ]; then
    [ -n "$FETCHED" ] || run git -C "$TS_REPO" fetch --quiet --tags origin
    FETCHED=1
    run git -C "$TS_REPO" worktree add --detach "$dir" "<commit of $ref>"
    printf '+ (cd %q && corepack pnpm install --frozen-lockfile && corepack pnpm run build) </dev/null\n' "$dir"
    BUILT_DIST="$dir/dist"
    return 0
  fi
  git -C "$TS_REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || fail "$ref 视为 git ref，但 ASTER_TS_REPO=$TS_REPO 不是 git 仓库（设置 ASTER_TS_REPO，或用 path: 前缀传已构建目录）"
  command -v corepack >/dev/null || fail "找不到 corepack（Node 24 自带；检查 PATH）"
  if [ -z "$FETCHED" ]; then
    git -C "$TS_REPO" fetch --quiet --tags origin </dev/null || log "警告：fetch origin 失败，使用本地已有的 ref"
    FETCHED=1
  fi
  resolve_ref "$ref"
  log "构建 ${label}：$ref (${RESOLVED_COMMIT:0:12})"
  BUILT_ANY=1  # 先登记再创建：中途被打断也会被 cleanup prune
  git -C "$TS_REPO" worktree add --quiet --detach "$dir" "$RESOLVED_COMMIT" </dev/null >/dev/null 2>&1 \
    || fail "git worktree add $ref 失败"
  if ! (cd "$dir" && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
        && corepack pnpm install --frozen-lockfile && corepack pnpm run build) </dev/null >"$WORK/build-$label.log" 2>&1; then
    tail -n 30 "$WORK/build-$label.log" >&2
    fail "构建 $ref 失败（上面是构建日志末尾）"
  fi
  BUILT_DIST="$dir/dist"
}

# --old-ts / --new-ts → BUILT_DIST。路径必须显式（path: / / ./ ../），其余视为 git ref。
resolve_ts() {
  local label="$1" arg="$2" path=""
  case "$arg" in
    path:*) path="${arg#path:}" ;;
    /*|./*|../*) path="$arg" ;;
  esac
  if [ -z "$path" ]; then
    build_ref "$label" "$arg"
    return 0
  fi
  if [ -f "$path/dist/src/browser.js" ]; then
    BUILT_DIST="$(cd "$path/dist" && pwd)"
  elif [ -f "$path/src/browser.js" ]; then
    BUILT_DIST="$(cd "$path" && pwd)"
  else
    fail "$path 没有构建产物（缺 dist/src/browser.js）——先在其中 pnpm build，或改传 git ref"
  fi
  log "$label 使用已有构建 $BUILT_DIST"
}

# ---------- 导出 ----------

# 在集群 Postgres pod 里跑只读导出；$1=库名，$2=输出文件，其余为额外 psql 参数。
export_db() {
  local db="$1" out="$2"; shift 2
  local kube=(kubectl)
  if [ -n "$KUBE_CONTEXT" ]; then kube+=(--context "$KUBE_CONTEXT"); fi
  kube+=(-n "$NAMESPACE" exec -i "$POD" -- psql -X -At -v ON_ERROR_STOP=1 -d "$db" "$@" -f -)
  if [ -n "$SSH_HOST" ]; then
    # 远端 shell 会再解析一次命令行：逐个参数 %q 转义后拼成单个字符串
    local remote="" a
    for a in "${kube[@]}"; do remote+=" $(printf '%q' "$a")"; done
    kube=(ssh -o BatchMode=yes -- "$SSH_HOST" "${remote# }")
  fi
  if [ "$DRY_RUN" = true ]; then
    printf '+'; printf ' %q' "${kube[@]}"; printf ' < %q > %q\n' "$SQL" "$out"
    return 0
  fi
  log "导出 $db"
  "${kube[@]}" <"$SQL" >"$out" || fail "导出 $db 失败（kubectl exec / psql 非零退出）"
}

# 校验导出的完成标记与行数，行数写入 EXPORT_COUNT；为空且未 --allow-empty-db 时失败。
check_export() {
  local file="$1" db="$2" markers count rows
  [ "$DRY_RUN" = true ] && return 0
  [ -f "$file" ] || fail "$file 不存在"
  markers="$(grep -c '^{"_count"' "$file" || true)"
  [ "$markers" = 1 ] || fail "$db 导出（${file}）应恰好有 1 行完成标记，实际 ${markers}——导出被截断或不完整"
  count="$(sed -n 's/^{"_count" *: *\([0-9][0-9]*\)}$/\1/p' "$file")"
  [ -n "$count" ] || fail "$db 导出（${file}）的完成标记无法解析"
  rows="$(grep -v -c -e '^{"_count"' -e '^$' "$file" || true)"
  [ "$rows" -eq "$count" ] || fail "$db 导出（${file}）完成标记 ${count} 行，实际 ${rows} 行——导出被截断或损坏"
  if [ "$count" -eq 0 ] && [ "$ALLOW_EMPTY" = false ]; then
    fail "$db 导出为 0 行——检查 pod / 库名；确属预期请加 --allow-empty-db（空扫描不算通过）"
  fi
  EXPORT_COUNT="$count"
  TOTAL_ROWS=$((TOTAL_ROWS + count))
}

# --allow-empty-db 只放行单边为空：两个库合计 0 行时导出必然有误（pod / 库名 / 集群错了）。
require_some_rows() {
  [ "$DRY_RUN" = true ] && return 0
  [ "$TOTAL_ROWS" -gt 0 ] || fail "两个库的导出合计 0 行——--allow-empty-db 只放行单边为空，至少一个库必须有策略；检查 context / pod / 库名"
}

export_both() {  # 目录
  export_db "$API_DB" "$1/api.jsonl"
  check_export "$1/api.jsonl" "$API_DB"; local api_count="$EXPORT_COUNT"
  export_db "$CLOUD_DB" "$1/cloud.jsonl" -v cloud=1
  check_export "$1/cloud.jsonl" "$CLOUD_DB"
  require_some_rows
  [ "$DRY_RUN" = true ] || log "导出完成：${API_DB} ${api_count} 行，${CLOUD_DB} ${EXPORT_COUNT} 行"
}

# ---------- 扫描 ----------

run_scan() {  # api.jsonl cloud.jsonl
  local scan=(node "$SCAN" --old "$OLD_DIST" --new "$NEW_DIST" --sources "$1" --sources "$2")
  if [ -n "$CODE" ]; then scan+=(--code "$CODE"); fi
  if [ "$DRY_RUN" = true ]; then
    run "${scan[@]}"
    exit 0
  fi
  local out="$WORK/scan.out" rc=0
  "${scan[@]}" >"$out" || rc=$?
  cat "$out"
  grep -q '^result: ' "$out" || fail "scan.mjs 没有输出 result 行（rc=${rc}）——扫描未完成，不能当作通过"
  [ "$rc" -le 1 ] || fail "scan.mjs 退出码 ${rc}（2 = 用法/崩溃，3 = 输入或构建不可信）"
  exit "$rc"
}

make_work() {
  local tmp="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${tmp%/}/gate-scan.XXXXXX")" || fail "mktemp 失败"
  [ "$DRY_RUN" = false ] || log "dry-run：只打印命令（临时目录 $WORK 退出时删除）"
}

build_both() {
  resolve_ts old "$OLD_TS"; OLD_DIST="$BUILT_DIST"
  resolve_ts new "$NEW_TS"; NEW_DIST="$BUILT_DIST"
}

cleanup() {
  if [ -n "$WORK" ]; then
    rm -rf "$WORK" || log "警告：删除临时目录 $WORK 失败，请手工删除"
  fi
  if [ -n "$BUILT_ANY" ]; then
    git -C "$TS_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  if [ -n "$PARTIAL_EXPORT" ]; then
    rm -f "$OUT/api.jsonl" "$OUT/cloud.jsonl" || true
    log "导出未完成，已删除 $OUT 下的部分导出"
  fi
  if [ -n "$DELETE_SOURCES" ]; then
    rm -f "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl" || log "警告：删除 $SOURCES_DIR 下的导出失败，请手工删除"
    rmdir "$SOURCES_DIR" 2>/dev/null || true
    log "已删除 $SOURCES_DIR 下的导出"
  fi
}

mode_export() {
  require_kubectl
  if [ "$DRY_RUN" = true ]; then export_both "$OUT"; exit 0; fi
  mkdir -p "$OUT" || fail "无法创建 $OUT"
  # -L 单独检查：悬空符号链接 -e 为假，写入会穿过链接落到别处
  local f
  for f in "$OUT/api.jsonl" "$OUT/cloud.jsonl"; do
    if [ -e "$f" ] || [ -L "$f" ]; then fail "$OUT 里已有 api.jsonl / cloud.jsonl（或符号链接）——先删除旧导出"; fi
  done
  PARTIAL_EXPORT=1
  export_both "$OUT"
  PARTIAL_EXPORT=""
  wc -l "$OUT/api.jsonl" "$OUT/cloud.jsonl" | sed '$d' | while read -r lines file; do
    echo "$file  $((lines - 1)) rows (+1 marker line)"
  done
  log "导出含生产策略源码：搬到扫描机后用 'gate-scan.sh scan --sources <dir>' 扫描，并删除本机这份（rm -rf ${OUT}）"
}

mode_scan() {
  require_node
  [ -d "$SOURCES_DIR" ] || fail "$SOURCES_DIR 不是目录"
  if [ "$KEEP" = false ]; then
    if [ "$DRY_RUN" = true ]; then
      printf '+ rm -f %q %q   # 退出时\n' "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl"
    else
      DELETE_SOURCES=1
    fi
  fi
  check_export "$SOURCES_DIR/api.jsonl" "$API_DB"
  check_export "$SOURCES_DIR/cloud.jsonl" "$CLOUD_DB"
  require_some_rows
  make_work
  build_both
  run_scan "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl"
}

mode_all() {
  require_node
  require_kubectl
  make_work
  build_both
  export_both "$WORK"
  run_scan "$WORK/api.jsonl" "$WORK/cloud.jsonl"
}

main() {
  parse_args "$@"
  umask 077
  trap 'on_err $? $LINENO' ERR
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'exit 143' TERM
  "mode_$MODE"
}

main "$@"
