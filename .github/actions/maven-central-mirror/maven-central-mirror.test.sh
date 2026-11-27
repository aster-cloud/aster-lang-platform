#!/usr/bin/env bash
# maven-central-mirror（install.sh + init 脚本）的回归测试。
#
# 用本仓的 Gradle Wrapper 跑临时夹具构建（Groovy DSL，不解析任何远端依赖），断言：
#   1. 仓库顺序：镜像紧插在第一个 Central / Plugin Portal 之前，mavenLocal / GitHub Packages 等前置仓库顺序不变；
#      覆盖 settings 的 pluginManagement（隐式缺省与显式声明）、dependencyResolutionManagement、项目 buildscript /
#      repositories，以及 includeBuild 的构建；没声明 Central 的容器不被插入；ASTER_MAVEN_CENTRAL_MIRROR 可覆盖地址。
#   2. install.sh：写入 init.d 与重试参数，重复执行幂等，不覆盖调用方已有的同名键。
#   3. 重试参数真的被这版 Gradle 读取：本地假仓库对每个请求回 429，镜像应恰好被请求 max.tentatives 次
#      （Gradle 升级后内部属性改名时这里会失败）。
#
# 依赖：bash、python3、本仓 ./gradlew（复用 ~/.gradle/wrapper 里的发行版，不重新下载）。
# 用法：bash .github/actions/maven-central-mirror/maven-central-mirror.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL [$CASE]: $*"; [ ! -f "$TMP/out" ] || { echo "--- output"; cat "$TMP/out"; }; exit 1; }

# 临时 Gradle 用户目录：只共享 wrapper 发行版，init.d / gradle.properties / caches 都是干净的。
GUH="$TMP/gradle-home"
mkdir -p "$GUH"
mkdir -p "${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper"
ln -s "${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper" "$GUH/wrapper"

gradle() {  # 在夹具目录跑 Gradle，输出进 $TMP/out
  local dir="$1"; shift
  set +e
  (cd "$ROOT" && GRADLE_USER_HOME="$GUH" ./gradlew -p "$dir" --no-daemon -q "$@") >"$TMP/out" 2>&1
  rc=$?
  set -e
}
expect_line() {  # 期望 $TMP/out 里有这一整行
  grep -qxF "$1" "$TMP/out" || fail "缺少输出行：$1"
}

# ---------- 2. install.sh ----------
CASE=install
printf 'org.gradle.jvmargs=-Xmx1g\nsystemProp.org.gradle.internal.repository.initial.backoff=10' >"$GUH/gradle.properties"   # 末尾无换行
GRADLE_USER_HOME="$GUH" bash "$HERE/install.sh" >/dev/null
GRADLE_USER_HOME="$GUH" bash "$HERE/install.sh" >/dev/null
cmp -s "$HERE/maven-central-mirror.init.gradle" "$GUH/init.d/aster-maven-central-mirror.init.gradle" || fail "init 脚本未装入 init.d"
[ "$(grep -c '^systemProp.org.gradle.internal.repository.max.tentatives=6$' "$GUH/gradle.properties")" = 1 ] \
  || fail "max.tentatives 应恰好写入一次：$(cat "$GUH/gradle.properties")"
[ "$(grep -c '^systemProp.org.gradle.internal.repository.initial.backoff=' "$GUH/gradle.properties")" = 1 ] \
  || fail "已有的 initial.backoff 不应被重复写入"
grep -qx 'systemProp.org.gradle.internal.repository.initial.backoff=10' "$GUH/gradle.properties" || fail "已有的 initial.backoff 不应被覆盖"
grep -qx 'org.gradle.jvmargs=-Xmx1g' "$GUH/gradle.properties" || fail "无换行结尾的最后一行不应与新行粘连"

# ---------- 1. 仓库顺序 ----------
CASE=order
FX="$TMP/fx"
mkdir -p "$FX/inc" "$FX/norepo"
cat >"$FX/settings.gradle" <<'EOF'
rootProject.name = 'fx'
dependencyResolutionManagement { repositories { mavenLocal(); mavenCentral() } }
includeBuild('inc')
include('norepo')
gradle.settingsEvaluated { s ->
  println "fx.pluginManagement=" + s.pluginManagement.repositories*.name
  println "fx.drm=" + s.dependencyResolutionManagement.repositories*.name
  println "fx.mirrorUrl=" + s.dependencyResolutionManagement.repositories.findByName('MavenCentralMirror')?.url
}
EOF
cat >"$FX/build.gradle" <<'EOF'
buildscript { repositories { mavenCentral() } }
println "fx.buildscript=" + buildscript.repositories*.name
EOF
cat >"$FX/norepo/build.gradle" <<'EOF'
repositories { mavenLocal() }
println "norepo.project=" + repositories*.name
EOF
cat >"$FX/inc/settings.gradle" <<'EOF'
pluginManagement { repositories { mavenLocal(); gradlePluginPortal(); mavenCentral() } }
rootProject.name = 'inc'
gradle.settingsEvaluated { s -> println "inc.pluginManagement=" + s.pluginManagement.repositories*.name }
EOF
cat >"$FX/inc/build.gradle" <<'EOF'
repositories {
  mavenLocal()
  maven { name = 'GitHubPackages'; url = 'https://maven.pkg.github.com/aster-cloud/x' }
  mavenCentral()
  maven { name = 'Repo1'; url = 'https://repo1.maven.org/maven2/' }
}
println "inc.project=" + repositories*.name
EOF
ASTER_MAVEN_CENTRAL_MIRROR="https://mirror.example.test/maven2/" gradle "$FX" help
[ "$rc" = 0 ] || fail "夹具构建失败 rc=$rc"
expect_line "fx.pluginManagement=[MavenCentralMirror, Gradle Central Plugin Repository]"
expect_line "fx.drm=[MavenLocal, MavenCentralMirror, MavenRepo]"
expect_line "fx.mirrorUrl=https://mirror.example.test/maven2/"
expect_line "fx.buildscript=[MavenCentralMirror, MavenRepo]"
expect_line "norepo.project=[MavenLocal]"
expect_line "inc.pluginManagement=[MavenLocal, MavenCentralMirror, Gradle Central Plugin Repository, MavenRepo]"
expect_line "inc.project=[MavenLocal, GitHubPackages, MavenCentralMirror, MavenRepo, Repo1]"

CASE=default-url
gradle "$FX" help
[ "$rc" = 0 ] || fail "夹具构建失败 rc=$rc"
expect_line "fx.mirrorUrl=https://maven-central.storage-download.googleapis.com/maven2/"

# ---------- 3. 重试参数生效 ----------
CASE=retry
cat >"$TMP/server.py" <<'EOF'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(sys.argv[2], 'a') as f: f.write(self.path + '\n')
        self.send_response(429); self.end_headers()
    do_HEAD = do_GET
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(s.server_address[1]))
s.serve_forever()
EOF
python3 -I "$TMP/server.py" "$TMP/port" "$TMP/requests" &
SERVER_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || fail "假仓库未启动"
RX="$TMP/rx"
mkdir -p "$RX"
echo "rootProject.name = 'rx'" >"$RX/settings.gradle"
cat >"$RX/build.gradle" <<'EOF'
repositories { mavenCentral() }
configurations { probe }
dependencies { probe 'org.example:missing:1.0' }
tasks.register('probe') { def c = configurations.probe; doLast { c.files } }
EOF
: >"$TMP/requests"
ASTER_MAVEN_CENTRAL_MIRROR="http://127.0.0.1:$(cat "$TMP/port")/maven2/" gradle "$RX" probe
[ "$rc" != 0 ] || fail "镜像持续 429 时构建应失败"
grep -q 'Received status code 429' "$TMP/out" || fail "应报 429"
n="$(grep -c 'org/example/missing/1.0/missing-1.0.pom' "$TMP/requests" || true)"
[ "$n" = 6 ] || fail "镜像应被请求 6 次（max.tentatives=6），实际 $n 次"

echo "maven-central-mirror: all cases passed"
