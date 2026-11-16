#!/usr/bin/env bash
# java-gate.sh 的本地回归测试。不连集群、不需要真实引擎：test/stub-engine 是一套最小的 aster-api / core 测试桩
# （InProcessCnlParser / TypeChecker / CoreIrJson / LexiconRegistry），按源码里的指令返回结果，并故意把源码
# 打到 stdout / stderr / JUL 日志，用来验证门禁不泄露源码。语言包与真实 core 一样经 TCCL 上的 SPI 发现，
# 每个语言包一个 jar，所以能复现「缺 zh 语言包 / 没设 TCCL」的失败模式。
#
# Worker 依赖 Jackson：按固定版本与 SHA-256 从 Maven Central 下载（JAVA_GATE_JACKSON_DIR 可指向已下载的目录）。
# 可选端到端（真实引擎 classpath，用 java-gate.sh classpath 构建）：
#   JAVA_GATE_OLD_CP=<文件> JAVA_GATE_NEW_CP=<文件> JAVA_GATE_CORPUS=<aster-lang-test 根> bash java-gate.test.sh
# 需要：bash、JDK 25（JAVA_HOME 或 macOS java_home）、curl、node 24（corpus-to-jsonl / regex-scan 用例）、perl。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/java-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CASE=""

fail() {
  echo "FAIL [$CASE]: $*"
  for f in "$TMP/out" "$TMP/err"; do [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; }; done
  exit 1
}

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then JH="$JAVA_HOME"
elif [ -x /usr/libexec/java_home ]; then JH="$(/usr/libexec/java_home -v 25)"
else JH="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"; fi
export JAVA_HOME="$JH"

# ---------- Jackson（Worker 的依赖） ----------
JACKSON_VERSION=2.18.2
JK="${JAVA_GATE_JACKSON_DIR:-$TMP/jackson}"
mkdir -p "$JK"
while read -r group artifact sha; do
  jar="$JK/$artifact-$JACKSON_VERSION.jar"
  [ -f "$jar" ] || curl -fsSL -o "$jar" \
    "https://repo1.maven.org/maven2/com/fasterxml/jackson/$group/$artifact/$JACKSON_VERSION/$artifact-$JACKSON_VERSION.jar"
  got="$(shasum -a 256 "$jar" 2>/dev/null || sha256sum "$jar")"
  [ "${got%% *}" = "$sha" ] || { echo "Jackson 校验失败：$jar"; exit 1; }
done <<'EOF'
core jackson-core d8054ae7c0d1c2d2f55d28e46026ebe5892881f3fab5f439233184381c3b4a1f
core jackson-databind 4b364e6850dc89172fcf1d4dd26b8ff5488eda44ff4657e22dd265203dd5ab3c
core jackson-annotations 581bd61000ef7648943f781ca05689e56d03f6052748365a8e2b3a9b5d3fa32f
EOF
JACKSON_CP="$JK/jackson-core-$JACKSON_VERSION.jar:$JK/jackson-databind-$JACKSON_VERSION.jar:$JK/jackson-annotations-$JACKSON_VERSION.jar"

# ---------- 桩引擎：old / new 两个 jar（只差 stub-build.txt），每个语言包一个 jar ----------
STUB_SRC=()
while IFS= read -r f; do STUB_SRC+=("$f"); done < <(find "$HERE/test/stub-engine" -name '*.java')
"$JH/bin/javac" -encoding UTF-8 -d "$TMP/stub-classes" "${STUB_SRC[@]}"
for build in old new; do
  mkdir -p "$TMP/res-$build"
  echo "$build" >"$TMP/res-$build/stub-build.txt"
  "$JH/bin/jar" --create --file "$TMP/engine-$build.jar" -C "$TMP/stub-classes" . -C "$TMP/res-$build" stub-build.txt
done
for lex in zh-CN de-DE hi-IN; do
  cls="Lex${lex%%-*}"
  d="$TMP/lexsrc-$lex"
  mkdir -p "$d/stub/lex" "$d/META-INF/services"
  printf 'package stub.lex;\npublic final class %s implements aster.core.lexicon.LexiconPack {\n  public String id() { return "%s"; }\n}\n' \
    "$cls" "$lex" >"$d/stub/lex/$cls.java"
  echo "stub.lex.$cls" >"$d/META-INF/services/aster.core.lexicon.LexiconPack"
  "$JH/bin/javac" -d "$d" -cp "$TMP/stub-classes" "$d/stub/lex/$cls.java"
  "$JH/bin/jar" --create --file "$TMP/lex-$lex.jar" -C "$d" stub -C "$d" META-INF
done
mkcp() {  # 输出文件 build 语言包…
  local out="$1" build="$2"; shift 2
  local cp="$TMP/engine-$build.jar:$JACKSON_CP" lex
  for lex in "$@"; do cp="$cp:$TMP/lex-$lex.jar"; done
  printf '%s' "$cp" >"$out"
}
mkcp "$TMP/old.cp" old zh-CN de-DE hi-IN
mkcp "$TMP/new.cp" new zh-CN de-DE hi-IN
mkcp "$TMP/new-nozh.cp" new de-DE hi-IN
printf '%s' "$TMP/engine-old.jar:$TMP/lex-zh-CN.jar:$TMP/lex-de-DE.jar:$TMP/lex-hi-IN.jar" >"$TMP/old-nojackson.cp"

# ---------- 合成导出 ----------
# jsonl 输出文件 [--count N] id=指令 …（kind 由 id 前缀推断，content 带 SECRET_TEXT_ 标记）
jsonl() {
  local out="$1"; shift
  local count="" lines=() spec id directive kind
  if [ "${1:-}" = --count ]; then count="$2"; shift 2; fi
  for spec in "$@"; do
    id="${spec%%=*}"; directive="${spec#*=}"
    case "${id%%:*}" in api) kind=api-policy-version ;; cloudv) kind=cloud-policy-version ;; *) kind=cloud-policy ;; esac
    lines+=("{\"id\":\"$id\",\"kind\":\"$kind\",\"content\":\"Module m.SECRET_TEXT_${id//:/_}. $directive\"}")
  done
  { [ ${#lines[@]} -eq 0 ] || printf '%s\n' "${lines[@]}"; echo "{\"_count\" : ${count:-${#lines[@]}}}"; } >"$out"
}

run() {  # 期望退出码 参数…；输出到 $TMP/out / $TMP/err
  local want="$1"; shift
  local rc=0
  bash "$GATE" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "期望退出码 ${want}，实际 ${rc}"
  if grep -q SECRET_TEXT_ "$TMP/out" "$TMP/err"; then fail "输出里出现了源码标记 SECRET_TEXT_"; fi
}
has() { grep -qF -- "$1" "$TMP/out" || fail "输出缺少：$1"; }
hasnt() { if grep -qF -- "$1" "$TMP/out"; then fail "输出不应包含：$1"; fi; }

# ---------- 用例 ----------
jsonl "$TMP/api.jsonl"
jsonl "$TMP/cloud.jsonl" \
  'cloud:same=' \
  'cloud:newfail=[new:E055]' \
  'cloud:comma=[new:comma]' \
  'cloud:throws=[new:throw]' \
  'cloud:codes=[all:E050][new:E061]' \
  'cloudv:fixed=[old:E055]' \
  'cloud:cols=[new:col]' \
  'cloud:renamed=[new:rename]' \
  'cloud:zhcols=[lex:zh-CN][new@zh-CN:col]' \
  'cloud:decols=[lex:de-DE][new@de-DE:rename]' \
  'cloud:hionly=[lex:hi-IN][new@hi-IN:E055]' \
  'cloud:typeerr=[new:tc]' \
  'cloud:resolve=[new:resolve]'

CASE=fixture
run 1 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/api.jsonl" --sources "$TMP/cloud.jsonl"
has 'sources: {cloud-policy=12, cloud-policy-version=1}'
has 'lexicons: en-US, zh-CN, de-DE, hi-IN'
has 'newly-failing-E064: 4'
has "cloud:comma [cloud-policy] en-US old=ok{} new=parse{E064(','):error}"
has 'newly-failing: 13'
has 'cloud:newfail [cloud-policy] zh-CN old=ok{} new=parse{E055:error}'
has 'cloud:hionly [cloud-policy] hi-IN old=ok{} new=parse{E055:error}'
has 'cloud:typeerr [cloud-policy] de-DE old=ok{} new=typecheck{E200:error}'
has 'cloud:resolve [cloud-policy] en-US old=ok{} new=resolve{E801:error}'
has 'throws: 4'
has 'cloud:throws [cloud-policy] hi-IN old=ok{} new=throw{THROW:IllegalStateException}'
has 'changed-codes: 1'
has 'cloud:codes [cloud-policy] en-US old=parse{E050:error} new=parse{E050:error,E061:error}'
has 'ir-changed-other: 5'
has 'cloud:decols [cloud-policy] de-DE paths=[decls.name]'
has 'ir-changed-cols-only: 5'
has 'cloud:zhcols [cloud-policy] zh-CN paths=[decls.origin.end.col, decls.origin.start.col]'
has 'newly-passing: 1'
has 'cloudv:fixed [cloud-policy-version] en-US old=parse{E055:error} new=ok{}'
has 'result: REVIEW (32 need review;'
hasnt 'W900'

CASE=pass
jsonl "$TMP/clean.jsonl" 'cloud:a=' 'cloud:b=[lex:zh-CN]' 'cloudv:c=[all:E050]'
run 0 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/api.jsonl" --sources "$TMP/clean.jsonl"
has 'compiles: old ok 5 / new ok 5 / 12 (source × lexicon); compared 6'
has 'front-end ok (ok + typecheck): old 5 / new 5; old sources ok in any lexicon: 2 / 3'
has 'result: PASS (0 need review;'

CASE=missing-lexicon-jar
run 3 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new-nozh.cp" --sources "$TMP/clean.jsonl"
has 'result: ERROR (environment)'
grep -qF 'new 侧未注册 lexicon zh-CN' "$TMP/err" || fail 'stderr 缺少未注册 lexicon 的说明'

CASE=missing-cp-entry
printf '%s:%s' "$(cat "$TMP/old.cp")" "$TMP/gone.jar" >"$TMP/old-gone.cp"
run 3 scan --old-cp "$TMP/old-gone.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl"
grep -qF 'classpath 条目不存在' "$TMP/err" || fail 'stderr 缺少 classpath 条目缺失的说明'

CASE=truncated-export
jsonl "$TMP/trunc.jsonl" --count 5 'cloud:a='
run 3 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/trunc.jsonl"

CASE=sanity-ok
printf 'old compiles: 5 ok, 0 threw, 7 not ok / 12 compiles\nold sources ok in any lexicon: 2 / 3\n' >"$TMP/ts-scan.txt"
run 0 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --ts-scan "$TMP/ts-scan.txt"
has 'sanity: old sources ok in any lexicon: java 2 vs ts 2 (gap 0, allowed 1 = 5%) — ok'

CASE=sanity-skipped
run 0 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl"
has 'sanity: SKIPPED'

CASE=sanity-other-export
printf 'old sources ok in any lexicon: 2 / 999\n' >"$TMP/ts-other.txt"
run 3 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --ts-scan "$TMP/ts-other.txt"
has 'result: INVALID (ts scan is of a different export)'

CASE=sanity-gap
run 3 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --ts-old-sources-ok 20 --ts-sources-total 3
has 'TOO LARGE'
has 'result: INVALID (java/ts old-ok sources gap too large)'
hasnt 'result: PASS'

CASE=sanity-bad-ts-file
echo 'nothing here' >"$TMP/ts-bad.txt"
run 3 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --ts-scan "$TMP/ts-bad.txt"

CASE=jvm-error
# 旧侧缺 Jackson：加载 Worker 时抛 NoClassDefFoundError（Error 而非 Exception），不得以 1（REVIEW）或静默结束
run 3 scan --old-cp "$TMP/old-nojackson.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl"
has 'result: ERROR'

CASE=usage
run 2 scan --old-cp "$TMP/old.cp" --sources "$TMP/clean.jsonl"
run 2 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --ts-old-sources-ok
run 2 scan --old-cp --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl"
run 2 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --ts-old-sources-ok 2
run 2 scan --old-cp "$TMP/old.cp" --new-cp "$TMP/new.cp" --sources "$TMP/clean.jsonl" --max-gap-pct 5
run 2 frobnicate

# ---------- regex-scan.mjs / corpus-to-jsonl.mjs ----------
if command -v node >/dev/null && command -v perl >/dev/null; then
  GS="$(dirname "$HERE")"
  CASE=regex-scan
  printf '# Rcap 大写字段名\n^\\s*Define\\b.*\\bhas\\s+[A-Z]\n# Rnone 不会命中\nZZZ_NEVER\n' >"$TMP/rules.txt"
  printf '%s\n' '{"id":"cloud:r1","kind":"cloud-policy","content":"Module m.SECRET_TEXT_r1.\nDefine A has Id as Text."}' \
    '{"id":"cloud:r2","kind":"cloud-policy","content":"Module m.SECRET_TEXT_r2."}' '{"_count": 2}' >"$TMP/rx.jsonl"
  rc=0; node "$GS/regex-scan.mjs" --rules "$TMP/rules.txt" --sources "$TMP/rx.jsonl" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq 1 ] || fail "regex-scan 期望退出码 1，实际 $rc"
  has 'hit cloud:r1 cloud-policy Rcap'
  has 'per-rule: Rcap=1 Rnone=0'
  hasnt 'cloud:r2 cloud-policy R'
  if grep -q SECRET_TEXT_ "$TMP/out" "$TMP/err"; then fail '输出里出现了源码标记'; fi
  rc=0; node "$GS/regex-scan.mjs" --rules "$TMP/rules.txt" --sources "$TMP/trunc.jsonl" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq 3 ] || fail "regex-scan 截断导出期望退出码 3，实际 $rc"

  CASE=corpus-to-jsonl
  mkdir -p "$TMP/corpus-root/corpus/a"
  printf 'Module x.\n' >"$TMP/corpus-root/corpus/a/one.aster"
  node "$GS/corpus-to-jsonl.mjs" "$TMP/corpus-root" "$TMP/corpus-out" >"$TMP/out"
  has 'cloud.jsonl: 1 sources; api.jsonl: 0'
  tail -n 1 "$TMP/corpus-out/cloud.jsonl" | grep -qF '{"_count":1}' || fail 'corpus 导出缺完成标记'
else
  echo "SKIP regex-scan / corpus-to-jsonl（缺 node 或 perl）"
fi

# ---------- 可选：真实引擎端到端 ----------
if [ -n "${JAVA_GATE_OLD_CP:-}" ] && [ -n "${JAVA_GATE_NEW_CP:-}" ] && [ -n "${JAVA_GATE_CORPUS:-}" ]; then
  CASE=real-engine
  node "$(dirname "$HERE")/corpus-to-jsonl.mjs" "$JAVA_GATE_CORPUS" "$TMP/real" >/dev/null
  rc=0; bash "$GATE" scan --old-cp "$JAVA_GATE_OLD_CP" --new-cp "$JAVA_GATE_NEW_CP" \
    --sources "$TMP/real/api.jsonl" --sources "$TMP/real/cloud.jsonl" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -le 1 ] || fail "真实引擎扫描退出码 $rc"
  grep -E '^(compiles|front-end ok|result)' "$TMP/out"
fi

echo "java-gate.test.sh: all cases passed"
