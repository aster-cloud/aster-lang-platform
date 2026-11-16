#!/usr/bin/env bash
# ADR 0053 修订 A2：列车 preflight 的「main CI 已通过」检查（被 release-train.yml 调用）。
#
# 各仓发布 run 不再重跑测试，而是要求 main CI 对要发布的 commit 已通过（共享门禁
# .github/actions/require-main-ci-green）。发布 run 里的门禁是最终防线；这里在**开车前**对所有
# 参与仓统一查一遍，任何一仓不绿就停在 L0 之前，一个制品都不发。
#
# 为什么 preflight 要自动重跑一次：生态 lockstep 的 pin PR 是逐仓依次合并的，先合的仓（core、test）
# 的 main CI 会拿后合仓的旧 main 构建而红——eco-1.0.47 / 1.0.48 的 core 与 test 都是「找不到
# aster-lang-platform:<旧版本>」。开车时各仓 main 都已就位，重跑失败的 job 即可变绿；真问题会再红一次。
# 重跑次数记在 GitHub（只重跑 run_attempt==1 的 run），续跑不会重复重跑。dryRun 只读，不重跑。
#
# 输入（env）：
#   LAYERS      coalesce 后的层（JSON）
#   MAIN_SHAS   preflight 验过的各仓 main SHA（JSON：repo→sha）
#   CLONE_ROOT  drift gate 克隆各仓 main 的根目录（缺省 /tmp）；门禁配置读 <root>/<repo>/.github/main-ci-gate.json
#   DRY_RUN     true 时不重跑
#   FORCE_TESTS true 时整体跳过（各仓发布 run 会跑完整测试）
#   GH_TOKEN    owner=aster-cloud 的令牌（CROSS_REPO_TOKEN，需 Actions 读写）
#   WONTLOST_TOKEN  owner=wontlost-ltd 的令牌
#   GATE_*      透传给门禁脚本（测试用短轮询）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${GATE_SCRIPT:-$HERE/../../.github/actions/require-main-ci-green/require-main-ci-green.sh}"
CLONE_ROOT="${CLONE_ROOT:-/tmp}"
DRY="${DRY_RUN:-true}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
MAIN_SHAS="${MAIN_SHAS:-}"
[ -n "$MAIN_SHAS" ] || MAIN_SHAS='{}'

echo '### main CI 门禁（ADR 0053 修订 A2）' >>"$SUMMARY"
if [ "${FORCE_TESTS:-false}" = "true" ]; then
  echo "::warning::forceTests=true：preflight 不查 main CI，各仓发布 run 将跑完整测试"
  echo '- ⚠️ forceTests=true：跳过，各仓发布 run 跑完整测试' >>"$SUMMARY"
  exit 0
fi

# 有发布 step 的仓（service 没有发布 run，aster-api 由 L4 pin PR 的必需检查与 deploy 把关）。
ROWS=$(jq -r '[.[][] | select((.kinds // []) | any(. == "service") | not)
              | "\(.org // "aster-cloud") \(.repo)"] | unique | .[]' <<<"$LAYERS") \
  || { echo "::error::LAYERS 不是合法 JSON（fail-closed）"; exit 1; }

LOGDIR="$(mktemp -d)"
trap 'rm -rf "$LOGDIR"' EXIT
PIDS=() NAMES=() fail=0
while read -r org repo; do
  [ -n "$repo" ] || continue
  sha=$(jq -r --arg r "$repo" '.[$r] // empty' <<<"$MAIN_SHAS")
  if [ -z "$sha" ]; then
    echo "::error::[$repo] MAIN_SHAS 里没有它的 preflight SHA，无法查 main CI（fail-closed）"
    fail=1; continue
  fi
  cfg="$CLONE_ROOT/$repo/.github/main-ci-gate.json"
  if [ ! -f "$cfg" ]; then
    # 过渡期：该仓的 release workflow 还没改用门禁，发布 run 仍自己跑测试，这里不拦。
    echo "::notice::[$repo] 没有 .github/main-ci-gate.json，发布 run 仍自己跑测试（修订 A2 过渡期），preflight 不查"
    echo "- ℹ️ \`$org/$repo\`：未接入门禁，发布 run 自己跑测试" >>"$SUMMARY"
    continue
  fi
  tok="$GH_TOKEN"
  [ "$org" != "wontlost-ltd" ] || tok="${WONTLOST_TOKEN:-}"
  rerun=true
  [ "$DRY" != "true" ] || rerun=false
  ( GH_TOKEN="$tok" GATE_REPO="$org/$repo" GATE_SHA="$sha" GATE_CONFIG="$cfg" GATE_RERUN_ONCE="$rerun" \
      GITHUB_OUTPUT=/dev/null bash "$GATE" ) >"$LOGDIR/$repo.log" 2>&1 &
  PIDS+=("$!"); NAMES+=("$repo")
done <<<"$ROWS"

# 各仓并行查（等待上限各自有界），全部收尾后再汇总，日志按仓分段输出。
for ((i=0; i<${#NAMES[@]}; i++)); do
  if wait "${PIDS[$i]}"; then r=0; else r=1; fi
  echo "::group::main CI 门禁 ${NAMES[$i]}"
  cat "$LOGDIR/${NAMES[$i]}.log"
  echo "::endgroup::"
  # ::error:: 注解在 group 里会被折叠，失败时在组外再报一次。
  if [ "$r" -ne 0 ]; then
    grep '^::error::' "$LOGDIR/${NAMES[$i]}.log" || echo "::error::[${NAMES[$i]}] main CI 门禁未通过"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "::error::preflight main CI 门禁未通过：上面列出的仓的 main CI 对要发布的 commit 不绿。修好并让 CI 变绿后重开列车（未发布任何制品）；确需绕过时用 forceTests=true（各仓发布 run 跑完整测试）。"
  exit 1
fi
echo "preflight main CI 门禁：全部通过 ✅"
