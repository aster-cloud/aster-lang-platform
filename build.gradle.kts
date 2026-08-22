// aster-lang-platform — the single source of truth for aster-lang
// ecosystem dependency versions (ADR 0012).
//
// This project publishes a Gradle *version catalog* artifact
// (cloud.aster-lang:aster-lang-platform). Every consumer repo
// (aster-lang-core, -runtime, -truffle, -validation, -locales,
// aster-api, …) imports this catalog in its settings.gradle and refers
// to deps by alias (e.g. `asterLibs.core`) instead of hardcoding
// `cloud.aster-lang:aster-lang-core:0.0.1`.
//
// To bump the whole ecosystem: change `asterLang` below once, publish a
// new platform version, then point each consumer's catalog import at it.
// (Multi-repo can't do literal "edit one line, everything updates" —
// each repo still pins which platform version it imports — but this
// collapses ~20 scattered version literals down to one per repo.)
//
// SCOPE: JVM ecosystem only. The TypeScript packages (aster-lang-ts etc.)
// publish to npm on an independent cadence and intentionally are NOT in
// this catalog — binding the two ecosystems to one number is a false
// coupling (see ADR 0012 §"rejected: unified cross-ecosystem version").

plugins {
    `version-catalog`
    `maven-publish`
}

group = "cloud.aster-lang"
// The platform artifact's OWN version. Bump this when the catalog
// contents change (i.e. when any ecosystem version below changes).
// 2026-07 全量审计收尾：28 项发现全部处理完毕（跨 core/ts/truffle/test/aster-api）。
// 本次把 platform 自身与生态号**对齐到同一数字**——此前 platform 因 wrapper 升级、
// 治理文件、审计报告等仅影响自身的改动先行到 1.0.16，生态仍停在 1.0.14，两者相差 2。
// lockstep 生态 → asterLang 1.0.14→1.0.17，platform 自身 1.0.16→1.0.17（追平）。
// 1.0.18：core 生产词法器补天城文、truffle NameNode slot 读取修复 + AsyncTaskRegistry
// 线程池泄漏、ts eval-parity 转 PR-blocking。platform 与生态号继续保持一致。
// 1.0.19：aster-api /evaluate-source 并发闸门可被取消绕过（许可挂 onTermination，
// HTTP 取消立刻归还而 worker 仍在跑 → 反复「发起再取消」可绕过闸门）。许可归还
// 收敛为 PermitLease 的 CAS 一次性租约。本仓无代码改动，随生态 lockstep 对齐。
// 1.0.20：truffle 两项修复随生态 lockstep 发布——(1) 步骤级 trace 带源码行号
// （条件漏斗按行号分组/排序，truffle#64）；(2) 成员访问失败时列出可用键名，
// 不再把「键名对不上」误导成 HostAccess 配置问题（truffle#65 / api#244）；
// 另 GraalVM 组件收敛到 25.0.4，消除 25.0.1/25.0.3/25.0.4 三版本混用（api#193）。
//
// 1.0.21：新增 graalvm 版本与 7 个组件别名（api#193），并随生态 lockstep 发版。
//
// ★订正上一版的判断：我曾只抬目录自身 version、把 asterLang 留在 1.0.20，
//   理由是「没有模块重新发版」。但 aster-api 的 CI 有一处刻意设计——
//   setup-aster-build 的 sibling-ref 默认 v1.0.20，注释写明
//   「生态 lockstep 发版，七个仓共用同一个版本号与 tag 名」。
//   分离两个版本轴会打破这个不变量，使 api 找不到对应 tag 的兄弟仓源码。
//   故本次按原设计走完整生态列车：platform / asterLang / ecosystemVersion 同为 1.0.21。
//
// 1.0.22：补丁列车，唯一实质内容是把 ui-messages 的 evidenceExport 四语文案
//   （aster-lang-locales#60 / aster-lang-hi#57，issue #260 遗留）带到 tag 上。
//
//   ★为什么不能直接移动 v1.0.21：aster-api 的 sibling parity 门禁比对的是
//   CI 检出的**兄弟仓 tag**，而 v1.0.21 的制品已发布到 GH Packages。
//   移 tag 会让「tag 指向的源码」与「同名不可变制品」永久对不上——
//   这正是 sibling-ref 钉版本要消除的那类不确定性。故只能向前发新版。
//
// 1.0.23：把 aster-lang-ts#112 的 stdlib 补齐送到 npm —— Text.substring /
//   Text.replace / List.slice / Maybe.unwrap / Result.unwrap / Result.unwrapErr
//   此前只有 JVM 引擎有，TS 侧缺失，而文档站演练场跑的正是 TS 引擎，
//   用户照文档抄必撞 Undefined function（aster-dev#22）。
//   其余各仓的未发版 commit 都是 CI 管道（共享 checkout-sibling），不改制品行为。
//
//   ★ui-messages 的 npm 版本同步抬到 1.0.18：它是 literal 版本且 1.0.17 已发布，
//   而 locales/hi 是 maven+npm 双制品共用一个 release.yml —— maven 1.0.23 不可见
//   必然触发 dispatch，连带重发 npm，撞重复版本即断层（1.0.22 已踩过）。
//
// 1.0.24：安全 + 正确性补丁列车。
//   ★ReDoS（CodeQL high）：scale 校验正则的歧义分支，宿主传入 2 万字符即可
//     占死线程 101 秒（truffle#84 / ts#114）。
//   其余：#73 实参不再写入共享 globalEnv、api#244 标量参数错误信息指向真因、
//   #74 第 1 项 Map 拒绝 null 键（ADR 0035 档位 A）、valueEquals 深度上限双引擎对齐。
//
// 1.0.25：二轮深度审查修的两条**双引擎分叉**。
//   ★is equal to 对结构体/列表两侧结果不同（TS 引用相等 false / Java 结构相等 true）
//     —— 同一条规则在两套引擎给出不同决策。统一为结构相等（ts#117）。
//   ★List.groupBy 自己造键、绕过 mapKey，null 分组键与字符串 "null" 塌陷同桶
//     （truffle#87 / ts#117），顺带修掉 groupBy 的 1 vs 1.0 分组分叉。
//   语料补 struct_list_equality 作跨引擎守门（test#90）——此前唯一的相等用例只喂标量。
version = "1.0.25"

catalog {
    versionCatalog {
        // ===== single source of truth for ecosystem versions =====
        // Current published baseline of every first-party JVM module.
        // 1.0.4 ecosystem-wide for the keyword-alias-mechanism release (ADR 0022 Plan D):
        // core gained the recognition-side alias mechanism (getAliases + Canonicalizer
        // normalization + Validator). The catalog uses one version for all, so every
        // module is re-tagged 1.0.4 in lockstep (runtime/truffle/validation/locales carry
        // no code change — they re-release only to keep the ecosystem catalog uniform).
        version("asterLang", "1.0.25")

        // ===== third-party ecosystem versions =====
        // These were previously hardcoded across consumer repos and had begun to
        // drift (audit #32): quarkus-bom 3.32.2 in -runtime vs 3.37.0 in aster-api;
        // assertj 3.27.3 (-core) / 3.27.6 (-validation) / 3.27.7 (aster-api). Governing
        // them here gives consumers one aligned value to import. Where consumers
        // diverged the NEWER value is chosen as the catalog target; runtime/validation
        // and other laggards should adopt these in a follow-up migration (this platform
        // PR does not touch consumer repos).
        version("junit", "6.0.0")      // org.junit.jupiter:junit-jupiter (uniform across consumers)
        version("quarkus", "3.37.0")   // quarkus-bom: newer of 3.32.2 (-runtime) / 3.37.0 (aster-api)
        version("antlr", "4.13.1")     // ANTLR tool + runtime (aster-lang-core)
        version("assertj", "3.27.7")   // newest present: 3.27.3 / 3.27.6 / 3.27.7 across consumers

        // ★GraalVM：全部组件必须 lockstep（aster-api#193）。
        //   混搭版本的典型症状是 NoClassDefFoundError → ExceptionInInitializerError
        //   at Engine.java:559（实测于单独升 polyglot 的 PR）。
        //   此前 aster-api 与 aster-lang-truffle 各自硬编码字面量，
        //   曾出现 api 内部 25.0.3/25.0.4 混用 + 跨仓 25.0.1 落后。
        //   收进目录后由此处统一，消费仓改用 asterLibs.graalvm.* 别名。
        version("graalvm", "25.0.4")

        // ===== libraries (all reference the version above) =====
        library("core", "cloud.aster-lang", "aster-lang-core").versionRef("asterLang")
        library("runtime", "cloud.aster-lang", "aster-lang-runtime").versionRef("asterLang")
        library("truffle", "cloud.aster-lang", "aster-lang-truffle").versionRef("asterLang")
        library("validation", "cloud.aster-lang", "aster-lang-validation").versionRef("asterLang")
        library("test", "cloud.aster-lang", "aster-lang-test").versionRef("asterLang")

        // GraalVM / Truffle 组件（全部 versionRef("graalvm")，保证 lockstep）
        library("graalvm-polyglot", "org.graalvm.polyglot", "polyglot").versionRef("graalvm")
        library("graalvm-sdk", "org.graalvm.sdk", "graal-sdk").versionRef("graalvm")
        library("graalvm-truffle-api", "org.graalvm.truffle", "truffle-api").versionRef("graalvm")
        library("graalvm-truffle-runtime", "org.graalvm.truffle", "truffle-runtime").versionRef("graalvm")
        library("graalvm-truffle-compiler", "org.graalvm.truffle", "truffle-compiler").versionRef("graalvm")
        library("graalvm-truffle-dsl-processor", "org.graalvm.truffle", "truffle-dsl-processor").versionRef("graalvm")
        library("graalvm-compiler", "org.graalvm.compiler", "compiler").versionRef("graalvm")

        // Locale packs from aster-lang-locales (multi-module).
        // 新坐标 aster-lang-locales-{en,zh,de}：从 aster-lang-locales 仓发布（自有坐标，
        // 无 GitHub Packages 422）。老坐标 aster-lang-{en,zh,de} 归属已归档仓、冻在 1.0.2，
        // 不再随生态级联。同 hi 用独立坐标的先例。
        library("en", "cloud.aster-lang", "aster-lang-locales-en").versionRef("asterLang")
        library("zh", "cloud.aster-lang", "aster-lang-locales-zh").versionRef("asterLang")
        library("de", "cloud.aster-lang", "aster-lang-locales-de").versionRef("asterLang")
        // Hindi (hi-IN) ships from its own repo (aster-lang-hi) as a hot-pluggable
        // SPI pack — extracted from core's builtins so ops can load/unload it.
        library("hi", "cloud.aster-lang", "aster-lang-hi").versionRef("asterLang")

        // ===== third-party libraries =====
        // Reference the third-party versions declared above so consumers can
        // replace their hardcoded literals with aliases (e.g. asterLibs.junit.jupiter).
        library("junit-jupiter", "org.junit.jupiter", "junit-jupiter").versionRef("junit")
        library("quarkus-bom", "io.quarkus.platform", "quarkus-bom").versionRef("quarkus")
        library("antlr", "org.antlr", "antlr4").versionRef("antlr")
        library("antlr-runtime", "org.antlr", "antlr4-runtime").versionRef("antlr")
        library("assertj-core", "org.assertj", "assertj-core").versionRef("assertj")

        // ===== bundles =====
        // The first-party locale packs, for consumers that load them all via
        // SPI (aster-api, aster-lang-truffle runtime). Includes hi so the
        // backend keeps offering Hindi now that it's an SPI pack, not a builtin.
        bundle("locales", listOf("en", "zh", "de", "hi"))
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["versionCatalog"])
            artifactId = "aster-lang-platform"
        }
    }
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/aster-cloud/aster-lang-platform")
            credentials {
                username = System.getenv("GITHUB_ACTOR") ?: ""
                password = System.getenv("GITHUB_TOKEN") ?: ""
            }
        }
    }
}
