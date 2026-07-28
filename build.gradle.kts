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
version = "1.0.17"

catalog {
    versionCatalog {
        // ===== single source of truth for ecosystem versions =====
        // Current published baseline of every first-party JVM module.
        // 1.0.4 ecosystem-wide for the keyword-alias-mechanism release (ADR 0022 Plan D):
        // core gained the recognition-side alias mechanism (getAliases + Canonicalizer
        // normalization + Validator). The catalog uses one version for all, so every
        // module is re-tagged 1.0.4 in lockstep (runtime/truffle/validation/locales carry
        // no code change — they re-release only to keep the ecosystem catalog uniform).
        version("asterLang", "1.0.17")

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

        // ===== libraries (all reference the version above) =====
        library("core", "cloud.aster-lang", "aster-lang-core").versionRef("asterLang")
        library("runtime", "cloud.aster-lang", "aster-lang-runtime").versionRef("asterLang")
        library("truffle", "cloud.aster-lang", "aster-lang-truffle").versionRef("asterLang")
        library("validation", "cloud.aster-lang", "aster-lang-validation").versionRef("asterLang")
        library("test", "cloud.aster-lang", "aster-lang-test").versionRef("asterLang")

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
