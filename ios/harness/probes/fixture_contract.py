#!/usr/bin/env python3
"""Validate that a work item's fixture inputs are deterministic and indexed."""

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--work-item", required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    item_path = root / "ios/harness/work-items" / f"{args.work_item}.json"
    item = json.loads(item_path.read_text(encoding="utf-8"))
    required = item.get("spec", {}).get("inputs", {}).get("fixtures", [])
    manifest = json.loads((root / "ios/harness/fixtures/manifest.json").read_text(encoding="utf-8"))
    indexed = {entry.get("id"): entry for entry in manifest.get("fixtures", [])}
    errors = []
    for fixture_id in required:
        entry = indexed.get(fixture_id)
        if entry is None:
            errors.append(f"fixture 未进入确定性 manifest：{fixture_id}")
            continue
        case_path = root / entry["path"] / "case.json"
        case = json.loads(case_path.read_text(encoding="utf-8"))
        determinism = case.get("determinism", {})
        if determinism.get("network_allowed") is not False:
            errors.append(f"fixture 必须禁止真实网络：{fixture_id}")
        for key in ("clock", "timezone", "locale", "random_seed"):
            if key not in determinism:
                errors.append(f"fixture 缺少 determinism.{key}：{fixture_id}")
        limits = case.get("limits", {})
        if not isinstance(limits.get("timeout_ms"), int) or not isinstance(limits.get("max_response_bytes"), int):
            errors.append(f"fixture 缺少资源上限：{fixture_id}")

    if "human-golden-prerequisite" in item.get("metadata", {}).get("labels", []):
        golden_manifest = json.loads((root / "ios/harness/goldens/manifest.json").read_text(encoding="utf-8"))
        goldens = golden_manifest.get("fixtures", {})
        if not golden_manifest.get("oracle", {}).get("runner_digest"):
            errors.append("受保护 golden manifest 缺少 Android runner_digest")
        if not golden_manifest.get("canonicalizer_sha256"):
            errors.append("受保护 golden manifest 缺少 canonicalizer_sha256")
        for fixture_id in required:
            golden = goldens.get(fixture_id)
            if not isinstance(golden, dict) or not golden.get("fixture_sha256") or not golden.get("golden_sha256"):
                errors.append(f"缺少受保护 Android golden：{fixture_id}")
            elif fixture_id not in indexed:
                continue
            elif golden.get("fixture_sha256") != indexed[fixture_id].get("sha256"):
                errors.append(f"Android golden 绑定的 fixture hash 已过期：{fixture_id}")

    if errors:
        for error in errors:
            print(f"FIXTURE_CONTRACT: {error}", file=sys.stderr)
        return 1
    print(f"FIXTURE_CONTRACT: OK ({len(required)} fixtures)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
