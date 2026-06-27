#!/usr/bin/env bash
# ADR 0023 阶段5：发布列车执行器（被 release-train.yml 调用）。Codex 审查 v2 修订：
# 精确 per-artifact 可见性 + 组内全 artifact 可见才算完成 + dispatch-time run 关联 +
# service 等 deploy 完成 + scoped-npm 正确探测。
#
# 输入（env）：GH_TOKEN(repo+read:packages) / LAYERS(coalesce JSON) / DRY_RUN /
#   FROM_LAYER / TRAIN_ID
#
# 每个 (repo,workflow) 步骤：组内全 artifact 已可见→skip(幂等)；否则 dispatch →
# 等 tag → 等本次 dispatch 触发的 publish run(created_at>=dispatch 时刻 + head_sha=tag commit)
# → 等组内全 artifact registry 可见。forward-only 失败即停。
set -euo pipefail

ORG=aster-cloud
DRY="${DRY_RUN:-true}"
FROM="${FROM_LAYER:-0}"
POLL_INTERVAL=20
POLL_MAX=90   # 90 × 20s = 30min/项（Java/Gradle 冷缓存发布偏慢）

command -v jq  >/dev/null || { echo "::error::jq not found"; exit 1; }
command -v gh  >/dev/null || { echo "::error::gh not found"; exit 1; }
command -v npm >/dev/null || { echo "::error::npm not found"; exit 1; }

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# run 关联用的起始时刻：回退 60s 容忍 runner 与 GitHub API created_at 的边界/时钟偏差。
since_iso() { date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ; }

# 远端是否已存在该 tag。
remote_tag_exists() {  # repo, tag
  gh api "repos/$ORG/$1/git/refs/tags/$2" -q '.ref' >/dev/null 2>&1
}

# ── 单个 artifact 可见性（精确，按具体 package name）────────────────────────
artifact_visible() {  # $1=artifact JSON
  local a="$1" kind ver npm reg pkgs p
  kind=$(jq -r '.kind' <<<"$a")
  ver=$(jq -r '.version // empty' <<<"$a")
  case "$kind" in
    maven|catalog)
      # 组内（如 locales:maven 的 en/zh/de）所有 mavenPackages 都须含该 version。
      pkgs=$(jq -r '.mavenPackages[]?' <<<"$a")
      [ -n "$pkgs" ] || return 1
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        gh api "orgs/$ORG/packages/maven/$p/versions" -q '.[].name' 2>/dev/null \
          | grep -qx "$ver" || return 1
      done <<<"$pkgs"
      return 0 ;;
    npm)
      npm=$(jq -r '.npmName // empty' <<<"$a")
      reg=$(jq -r '.npmRegistry // empty' <<<"$a")
      [ -n "$npm" ] || return 1
      if [ "$reg" = "npmjs" ]; then
        npm view "${npm}@${ver}" version --registry=https://registry.npmjs.org >/dev/null 2>&1
        return $?
      else
        # GH Packages npm：package_name 用完整 scoped 名 URL-encode（@aster-cloud%2Fxxx）。
        local enc; enc=$(jq -rn --arg v "$npm" '$v|@uri')
        gh api "orgs/$ORG/packages/npm/$enc/versions" -q '.[].name' 2>/dev/null | grep -qx "$ver"
        return $?
      fi ;;
    service) return 0 ;;  # service 无 registry 版本，可见性由 deploy run 成功代表（见 run_step）
  esac
  return 1
}

# 组内全部 artifact 可见？
all_artifacts_visible() {  # $1=step JSON
  local step="$1" n i a
  n=$(jq '.artifacts | length' <<<"$step")
  for ((i=0;i<n;i++)); do
    a=$(jq -c ".artifacts[$i]" <<<"$step")
    artifact_visible "$a" || return 1
  done
  return 0
}

# 等 tag 在远端出现，回显其指向的 commit SHA（lightweight tag → object 即 commit；
# annotated → peel 到 commit）。
wait_tag_commit() {  # repo, tag
  local repo="$1" tag="$2" i typ sha
  for ((i=0;i<POLL_MAX;i++)); do
    typ=$(gh api "repos/$ORG/$repo/git/refs/tags/$tag" -q '.object.type' 2>/dev/null || true)
    if [ "$typ" = "commit" ]; then
      gh api "repos/$ORG/$repo/git/refs/tags/$tag" -q '.object.sha'; return 0
    elif [ "$typ" = "tag" ]; then
      sha=$(gh api "repos/$ORG/$repo/git/refs/tags/$tag" -q '.object.sha')
      gh api "repos/$ORG/$repo/git/tags/$sha" -q '.object.sha'; return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  log "::error::tag $tag 在 $repo 未在超时内出现"; return 1
}

# 等本次 dispatch 触发的 publish run 完成。关联条件：event=push + head_sha=tag commit
# + created_at >= dispatch 时刻（防匹配到同 commit 的历史旧 run）。
wait_publish_run() {  # repo, workflow, commit_sha, since_iso
  local repo="$1" workflow="$2" commit="$3" since="$4" i run status concl
  for ((i=0;i<POLL_MAX;i++)); do
    run=$(gh api --method GET "repos/$ORG/$repo/actions/workflows/$workflow/runs" \
            -f event=push -f head_sha="$commit" -f created=">=$since" -f per_page=100 \
            -q '.workflow_runs | sort_by(.created_at) | last | .id' 2>/dev/null || true)
    if [ -n "$run" ] && [ "$run" != "null" ]; then
      status=$(gh api "repos/$ORG/$repo/actions/runs/$run" -q '.status' 2>/dev/null || true)
      if [ "$status" = "completed" ]; then
        concl=$(gh api "repos/$ORG/$repo/actions/runs/$run" -q '.conclusion')
        [ "$concl" = "success" ] && { log "  publish run $run success"; return 0; }
        log "::error::publish run $run conclusion=$concl"; return 1
      fi
    fi
    sleep "$POLL_INTERVAL"
  done
  log "::error::$repo/$workflow 的 tag-push publish run 未在超时内完成"; return 1
}

# 等某 dispatch 的 workflow_dispatch run 完成（用于 service deploy）。
wait_dispatch_run() {  # repo, workflow, since_iso
  local repo="$1" workflow="$2" since="$3" i run status concl
  for ((i=0;i<POLL_MAX;i++)); do
    run=$(gh api --method GET "repos/$ORG/$repo/actions/workflows/$workflow/runs" \
            -f event=workflow_dispatch -f created=">=$since" -f per_page=100 \
            -q '.workflow_runs | sort_by(.created_at) | last | .id' 2>/dev/null || true)
    if [ -n "$run" ] && [ "$run" != "null" ]; then
      status=$(gh api "repos/$ORG/$repo/actions/runs/$run" -q '.status' 2>/dev/null || true)
      if [ "$status" = "completed" ]; then
        concl=$(gh api "repos/$ORG/$repo/actions/runs/$run" -q '.conclusion')
        [ "$concl" = "success" ] && { log "  dispatch run $run success"; return 0; }
        log "::error::dispatch run $run conclusion=$concl"; return 1
      fi
    fi
    sleep "$POLL_INTERVAL"
  done
  log "::error::$repo/$workflow 的 dispatch run 未在超时内完成"; return 1
}

run_step() {  # $1 = step JSON
  local step="$1" repo workflow version ids kinds since tag commit
  repo=$(jq -r '.repo' <<<"$step")
  workflow=$(jq -r '.workflow' <<<"$step")
  version=$(jq -r '.version // empty' <<<"$step")
  ids=$(jq -r '.artifactIds | join(",")' <<<"$step")
  kinds=$(jq -r '.kinds | join(",")' <<<"$step")
  log "STEP $repo/$workflow v${version:-<none>} ids=[$ids]"

  # service（aster-api/deploy.yml）：无 version/tag → dispatch 并**等 deploy run 成功**。
  if [ "$kinds" = "service" ] || [ -z "$version" ]; then
    if [ "$DRY" = "true" ]; then log "  [dry-run] would dispatch+wait $repo/$workflow (service deploy)"; return 0; fi
    since=$(since_iso)
    gh workflow run "$workflow" --repo "$ORG/$repo" --ref main -f trainId="$TRAIN_ID" 2>/dev/null \
      || gh workflow run "$workflow" --repo "$ORG/$repo" --ref main
    log "  dispatched service deploy; waiting for deploy run ..."
    sleep 5
    wait_dispatch_run "$repo" "$workflow" "$since"
    return $?
  fi

  # 幂等：组内全 artifact 已可见 → skip（resume 安全；dual-artifact 要求全可见）
  if all_artifacts_visible "$step"; then
    log "  all artifacts v$version already visible → skip (resume/idempotent)"
    return 0
  fi

  tag="v$version"

  # fail-fast：tag 已存在但 artifact 不全。各仓 create-tag 对已存在同 commit tag 是
  # no-op（不会再触发 publish），等 push run 会白等到超时。直接报错让人工恢复
  # （rerun 对应 tag-push publish run，或排查为何某 artifact 没发——如 locales zh/de 缺包）。
  if remote_tag_exists "$repo" "$tag"; then
    log "::error::$repo $tag 已存在但组内 artifact 未全部可见（部分发布/发布失败）。"
    log "::error::dispatch 对已存在 tag 是 no-op，不会重新发布。需人工恢复：rerun $repo 的 tag-push publish run，或排查缺失 artifact。"
    return 1
  fi

  if [ "$DRY" = "true" ]; then
    log "  [dry-run] would: gh workflow run $workflow --repo $ORG/$repo --ref main -f version=$version -f artifactIds=$ids -f trainId=$TRAIN_ID"
    log "  [dry-run] then wait tag $tag → wait push run → wait ALL artifacts visible"
    return 0
  fi

  since=$(since_iso)
  gh workflow run "$workflow" --repo "$ORG/$repo" --ref main \
    -f version="$version" -f artifactIds="$ids" -f trainId="$TRAIN_ID"
  log "  dispatched; waiting for tag $tag ..."
  commit=$(wait_tag_commit "$repo" "$tag")
  log "  tag $tag → commit $commit; waiting for publish run (since $since) ..."
  wait_publish_run "$repo" "$workflow" "$commit" "$since"
  log "  waiting for ALL artifacts registry visibility ..."
  local i
  for ((i=0;i<POLL_MAX;i++)); do
    if all_artifacts_visible "$step"; then
      log "  $repo v$version all artifacts visible ✅"; return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  log "::error::$repo v$version 发布后部分 artifact registry 未在超时内可见"; return 1
}

NLAYERS=$(jq 'length' <<<"$LAYERS")
log "Release train start: $NLAYERS layers, fromLayer=$FROM, dryRun=$DRY, trainId=$TRAIN_ID"
for ((L=FROM; L<NLAYERS; L++)); do
  log "=== Layer $L ==="
  LAYER=$(jq ".[$L]" <<<"$LAYERS")
  NSTEPS=$(jq 'length' <<<"$LAYER")
  for ((S=0; S<NSTEPS; S++)); do
    STEP=$(jq -c ".[$S]" <<<"$LAYER")
    run_step "$STEP"
  done
  log "=== Layer $L done ==="
done
log "Release train complete."
