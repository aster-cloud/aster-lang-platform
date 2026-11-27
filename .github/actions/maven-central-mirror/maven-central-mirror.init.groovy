// Maven Central 镜像（CI 专用 Gradle init 脚本，由 .github/actions/maven-central-mirror/install.sh 以
// aster-maven-central-mirror.init.gradle 装进 Gradle 用户目录的 init.d；源文件扩展名故意不是 .gradle，见 install.sh）。
//
// 为什么：GitHub 托管 runner 共用出口 IP，repo.maven.apache.org 按 IP 限流，生态各 workflow 又按 includeBuild /
// publishToMavenLocal 在每次 run 里解析多个兄弟仓的完整依赖图，于是频繁 HTTP 429（2026-11-27：truffle native、
// platform release-train api-parity、ts parity、aster-api verify）。缓存只能挡住已缓存的模块——依赖一升级，差量照样打
// Central，限流持续数分钟，退避重试也挡不住（api-parity 用 gradle-retry.sh 重试 3 次仍 429）。
//
// 做法：在构建声明的每个「Maven Central / Gradle Plugin Portal」仓库**紧前面**插入同一个 Maven Central 镜像
// （缺省 Google Cloud Storage 镜像，可用环境变量 ASTER_MAVEN_CENTRAL_MIRROR 覆盖）。
//   - 不改写、不删除原仓库：镜像缺货（同步滞后、Plugin Portal 独有的插件）时 Gradle 照常回落到原仓库，结果不变。
//   - 只插在第一个 Central / Portal 之前：在它前面的仓库（mavenLocal、GitHub Packages）顺序不变，
//     所以 CI 先 publishToMavenLocal 的兄弟仓 cloud.aster-lang 制品仍优先于任何远端，不会换成旧的已发布版本。
//   - 镜像是 Central 的逐字节副本：同一坐标的文件与 Central 完全相同，校验和 / 依赖校验（verification-metadata）不受影响。
//   - 覆盖 settings（pluginManagement、dependencyResolutionManagement、settings buildscript）、每个项目的 buildscript
//     与 repositories；init 脚本对构建树里的每个 build（含 includeBuild、buildSrc）都会执行。
//   - 容器里若有带内容过滤（`content {}` / `exclusiveContent {}`）的上游仓库，插入不带过滤的镜像可能把本该由后面仓库
//     提供的模块改从镜像取。这种容器在使用前（settings 评估完、各配置解析前）撤掉镜像，恢复原样。生态各仓目前都没有这种写法。
//   - 动态版本（`1.+`、范围）由 Gradle 在全部仓库里取最高版本（DynamicVersionResolver），镜像元数据滞后不会让版本变旧。
//   - pluginManagement 没声明仓库时 Gradle 隐式用 Plugin Portal；这里在 settings 脚本执行前显式放一个 Portal 替身
//     （与隐式行为等价，settings 自己声明仓库时撤掉），让镜像能插在它前面，settings 的 plugins {} 也能用上——
//     jmh 插件的 jmh-core 就是经 Plugin Portal 重定向到 Central 才 429 的。
//
// 本地开发不受影响：只有 CI 的 action 会安装本脚本。

def mirrorUrl = (System.getenv('ASTER_MAVEN_CENTRAL_MIRROR') ?: 'https://maven-central.storage-download.googleapis.com/maven2/').trim()
def mirrorName = 'MavenCentralMirror'
// Central 的两个官方主机名，以及会把非插件制品重定向到 Central 的 Plugin Portal。
def upstreamHosts = ['repo.maven.apache.org', 'repo1.maven.org', 'plugins.gradle.org'] as Set

def isUpstream = { repo ->
    repo instanceof MavenArtifactRepository && repo.name != mirrorName && upstreamHosts.contains(repo.url?.host)
}

// 每个仓库容器只插一次：插在第一个上游仓库之前，镜像就已排在全部上游仓库前面。
def insertMirror = { RepositoryHandler repos, ArtifactRepository upstream ->
    if (repos.findByName(mirrorName) != null) return
    def mirror = repos.maven { MavenArtifactRepository m ->
        m.name = mirrorName
        m.url = mirrorUrl
        m.mavenContent { releasesOnly() }   // 与 mavenCentral() 相同
    }
    repos.remove(mirror)
    repos.add(repos.indexOf(upstream), mirror)
}

// 读内部字段（Gradle 9.6.1 的 AbstractArtifactRepository.repositoryContentDescriptor 与
// DefaultRepositoryContentDescriptor 的 include/exclude 规则）。只读，不调用 toContentFilter()：后者会锁定描述符，
// 之后再 content {} 就会报错。字段读不到（Gradle 内部实现变了）时按「有过滤」处理：撤掉镜像、构建照常，只是失去镜像保护；
// maven-central-mirror.test.sh 断言不带过滤的容器保留镜像，会先发现。
// 不看 releasesOnly / snapshotsOnly：mavenCentral() 本身就是 releasesOnly，镜像也设成 releasesOnly，两者一致。
def privateField = { obj, String name ->
    for (def c = obj.getClass(); c != null; c = c.superclass) {
        try {
            def f = c.getDeclaredField(name)
            f.accessible = true
            return f.get(obj)
        } catch (NoSuchFieldException ignored) {
        }
    }
    throw new NoSuchFieldException("${obj.getClass().name}.${name}")
}

def hasContentFilter = { repo ->
    try {
        def d = privateField(repo, 'repositoryContentDescriptor')
        return ['includeSpecs', 'excludeSpecs', 'includedConfigurations', 'excludedConfigurations', 'requiredAttributes'].any { privateField(d, it) }
    } catch (Exception e) {
        logger.warn("maven-central-mirror: 无法判断仓库 ${repo.name} 是否带内容过滤（${e}），按带过滤处理、不使用镜像")
        return true
    }
}

def dropMirrorIfFiltered = { RepositoryHandler repos ->
    def mirror = repos.findByName(mirrorName)
    if (mirror != null && repos.any { isUpstream(it) && hasContentFilter(it) }) {
        repos.remove(mirror)
        logger.info("maven-central-mirror: 仓库带内容过滤，撤掉镜像 ${repos*.name}")
    }
}

// 解析前撤掉镜像：exclusiveContent 是在仓库加入之后才给它挂过滤的，加入时还看不出来。
def dropMirrorBeforeResolve = { ConfigurationContainer configurations, RepositoryHandler repos ->
    configurations.configureEach { Configuration c ->
        c.incoming.beforeResolve { dropMirrorIfFiltered(repos) }
    }
}

def mirrorBeforeUpstream = { RepositoryHandler repos ->
    // 已声明的仓库（本脚本挂钩之前加入的）与之后加入的都要处理。
    def existing = repos.find { isUpstream(it) }
    if (existing != null) insertMirror(repos, existing)
    repos.whenObjectAdded { ArtifactRepository repo ->
        if (isUpstream(repo)) insertMirror(repos, repo)
    }
}

// pluginManagement 没声明仓库时 Gradle 隐式用 Plugin Portal。settings 脚本执行前先显式放一个 Portal（等价于隐式缺省），
// 镜像就能在 settings 的 plugins {} 解析之前插到它前面；settings 脚本一旦自己声明仓库，就撤掉这个替身（连同镜像），
// 按它声明的顺序重新插入——与「声明了仓库就不再有隐式 Portal」的原语义一致。
def standInImplicitPortal = { RepositoryHandler repos ->
    def standIn = repos.gradlePluginPortal()
    repos.whenObjectAdded { ArtifactRepository repo ->
        if (standIn == null || repo.is(standIn) || repo.name == mirrorName) return
        repos.remove(standIn)
        def mirror = repos.findByName(mirrorName)
        if (mirror != null) repos.remove(mirror)
        standIn = null
    }
}

beforeSettings { settings ->
    mirrorBeforeUpstream(settings.buildscript.repositories)
    dropMirrorBeforeResolve(settings.buildscript.configurations, settings.buildscript.repositories)
    // 先挂替身的撤除钩子，再挂插入钩子：settings 声明第一个上游仓库时，先撤旧镜像，再把镜像插到它前面。
    if (settings.pluginManagement.repositories.isEmpty()) standInImplicitPortal(settings.pluginManagement.repositories)
    mirrorBeforeUpstream(settings.pluginManagement.repositories)
    mirrorBeforeUpstream(settings.dependencyResolutionManagement.repositories)
}

settingsEvaluated { settings ->
    dropMirrorIfFiltered(settings.pluginManagement.repositories)
    dropMirrorIfFiltered(settings.dependencyResolutionManagement.repositories)
}

allprojects { project ->
    mirrorBeforeUpstream(project.buildscript.repositories)
    dropMirrorBeforeResolve(project.buildscript.configurations, project.buildscript.repositories)
    mirrorBeforeUpstream(project.repositories)
    dropMirrorBeforeResolve(project.configurations, project.repositories)
}
