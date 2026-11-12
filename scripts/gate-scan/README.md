# 发布列车门槛扫描（gate scan）

在每次引擎发布列车（train）**之前**运行：把生产库里的全部策略源码分别用「当前已发布」与「候选」两个
aster-lang-ts 构建编译一遍，报告编译结论发生变化的策略。报告为空才说明候选版本不会改变任何生产策略的行为。

| 文件 | 作用 |
| --- | --- |
| `gate-scan.sh` | 一键入口：构建两个 ts、从集群导出策略源码、运行扫描、退出时删除导出 |
| `export-policy-sources.sql` | 只读导出（READ ONLY 事务），输出 JSONL `{id, kind, content}` |
| `scan.mjs` | 比较两个 ts 构建上的诊断码集合，只打印 id / kind / 诊断码 |
| `gate-scan.test.sh` | 本地回归测试（kubectl 用 shim 顶替，不连集群） |

## 何时运行

- 每次发布列车前，候选 aster-lang-ts（或包含它的版本计划）确定之后。
- 任何会收紧解析 / 降级规则的修复（如 #250 降低类型嵌套上限）在合并前，用 `--code` 确认生产里没有命中。

## 前置条件

- 对生产集群有 kubectl 访问权（能 `kubectl exec` 进 `data-services/shared-postgres-1`）；可用 `--kube-context` 指定 context。
- 本机有 aster-lang-ts 克隆：环境变量 `ASTER_TS_REPO`，缺省为本仓库同级目录 `../aster-lang-ts`。传 git ref 时脚本会
  `git fetch origin`，在临时目录建 detached worktree 并 `corepack pnpm install --frozen-lockfile && corepack pnpm run build`
  （每个 ref 约 15 秒到数分钟）。也可直接传已构建好的目录（仓库根或 `dist`）跳过构建。
- Node 24（含 corepack），如 `export PATH=/opt/homebrew/opt/node@24/bin:$PATH`。

## 示例

#250（类型嵌套上限降到 64）：确认没有生产策略在 1.4.0 上不报 E054、在候选分支上报 E054：

```bash
scripts/gate-scan/gate-scan.sh --old-ts v1.4.0 --new-ts fix/250-type-nesting-guard --code E054
```

常规列车：比较当前已发布版本与列车候选（tag、分支或 commit 都可以）上的全部诊断码变化：

```bash
scripts/gate-scan/gate-scan.sh --old-ts v1.4.0 --new-ts main --kube-context <prod-context>
```

先看会执行什么（不构建、不连集群）：加 `--dry-run`。其它选项见 `--help`
（`--namespace`、`--pod`、`--api-db`、`--cloud-db`，缺省 `data-services` / `shared-postgres-1` / `aster_api` / `aster_cloud`）。

也可以单独运行扫描（例如对已导出的文件）：

```bash
node scripts/gate-scan/scan.mjs --old <ts dist> --new <ts dist> --sources sources.jsonl [--code E054]
```

## 如何读结果

```
gate scan: old=1.4.0 (…/ts-old/dist)
           new=1.4.0 (…/ts-new/dist)
mode: code E054 (absent on old, present on new)
lexicons tried: en-US, zh-CN, de-DE, hi-IN
scanned: 61 (api-policy-version=57, cloud-policy=3, cloud-policy-version=1)
gains-E054: 1
  cloud:abc123 [cloud-policy] lexicon=en-US old={} new={E054}!
result: FAIL (1 reported)
```

- 每个报告行：策略 id（前缀 `api:` = aster-api `policy_versions.id`，`cloud:` = aster-cloud `"Policy".id`，
  `cloudv:` = `"PolicyVersion".id`）、来源 kind、选定的 lexicon、新旧两边的诊断码集合；集合后的 `!` 表示该边编译失败。
- 不带 `--code` 时分三组：
  - `newly-failing`：旧版编译成功、新版失败——**这些策略在升级后会坏，必须处理**；
  - `newly-passing`：旧版失败、新版成功——通常是预期的修复，确认即可；
  - `changed-codes`：成败不变但诊断码集合变了（含警告码）——逐个确认是否预期。
- 带 `--code X` 时只有一组 `gains-X`：旧版无 X、新版有 X 的策略。
- 退出码：`0` 报告为空（通过）；`1` 有报告项（需人工确认）；`2` 用法错误；`3` 环境 / 构建 / 导出失败
  （两个库导出都为空也算失败——空扫描不算通过）。
- 诊断码取自 ts `compile()` 返回的 `parseErrors`、`loweringDiagnostics`、`resolutionDiagnostics`；
  只有无码的 `loweringErrors` 时记为 `UNCODED`，`compile()` 抛异常记为 `THROW`。不含类型检查阶段。

### lexicon 选择规则

生产库不存策略的语言，因此对每份源依次尝试两个构建都有的 lexicon（顺序 en-US、zh-CN、de-DE，其后按名称排序的其余语言），
为该源选定**一个** lexicon，新旧两边都按它比较：

1. 旧版编译成功的第一个 lexicon；
2. 否则，新版编译成功的第一个 lexicon（让「新版才通过」的源可见）；
3. 否则，旧版通过解析阶段（失败在名称解析 / 降级）的第一个 lexicon；
4. 否则，第一个 lexicon（en-US）。

## 数据处理

- SQL 在 `BEGIN TRANSACTION READ ONLY` 里执行，不写任何库；脚本不读取任何密钥，依赖操作者已有的 kubectl 权限。
- 导出只写到 `umask 077` 的 `mktemp -d` 临时目录，**不离开该目录**；脚本以 `trap … EXIT` 在任何退出路径
  （成功、失败、Ctrl-C）删除整个临时目录，并移除为构建创建的 aster-lang-ts worktree。
- 输出只含 id、kind、lexicon 与诊断码，**从不打印源码内容**；扫描结果可以直接贴到 issue / PR。

## 测试

```bash
bash scripts/gate-scan/gate-scan.test.sh   # 用法 / dry-run（无需构建）
GATE_SCAN_OLD_TS=<v1.4.0 构建> GATE_SCAN_NEW_TS=<fix/250 构建> bash scripts/gate-scan/gate-scan.test.sh   # 加端到端
```

端到端部分用合成源（类型嵌套深度 2/64/65/300）和 kubectl shim，期望 depth65、depth300 被报告。
