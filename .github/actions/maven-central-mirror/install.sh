#!/usr/bin/env bash
# 把 Maven Central 镜像 init 脚本与依赖解析重试参数装进 Gradle 用户目录（只供 CI 使用）。
#
# 用法：bash install.sh            （由 action.yml 与 setup-gradle-cached 调用）
#
# 装两样东西，之后本 job 里的每次 Gradle 调用（含兄弟仓的 publishToMavenLocal、includeBuild）都生效：
#   1. init.d/aster-maven-central-mirror.init.gradle（源文件 maven-central-mirror.init.groovy）—— 在每个 Maven Central / Plugin Portal 仓库紧前面插入镜像，
#      语义见该脚本文件头；
#   2. gradle.properties 里的依赖解析重试参数（Gradle 内部属性，9.6.1 的 ErrorHandlingModuleComponentRepository 读取）：
#        org.gradle.internal.repository.max.tentatives  缺省 3 → 6
#        org.gradle.internal.repository.initial.backoff 缺省 1000ms → 2000ms（每次翻倍：2+4+8+16+32 ≈ 62s）
#      Gradle 已把 429 当作瞬时错误重试，但缺省 3 次共约 3 秒，扛不住持续数分钟的限流；同一仓库失败后整个构建会禁用该仓库。
#      已存在的同名键不覆盖（调用方显式配置优先）。属性名若在 Gradle 升级后改名，maven-central-mirror.test.sh 会失败。
#
# 环境变量：
#   GRADLE_USER_HOME            Gradle 用户目录，缺省 ~/.gradle
#   ASTER_MAVEN_CENTRAL_MIRROR  构建时读取（不是安装时）：覆盖镜像地址，缺省 Google Cloud Storage 的 Maven Central 镜像
set -euo pipefail

# 源文件不用 .gradle 扩展名：各仓缓存键 hashFiles('**/*.gradle*') 会把检出的 platform 一并算进去，
# 叫 *.gradle 的话每改一次本脚本，所有消费方的 Gradle 缓存都会整条失效。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guh="${GRADLE_USER_HOME:-$HOME/.gradle}"

mkdir -p "$guh/init.d"
cp "$HERE/maven-central-mirror.init.groovy" "$guh/init.d/aster-maven-central-mirror.init.gradle"

props="$guh/gradle.properties"
touch "$props"
for kv in \
  "systemProp.org.gradle.internal.repository.max.tentatives=6" \
  "systemProp.org.gradle.internal.repository.initial.backoff=2000"; do
  key="${kv%%=*}"
  if grep -q "^${key//./\\.}=" "$props"; then
    echo "保留已有配置：$(grep "^${key//./\\.}=" "$props" | tail -n1)"
  else
    # 文件末尾可能没有换行：先补一个，避免与上一行粘连。
    [ ! -s "$props" ] || [ -z "$(tail -c1 "$props")" ] || echo >>"$props"
    echo "$kv" >>"$props"
  fi
done

echo "Maven Central 镜像已启用：${ASTER_MAVEN_CENTRAL_MIRROR:-https://maven-central.storage-download.googleapis.com/maven2/}（插在 Central / Plugin Portal 之前，缺货回落原仓库）"
echo "依赖解析重试：$(grep -E '^systemProp\.org\.gradle\.internal\.repository\.' "$props" | tr '\n' ' ')"
