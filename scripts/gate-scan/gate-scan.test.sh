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
# 按 SQL 内容区分五种导出：源码（export-policy-sources）、影响面（export-profile-impact）、对账集合（export-profile-ids）、
# 词汇（export-vocab）、排版（export-layouts）
if grep -q 'PolicyVersionLayout' <<<"$sql"; then what=LAYOUT
elif grep -q 'vocabularies' <<<"$sql"; then what=VOCAB
elif grep -q 'gatedExecutions30d' <<<"$sql"; then what=IMPACT
elif grep -q 'Profil' <<<"$sql"; then what=IDS
else what=SRC; fi
case "$what: $* " in
  "SRC:"*" -d aster_api "*) cat "$FAKE_API_JSONL" ;;
  "SRC:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_JSONL" ;;
  "IMPACT:"*" -d aster_api "*) cat "$FAKE_API_IMPACT_JSONL" ;;
  "IMPACT:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_IMPACT_JSONL" ;;
  "IDS:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_IDS_JSONL" ;;
  "VOCAB:"*" -d aster_api "*) cat "$FAKE_API_VOCAB_JSONL" ;;
  "VOCAB:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_VOCAB_JSONL" ;;
  "LAYOUT:"*" -d aster_cloud -v cloud=1 "*) cat "$FAKE_CLOUD_LAYOUT_JSONL" ;;
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

# ---------- 词汇 / 别名碰撞（export --with-vocab + vocab-check.mjs） ----------
# 合成导出：每条记录一行，字段与 export-vocab.sql 相同；触发词与别名都是会命中 / 不该命中的拼写，另带 SECRET_TEXT_ 标记，
# 用来验证 vocab-check 只打印 id / kind / lexicon / 规则名。
API_VOCAB="$TMP/api-vocab.jsonl"; CLOUD_VOCAB="$TMP/cloud-vocab.jsonl"
export FAKE_API_VOCAB_JSONL="$API_VOCAB" FAKE_CLOUD_VOCAB_JSONL="$CLOUD_VOCAB"
cat >"$TMP/mkvocab.mjs" <<'EOF'
import { writeFileSync } from 'node:fs';
const [apiOut, cloudOut] = process.argv.slice(2);
const kinds = { api: 'api-policy-version', cloudv: 'cloud-policy-version', cloudterm: 'cloud-domain-term' };
const lit = (localized, canonical = 'SECRET_TEXT_value') => ({ kind: 'literal', localized, canonical });
const emb = (...terms) => JSON.stringify({ v: 1, terms });
const vocab = (o = {}) => ({ source: 'snapshot', id: 's', locale: null, found: true, literalTriggers: [], triggers: [], values: [], ...o });
const row = (id, lexicon, o = {}) => ({ id, kind: kinds[id.split(':')[0]], lexicon, lexiconFrom: lexicon ? 'envelope' : null,
  aliasSet: null, embedded: null, vocabularies: [], ...o });
const cloud = [
  // D1：字面量触发词 = 本语言关键词 / 折叠后相等 / zh 里的 en-US 拼写（短码 zh）/ NFC 不同写法 / 语言未知按全部 locale
  row('cloudv:d1kw', 'zh-CN', { embedded: emb(lit('返回'), { kind: 'struct', localized: 'SECRET_TEXT_s', canonical: 'S' }) }),
  row('cloudv:d1fold', 'en-US', { vocabularies: [vocab({ literalTriggers: ['greeting', 'RETURN'], triggers: ['greeting', 'RETURN'] })] }),
  row('cloudv:d1en', 'zh', { embedded: emb(lit('Text')) }),
  row('cloudv:d1nfc', 'hi-IN', { embedded: emb(lit('प्रो\u095Eाइल')) }),
  row('cloudv:d1unknown', null, { embedded: emb(lit('Profil')) }),
  // D1：字面量触发词 = 本版本 aliasSet 的别名（折叠后）
  row('cloudv:d1alias', 'en-US', { aliasSet: JSON.stringify({ RETURN: ['giveback', 'SECRET_TEXT_a'] }), embedded: emb(lit('GiveBack')) }),
  // D1 对照：他语言的拼写、非字面量词条、多词关键词的一部分、仅前缀相同、别名属于别的写法
  row('cloudv:ctl_d1_locale', 'en-US', { embedded: emb(lit('返回'), lit('Profil')) }),
  row('cloudv:ctl_d1_struct', 'en-US', { embedded: emb({ kind: 'struct', localized: 'Return', canonical: 'R' }),
    vocabularies: [vocab({ triggers: ['Text'] })] }),
  row('cloudv:ctl_d1_word', 'en-US', { embedded: emb(lit('result'), lit('Returns'), lit('greeting')) }),
  row('cloudv:ctl_d1_alias', 'en-US', { aliasSet: JSON.stringify({ RETURN: ['handback'] }), embedded: emb(lit('giveback')) }),
  // D3：aliasSet / 任意种类的触发词 / 规范名等于新类型关键词（不分 locale、不分大小写）
  row('cloudv:d3alias', 'de-DE', { aliasSet: JSON.stringify({ TYPE_ALIAS: ['TYP'] }) }),
  row('cloudv:d3trig', 'zh-CN', { vocabularies: [vocab({ triggers: ['类型'], values: ['Kind'] })] }),
  row('cloudv:d3hi', 'hi-IN', { embedded: emb({ kind: 'field', localized: 'प्रकार', canonical: 'kind', parent: 'P' }) }),
  row('cloudv:d3value', 'en-US', { embedded: emb(lit('SECRET_TEXT_t', 'typ')) }),
  row('cloudterm:d3term', 'zh-CN', { lexiconFrom: 'term', vocabularies: [vocab({ source: 'term', triggers: ['种类', '类型'], values: ['kind'] })] }),
  // D3 对照：近似拼写
  row('cloudv:ctl_d3', 'de-DE', { aliasSet: JSON.stringify({ TYPE_ALIAS: ['Typo'] }), embedded: emb({ kind: 'struct', localized: 'Typen', canonical: 'Types' }) }),
  // 无法检查的记录
  row('cloudv:badalias', 'en-US', { aliasSet: '{not json SECRET_TEXT_x' }),
  row('cloudv:badembedded', 'en-US', { embedded: '[1,2]' }),
  // 嵌套形状不符不得被静默跳过（否则藏住命中）：别名里的数组、缺 v、未知 kind、非字符串 localized、快照里的非字符串触发词
  row('cloudv:badalias2', 'de-DE', { aliasSet: JSON.stringify({ TYPE_ALIAS: [['Typ']] }) }),
  row('cloudv:badembedded2', 'zh-CN', { embedded: JSON.stringify({ terms: [lit('返回')] }) }),
  row('cloudv:badembedded3', 'zh-CN', { embedded: emb({ kind: 'literalx', localized: '返回', canonical: 'x' }) }),
  row('cloudv:badembedded4', 'zh-CN', { embedded: emb({ kind: 'literal', localized: ['返回'], canonical: 'x' }) }),
  row('cloudv:badvocab', 'de-DE', { vocabularies: [vocab({ triggers: [['Typ']] })] }),
  row('cloudv:missing', 'de-DE', { vocabularies: [vocab({ found: false })] }),
  row('cloudv:clean', 'en-US'),
];
const api = [
  row('api:d1', 'zh-CN', { vocabularies: [vocab({ source: 'frozen', literalTriggers: ['文本'], triggers: ['文本'] })] }),
  row('api:clean', null),
];
const write = (out, rows) => writeFileSync(out, [...rows.map(r => JSON.stringify(r)), `{"_count" : ${rows.length}}`].join('\n') + '\n');
write(apiOut, api);
write(cloudOut, cloud);
EOF
vocab_exports() { node "$TMP/mkvocab.mjs" "$API_VOCAB" "$CLOUD_VOCAB"; }
VOCAB_CHECK="$HERE/vocab-check.mjs"
run_check() {  # 期望退出码, vocab-check 参数...
  local want="$1"; shift
  local rc=0
  node "$VOCAB_CHECK" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "vocab-check $* 期望 rc=${want}，实际 rc=${rc}"
  ! grep -q -F -e SECRET_TEXT -e '返回' -e '文本' -e '类型' -e 'प्रकार' -e GiveBack -e giveback -e Profil "$TMP/out" "$TMP/err" \
    || fail "输出泄露了触发词 / 别名 / 词汇内容"
}
hits() { grep '^hit ' "$TMP/out" | awk '{print $2 "/" $4 "/" $5}' | sort | tr '\n' ' ' || true; }
expect_hits() { [ "$(hits)" = "$1" ] || fail "命中应为 '$1'，实际 '$(hits)'"; }

CASE="--with-vocab 用法"
run_script 2 --old-ts a --new-ts b --with-vocab
run_script 2 scan --sources "$TMP/x" --old-ts a --new-ts b --with-vocab
run_script 2 input-refs --ts a --profile p --with-vocab
run_script 0 --help; expect_out '--with-vocab'

CASE="--with-vocab dry-run"
: >"$FAKE_KUBECTL_LOG"
run_script 0 export --out "$TMP/never" --with-vocab --dry-run
expect_out "-d aster_api -f - < .*export-vocab.sql > .*api-vocab.jsonl"
expect_out "-d aster_cloud -v cloud=1 -f - < .*export-vocab.sql > .*cloud-vocab.jsonl"
[ ! -e "$TMP/never" ] || fail "export --dry-run 不应创建目录"
[ ! -s "$FAKE_KUBECTL_LOG" ] || fail "dry-run 不应调用 kubectl"

CASE="export --with-vocab"
default_exports; vocab_exports
: >"$FAKE_KUBECTL_LOG"
run_script 0 export --out "$TMP/vx" --with-vocab
expect_out "$TMP/vx/api-vocab.jsonl  2 rows"
expect_out "$TMP/vx/cloud-vocab.jsonl  25 rows"
[ "$(wc -l <"$FAKE_KUBECTL_LOG")" -eq 4 ] || fail "export --with-vocab 应调用 kubectl 四次（源码×2、词汇×2）"
[ "$(grep -c -- '-d aster_cloud -v cloud=1 -f -' "$FAKE_KUBECTL_LOG")" -eq 2 ] || fail "cloud 词汇导出应带 -v cloud=1"
for f in api cloud api-vocab cloud-vocab; do
  perm="$(ls -l "$TMP/vx/$f.jsonl" | cut -c1-10)"
  [ "$perm" = "-rw-------" ] || fail "$f.jsonl 权限应为 600，实际 $perm"
done
run_script 3 export --out "$TMP/vx" --with-vocab; expect_err '已有 api.jsonl'
rm "$TMP/vx/api.jsonl" "$TMP/vx/cloud.jsonl"
run_script 3 export --out "$TMP/vx" --with-vocab; expect_err '已有 api.jsonl'   # 只剩词汇导出也拒绝覆盖
[ -f "$TMP/vx/cloud-vocab.jsonl" ] || fail "拒绝覆盖时不应删除已有导出"
run_check 1 --sources "$TMP/vx/cloud-vocab.jsonl" --sources "$TMP/vx/api-vocab.jsonl"
expect_out '^result: HITS'
rm -rf "$TMP/vx"

CASE="--with-vocab 导出截断与空导出"
head -n 3 "$CLOUD_VOCAB" >"$TMP/cv-cut.jsonl"
FAKE_CLOUD_VOCAB_JSONL="$TMP/cv-cut.jsonl" run_script 3 export --out "$TMP/vcut" --with-vocab
expect_err '应恰好有 1 行完成标记'
[ -z "$(ls -A "$TMP/vcut")" ] || fail "词汇导出截断时应删除全部部分导出"
printf '{"_count" : 0}\n' >"$TMP/empty.jsonl"
FAKE_CLOUD_VOCAB_JSONL="$TMP/empty.jsonl" run_script 3 export --out "$TMP/vempty" --with-vocab --allow-empty-api-db
expect_err 'aster_cloud 导出为 0 行'
[ -z "$(ls -A "$TMP/vempty")" ] || fail "cloud 词汇导出为空时应删除部分导出"
FAKE_API_VOCAB_JSONL="$TMP/empty.jsonl" run_script 3 export --out "$TMP/vempty" --with-vocab
expect_err 'aster_api 导出为 0 行'
FAKE_API_VOCAB_JSONL="$TMP/empty.jsonl" run_script 0 export --out "$TMP/vempty" --with-vocab --allow-empty-api-db
expect_out "api-vocab.jsonl  0 rows"
rm -rf "$TMP/vempty" "$TMP/vcut"

CASE="vocab-check 规则命中与对照"
run_check 1 --sources "$CLOUD_VOCAB" --sources "$API_VOCAB"
expect_hits 'api:d1/zh-CN/D1_trigger_keyword cloudterm:d3term/zh-CN/D3_vocab_trigger cloudv:badalias/en-US/unreadable_aliasSet cloudv:badalias2/de-DE/unreadable_aliasSet cloudv:badembedded/en-US/unreadable_embedded cloudv:badembedded2/zh-CN/unreadable_embedded cloudv:badembedded3/zh-CN/unreadable_embedded cloudv:badembedded4/zh-CN/unreadable_embedded cloudv:badvocab/de-DE/unreadable_vocabulary cloudv:d1alias/en-US/D1_trigger_aliasSet cloudv:d1en/zh-CN/D1_trigger_keyword cloudv:d1fold/en-US/D1_trigger_keyword cloudv:d1kw/zh-CN/D1_trigger_keyword cloudv:d1nfc/hi-IN/D1_trigger_keyword cloudv:d1unknown/?/D1_trigger_keyword cloudv:d3alias/de-DE/D3_aliasSet cloudv:d3hi/hi-IN/D3_vocab_trigger cloudv:d3trig/zh-CN/D3_vocab_trigger cloudv:d3value/en-US/D3_vocab_value cloudv:missing/de-DE/missing_snapshot '
! grep -q -e 'ctl_' -e ':clean ' "$TMP/out" || fail "对照记录不应命中"
expect_out '^records: cloud-policy-version=24 cloud-domain-term=1 api-policy-version=2$'
expect_out '^lexicons: en-US=10 zh-CN=8 de-DE=5 hi-IN=2 ?=2$'
expect_out '^per-rule: unreadable_aliasSet=2 unreadable_embedded=4 unreadable_vocabulary=1 missing_snapshot=1 D1_trigger_keyword=6 D1_trigger_aliasSet=1 D3_aliasSet=1 D3_vocab_trigger=3 D3_vocab_value=1$'
expect_out '^result: HITS (20 hits, 20 ids)$'

CASE="vocab-check 单个规则文件"
run_check 1 --sources "$CLOUD_VOCAB" --sources "$API_VOCAB" --rules "$HERE/vocab-rules/d3-type-alias-keyword.json"
expect_hits 'cloudterm:d3term/zh-CN/D3_vocab_trigger cloudv:badalias/en-US/unreadable_aliasSet cloudv:badalias2/de-DE/unreadable_aliasSet cloudv:badembedded/en-US/unreadable_embedded cloudv:badembedded2/zh-CN/unreadable_embedded cloudv:badembedded3/zh-CN/unreadable_embedded cloudv:badembedded4/zh-CN/unreadable_embedded cloudv:badvocab/de-DE/unreadable_vocabulary cloudv:d3alias/de-DE/D3_aliasSet cloudv:d3hi/hi-IN/D3_vocab_trigger cloudv:d3trig/zh-CN/D3_vocab_trigger cloudv:d3value/en-US/D3_vocab_value cloudv:missing/de-DE/missing_snapshot '

CASE="vocab-check 无命中"
node -e '
const fs = require("fs");
const row = { id: "cloudv:a", kind: "cloud-policy-version", lexicon: "en-US", lexiconFrom: "envelope", aliasSet: "{\"RETURN\":[\"handback\"]}",
  embedded: JSON.stringify({ v: 1, terms: [{ kind: "literal", localized: "greeting", canonical: "hi" }] }), vocabularies: [] };
fs.writeFileSync(process.argv[1], JSON.stringify(row) + "\n{\"_count\" : 1}\n");
' "$TMP/pass-vocab.jsonl"
run_check 3 --sources "$TMP/pass-vocab.jsonl"; expect_err 'api-policy-version 为 0'
run_check 0 --sources "$TMP/pass-vocab.jsonl" --allow-empty-api
expect_out '^result: PASS (0 hits)$'

CASE="vocab-check 输入错误"
run_check 2
run_check 2 --sources "$CLOUD_VOCAB" --bogus
run_check 2 --sources "$CLOUD_VOCAB" --rules "$TMP/no-such-rules.json"
run_check 3 --sources "$CLOUD_VOCAB" --sources "$CLOUD_VOCAB" --allow-empty-api; expect_err '记录 id 重复'
run_check 3 --sources "$TMP/cv-cut.jsonl" --allow-empty-api; expect_err '应恰好有 1 行完成标记'
printf '{"id":"cloud:x","kind":"cloud-policy","vocabularies":[]}\n{"_count" : 1}\n' >"$TMP/bad-kind.jsonl"
run_check 3 --sources "$TMP/bad-kind.jsonl" --allow-empty-api; expect_err '字段不合要求'
run_check 3 --sources "$TMP/empty.jsonl" --sources "$API_VOCAB"; expect_err 'cloud-policy-version 为 0'
printf '{"rules":[{"name":"X","subject":"triggers","against":"spellings"}],"spellings":{"fr-FR":["x"]}}\n' >"$TMP/bad-rules.json"
run_check 3 --sources "$CLOUD_VOCAB" --sources "$API_VOCAB" --rules "$TMP/bad-rules.json"; expect_err '未知 locale fr-FR'
printf '{"rules":[{"name":"missing_snapshot","subject":"triggers","against":"aliasSet"}]}\n' >"$TMP/bad-rules.json"
run_check 3 --sources "$CLOUD_VOCAB" --sources "$API_VOCAB" --rules "$TMP/bad-rules.json"; expect_err '保留名冲突'
default_exports

# ---------- 存量显示排版（export --with-layouts + layout-check.mjs，Wave D G5） ----------
# 合成导出：字段与 export-layouts.sql 相同；排版里的文字都带 SECRET_TEXT_ 标记或中文诗句，用来验证 layout-check
# 只打印 id / kind / lexicon / 规则名。
CLOUD_LAYOUT="$TMP/cloud-layouts.jsonl"
export FAKE_CLOUD_LAYOUT_JSONL="$CLOUD_LAYOUT"
cat >"$TMP/mklayout.mjs" <<'EOF'
import { writeFileSync } from 'node:fs';
const [out] = process.argv.slice(2);
const T = text => ({ text });
const S = (canonical, display) => ({ canonical, display });
const lay = (...spans) => JSON.stringify({ v: 1, spans });
const row = (id, lexicon, layout, o = {}) => ({ id, kind: 'cloud-policy-version-layout', lexicon,
  lexiconFrom: lexicon ? 'envelope' : null, layout, ...o });
const rows = [
  // G5a：结构 span 的 canonical 含反引号——恰为 L10 三元组形状、与空格合并（E11）、JSON 里写成 ` 转义
  row('cloudv:g5a_triple', 'zh-CN', lay(T('SECRET_TEXT_床前'), S('`', ''), T('当'), S('`', ''), T('明月光'))),
  row('cloudv:g5a_merged', 'zh-CN', lay(S(' `', ''), T('SECRET_TEXT_版本'), S('`', ''))),
  row('cloudv:g5a_escaped', 'en-US', '{"v":1,"spans":[{"canonical":"\\u0060","display":""},{"text":"SECRET_TEXT_x"}]}'),
  // G5b：结构 span 的 display 含反引号——把关键词伪装成转义名（E14）、display 恰为反引号（E13）
  row('cloudv:g5b_disguise', 'zh', lay(S('如果', '`如果`'), T(' SECRET_TEXT_x'))),
  row('cloudv:g5b_tick', 'de-DE', lay(S('wenn', '`'), T(' SECRET_TEXT_x'))),
  // 同时命中 G5a 与 G5b
  row('cloudv:g5ab', 'en-US', lay(S('`', '`'), T('SECRET_TEXT_x'), S('`', '`'))),
  // 分诊：内容 span 里的反引号（字符串 / 注释）、全角反引号在内容 / 结构 display / 结构 canonical 里
  row('cloudv:note_content', 'en-US', lay(T('Return "SECRET_TEXT_`x`".'))),
  row('cloudv:note_fw_text', 'zh-CN', lay(T('SECRET_TEXT_｀版本｀'))),
  row('cloudv:note_fw_display', null, lay(S('If', '｀若｀'), T(' SECRET_TEXT_x'))),
  row('cloudv:note_fw_canon', 'hi-IN', lay(S('｀', ' '), T('SECRET_TEXT_x'))),
  // 门禁 + 分诊
  row('cloudv:mixed', 'zh-CN', lay(S('`', ''), T('SECRET_TEXT_`当'), S('`', ''))),
  // 无法检查：不是 JSON、多余键、v≠1、spans 为空、span 多键 / 空 text / 空 canonical / display 非串
  row('cloudv:bad_json', 'en-US', '{"v":1,"spans":[SECRET_TEXT_'),
  row('cloudv:bad_keys', 'en-US', JSON.stringify({ v: 1, spans: [T('SECRET_TEXT_x')], extra: 1 })),
  row('cloudv:bad_v', 'en-US', JSON.stringify({ v: 2, spans: [T('SECRET_TEXT_x')] })),
  row('cloudv:bad_empty', 'en-US', lay()),
  row('cloudv:bad_span', 'en-US', lay({ text: 'SECRET_TEXT_x', canonical: 'a', display: 'b' })),
  row('cloudv:bad_text', 'en-US', lay(T(''))),
  row('cloudv:bad_canon', 'en-US', lay(S('', 'SECRET_TEXT_x'))),
  row('cloudv:bad_display', 'en-US', lay(S('If', null))),
  // 对照：普通排版、隐藏空格、全角的其它字符
  row('cloudv:ctl_plain', 'zh-CN', lay(T('SECRET_TEXT_床前明月光'), S('。\n', '，'), T('疑是地上霜'))),
  row('cloudv:ctl_hidden_space', 'en-US', lay(T('Return'), S(' ', ''), T('SECRET_TEXT_x.'))),
  row('cloudv:ctl_fullwidth', 'zh-CN', lay(T('SECRET_TEXT_（版本）'), S('如果', '＂若＂'))),
];
writeFileSync(out, [...rows.map(r => JSON.stringify(r)), `{"_count" : ${rows.length}}`].join('\n') + '\n');
EOF
layout_exports() { node "$TMP/mklayout.mjs" "$CLOUD_LAYOUT"; }
LAYOUT_CHECK="$HERE/layout-check.mjs"
run_layout_check() {  # 期望退出码, layout-check 参数...
  local want="$1"; shift
  local rc=0
  node "$LAYOUT_CHECK" "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "layout-check $* 期望 rc=${want}，实际 rc=${rc}"
  ! grep -q -F -e SECRET_TEXT -e '`' -e '｀' -e '当' -e '如果' -e '版本' -e 'wenn' "$TMP/out" "$TMP/err" \
    || fail "输出泄露了排版 / display / canonical 文本"
}
lines_of() { grep "^$1 " "$TMP/out" | awk '{print $2 "/" $4 "/" $5}' | sort | tr '\n' ' ' || true; }
expect_lines() { [ "$(lines_of "$1")" = "$2" ] || fail "$1 行应为 '$2'，实际 '$(lines_of "$1")'"; }

CASE="--with-layouts 用法"
run_script 2 --old-ts a --new-ts b --with-layouts
run_script 2 scan --sources "$TMP/x" --old-ts a --new-ts b --with-layouts
run_script 2 input-refs --ts a --profile p --with-layouts
run_script 0 --help; expect_out '--with-layouts'

CASE="--with-layouts dry-run"
: >"$FAKE_KUBECTL_LOG"
run_script 0 export --out "$TMP/never" --with-layouts --dry-run
expect_out "-d aster_cloud -v cloud=1 -f - < .*export-layouts.sql > .*cloud-layouts.jsonl"
! grep -q -e "-d aster_api .*export-layouts.sql" "$TMP/out" || fail "aster_api 不存排版，不应导出"
[ ! -e "$TMP/never" ] || fail "export --dry-run 不应创建目录"
[ ! -s "$FAKE_KUBECTL_LOG" ] || fail "dry-run 不应调用 kubectl"

CASE="export --with-layouts"
default_exports; layout_exports
: >"$FAKE_KUBECTL_LOG"
run_script 0 export --out "$TMP/lx" --with-layouts
expect_out "$TMP/lx/cloud-layouts.jsonl  22 rows"
[ "$(wc -l <"$FAKE_KUBECTL_LOG")" -eq 3 ] || fail "export --with-layouts 应调用 kubectl 三次（源码×2、排版×1）"
[ "$(grep -c -- '-d aster_cloud -v cloud=1 -f -' "$FAKE_KUBECTL_LOG")" -eq 2 ] || fail "cloud 排版导出应带 -v cloud=1"
for f in api cloud cloud-layouts; do
  perm="$(ls -l "$TMP/lx/$f.jsonl" | cut -c1-10)"
  [ "$perm" = "-rw-------" ] || fail "$f.jsonl 权限应为 600，实际 $perm"
done
rm "$TMP/lx/api.jsonl" "$TMP/lx/cloud.jsonl"
run_script 3 export --out "$TMP/lx" --with-layouts; expect_err '已有 api.jsonl'   # 只剩排版导出也拒绝覆盖
[ -f "$TMP/lx/cloud-layouts.jsonl" ] || fail "拒绝覆盖时不应删除已有导出"
run_layout_check 1 --sources "$TMP/lx/cloud-layouts.jsonl"
expect_out '^result: HITS'
rm -rf "$TMP/lx"
vocab_exports
: >"$FAKE_KUBECTL_LOG"
run_script 0 export --out "$TMP/lvx" --with-vocab --with-layouts
[ "$(wc -l <"$FAKE_KUBECTL_LOG")" -eq 5 ] || fail "--with-vocab --with-layouts 应调用 kubectl 五次"
expect_out "$TMP/lvx/cloud-vocab.jsonl  25 rows"
expect_out "$TMP/lvx/cloud-layouts.jsonl  22 rows"
rm -rf "$TMP/lvx"

CASE="--with-layouts 导出截断、空导出与失败"
head -n 3 "$CLOUD_LAYOUT" >"$TMP/cl-cut.jsonl"
FAKE_CLOUD_LAYOUT_JSONL="$TMP/cl-cut.jsonl" run_script 3 export --out "$TMP/lcut" --with-layouts
expect_err '应恰好有 1 行完成标记'
[ -z "$(ls -A "$TMP/lcut")" ] || fail "排版导出截断时应删除全部部分导出"
{ head -n 3 "$CLOUD_LAYOUT"; echo '{"_count" : 4}'; } >"$TMP/cl-short.jsonl"
FAKE_CLOUD_LAYOUT_JSONL="$TMP/cl-short.jsonl" run_script 3 export --out "$TMP/lcut" --with-layouts
expect_err '完成标记 4 行，实际 3 行'
[ -z "$(ls -A "$TMP/lcut")" ] || fail "排版导出行数不符时应删除全部部分导出"
FAKE_CLOUD_LAYOUT_JSONL="$TMP/empty.jsonl" run_script 0 export --out "$TMP/lempty" --with-layouts
expect_out "cloud-layouts.jsonl  0 rows"
run_layout_check 3 --sources "$TMP/lempty/cloud-layouts.jsonl"; expect_err '排版记录为 0'
run_layout_check 0 --sources "$TMP/lempty/cloud-layouts.jsonl" --allow-empty
expect_out '^records: cloud-policy-version-layout=0$'
expect_out '^result: PASS (0 hits, 0 notes)$'
rm -rf "$TMP/lempty"
# 源码导出（cloud）为空时整个导出失败：排版的 0 行放行依赖它证明连对了库
jsonl "$CLOUD"
run_script 3 export --out "$TMP/lempty" --with-layouts --allow-empty-api-db; expect_err 'aster_cloud 导出为 0 行'
[ -z "$(ls -A "$TMP/lempty")" ] || fail "cloud 源码导出为空时应删除部分导出"
default_exports
FAKE_KUBECTL_FAIL=1 run_script 3 export --out "$TMP/lfail" --with-layouts
[ -z "$(ls -A "$TMP/lfail")" ] || fail "kubectl 失败时应删除部分导出"
rm -rf "$TMP/lempty" "$TMP/lcut" "$TMP/lfail"

CASE="export-layouts.sql 形状"
SQL_LAYOUTS_FILE="$HERE/export-layouts.sql"
grep -q 'BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;' "$SQL_LAYOUTS_FILE" || fail "排版导出必须在 READ ONLY 事务里"
grep -q "json_build_object('_count', count(\*))" "$SQL_LAYOUTS_FILE" || fail "排版导出必须带 _count 完成标记"
grep -q 'RAISE EXCEPTION' "$SQL_LAYOUTS_FILE" || fail "不带 -v cloud=1 时排版导出必须报错"
# 输出键只能是 id / kind / lexicon / lexiconFrom / layout（content 只出现在 envelope 重算里，形如 ->>'content'）
! grep -q -E "(^|[[:space:](,])'(content|source)'[[:space:]]*," "$SQL_LAYOUTS_FILE" || fail "排版导出不得输出源码列"
grep -q "'layout', ver.layout" "$SQL_LAYOUTS_FILE" || fail "排版导出应输出 layout 原文"

CASE="layout-check 规则命中与对照"
run_layout_check 1 --sources "$CLOUD_LAYOUT"
expect_lines hit 'cloudv:bad_canon/en-US/unreadable_layout cloudv:bad_display/en-US/unreadable_layout cloudv:bad_empty/en-US/unreadable_layout cloudv:bad_json/en-US/unreadable_layout cloudv:bad_keys/en-US/unreadable_layout cloudv:bad_span/en-US/unreadable_layout cloudv:bad_text/en-US/unreadable_layout cloudv:bad_v/en-US/unreadable_layout cloudv:g5a_escaped/en-US/G5a_structural_backtick cloudv:g5a_merged/zh-CN/G5a_structural_backtick cloudv:g5a_triple/zh-CN/G5a_structural_backtick cloudv:g5ab/en-US/G5a_structural_backtick cloudv:g5ab/en-US/G5b_display_backtick cloudv:g5b_disguise/zh-CN/G5b_display_backtick cloudv:g5b_tick/de-DE/G5b_display_backtick cloudv:mixed/zh-CN/G5a_structural_backtick '
expect_lines note 'cloudv:mixed/zh-CN/content_backtick cloudv:note_content/en-US/content_backtick cloudv:note_fw_canon/hi-IN/fullwidth_backtick cloudv:note_fw_display/?/fullwidth_backtick cloudv:note_fw_text/zh-CN/fullwidth_backtick '
! grep -q 'ctl_' "$TMP/out" || fail "对照记录不应命中"
expect_out '^records: cloud-policy-version-layout=22$'
expect_out '^lexicons: en-US=12 zh-CN=7 de-DE=1 hi-IN=1 ?=1$'
expect_out '^per-rule: unreadable_layout=8 G5a_structural_backtick=5 G5b_display_backtick=3 content_backtick=2 fullwidth_backtick=3$'
expect_out '^result: HITS (16 hits, 15 ids, 5 notes)$'

CASE="layout-check 只有分诊项时退出 0"
grep -e note_ -e ctl_ "$CLOUD_LAYOUT" >"$TMP/notes-layouts.jsonl"
echo "{\"_count\" : $(wc -l <"$TMP/notes-layouts.jsonl" | tr -d ' ')}" >>"$TMP/notes-layouts.jsonl"
run_layout_check 0 --sources "$TMP/notes-layouts.jsonl"
expect_lines note 'cloudv:note_content/en-US/content_backtick cloudv:note_fw_canon/hi-IN/fullwidth_backtick cloudv:note_fw_display/?/fullwidth_backtick cloudv:note_fw_text/zh-CN/fullwidth_backtick '
expect_out '^result: PASS (0 hits, 4 notes)$'

CASE="layout-check 输入错误"
run_layout_check 2
run_layout_check 2 --sources "$CLOUD_LAYOUT" --bogus
run_layout_check 3 --sources "$TMP/no-such.jsonl"; expect_err '不存在'
run_layout_check 3 --sources "$CLOUD_LAYOUT" --sources "$CLOUD_LAYOUT"; expect_err '记录 id 重复'
run_layout_check 3 --sources "$TMP/cl-cut.jsonl"; expect_err '应恰好有 1 行完成标记'
run_layout_check 3 --sources "$TMP/cl-short.jsonl"; expect_err '与实际行数 3 不符'
printf '{"id":"cloudv:x","kind":"cloud-policy-version","layout":"{}"}\n{"_count" : 1}\n' >"$TMP/bad-layout-row.jsonl"
run_layout_check 3 --sources "$TMP/bad-layout-row.jsonl"; expect_err '字段不合要求'
printf '{"id":"api:x","kind":"cloud-policy-version-layout","layout":"{}"}\n{"_count" : 1}\n' >"$TMP/bad-layout-row.jsonl"
run_layout_check 3 --sources "$TMP/bad-layout-row.jsonl"; expect_err '字段不合要求'
printf '{"id":"cloudv:x","kind":"cloud-policy-version-layout","layout":null}\n{"_count" : 1}\n' >"$TMP/bad-layout-row.jsonl"
run_layout_check 3 --sources "$TMP/bad-layout-row.jsonl"; expect_err '字段不合要求'
default_exports

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
