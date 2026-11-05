#!/usr/bin/env bash
# ADR 0053 §9：发布列车清理器。release-train.yml 的 cleanup job（if: always()，成功/失败都跑）
# 与手工 workflow cleanup-train.yml 共用本脚本。只删**本列车**产生的临时物，三类：
#
#   1. tag-ref 缓存：各仓 tag-push 发布 run 在 refs/tags/<tag> 作用域写入的 Actions cache
#      （setup-java gradle / setup-node pnpm）。cache 按 ref 隔离，tag ref 的缓存**永远不会**
#      被后续 main/PR 构建命中，纯占 10GB 配额并挤掉 main 上有用的缓存。
#   2. 本列车触发的 service deploy run 的 workflow 制品（如 aster-api 的 quarkus-app-<key>）：
#      按 run 标题「… train <id>」精确识别，不碰手工或 push 触发的 run。
#      镜像已按 digest 推送并签名，复用走镜像（ADR 0053 §5），这些中间制品已无用。
#   3. 列车自身 run 的 train-<id>-* 制品（manifest 等）。
#
# 兜底：上述制品上传时均设了 retention-days，本脚本若没跑到（runner 被杀等），到期自动回收。
# 缺权限 / API 失败只告警不失败——清理绝不能把一次成功的列车变红。
#
# 输入（env）：
#   GH_TOKEN / WONTLOST_TOKEN  同 run-train.sh（需 Actions: write 才能删 cache / artifact）
#   LAYERS        coalesce.py 输出（决定哪些 repo/tag）
#   TRAIN_ID      列车标识
#   TRAIN_RUN_ID  列车自身的 run id（可空：手工清理时不删列车自身制品）
#   PLATFORM_REPO 列车所在仓 owner/name（缺省 aster-cloud/aster-lang-platform）
#   DRY_RUN       true=只列不删（手工 workflow 缺省 true）
#   KEEP_RESUME   true=保留第 2 类（service deploy 的中间制品）。列车失败时由 workflow 置 true：
#                 那些制品正是续跑（fromLayer）时免重建的复用源（ADR 0053 §5），删了就要再跑
#                 ~28min build&test；它们有 retention-days 兜底，到期自动回收。
set -euo pipefail

DRY="${DRY_RUN:-true}"
PLATFORM_REPO="${PLATFORM_REPO:-aster-cloud/aster-lang-platform}"
TRAIN_RUN_ID="${TRAIN_RUN_ID:-}"
WONTLOST_TOKEN="${WONTLOST_TOKEN:-}"
ASTER_CLOUD_TOKEN="$GH_TOKEN"
KEEP_RESUME="${KEEP_RESUME:-false}"
DELETED=0; FAILED=0

log()  { echo "[cleanup] $*" >&2; }
warn() { echo "::warning::$*" >&2; }

token_for() {  # org
  if [ "$1" = "wontlost-ltd" ]; then
    [ -n "$WONTLOST_TOKEN" ] || return 1
    export GH_TOKEN="$WONTLOST_TOKEN"
  else
    export GH_TOKEN="$ASTER_CLOUD_TOKEN"
  fi
}

delete() {  # what, endpoint
  if [ "$DRY" = "true" ]; then log "  [dry-run] would delete $1"; return 0; fi
  if gh api --method DELETE "$2" >/dev/null 2>&1; then
    DELETED=$((DELETED+1)); log "  deleted $1"
  else
    FAILED=$((FAILED+1)); warn "删除 $1 失败（$2）——到 retention 期自动回收"
  fi
}

# (repo org workflow tag kind) 去重列表
STEPS=$(jq -r '.[][] | [.repo, (.org // "aster-cloud"), .workflow,
  (if .version then ((.tagPrefix // "v") + .version) else "-" end), (.kinds|join(","))] | @tsv' <<<"$LAYERS" | sort -u)

while IFS=$'\t' read -r repo org workflow tag kinds; do
  [ -n "$repo" ] || continue
  [ "$tag" = "-" ] && tag=""
  token_for "$org" || { warn "$org/$repo：缺 WONTLOST_TOKEN，跳过清理"; continue; }
  if [ -n "$tag" ]; then
    log "$org/$repo: tag-ref 缓存 refs/tags/$tag"
    ids=$(gh api --method GET "repos/$org/$repo/actions/caches" -f ref="refs/tags/$tag" -f per_page=100 \
            -q ".actions_caches[] | select(.ref==\"refs/tags/$tag\") | .id" 2>/dev/null || true)
    for id in $ids; do delete "cache $id ($org/$repo refs/tags/$tag)" "repos/$org/$repo/actions/caches/$id"; done
  fi
  if [ "$kinds" = "service" ] && [ "$KEEP_RESUME" = "true" ]; then
    log "$org/$repo: 列车未成功 → 保留 $workflow 的中间制品供续跑复用（retention 到期自动回收）"
  elif [ "$kinds" = "service" ]; then
    log "$org/$repo: 本列车 $workflow run 的制品"
    runs=$(gh api --method GET "repos/$org/$repo/actions/workflows/$workflow/runs" -f event=workflow_dispatch -f per_page=100 \
             -q ".workflow_runs[] | select((.display_title // \"\") | endswith(\"train $TRAIN_ID\")) | .id" 2>/dev/null || true)
    for run in $runs; do
      arts=$(gh api "repos/$org/$repo/actions/runs/$run/artifacts" -q '.artifacts[] | "\(.id)\t\(.name)"' 2>/dev/null || true)
      while IFS=$'\t' read -r aid aname; do
        if [ -n "$aid" ]; then delete "artifact $aid $aname (run $run)" "repos/$org/$repo/actions/artifacts/$aid"; fi
      done <<<"$arts"
    done
  fi
done <<<"$STEPS"

if [ -n "$TRAIN_RUN_ID" ]; then
  export GH_TOKEN="$ASTER_CLOUD_TOKEN"
  log "$PLATFORM_REPO: 列车 run $TRAIN_RUN_ID 的 train-$TRAIN_ID-* 制品"
  arts=$(gh api "repos/$PLATFORM_REPO/actions/runs/$TRAIN_RUN_ID/artifacts" \
           -q ".artifacts[] | select(.name | startswith(\"train-$TRAIN_ID-\")) | \"\(.id)\t\(.name)\"" 2>/dev/null || true)
  while IFS=$'\t' read -r aid aname; do
    if [ -n "$aid" ]; then delete "artifact $aid $aname" "repos/$PLATFORM_REPO/actions/artifacts/$aid"; fi
  done <<<"$arts"
fi

log "done: deleted=$DELETED failed=$FAILED dryRun=$DRY"
echo "cleanup: deleted=$DELETED failed=$FAILED dryRun=$DRY" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
