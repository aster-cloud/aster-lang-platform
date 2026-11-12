# 发布列车门槛扫描（gate scan）

在每次引擎发布列车（train）**之前**运行：把生产库里的全部策略源码分别用「当前已发布」与「候选」两个
aster-lang-ts 构建编译一遍，报告编译结论发生变化的策略。报告为空才说明候选版本不会改变任何生产策略的行为。

| 文件 | 作用 |
| --- | --- |
| `gate-scan.sh` | 入口：一体化（缺省），或分步 `export` / `scan` |
| `export-policy-sources.sql` | 只读导出（READ ONLY 事务），输出 JSONL `{id, kind, content}`，末行完成标记 `{"_count" : N}` |
| `scan.mjs` | 比较两个 ts 构建上的诊断码集合，只打印 id / kind / lexicon / 诊断码 |
| `gate-scan.test.sh` | 本地回归测试（假 kubectl + 假 ts 构建，不连集群） |

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
scripts/gate-scan/gate-scan.sh --old-ts v1.4.0 --new-ts main --allow-empty-db
```

没有本机 kubeconfig、只能 ssh 到 master-1 时，加 `--ssh-host root@master-1`：kubectl 经 `ssh -o BatchMode=yes` 在远端执行
（参数逐个转义，导出 SQL 走 stdin；需要免密登录，不会弹口令提示）。
`kubectl` 与 `--kube-context` 都按**远端**主机的 PATH / kubeconfig 解析，不是本机的。传给远端的值（context、namespace、pod、库名）
不得含控制字符，且远端登录 shell 须为 bash / zsh（用 bash 的 `%q` 转义，POSIX sh 不认其输出）；含 `;`、`$()`、引号等元字符的值会被原样当作单个参数。

注意：`aster_api` 在生产里目前没有任何 `policy_versions`（0 行），所以现阶段 `--allow-empty-db` 是预期用法，直到有保存的版本为止。
`--allow-empty-db` 只放行**单边**为空：两个库合计 0 行（云端导出也为空）仍是退出码 3，因为那只可能是 context / pod / 库名错了。

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
  `3` 环境 / 构建 / 导出 / 扫描失败——包括：kubectl 或 psql 失败、任一库导出为 0 行（`--allow-empty-db` 可放行）、
  完成标记缺失或与行数不符（导出被截断）、JSONL 损坏、金丝雀源在某个构建上编译失败（构建损坏）、
  两个库合计 0 行（即使加了 `--allow-empty-db`）、scan.mjs 没有输出 `result:` 行、任何意外命令失败。**只有退出码 0 才算通过。**
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

## 数据处理

- SQL 在 `READ ONLY` 事务里执行，不写任何库；脚本不读取任何密钥，依赖操作者已有的 kubectl 权限。
- 一体化模式：导出与构建只在 `umask 077` 的 `mktemp -d` 临时目录里，`trap … EXIT` 删除整个目录并 prune 临时 worktree。
  所有正常退出路径以及 INT / TERM / HUP 信号都会清理；SIGKILL（`kill -9`）或断电无法清理，此时手工删除
  `${TMPDIR:-/tmp}/gate-scan.*` 并在 aster-lang-ts 里 `git worktree prune`。
- 分步模式：导出文件以 600 权限写入 `--out`；`scan` 结束时删除 `--sources` 下的导出（`--keep` 除外）。
  导出端的那份需要按上面的步骤手工删除——**两台机器上都不要留导出**。
- `compile()` 期间屏蔽 console 与 stdout / stderr，输出只含 id、kind、lexicon 与诊断码，**从不打印源码内容**；
  扫描结果可以直接贴到 issue / PR。

## 测试

```bash
bash scripts/gate-scan/gate-scan.test.sh   # 假构建 + 假 kubectl，覆盖各分组、各失败路径、分步往返
GATE_SCAN_OLD_TS=<v1.4.0 构建> GATE_SCAN_NEW_TS=<fix/250 构建> bash scripts/gate-scan/gate-scan.test.sh   # 加真实构建
```

真实构建部分用合成源（类型嵌套深度 2/64/65/300），期望 depth65、depth300 被报告。
