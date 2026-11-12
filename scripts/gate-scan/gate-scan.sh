#!/usr/bin/env bash
# 发布列车门槛扫描（gate scan）一键入口：把生产库里的策略源码分别用「当前已发布」与「候选」两个
# aster-lang-ts 构建编译一遍，报告编译结论发生变化的策略（只打印 id / kind / 诊断码，不打印源码）。
#
# 流程：
#   1. 解析 --old-ts / --new-ts：已有构建的路径（仓库根或 dist）直接用；否则视为 aster-lang-ts 的
#      git ref（tag / 分支 / commit），在临时目录建 detached worktree，Node 24 + corepack pnpm 安装并构建。
#   2. 经 kubectl exec 在集群 Postgres pod 里跑只读的 export-policy-sources.sql（aster_api + aster_cloud），
#      导出写到 umask 077 的 mktemp 目录。
#   3. 运行 scan.mjs 比较两边，输出摘要。
#   4. 无论成功失败，EXIT trap 删除临时目录（含导出）并移除临时 worktree。
#
# 不读取任何密钥；SQL 在 READ ONLY 事务里执行，不写任何库。
# 退出码：0 = 无报告项；1 = 有报告项（需人工确认）；2 = 用法错误；3 = 环境 / 构建 / 导出失败。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SQL="$HERE/export-policy-sources.sql"
SCAN="$HERE/scan.mjs"
TS_REPO="${ASTER_TS_REPO:-$REPO_ROOT/../aster-lang-ts}"

OLD_TS=""; NEW_TS=""; CODE=""; KUBE_CONTEXT=""
NAMESPACE="data-services"; POD="shared-postgres-1"
API_DB="aster_api"; CLOUD_DB="aster_cloud"
DRY_RUN=false
FETCHED=""

usage() {
  cat <<EOF
用法：scripts/gate-scan/gate-scan.sh --old-ts <ref|path> --new-ts <ref|path> [选项]

  --old-ts <ref|path>   当前已发布的 aster-lang-ts：git ref（如 v1.4.0）或已构建的目录（仓库根或 dist）
  --new-ts <ref|path>   候选 aster-lang-ts：git ref（如 fix/250-type-nesting-guard）或已构建的目录
  --code <CODE>         只报告「旧版无 CODE、新版有 CODE」的策略（如 E054）；缺省报告全部诊断码变化
  --kube-context <ctx>  kubectl context（缺省用当前 context）
  --namespace <ns>      Postgres 所在 namespace（缺省 ${NAMESPACE}）
  --pod <pod>           Postgres pod（缺省 ${POD}）
  --api-db <db>         aster-api 库名（缺省 ${API_DB}）
  --cloud-db <db>       aster-cloud 库名（缺省 ${CLOUD_DB}）
  --dry-run             只打印将执行的命令，不构建、不连集群
  -h, --help            显示本帮助

环境变量：ASTER_TS_REPO  aster-lang-ts 克隆路径（缺省 ${TS_REPO}），git ref 模式需要。
退出码：0 无报告项；1 有报告项；2 用法错误；3 环境 / 构建 / 导出失败。
EOF
}

log() { echo "[gate-scan] $*" >&2; }
fail() { echo "[gate-scan] 错误：$*" >&2; exit 3; }
usage_error() { echo "[gate-scan] 用法错误：$*" >&2; echo "运行 --help 查看用法" >&2; exit 2; }

# 打印（dry-run）或执行一条命令。
run() {
  if [ "$DRY_RUN" = true ]; then
    printf '+'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --old-ts|--new-ts|--code|--kube-context|--namespace|--pod|--api-db|--cloud-db)
        [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 需要一个值"
        case "$1" in
          --old-ts) OLD_TS="$2" ;;
          --new-ts) NEW_TS="$2" ;;
          --code) CODE="$2" ;;
          --kube-context) KUBE_CONTEXT="$2" ;;
          --namespace) NAMESPACE="$2" ;;
          --pod) POD="$2" ;;
          --api-db) API_DB="$2" ;;
          --cloud-db) CLOUD_DB="$2" ;;
        esac
        shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "未知参数 $1" ;;
    esac
  done
  [ -n "$OLD_TS" ] || usage_error "缺少 --old-ts"
  [ -n "$NEW_TS" ] || usage_error "缺少 --new-ts"
}

check_tools() {
  [ "$DRY_RUN" = true ] && return 0
  command -v node >/dev/null || fail "找不到 node（需要 Node 24，如 export PATH=/opt/homebrew/opt/node@24/bin:\${PATH}）"
  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$major" -ge 24 ] || fail "需要 Node 24+，当前 $(node -v)（如 export PATH=/opt/homebrew/opt/node@24/bin:\${PATH}）"
  command -v kubectl >/dev/null || fail "找不到 kubectl"
  command -v git >/dev/null || fail "找不到 git"
}

# 已构建目录 → 打印其 dist 绝对路径；不是目录 → 打印空串（视为 git ref）；目录但未构建 → 报错。
existing_dist() {
  local path="$1"
  [ -d "$path" ] || return 0
  if [ -f "$path/dist/src/browser.js" ]; then (cd "$path/dist" && pwd); return 0; fi
  if [ -f "$path/src/browser.js" ]; then (cd "$path" && pwd); return 0; fi
  fail "$path 是目录但没有构建产物（缺 dist/src/browser.js）——先在其中 pnpm build，或改传 git ref"
}

# git ref → commit：远端分支优先（取最新），其次 tag / 本地分支 / commit。
resolve_ref() {
  local ref="$1"
  git -C "$TS_REPO" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" \
    || git -C "$TS_REPO" rev-parse --verify --quiet "$ref^{commit}" \
    || fail "在 $TS_REPO 找不到 ref ${ref}（已 fetch origin）"
}

# 在临时 worktree 构建 ref，结果 dist 路径写到全局 BUILT_DIST。
build_ref() {
  local label="$1" ref="$2" dir="$WORK/ts-$1"
  if [ "$DRY_RUN" = true ]; then
    [ -n "$FETCHED" ] || run git -C "$TS_REPO" fetch --quiet --tags origin
    FETCHED=1
    run git -C "$TS_REPO" worktree add --detach "$dir" "<commit of $ref>"
    printf '+ (cd %q && corepack pnpm install --frozen-lockfile && corepack pnpm run build)\n' "$dir"
    BUILT_DIST="$dir/dist"
    return 0
  fi
  git -C "$TS_REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || fail "$ref 不是已构建目录，且 ASTER_TS_REPO=$TS_REPO 不是 git 仓库（设置 ASTER_TS_REPO 指向 aster-lang-ts 克隆）"
  command -v corepack >/dev/null || fail "找不到 corepack（Node 24 自带；检查 PATH）"
  if [ -z "$FETCHED" ]; then
    git -C "$TS_REPO" fetch --quiet --tags origin || log "警告：fetch origin 失败，使用本地已有的 ref"
    FETCHED=1
  fi
  local commit
  commit="$(resolve_ref "$ref")"
  log "构建 ${label}：$ref ($(git -C "$TS_REPO" rev-parse --short "$commit"))"
  WORKTREES+=("$dir")  # 先登记再创建：中途被打断也会被 cleanup 移除
  git -C "$TS_REPO" worktree add --quiet --detach "$dir" "$commit"
  if ! (cd "$dir" && corepack pnpm install --frozen-lockfile && corepack pnpm run build) >"$WORK/build-$label.log" 2>&1; then
    tail -n 30 "$WORK/build-$label.log" >&2
    fail "构建 $ref 失败（上面是构建日志末尾）"
  fi
  BUILT_DIST="$dir/dist"
}

resolve_ts() {
  local label="$1" arg="$2" dist
  dist="$(existing_dist "$arg")"
  if [ -n "$dist" ]; then
    log "$label 使用已有构建 $dist"
    BUILT_DIST="$dist"
  else
    build_ref "$label" "$arg"
  fi
}

# 在集群 Postgres pod 里跑只读导出；$1=库名，$2=输出文件，其余为额外 psql 参数。
export_db() {
  local db="$1" out="$2"; shift 2
  local kube=(kubectl)
  [ -n "$KUBE_CONTEXT" ] && kube+=(--context "$KUBE_CONTEXT")
  kube+=(-n "$NAMESPACE" exec -i "$POD" -- psql -X -At -v ON_ERROR_STOP=1 -d "$db" "$@" -f -)
  if [ "$DRY_RUN" = true ]; then
    printf '+'; printf ' %q' "${kube[@]}"; printf ' < %q > %q\n' "$SQL" "$out"
    return 0
  fi
  log "导出 $db"
  "${kube[@]}" <"$SQL" >"$out" || fail "导出 $db 失败（kubectl exec / psql 非零退出）"
}

cleanup() {
  local wt
  for wt in "${WORKTREES[@]+"${WORKTREES[@]}"}"; do
    git -C "$TS_REPO" worktree remove --force "$wt" >/dev/null 2>&1 || true
  done
  [ "${#WORKTREES[@]}" -eq 0 ] || git -C "$TS_REPO" worktree prune >/dev/null 2>&1 || true
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

main() {
  parse_args "$@"
  check_tools
  umask 077
  WORKTREES=()
  local tmp="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "${tmp%/}/gate-scan.XXXXXX")"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$DRY_RUN" = true ] && log "dry-run：只打印命令（临时目录 $WORK 退出时删除）"

  resolve_ts old "$OLD_TS"; local old_dist="$BUILT_DIST"
  resolve_ts new "$NEW_TS"; local new_dist="$BUILT_DIST"

  export_db "$API_DB" "$WORK/api.jsonl"
  export_db "$CLOUD_DB" "$WORK/cloud.jsonl" -v cloud=1

  local scan=(node "$SCAN" --old "$old_dist" --new "$new_dist" --sources "$WORK/sources.jsonl")
  [ -n "$CODE" ] && scan+=(--code "$CODE")
  if [ "$DRY_RUN" = true ]; then
    printf '+ cat %q %q > %q\n' "$WORK/api.jsonl" "$WORK/cloud.jsonl" "$WORK/sources.jsonl"
    run "${scan[@]}"
    return 0
  fi

  [ -s "$WORK/api.jsonl" ] || log "警告：$API_DB 导出为空"
  [ -s "$WORK/cloud.jsonl" ] || log "警告：$CLOUD_DB 导出为空"
  cat "$WORK/api.jsonl" "$WORK/cloud.jsonl" >"$WORK/sources.jsonl"
  [ -s "$WORK/sources.jsonl" ] || fail "两个库都没有导出任何策略源码——检查 pod / 库名，空扫描不算通过"

  local rc=0
  "${scan[@]}" || rc=$?
  [ "$rc" -le 1 ] || fail "scan.mjs 异常退出（rc=${rc}）"
  return "$rc"
}

main "$@"
