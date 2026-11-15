#!/usr/bin/env python3
"""ADR 0023 防漂移 gate：校验某仓的实际版本/pin 是否符合 release-plan.json。

单点逻辑（放 platform 仓），各仓 CI 与 orchestrator preflight 都 checkout platform
后调用同一脚本，避免 9 仓复制断言逻辑再漂移。

用法：
    check-artifact.py --plan <release-plan.json> --artifact <id> --repo-root <path>

  --artifact   release-plan.json 里的 artifact id（如 core:maven / locales:npm）
  --repo-root  被校验仓的 checkout 根目录（脚本据 versionSource/kind 读对应文件）

退出码 0=通过，非 0=漂移（打印 ::error）。

按 versionSource 分派断言：
  literal         : 源文件硬编码 version 字面量 == expectedVersion
  catalog-derived : 双断言——①版本确实派生自 asterLibs.findVersion("asterLang")
                    （源文件不含 literal version 行）②expectedPlatformPin == plan.platformVersion
  none            : 无版本制品（service），只校 expectedPlatformPin
另对所有 expectedPlatformPin 非 null 的 artifact 校验 settings 的 platform pin。

pinOwner（ADR 0053 修订 A1 §3，缺省 human）：
  human : pin 必须 == plan.platformVersion（现行断言，人先合 pin PR 再开车）
  train : 列车在 L4 负责 bump（只用于 service 制品，即 aster-api）。pin 允许
          ① == platformVersion（已 bump，阶段 P 跳过）
          ② 严格小于 platformVersion 且 aster-lang-platform 上存在 v<pin> tag（阶段 P bump）
          其余（更高、tag 不存在、无法解析）判漂移；tag 查询失败 fail-closed。
          无论哪种取值，settings 与 setup-aster-build 的 sibling-ref 默认值必须一致（#337）。
          通过时把 `<artifact>=bump|skip` 追加到 --pin-action-file（preflight 输出 api_pin_action）。
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# aster-api 的第二处 platform 版本源（verify-sibling-ref-pin.sh 的另一侧）。
SIBLING_REF_ACTION = ".github/actions/setup-aster-build/action.yml"
DEFAULT_PLATFORM_REMOTE = "https://github.com/aster-cloud/aster-lang-platform"
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
PIN_OWNERS = ("human", "train")


def err(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)


def read_text(p: Path) -> str:
    return p.read_text(encoding="utf-8") if p.exists() else ""


def find_settings(repo_root: Path) -> Path | None:
    for name in ("settings.gradle.kts", "settings.gradle"):
        f = repo_root / name
        if f.exists():
            return f
    return None


def gradle_literal_version(build_file: Path) -> str | None:
    """读 build.gradle(.kts) 的 version = "X" 字面量。"""
    m = re.search(r'^version\s*=\s*["\']([0-9][^"\']*)["\']', read_text(build_file), re.M)
    return m.group(1) if m else None


def gradle_has_catalog_derived_version(build_file: Path) -> bool:
    """version 是否派生自 catalog（asterLibs.findVersion("asterLang")）。"""
    return 'findVersion("asterLang")' in read_text(build_file) or \
           "findVersion('asterLang')" in read_text(build_file)


def npm_version(pkg_json: Path) -> str | None:
    if not pkg_json.exists():
        return None
    return json.loads(pkg_json.read_text(encoding="utf-8")).get("version")


def _settings_pin_at(base: Path) -> str | None:
    s = find_settings(base)
    if not s:
        return None
    m = re.search(r'from\(\s*["\']cloud\.aster-lang:aster-lang-platform:([0-9.]+)["\']\s*\)', read_text(s))
    return m.group(1) if m else None


def settings_platform_pin(repo_root: Path, artifact_path: str | None = None) -> str | None:
    # 子目录制品（如 test:jvm 的 packages/jvm）的 settings/pin 在 artifactPath 下，
    # 不在仓根。先试 artifactPath 子目录，找不到再回退仓根——与 build_file_for 的
    # artifactPath 模型一致。注意双制品仓（locales/hi）的 npm artifact 虽有 artifactPath
    # (ui-messages) 但其 Gradle settings/pin 在仓根，子目录无 settings → 自动回退仓根。
    if artifact_path:
        pin = _settings_pin_at(repo_root / artifact_path)
        if pin is not None:
            return pin
    return _settings_pin_at(repo_root)


def sibling_ref_pin(repo_root: Path) -> str | None:
    """setup-aster-build 的 sibling-ref 默认值（去掉前缀 v）。与 verify-sibling-ref-pin.sh 同一解析：
    只取 sibling-ref 段内的 default，避免撞上其它输入的 default。"""
    text = read_text(repo_root / SIBLING_REF_ACTION)
    blk = re.search(r'^  sibling-ref:\s*$(.*?)(?=^  \S|\Z)', text, re.S | re.M)
    if not blk:
        return None
    d = re.search(r'default:\s*"v?(\d+\.\d+\.\d+)"', blk.group(1))
    return d.group(1) if d else None


def parse_semver(v: str | None) -> tuple[int, int, int] | None:
    """完整匹配 X.Y.Z（不接受前缀 v、预发布后缀、构建元数据），按整数三元组返回。"""
    m = SEMVER.match(v or "")
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None


def platform_tag_state(remote: str, version: str) -> str:
    """aster-lang-platform 上 v<version> 是否存在：exists / missing / error:<原因>。
    git ls-remote --exit-code：0=存在，2=不存在，其它非零=查询失败（网络、鉴权）。"""
    try:
        r = subprocess.run(["git", "ls-remote", "--exit-code", remote, f"refs/tags/v{version}"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"error:{e}"
    if r.returncode == 0:
        return "exists"
    if r.returncode == 2:
        return "missing"
    # 注解只认单行：把 git 的多行报错压成一行。
    return f"error:exit {r.returncode}: {' | '.join(l for l in r.stderr.splitlines() if l.strip())[:300]}"


def check_train_pin(repo_root: Path, actual: str | None, target: str, remote: str) -> tuple[list[str], str | None]:
    """pinOwner=train 的放宽断言。返回 (failures, action)，action ∈ {bump, skip}，失败时为 None。"""
    failures: list[str] = []
    sibling = sibling_ref_pin(repo_root)
    if sibling is None:
        failures.append(f"未能从 {SIBLING_REF_ACTION} 解析出 sibling-ref 默认值（形如 \"vX.Y.Z\"）")
    elif actual != sibling:
        failures.append(f"settings.gradle platform pin {actual!r} 与 sibling-ref 默认值 v{sibling} 不一致"
                        "（半改状态，两处必须同时 bump，见 verify-sibling-ref-pin.sh）")
    tgt, cur = parse_semver(target), parse_semver(actual)
    if tgt is None:
        failures.append(f"plan.platformVersion {target!r} 无法解析为 X.Y.Z")
    if cur is None:
        failures.append(f"platform pin {actual!r} 无法解析为 X.Y.Z")
    if failures:
        return failures, None
    if cur == tgt:
        return [], "skip"
    if cur > tgt:
        return [f"platform pin {actual} 高于目标 {target}（pinOwner=train 只允许 == 目标或已发布的旧版本）"], None
    state = platform_tag_state(remote, actual)
    if state == "missing":
        return [f"platform pin {actual} 低于目标 {target}，但 aster-lang-platform 上 tag v{actual} 不存在"
                "（不是发布过的版本）"], None
    if state != "exists":
        return [f"aster-lang-platform tag v{actual} 查询失败（fail-closed：网络或鉴权错误，无法判定 tag 是否发布过）："
                f"{state[len('error:'):]}"], None
    print(f"[pin bump] settings.gradle {actual} → {target}；sibling-ref v{actual} → v{target}")
    return [], "bump"


def build_file_for(repo_root: Path, artifact_path: str | None) -> Path:
    base = repo_root / artifact_path if artifact_path else repo_root
    return base / "build.gradle.kts"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--repo-root", required=True)
    ap.add_argument("--platform-remote", default=DEFAULT_PLATFORM_REMOTE,
                    help="pinOwner=train 校验 v<pin> tag 的 aster-lang-platform 远端（测试用本地仓）")
    ap.add_argument("--pin-action-file",
                    help="pinOwner=train 通过时追加 `<artifact>=bump|skip` 的文件（preflight 输出 api_pin_action）")
    args = ap.parse_args()

    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))
    art = next((a for a in plan["artifacts"] if a["id"] == args.artifact), None)
    if art is None:
        err(f"artifact id '{args.artifact}' not in release-plan.json")
        return 2

    repo_root = Path(args.repo_root)
    plat_ver = plan["platformVersion"]
    eco_ver = plan["ecosystemVersion"]
    failures: list[str] = []

    vs = art["versionSource"]
    expected = art.get("expectedVersion")
    artifact_path = art.get("artifactPath")

    if vs == "literal":
        if art["kind"] == "npm":
            pkg = (repo_root / artifact_path / "package.json") if artifact_path else (repo_root / "package.json")
            actual = npm_version(pkg)
            if actual != expected:
                failures.append(f"npm version {actual!r} != expected {expected!r} ({pkg})")
        else:  # maven / catalog
            bf = build_file_for(repo_root, artifact_path)
            actual = gradle_literal_version(bf)
            if actual != expected:
                failures.append(f"gradle literal version {actual!r} != expected {expected!r} ({bf})")
    elif vs == "catalog-derived":
        bf = build_file_for(repo_root, artifact_path)
        # 双断言①：确实派生（不许回退成字面量）
        if not gradle_has_catalog_derived_version(bf):
            failures.append(f"catalog-derived artifact 期望 version=findVersion(\"asterLang\") 但 {bf} 未发现派生（可能被改成字面量）")
        # 双断言②：派生出的值 == ecosystemVersion（即 expectedVersion 应 == ecosystemVersion）
        if expected != eco_ver:
            failures.append(f"catalog-derived expectedVersion {expected!r} != plan.ecosystemVersion {eco_ver!r}（plan 自相矛盾）")
    elif vs == "none":
        pass  # service：无版本制品，只校 pin（下方统一）
    else:
        failures.append(f"未知 versionSource: {vs!r}")

    # platform pin 校验（凡 expectedPlatformPin 非 null）
    exp_pin = art.get("expectedPlatformPin")
    pin_owner = art.get("pinOwner", "human")
    pin_action = None
    if pin_owner not in PIN_OWNERS:
        failures.append(f"未知 pinOwner: {pin_owner!r}（只允许 {'/'.join(PIN_OWNERS)}）")
    elif pin_owner == "train" and (art["kind"] != "service" or exp_pin is None):
        failures.append("pinOwner=train 只适用于有 expectedPlatformPin 的 service 制品（列车只会 bump aster-api）")
    elif exp_pin is not None:
        actual_pin = settings_platform_pin(repo_root, artifact_path)
        if pin_owner == "train":
            train_failures, pin_action = check_train_pin(repo_root, actual_pin, plat_ver, args.platform_remote)
            failures.extend(train_failures)
        elif actual_pin != exp_pin:
            failures.append(f"platform pin {actual_pin!r} != expected {exp_pin!r}（应 == plan.platformVersion {plat_ver!r}）")
        if exp_pin != plat_ver:
            failures.append(f"plan 自相矛盾：artifact.expectedPlatformPin {exp_pin!r} != plan.platformVersion {plat_ver!r}")

    if failures:
        for f in failures:
            err(f"[{args.artifact}] {f}")
        return 1
    if pin_action and args.pin_action_file:
        with open(args.pin_action_file, "a", encoding="utf-8") as f:
            f.write(f"{args.artifact}={pin_action}\n")
    print(f"[{args.artifact}] OK (versionSource={vs}, expected={expected}, pin={exp_pin}"
          f"{f', pinOwner={pin_owner}, api_pin_action={pin_action}' if pin_action else ''})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
