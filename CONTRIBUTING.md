# 贡献指南 · Contributing to aster-lang-platform

感谢你有意为 Aster 语言生态贡献力量！Thanks for contributing to the Aster ecosystem.

## 开始之前 · Before You Start

- 阅读 [README](README.md) 了解本仓职责与在生态中的位置。
- 遵守 [行为准则](CODE_OF_CONDUCT.md)。
- 安全问题请走 [SECURITY.md](SECURITY.md)（**不要**开公开 issue）。

## 本地验证 · Local Verification

```bash
./gradlew build     # 构建
./gradlew test      # 测试
```

改动**必须**在本地跑通 `build` + `test` 后再提 PR。若本仓依赖 `aster-lang-core`
等上游仓，跨仓构建前需先把上游发布到 mavenLocal（`./gradlew publishToMavenLocal`）。
具体命令以 README 为准。

## 提交流程 · Pull Request Flow

1. 从 `main` 切分支（`fix/…`、`feat/…`、`docs/…`）。
2. 小步提交，保持每次可编译；提交信息用祈使语气说明「做了什么 + 为什么」。
3. PR 描述附本地验证结果；等 CI 全绿后再请求合并。

## 代码风格 · Code Style

沿用仓内既有风格；新实现前先找 2–3 处相似实现参照，复用既有模式。

## 许可证 · License

贡献即表示你同意你的贡献按本仓 [LICENSE](LICENSE)（Apache-2.0）授权。
By contributing, you agree your contributions are licensed under Apache-2.0.
