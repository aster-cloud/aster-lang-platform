#!/usr/bin/env bash
# 发布列车门槛扫描（gate scan）入口：把生产库里的策略源码分别用「当前已发布」与「候选」两个
# aster-lang-ts 构建编译一遍，报告编译结论发生变化的策略（只打印 id / kind / 诊断码，不打印源码）。
#
# 四种模式：
#   （缺省）一体化：构建 → 导出 → 扫描，同一台机器上需要 kubectl 与 Node 24。
#   export     只导出（只需 kubectl + psql，不需要 Node）：写 api.jsonl / cloud.jsonl 到 --out 目录
#              （--with-input-refs 另写 input-refs 用的 api-impact / cloud-impact / profile-ids.jsonl）。
#   scan       只扫描（不需要 kubectl）：读 --sources 目录里的导出，退出时删除它们（除非 --keep）。
#   input-refs 档案模块的规则输入引用清单（ADR 0046 §11.4 ⑦ 翻转前扫描，见 input-refs.mjs）：一个 ts 构建（--ts），
#              缺省一体化导出 源码 / 影响面 / 对账集合 并自动传 --impact 与 --profile-ids；给 --sources 则只扫描。
#   kubectl 与 Node 不在同一台机器时用 export + scan 两步，中间用 scp 搬运（见 README）。
#   --ssh-host <host> 可让导出经 ssh 在远端执行 kubectl（本机无 kubeconfig 时）。
#
# 导出由 export-*.sql 在 READ ONLY 事务里生成，末行是完成标记 {"_count" : N}；本脚本与 scan.mjs / input-refs.mjs
# 都校验标记与行数一致。空导出不放行：--allow-empty-api-db 只放行 aster_api 库的源码导出为 0 行，cloud 库为 0 行
# 一律失败；旧旗标 --allow-empty-db（只用于 diff 扫描与 export）保留原义——放行单边为空，两库合计为空仍失败。
# 一体化模式的导出与构建都在 umask 077 的 mktemp 目录里，EXIT trap 必删；正常退出路径与
# INT / TERM / HUP 都会清理（SIGKILL 无法清理）。不读取任何密钥，不写任何库。
#
# 退出码：0 = 无报告项；1 = 有报告项（需人工确认）；2 = 用法错误；3 = 环境 / 构建 / 导出 / 扫描失败；
#         4 = input-refs 对账不等（源码头部声明档案的 cloud id 集合与扫描所得不一致）。
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SQL_SOURCES="$HERE/export-policy-sources.sql"
SQL_IMPACT="$HERE/export-profile-impact.sql"
SQL_IDS="$HERE/export-profile-ids.sql"
SCAN="$HERE/scan.mjs"
INPUT_REFS="$HERE/input-refs.mjs"
# input-refs 额外的三份导出（只含 id / 租户 / 计数，不含源码）
EXTRA_EXPORTS=(api-impact.jsonl cloud-impact.jsonl profile-ids.jsonl)
TS_REPO="${ASTER_TS_REPO:-$REPO_ROOT/../aster-lang-ts}"

MODE="all"
OLD_TS=""; NEW_TS=""; CODE=""; KUBE_CONTEXT=""; SSH_HOST=""
NAMESPACE="data-services"; POD="shared-postgres-1"
API_DB="aster_api"; CLOUD_DB="aster_cloud"
OUT=""; SOURCES_DIR=""; KEEP=false; ALLOW_EMPTY=false; ALLOW_EMPTY_API=false; DRY_RUN=false
TS=""; PROFILE=""; IMPACTS=(); PROFILE_IDS=""; WITH_INPUT_REFS=false

# 清理状态（EXIT trap 读取）
WORK=""; FETCHED=""; BUILT_ANY=""; PARTIAL_EXPORT=""; DELETE_SOURCES=""
BUILT_DIST=""; RESOLVED_COMMIT=""; EXPORT_COUNT=""; TOTAL_ROWS=0; TS_DIST=""

usage() {
  cat <<EOF
用法：
  scripts/gate-scan/gate-scan.sh [run] --old-ts <ts> --new-ts <ts> [--code X] [导出选项]   一体化（缺省）
  scripts/gate-scan/gate-scan.sh export --out <dir> [--with-input-refs] [导出选项]           只导出（kubectl 主机）
  scripts/gate-scan/gate-scan.sh scan --sources <dir> --old-ts <ts> --new-ts <ts> [--code X] [--keep]   只扫描
  scripts/gate-scan/gate-scan.sh input-refs --ts <ts> --profile <id> [导出选项]                    档案输入引用（一体化）
  scripts/gate-scan/gate-scan.sh input-refs --sources <dir> --ts <ts> --profile <id> [--impact <jsonl> ...]
                                [--profile-ids <jsonl>] [--keep]                                  档案输入引用（只扫描）

  <ts>                  aster-lang-ts 的 git ref（tag / 分支 / commit，如 v1.4.0），或本地已构建目录：
                        以 path: 前缀、/、./ 或 ../ 开头的视为路径（仓库根或 dist），否则一律视为 git ref
  --code <CODE>         只报告「旧版无 CODE、新版有 CODE」的策略（如 E054）；缺省报告全部诊断码变化
  --out <dir>           export：导出目录（写入 api.jsonl / cloud.jsonl，文件不得已存在）
  --sources <dir>       scan：含 api.jsonl / cloud.jsonl 的目录；扫描结束（含失败）后删除这两个文件
  --keep                scan / input-refs --sources：扫描后保留导出文件
  --ts <ts>             input-refs：aster-lang-ts 构建（≥ 1.5.0），写法同 <ts>
  --profile <id>        input-refs：只报告声明该档案的模块（如 eu-ai-act-high-risk）
  --impact <jsonl>      input-refs --sources：export-profile-impact.sql 的导出（可重复；一体化时自动导出并传入）
  --profile-ids <jsonl> input-refs --sources：export-profile-ids.sql 的导出（对账；一体化时自动导出并传入；G3 必需）
  --with-input-refs     export：另导出 api-impact.jsonl / cloud-impact.jsonl / profile-ids.jsonl
导出选项：
  --kube-context <ctx>  kubectl context（缺省用当前 context）
  --ssh-host <host>     本机没有 kubeconfig 时，经 ssh -o BatchMode=yes <host> 在远端执行 kubectl（stdin 原样转发）
  --namespace <ns>      Postgres 所在 namespace（缺省 ${NAMESPACE}）
  --pod <pod>           Postgres pod（缺省 ${POD}）
  --api-db <db>         aster-api 库名（缺省 ${API_DB}）
  --cloud-db <db>       aster-cloud 库名（缺省 ${CLOUD_DB}）
  --allow-empty-api-db  允许 aster_api 库的源码导出为 0 行（生产 policy_versions 今天为 0 行）；cloud 库为 0 行仍然失败
  --allow-empty-db      旧旗标（diff 扫描 / export）：允许某个库导出 0 行，两个库都为 0 行仍然失败；input-refs 不接受
通用：
  --dry-run             只打印将执行的命令，不构建、不连集群、不删文件
  -h, --help            显示本帮助

环境变量：ASTER_TS_REPO  aster-lang-ts 克隆路径（缺省 ${TS_REPO}），git ref 模式需要。
退出码：0 无报告项；1 有报告项（input-refs：有 STAR 规则）；2 用法错误；3 环境 / 构建 / 导出 / 扫描失败；
        4 input-refs 对账不等。
EOF
}

log() { echo "[gate-scan] $*" >&2; }
fail() { echo "[gate-scan] 错误：$*" >&2; exit 3; }
usage_error() { echo "[gate-scan] 用法错误：$*" >&2; echo "运行 --help 查看用法" >&2; exit 2; }
on_err() { echo "[gate-scan] 错误：第 $2 行命令意外失败（rc=$1）" >&2; exit 3; }
# 有意的正常退出一律经 finish：bash 3.2（macOS /bin/bash）在设置了 EXIT trap 时，set -u 的未绑定变量中止会以 0 退出，
# cleanup 据 FINISHED 把这种「未经 finish 的 0」改判为 3，避免崩溃被当作通过。
FINISHED=""
finish() { FINISHED=1; exit "$1"; }

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
    export|scan|run|input-refs) MODE="$1"; shift ;;
  esac
  [ "$MODE" = run ] && MODE=all
  while [ $# -gt 0 ]; do
    case "$1" in
      --old-ts|--new-ts|--code|--kube-context|--ssh-host|--namespace|--pod|--api-db|--cloud-db|--out|--sources|--ts|--profile|--impact|--profile-ids)
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
          --ts) TS="$2" ;;
          --profile) PROFILE="$2" ;;
          --impact) IMPACTS+=("$2") ;;
          --profile-ids) PROFILE_IDS="$2" ;;
        esac
        shift 2 ;;
      --keep) KEEP=true; shift ;;
      --allow-empty-db) ALLOW_EMPTY=true; shift ;;
      --allow-empty-api-db) ALLOW_EMPTY_API=true; shift ;;
      --with-input-refs) WITH_INPUT_REFS=true; shift ;;
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
  local ir_only="$TS$PROFILE$PROFILE_IDS${IMPACTS[*]-}"
  if [ "$MODE" = export ]; then
    [ -n "$OUT" ] || usage_error "export 需要 --out"
    [ -z "$OLD_TS$NEW_TS$CODE$SOURCES_DIR$ir_only" ] && [ "$KEEP" = false ] \
      || usage_error "export 只接受 --out、--with-input-refs 与导出选项"
    return 0
  fi
  [ "$WITH_INPUT_REFS" = false ] || usage_error "--with-input-refs 只用于 export"
  if [ "$MODE" = input-refs ]; then
    validate_input_refs_args
    return 0
  fi
  [ -z "$ir_only" ] || usage_error "--ts / --profile / --impact / --profile-ids 只用于 input-refs"
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

validate_input_refs_args() {
  [ "$ALLOW_EMPTY" = false ] || usage_error "input-refs 不接受 --allow-empty-db（cloud 导出永不允许为空）；aster_api 为 0 行请用 --allow-empty-api-db"
  [ -n "$TS" ] || usage_error "input-refs 需要 --ts"
  [ -n "$PROFILE" ] || usage_error "input-refs 需要 --profile"
  [[ "$PROFILE" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || usage_error "--profile 不是合法档案 id：$PROFILE"
  [ -z "$OLD_TS$NEW_TS$CODE$OUT" ] || usage_error "input-refs 不接受 --old-ts / --new-ts / --code / --out"
  if [ -n "$SOURCES_DIR" ]; then
    [ -z "$SSH_HOST" ] || usage_error "--ssh-host 只用于导出（input-refs 一体化 / export）"
  else
    [ -z "$PROFILE_IDS${IMPACTS[*]-}" ] && [ "$KEEP" = false ] \
      || usage_error "--impact / --profile-ids / --keep 只用于 input-refs --sources（一体化模式自动导出并传入）"
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

# 在集群 Postgres pod 里跑只读导出；$1=SQL 文件，$2=库名，$3=输出文件，其余为额外 psql 参数。
export_db() {
  local sql="$1" db="$2" out="$3"; shift 3
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
    printf '+'; printf ' %q' "${kube[@]}"; printf ' < %q > %q\n' "$sql" "$out"
    return 0
  fi
  log "导出 ${db}（$(basename "$sql")）"
  # noclobber（O_EXCL）：输出文件已存在或是符号链接时拒绝写入，关闭「检查后写入」的竞态
  ( set -C; "${kube[@]}" <"$sql" >"$out" ) || fail "导出 $db 失败（kubectl exec / psql 非零退出）"
}

# 校验导出的完成标记与行数，行数写入 EXPORT_COUNT；为空且 $3（放行说明）为空时失败，$4 为失败时的处理提示。
check_export() {
  local file="$1" db="$2" allow="${3:-}" hint="${4:-}" markers count rows
  [ "$DRY_RUN" = true ] && return 0
  [ -f "$file" ] || fail "$file 不存在"
  markers="$(grep -c '^{"_count"' "$file" || true)"
  [ "$markers" = 1 ] || fail "$db 导出（${file}）应恰好有 1 行完成标记，实际 ${markers}——导出被截断或不完整"
  count="$(sed -n 's/^{"_count" *: *\([0-9][0-9]*\)}$/\1/p' "$file")"
  [ -n "$count" ] || fail "$db 导出（${file}）的完成标记无法解析"
  rows="$(grep -v -c -e '^{"_count"' -e '^$' "$file" || true)"
  [ "$rows" -eq "$count" ] || fail "$db 导出（${file}）完成标记 ${count} 行，实际 ${rows} 行——导出被截断或损坏"
  if [ "$count" -eq 0 ] && [ -z "$allow" ]; then
    fail "$db 导出为 0 行（$(basename "$file")）——检查 context / pod / 库名${hint}（空扫描不算通过）"
  fi
  EXPORT_COUNT="$count"
}

# 源码导出的空导出放行：aster_api 由 --allow-empty-api-db 或旧旗标放行，aster_cloud 只由旧旗标放行。
api_empty_allowed() { [ "$ALLOW_EMPTY_API" = true ] || [ "$ALLOW_EMPTY" = true ] && echo 1 || true; }
cloud_empty_allowed() { [ "$ALLOW_EMPTY" = true ] && echo 1 || true; }
API_EMPTY_HINT="；确属预期（生产 policy_versions 今天为 0 行）请加 --allow-empty-api-db"
CLOUD_EMPTY_HINT="；cloud 库导出不允许为空"

check_sources() {  # api.jsonl cloud.jsonl
  check_export "$1" "$API_DB" "$(api_empty_allowed)" "$API_EMPTY_HINT"; local api_count="$EXPORT_COUNT"
  check_export "$2" "$CLOUD_DB" "$(cloud_empty_allowed)" "$CLOUD_EMPTY_HINT"
  TOTAL_ROWS=$((api_count + EXPORT_COUNT))
  require_some_rows
  [ "$DRY_RUN" = true ] || log "源码导出：${API_DB} ${api_count} 行，${CLOUD_DB} ${EXPORT_COUNT} 行"
}

# --allow-empty-db 只放行单边为空：两个库合计 0 行时导出必然有误（pod / 库名 / 集群错了）。
require_some_rows() {
  [ "$DRY_RUN" = true ] && return 0
  [ "$TOTAL_ROWS" -gt 0 ] || fail "两个库的导出合计 0 行——--allow-empty-db 只放行单边为空，至少一个库必须有策略；检查 context / pod / 库名"
}

export_both() {  # 目录
  export_db "$SQL_SOURCES" "$API_DB" "$1/api.jsonl"
  export_db "$SQL_SOURCES" "$CLOUD_DB" "$1/cloud.jsonl" -v cloud=1
  check_sources "$1/api.jsonl" "$1/cloud.jsonl"
}

# input-refs 的三份额外导出：aster_api 签发方（可为空：没有任何签发方是合法状态，只会让各租户显示为无启用签发方）、
# cloud 影响面（与源码导出同一选取条件，不得为空）、cloud 对账集合（可为空：由 input-refs.mjs 逐 id 对账）。
export_input_refs_extras() {  # 目录
  export_db "$SQL_IMPACT" "$API_DB" "$1/api-impact.jsonl"
  check_export "$1/api-impact.jsonl" "$API_DB" 1
  export_db "$SQL_IMPACT" "$CLOUD_DB" "$1/cloud-impact.jsonl" -v cloud=1
  check_export "$1/cloud-impact.jsonl" "$CLOUD_DB" "" "$CLOUD_EMPTY_HINT"
  export_db "$SQL_IDS" "$CLOUD_DB" "$1/profile-ids.jsonl" -v cloud=1
  check_export "$1/profile-ids.jsonl" "$CLOUD_DB" 1
}

# ---------- 扫描 ----------

run_scan() {  # api.jsonl cloud.jsonl
  local scan=(node "$SCAN" --old "$OLD_DIST" --new "$NEW_DIST" --sources "$1" --sources "$2")
  if [ -n "$CODE" ]; then scan+=(--code "$CODE"); fi
  if [ -n "$(api_empty_allowed)" ]; then scan+=(--allow-empty-api); fi
  if [ -n "$(cloud_empty_allowed)" ]; then scan+=(--allow-empty-cloud); fi
  if [ "$DRY_RUN" = true ]; then
    run "${scan[@]}"
    finish 0
  fi
  local out="$WORK/scan.out" rc=0
  "${scan[@]}" >"$out" || rc=$?
  cat "$out"
  grep -q '^result: ' "$out" || fail "scan.mjs 没有输出 result 行（rc=${rc}）——扫描未完成，不能当作通过"
  [ "$rc" -le 1 ] || fail "scan.mjs 退出码 ${rc}（2 = 用法/崩溃，3 = 输入或构建不可信）"
  finish "$rc"
}

run_input_refs() {  # api.jsonl cloud.jsonl [impact 文件...]；对账文件取 PROFILE_IDS
  local api="$1" cloud="$2"; shift 2
  local scan=(node "$INPUT_REFS" --ts "$TS_DIST" --profile "$PROFILE" --sources "$api" --sources "$cloud")
  if [ "$ALLOW_EMPTY_API" = true ]; then scan+=(--allow-empty-api); fi
  local f
  for f in "$@"; do scan+=(--impact "$f"); done
  if [ -n "$PROFILE_IDS" ]; then scan+=(--profile-ids "$PROFILE_IDS"); fi
  if [ "$DRY_RUN" = true ]; then
    run "${scan[@]}"
    finish 0
  fi
  local out="$WORK/input-refs.out" rc=0
  "${scan[@]}" >"$out" || rc=$?
  cat "$out"
  grep -q '^result: ' "$out" || fail "input-refs.mjs 没有输出 result 行（rc=${rc}）——扫描未完成，不能当作通过"
  case "$rc" in
    0|1|4) finish "$rc" ;;
    *) fail "input-refs.mjs 退出码 ${rc}（2 = 用法/崩溃，3 = 输入或构建不可信）" ;;
  esac
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
  local rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$FINISHED" ]; then
    echo "[gate-scan] 错误：脚本意外中止（未经正常退出路径）" >&2
    rc=3
  fi
  if [ -n "$WORK" ]; then
    rm -rf "$WORK" || log "警告：删除临时目录 $WORK 失败，请手工删除"
  fi
  if [ -n "$BUILT_ANY" ]; then
    git -C "$TS_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  if [ -n "$PARTIAL_EXPORT" ]; then
    rm -f "$OUT/api.jsonl" "$OUT/cloud.jsonl" "${EXTRA_EXPORTS[@]/#/$OUT/}" || true
    log "导出未完成，已删除 $OUT 下的部分导出"
  fi
  if [ -n "$DELETE_SOURCES" ]; then
    rm -f "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl" || log "警告：删除 $SOURCES_DIR 下的导出失败，请手工删除"
    rmdir "$SOURCES_DIR" 2>/dev/null || true
    log "已删除 $SOURCES_DIR 下的导出"
  fi
  exit "$rc"
}

mode_export() {
  require_kubectl
  if [ "$DRY_RUN" = true ]; then
    export_both "$OUT"
    if [ "$WITH_INPUT_REFS" = true ]; then export_input_refs_extras "$OUT"; fi
    finish 0
  fi
  mkdir -p "$OUT" || fail "无法创建 $OUT"
  # -L 单独检查：悬空符号链接 -e 为假，写入会穿过链接落到别处
  local f files=("$OUT/api.jsonl" "$OUT/cloud.jsonl")
  if [ "$WITH_INPUT_REFS" = true ]; then files+=("${EXTRA_EXPORTS[@]/#/$OUT/}"); fi
  for f in "$OUT/api.jsonl" "$OUT/cloud.jsonl" "${EXTRA_EXPORTS[@]/#/$OUT/}"; do
    if [ -e "$f" ] || [ -L "$f" ]; then fail "$OUT 里已有 api.jsonl / cloud.jsonl 等导出（或符号链接）——先删除旧导出"; fi
  done
  PARTIAL_EXPORT=1
  export_both "$OUT"
  if [ "$WITH_INPUT_REFS" = true ]; then export_input_refs_extras "$OUT"; fi
  PARTIAL_EXPORT=""
  wc -l "${files[@]}" | sed '$d' | while read -r lines file; do
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
  check_sources "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl"
  make_work
  build_both
  run_scan "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl"
}

# input-refs：缺省一体化（构建 → 导出五份 → 扫描，自动传 --impact 与 --profile-ids）；给 --sources 时只扫描。
mode_input_refs() {
  require_node
  if [ -n "$SOURCES_DIR" ]; then
    [ -d "$SOURCES_DIR" ] || fail "$SOURCES_DIR 不是目录"
    if [ "$KEEP" = false ]; then
      if [ "$DRY_RUN" = true ]; then
        printf '+ rm -f %q %q   # 退出时\n' "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl"
      else
        DELETE_SOURCES=1
      fi
    fi
    check_sources "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl"
    make_work
    resolve_ts ts "$TS"; TS_DIST="$BUILT_DIST"
    run_input_refs "$SOURCES_DIR/api.jsonl" "$SOURCES_DIR/cloud.jsonl" ${IMPACTS[@]+"${IMPACTS[@]}"}
  fi
  require_kubectl
  make_work
  resolve_ts ts "$TS"; TS_DIST="$BUILT_DIST"
  export_both "$WORK"
  export_input_refs_extras "$WORK"
  PROFILE_IDS="$WORK/profile-ids.jsonl"
  run_input_refs "$WORK/api.jsonl" "$WORK/cloud.jsonl" "$WORK/api-impact.jsonl" "$WORK/cloud-impact.jsonl"
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
  "mode_${MODE//-/_}"
  finish 0
}

main "$@"
