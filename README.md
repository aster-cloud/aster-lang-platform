# aster-lang-platform

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Aster Lang **JVM 生态的单一版本源**。发布一个 Gradle
[version catalog](https://docs.gradle.org/current/userguide/platforms.html)
artifact（`cloud.aster-lang:aster-lang-platform`），让所有消费方仓库
（aster-lang-core / -runtime / -truffle / -validation / -locales / -hi / -test、
aster-api …）按别名引用 aster-lang 依赖，而不再把
`cloud.aster-lang:aster-lang-core:0.0.1` 这样的版本字面量散落各处。

本仓同时是生态**发布**的真相源：`release-plan.json` 描述全部制品的期望版本与发布
顺序，`release-train.yml` 据它按层 dispatch 各仓发布；各仓 CI 与列车 preflight 都用
`scripts/release-plan/check-artifact.py` 对照它做防漂移门禁（ADR 0023）。

## 解决什么

合并前：~20 处硬编码 `:0.0.1` 散在 5 个 repo 的 build 文件里，升一次生态版本
要手改每一处、极易漏。本仓库把这些收敛成**一个版本源**（`build.gradle.kts`
里的 `asterLang` 版本）。

> 多 repo 架构做不到字面意义的"改一行全生效"——每个消费方仍要 pin 它 import
> 哪个 platform 版本。但这把"每 repo 散落 N 处"压成"每 repo 一个 catalog 引用
> 点"，并让版本语义集中可审。

## 范围

**仅 JVM 生态**。TypeScript 包（aster-lang-ts 等）走 npm、节奏独立，**不**进本
catalog——把两个生态绑成同一个数字是假耦合（见 ADR 0012）。ts 的 npm 版本只在
`release-plan.json`（`tsNpmVersion`）里登记，供发布列车编排，不进 catalog。

## 消费方式

消费方 `settings.gradle.kts`（pin 的版本须等于 `release-plan.json` 的
`platformVersion`，各仓 CI 的 drift gate 会断言这点）：

```kotlin
dependencyResolutionManagement {
    repositories { mavenLocal(); mavenCentral() /* + GitHub Packages */ }
    versionCatalogs {
        create("asterLibs") {
            from("cloud.aster-lang:aster-lang-platform:1.0.30")
        }
    }
}
```

消费方 `build.gradle.kts`：

```kotlin
// 自身版本派生自 catalog，不写字面量（drift gate 断言 versionSource=catalog-derived）
version = asterLibs.findVersion("asterLang").get().requiredVersion

dependencies {
    implementation(asterLibs.core)
    implementation(asterLibs.runtime)
    runtimeOnly(asterLibs.bundles.locales)      // en + zh + de + hi
    implementation(asterLibs.graalvm.polyglot)  // GraalVM 组件全部走 graalvm.* 别名，保证 lockstep
    testImplementation(asterLibs.test)
    testImplementation(asterLibs.junit.jupiter)
}
```

## 当前 catalog 内容

以 `build.gradle.kts` 为准；下表与其生成结果一致，可随时重新生成核对：

```bash
./gradlew --offline -q generateCatalogAsToml && cat build/version-catalog/libs.versions.toml
```

版本键（`[versions]`）：

| 键 | 值 | 说明 |
|---|---|---|
| `asterLang` | `1.0.30` | 全部一方 JVM 模块共用一个号，每次发版 lockstep 重新打 tag |
| `graalvm` | `25.0.4` | GraalVM/Truffle 全部组件必须同版，混用会 `NoClassDefFoundError` |
| `junit` | `6.0.0` | |
| `quarkus` | `3.37.0` | quarkus-bom |
| `antlr` | `4.13.1` | |
| `assertj` | `3.27.7` | |

库别名（`[libraries]`）：

| alias | 坐标 | version.ref |
|---|---|---|
| `core` | cloud.aster-lang:aster-lang-core | `asterLang` |
| `runtime` | cloud.aster-lang:aster-lang-runtime | `asterLang` |
| `truffle` | cloud.aster-lang:aster-lang-truffle | `asterLang` |
| `validation` | cloud.aster-lang:aster-lang-validation | `asterLang` |
| `test` | cloud.aster-lang:aster-lang-test | `asterLang` |
| `en` / `zh` / `de` | cloud.aster-lang:aster-lang-locales-{en,zh,de} | `asterLang` |
| `hi` | cloud.aster-lang:aster-lang-hi | `asterLang` |
| `graalvm-polyglot` | org.graalvm.polyglot:polyglot | `graalvm` |
| `graalvm-sdk` | org.graalvm.sdk:graal-sdk | `graalvm` |
| `graalvm-truffle-api` | org.graalvm.truffle:truffle-api | `graalvm` |
| `graalvm-truffle-runtime` | org.graalvm.truffle:truffle-runtime | `graalvm` |
| `graalvm-truffle-compiler` | org.graalvm.truffle:truffle-compiler | `graalvm` |
| `graalvm-truffle-dsl-processor` | org.graalvm.truffle:truffle-dsl-processor | `graalvm` |
| `graalvm-compiler` | org.graalvm.compiler:compiler | `graalvm` |
| `junit-jupiter` | org.junit.jupiter:junit-jupiter | `junit` |
| `quarkus-bom` | io.quarkus.platform:quarkus-bom | `quarkus` |
| `antlr` / `antlr-runtime` | org.antlr:antlr4 / org.antlr:antlr4-runtime | `antlr` |
| `assertj-core` | org.assertj:assertj-core | `assertj` |

bundle（`[bundles]`）：

| bundle | 成员 |
|---|---|
| `locales` | en + zh + de + hi |

> 旧坐标 `aster-lang-{en,zh,de}` 归属已归档仓、冻在 1.0.2，不再随生态级联；locale
> 包现从 aster-lang-locales 仓以 `aster-lang-locales-*` 坐标发布，hi 从 aster-lang-hi
> 仓以独立坐标发布（SPI 热插拔包）。

## 升级生态版本

生态是 lockstep 的：platform 自身 `version`、catalog 内 `asterLang`、
`release-plan.json` 的 `platformVersion` / `ecosystemVersion` 同为一个号。
CI 的 drift gate（`.github/workflows/ci.yml`）断言 `build.gradle.kts` 的 `version`
== `release-plan.json.platformVersion`，**漏改 release-plan.json 的 PR 必然 CI 红**。

1. `build.gradle.kts`：改 `version = "X.Y.Z"` 与 `version("asterLang", "X.Y.Z")`，
   并在文件头 changelog 加一段本版说明（为什么发、改了什么）。
2. `release-plan.json`：`platformVersion` / `ecosystemVersion` 改为 X.Y.Z；每个
   `versionSource=catalog-derived` 的 artifact 把 `expectedVersion` 与
   `expectedPlatformPin` 改为 X.Y.Z；`platform` artifact 的 `expectedVersion` 同步；
   若 ts 同轮发版则改 `tsNpmVersion` 与 `ts:npm.expectedVersion`。
   （ui-messages 系列 npm 独立 cadence，不随生态号动。）
3. 本地核对（与 CI 相同的两道门禁）：
   ```bash
   python3 scripts/release-plan/check-artifact.py --plan release-plan.json --artifact platform --repo-root .
   ./gradlew build generateCatalogAsToml
   ```
4. 提 PR、合入 `main`（参考既往 `chore(release): 生态 pin bump …` 提交）。
5. 各消费仓把 `settings.gradle.kts` 的 `from("cloud.aster-lang:aster-lang-platform:X.Y.Z")`
   指向新版（Renovate pin PR 或手工，每 repo 一行）。列车 preflight 会 checkout 每个
   仓的 `main` 跑 `check-artifact.py`，任一仓 pin 未更新即拒绝发车。
6. 在本仓 Actions 手动运行 **Release Train**（`release-train.yml`）：先 `dryRun=true`
   看计划与 preflight，再 `dryRun=false` 真发。列车按 `releaseOrder` 逐层发布：
   platform → {core, runtime, validation, test} → {locales, hi} → truffle → {ts, aster-api}；
   每步 dispatch 目标仓 `release.yml` 建 tag → 等 tag-push publish run → 等制品在
   registry 可见。forward-only，失败即停，可用 `fromLayer` 续跑。

只改本仓（不发生态）时——例如 wrapper 升级、治理文件——**不要**动 `asterLang`，
但 platform 自身 `version` 与 `release-plan.json.platformVersion` 仍须一起动。

## 迁移状态

ADR 0012 的逐仓切换已完成：`release-plan.json` 中所有一方 JVM 制品均为
`versionSource=catalog-derived`（版本派生自本 catalog），pin 由列车 preflight 与各仓
CI 的 drift gate 共同约束。本仓库是唯一版本源。
