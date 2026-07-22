#!/usr/bin/env python3
"""Validate that a work item's fixture inputs are deterministic and indexed."""

import argparse
import re
import sys
from pathlib import Path, PurePosixPath


HARNESS_ROOT = Path(__file__).resolve().parents[1]
if str(HARNESS_ROOT) not in sys.path:
    sys.path.insert(0, str(HARNESS_ROOT))

from oracle.contract import doctor as oracle_doctor  # noqa: E402
from oracle.contract import fixture_digest  # noqa: E402
from oracle.exact_json import NumberToken, loads  # noqa: E402


HEX64 = re.compile(r"[0-9a-f]{64}\Z")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--work-item", required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    item_path = root / "ios/harness/work-items" / f"{args.work_item}.json"
    item = loads(item_path.read_bytes())
    required = item.get("spec", {}).get("inputs", {}).get("fixtures", [])
    manifest = loads((root / "ios/harness/fixtures/manifest.json").read_bytes())
    indexed = {}
    errors = []
    paths = set()
    for entry in manifest.get("fixtures", []):
        fixture_id = entry.get("id") if isinstance(entry, dict) else None
        path = entry.get("path") if isinstance(entry, dict) else None
        digest = entry.get("sha256") if isinstance(entry, dict) else None
        if (
            not isinstance(fixture_id, str)
            or fixture_id in indexed
            or not isinstance(path, str)
            or path in paths
            or not isinstance(digest, str)
            or HEX64.fullmatch(digest) is None
        ):
            errors.append("fixture manifest 含重复或无效条目")
            continue
        try:
            directory = safe_fixture_directory(root, path)
            if directory.name != fixture_id or fixture_digest(directory) != digest:
                errors.append(f"fixture 内容摘要已过期：{fixture_id}")
        except (OSError, ValueError) as error:
            errors.append(f"fixture 路径无效：{fixture_id}: {error}")
        indexed[fixture_id] = entry
        paths.add(path)
    for fixture_id in required:
        entry = indexed.get(fixture_id)
        if entry is None:
            errors.append(f"fixture 未进入确定性 manifest：{fixture_id}")
            continue
        try:
            directory = safe_fixture_directory(root, entry["path"])
            case = loads((directory / "case.json").read_bytes())
        except (OSError, ValueError) as error:
            errors.append(f"fixture case 无效：{fixture_id}: {error}")
            continue
        if not isinstance(case, dict) or case.get("id") != fixture_id:
            errors.append(f"fixture case identity 不一致：{fixture_id}")
            continue
        determinism = case.get("determinism", {})
        if determinism.get("network_allowed") is not False:
            errors.append(f"fixture 必须禁止真实网络：{fixture_id}")
        for key in ("clock", "timezone", "locale", "random_seed"):
            if key not in determinism:
                errors.append(f"fixture 缺少 determinism.{key}：{fixture_id}")
        limits = case.get("limits", {})
        if not positive_integer(limits.get("timeout_ms")) or not positive_integer(limits.get("max_response_bytes")):
            errors.append(f"fixture 缺少资源上限：{fixture_id}")

    if "oracle-proposal" in item.get("metadata", {}).get("labels", []):
        errors.extend(f"Oracle control plane: {error}" for error in oracle_doctor(root))

    if "human-golden-prerequisite" in item.get("metadata", {}).get("labels", []):
        golden_manifest = loads((root / "ios/harness/goldens/manifest.json").read_bytes())
        goldens = golden_manifest.get("fixtures", {})
        if not golden_manifest.get("oracle", {}).get("runner_digest"):
            errors.append("受保护 golden manifest 缺少 Android runner_digest")
        if HEX64.fullmatch(golden_manifest.get("canonicalizer_sha256") or "") is None:
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


def safe_fixture_directory(root: Path, relative: str) -> Path:
    pure = PurePosixPath(relative)
    if (
        not relative.startswith("ios/harness/fixtures/")
        or "\\" in relative
        or "\0" in relative
        or pure.is_absolute()
        or any(part in {"", ".", ".."} for part in relative.split("/"))
    ):
        raise ValueError("path escapes fixture root")
    current = root
    for part in pure.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("symlink is forbidden")
    directory = current.resolve(strict=True)
    directory.relative_to((root / "ios/harness/fixtures").resolve(strict=True))
    if not directory.is_dir():
        raise ValueError("fixture path is not a directory")
    return directory


def positive_integer(value) -> bool:
    return isinstance(value, NumberToken) and value.token.isdigit() and int(value.token) > 0


if __name__ == "__main__":
    sys.exit(main())
