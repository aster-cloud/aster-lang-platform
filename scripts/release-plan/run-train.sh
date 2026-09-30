#!/usr/bin/env bash
# ADR 0023 阶段5：发布列车执行器（被 release-train.yml 调用）。Codex 审查 v2 修订：
# 精确 per-artifact 可见性 + 组内全 artifact 可见才算完成 + dispatch-time run 关联 +
# service 等 deploy 完成 + scoped-npm 正确探测。
#
# 输入（env）：
#   GH_TOKEN   跨仓写操作用（CROSS_REPO_TOKEN，需 Actions+Contents 写）：gh workflow run
#              dispatch、轮询/读其他仓的 runs 与 tags。**owner=aster-cloud**。
#   WONTLOST_TOKEN  同上但 **owner=wontlost-ltd**（secret CROSS_REPO_TOKEN_WONTLOST，
#              token 名 aster-cross-repo-wontlost）。fine-grained PAT 的 resource owner
#              只能选一个 org，故跨 org 必须备两个 token——这不是冗余配置，是 GitHub 的
#              硬约束。缺省回退 GH_TOKEN（若将来换成 classic PAT 可一个走天下）。
#   VIS_TOKEN  可见性查询用（默认 GITHUB_TOKEN，需 packages:read）：org 级 GH Packages
#              versions 查询。**与 GH_TOKEN 分离**——fine-grained CROSS_REPO_TOKEN 读
#              GH Packages 私有 Maven 包受限/可能 403；GITHUB_TOKEN 内置 packages:read
#              且能读本 org 的包，更健壮。缺省回退到 GH_TOKEN。
#   LAYERS / DRY_RUN / FROM_LAYER / TRAIN_ID
#
# 每个 (repo,workflow) 步骤：组内全 artifact 已可见→skip(幂等)；否则 dispatch →
# 等 tag → 等本次 dispatch 触发的 publish run(created_at>=dispatch 时刻 + head_sha=tag commit)
# → 等组内全 artifact registry 可见。forward-only 失败即停。
set -euo pipefail

# ★仓库所属 org：缺省 aster-cloud；aster-api 于 2026-08 迁至 wontlost-ltd。
#   run_step 会按 step.org 覆写 REPO_ORG（同一 step 内 repo 唯一，故可用全局）。
#   ★PKG_ORG 与之无关且**不随 repo 变**：GH Packages 制品统一发布在 aster-cloud
#     组织下（包名 @aster-cloud/*），即便源码仓迁走也不变。两者别混。
DEFAULT_ORG=aster-cloud
REPO_ORG="$DEFAULT_ORG"
PKG_ORG=aster-cloud
DRY="${DRY_RUN:-true}"
FROM="${FROM_LAYER:-0}"
VIS_TOKEN="${VIS_TOKEN:-$GH_TOKEN}"   # 可见性查询 token（GITHUB_TOKEN），缺省退回 GH_TOKEN
WONTLOST_TOKEN="${WONTLOST_TOKEN:-}"  # owner=wontlost-ltd 的 fine-grained PAT
ASTER_CLOUD_TOKEN="$GH_TOKEN"         # 保留原始（GH_TOKEN 会被 token_for 改写）
# 轮询节奏可由 env 覆写（测试用短轮询驱动超时路径）；生产缺省 90 × 20s = 30min/项
# （Java/Gradle 冷缓存发布偏慢）。
POLL_INTERVAL="${POLL_INTERVAL:-20}"
POLL_MAX="${POLL_MAX:-90}"

# ★日志一律写 stderr：wait_tag_commit 等函数的 stdout 是被 `$(...)` 捕获的返回值
#   （tag commit SHA），若 log 也写 stdout，超时时的 ::error:: 会被吞进变量而非
#   出现在 Actions 日志里（issue #85）。
# ★错误注解走 err 而非 log：GitHub runner 只把**行首**为 `::` 的行识别为 workflow
#   command，log 的时间戳前缀会让 `::error::` 退化成普通日志行，Annotations 与
#   job summary 里什么都不会出现（issue #89）。err 同样写 stderr，理由同上。
log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
err() { echo "::error::$*" >&2; }

command -v jq  >/dev/null || { err "jq not found"; exit 1; }
command -v gh  >/dev/null || { err "gh not found"; exit 1; }
command -v npm >/dev/null || { err "npm not found"; exit 1; }

# 按目标 org 切换 gh 使用的令牌（gh 从环境读 GH_TOKEN，故只能整体切换）。
# ★fine-grained PAT 的 resource owner 只能选一个 org——这是 GitHub 的硬约束，
#   不是配置冗余。缺 wontlost 令牌时 fail-fast，绝不静默用错 org 的令牌去打
#   （那会得到一个 404，看起来像"仓不存在"，极难排查——本次 aster-api 就踩过）。
use_token_for_org() {  # $1 = org
  case "$1" in
    wontlost-ltd)
      [ -n "$WONTLOST_TOKEN" ] || {
        err "step 目标 org=wontlost-ltd，但未提供 WONTLOST_TOKEN（secret CROSS_REPO_TOKEN_WONTLOST，token 名 aster-cross-repo-wontlost）。fine-grained PAT 的 owner 只能选一个 org，aster-cloud 的令牌对 wontlost-ltd 仓会返回 404。"
        return 1
      }
      export GH_TOKEN="$WONTLOST_TOKEN" ;;
    *)
      export GH_TOKEN="$ASTER_CLOUD_TOKEN" ;;
  esac
}

# run 关联用的起始时刻：回退 60s 容忍 runner 与 GitHub API created_at 的边界/时钟偏差。
since_iso() { date -u -d '60 seconds ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ; }

# 远端是否已存在该 tag。
remote_tag_exists() {  # repo, tag
  gh api "repos/$REPO_ORG/$1/git/refs/tags/$2" -q '.ref' >/dev/null 2>&1
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
        GH_TOKEN="$VIS_TOKEN" gh api "orgs/$PKG_ORG/packages/maven/$p/versions" -q '.[].name' 2>/dev/null \
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
        GH_TOKEN="$VIS_TOKEN" gh api "orgs/$PKG_ORG/packages/npm/$enc/versions" -q '.[].name' 2>/dev/null | grep -qx "$ver"
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
    typ=$(gh api "repos/$REPO_ORG/$repo/git/refs/tags/$tag" -q '.object.type' 2>/dev/null || true)
    if [ "$typ" = "commit" ]; then
      gh api "repos/$REPO_ORG/$repo/git/refs/tags/$tag" -q '.object.sha'; return 0
    elif [ "$typ" = "tag" ]; then
      sha=$(gh api "repos/$REPO_ORG/$repo/git/refs/tags/$tag" -q '.object.sha')
      gh api "repos/$REPO_ORG/$repo/git/tags/$sha" -q '.object.sha'; return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  err "tag $tag 在 $repo 未在超时内出现"; return 1
}

# 等本次 dispatch 触发的 publish run 完成。关联条件：event=push + head_sha=tag commit
# + created_at >= dispatch 时刻（防匹配到同 commit 的历史旧 run）。
wait_publish_run() {  # repo, workflow, commit_sha, since_iso
  local repo="$1" workflow="$2" commit="$3" since="$4" i run status concl
  for ((i=0;i<POLL_MAX;i++)); do
    run=$(gh api --method GET "repos/$REPO_ORG/$repo/actions/workflows/$workflow/runs" \
            -f event=push -f head_sha="$commit" -f created=">=$since" -f per_page=100 \
            -q '.workflow_runs | sort_by(.created_at) | last | .id' 2>/dev/null || true)
    if [ -n "$run" ] && [ "$run" != "null" ]; then
      status=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.status' 2>/dev/null || true)
      if [ "$status" = "completed" ]; then
        concl=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.conclusion')
        [ "$concl" = "success" ] && { log "  publish run $run success"; return 0; }
        err "publish run $run conclusion=$concl"; return 1
      fi
    fi
    sleep "$POLL_INTERVAL"
  done
  err "$repo/$workflow 的 tag-push publish run 未在超时内完成"; return 1
}

# 等某 dispatch 的 workflow_dispatch run 完成（用于 service deploy）。
wait_dispatch_run() {  # repo, workflow, since_iso
  local repo="$1" workflow="$2" since="$3" i run status concl
  for ((i=0;i<POLL_MAX;i++)); do
    run=$(gh api --method GET "repos/$REPO_ORG/$repo/actions/workflows/$workflow/runs" \
            -f event=workflow_dispatch -f created=">=$since" -f per_page=100 \
            -q '.workflow_runs | sort_by(.created_at) | last | .id' 2>/dev/null || true)
    if [ -n "$run" ] && [ "$run" != "null" ]; then
      status=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.status' 2>/dev/null || true)
      if [ "$status" = "completed" ]; then
        concl=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.conclusion')
        [ "$concl" = "success" ] && { log "  dispatch run $run success"; return 0; }
        err "dispatch run $run conclusion=$concl"; return 1
      fi
    fi
    sleep "$POLL_INTERVAL"
  done

  # ★判超时前**再查一次终态**（issue #82）：轮询是离散的，run 可能恰好在最后一次
  #   sleep 期间完成。1.0.29 实测：deploy 21:38:24 success，列车 21:38:42 判超时——
  #   差 18 秒，把一次成功的部署报成了失败。
  run=$(gh api --method GET "repos/$REPO_ORG/$repo/actions/workflows/$workflow/runs" \
          -f event=workflow_dispatch -f created=">=$since" -f per_page=100 \
          -q '.workflow_runs | sort_by(.created_at) | last | .id' 2>/dev/null || true)
  if [ -n "$run" ] && [ "$run" != "null" ]; then
    status=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.status' 2>/dev/null || true)
    if [ "$status" = "completed" ]; then
      concl=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.conclusion')
      [ "$concl" = "success" ] && { log "  dispatch run $run success (末轮补查)"; return 0; }
      err "dispatch run $run conclusion=$concl"; return 1
    fi
    err "$repo/$workflow 的 dispatch run $run 未在超时内完成（末次状态=${status}）"
    return 1
  fi
  err "$repo/$workflow 的 dispatch run 未在超时内完成（且未找到对应 run）"; return 1
}

run_step() {  # $1 = step JSON
  local step="$1" repo workflow version ids kinds since tag commit
  repo=$(jq -r '.repo' <<<"$step")
  # ★按 step 覆写仓库 org（coalesce.py 从 release-plan 的 artifact.org 带出，缺省 aster-cloud）
  #   并同步切换 GH_TOKEN——fine-grained PAT 的 resource owner 只能选一个 org，
  #   故 aster-cloud 与 wontlost-ltd 各需一个 token（见文件头 env 说明）。
  REPO_ORG=$(jq -r '.org // "aster-cloud"' <<<"$step")
  use_token_for_org "$REPO_ORG"
  workflow=$(jq -r '.workflow' <<<"$step")
  version=$(jq -r '.version // empty' <<<"$step")
  ids=$(jq -r '.artifactIds | join(",")' <<<"$step")
  kinds=$(jq -r '.kinds | join(",")' <<<"$step")
  log "STEP $repo/$workflow v${version:-<none>} ids=[$ids]"

  # service（aster-api/deploy.yml）：无 version/tag → dispatch 并**等 deploy run 成功**。
  if [ "$kinds" = "service" ] || [ -z "$version" ]; then
    if [ "$DRY" = "true" ]; then log "  [dry-run] would dispatch+wait $repo/$workflow (service deploy)"; return 0; fi
    since=$(since_iso)
    # ★trainId 必须传进去，且传不进去要**报错**（issue #82）。
    #
    #   旧写法是 `-f trainId=... 2>/dev/null || <无参重试>`：deploy.yml 当时根本没定义
    #   任何 workflow_dispatch input，于是带参 dispatch 必然失败、错误被 2>/dev/null 吞掉、
    #   静默走无参 fallback。后果是被 dispatch 的 deploy **无从得知自己是列车触发的**，
    #   其 image-pin-pr 只认 push 事件 → 静默 skip → 集群永不换版本，
    #   而列车这头只看到一个「等待超时」。1.0.29 实测就是这样发出去的。
    #
    #   现在：传参失败即失败。宁可在这里红，也不要发完制品才发现集群没换版本。
    if ! gh workflow run "$workflow" --repo "$REPO_ORG/$repo" --ref main \
           -f trainId="$TRAIN_ID"; then
      err "dispatch $repo/$workflow 失败（带 trainId=${TRAIN_ID}）。"
      err "若报 'unexpected input', 说明该 workflow 未定义 trainId input——"
      err "它的 image-pin/部署闭环很可能只认 push 事件，列车触发不会真正生效。"
      return 1
    fi
    log "  dispatched service deploy (trainId=$TRAIN_ID); waiting for deploy run ..."
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
    err "$repo $tag 已存在但组内 artifact 未全部可见（部分发布/发布失败）。"
    err "dispatch 对已存在 tag 是 no-op，不会重新发布。需人工恢复：rerun $repo 的 tag-push publish run，或排查缺失 artifact。"
    return 1
  fi

  if [ "$DRY" = "true" ]; then
    log "  [dry-run] would: gh workflow run $workflow --repo $REPO_ORG/$repo --ref main -f version=$version -f artifactIds=$ids -f trainId=$TRAIN_ID"
    log "  [dry-run] then wait tag $tag → wait push run → wait ALL artifacts visible"
    return 0
  fi

  since=$(since_iso)
  gh workflow run "$workflow" --repo "$REPO_ORG/$repo" --ref main \
    -f version="$version" -f artifactIds="$ids" -f trainId="$TRAIN_ID"
  log "  dispatched; waiting for tag $tag ..."
  # 显式处理失败而不依赖 set -e 的隐式退出：典型原因是兄弟仓 release.yml 的
  # create-tag 因 dispatch version != build.gradle.kts version 而失败，tag 永不出现。
  commit=$(wait_tag_commit "$repo" "$tag") || {
    err "$repo/$workflow dispatch 后 $tag 未出现，多半是该仓 create-tag 门禁失败（dispatch version != build.gradle.kts version），请查该仓的 release run。"
    return 1
  }
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
  err "$repo v$version 发布后部分 artifact registry 未在超时内可见"; return 1
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
