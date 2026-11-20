#!/usr/bin/env bash
# gradle-retry.sh / gradle-version.sh 的回归测试（aster-lang-platform#138）。
#
# 做法：假 gradlew——每次调用按 $PLAN 里的下一个动作行事（ok / 429 / fail / noversion / unspecified），
# 调用参数记到 $CALLS。只依赖 bash。
#
# 用法：bash .github/actions/setup-gradle-cached/setup-gradle-cached.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRY="$HERE/gradle-retry.sh"
VERSION="$HERE/gradle-version.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GRADLE_RETRY_DELAYS="0" GRADLE_RETRY_JITTER=0

# 假 gradlew：第 N 次调用执行 PLAN 的第 N 个动作（超出时沿用最后一个）。
mkgradlew() {  # dir
  mkdir -p "$1"
  cat >"$1/gradlew" <<'EOF'
#!/usr/bin/env bash
n=$(( $(wc -l <"$CALLS") + 1 ))
echo "$PWD $*" >>"$CALLS"
read -r -a plan <<<"$PLAN"
i=$(( n - 1 )); [ "$i" -lt "${#plan[@]}" ] || i=$(( ${#plan[@]} - 1 ))
case "${plan[$i]}" in
  ok)          echo "attempt $n"; echo "version: ${FAKE_VERSION:-1.0.53}"; echo "group: cloud.aster-lang" ;;
  noversion)   echo "group: cloud.aster-lang" ;;
  unspecified) echo "version: unspecified" ;;
  429)         echo "partial-stdout-$n"
               echo "> Could not GET 'https://repo.maven.apache.org/maven2/org/openjdk/jmh/jmh-core/1.37/jmh-core-1.37.pom'. Received status code 429 from server: Too Many Requests" >&2
               echo "BUILD FAILED" >&2; exit 1 ;;
  fail)        echo "> Could not resolve org.example:missing:1.0 (404)" >&2; echo "BUILD FAILED" >&2; exit 7 ;;
  testlog429)  echo "RateLimitTest > rejects burst FAILED: expected 200 but was 429 Too Many Requests"; echo "BUILD FAILED" >&2; exit 1 ;;
esac
EOF
  chmod +x "$1/gradlew"
}

newcase() {
  CASE="$1"; PLAN="$2"
  W="$TMP/w-$CASE"; rm -rf "$W"; mkgradlew "$W"
  CALLS="$W/.calls"; : >"$CALLS"
  export PLAN CALLS
}
run() {  # 在 $W 里执行，收集 rc / stdout / stderr
  set +e
  (cd "$W" && "$@") >"$TMP/out" 2>"$TMP/err"
  rc=$?
  set -e
}
calls() { wc -l <"$CALLS" | tr -d ' '; }
fail() { echo "FAIL [$CASE]: $*"; echo "--- stdout"; cat "$TMP/out"; echo "--- stderr"; cat "$TMP/err"; exit 1; }

# ---------- gradle-retry.sh ----------

newcase retry-ok-first "ok"
run bash "$RETRY" ./gradlew -q properties
[ "$rc" = 0 ] || fail "应成功，rc=$rc"
[ "$(calls)" = 1 ] || fail "应只调用 1 次，实际 $(calls)"
grep -qx 'version: 1.0.53' "$TMP/out" || fail "stdout 应原样透传"
grep -q "$W -q properties" "$CALLS" || fail "参数应原样传给命令"

newcase retry-429-then-ok "429 ok"
run bash "$RETRY" ./gradlew -q properties
[ "$rc" = 0 ] || fail "429 后重试成功应 rc=0，rc=$rc"
[ "$(calls)" = 2 ] || fail "应调用 2 次，实际 $(calls)"
grep -q 'partial-stdout' "$TMP/out" && fail "失败尝试的 stdout 不应进入 stdout"
grep -q 'partial-stdout-1' "$TMP/err" || fail "失败尝试的 stdout 应回放到 stderr"
grep -qx 'attempt 2' "$TMP/out" || fail "stdout 应是最后一次尝试的输出"
grep -q '::warning::命中 Maven 仓库限流（第 1/3 次尝试' "$TMP/err" || fail "应告警限流重试"

newcase retry-429-exhausted "429"
run bash "$RETRY" ./gradlew publishToMavenLocal
[ "$rc" = 1 ] || fail "次数用尽应返回最后一次的退出码 1，rc=$rc"
[ "$(calls)" = 3 ] || fail "缺省应共尝试 3 次，实际 $(calls)"
grep -q 'Too Many Requests' "$TMP/err" || fail "最后一次的 stderr 应保留"

newcase retry-non-429 "fail ok"
run bash "$RETRY" ./gradlew publishToMavenLocal
[ "$rc" = 7 ] || fail "非限流失败应立即原样返回退出码 7，rc=$rc"
[ "$(calls)" = 1 ] || fail "非限流失败不应重试，实际 $(calls) 次"
grep -q "missing:1.0 (404)" "$TMP/err" || fail "非限流失败的 stderr 应原样保留"

# 测试日志里的 429 / Too Many Requests 不是仓库限流：真失败不得重跑。
newcase retry-test-log-429 "testlog429 ok"
run bash "$RETRY" ./gradlew :test
[ "$rc" = 1 ] || fail "测试失败（日志含 429 字样）应立即返回，rc=$rc"
[ "$(calls)" = 1 ] || fail "测试日志里的 429 不应触发重试，实际 $(calls) 次"

newcase retry-attempts-env "429 429 429 ok"
GRADLE_RETRY_ATTEMPTS=4 run bash "$RETRY" ./gradlew build
[ "$rc" = 0 ] || fail "ATTEMPTS=4 时第 4 次成功应 rc=0，rc=$rc"
[ "$(calls)" = 4 ] || fail "应调用 4 次，实际 $(calls)"

newcase retry-empty-delays "429 ok"
GRADLE_RETRY_DELAYS="" run bash "$RETRY" ./gradlew build
[ "$rc" = 0 ] || fail "DELAYS 为空时应按 0 秒重试，rc=$rc"

newcase retry-no-args "ok"
run bash "$RETRY"
[ "$rc" = 2 ] || fail "没有命令应退出 2，rc=$rc"

# ---------- gradle-version.sh ----------

newcase version-ok "ok"
run bash "$VERSION"
[ "$rc" = 0 ] || fail "应成功，rc=$rc"
[ "$(cat "$TMP/out")" = "1.0.53" ] || fail "stdout 应恰好是版本号"
grep -q "$W -q properties" "$CALLS" || fail "缺省应在当前目录跑 -q properties"

newcase version-dir-task "ok"
mkgradlew "$W/packages/jvm"
run bash "$VERSION" packages/jvm :en:properties
[ "$rc" = 0 ] && [ "$(cat "$TMP/out")" = "1.0.53" ] || fail "指定目录与任务应成功，rc=$rc"
grep -q "$W/packages/jvm -q :en:properties" "$CALLS" || fail "应在指定目录跑指定任务"

newcase version-429-then-ok "429 ok"
run bash "$VERSION"
[ "$rc" = 0 ] && [ "$(cat "$TMP/out")" = "1.0.53" ] || fail "限流后重试成功应得到版本，rc=$rc"

newcase version-gradle-fails "429"
run bash "$VERSION"
[ "$rc" = 1 ] || fail "Gradle 失败应退出 1，rc=$rc"
[ ! -s "$TMP/out" ] || fail "失败时 stdout 应为空"
grep -q "::error::Gradle 'properties'（目录 .）执行失败" "$TMP/err" || fail "应明确指出是 Gradle 失败"
grep -q 'Too Many Requests' "$TMP/err" || fail "应保留 Gradle 原始报错"

newcase version-no-line "noversion"
run bash "$VERSION"
[ "$rc" = 1 ] || fail "没有 version 行应退出 1，rc=$rc"
grep -q '没有输出有效的 version' "$TMP/err" || fail "应说明没有 version"

newcase version-unspecified "unspecified"
run bash "$VERSION"
[ "$rc" = 1 ] || fail "version=unspecified 应退出 1，rc=$rc"

# 调用方写法（release.yml 的 create-tag 步骤，GitHub 缺省 shell 是 bash -e）：Gradle 失败时整步在赋值处终止，
# 走不到「dispatch version != 解析版本 ()」那句误报。
newcase caller-bash-e "fail"
cat >"$W/step.sh" <<EOF
VERSION=1.0.53
RESOLVED=\$(bash "$VERSION")
if [ "\$VERSION" != "\$RESOLVED" ]; then
  echo "::error::dispatch version (\$VERSION) != Gradle-resolved catalog version (\$RESOLVED)"; exit 1
fi
echo reached-tag-creation
EOF
run bash -e step.sh
[ "$rc" != 0 ] || fail "Gradle 失败时步骤应失败"
grep -q 'Gradle-resolved catalog version ()' "$TMP/out" "$TMP/err" && fail "不应再出现空版本误报"
grep -q 'reached-tag-creation' "$TMP/out" && fail "不应走到建 tag"
grep -q '执行失败' "$TMP/err" || fail "应报 Gradle 执行失败"

echo "setup-gradle-cached: all cases passed"
