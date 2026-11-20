#!/usr/bin/env bash
# 读出 Gradle 解析到的 project version（catalog 派生，ADR 0023 §9）；读不到就明确失败（aster-lang-platform#138）。
#
# 用法：gradle-version.sh [项目目录（缺省 .）] [properties 任务（缺省 properties，locales 用 :en:properties）]
#       成功时 stdout 恰好一行版本号，退出 0。
#
# 为什么需要：发布 workflow 原来写 `RESOLVED=$(./gradlew -q properties | sed … | head -n1)`。管道的退出码是 head 的，
# Gradle 失败（例如 Maven Central 429）被吞掉，RESOLVED 为空，日志只剩一句「dispatch version (1.0.52) !=
# Gradle-resolved catalog version ()」，看起来像版本不一致（eco-1.0.52，aster-lang-core run 44616501131）。
# 现在：Gradle 失败 → 退出 1 并指明是 Gradle 失败；成功但没有 version 行或为 unspecified → 退出 1 并说明。
# Gradle 命令经 gradle-retry.sh 执行，限流时先退避重试。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="${1:-.}"
task="${2:-properties}"

if ! out="$(cd "$dir" && bash "$HERE/gradle-retry.sh" ./gradlew -q "$task")"; then
  echo "::error::Gradle '${task}'（目录 ${dir}）执行失败，无法解析 project version——见上方 Gradle 输出（不是版本不一致）" >&2
  exit 1
fi

version="$(printf '%s\n' "$out" | sed -n 's/^version: //p' | head -n1)"
if [ -z "$version" ] || [ "$version" = "unspecified" ]; then
  echo "::error::Gradle '${task}'（目录 ${dir}）成功，但没有输出有效的 version（得到 '${version}'）" >&2
  exit 1
fi
echo "$version"
