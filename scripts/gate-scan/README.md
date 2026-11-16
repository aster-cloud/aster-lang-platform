# 发布列车门槛扫描（gate scan）

在每次引擎发布列车（train）**之前**运行：把生产库里的全部策略源码分别用「当前已发布」与「候选」两个
aster-lang-ts 构建编译一遍，报告编译结论发生变化的策略。报告为空才说明候选版本不会改变任何生产策略的行为。

| 文件 | 作用 |
| --- | --- |
| `gate-scan.sh` | 入口：一体化（缺省），或分步 `export` / `scan`；`input-refs` 子命令 |
| `export-policy-sources.sql` | 只读导出（READ ONLY 事务），输出 JSONL `{id, kind, content}`，末行完成标记 `{"_count" : N}` |
| `export-profile-impact.sql` | `input-refs` 用：cloud 库每个源的租户与近 30 天需审批执行数；aster_api 库的签名事实签发方（不含公钥） |
| `export-profile-ids.sql` | `input-refs` 用：cloud 库中源码头部声明了档案的 id（独立于编译器的对账集合） |
| `scan.mjs` | 比较两个 ts 构建上的诊断码集合，只打印 id / kind / lexicon / 诊断码 |
| `input-refs.mjs` | 列出档案模块每条 Verdict 规则的 `inputRefs`，标出 `*` / `""`，合入影响面并对账 |
| `common.mjs` | `scan.mjs` 与 `input-refs.mjs` 共用：构建 / lexicon 加载、静默编译、导出校验、源计数 |
| `gate-scan.test.sh` | 本地回归测试（假 kubectl + 假 ts 构建，不连集群；可选真实构建端到端） |
| `java-gate/` | 补充扫描：Java 生产编译路径（aster-api InProcessCnlParser + TypeChecker）旧引擎 vs 新引擎，含 Core IR 差异，见下文 |
| `ir-diff.mjs` | 补充扫描：两个 ts 构建上 `compileAndTypecheck` 的结论、类型诊断与规范 Core IR 差异 |
| `regex-scan.mjs` | 补充扫描：按规则文件对导出逐行跑 PCRE 预筛，只打印 id / kind / 规则名 |
| `corpus-to-jsonl.mjs` | 把 aster-lang-test 语料写成导出格式，供补充扫描在不碰生产数据的前提下自测 |

## 何时运行

- 每次发布列车前，候选 aster-lang-ts（或包含它的版本计划）确定之后。
- 任何会收紧解析 / 降级规则的修复（如 #250 降低类型嵌套上限）在合并前，用 `--code` 确认生产里没有命中。

## 前置条件

- **导出端**：对生产集群有 kubectl 访问权（能 `kubectl exec` 进 `data-services/shared-postgres-1`），可用 `--kube-context` 指定 context。只需 bash + kubectl，不需要 Node。
- **扫描端**：Node 24（含 corepack），如 `export PATH=/opt/homebrew/opt/node@24/bin:$PATH`；aster-lang-ts 克隆路径用环境变量
  `ASTER_TS_REPO` 指定，缺省为本仓库同级目录 `../aster-lang-ts`。
- `--old-ts` / `--new-ts` 的写法：
  - git ref（tag / 分支 / commit）：脚本 `git fetch origin`（分支优先取 `origin/<分支>`），在临时目录建 detached worktree，
    `corepack pnpm install --frozen-lockfile && corepack pnpm run build`（每个 ref 约 15 秒到数分钟）；
  - 本地已构建目录：**必须**写成 `path:<目录>`，或以 `/`、`./`、`../` 开头（仓库根或 `dist` 都行）。其余一律当作 git ref，
    避免目录名与分支名混淆。

## 示例

### 一体化（kubectl 与 Node 在同一台机器）

#250（类型嵌套上限降到 64）：确认没有生产策略在 1.4.0 上不报 E054、在候选分支上报 E054：

```bash
scripts/gate-scan/gate-scan.sh --old-ts v1.4.0 --new-ts fix/250-type-nesting-guard --code E054
```

常规列车：比较当前已发布版本与列车候选上的全部诊断码变化：

```bash
scripts/gate-scan/gate-scan.sh --old-ts v1.4.0 --new-ts main --kube-context <prod-context>
```

### 单机（已验证的本地配置）

整套流程可以在一台 Mac 上跑完，不需要 master-1 上的 checkout：

```bash
export PATH=/opt/homebrew/opt/node@24/bin:$PATH     # Node 24 必须在 PATH 最前
export ASTER_TS_REPO=~/IdeaProjects/aster-lang-ts    # git ref 模式需要
export KUBECONFIG=<集群 kubeconfig 路径>             # 本机直连集群
scripts/gate-scan/gate-scan.sh --old-ts v1.4.0 --new-ts main --allow-empty-api-db
```

没有本机 kubeconfig、只能 ssh 到 master-1 时，加 `--ssh-host root@master-1`：kubectl 经 `ssh -o BatchMode=yes` 在远端执行
（参数逐个转义，导出 SQL 走 stdin；需要免密登录，不会弹口令提示）。
`kubectl` 与 `--kube-context` 都按**远端**主机的 PATH / kubeconfig 解析，不是本机的。传给远端的值（context、namespace、pod、库名）
不得含控制字符，且远端登录 shell 须为 bash / zsh（用 bash 的 `%q` 转义，POSIX sh 不认其输出）；含 `;`、`$()`、引号等元字符的值会被原样当作单个参数。

注意：`aster_api` 在生产里目前没有任何 `policy_versions`（0 行），所以现阶段 `--allow-empty-api-db` 是预期用法，直到有保存的版本为止。
`--allow-empty-api-db` 只放行 **aster_api** 为空；cloud 库导出 0 行一律是退出码 3（那只可能是 context / pod / 库名错了）。
扫描开头打印按 kind 的源计数 `sources: cloud-policy=N cloud-policy-version=M api-policy-version=K`，贴结果时一并贴上。
旧旗标 `--allow-empty-db`（放行任一单边为空，两库合计 0 行仍为 3）为向后兼容保留在 diff 扫描与 `export` 中，不再推荐；
`input-refs` 不接受它（退出码 2）。

### 分步（kubectl 在 master-1，Node / ts 在本机）

```bash
# 1. 在 master-1 上导出（只需 kubectl；目录自动以 700 创建，文件 600）
ssh master-1 'cd aster-lang-platform && scripts/gate-scan/gate-scan.sh export --out /tmp/gate-scan-export'
#    输出：两个文件的路径与行数（不含内容）

# 2. 拷到本机（本机目标目录先建好并收紧权限），随即删除 master-1 上的那份
mkdir -m 700 ~/gate-scan-export
scp 'master-1:/tmp/gate-scan-export/*.jsonl' ~/gate-scan-export/ && chmod 600 ~/gate-scan-export/*.jsonl
ssh master-1 'rm -rf /tmp/gate-scan-export'

# 3. 在本机扫描；结束时（成功或失败）自动删除 ~/gate-scan-export 下的导出及空目录
scripts/gate-scan/gate-scan.sh scan --sources ~/gate-scan-export \
  --old-ts v1.4.0 --new-ts fix/250-type-nesting-guard --code E054
```

`scan` 加 `--keep` 可保留导出（例如要对多个候选连续扫描）——用完务必手工删除。`export` 拒绝覆盖已存在的导出文件，
导出失败时删除已写的部分文件；目标位置已有文件或符号链接（含悬空链接）同样拒绝，不会写穿链接。

先看会执行什么（不构建、不连集群、不删文件）：加 `--dry-run`。其它选项见 `--help`
（`--namespace`、`--pod`、`--api-db`、`--cloud-db`，缺省 `data-services` / `shared-postgres-1` / `aster_api` / `aster_cloud`）。

## 如何读结果

```
sources: cloud-policy=3 cloud-policy-version=1 api-policy-version=57
gate scan: old=1.4.0 (…/ts-old/dist)
           new=1.4.0 (…/ts-new/dist)
mode: code E054 (absent on old, present on new)
lexicons tried (old): en-US, zh-CN, de-DE, hi-IN
scanned: 61 (api-policy-version=57, cloud-policy=3, cloud-policy-version=1)
old compiles: 232 ok, 0 threw, 12 not ok / 244 compiles
new compiles: 224 ok, 0 threw, 20 not ok / 244 compiles
throws-on-new: 0
lexicons-missing-in-new: 0
gains-E054: 1
  cloud:abc123 [cloud-policy] en-US old={} new={E054}!; zh-CN old={} new={E054}!
result: FAIL (1 reported)
```

- 报告行：策略 id（前缀 `api:` = aster-api `policy_versions.id`，`cloud:` = aster-cloud `"Policy".id`，
  `cloudv:` = `"PolicyVersion".id`）、kind，然后是**有差异的** lexicon 及新旧诊断码集合；集合后的 `!` 表示该边编译失败。
- `old compiles` / `new compiles`：每个构建上（源 × lexicon）的编译次数统计。`threw` 应为 0。
- 报告组（任一组非空即 FAIL）：
  - `throws-on-new`：新版 `compile()` 在某个 lexicon 下抛异常——无论旧版如何都要处理；
  - `lexicons-missing-in-new`：旧版有、新版没有的 lexicon（新版多出的 lexicon 只在开头 WARNING 行提示）；
  - 不带 `--code`：
    - `newly-failing`：某个对比 lexicon 下旧版成功、新版失败——**升级后会坏，必须处理**；
    - `newly-passing`：旧版失败、新版成功——通常是预期的修复，确认即可；
    - `changed-codes`：成败不变但诊断码集合变了（含警告码）——逐个确认是否预期；
  - 带 `--code X`：`gains-X`：某个对比 lexicon 下旧版无 X、新版有 X。
- 退出码：`0` 报告为空（通过）；`1` 有报告项（需人工确认）；`2` 用法错误；
  `3` 环境 / 构建 / 导出 / 扫描失败——包括：kubectl 或 psql 失败、aster_api 导出为 0 行（`--allow-empty-api-db` 可放行）、
  cloud 导出为 0 行（只有旧旗标 `--allow-empty-db` 能放行）、完成标记缺失或与行数不符（导出被截断）、JSONL 损坏、
  金丝雀源在某个构建上编译失败（构建损坏）、两个库合计 0 行、scan.mjs 没有输出 `result:` 行、任何意外命令失败
  （含脚本未经正常退出路径中止——macOS 自带 bash 3.2 下这类中止原本会以 0 退出）。**只有退出码 0 才算通过。**
- **退出码 1 但没有 `result:` 行 = 脚本崩溃（如 bash / node 自身出错），不是「有报告项」。** 真正的「有报告项」一定以
  `result: FAIL (N reported)` 结尾；没有这一行的 1 一律当作失败处理，先看 stderr。
- 诊断码取自 ts `compile()` 返回的 `parseErrors`、`loweringDiagnostics`、`resolutionDiagnostics`（规范化为大写）；
  只有无码的 `loweringErrors` 时记为 `UNCODED`，`compile()` 抛异常记为 `THROW`，新版缺 lexicon 记为 `NO_LEXICON`。不含类型检查阶段。

### lexicon 规则

生产库不存策略的语言，因此对每份源尝试**旧版**构建的全部 lexicon（顺序 en-US、zh-CN、de-DE，其后按名称排序的其余语言），
新版用同名 lexicon（新版缺失即视为编译失败）：

- 旧版编译成功的**每一个** lexicon 都参与对比，任一个出现差异即报告；
- 旧版在所有 lexicon 下都失败时，只对比一个选定的 lexicon：新版编译成功的第一个（让「新版才通过」可见）→
  旧版通过解析阶段（失败在名称解析 / 降级）的第一个 → 第一个（en-US）。

### 防止假通过

- 启动时在两个构建上各编译一份已知可编译的金丝雀源，失败即退出码 3（避免「两边都抛异常 → 诊断码相同 → PASS」）。
- 导出的完成标记与源行出自同一条 SQL 语句（同一快照）；脚本（bash 侧）与 scan.mjs 都校验标记与行数一致。

## input-refs：档案模块的规则输入引用（ADR 0046 §11.4 ⑦ 翻转前扫描）

把 `eu-ai-act-high-risk.requires.verifiedInputs` 翻为 `true`（registry 1.3.0）之前，列出生产里每个声明该档案的模块、
每条 Verdict 规则的 `inputRefs`，作为 X4 计划 G3「生产可验证性台账」的输入。只需一个 aster-lang-ts 构建，且必须 ≥ 1.5.0
（Core IR 写 `Func.inputRefs`）。

### 用法（P2，单机，已验证的本地配置）

```bash
export PATH=/opt/homebrew/opt/node@24/bin:$PATH
export ASTER_TS_REPO=~/IdeaProjects/aster-lang-ts KUBECONFIG=~/.kube/k3s-config
scripts/gate-scan/gate-scan.sh input-refs --ts v1.5.0 --profile eu-ai-act-high-risk --allow-empty-api-db
# 子命令内部依次导出 export-policy-sources / export-profile-impact / export-profile-ids，并自动传 --impact 与 --profile-ids
```

一体化模式共导出五份（aster_api：源码、签发方；aster_cloud：源码、影响面、对账集合），全部写在 `umask 077` 的临时目录里，
退出即删。没有本机 kubeconfig 时加 `--ssh-host root@master-1`（同上文）。

分步：kubectl 主机上 `gate-scan.sh export --out <dir> --with-input-refs --allow-empty-api-db`（另写
`api-impact.jsonl`、`cloud-impact.jsonl`、`profile-ids.jsonl`），搬到扫描机后：

```bash
scripts/gate-scan/gate-scan.sh input-refs --sources <dir> --ts v1.5.0 --profile eu-ai-act-high-risk --allow-empty-api-db \
  --impact <dir>/api-impact.jsonl --impact <dir>/cloud-impact.jsonl --profile-ids <dir>/profile-ids.jsonl
```

结束时删除 `<dir>` 下的 `api.jsonl` / `cloud.jsonl`（`--keep` 除外）；另外三份只含 id / 租户 / 计数，用完手工删除。
不给 `--profile-ids` 时打印 `reconcile: SKIPPED`，**这样的结果不能用于 G3**。

### 输出

```
sources: cloud-policy=2 cloud-policy-version=1 api-policy-version=0
input-refs scan: ts=1.5.0 (…/ts-ts/dist)
profile: eu-ai-act-high-risk (verifiedInputs forced true on registry 1.2.0)
lexicons tried: en-US, zh-CN, de-DE, hi-IN
compile-failed: 0
input-refs: 2
  cloud:abc kind=cloud-policy lexicon=en-US module=credit.pilot rule=decide inputRefs=["context.amount"] flags=- construct=- tenant=team-a gatedExecutions30d=3 tenantHasEnabledIssuer=yes
  cloudv:def kind=cloud-policy-version lexicon=en-US module=credit.pilot rule=decide inputRefs=["*"] flags=STAR construct=dynamic-map-key tenant=user-b gatedExecutions30d=0 tenantHasEnabledIssuer=no
modules-without-verdict-rules: 0
modules: 2
rules: 2
star-rules: 1 (dynamic-map-key=1)
whole-input-serialized: 0
root-rules: 0
tenants: 2 (without enabled issuer: 1)
reconcile: sql=3 scan=3 onlyInSql=[] onlyInScan=[]
result: STAR (1 STAR rules)
```

- 每份源依 en-US → zh-CN → de-DE → 其余的顺序取第一个编译成功的 lexicon；只报告 Core IR `profile` 等于 `--profile` 的模块。
  编译时注入「该档案 `verifiedInputs` 置 true」的注册表副本，`construct` 取同一规则 E708 诊断的参数。
- `flags`：`STAR` = `inputRefs` 含 `*`（静态不可知，翻转后 E708）；`ROOT` = 含 `""`（读整个输入）；`-` = 都不含。
- `whole-input-serialized` 单列（ADR 0046 §11.6 第 16 条 / §11.7 第 13 条的裁定依据）。
- `tenant` = 策略的 `teamId`（个人策略为 `userId`）；`gatedExecutions30d` = 近 30 天 `decision` 为 `require_approval` /
  `escalate` 的执行数（`cloudv:` 只计该版本）；`tenantHasEnabledIssuer` = 该租户在 aster-api 有启用且未过 `notAfter` 的签发方。
- `compile-failed`：所有 lexicon 下都编译失败的源 id；`modules-without-verdict-rules`：声明了档案但没有 Verdict 规则的模块。
- `reconcile`：`export-profile-ids.sql` 按源码头部正则（四个 lexicon 的档案关键字后跟引号）选出的 id 集合，与本扫描
  「任一 lexicon 编译成功且 Core IR `profile` 非空」的 id 集合逐 id 比较。不等的常见原因是源码用自定义关键词别名写档案、
  或源码编译失败（同时出现在 `compile-failed`）；两者都要在台账里逐 id 说明后修正对账集合重跑，不得口头放行。

### 退出码与防止假通过

| 退出码 | 含义 |
| --- | --- |
| `0` | 无 `STAR` 规则 |
| `1` | 有 `STAR` 规则（逐条裁定：先改源码，或归入台账 (b) / (c)） |
| `2` | 用法错误（含 `--allow-empty-db`） |
| `3` | 输入或构建不可信：导出失败 / 截断 / 损坏、cloud 导出为 0 行、未放行的 aster_api 为 0 行、影响面缺少某个档案模块、金丝雀失败（构建 < 1.5.0 或注册表注入无效）、构建的注册表没有该档案、没有 `result:` 行 |
| `4` | 对账不等（G3 不通过） |

- 金丝雀：启动时编译两份声明 `--profile` 的已知模块——字面路径规则的 IR 必须带 `inputRefs ["context.amount"]`（否则构建低于 1.5.0），
  动态 Map 键规则必须报 E708 `dynamic-map-key`（否则注入的注册表没生效，`construct` 不可信）。
- 退出码 3 或 4 的结果不进入台账，先修导出或对账。

## 补充扫描（引擎改动可能改变 IR，或只影响 Java 侧时）

标准扫描只比较 ts `compile()` 的诊断码：看不见 Core IR 的变化，也看不见生产实际走的 Java 编译路径。aster-lang-core 的改动、
或任何可能「诊断不变、IR 变了」的改动（标识符改名、规范化器改动、新 IR 节点），在标准扫描之外再跑下面三项。
它们都只读导出文件（标准扫描加 `--keep` 保留导出），用完照常删除导出。

### Java 门禁（`java-gate/`）

生产编译走 aster-api 的 `InProcessCnlParser`（replay 模块）+ core 的 `TypeChecker`。门禁在一个 JVM 里给旧、新引擎各建一个
隔离的 `URLClassLoader`（各自的 replay + core + truffle + 语言包），每份源在 en-US / zh-CN / de-DE / hi-IN 下各编译一次。

```bash
# 1. 每侧准备一个工作区：aster-api 检出，同级目录放好该侧的 aster-lang-core / -runtime / -truffle / -validation / -hi / -locales
#    （aster-api 的 settings.gradle 会 composite 替换它们），然后构建 classpath（不改 aster-api 仓的文件）
scripts/gate-scan/java-gate/java-gate.sh classpath --api ~/wt-gate-x/old/aster-api --out ~/wt-gate-x/old.cp
scripts/gate-scan/java-gate/java-gate.sh classpath --api ~/wt-gate-x/new/aster-api --out ~/wt-gate-x/new.cp

# 2. 标准扫描保留导出并留下输出，Java 门禁用它做对账
scripts/gate-scan/gate-scan.sh scan --sources "$D" --keep --old-ts <旧> --new-ts <新> > ts-scan.txt
scripts/gate-scan/java-gate/java-gate.sh scan --old-cp ~/wt-gate-x/old.cp --new-cp ~/wt-gate-x/new.cp \
  --sources "$D/api.jsonl" --sources "$D/cloud.jsonl" --ts-scan ts-scan.txt
```

需要 JDK 25（`JAVA_HOME`，macOS 上缺省用 `java_home -v 25`）。分组：

| 分组 | 含义 | 处理 |
| --- | --- | --- |
| `newly-failing` / `newly-failing-E064` | 旧版成功、新版失败（E064(',') 单列） | 必须处理 |
| `throws` | 新版抛异常 | 必须处理 |
| `changed-codes` | 成败不变、诊断码集合变了 | 逐个确认 |
| `ir-changed-other` | 两侧都成功但 IR 有非列差异（改名、结构变化） | 逐个确认，改名类要核对请求输入字段 |
| `ir-changed-cols-only` | IR 只在 `origin.*.col` 上不同 | 逐个确认（见下面「列抖动」） |
| `newly-passing` / `ir-changed-expected` / `e064-prefilter-hits` | 信息项 | 确认即可 |

退出码：`0` PASS；`1` REVIEW；`2` 用法错误；`3` 环境错误或结果不可信——只有 0 算通过。以下情况一律是 3：

- **语言包预检失败**：任一侧没注册全部四个 lexicon。core 的 `LexiconRegistry` 经线程上下文类加载器（TCCL）上的 SPI 发现
  zh / de / hi 语言包，门禁在每次反射调用前把 TCCL 设成该侧的类加载器。没设 TCCL 时只有 en-US：zh-CN / de-DE 全部 UNCODED
  失败、hi-IN 静默回退 en-US——2026-11-17 之前本地的 Java 门禁一直如此，只扫过 en-US。
- **与 ts 扫描对账失败**（`--ts-scan` 或 `--ts-old-sources-ok`）：Java 与 ts「旧版在任一 lexicon 下能编译的源数」差距超过
  `--max-gap-pct`（缺省 5%）。按源计而不按「源 × lexicon」计：Java 的 zh / de / hi 词法表回退 en-US，英文源在四个 lexicon 下
  都能编译，逐 lexicon 的成功数两边天然不同（2026-11-17 生产：Java 344 vs ts 269 / 440，按源计两边都是 110 / 110）。
- classpath 文件或其中任一条目不存在（`URLClassLoader` 会静默跳过缺失条目）、金丝雀源编译失败、导出完成标记缺失或不符。

调用引擎期间 `System.out` / `System.err` 指向空流，报告只含 id / kind / lexicon / 诊断码 / IR 键路径。

**列抖动（aster-lang-core#281 之前）**：core 1.0.49 及更早的 `DynamicLexicon` 用 `Map.copyOf` 存关键词，遍历顺序随 JVM 进程变化；
zh-CN 的「包含」同时是 TYPE_WITH 与 TYPE_HAS 的拼写，规范化时随机成 `with` 或 `has`，「包含」之后同一行的 IR 列差 1。
两侧引擎各自随机，所以含「包含」的 zh 源会时有时无地出现在 `ir-changed-cols-only`（2026-11-17 生产 4 个 id，同一对
classpath 连跑两次一次 PASS 一次 REVIEW）。旧引擎早于修复时，`ir-changed-cols-only` 里只有 zh-CN、重跑后消失或出现的条目
按此归类；不能确定时用元数据探针比较同一引擎多个 JVM 进程下的「去列哈希」（不打印源码）。

### ts ir-diff（`ir-diff.mjs`）

```bash
node scripts/gate-scan/ir-diff.mjs --old <ts 构建> --new <ts 构建> \
  --sources "$D/api.jsonl" --sources "$D/cloud.jsonl" --allow-empty-api
```

旧版成功的每个 lexicon 上比较新版的 `compileAndTypecheck`：`newly-failing*`、`throws-on-new`、`typecheck-new-errors` 需复核
（退出码 1），`ir-changed`（只列 IR 键名）、`typecheck-changed`、`e064-prefilter-hits` 为信息项。复用本目录的 `common.mjs`。

### 正则预筛（`regex-scan.mjs`）

```bash
node scripts/gate-scan/regex-scan.mjs --rules rules.txt --sources "$D/api.jsonl" --sources "$D/cloud.jsonl"
```

规则文件每条两行：`# <规则名> <说明>` + 下一行 PCRE（规则名只含字母、数字、下划线）。规则取自该改动的 ADR / PR 列出的风险写法
（如 ADR 0056 修订 A3 §6）。匹配交给系统 perl 逐行执行（与 `grep -P` 同语义），输出 `hit <id> <kind> <规则名>`；
命中只是预筛，要与 Java / ts 的 IR 差异交叉核对。退出码 0 无命中、1 有命中、2 用法错误、3 规则 / 导出损坏或 perl 失败。

### 先自测再信任生产结果

每轮补充扫描先在 aster-lang-test 语料上跑一遍，再为本轮每个风险各写一份合成源，确认每个风险都能被检出：

```bash
node scripts/gate-scan/corpus-to-jsonl.mjs ~/IdeaProjects/aster-lang-test /tmp/corpus-export   # cloud.jsonl + 空 api.jsonl
```

## 数据处理

- SQL 在 `READ ONLY` 事务里执行，不写任何库；脚本不读取任何密钥（签发方导出不含公钥），依赖操作者已有的 kubectl 权限。
- 一体化模式：导出与构建只在 `umask 077` 的 `mktemp -d` 临时目录里，`trap … EXIT` 删除整个目录并 prune 临时 worktree。
  所有正常退出路径以及 INT / TERM / HUP 信号都会清理；SIGKILL（`kill -9`）或断电无法清理，此时手工删除
  `${TMPDIR:-/tmp}/gate-scan.*` 并在 aster-lang-ts 里 `git worktree prune`。
- 分步模式：导出文件以 600 权限写入 `--out`；`scan` 结束时删除 `--sources` 下的导出（`--keep` 除外）。
  导出端的那份需要按上面的步骤手工删除——**两台机器上都不要留导出**。
- `compile()` 期间屏蔽 console 与 stdout / stderr，输出只含 id、kind、lexicon 与诊断码（`input-refs` 另有模块名、规则名、
  引用路径、租户 id 与计数），**从不打印源码内容**；扫描结果可以直接贴到 issue / PR。

## 测试

```bash
bash scripts/gate-scan/gate-scan.test.sh   # 假构建 + 假 kubectl，覆盖各分组、各失败路径、分步往返
GATE_SCAN_OLD_TS=<v1.4.0 构建> GATE_SCAN_NEW_TS=<fix/250 构建> bash scripts/gate-scan/gate-scan.test.sh   # 加真实构建
```

真实构建部分用合成源（类型嵌套深度 2/64/65/300），期望 depth65、depth300 被报告。

```bash
GATE_SCAN_TS_150=<v1.5.0 构建> GATE_SCAN_TS_140=<v1.4.0 构建> bash scripts/gate-scan/gate-scan.test.sh   # input-refs 真实构建
```

input-refs 真实构建部分编译字面路径、动态 Map 键、`Profile "governed"` 三份源，期望恰两行、动态键行 `flags=STAR construct=dynamic-map-key`；
1.5.0 之前的构建期望退出码 3。

```bash
bash scripts/gate-scan/java-gate/java-gate.test.sh   # Java 门禁 + regex-scan + corpus-to-jsonl（CI 中运行）
JAVA_GATE_OLD_CP=<old.cp> JAVA_GATE_NEW_CP=<new.cp> JAVA_GATE_CORPUS=<aster-lang-test 根> bash scripts/gate-scan/java-gate/java-gate.test.sh
```

Java 门禁测试用 `java-gate/test/stub-engine` 的最小桩引擎（同名的 InProcessCnlParser / TypeChecker / CoreIrJson /
LexiconRegistry，语言包经 TCCL 上的 SPI 发现，每个语言包一个 jar），覆盖：各分组（含只在 zh / de / hi 下出现的差异、
只差列的 IR）、PASS、缺 zh 语言包 jar（退出码 3）、classpath 条目缺失、导出截断、与 ts 对账通过 / 差距过大、用法错误，
并检查桩引擎故意打到 stdout / stderr / JUL 的源码不会出现在输出里。Worker 依赖的 Jackson 按固定版本与 SHA-256 从 Maven Central
下载（`JAVA_GATE_JACKSON_DIR` 可指向已下载的目录）。
