# aster-lang-platform

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Aster Lang **JVM 生态的单一版本源**。发布一个 Gradle
[version catalog](https://docs.gradle.org/current/userguide/platforms.html)
artifact（`cloud.aster-lang:aster-lang-platform`），让所有消费方仓库
（aster-lang-core / -runtime / -truffle / -validation / -locales、aster-api …）
按别名引用 aster-lang 依赖，而不再把 `cloud.aster-lang:aster-lang-core:0.0.1`
这样的版本字面量散落各处。

## 解决什么

合并前：~20 处硬编码 `:0.0.1` 散在 5 个 repo 的 build 文件里，升一次生态版本
要手改每一处、极易漏。本仓库把这些收敛成**一个版本源**（`build.gradle.kts`
里的 `asterLang` 版本）。

> 多 repo 架构做不到字面意义的"改一行全生效"——每个消费方仍要 pin 它 import
> 哪个 platform 版本。但这把"每 repo 散落 N 处"压成"每 repo 一个 catalog 引用
> 点"，并让版本语义集中可审。

## 范围

**仅 JVM 生态**。TypeScript 包（aster-lang-ts 等）走 npm、节奏独立，**不**进本
catalog——把两个生态绑成同一个数字是假耦合（见 ADR 0012）。

## 消费方式

消费方 `settings.gradle.kts`：

```kotlin
dependencyResolutionManagement {
    repositories { mavenLocal(); mavenCentral() /* + GitHub Packages */ }
    versionCatalogs {
        create("asterLibs") {
            from("cloud.aster-lang:aster-lang-platform:1.0.3")
        }
    }
}
```

消费方 `build.gradle.kts`：

```kotlin
dependencies {
    implementation(asterLibs.core)
    implementation(asterLibs.runtime)
    runtimeOnly(asterLibs.bundles.locales)   // en + zh + de
    testImplementation(asterLibs.test)
}
```

## 升级生态版本

1. 改本仓库 `build.gradle.kts` 的 `version("asterLang", "X.Y.Z")` 一处
2. bump 本仓库自身 `version`（catalog 内容变了）
3. 发布新 platform 版本
4. 各消费方把 `from("...:X.Y.Z")` 指向新版（每 repo 一行）

## 当前 catalog 内容

| alias | 坐标 | 版本 |
|---|---|---|
| `core` | cloud.aster-lang:aster-lang-core | `asterLang` |
| `runtime` | cloud.aster-lang:aster-lang-runtime | `asterLang` |
| `truffle` | cloud.aster-lang:aster-lang-truffle | `asterLang` |
| `validation` | cloud.aster-lang:aster-lang-validation | `asterLang` |
| `test` | cloud.aster-lang:aster-lang-test | `asterLang` |
| `en` / `zh` / `de` | cloud.aster-lang:aster-lang-{en,zh,de} | `asterLang` |
| bundle `locales` | en + zh + de | — |

`asterLang` 当前 = `1.0.2`（与现有发布基线一致，切换时零行为变化）。

## 迁移状态

逐 repo 切换中（ADR 0012）。试点：aster-lang-truffle。其余 repo 一个 PR 一个，
各自本地跑全 parity/test 再 push。所有 repo 切完后，本仓库成为唯一版本源。
