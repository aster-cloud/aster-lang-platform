#!/usr/bin/env bash
# verify-jar-contents.sh 的回归测试（ADR 0053 修订 A2）。用 python3 zipfile 造 jar，只依赖 bash + python3 + unzip。
# 用法：bash .github/actions/verify-jar-contents/verify-jar-contents.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V="$HERE/verify-jar-contents.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkjar() {  # path entry...
  local p="$1"; shift
  mkdir -p "$(dirname "$p")"
  python3 - "$p" "$@" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for e in sys.argv[2:]:
        z.writestr(e, "" if e.endswith("/") else "x")
PY
}
run() {  # globs entries version
  set +e
  (cd "$TMP/w" && JAR_GLOBS="$1" JAR_ENTRIES="$2" JAR_VERSION="${3:-}" bash "$V") >"$TMP/out" 2>&1
  rc=$?
  set -e
}
fail() { echo "FAIL [$CASE]: $*"; cat "$TMP/out"; exit 1; }
newcase() { CASE="$1"; rm -rf "$TMP/w"; mkdir -p "$TMP/w"; }

SPI=$'^META-INF/services/\n^aster/lang/.*\\.class$'

newcase pass
mkjar "$TMP/w/en/build/libs/x-en-1.0.49.jar" META-INF/services/aster.Spi aster/lang/En.class
mkjar "$TMP/w/en/build/libs/x-en-1.0.49-sources.jar" aster/lang/En.java
mkjar "$TMP/w/zh/build/libs/x-zh-1.0.49.jar" META-INF/services/aster.Spi aster/lang/Zh.class
run $'en/build/libs/*.jar\nzh/build/libs/*.jar' "$SPI" 1.0.49
[ "$rc" = 0 ] || fail "应通过，rc=$rc"
grep -q '2 个 jar 通过' "$TMP/out" || fail "应检查 2 个主 jar（忽略 -sources）"

newcase missing-entry
mkjar "$TMP/w/build/libs/x-1.0.49.jar" aster/lang/En.class
run 'build/libs/*.jar' "$SPI" 1.0.49
[ "$rc" = 1 ] || fail "缺 META-INF/services 应失败"; grep -q 'META-INF/services' "$TMP/out" || fail "应指出缺失模式"

newcase no-jar
mkdir -p "$TMP/w/build/libs"
mkjar "$TMP/w/build/libs/x-1.0.49-javadoc.jar" index.html
run 'build/libs/*.jar' '\.class$'
[ "$rc" = 1 ] || fail "只有 javadoc jar 应失败"; grep -q '没有匹配到任何主 jar' "$TMP/out" || fail "应说明没有主 jar"

newcase wrong-version
mkjar "$TMP/w/build/libs/x-1.0.48.jar" a/B.class
run 'build/libs/*.jar' '\.class$' 1.0.49
[ "$rc" = 1 ] || fail "版本不符应失败"; grep -q '与版本 1.0.49 不符' "$TMP/out" || fail "应说明版本不符"

newcase one-of-two-bad
mkjar "$TMP/w/a/build/libs/a-1.0.49.jar" a/B.class
mkjar "$TMP/w/b/build/libs/b-1.0.49.jar" README
run $'a/build/libs/*.jar\nb/build/libs/*.jar' '\.class$' 1.0.49
[ "$rc" = 1 ] || fail "任一 jar 不合格即失败"

newcase empty-inputs
run '' '\.class$'; [ "$rc" = 1 ] || fail "空 JAR_GLOBS 应失败"
run 'x/*.jar' ''; [ "$rc" = 1 ] || fail "空 JAR_ENTRIES 应失败"

echo "verify-jar-contents.test.sh: all cases passed"
