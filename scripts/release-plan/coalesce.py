#!/usr/bin/env python3
"""ADR 0023 阶段3：把 release-plan.json 的 artifact 粒度 releaseOrder 折叠成
**(repo, releaseWorkflow) 粒度的发布步骤**，供 orchestrator(release-train.yml) 逐层
dispatch。

关键：locales/hi 的 Maven+npm 共用一个 release.yml，必须只 dispatch 一次（传
artifactIds 列表），否则重复 publish。test:jvm/test:npm 是两个独立 workflow，各成步。

输出（JSON，每层一个数组，层内可并行）：
[
  [ {"repo","workflow","version","artifactIds":[...],"ids":[...],"npmNames":[...]} , ... ],
  ...
]

version 取该 (repo,workflow) 组里**主 artifact** 的版本：
  - 组里有 catalog-derived/maven/catalog → 用它的 expectedVersion（Maven 主 release line，tag 代表它）
  - 否则（纯 npm 组，如 ts:npm / test:npm）→ 用该 npm artifact 的 expectedVersion
dual-artifact 同 workflow（locales/hi）→ 主版本是 Maven 的，npm 版本由各仓 publish 内部 gate 自校。

用法： coalesce.py --plan release-plan.json   → stdout JSON
"""
import argparse
import json
import sys
from pathlib import Path

# 主版本优先级：tag 代表的 release line。Maven/catalog > service > npm。
KIND_PRIORITY = {"catalog": 0, "maven": 1, "service": 2, "npm": 3}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    args = ap.parse_args()
    plan = json.loads(Path(args.plan).read_text(encoding="utf-8"))

    by_id = {a["id"]: a for a in plan["artifacts"]}
    out_layers = []
    for layer in plan["releaseOrder"]:
        # 按 (repo, releaseWorkflow) 分组
        groups: dict[tuple, list] = {}
        for art_id in layer:
            art = by_id[art_id]
            key = (art["repo"], art["releaseWorkflow"])
            groups.setdefault(key, []).append(art)
        steps = []
        for (repo, workflow), arts in groups.items():
            # 主 artifact = kind 优先级最高（Maven/catalog 优先做 tag 主版本）
            primary = sorted(arts, key=lambda a: KIND_PRIORITY.get(a["kind"], 9))[0]
            steps.append({
                "repo": repo,
                "workflow": workflow,
                "version": primary["expectedVersion"],
                "artifactIds": [a["id"] for a in arts],
                "kinds": [a["kind"] for a in arts],
                # 组内每个 artifact 的完整可见性判定信息——orchestrator 必须确认
                # **组内全部 artifact 都可见**才算该步完成（dual-artifact 不可只看 primary）。
                "artifacts": [
                    {
                        "id": a["id"],
                        "kind": a["kind"],
                        "version": a["expectedVersion"],
                        "mavenPackages": a.get("mavenPackages", []),
                        "npmName": a.get("npmName"),
                        "npmRegistry": a.get("npmRegistry"),  # 'npmjs' | 'ghpkg' | None
                    }
                    for a in arts
                ],
            })
        out_layers.append(steps)

    json.dump(out_layers, sys.stdout, ensure_ascii=False, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
