# 贡献指南 · Contributing to aster-lang-platform

感谢你有意为 Aster 语言生态贡献力量！Thanks for contributing to the Aster ecosystem.

## 开始之前 · Before You Start

- 阅读 [README](README.md) 了解本仓职责与在生态中的位置。
- 遵守 [行为准则](CODE_OF_CONDUCT.md)。
- 安全问题请走 [SECURITY.md](SECURITY.md)（**不要**开公开 issue）。

## 本地验证 · Local Verification

本仓只有一个生成的 TOML catalog，没有编译代码，也**没有 `test` 任务**。本地跑与
CI（`.github/workflows/ci.yml`）相同的三道检查：

```bash
# 1. 防漂移门禁：build.gradle.kts 的 version 必须等于 release-plan.json 的 platformVersion
python3 scripts/release-plan/check-artifact.py --plan release-plan.json --artifact platform --repo-root .

# 2. 构建并生成 catalog（校验 catalog DSL 与 publish 装配）
./gradlew build generateCatalogAsToml
cat build/version-catalog/libs.versions.toml

# 3. 发布列车执行器的回归测试（仅当改了 scripts/release-plan/）
bash scripts/release-plan/run-train.test.sh
```

改动**必须**在本地跑通以上检查后再提 PR。改了 catalog 内容（`asterLang` 或任何
第三方版本）时，须同步 bump `version` 与 `release-plan.json`，步骤见
[README · 升级生态版本](README.md#升级生态版本)。

## 提交流程 · Pull Request Flow

1. 从 `main` 切分支（`fix/…`、`feat/…`、`docs/…`）。
2. 小步提交，保持每次可编译；提交信息用祈使语气说明「做了什么 + 为什么」。
3. PR 描述附本地验证结果；等 CI 全绿后再请求合并。

## 代码风格 · Code Style

沿用仓内既有风格；新实现前先找 2–3 处相似实现参照，复用既有模式。

## 许可证 · License

贡献即表示你同意你的贡献按本仓 [LICENSE](LICENSE)（Apache-2.0）授权。
By contributing, you agree your contributions are licensed under Apache-2.0.
