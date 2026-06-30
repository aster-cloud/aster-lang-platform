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
version = "1.0.11"

catalog {
    versionCatalog {
        // ===== single source of truth for ecosystem versions =====
        // Current published baseline of every first-party JVM module.
        // 1.0.4 ecosystem-wide for the keyword-alias-mechanism release (ADR 0022 Plan D):
        // core gained the recognition-side alias mechanism (getAliases + Canonicalizer
        // normalization + Validator). The catalog uses one version for all, so every
        // module is re-tagged 1.0.4 in lockstep (runtime/truffle/validation/locales carry
        // no code change — they re-release only to keep the ecosystem catalog uniform).
        version("asterLang", "1.0.9")

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
