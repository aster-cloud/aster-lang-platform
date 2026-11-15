# 运行手册：发布列车的 aster-api pin App（ADR 0053 修订 A1）

修订 A1 让发布列车在 L4 自己完成 aster-api 的 platform pin bump：改两处版本号 → 开 PR → 等必需检查 → 合并。
推分支、开 PR、超时重跑、合并都用一个**专用 GitHub App** 的短时令牌，做法与 aster-api `deploy.yml` 的 image-pin App 相同。
本手册列出只有组织管理员能做的人工步骤。规范见 aster-api 仓 `docs/adr/0053-amendment-1-train-owns-api-pin.md` §6、§9。

在下面 4 步做完、并且把 `release-plan.json` 的 `pinOwner` 改成 `train` 之前，列车行为与现在一致：`pinOwner` 缺省为 `human`，不需要这个 App。

## 1. 注册 App（wontlost-ltd 组织 owner）

打开 `https://github.com/organizations/wontlost-ltd/settings/apps`，点 **New GitHub App**：

| 字段 | 值 |
|---|---|
| GitHub App name | `aster-train-pin`（bot 登录名为 `aster-train-pin[bot]`）。名称已被占用时可换一个；代码不依赖名称，commit 作者名取签发步骤输出的 `app-slug` |
| Homepage URL | `https://github.com/aster-cloud/aster-lang-platform` |
| Webhook | 取消勾选 **Active** |
| Where can this GitHub App be installed? | **Only on this account** |

**Repository permissions**（最小集，其余全部 **No access**）：

| 权限 | 级别 | 用途 |
|---|---|---|
| Contents | Read and write | 推 `train/aster-api-pin-<X>` 分支；读 main 上的两个 pin 文件 |
| Pull requests | Read and write | 开 PR、查询同名 PR、合并（`gh pr merge --squash --match-head-commit`） |
| Checks | Read-only | 读 PR head 上 `ci-result`、`Guard bypass suite (#466)`、`build-hosted / build` 的 check-run 与注解 |
| Actions | Read and write | 读 CI run 的 `run_attempt`；可证实超时时 `gh run rerun --failed`，至多一次 |
| Metadata | Read-only | 必选基线，自动勾选 |

**不要授予**：Workflows（两处改动都不在 `.github/workflows/` 下）、Administration、任何 Organization 权限，也不要把 App 加进任何规则集的 bypass 列表（见第 5 节）。

创建后：

1. 在 App 设置页的 **About** 区记下 **Client ID**（形如 `Iv23li…`）。
2. 在 **Private keys** 区点 **Generate a private key**，下载 `.pem`。私钥只能下载这一次。

## 2. 安装 App，只装到 aster-api

App 设置页 → **Install App** → `wontlost-ltd` → **Only select repositories** → 只选 **`aster-api`** → **Install**。

核对：

```bash
gh api repos/wontlost-ltd/aster-api/installation --jq '{app_id, app_slug, id, permissions}'
```

`app_slug` 应为 `aster-train-pin`。`permissions` 应恰好是 `contents: write`、`pull_requests: write`、`checks: read`、`actions: write`、`metadata: read`。

## 3. 在 aster-lang-platform 配置变量与 secret

列车在 `aster-cloud/aster-lang-platform` 上运行，所以变量与 secret 配在**这个仓**，不是 aster-api。
命名与 aster-api 的 image-pin App 一致：它在 aster-api 上用的是 repo variable `IMAGE_PIN_APP_CLIENT_ID` 和 secret `IMAGE_PIN_APP_PRIVATE_KEY`，App 本身装在 `wontlost-ltd/k3s`。
令牌按 `owner: wontlost-ltd` 跨组织签发，不需要把 App 装到 aster-cloud 组织。

| 类型 | 名称 | 值 |
|---|---|---|
| Repository variable | `TRAIN_PIN_APP_CLIENT_ID` | 第 1 步的 Client ID |
| Repository secret | `TRAIN_PIN_APP_PRIVATE_KEY` | 第 1 步下载的 `.pem` 全文 |

```bash
gh variable set TRAIN_PIN_APP_CLIENT_ID --repo aster-cloud/aster-lang-platform --body '<Client ID>'
gh secret set TRAIN_PIN_APP_PRIVATE_KEY --repo aster-cloud/aster-lang-platform < /path/to/aster-train-pin.pem
# 上传后删掉本地 .pem
```

缺任何一项时，train job 的 `Require train-pin App credentials` 步骤会报错停车，并写明缺哪个名字。
`run-train.sh` 拿不到令牌时同样会失败（fail-closed），不会回退到 PAT。

## 4. 启用并验证

1. 在 aster-lang-platform 开一个 PR，给 `release-plan.json` 的 `aster-api:service` 条目加上 `"pinOwner": "train"`。
2. 合并后跑一次 **dry-run** 列车：Actions → Release Train → `dryRun: true`。期望结果：
   - preflight 打印 `api_pin_action=bump`（或 `skip`）。为 `bump` 时，job summary 里有两处版本号的 diff；
   - train job 的 `Mint aster-api pin token` 步骤成功。这说明 App 已装在 aster-api、私钥有效。dry-run 只申请 `contents`、`pull-requests`、`checks` 三项读权限；
   - L4 日志里有 `[dry-run] 已有同名 open PR：…` 和本地生成的 diff，没有任何推送、开 PR、合并或 dispatch。
3. dry-run **证明不了写权限可用**：App 安装的权限低于真发申请的写权限时，签发会直接失败，而 dry-run 只申请读权限，看不到这种失败。所以每次改了 App 权限之后，第一趟真发列车要留意 L4 的 `Mint aster-api pin token` 步骤。

回滚：把 `pinOwner` 改回 `human`，或删掉这个字段，即恢复手工 pin 流程，不需要 revert 代码。

## 5. 规则集：不需要 bypass

aster-api 的 `main-protect`（id 22982832）只有三条规则：`deletion`、`non_fast_forward`、`required_status_checks`。必需检查是 `ci-result` 和 `Guard bypass suite (#466)`，都限定由 GitHub Actions（integration 15368）产出，并开着 `strict_required_status_checks_policy: true`。规则集没有 pull_request（审批）规则，`train/*` 分支上也没有任何规则。

- 到 L4 时，L0–L3 已经打出全部 `vX` tag，pin PR 的 CI 能正常变绿。App 按正常路径合并，**不需要也不应该**进 bypass 列表。
- **strict（要求与 main 同步）**：pin 分支建在 preflight 记录的 main SHA 上，pin 阶段开始前又过一次 stale gate，所以开 PR 时它与 main 是同步的。CI 期间如果有人往 main 合入，合并会被拒。列车随即停车，报「main 前进」，**不会**自动 update-branch：update 之后要再跑约 40 分钟 CI，而且新 base 没经过 preflight 验证。用 `fromLayer=4` 续跑即可：preflight 会重新取 main tip，阶段 P 在新 tip 上重建 commit、force-push 到同名分支，再等一轮 CI。

## 6. App 令牌的有效期

安装令牌 1 小时过期。train job 因此分两段跑：先跑 pin 层之前的各层，再签发令牌，然后从 pin 层开始跑。这样令牌的有效期从 L4 开始算。
`run-train.sh` 在令牌签发 55 分钟后不再做写操作（推分支、重跑、合并）。超过这个时间仍在等 CI 时，它会停车并提示 `fromLayer=4` 续跑。续跑会重新签发令牌，复用同名 PR，接着等或直接合并，最坏情况下 CI 也只重跑一次。

## 7. 信任边界

与 ADR 0053 修订 A1 §6 一致：能在 aster-lang-platform 上 dispatch Release Train 的人，或者能改列车代码并让它在 main 上运行的人，都可以间接让这个 App 往 aster-api 推分支并合并通过 CI 的 PR，而合并会触发部署。所以 **platform 仓的写权限实际上等于 aster-api 的维护权限**。启用前请确认两个仓有写权限的人员一致。
