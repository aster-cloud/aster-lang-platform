#!/usr/bin/env bash
# 发布制品冒烟（ADR 0053 修订 A2）：发布 run 不再跑测试后，用几秒钟确认「要发布的 jar 本身」没坏。
# 测试跑的是 class 目录，从来不看 jar；这里补上的是 jar 级别的检查：
#   - 每个 glob 至少匹配到一个主 jar（忽略 -sources / -javadoc / -plain / -test-fixtures 等附属 jar：
#     java-test-fixtures 插件产出的 -test-fixtures.jar 是测试夹具，不含主 jar 的必需条目，也不按主 jar 校验）；
#   - 给了 JAR_VERSION 时，主 jar 文件名必须以 -<version>.jar 结尾（与 tag 版本一致）；
#   - 每个主 jar 对 JAR_ENTRIES 中的每条 ERE 至少有一个条目匹配（如 SPI 的 META-INF/services/）。
#
# 输入（env）：JAR_GLOBS（换行分隔，相对当前目录）、JAR_ENTRIES（换行分隔 ERE）、JAR_VERSION（可空）
# 退出码：0 通过，1 不通过。
set -euo pipefail

GLOBS="${JAR_GLOBS:-}"
ENTRIES="${JAR_ENTRIES:-}"
# 允许直接传 tag（vX）：去掉开头的一个 v。
VERSION="${JAR_VERSION:-}"
VERSION="${VERSION#v}"
nonblank() { [ -n "$(tr -d '[:space:]' <<<"$1")" ]; }
die() { echo "::error::[verify-jar-contents] $*" >&2; exit 1; }

nonblank "$GLOBS" || die "JAR_GLOBS 为空"
nonblank "$ENTRIES" || die "JAR_ENTRIES 为空（不检查任何条目等于没有冒烟）"
command -v unzip >/dev/null || die "缺少 unzip"

# 一个 jar 是否满足全部条目要求；不满足时输出缺失的模式。
missing_entries() {  # jar
  local listing pat
  listing=$(unzip -Z1 "$1") || { echo "<无法读取>"; return 0; }
  while IFS= read -r pat; do
    nonblank "$pat" || continue
    grep -Eq -- "$pat" <<<"$listing" || echo "$pat"
  done <<<"$ENTRIES"
}

fail=0 checked=0
while IFS= read -r glob; do
  nonblank "$glob" || continue
  found=0
  # glob 由调用方给定、相对当前目录；不加引号让 shell 展开，未匹配时保持原样被下面的 -f 过滤掉。
  for jar in $glob; do
    [ -f "$jar" ] || continue
    case "$jar" in *-sources.jar|*-javadoc.jar|*-plain.jar|*-test-fixtures.jar) continue ;; esac
    found=1 checked=$((checked+1))
    if [ -n "$VERSION" ] && [[ "$jar" != *"-$VERSION.jar" ]]; then
      echo "::error::[verify-jar-contents] $jar 的文件名与版本 $VERSION 不符" >&2; fail=1; continue
    fi
    miss=$(missing_entries "$jar")
    if [ -n "$miss" ]; then
      echo "::error::[verify-jar-contents] $jar 缺少匹配以下模式的条目：$(tr '\n' ' ' <<<"$miss")" >&2; fail=1
    else
      echo "[verify-jar-contents] $jar ✓（$(unzip -Z1 "$jar" | wc -l | tr -d ' ') 个条目）"
    fi
  done
  [ "$found" = 1 ] || { echo "::error::[verify-jar-contents] '$glob' 没有匹配到任何主 jar" >&2; fail=1; }
done <<<"$GLOBS"

[ "$fail" = 0 ] || exit 1
echo "[verify-jar-contents] $checked 个 jar 通过"
