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
#   TO_LAYER   只跑到第几层（含）。缺省跑到最后一层。release-train.yml 用它把列车分成两段：
#              pin 层之前一段、pin 层起一段，中间签发 App 令牌（令牌 1 小时有效，见 ADR 0053 修订 A1）。
#   PIN_TOKEN  pinOwner=train 的 service step 用的 GitHub App 令牌（aster-train-pin，只装在
#              wontlost-ltd/aster-api）。dry-run 时是只读令牌。缺失即失败（fail-closed）。
#   PIN_TOKEN_ISSUED_AT  该令牌的签发时刻（epoch 秒）。离过期不足 5 分钟时不再写，停车待续跑。
#
# ADR 0053 修订 A1：pinOwner=train 的 service step（aster-api）拆成两个阶段——
#   阶段 P：main 两处 pin 已 == 目标 → 跳过；否则在 preflight SHA 上改两处、开/复用
#           train/aster-api-pin-<X> PR、等必需检查、可证实超时最多自动重跑一次、
#           --match-head-commit 合并。
#   阶段 D：P 合并了 → 跟随 merge commit 的 push deploy run（不再 dispatch）；
#           P 跳过 → 按现状 dispatch，并断言 run 的 head_sha == preflight SHA。
#           两条路径都要求 run 成功 + image-pin 开 PR 步骤成功 + pin-closure-guard 成功。
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
# 连续多少轮找不到带列车标题的 run 后，才回退到「since 后最早的 dispatch run」（老 deploy.yml 兼容）。
# 缺省 15 × 20s = 5min：run 出现在列表里通常只要几秒，5 分钟仍找不到标题即可判定 deploy.yml 没有 run-name。
SERVICE_FALLBACK_AFTER="${SERVICE_FALLBACK_AFTER:-15}"
TO="${TO_LAYER:-}"
# ── ADR 0053 修订 A1：列车接管 aster-api pin bump ──────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_TOKEN="${PIN_TOKEN:-}"
PIN_TOKEN_ISSUED_AT="${PIN_TOKEN_ISSUED_AT:-}"
# 安装令牌 1 小时过期；留 5 分钟余量，过了就不再做写操作（停车，续跑会重新签发）。
PIN_TOKEN_TTL="${PIN_TOKEN_TTL:-3300}"
# pin PR 必需检查的等待上限：缺省 180 × 20s = 60min（托管构建实测 36–40min）。
PIN_CI_POLL_MAX="${PIN_CI_POLL_MAX:-180}"
# 被 bump 仓的 git 远端根（测试指向本地目录）。
GIT_BASE="${GIT_BASE:-https://github.com}"
TRAIN_RUN_URL="${TRAIN_RUN_URL:-}"
PIN_APP_SLUG="${PIN_APP_SLUG:-aster-train-pin}"
# aster-api 规则集 main-protect（id 22982832）的两个必需检查，只认 GitHub Actions（integration 15368）。
PIN_REQUIRED_CHECKS=("ci-result" "Guard bypass suite (#466)")
ACTIONS_APP_ID=15368
# 「可证实超时」只看托管构建：本地 runner 失败会回落到托管，托管才是有超时上限的那一条。
# 按前缀匹配托管路径下的任一 job：ci-build.yml 拆分前只有 `build-hosted / build`，拆成并行 job 后
# 为 `build-hosted / {checks,guard-bypass,unit,integration,verify}`（ADR 0053 修订 A2 §8）。
PIN_HOSTED_BUILD_PREFIX="build-hosted / "
PIN_TIMEOUT_TEXT="has exceeded the maximum execution time"
# pin 改动必须恰好是这两个文件（sort 后的顺序）。
PIN_FILES=$'.github/actions/setup-aster-build/action.yml\nsettings.gradle'
# deploy.yml 的闭环 job / 步骤名（job outputs 不经 REST 暴露，只能看结论）。
DEPLOY_PIN_JOB="image-pin-pr"
DEPLOY_PIN_STEP="Open/update image-pin PR to k3s"
DEPLOY_GUARD_JOB="pin-closure-guard"
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
record_step() {  # step, result, tag, commit, run[, extra JSON 对象（如 pin 字段）]
  jq -cn --argjson s "$1" --arg result "$2" --arg tag "$3" --arg commit "$4" --arg run "$5" \
    --argjson extra "${6:-"{}"}" \
    '{repo:$s.repo, org:($s.org // "aster-cloud"), workflow:$s.workflow, artifactIds:$s.artifactIds,
      tag:(if $tag=="" then null else $tag end), commit:(if $commit=="" then null else $commit end),
      run:(if $run=="" then null else ($run|tonumber) end), result:$result} + $extra' \
    >"$STEP_DIR/step-$(jq -r '.artifactIds|join("_")' <<<"$1" | tr ':/' '__').json"
}

# 分段执行（TO_LAYER）时，第二段要保留第一段已写入的清单条目：先把已有清单拆回 STEP_DIR。
seed_manifest() {
  [ -s "$TRAIN_MANIFEST" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && record_seed "$line"
  done < <(jq -c '.steps[]?' "$TRAIN_MANIFEST" 2>/dev/null || true)
}
record_seed() { echo "$1" >"$STEP_DIR/step-$(jq -r '.artifactIds|join("_")' <<<"$1" | tr ':/' '__').json"; }

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
#   $4=titled   只认标题以「train <id>」结尾的 run（deploy.yml 的 run-name）
#   $4=earliest 回退：created>=since 的**最早**一个 dispatch run（老 deploy.yml 无 run-name 时）
# ★不锁定（review M2）：wait_dispatch_run 每轮都重新按标题查；回退只在**连续**
#   SERVICE_FALLBACK_AFTER 轮无标题匹配后才启用，避免把延迟窗口里插进来的手工 dispatch 当成本列车的。
find_service_run() {  # repo, workflow, since, mode
  local filter
  if [ "$4" = titled ]; then
    filter="[.workflow_runs[] | select((.display_title // \"\") | endswith(\"train $TRAIN_ID\"))] | sort_by(.created_at) | last | .id // empty"
  else
    filter=".workflow_runs | sort_by(.created_at) | first | .id // empty"
  fi
  gh api --method GET "repos/$REPO_ORG/$1/actions/workflows/$2/runs" \
    -f event=workflow_dispatch -f created=">=$3" -f per_page=100 -q "$filter" 2>/dev/null || true
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
  local repo="$1" workflow="$2" since="$3" i run="" rc misses=0 warned=""
  RUN_STATUS=""
  # ★<= 而非 <：最后一轮之后**再查一次终态**（issue #82，1.0.29 差 18 秒误判超时）。
  for ((i=0;i<=SERVICE_POLL_MAX;i++)); do
    run=$(find_service_run "$repo" "$workflow" "$since" titled)
    if [ -z "$run" ]; then
      misses=$((misses+1))
      if [ "$misses" -ge "$SERVICE_FALLBACK_AFTER" ]; then
        run=$(find_service_run "$repo" "$workflow" "$since" earliest)
        if [ -n "$run" ] && [ -z "$warned" ]; then
          log "  连续 $misses 轮无标题含 train $TRAIN_ID 的 run（deploy.yml 缺 run-name？）→ 回退关联 since 后最早的 run $run"
          warned=1
        fi
      fi
    fi
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

# ══ ADR 0053 修订 A1：列车在 L4 接管 aster-api 的 pin bump ═══════════════════════
# 阶段 P 的写操作（推分支、开 PR、重跑 CI、合并）全部用 PIN_TOKEN（GitHub App，只装在 aster-api）；
# 阶段 D 的 dispatch / 轮询沿用 WONTLOST_TOKEN（与 pinOwner=human 的路径相同）。
pin_gh() { GH_TOKEN="$PIN_TOKEN" gh "$@"; }

# 带 App 令牌的 git：经 GIT_CONFIG_* 注入 extraheader（与 actions/checkout 同一做法），
# 令牌不进命令行参数，也不落 .git/config。只对 https://github.com/ 生效。
pin_git() {
  local b64
  b64=$(printf 'x-access-token:%s' "$PIN_TOKEN" | base64 | tr -d '\n')
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $b64" git "$@"
}

# App 令牌是否还在安全期内（签发后 PIN_TOKEN_TTL 秒）。未提供签发时刻时不设防（本地测试）。
pin_token_alive() {
  [ -n "$PIN_TOKEN_ISSUED_AT" ] || return 0
  [ "$(date +%s)" -lt "$((PIN_TOKEN_ISSUED_AT + PIN_TOKEN_TTL))" ]
}
pin_token_expiring() {  # 上下文
  err "App 令牌（1 小时有效）即将过期，$1 前停车；PR 与 CI 保持原状。用 fromLayer=$L 续跑：会重新签发令牌并复用同名 PR 接着等/合并（ADR 0053 修订 A1 §5）。"
}

# 浅取 main 到 $2，回显其 SHA。
pin_checkout() {  # repo dir
  local url="$GIT_BASE/$REPO_ORG/$1.git"
  rm -rf "$2"; git init -q "$2"
  if ! pin_git -C "$2" fetch -q --depth 1 "$url" refs/heads/main 2>"$2.err"; then
    err "fetch $REPO_ORG/$1 main 失败（App 未安装到该仓或令牌无 contents 权限？）：$(tr '\n' ' ' <"$2.err")"
    return 1
  fi
  git -C "$2" checkout -q FETCH_HEAD
  git -C "$2" rev-parse HEAD
}

# 必需检查在 PR head 上的状态：green / pending / failed <check-run id…>。
# 每个检查取 GitHub Actions 出的最新一个；$3 里列出的 id 视为过时（自动重跑前的结果）→ pending。
# 只有两个必需检查都已完成才判 failed：ci-result 依赖其余 job，它完成时整个 CI run 已结束，可以重跑。
pin_checks_state() {  # repo head seen-ids
  local json name line id status concl ids="" pending="" bad=""
  json=$(pin_gh api "repos/$REPO_ORG/$1/commits/$2/check-runs?per_page=100" 2>/dev/null) || { echo pending; return 0; }
  for name in "${PIN_REQUIRED_CHECKS[@]}"; do
    line=$(jq -r --arg n "$name" --argjson app "$ACTIONS_APP_ID" \
      '[.check_runs[]? | select(.name==$n and .app.id==$app)] | sort_by(.id) | last
       | if . == null then "" else "\(.id) \(.status) \(.conclusion)" end' <<<"$json")
    read -r id status concl <<<"$line"
    if [ -z "$id" ] || [ "$status" != "completed" ] || [[ " $3 " == *" $id "* ]]; then
      pending=1; continue
    fi
    ids="$ids $id"
    [ "$concl" = "success" ] || bad=1
  done
  if [ -n "$pending" ]; then echo pending
  elif [ -n "$bad" ]; then echo "failed$ids"
  else echo green; fi
}

# §2.1 第 6 步：只对可证实的超时自动重跑一次。返回 0 = 已重跑，继续等；非 0 = 停车。
# 判定超时：托管构建的 check-run conclusion == timed_out，或其注解含 runner 的固定超时文案。
# 次数记在 GitHub 自己的 run_attempt 里：只有 run_attempt == 1 才重跑，续跑多少次都只重跑一次。
pin_maybe_rerun() {  # repo pr head
  local repo="$1" pr="$2" json cur rows id concl url msgs run attempt proven="" seen=""
  local pr_url="https://github.com/$REPO_ORG/$repo/pull/$pr"
  json=$(pin_gh api "repos/$REPO_ORG/$repo/commits/$3/check-runs?per_page=100" 2>/dev/null) || {
    err "PR #$pr 必需检查失败；查询 check-run 失败，无法证实超时 → 不自动重跑，停车。PR 留给人看：$pr_url"; return 1; }
  # 证据必须来自当前失败的那次 CI run：取最新 ci-result check-run 所属的 run，只看同一 run 的托管 job。
  # 同一 commit 上更早的 run（例如被并发组取消的旧 run）里的超时不能作为证据。
  cur=$(jq -r --argjson app "$ACTIONS_APP_ID" '
    [.check_runs[]? | select(.name == "ci-result" and .app.id == $app)] | sort_by(.id) | last
    | ((.details_url // "") | capture("/actions/runs/(?<r>[0-9]+)/")? | .r) // empty' <<<"$json" 2>/dev/null || true)
  [ -n "$cur" ] || { err "PR #$pr 必需检查失败；无法从 ci-result 确定当前 CI run，无法证实超时 → 不自动重跑，停车。PR：$pr_url"; return 1; }
  # 托管路径下未成功的 job，timed_out 排在前面；逐个找超时证据，第一个被证实的即为重跑对象。
  rows=$(jq -r --arg p "$PIN_HOSTED_BUILD_PREFIX" --arg cur "/actions/runs/$cur/" --argjson app "$ACTIONS_APP_ID" '
    [.check_runs[]? | select((.name | startswith($p)) and .app.id == $app and .status == "completed"
                             and ((.details_url // "") | contains($cur))
                             and .conclusion != "success" and .conclusion != "skipped")]
    | sort_by(if .conclusion == "timed_out" then 0 else 1 end, -.id)
    | .[] | "\(.id) \(.conclusion) \(.details_url)"' <<<"$json")
  while read -r id concl url; do
    [ -n "$id" ] || continue
    seen="$seen ${concl}"
    if [ "$concl" = "timed_out" ]; then proven=1; break; fi
    msgs=$(pin_gh api "repos/$REPO_ORG/$repo/check-runs/$id/annotations?per_page=100" -q '.[].message' 2>/dev/null) || {
      err "PR #$pr 必需检查失败；查询托管 job（check-run ${id}）的注解失败，无法证实超时 → 不自动重跑，停车。PR：$pr_url"; return 1; }
    if grep -qF "$PIN_TIMEOUT_TEXT" <<<"$msgs"; then proven=1; break; fi
  done <<<"$rows"
  if [ -z "$proven" ]; then
    err "PR #$pr 必需检查失败，且不是可证实的超时（${PIN_HOSTED_BUILD_PREFIX}* 未成功的 job：${seen:- 无}）→ 不自动重跑，停车。PR 留给人看：$pr_url"
    return 1
  fi
  run=$(sed -n 's#.*/actions/runs/\([0-9][0-9]*\)/job.*#\1#p' <<<"$url")
  [ -n "$run" ] || { err "PR #$pr 构建超时，但无法从 details_url 解析 CI run（${url}）→ 不自动重跑，停车"; return 1; }
  attempt=$(pin_gh api "repos/$REPO_ORG/$repo/actions/runs/$run" -q '.run_attempt' 2>/dev/null) || {
    err "PR #$pr 构建超时，但读取 CI run $run 失败 → 不自动重跑，停车"; return 1; }
  if [ "$attempt" != "1" ]; then
    err "PR #$pr 的 CI run $run 超时，但已是第 $attempt 次尝试（列车对同一 head 最多自动重跑一次）→ 停车。PR：$pr_url"
    return 1
  fi
  pin_token_alive || { pin_token_expiring "重跑 CI"; return 1; }
  pin_gh run rerun "$run" --failed --repo "$REPO_ORG/$repo" >&2 || { err "重跑 CI run $run 失败 → 停车。PR：$pr_url"; return 1; }
  log "  [pin] CI run $run 可证实超时（check-run ${id}）→ 已自动重跑失败 job（仅此一次）"
}

# 等 PR head 上两个必需检查全绿。上限 PIN_CI_POLL_MAX 轮，且不超过 App 令牌的安全期。
pin_wait_checks() {  # repo pr head
  local i st seen=""
  for ((i=0;i<=PIN_CI_POLL_MAX;i++)); do
    pin_token_alive || { pin_token_expiring "等必需检查期间"; return 1; }
    st=$(pin_checks_state "$1" "$3" "$seen")
    case "$st" in
      green) log "  [pin] PR #$2 必需检查（${PIN_REQUIRED_CHECKS[*]}）全绿"; return 0 ;;
      failed*) pin_maybe_rerun "$1" "$2" "$3" || return 1; seen="$seen ${st#failed}" ;;
    esac
    [ "$i" -lt "$PIN_CI_POLL_MAX" ] && sleep "$POLL_INTERVAL"
  done
  err "PR #$2 的必需检查未在 $((PIN_CI_POLL_MAX*POLL_INTERVAL))s 内完成；PR 留着。CI 变绿后用 fromLayer=$L 续跑即可合并：https://github.com/$REPO_ORG/$1/pull/$2"
  return 1
}

# 阶段 P（§2.1）。输出：PIN_RESULT=skipped|merged|dry-run，PIN_ACTION=skip|bump，PIN_PR，PIN_COMMIT。
pin_phase() {  # repo target
  local repo="$1" target="$2" dir="$STEP_DIR/pin-$1" base want cur sib out names tree branch
  local pr="" head="" htree="" hparent="" body tip merged
  PIN_RESULT="" PIN_ACTION="" PIN_PR="" PIN_COMMIT=""
  # 只读调用：令牌能读到仓 = App 已安装在该仓（dry-run 也做）。
  pin_gh api "repos/$REPO_ORG/$repo" -q '.full_name' >/dev/null 2>&1 || {
    err "App 令牌读不到 $REPO_ORG/${repo}（App 未安装到该仓？见 docs/runbooks/train-pin-app.md）"; return 1; }
  base=$(pin_checkout "$repo" "$dir") || return 1
  out=$(python3 "$HERE/bump-api-pin.py" --repo-root "$dir" --read) || return 1
  read -r cur sib <<<"$out"
  # 第 1 步：幂等检查。
  if [ "$cur" = "$target" ] && [ "$sib" = "$target" ]; then
    log "  [pin] $repo main 两处 pin 已是 $target → 阶段 P 跳过"
    PIN_RESULT=skipped; PIN_ACTION=skip; return 0
  fi
  if [ "$cur" = "$target" ] || [ "$sib" = "$target" ]; then
    err "$repo main 的 platform pin 半改（settings.gradle=${cur}，sibling-ref=v${sib}，目标 ${target}）。列车不猜：请人工把两处改一致后续跑。"
    return 1
  fi
  PIN_ACTION=bump
  # 第 2 步：stale gate。pin PR 的 base 必须是 preflight 验过的 SHA。
  want=$(jq -r --arg r "$repo" '.[$r] // empty' <<<"$MAIN_SHAS")
  [ -n "$want" ] || { err "pinOwner=train 需要 preflight 记录的 $repo main SHA（MAIN_SHAS），pin PR 的 base 必须是它"; return 1; }
  if [ "$base" != "$want" ]; then
    err "$repo main 已从 preflight 的 $want 前进到 ${base}（列车途中有合入）。停车：用 fromLayer=$L 续跑（preflight 会重新验新 tip）。"
    return 1
  fi
  log "  stale gate: $repo main 仍为 ${want:0:12} ✓"
  # 第 3 步：改两处 → verify-sibling-ref-pin.sh → diff 恰好两个文件。
  python3 "$HERE/bump-api-pin.py" --repo-root "$dir" --write "$target" >&2 || return 1
  ( cd "$dir" && bash scripts/ci/verify-sibling-ref-pin.sh ) >&2 || {
    err "$repo 的 verify-sibling-ref-pin.sh 未通过：改后两处 pin 不一致（#337）。停车。"; return 1; }
  names=$(git -C "$dir" diff --name-only | LC_ALL=C sort)
  if [ "$names" != "$PIN_FILES" ]; then
    err "pin 改动必须恰好是 settings.gradle 与 setup-aster-build/action.yml，实际：$(tr '\n' ' ' <<<"$names")"
    return 1
  fi
  log "  [pin] 本地生成的 diff（$cur → ${target}）："
  git -C "$dir" --no-pager diff >&2
  git -C "$dir" -c user.name="${PIN_APP_SLUG}[bot]" -c user.email="${PIN_APP_SLUG}[bot]@users.noreply.github.com" \
    commit -q -am "chore(release): 生态 pin bump $cur → ${target}（train ${TRAIN_ID}）"
  tree=$(git -C "$dir" rev-parse 'HEAD^{tree}')
  # 第 4 步：同名 open PR？（只读，dry-run 也查）
  branch="train/$repo-pin-$target"
  out=$(pin_gh api --method GET "repos/$REPO_ORG/$repo/pulls" -f head="$REPO_ORG:$branch" -f state=open -f per_page=100 \
          -q "[.[] | select(.head.ref == \"$branch\") | \"\(.number) \(.head.sha)\"] | first // empty") || {
    err "查询 $repo 的同名 PR（${branch}）失败"; return 1; }
  read -r pr head <<<"$out"
  if [ "$DRY" = "true" ]; then
    log "  [dry-run] 已有同名 open PR：${pr:+#${pr}（head ${head:0:12}）}${pr:-无}"
    log "  [dry-run] would push ${branch}（base ${base:0:12}），${pr:+复用 PR #$pr}${pr:-开 PR}，等 ${PIN_REQUIRED_CHECKS[*]}，--squash --match-head-commit 合并"
    PIN_RESULT=dry-run; return 0
  fi
  pin_token_alive || { pin_token_expiring "推 pin 分支"; return 1; }
  if [ -n "$pr" ]; then
    out=$(pin_gh api "repos/$REPO_ORG/$repo/git/commits/$head" -q '"\(.tree.sha) \(.parents[0].sha)"' 2>/dev/null || true)
    read -r htree hparent <<<"$out"
  fi
  if [ -n "$pr" ] && [ "$htree" = "$tree" ] && [ "$hparent" = "$base" ]; then
    log "  [pin] 复用 PR #${pr}：head ${head:0:12} 与本次生成的改动一致"
  else
    pin_git -C "$dir" push -q --force "$GIT_BASE/$REPO_ORG/$repo.git" "HEAD:refs/heads/$branch" >&2 || {
      err "推送 $branch 失败（App 是否有 contents: write？）"; return 1; }
    head=$(git -C "$dir" rev-parse HEAD)
    log "  [pin] 已推送 $branch → ${head:0:12}${pr:+（force-push 到已有 PR #${pr}）}"
  fi
  if [ -z "$pr" ]; then
    body="由发布列车开出（ADR 0053 修订 A1）：只改 settings.gradle 的 platform 版本与 setup-aster-build 的 sibling-ref 默认值两处，$cur → ${target}。

- trainId：$TRAIN_ID
- 列车 run：${TRAIN_RUN_URL:-（本地运行）}

列车会等必需检查（${PIN_REQUIRED_CHECKS[*]}）全绿后以 \`--squash --match-head-commit\` 合并。若决定放弃这一版，请关闭本 PR 并删除分支 \`$branch\`。"
    pr=$(pin_gh api --method POST "repos/$REPO_ORG/$repo/pulls" -f title="chore(release): 生态 pin bump $cur → ${target}（train ${TRAIN_ID}）" \
           -f head="$branch" -f base=main -f body="$body" -q '.number') || { err "开 pin PR 失败（App 是否有 pull-requests: write？）"; return 1; }
    log "  [pin] 已开 PR #$pr"
  fi
  PIN_PR="$pr"
  # 第 5–6 步：等必需检查（可证实超时自动重跑一次）。
  pin_wait_checks "$repo" "$pr" "$head" || return 1
  # 第 7 步：合并。strict 规则集要求 PR 与 main 同步；main 前进就停车，不自动 update-branch。
  pin_token_alive || { pin_token_expiring "合并 PR #$pr"; return 1; }
  if ! out=$(pin_gh pr merge "$pr" --repo "$REPO_ORG/$repo" --squash --match-head-commit "$head" 2>&1); then
    tip=$(pin_gh api "repos/$REPO_ORG/$repo/commits/main" -q '.sha' 2>/dev/null || true)
    if [ -n "$tip" ] && [ "$tip" != "$base" ]; then
      err "合并 PR #$pr 被拒：$repo main 已从 $base 前进到 ${tip}（规则集 main-protect 的 strict 要求 PR 与 main 同步）。列车不自动 update-branch（update 后要再跑约 40 分钟 CI，且新 base 未经 preflight 验证）。按 ADR 0053 修订 A1 §5 用 fromLayer=$L 续跑：阶段 P 会在新 tip 上重建 commit 并 force-push。"
    else
      err "合并 PR #$pr 失败：$(tr '\n' ' ' <<<"$out")"
    fi
    return 1
  fi
  merged=$(pin_gh api "repos/$REPO_ORG/$repo/pulls/$pr" -q 'select(.merged) | .merge_commit_sha' 2>/dev/null || true)
  [ -n "$merged" ] && [ "$merged" != "null" ] || { err "PR #$pr 合并后查不到 merge commit"; return 1; }
  # 第 8 步：列车自己推进了 main（ADR 0053 §7 登记的例外）→ 更新 MAIN_SHAS。
  MAIN_SHAS=$(jq -c --arg r "$repo" --arg s "$merged" '.[$r] = $s' <<<"$MAIN_SHAS")
  PIN_COMMIT="$merged"; PIN_RESULT=merged
  log "  [pin] PR #$pr 已合并 → $merged"
}

# 阶段 D 完成条件（§2.2）：run 已 success 的前提下，image-pin 开 PR 步骤 success 且 pin-closure-guard success。
deploy_closure_ok() {  # repo run
  local json pj ps g
  json=$(gh api "repos/$REPO_ORG/$1/actions/runs/$2/jobs?per_page=100" 2>/dev/null) || {
    err "查询 deploy run $2 的 jobs 失败（fail-closed）"; return 1; }
  pj=$(jq -r --arg j "$DEPLOY_PIN_JOB" '[.jobs[]? | select(.name==$j)] | last | .conclusion // "missing"' <<<"$json")
  ps=$(jq -r --arg j "$DEPLOY_PIN_JOB" --arg s "$DEPLOY_PIN_STEP" \
    '[.jobs[]? | select(.name==$j)] | last | [(.steps // [])[] | select(.name==$s)] | last | .conclusion // "missing"' <<<"$json")
  g=$(jq -r --arg j "$DEPLOY_GUARD_JOB" '[.jobs[]? | select(.name==$j)] | last | .conclusion // "missing"' <<<"$json")
  if [ "$pj" = "success" ] && [ "$ps" = "success" ] && [ "$g" = "success" ]; then
    log "  deploy 闭环：$DEPLOY_PIN_JOB / 开 PR 步骤 / $DEPLOY_GUARD_JOB 均 success ✓"
    return 0
  fi
  if [ "$pj" = "skipped" ] || [ "$ps" = "skipped" ]; then
    err "deploy run $2 判过时（$DEPLOY_PIN_JOB=${pj}，开 PR 步骤=${ps}）：main 在部署期间前进，更新的 commit 的 deploy run 理应接手，但列车不替它担保；请确认该 run 成功后用 fromLayer=$L 续跑。"
    return 1
  fi
  err "deploy run $2 闭环未完成：$DEPLOY_PIN_JOB=${pj}，开 PR 步骤=${ps}，$DEPLOY_GUARD_JOB=$g"
  return 1
}

# 阶段 D（P 合并了）：跟随 pin merge commit 的 push deploy run，不再 dispatch（§4）。
follow_push_deploy() {  # repo workflow merge-sha
  local repo="$1" workflow="$2" sha="$3" i ids run="" rc
  RUN_STATUS=""
  for ((i=0;i<=SERVICE_POLL_MAX;i++)); do
    if [ -z "$run" ]; then
      ids=$(gh api --method GET "repos/$REPO_ORG/$repo/actions/workflows/$workflow/runs" \
              -f event=push -f head_sha="$sha" -f per_page=100 \
              -q "[.workflow_runs[]? | select(.event == \"push\" and .head_sha == \"$sha\")] | sort_by(.created_at) | map(.id | tostring) | join(\" \")" \
              2>/dev/null || true)
      if [ -n "$ids" ]; then
        run="${ids%% *}"
        [ "$ids" = "$run" ] || log "  pin merge commit 有多个 push deploy run（${ids}）→ 取最早的 $run"
        log "  关联 pin merge commit ${sha:0:12} 的 push deploy run $run"
      elif [ "$((i+1))" -ge "$SERVICE_FALLBACK_AFTER" ]; then
        err "pin merge commit $sha 的 push deploy run 在 $((i+1)) 轮内未出现 → 停车（不回退到其它 run：没有标题可做二次确认）"
        return 1
      fi
    fi
    if [ -n "$run" ]; then
      rc=0; run_terminal "$repo" "$run" || rc=$?
      case "$rc" in
        0) SERVICE_RUN="$run"; log "  deploy run $run success"; deploy_closure_ok "$repo" "$run"; return $? ;;
        1) err "$repo/$workflow push deploy run $run ${RUN_STATUS}"; return 1 ;;
      esac
    fi
    [ "$i" -lt "$SERVICE_POLL_MAX" ] && sleep "$POLL_INTERVAL"
  done
  err "$repo/$workflow 的 push deploy run ${run:-（未出现）} 未在 $((SERVICE_POLL_MAX*POLL_INTERVAL))s 内完成（末次状态=${RUN_STATUS}）。它成功后用 fromLayer=$L 续跑收尾：https://github.com/$REPO_ORG/$repo/actions/runs/$run"
  return 1
}

# dispatch service deploy 并等 run 成功（pinOwner=human 的现行路径，pinOwner=train 的 P 跳过路径共用）。
dispatch_service_deploy() {  # repo workflow → SERVICE_RUN
  local repo="$1" workflow="$2" since
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
}

# pinOwner=train 的 service step：阶段 P → 阶段 D。
run_service_with_pin() {  # step repo workflow
  local step="$1" repo="$2" workflow="$3" target pinfo head want
  target=$(jq -r '.pinVersion // empty' <<<"$step")
  [ -n "$target" ] || { err "${repo}：pinOwner=train 但 step 缺 pinVersion（release-plan 的 expectedPlatformPin）"; return 1; }
  if [ -z "$PIN_TOKEN" ]; then
    err "${repo}：pinOwner=train 需要 GitHub App 令牌 PIN_TOKEN（App aster-train-pin，只装在 $REPO_ORG/${repo}）。请在 aster-lang-platform 配置 repo variable TRAIN_PIN_APP_CLIENT_ID 与 secret TRAIN_PIN_APP_PRIVATE_KEY（见 docs/runbooks/train-pin-app.md），或把 release-plan 的 pinOwner 改回 human。"
    return 1
  fi
  pin_phase "$repo" "$target" || return 1
  if [ "$DRY" = "true" ]; then
    if [ "$PIN_ACTION" = "skip" ]; then
      stale_gate "$repo" || return 1
      log "  [dry-run] 阶段 D：would dispatch+wait $repo/${workflow}（trainId=${TRAIN_ID}）并断言 run head_sha == preflight SHA 与部署闭环"
    else
      log "  [dry-run] 阶段 D：would follow the push deploy run of the pin merge commit（不 dispatch），并断言部署闭环"
    fi
    record_step "$step" dry-run "" "" "" "$(jq -cn --arg a "$PIN_ACTION" '{pinAction:$a}')"
    return 0
  fi
  if [ "$PIN_RESULT" = "merged" ]; then
    pinfo=$(jq -cn --arg pr "$PIN_PR" --arg c "$PIN_COMMIT" '{pin:"merged", pinPr:($pr|tonumber), pinCommit:$c}')
    # 先记下 pin 合并：阶段 D 失败时清单也要能说明 main 已被列车推进到哪个 commit。
    record_step "$step" pin-merged "" "$PIN_COMMIT" "" "$pinfo"
    follow_push_deploy "$repo" "$workflow" "$PIN_COMMIT" || return 1
    record_step "$step" deployed "" "$PIN_COMMIT" "$SERVICE_RUN" "$pinfo"
    return 0
  fi
  # P 跳过：按现状 dispatch，部署的必须是 preflight 验过、且已含 pin 的那个 commit。
  stale_gate "$repo" || return 1
  dispatch_service_deploy "$repo" "$workflow" || return 1
  want=$(jq -r --arg r "$repo" '.[$r] // empty' <<<"$MAIN_SHAS")
  head=$(gh api "repos/$REPO_ORG/$repo/actions/runs/$SERVICE_RUN" -q '.head_sha' 2>/dev/null || true)
  if [ -z "$head" ] || [ "$head" != "$want" ]; then
    err "$repo deploy run $SERVICE_RUN 的 head_sha ${head:-（查询失败）} 不等于 preflight SHA ${want}：部署的不是本次 preflight 验过的 commit。停车。"
    return 1
  fi
  deploy_closure_ok "$repo" "$SERVICE_RUN" || return 1
  record_step "$step" deployed "" "$head" "$SERVICE_RUN" '{"pin":"skipped"}'
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
    # ADR 0053 修订 A1：pinOwner=train → 先由列车 bump pin（阶段 P），再部署（阶段 D）。
    if [ "$(jq -r '.pinOwner // "human"' <<<"$step")" = "train" ]; then
      run_service_with_pin "$step" "$repo" "$workflow"; return $?
    fi
    stale_gate "$repo" || return 1
    if [ "$DRY" = "true" ]; then
      log "  [dry-run] would dispatch+wait $repo/$workflow (service deploy, trainId=$TRAIN_ID, ≤$((SERVICE_POLL_MAX*POLL_INTERVAL))s)"
      record_step "$step" dry-run "" "" ""; return 0
    fi
    dispatch_service_deploy "$repo" "$workflow" || return 1
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
LAST=$((NLAYERS-1))
[ -n "$TO" ] && [ "$TO" -lt "$LAST" ] && LAST="$TO"
if [ "$FROM" -gt "$LAST" ]; then
  log "Release train: fromLayer=$FROM > toLayer=${LAST}，本段无层可跑"
  exit 0
fi
seed_manifest
log "Release train start: $NLAYERS layers, fromLayer=$FROM, toLayer=$LAST, dryRun=$DRY, trainId=$TRAIN_ID"
for ((L=FROM; L<=LAST; L++)); do
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
