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
"""
import argparse
import json
import re
import sys
from pathlib import Path


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


def build_file_for(repo_root: Path, artifact_path: str | None) -> Path:
    base = repo_root / artifact_path if artifact_path else repo_root
    return base / "build.gradle.kts"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--artifact", required=True)
    ap.add_argument("--repo-root", required=True)
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
    if exp_pin is not None:
        actual_pin = settings_platform_pin(repo_root, artifact_path)
        if actual_pin != exp_pin:
            failures.append(f"platform pin {actual_pin!r} != expected {exp_pin!r}（应 == plan.platformVersion {plat_ver!r}）")
        if exp_pin != plat_ver:
            failures.append(f"plan 自相矛盾：artifact.expectedPlatformPin {exp_pin!r} != plan.platformVersion {plat_ver!r}")

    if failures:
        for f in failures:
            err(f"[{args.artifact}] {f}")
        return 1
    print(f"[{args.artifact}] OK (versionSource={vs}, expected={expected}, pin={exp_pin})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
