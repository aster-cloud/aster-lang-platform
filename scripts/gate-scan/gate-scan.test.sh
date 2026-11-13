#!/usr/bin/env bash
# gate-scan.sh / scan.mjs 的本地回归测试。不连集群：kubectl 由 shim 顶替（按 psql 的 -d 返回合成导出）；
# aster-lang-ts 由几个假构建顶替（compile() 按源码里的指令返回诊断，并故意把源码打印到
# console / stdout，用来验证扫描不会泄露源码）。只依赖 bash + node 24。
#
# 源码指令：[<build>[@<lexicon>]:<CODE|Wxxx|throw>]，build 为 old / new / all；
#           [lex:<id>] 表示只在该 lexicon 下能解析。每份源都带唯一的 SECRET_TEXT_ 标记。
#
# 可选端到端（真实构建，合成源为类型嵌套深度 2/64/65/300，#250 期望 depth65/depth300 被报告）：
#   GATE_SCAN_OLD_TS=<v1.4.0 构建> GATE_SCAN_NEW_TS=<fix/250 构建> bash scripts/gate-scan/gate-scan.test.sh
# 可选端到端（input-refs，真实 ts 1.5.0 构建编译三份档案源；可再给一个 1.5.0 之前的构建验证退出码 3）：
#   GATE_SCAN_TS_150=<v1.5.0 构建> [GATE_SCAN_TS_140=<v1.4.0 构建>] bash scripts/gate-scan/gate-scan.test.sh
# 用法：bash scripts/gate-scan/gate-scan.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/gate-scan.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/tmp"
CASE=""

fail() {
  echo "FAIL [$CASE]: $*"
  for f in "$TMP/out" "$TMP/err"; do [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; }; done
  exit 1
}

# ---------- 假构建 ----------
make_build() {  # 目录 build名 lexicon...
  local dir="$1" build="$2"; shift 2
  mkdir -p "$dir/dist/src/config/lexicons"
  echo "{\"version\":\"0.0.0-$build\"}" >"$dir/package.json"
  sed "s/__BUILD__/$build/" >"$dir/dist/src/browser.js" <<'EOF'
const BUILD = '__BUILD__';
export function compile(source, options) {
  console.log('LEAK', source); console.error('LEAK', source); process.stdout.write(`LEAK ${source}\n`);
  if (BUILD === 'broken') throw new Error(`boom ${source}`);
  const lex = options?.lexicon?.id ?? 'en-US';
  const errors = []; const warnings = [];
  for (const m of source.matchAll(/\[(\w+)(?:@([\w-]+))?:([\w-]+)\]/g)) {
    const [, who, onlyLex, what] = m;
    if (who === 'lex') { if (lex !== what) errors.push('E050'); continue; }
    if (who !== BUILD && who !== 'all') continue;
    if (onlyLex && onlyLex !== lex) continue;
    if (what === 'throw') throw new Error(`boom ${source}`);
    (what.startsWith('W') ? warnings : errors).push(what);
  }
  if (errors.length) return { success: false, parseErrors: errors.map(code => ({ code, message: source })) };
  return warnings.length ? { success: true, parseErrors: warnings.map(code => ({ code })) } : { success: true };
}
EOF
  local id
  for id in "$@"; do
    echo "export const LEX_${id/-/_} = { id: '$id', keywords: {} };" >"$dir/dist/src/config/lexicons/$id.js"
  done
}
make_build "$TMP/fake-old" old en-US zh-CN hi-IN
make_build "$TMP/fake-new" new en-US zh-CN hi-IN
make_build "$TMP/fake-new-nohi" new en-US zh-CN
make_build "$TMP/fake-broken" broken en-US zh-CN hi-IN

# ---------- 合成导出 ----------
# jsonl 输出文件 [--count N] id=指令 ...（kind 由 id 前缀推断，content 带 SECRET_TEXT_ 标记）
cat >"$TMP/mkjsonl.mjs" <<'EOF'
import { writeFileSync } from 'node:fs';
const [out, ...rest] = process.argv.slice(2);
let count;
if (rest[0] === '--count') { count = Number(rest[1]); rest.splice(0, 2); }
const kinds = { api: 'api-policy-version', cloud: 'cloud-policy', cloudv: 'cloud-policy-version' };
const lines = rest.map(spec => {
  if (spec === 'BAD') return '{not json SECRET_TEXT_bad';
  const eq = spec.indexOf('=');   // 只按第一个 = 切分：指令里可以再含 =
  const [id, directive] = eq < 0 ? [spec, ''] : [spec.slice(0, eq), spec.slice(eq + 1)];
  return JSON.stringify({ id, kind: kinds[id.split(':')[0]], content: `Module m.SECRET_TEXT_${id.replace(':', '_')}. ${directive}` });
});
const n = count ?? lines.length;
writeFileSync(out, [...lines, `{"_count" : ${n}}`].join('\n') + '\n');
EOF
jsonl() { node "$TMP/mkjsonl.mjs" "$@"; }

API="$TMP/api.jsonl"; CLOUD="$TMP/cloud.jsonl"
default_exports() {
  jsonl "$API" 'api:same' 'api:newfail=[new:E054]' 'api:newpass=[old:E055]' 'api:warn=[new:W001]' 'api:bothfail=[all:E055]'
  jsonl "$CLOUD" 'cloud:zh=[lex:zh-CN]' 'cloud:hi=[lex:hi-IN]' 'cloud:perlex=[new@zh-CN:E077]' 'cloudv:throw=[new:throw]'
}

# kubectl shim：校验 SQL 走 stdin 且为只读事务，按库名返回导出；FAKE_KUBECTL_FAIL=1 时模拟失败。
cat >"$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_KUBECTL_LOG"
sql="$(cat)"
grep -q 'READ ONLY' <<<"$sql" || { echo "shim: SQL 不是只读事务" >&2; exit 9; }
[ "${FAKE_KUBECTL_FAIL:-}" = 1 ] && { echo "shim: error: unable to upgrade connection" >&2; exit 1; }
# 按 SQL 内容区分三份导出：源码（export-policy-sources）、影响面（export-profile-impact）、对账集合（export-profile-ids）
if grep -q 'gatedExecutions30d' <<<"$sql"; then what=IMPACT
elif grep -q 'Profil' <<<"$sql"; then what=IDS
else what=SRC; fi
case "$what: $* " in
  "SRC:"*" -d aster_api "*) cat "$FAKE_API_JSONL" ;;
  "SRC:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_JSONL" ;;
  "IMPACT:"*" -d aster_api "*) cat "$FAKE_API_IMPACT_JSONL" ;;
  "IMPACT:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_IMPACT_JSONL" ;;
  "IDS:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_IDS_JSONL" ;;
  *) echo "shim: 未知库 / 导出 $what $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
export FAKE_KUBECTL_LOG="$TMP/kubectl.log" FAKE_API_JSONL="$API" FAKE_CLOUD_JSONL="$CLOUD"
: >"$FAKE_KUBECTL_LOG"

run_script() {  # 期望退出码, 参数...
  local want="$1"; shift
  local rc=0
  PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmp" ASTER_TS_REPO="$TMP/no-ts-repo" bash "$SCRIPT" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "gate-scan.sh $* 期望 rc=${want}，实际 rc=${rc}"
  # 临时目录必须已清理（node 自己的 compile cache 除外）
  [ -z "$(ls -A "$TMP/tmp" | grep -v '^node-compile-cache$' || true)" ] || fail "退出后临时目录未清理：$(ls -A "$TMP/tmp")"
  ! grep -q 'SECRET_TEXT' "$TMP/out" "$TMP/err" || fail "输出泄露了源码内容"
}
group() { sed -n "/^$1: /,/^[a-z]/p" "$TMP/out" | grep '^  ' | awk '{print $1}' | sort | tr '\n' ' '; }
expect_group() { [ "$(group "$1")" = "$2" ] || fail "$1 应为 '$2'，实际 '$(group "$1")'"; }
expect_out() { grep -q -- "$1" "$TMP/out" || fail "stdout 缺少：$1"; }
expect_err() { grep -q -- "$1" "$TMP/err" || fail "stderr 缺少：$1"; }

OLD="path:$TMP/fake-old"; NEW="path:$TMP/fake-new"

CASE="用法"
run_script 0 --help; expect_out '--old-ts'
run_script 2 --old-ts v1.4.0
run_script 2 --old-ts v1.4.0 --new-ts x --bogus
run_script 2 --old-ts v1.4.0 --new-ts x --code 'e 54!'
run_script 2 export
run_script 2 export --out "$TMP/x" --old-ts v1.4.0
run_script 2 scan --old-ts a --new-ts b
run_script 2 --old-ts a --new-ts b --keep

CASE="dry-run"
run_script 0 --old-ts v1.4.0 --new-ts fix/250-type-nesting-guard --code E054 --kube-context ctx --dry-run
expect_out 'kubectl --context ctx -n data-services exec -i shared-postgres-1 -- psql -X -At -v ON_ERROR_STOP=1 -d aster_api -f -'
expect_out '-d aster_cloud -v cloud=1 -f -'
expect_out 'worktree add --detach'
expect_out 'scan.mjs --old .* --code E054'
run_script 0 export --out "$TMP/never" --dry-run; expect_out '-d aster_api -f -'
[ ! -e "$TMP/never" ] || fail "export --dry-run 不应创建目录"
[ ! -s "$FAKE_KUBECTL_LOG" ] || fail "dry-run 不应调用 kubectl"

CASE="diff 模式"
default_exports
run_script 1 --old-ts "$OLD" --new-ts "$NEW"
expect_group throws-on-new 'cloudv:throw '
expect_group lexicons-missing-in-new ''
expect_group newly-failing 'api:newfail cloud:perlex '
expect_group newly-passing 'api:newpass '
expect_group changed-codes 'api:warn '
expect_out '^scanned: 9 '
expect_out '^new compiles: .* 3 threw'
expect_out 'cloud:perlex \[cloud-policy\] zh-CN old={} new={E077}!$'
expect_out '^result: FAIL (5 reported)$'

CASE="--code E054"
run_script 1 --old-ts "$OLD" --new-ts "$NEW" --code e054
expect_group gains-E054 'api:newfail '
expect_group throws-on-new 'cloudv:throw '

CASE="自比"
run_script 0 --old-ts "$OLD" --new-ts "$OLD"; expect_out '^result: PASS (0 reported)$'

CASE="新版去掉 lexicon"
run_script 1 --old-ts "$OLD" --new-ts "path:$TMP/fake-new-nohi"
expect_group lexicons-missing-in-new 'hi-IN '
expect_out 'cloud:hi \[cloud-policy\] hi-IN old={} new={NO_LEXICON}!'

CASE="金丝雀"
run_script 3 --old-ts "$OLD" --new-ts "path:$TMP/fake-broken"; expect_err '金丝雀'

CASE="kubectl 失败"
FAKE_KUBECTL_FAIL=1 run_script 3 --old-ts "$OLD" --new-ts "$NEW"; expect_err '导出 aster_api 失败'

CASE="单边空导出"
jsonl "$CLOUD"
run_script 3 --old-ts "$OLD" --new-ts "$NEW"; expect_err 'aster_cloud 导出为 0 行'
run_script 1 --old-ts "$OLD" --new-ts "$NEW" --allow-empty-db; expect_out '^scanned: 5 '

CASE="两库皆空"
jsonl "$API"; jsonl "$CLOUD"
run_script 3 --old-ts "$OLD" --new-ts "$NEW" --allow-empty-db; expect_err '合计 0 行'
run_script 3 export --out "$TMP/xfer-empty" --allow-empty-db; expect_err '合计 0 行'
[ -z "$(ls -A "$TMP/xfer-empty")" ] || fail "两库皆空时应删除部分导出"
mkdir "$TMP/empty-src"; cp "$API" "$TMP/empty-src/api.jsonl"; cp "$CLOUD" "$TMP/empty-src/cloud.jsonl"
run_script 3 scan --sources "$TMP/empty-src" --old-ts "$OLD" --new-ts "$NEW" --allow-empty-db; expect_err '合计 0 行'
default_exports

CASE="截断导出"
jsonl "$CLOUD" --count 7 'cloud:zh=[lex:zh-CN]' 'cloud:hi=[lex:hi-IN]'
run_script 3 --old-ts "$OLD" --new-ts "$NEW"; expect_err '完成标记 7 行，实际 2 行'
head -n 2 "$API" >"$TMP/api-cut.jsonl"
FAKE_API_JSONL="$TMP/api-cut.jsonl" run_script 3 --old-ts "$OLD" --new-ts "$NEW"; expect_err '应恰好有 1 行完成标记'

CASE="坏 JSONL"
jsonl "$CLOUD" 'cloud:zh=[lex:zh-CN]' BAD
run_script 3 --old-ts "$OLD" --new-ts "$NEW"; expect_err '不是合法 JSON'

CASE="路径须显式"
default_exports
(cd "$TMP" && PATH="$TMP/bin:$PATH" TMPDIR="$TMP/tmp" ASTER_TS_REPO="$TMP/no-ts-repo" \
  bash "$SCRIPT" --old-ts fake-old --new-ts fake-new >"$TMP/out" 2>"$TMP/err") && fail "裸目录名应视为 git ref 并失败"
expect_err '视为 git ref'

CASE="分步 export + scan"
: >"$FAKE_KUBECTL_LOG"
run_script 0 export --out "$TMP/xfer"
expect_out "$TMP/xfer/api.jsonl  5 rows"
expect_out "$TMP/xfer/cloud.jsonl  4 rows"
[ "$(wc -l <"$FAKE_KUBECTL_LOG")" -eq 2 ] || fail "export 应调用 kubectl 两次"
perm="$(ls -l "$TMP/xfer/api.jsonl" | cut -c1-10)"
[ "$perm" = "-rw-------" ] || fail "导出文件权限应为 600，实际 $perm"
run_script 3 export --out "$TMP/xfer"; expect_err '已有 api.jsonl'
cp -R "$TMP/xfer" "$TMP/xfer-keep"
: >"$FAKE_KUBECTL_LOG"
PATH="$TMP/bin:$PATH" FAKE_KUBECTL_FAIL=1 run_script 1 scan --sources "$TMP/xfer" --old-ts "$OLD" --new-ts "$NEW"
expect_group newly-failing 'api:newfail cloud:perlex '
[ ! -s "$FAKE_KUBECTL_LOG" ] || fail "scan 模式不应调用 kubectl"
[ ! -e "$TMP/xfer" ] || fail "scan 结束后应删除导出（及空目录）"
run_script 1 scan --sources "$TMP/xfer-keep" --old-ts "$OLD" --new-ts "$NEW" --keep
[ -f "$TMP/xfer-keep/api.jsonl" ] || fail "--keep 应保留导出"
run_script 3 scan --sources "$TMP/xfer-keep" --old-ts "$OLD" --new-ts "path:$TMP/fake-broken"
[ ! -e "$TMP/xfer-keep/api.jsonl" ] || fail "scan 失败时也应删除导出"
FAKE_KUBECTL_FAIL=1 run_script 3 export --out "$TMP/xfer-fail"
[ -z "$(ls -A "$TMP/xfer-fail")" ] || fail "export 失败时应删除部分导出"

CASE="export 不写穿符号链接"
mkdir "$TMP/xfer-link"
ln -s "$TMP/link-target-api" "$TMP/xfer-link/api.jsonl"   # 悬空：-e 为假
run_script 3 export --out "$TMP/xfer-link"; expect_err '符号链接'
[ ! -e "$TMP/link-target-api" ] || fail "悬空符号链接被写穿，目标已被创建"
rm "$TMP/xfer-link/api.jsonl"; ln -s "$TMP/link-target-cloud" "$TMP/xfer-link/cloud.jsonl"
run_script 3 export --out "$TMP/xfer-link"; expect_err '符号链接'
[ ! -e "$TMP/link-target-cloud" ] || fail "悬空符号链接被写穿，目标已被创建"
rm "$TMP/xfer-link/cloud.jsonl"; echo KEEP >"$TMP/live-target"; ln -s "$TMP/live-target" "$TMP/xfer-link/api.jsonl"   # 有效链接
run_script 3 export --out "$TMP/xfer-link"; expect_err '符号链接'
[ "$(cat "$TMP/live-target")" = KEEP ] || fail "有效符号链接的目标被改写"

CASE="--ssh-host"
# 假 ssh：记录参数，把最后一个参数（远端命令行）交给 bash -c，stdin 原样透传；假 kubectl 在 PATH 上充当「远端」。
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_SSH_LOG"
[ "$1" = -o ] && [ "$2" = BatchMode=yes ] && [ "$3" = -- ] || { echo "ssh shim: 参数不符 $*" >&2; exit 9; }
shift 4   # -o BatchMode=yes -- <host>
exec bash -c "$1"
EOF
chmod +x "$TMP/bin/ssh"
export FAKE_SSH_LOG="$TMP/ssh.log"; : >"$FAKE_SSH_LOG"; : >"$FAKE_KUBECTL_LOG"
run_script 2 scan --sources "$TMP" --old-ts a --new-ts b --ssh-host h
run_script 2 export --out "$TMP/x" --ssh-host -oProxyCommand=x
run_script 0 export --out "$TMP/never" --ssh-host admin@h --dry-run; expect_out '+ ssh -o BatchMode=yes -- admin@h'
run_script 0 export --out "$TMP/xfer-ssh" --ssh-host root@master-1 --kube-context 'ctx with space'
[ "$(wc -l <"$FAKE_SSH_LOG")" -eq 2 ] || fail "export 应调用 ssh 两次"
grep -q -- '--context ctx with space' "$FAKE_KUBECTL_LOG" || fail "远端 kubectl 应收到完整的带空格参数"
expect_out "$TMP/xfer-ssh/api.jsonl  5 rows"
run_script 1 --old-ts "$OLD" --new-ts "$NEW" --ssh-host root@master-1
expect_out '^scanned: 9 '
FAKE_KUBECTL_FAIL=1 run_script 3 --old-ts "$OLD" --new-ts "$NEW" --ssh-host root@master-1; expect_err '导出 aster_api 失败'
# 元字符：值必须原样到达远端 kubectl，且不被 shell 执行
mkdir "$TMP/inj"; : >"$FAKE_KUBECTL_LOG"
( cd "$TMP/inj" && run_script 0 export --out "$TMP/xfer-inj1" --ssh-host root@h --kube-context 'a;touch X' )
grep -q -- '--context a;touch X ' "$FAKE_KUBECTL_LOG" || fail "含分号的值应原样到达 kubectl"
( cd "$TMP/inj" && run_script 0 export --out "$TMP/xfer-inj2" --ssh-host root@h --kube-context "\$(touch Y)'q\"" )
grep -qF -- "--context \$(touch Y)'q\" " "$FAKE_KUBECTL_LOG" || fail "含 \$() 与引号的值应原样到达 kubectl"
[ -z "$(ls -A "$TMP/inj")" ] || fail "元字符被远端 shell 执行：$(ls "$TMP/inj")"
# ssh 自身失败（连接不上）→ rc 3，且不留部分导出
cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh: connect to host h port 22: Connection refused" >&2; exit 255
EOF
chmod +x "$TMP/bin/ssh"
run_script 3 export --out "$TMP/xfer-sshfail" --ssh-host root@h; expect_err '导出 aster_api 失败'
[ -z "$(ls -A "$TMP/xfer-sshfail")" ] || fail "ssh 失败时应删除部分导出"
rm -f "$TMP/bin/ssh"

# ---------- input-refs 子命令 ----------
# 假 ts 1.5.0 构建：compileAndTypecheck 按源码指令产出 Core IR（profile、Verdict 规则的 inputRefs）与 E708；
# 指令：[profile:<id>] [module:<名>] [rule:<名>=<路径,路径>|*:<construct>|ROOT] [fail]，外加 [lex:<id>]（同上）。
# 金丝雀（真实 Aster 语法，按 Profile "…" 与是否含 Map.get 识别）同样处理。故意把源码打到 console / stdout。
# variant：v150 正常；v140 不写 inputRefs、无 E708（ts 1.4.0）；noflip 无视注入的注册表（永不报 E708）。
make_ir_build() {  # 目录 variant lexicon...
  local dir="$1" variant="$2"; shift 2
  mkdir -p "$dir/dist/src/config/lexicons"
  echo "{\"version\":\"0.0.0-ir-$variant\",\"type\":\"module\"}" >"$dir/package.json"
  sed "s/__VARIANT__/$variant/" >"$dir/dist/src/browser.js" <<'EOF'
const VARIANT = '__VARIANT__';
const profile = (id, verifiedInputs) => ({ id, requires: { ruleId: true, registeredControls: true, frameworks: [], verifiedInputs } });
export const CONTROLS_REGISTRY = { version: '1.2.0', controls: [], frameworks: [], profiles: [profile('governed', false), profile('eu-ai-act-high-risk', false)] };
export function controlRegistryFrom(data) {
  const byId = new Map(data.profiles.map(p => [p.id, { id: p.id, verifiedInputs: p.requires.verifiedInputs === true }]));
  return { version: data.version, has: () => false, profile: id => byId.get(id) };
}
export function compile(source, options) { return compileAndTypecheck(source, options); }
export function compileAndTypecheck(source, options) {
  console.log('LEAK', source); console.error('LEAK', source); process.stdout.write(`LEAK ${source}\n`);
  const lex = options?.lexicon?.id ?? 'en-US';
  const onlyLex = /\[lex:([\w-]+)\]/.exec(source);
  if (/\[fail\]/.test(source) || (onlyLex && onlyLex[1] !== lex)) {
    return { success: false, parseErrors: [{ code: 'E050', message: source }], typeErrors: [] };
  }
  const prof = /\[profile:([\w-]+)\]/.exec(source)?.[1] ?? /Profile "([\w-]+)"/.exec(source)?.[1];
  const name = /\[module:([\w.]+)\]/.exec(source)?.[1] ?? (/^Module gate\.canary/.test(source) ? 'gate.canary' : 'm');
  const rules = [...source.matchAll(/\[rule:(\w+)=([^\]]*)\]/g)].map(m => [m[1], m[2]]);
  if (/^Module gate\.canary/.test(source)) rules.push(['decide', source.includes('Map.get(') ? '*:dynamic-map-key' : 'context.amount']);
  const verified = prof !== undefined && VARIANT !== 'noflip' && options?.controls?.profile?.(prof)?.verifiedInputs === true;
  const typeErrors = [];
  const decls = rules.map(([rule, spec]) => {
    const fn = { kind: 'Func', name: rule };
    if (prof === undefined || VARIANT === 'v140') return fn;
    if (spec.startsWith('*:')) {
      fn.inputRefs = ['*'];
      if (verified) typeErrors.push({ code: 'E708', severity: 'error', message: source, data: { rule, profile: prof, construct: spec.slice(2) } });
    } else {
      fn.inputRefs = spec === 'ROOT' ? [''] : spec.split(',').filter(Boolean);
    }
    return fn;
  });
  const core = { kind: 'Module', name, decls, ...(prof !== undefined ? { profile: prof } : {}) };
  return { success: true, core, typeErrors };
}
EOF
  local id
  for id in "$@"; do
    echo "export const LEX_${id/-/_} = { id: '$id', keywords: {} };" >"$dir/dist/src/config/lexicons/$id.js"
  done
}
make_ir_build "$TMP/ir-150" v150 en-US zh-CN de-DE hi-IN
make_ir_build "$TMP/ir-140" v140 en-US zh-CN de-DE hi-IN
make_ir_build "$TMP/ir-noflip" noflip en-US zh-CN de-DE hi-IN
TS150="path:$TMP/ir-150"

# 原样写 JSONL（影响面 / 对账集合）：输出文件 行... ，末尾自动加完成标记
rawjsonl() { local out="$1"; shift; { [ $# -eq 0 ] || printf '%s\n' "$@"; echo "{\"_count\" : $#}"; } >"$out"; }
API_IMPACT="$TMP/api-impact.jsonl"; CLOUD_IMPACT="$TMP/cloud-impact.jsonl"; IDS="$TMP/profile-ids.jsonl"
export FAKE_API_IMPACT_JSONL="$API_IMPACT" FAKE_CLOUD_IMPACT_JSONL="$CLOUD_IMPACT" FAKE_IDS_JSONL="$IDS"
ir_exports() {
  jsonl "$API"
  jsonl "$CLOUD" 'cloud:lit=[profile:eu-ai-act-high-risk][module:credit.pilot][rule:decide=context.amount,principal.id]' \
    'cloud:gov=[profile:governed][rule:decide=*:dynamic-map-key]' \
    'cloudv:dyn=[profile:eu-ai-act-high-risk][module:credit.pilot][rule:decide=*:dynamic-map-key]'
  rawjsonl "$API_IMPACT" '{"tenant":"team-a","issuer":"aster-cloud","kid":"k1","enabled":true,"notAfter":null}' \
    '{"tenant":"user-b","issuer":"aster-cloud","kid":"k0","enabled":false,"notAfter":null}'
  rawjsonl "$CLOUD_IMPACT" '{"id":"cloud:lit","tenant":"team-a","gatedExecutions30d":3}' \
    '{"id":"cloud:gov","tenant":"team-a","gatedExecutions30d":0}' '{"id":"cloudv:dyn","tenant":"user-b","gatedExecutions30d":0}'
  rawjsonl "$IDS" '{"id":"cloud:lit"}' '{"id":"cloud:gov"}' '{"id":"cloudv:dyn"}'
}
IR=(input-refs --ts "$TS150" --profile eu-ai-act-high-risk)

CASE="input-refs 用法"
run_script 0 input-refs --help; expect_out '--profile'
run_script 2 input-refs --profile eu-ai-act-high-risk
run_script 2 input-refs --ts "$TS150"
run_script 2 input-refs --ts "$TS150" --profile 'Bad Profile'
run_script 2 input-refs --ts "$TS150" --profile eu-ai-act-high-risk --old-ts x
run_script 2 input-refs --ts "$TS150" --profile eu-ai-act-high-risk --impact "$TMP/x.jsonl"   # --impact 只用于 --sources
CASE="legacyAllowEmptyDbRejectedForInputRefs"
run_script 2 "${IR[@]}" --allow-empty-db; expect_err '--allow-empty-api-db'

CASE="input-refs dry-run"
: >"$FAKE_KUBECTL_LOG"
run_script 0 input-refs --ts v1.5.0 --profile eu-ai-act-high-risk --allow-empty-api-db --dry-run
expect_out 'export-profile-impact.sql'
expect_out 'export-profile-ids.sql'
expect_out 'input-refs.mjs --ts .* --profile eu-ai-act-high-risk .*--allow-empty-api .*--impact .*--impact .*--profile-ids '
[ ! -s "$FAKE_KUBECTL_LOG" ] || fail "dry-run 不应调用 kubectl"

CASE="input-refs 三份夹具（字面路径 / 动态键 / governed）"
ir_exports
: >"$FAKE_KUBECTL_LOG"
run_script 1 "${IR[@]}" --allow-empty-api-db
[ "$(wc -l <"$FAKE_KUBECTL_LOG")" -eq 5 ] || fail "一体化 input-refs 应调用 kubectl 五次（源码×2、影响面×2、对账×1）"
expect_group input-refs 'cloud:lit cloudv:dyn '
expect_out '^  cloudv:dyn kind=cloud-policy-version lexicon=en-US module=credit.pilot rule=decide inputRefs=\["\*"\] flags=STAR construct=dynamic-map-key '
expect_out '^  cloud:lit kind=cloud-policy lexicon=en-US module=credit.pilot rule=decide inputRefs=\["context.amount","principal.id"\] flags=- construct=- '
CASE="--impact 合入租户与执行数"
expect_out '^  cloud:lit .* tenant=team-a gatedExecutions30d=3 tenantHasEnabledIssuer=yes$'
expect_out '^  cloudv:dyn .* tenant=user-b gatedExecutions30d=0 tenantHasEnabledIssuer=no$'
expect_out '^modules: 2$'
expect_out '^rules: 2$'
expect_out '^star-rules: 1 (dynamic-map-key=1)$'
expect_out '^whole-input-serialized: 0$'
expect_out '^root-rules: 0$'
expect_out '^tenants: 2 (without enabled issuer: 1)$'
expect_out '^result: STAR (1 STAR rules)$'
CASE="sourceCountsPrinted"
expect_out '^sources: cloud-policy=2 cloud-policy-version=1 api-policy-version=0$'
CASE="reconcileMatchPasses"
expect_out '^reconcile: sql=3 scan=3 onlyInSql=\[\] onlyInScan=\[\]$'

CASE="apiExportEmptyAllowedWithFlag"
jsonl "$CLOUD" 'cloud:lit=[profile:eu-ai-act-high-risk][rule:decide=context.amount]'
rawjsonl "$CLOUD_IMPACT" '{"id":"cloud:lit","tenant":"team-a","gatedExecutions30d":3}'
rawjsonl "$IDS" '{"id":"cloud:lit"}'
run_script 0 "${IR[@]}" --allow-empty-api-db; expect_out '^result: PASS (0 STAR rules)$'
run_script 3 "${IR[@]}"; expect_err 'aster_api 导出为 0 行'
CASE="ROOT 标记"
jsonl "$CLOUD" 'cloud:lit=[profile:eu-ai-act-high-risk][rule:decide=ROOT]'
run_script 0 "${IR[@]}" --allow-empty-api-db
expect_out '^  cloud:lit .* inputRefs=\[""\] flags=ROOT construct=- '; expect_out '^root-rules: 1$'

CASE="cloudExportEmptyIsExit3"
ir_exports; jsonl "$CLOUD"; rawjsonl "$CLOUD_IMPACT"; rawjsonl "$IDS"
run_script 3 "${IR[@]}" --allow-empty-api-db; expect_err 'aster_cloud 导出为 0 行'
CASE="reconcileMismatchIsExit4"
ir_exports; rawjsonl "$IDS" '{"id":"cloud:lit"}' '{"id":"cloud:gov"}' '{"id":"cloudv:dyn"}' '{"id":"cloud:extra"}'
run_script 4 "${IR[@]}" --allow-empty-api-db
expect_out '^reconcile: sql=4 scan=3 onlyInSql=\[cloud:extra\] onlyInScan=\[\]$'
expect_out '^result: RECONCILE-MISMATCH '
CASE="对账：编译失败的档案源只在 SQL 集合"
ir_exports
jsonl "$CLOUD" 'cloud:lit=[profile:eu-ai-act-high-risk][rule:decide=context.amount]' 'cloud:gov=[profile:governed][fail]'
rawjsonl "$IDS" '{"id":"cloud:lit"}' '{"id":"cloud:gov"}'
run_script 4 "${IR[@]}" --allow-empty-api-db
expect_out '^reconcile: sql=2 scan=1 onlyInSql=\[cloud:gov\] onlyInScan=\[\]$'
expect_group compile-failed 'cloud:gov '

CASE="input-refs：ts 1.4.0 构建"
ir_exports
run_script 3 input-refs --ts "path:$TMP/ir-140" --profile eu-ai-act-high-risk --allow-empty-api-db; expect_err '1.5.0'
CASE="input-refs：注册表注入无效"
run_script 3 input-refs --ts "path:$TMP/ir-noflip" --profile eu-ai-act-high-risk --allow-empty-api-db; expect_err 'E708'
CASE="input-refs：未知档案"
run_script 3 input-refs --ts "$TS150" --profile no-such-profile --allow-empty-api-db; expect_err "没有档案 no-such-profile"   # .mjs 的用法错误在入口层一律为 3
CASE="input-refs：影响面缺行"
rawjsonl "$CLOUD_IMPACT" '{"id":"cloud:lit","tenant":"team-a","gatedExecutions30d":3}'
run_script 3 "${IR[@]}" --allow-empty-api-db; expect_err 'cloudv:dyn'
CASE="input-refs：对账导出截断"
ir_exports; printf '%s\n' '{"id":"cloud:lit"}' '{"_count" : 3}' >"$IDS"
run_script 3 "${IR[@]}" --allow-empty-api-db; expect_err '完成标记'
CASE="input-refs：kubectl 失败"
ir_exports
FAKE_KUBECTL_FAIL=1 run_script 3 "${IR[@]}" --allow-empty-api-db; expect_err '导出 aster_api 失败'

CASE="input-refs 分步（export --with-input-refs + input-refs --sources）"
ir_exports
run_script 0 export --out "$TMP/irx" --with-input-refs --allow-empty-api-db
for f in api cloud api-impact cloud-impact profile-ids; do [ -f "$TMP/irx/$f.jsonl" ] || fail "缺 $f.jsonl"; done
run_script 2 input-refs --sources "$TMP/irx" --ts "$TS150" --profile eu-ai-act-high-risk --ssh-host h
run_script 1 input-refs --sources "$TMP/irx" --ts "$TS150" --profile eu-ai-act-high-risk --allow-empty-api-db \
  --impact "$TMP/irx/api-impact.jsonl" --impact "$TMP/irx/cloud-impact.jsonl" --profile-ids "$TMP/irx/profile-ids.jsonl"
expect_out '^reconcile: sql=3 scan=3 '
[ ! -e "$TMP/irx/api.jsonl" ] && [ ! -e "$TMP/irx/cloud.jsonl" ] || fail "input-refs --sources 结束后应删除源码导出"
cp "$CLOUD" "$TMP/irx/cloud.jsonl"; cp "$API" "$TMP/irx/api.jsonl"
run_script 1 input-refs --sources "$TMP/irx" --ts "$TS150" --profile eu-ai-act-high-risk --allow-empty-api-db --keep
expect_out '^reconcile: SKIPPED'
[ -f "$TMP/irx/cloud.jsonl" ] || fail "--keep 应保留导出"
rm -rf "$TMP/irx"

# ---------- 常规 diff 扫描的源计数与 --allow-empty-api-db ----------
CASE="diffScanPrintsSourceCounts"
default_exports
run_script 1 --old-ts "$OLD" --new-ts "$NEW"
expect_out '^sources: cloud-policy=3 cloud-policy-version=1 api-policy-version=5$'
CASE="diffScanAcceptsAllowEmptyApiDb"
jsonl "$API"
run_script 1 --old-ts "$OLD" --new-ts "$NEW" --allow-empty-api-db
expect_out '^sources: cloud-policy=3 cloud-policy-version=1 api-policy-version=0$'
run_script 3 --old-ts "$OLD" --new-ts "$NEW"; expect_err 'aster_api 导出为 0 行'
mkdir "$TMP/apiempty-src"; cp "$API" "$TMP/apiempty-src/api.jsonl"; cp "$CLOUD" "$TMP/apiempty-src/cloud.jsonl"
run_script 1 scan --sources "$TMP/apiempty-src" --old-ts "$OLD" --new-ts "$NEW" --allow-empty-api-db
CASE="diffScanCloudEmptyIsExit3WithApiFlag"
default_exports; jsonl "$CLOUD"
run_script 3 --old-ts "$OLD" --new-ts "$NEW" --allow-empty-api-db; expect_err 'aster_cloud 导出为 0 行'
default_exports

if [ -n "${GATE_SCAN_OLD_TS:-}" ] && [ -n "${GATE_SCAN_NEW_TS:-}" ]; then
  CASE="真实构建 #250"
  node -e '
const fs = require("fs");
const src = d => `Module m.t.\n\nRule f given x as ${"list of ".repeat(d - 1)}Int, produce Int:\n  Return 1.`;
const row = (id, kind, d) => JSON.stringify({ id, kind, content: src(d) });
fs.writeFileSync(process.argv[1], [row("api:depth2", "api-policy-version", 2), row("api:depth64", "api-policy-version", 64), "{\"_count\" : 2}"].join("\n") + "\n");
fs.writeFileSync(process.argv[2], [row("cloud:depth65", "cloud-policy", 65), row("cloudv:depth300", "cloud-policy-version", 300), "{\"_count\" : 2}"].join("\n") + "\n");
' "$API" "$CLOUD"
  run_script 1 --old-ts "path:$GATE_SCAN_OLD_TS" --new-ts "path:$GATE_SCAN_NEW_TS" --code E054
  expect_group gains-E054 'cloud:depth65 cloudv:depth300 '
  ! grep -q 'list of' "$TMP/out" "$TMP/err" || fail "输出泄露了源码内容"
  run_script 1 --old-ts "path:$GATE_SCAN_OLD_TS" --new-ts "path:$GATE_SCAN_NEW_TS"
  expect_group newly-failing 'cloud:depth65 cloudv:depth300 '
  expect_group throws-on-new ''
  run_script 0 --old-ts "path:$GATE_SCAN_OLD_TS" --new-ts "path:$GATE_SCAN_OLD_TS"
else
  echo "SKIP: 未设置 GATE_SCAN_OLD_TS / GATE_SCAN_NEW_TS，跳过真实构建端到端"
fi

if [ -n "${GATE_SCAN_TS_150:-}" ]; then
  CASE="真实构建 input-refs"
  # 三份真实源：字面路径（adr-01）、动态 Map 键（adr-06）、同一规则改为 Profile "governed"；哨兵串放在字符串字面量里
  node -e '
const fs = require("fs");
const head = (name, profile) => `Module ${name}.\nProfile "${profile}".\n\nDefine GuardContext has amount as Decimal, tier as Text, band as Text, meta as Map Text to Text.\nDefine GuardRequest has principal_roles as List of Text, action as Text, context as GuardContext.\n\n@id("R-1")\n@control("EU_AI_ACT:ART14")\nRule decide given req as GuardRequest, produce Verdict:\n`;
const lit = head("real.lit", "eu-ai-act-high-risk") + `  If req.context.amount at least 50000:\n    Return Verdict.escalate("SECRET_TEXT_lit").\n  Return Verdict.allow().\n`;
const dyn = p => head("real.dyn", p) + `  Let k be req.action.\n  If Maybe.withDefault(Map.get(req.context.meta, k), "") equals to "SECRET_TEXT_dyn":\n    Return Verdict.escalate("eu").\n  Return Verdict.allow().\n`;
const row = (id, kind, content) => JSON.stringify({ id, kind, content });
fs.writeFileSync(process.argv[1], "{\"_count\" : 0}\n");
fs.writeFileSync(process.argv[2], [row("cloud:lit", "cloud-policy", lit), row("cloud:gov", "cloud-policy", dyn("governed")),
  row("cloudv:dyn", "cloud-policy-version", dyn("eu-ai-act-high-risk")), "{\"_count\" : 3}"].join("\n") + "\n");
' "$API" "$CLOUD"
  rawjsonl "$IDS" '{"id":"cloud:lit"}' '{"id":"cloud:gov"}' '{"id":"cloudv:dyn"}'
  rawjsonl "$API_IMPACT"
  rawjsonl "$CLOUD_IMPACT" '{"id":"cloud:lit","tenant":"t1","gatedExecutions30d":1}' \
    '{"id":"cloud:gov","tenant":"t1","gatedExecutions30d":0}' '{"id":"cloudv:dyn","tenant":"t2","gatedExecutions30d":2}'
  run_script 1 input-refs --ts "path:$GATE_SCAN_TS_150" --profile eu-ai-act-high-risk --allow-empty-api-db
  expect_group input-refs 'cloud:lit cloudv:dyn '
  expect_out '^  cloud:lit kind=cloud-policy lexicon=en-US module=real.lit rule=decide inputRefs=\["context.amount"\] flags=- construct=- tenant=t1 '
  expect_out '^  cloudv:dyn .* inputRefs=\["\*"\] flags=STAR construct=dynamic-map-key tenant=t2 gatedExecutions30d=2 tenantHasEnabledIssuer=no$'
  expect_out '^sources: cloud-policy=2 cloud-policy-version=1 api-policy-version=0$'
  expect_out '^reconcile: sql=3 scan=3 onlyInSql=\[\] onlyInScan=\[\]$'
  ! grep -q 'Verdict\.' "$TMP/out" "$TMP/err" || fail "输出泄露了源码内容"
  if [ -n "${GATE_SCAN_TS_140:-}" ]; then
    run_script 3 input-refs --ts "path:$GATE_SCAN_TS_140" --profile eu-ai-act-high-risk --allow-empty-api-db
  fi
  default_exports
else
  echo "SKIP: 未设置 GATE_SCAN_TS_150，跳过 input-refs 真实构建端到端"
fi

echo "PASS"
