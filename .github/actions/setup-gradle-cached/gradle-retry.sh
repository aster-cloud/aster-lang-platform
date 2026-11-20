#!/usr/bin/env bash
# 执行一条 Gradle 命令；失败且 Gradle 报告仓库限流（HTTP 429）时退避重试（aster-lang-platform#138）。
#
# 用法：gradle-retry.sh <命令> [参数…]        例：gradle-retry.sh ./gradlew publishToMavenLocal
#
# 语义：
#   - 每次尝试的 stdout / stderr 先落盘，结束后再回放：stdout 只回放**最后一次**尝试的（调用方可以安全地
#     `X=$(gradle-retry.sh ./gradlew -q properties)` 取输出，不会混进失败尝试的残留）；失败尝试的 stdout
#     回放到 stderr，留在日志里供排查。
#   - 只有「失败 + 输出命中限流模式」才重试；其它失败（编译错误、配置错误、404）立即原样返回退出码，
#     不把真问题拖成几分钟的空等。
#   - 退出码等于最后一次尝试的退出码。
#
# 环境变量（测试与特殊调用方用，缺省即可）：
#   GRADLE_RETRY_ATTEMPTS  总尝试次数，缺省 3
#   GRADLE_RETRY_DELAYS    各次重试前的基础等待秒数（空格分隔，不够长时沿用最后一个），缺省 "30 90"
#   GRADLE_RETRY_JITTER    每次等待额外加 0..N 秒随机抖动，缺省 15（同层并行的多个仓不要同时重试）
#   GRADLE_RETRY_PATTERN   判定限流的 ERE，缺省 'Received status code 429'——Gradle 仓库访问失败的原话
#                          （「Could not GET '…'. Received status code 429 from server: Too Many Requests」）。
#                          不用宽泛的「Too Many Requests」：被包住的若是测试任务，测试日志里本来就可能出现 429 字样，
#                          真失败不能被当成限流重跑。
set -uo pipefail

[ $# -gt 0 ] || { echo "::error::gradle-retry.sh: 缺少要执行的命令" >&2; exit 2; }

attempts="${GRADLE_RETRY_ATTEMPTS:-3}"
read -r -a delays <<<"${GRADLE_RETRY_DELAYS:-30 90}"
[ "${#delays[@]}" -gt 0 ] || delays=(0)
jitter="${GRADLE_RETRY_JITTER:-15}"
pattern="${GRADLE_RETRY_PATTERN:-Received status code 429}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

n=1
while :; do
  "$@" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  if [ "$rc" = 0 ] || [ "$n" -ge "$attempts" ] || ! grep -qE "$pattern" "$tmp/out" "$tmp/err"; then
    cat "$tmp/out"
    cat "$tmp/err" >&2
    exit "$rc"
  fi
  i=$((n - 1)); [ "$i" -lt "${#delays[@]}" ] || i=$((${#delays[@]} - 1))
  wait_s=$(( ${delays[$i]} + (jitter > 0 ? RANDOM % (jitter + 1) : 0) ))
  cat "$tmp/out" >&2
  cat "$tmp/err" >&2
  echo "::warning::命中 Maven 仓库限流（第 ${n}/${attempts} 次尝试，退出码 ${rc}），${wait_s}s 后重试：$*" >&2
  sleep "$wait_s"
  n=$((n + 1))
done
