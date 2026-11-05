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
# ★service（aster-api deploy）单独的上限（ADR 0053 §6）：deploy 含 ~28min 全量 build&test，
#   实测 26–32min（1.0.38 / 1.0.39），与 Java 发布共用的 30min 上限几乎贴边——1.0.39 的
#   deploy 32 分钟成功，列车却在第 30 分钟报超时。缺省 180 × 20s = 60min，仍是有界等待。
SERVICE_POLL_MAX="${SERVICE_POLL_MAX:-180}"
# stale gate（ADR 0053 §7）：preflight 记录的各仓 main SHA（JSON 对象 repo→sha）。
# dispatch 前若该仓 main 已前进 → 停车，防「drift gate 验的是 A，发出去的是 B」（1.0.37）。
# 缺省 {} = 不设防（向后兼容：老的 workflow 不传它时行为不变）。
MAIN_SHAS="${MAIN_SHAS:-}"
[ -n "$MAIN_SHAS" ] || MAIN_SHAS='{}'
# 列车清单（ADR 0053 §3/§8）：每个 step 的 repo/tag/commit/run/结果，供下游复用与审计；
# 由 release-train.yml 作为 train-<id>-manifest 制品上传，cleanup 阶段删除。
TRAIN_MANIFEST="${TRAIN_MANIFEST:-${RUNNER_TEMP:-/tmp}/train-manifest-${TRAIN_ID}.json}"
STEP_DIR="$(mktemp -d)"
trap 'rm -rf "$STEP_DIR"' EXIT
STEP_LABEL=""

# ★日志一律写 stderr：wait_tag_commit 等函数的 stdout 是被 `$(...)` 捕获的返回值
#   （tag commit SHA），若 log 也写 stdout，超时时的 ::error:: 会被吞进变量而非
#   出现在 Actions 日志里（issue #85）。
# ★错误注解走 err 而非 log：GitHub runner 只把**行首**为 `::` 的行识别为 workflow
#   command，log 的时间戳前缀会让 `::error::` 退化成普通日志行，Annotations 与
#   job summary 里什么都不会出现（issue #89）。err 同样写 stderr，理由同上。
log() { echo "[$(date -u +%H:%M:%S)]${STEP_LABEL:+ [$STEP_LABEL]} $*" >&2; }
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
  local a="$1" kind ver npm reg pkgs p vers
  kind=$(jq -r '.kind' <<<"$a")
  ver=$(jq -r '.version // empty' <<<"$a")
  case "$kind" in
    maven|catalog)
      # 组内（如 locales:maven 的 en/zh/de）所有 mavenPackages 都须含该 version。
      pkgs=$(jq -r '.mavenPackages[]?' <<<"$a")
      [ -n "$pkgs" ] || return 1
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        # ★先取全量再 grep，不要 `gh … | grep -q`：grep -q 命中即退出，gh 随后写管道得 SIGPIPE，
        #   在 pipefail 下整条管道判失败 → 「已发布却判不可见」（本地 dry-run 实测复现）。
        #   --paginate：版本数超过一页（30）后旧实现只看第一页。
        vers=$(GH_TOKEN="$VIS_TOKEN" gh api --paginate "orgs/$PKG_ORG/packages/maven/$p/versions" -q '.[].name' 2>/dev/null || true)
        grep -qx "$ver" <<<"$vers" || return 1
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
        vers=$(GH_TOKEN="$VIS_TOKEN" gh api --paginate "orgs/$PKG_ORG/packages/npm/$enc/versions" -q '.[].name' 2>/dev/null || true)
        grep -qx "$ver" <<<"$vers"
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

# 解析 tag 指向的 commit SHA（lightweight tag → object 即 commit；annotated → peel 到 commit）。
# tag 不存在返回非零。只查一次，不等待。
resolve_tag_commit() {  # repo, tag
  local repo="$1" tag="$2" typ sha
  typ=$(gh api "repos/$REPO_ORG/$repo/git/refs/tags/$tag" -q '.object.type' 2>/dev/null || true)
  if [ "$typ" = "commit" ]; then
    gh api "repos/$REPO_ORG/$repo/git/refs/tags/$tag" -q '.object.sha'; return 0
  elif [ "$typ" = "tag" ]; then
    sha=$(gh api "repos/$REPO_ORG/$repo/git/refs/tags/$tag" -q '.object.sha')
    gh api "repos/$REPO_ORG/$repo/git/tags/$sha" -q '.object.sha'; return 0
  fi
  return 1
}

# 等 tag 在远端出现，回显其指向的 commit SHA。
wait_tag_commit() {  # repo, tag
  local repo="$1" tag="$2" i
  for ((i=0;i<POLL_MAX;i++)); do
    resolve_tag_commit "$repo" "$tag" && return 0
    sleep "$POLL_INTERVAL"
  done
  err "tag $tag 在 $repo 未在超时内出现"; return 1
}

# stale gate（ADR 0053 §7）：dispatch 前确认该仓 main 仍是 preflight 时验过的那个 commit。
# 发布 workflow 一律 `--ref main` 打 tag，若 main 在列车途中前进（有 PR 合入），tag 会打在
# drift gate **没验过**的 commit 上——1.0.37 层 4 deploy 失败即此。宁可停车也不发未验 commit。
stale_gate() {  # repo
  local repo="$1" want tip
  want=$(jq -r --arg r "$repo" '.[$r] // empty' <<<"$MAIN_SHAS")
  [ -n "$want" ] || return 0
  tip=$(gh api "repos/$REPO_ORG/$repo/commits/main" -q '.sha' 2>/dev/null || true)
  if [ -z "$tip" ]; then
    err "$repo 无法解析 main tip（stale gate fail-closed）"; return 1
  fi
  if [ "$tip" != "$want" ]; then
    err "$repo main 已从 preflight 的 $want 前进到 ${tip}（列车途中有合入）。停车：重跑列车（preflight 会重新验新 tip），或用 fromLayer 从本层续跑。"
    return 1
  fi
  log "  stale gate: $repo main 仍为 ${want:0:12} ✓"
}

# 记录本 step 的结果到 STEP_DIR（层末合并进 TRAIN_MANIFEST）。并行 step 各写各的文件，无竞争。
record_step() {  # step, result, tag, commit, run
  jq -cn --argjson s "$1" --arg result "$2" --arg tag "$3" --arg commit "$4" --arg run "$5" \
    '{repo:$s.repo, org:($s.org // "aster-cloud"), workflow:$s.workflow, artifactIds:$s.artifactIds,
      tag:(if $tag=="" then null else $tag end), commit:(if $commit=="" then null else $commit end),
      run:(if $run=="" then null else ($run|tonumber) end), result:$result}' \
    >"$STEP_DIR/step-$(jq -r '.artifactIds|join("_")' <<<"$1" | tr ':/' '__').json"
}

# 把已完成 step 合并成清单（每层末调用一次 → 失败时清单也反映已发布到哪一层）。
write_manifest() {
  local files=("$STEP_DIR"/step-*.json)
  if [ -e "${files[0]}" ]; then
    jq -s --arg id "$TRAIN_ID" '{trainId:$id, steps:.}' "${files[@]}" >"$TRAIN_MANIFEST"
  else
    jq -n --arg id "$TRAIN_ID" '{trainId:$id, steps:[]}' >"$TRAIN_MANIFEST"
  fi
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
        [ "$concl" = "success" ] && { PUBLISH_RUN="$run"; log "  publish run $run success"; return 0; }
        err "publish run $run conclusion=$concl"; return 1
      fi
    fi
    sleep "$POLL_INTERVAL"
  done
  err "$repo/$workflow 的 tag-push publish run 未在超时内完成"; return 1
}

# 找本列车 dispatch 的 deploy run（ADR 0053 §6）。
# ★信号要对：旧实现取「created>=since 的**最新**一个 dispatch run」，任何人在此期间手工
#   dispatch 一次 deploy 就会关联错。现在优先按 run-name 关联——deploy.yml 在 trainId 非空时
#   把 run 标题设为「Deploy · train <id>」；老版本 deploy.yml 无 run-name 时回退为
#   created>=since 的**最早**一个 dispatch run（列车 dispatch 之后最先出现的那个）。
find_service_run() {  # repo, workflow, since
  local repo="$1" workflow="$2" since="$3"
  gh api --method GET "repos/$REPO_ORG/$repo/actions/workflows/$workflow/runs" \
    -f event=workflow_dispatch -f created=">=$since" -f per_page=100 \
    -q "[.workflow_runs[] | select((.display_title // \"\") | endswith(\"train $TRAIN_ID\"))] as \$t
        | if (\$t|length)>0 then (\$t | sort_by(.created_at) | last | .id)
          else (.workflow_runs | sort_by(.created_at) | first | .id // empty) end" 2>/dev/null || true
}

# 查 run 终态：0=success，1=失败，2=未完成。
run_terminal() {  # repo, run
  local status concl
  status=$(gh api "repos/$REPO_ORG/$1/actions/runs/$2" -q '.status' 2>/dev/null || true)
  [ "$status" = "completed" ] || { RUN_STATUS="${status:-unknown}"; return 2; }
  concl=$(gh api "repos/$REPO_ORG/$1/actions/runs/$2" -q '.conclusion')
  [ "$concl" = "success" ] && return 0
  RUN_STATUS="completed/$concl"; return 1
}

# 等本列车 dispatch 的 deploy run 完成（service step）。上限 SERVICE_POLL_MAX，有界。
wait_dispatch_run() {  # repo, workflow, since_iso
  local repo="$1" workflow="$2" since="$3" i run="" rc
  RUN_STATUS=""
  # ★<= 而非 <：最后一轮之后**再查一次终态**（issue #82，1.0.29 差 18 秒误判超时）。
  for ((i=0;i<=SERVICE_POLL_MAX;i++)); do
    [ -n "$run" ] || run=$(find_service_run "$repo" "$workflow" "$since")
    if [ -n "$run" ] && [ "$run" != "null" ]; then
      rc=0; run_terminal "$repo" "$run" || rc=$?
      case "$rc" in
        0) SERVICE_RUN="$run"; log "  deploy run $run success"; return 0 ;;
        1) err "$repo/$workflow deploy run $run ${RUN_STATUS}"; return 1 ;;
      esac
    fi
    [ "$i" -lt "$SERVICE_POLL_MAX" ] && sleep "$POLL_INTERVAL"
  done
  if [ -n "$run" ]; then
    err "$repo/$workflow 的 deploy run $run 未在 $((SERVICE_POLL_MAX*POLL_INTERVAL))s 内完成（末次状态=${RUN_STATUS}）。run 仍在跑时请看 https://github.com/$REPO_ORG/$repo/actions/runs/$run ——它成功即部署成功，可用 fromLayer 续跑以收尾。"
  else
    err "$repo/$workflow 的 deploy run 未在超时内出现（未找到标题含 train $TRAIN_ID 的 dispatch run）"
  fi
  return 1
}

run_step() {  # $1 = step JSON
  local step="$1" repo workflow version prefix ids kinds since tag commit
  repo=$(jq -r '.repo' <<<"$step")
  # ★按 step 覆写仓库 org（coalesce.py 从 release-plan 的 artifact.org 带出，缺省 aster-cloud）
  #   并同步切换 GH_TOKEN——fine-grained PAT 的 resource owner 只能选一个 org，
  #   故 aster-cloud 与 wontlost-ltd 各需一个 token（见文件头 env 说明）。
  REPO_ORG=$(jq -r '.org // "aster-cloud"' <<<"$step")
  use_token_for_org "$REPO_ORG"
  workflow=$(jq -r '.workflow' <<<"$step")
  version=$(jq -r '.version // empty' <<<"$step")
  # tag 前缀由 coalesce.py 从 release-plan 的 artifact.tagPrefix 带出（缺省 v）；
  # 独立号 npm 制品用专属前缀（test:npm=npm-v），避免与生态号 v* 撞 tag（aster-lang-test#168）。
  prefix=$(jq -r '.tagPrefix // "v"' <<<"$step")
  ids=$(jq -r '.artifactIds | join(",")' <<<"$step")
  kinds=$(jq -r '.kinds | join(",")' <<<"$step")
  log "STEP $repo/$workflow ${version:+$prefix}${version:-<none>} ids=[$ids]"

  # service（aster-api/deploy.yml）：无 version/tag → dispatch 并**等 deploy run 成功**。
  if [ "$kinds" = "service" ] || [ -z "$version" ]; then
    stale_gate "$repo" || return 1
    if [ "$DRY" = "true" ]; then
      log "  [dry-run] would dispatch+wait $repo/$workflow (service deploy, trainId=$TRAIN_ID, ≤$((SERVICE_POLL_MAX*POLL_INTERVAL))s)"
      record_step "$step" dry-run "" "" ""; return 0
    fi
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
    wait_dispatch_run "$repo" "$workflow" "$since" || return 1
    record_step "$step" deployed "" "" "$SERVICE_RUN"
    return 0
  fi

  # 幂等：组内全 artifact 已可见 → skip（resume 安全；dual-artifact 要求全可见）
  tag="$prefix$version"
  if all_artifacts_visible "$step"; then
    log "  all artifacts $prefix$version already visible → skip (resume/idempotent)"
    record_step "$step" skipped "$tag" "$(resolve_tag_commit "$repo" "$tag" 2>/dev/null || true)" ""
    return 0
  fi

  # fail-fast：tag 已存在但 artifact 不全。各仓 create-tag 对已存在同 commit tag 是
  # no-op（不会再触发 publish），等 push run 会白等到超时。直接报错让人工恢复
  # （rerun 对应 tag-push publish run，或排查为何某 artifact 没发——如 locales zh/de 缺包）。
  if remote_tag_exists "$repo" "$tag"; then
    err "$repo $tag 已存在但组内 artifact 未全部可见（部分发布/发布失败）。"
    err "dispatch 对已存在 tag 是 no-op，不会重新发布。需人工恢复：rerun $repo 的 tag-push publish run，或排查缺失 artifact。"
    return 1
  fi

  stale_gate "$repo" || return 1

  if [ "$DRY" = "true" ]; then
    record_step "$step" dry-run "$tag" "" ""
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
  wait_publish_run "$repo" "$workflow" "$commit" "$since" || return 1
  log "  waiting for ALL artifacts registry visibility ..."
  local i
  for ((i=0;i<POLL_MAX;i++)); do
    if all_artifacts_visible "$step"; then
      log "  $repo $tag all artifacts visible ✅"
      record_step "$step" published "$tag" "$commit" "$PUBLISH_RUN"; return 0
    fi
    sleep "$POLL_INTERVAL"
  done
  err "$repo $tag 发布后部分 artifact registry 未在超时内可见"; return 1
}

NLAYERS=$(jq 'length' <<<"$LAYERS")
log "Release train start: $NLAYERS layers, fromLayer=$FROM, dryRun=$DRY, trainId=$TRAIN_ID"
for ((L=FROM; L<NLAYERS; L++)); do
  log "=== Layer $L ==="
  LAYER=$(jq ".[$L]" <<<"$LAYERS")
  NSTEPS=$(jq 'length' <<<"$LAYER")
  # ★同层 step 并行（ADR 0053 §2）：release-plan 的契约本就是「同一层无依赖可并行」，
  #   旧实现却逐个串行等待——1.0.39 层 1 的四个 Java 发布串行 11.6min，并行只需最长那个 3.8min。
  #   每个 step 在自己的子 shell 里跑（GH_TOKEN/REPO_ORG 按 step 切换互不干扰），
  #   层末统一 wait：任一失败 → 等同层其他 step 收尾后停车（不半途杀掉正在发布的仓）。
  PIDS=(); LABELS=()
  for ((S=0; S<NSTEPS; S++)); do
    STEP=$(jq -c ".[$S]" <<<"$LAYER")
    label="$(jq -r '.repo + "/" + .workflow' <<<"$STEP")"
    ( STEP_LABEL="$label"; run_step "$STEP" ) &
    PIDS+=("$!"); LABELS+=("$label")
  done
  failed=()
  for ((S=0; S<NSTEPS; S++)); do
    wait "${PIDS[$S]}" || failed+=("${LABELS[$S]}")
  done
  write_manifest
  if [ "${#failed[@]}" -gt 0 ]; then
    err "Layer $L 失败：${failed[*]}（forward-only：同层其余 step 已收尾；修复后用 fromLayer=$L 续跑，已发布制品会被幂等 skip）"
    exit 1
  fi
  log "=== Layer $L done ==="
done
log "Release train complete. manifest: $TRAIN_MANIFEST"
