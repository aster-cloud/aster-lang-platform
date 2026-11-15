#!/usr/bin/env python3
"""ADR 0053 修订 A1 §2.1 第 3 步：读取 / 改写 aster-api 的两处 platform 版本。

aster-api 的 platform 版本写在两处，必须同时 bump（aster-api 的 verify-sibling-ref-pin.sh 门禁，#337）：

  settings.gradle                                   from('cloud.aster-lang:aster-lang-platform:X')
  .github/actions/setup-aster-build/action.yml     sibling-ref 段的 default: "vX"

用法：
  bump-api-pin.py --repo-root DIR --read           → stdout 一行「<settings 版本> <sibling-ref 版本>」
  bump-api-pin.py --repo-root DIR --write X.Y.Z    → 原地改写两处，stdout 打印「旧 → 新」

两处锚点都必须**恰好命中一次**，否则拒绝改写（退出 2）：宁可停车，也不猜着改。
run-train.sh 的阶段 P 与 preflight 的 bump 预览共用本脚本，保证两边改出来的是同一份 diff。
"""
import argparse
import re
import sys
from pathlib import Path

SETTINGS = "settings.gradle"
ACTION = ".github/actions/setup-aster-build/action.yml"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
# 与 check-artifact.py 的 settings_platform_pin 同一锚点。
SETTINGS_RE = re.compile(r'(from\(\s*["\']cloud\.aster-lang:aster-lang-platform:)([0-9][^"\']*)(["\']\s*\))')
# 与 verify-sibling-ref-pin.sh 同一锚点：只取 sibling-ref 段内的 default。
BLOCK_RE = re.compile(r'^  sibling-ref:\s*$(.*?)(?=^  \S|\Z)', re.S | re.M)
DEFAULT_RE = re.compile(r'(default:\s*")v?([^"]*)(")')


def die(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(2)


def locate(root: Path):
    """返回 (settings 文本, settings 命中, action 文本, sibling-ref 段命中, default 命中)。"""
    s_path, a_path = root / SETTINGS, root / ACTION
    if not s_path.is_file() or not a_path.is_file():
        die(f"{root} 缺少 {SETTINGS} 或 {ACTION}")
    s_text = s_path.read_text(encoding="utf-8")
    s_hits = list(SETTINGS_RE.finditer(s_text))
    if len(s_hits) != 1:
        die(f"{SETTINGS} 中 aster-lang-platform 锚点命中 {len(s_hits)} 次（应恰好 1 次）")
    a_text = a_path.read_text(encoding="utf-8")
    blocks = list(BLOCK_RE.finditer(a_text))
    if len(blocks) != 1:
        die(f"{ACTION} 中 sibling-ref 输入命中 {len(blocks)} 次（应恰好 1 次）")
    defaults = list(DEFAULT_RE.finditer(blocks[0].group(1)))
    if len(defaults) != 1:
        die(f"{ACTION} 的 sibling-ref 段内 default 命中 {len(defaults)} 次（应恰好 1 次）")
    return s_text, s_hits[0], a_text, blocks[0], defaults[0]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", required=True)
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--read", action="store_true")
    mode.add_argument("--write", metavar="VERSION")
    args = ap.parse_args()
    root = Path(args.repo_root)

    s_text, s_hit, a_text, block, default = locate(root)
    old_settings, old_sibling = s_hit.group(2), default.group(2)
    if args.read:
        print(old_settings, old_sibling)
        return 0

    new = args.write
    if not SEMVER.match(new):
        die(f"目标版本 {new!r} 不是 X.Y.Z")
    (root / SETTINGS).write_text(s_text[:s_hit.start(2)] + new + s_text[s_hit.end(2):], encoding="utf-8")
    # default 命中位置是相对 sibling-ref 段的，换算回全文偏移。
    start = block.start(1) + default.start(2)
    end = block.start(1) + default.end(2)
    prefix = "" if a_text[start - 1] == "v" else "v"
    (root / ACTION).write_text(a_text[:start] + prefix + new + a_text[end:], encoding="utf-8")
    print(f"{SETTINGS}: {old_settings} → {new}")
    print(f"{ACTION} sibling-ref: v{old_sibling} → v{new}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
