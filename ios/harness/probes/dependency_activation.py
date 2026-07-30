#!/usr/bin/env python3
"""Project the exact GRDB activation state for Loop structured acceptance."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


FIXTURE_ID = "dependency-grdb-persistence-v1"
IDENTITY = "grdb.swift"
VERSION = "7.11.1"
TARGET = "DatabaseGRDB"
REVISION = re.compile(r"^[0-9a-f]{40}$")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def resolved_pins(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, dict) and isinstance(value.get("pins"), list):
        return [
            entry for entry in value["pins"]
            if isinstance(entry, dict)
        ]
    if isinstance(value, dict) and isinstance(value.get("object"), dict):
        pins = value["object"].get("pins", [])
        return [
            entry for entry in pins
            if isinstance(entry, dict)
        ]
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    divergence: str | None = None
    revision: str | None = None
    try:
        policy = load_json(root / "ios/harness/dependency-policy.json")
        package = next(
            entry
            for entry in policy["packages"]
            if entry.get("identity") == IDENTITY
        )
        lock = load_json(
            root / "ios/Packages/LegadoKit/Package.resolved"
        )
        pin = next(
            entry
            for entry in resolved_pins(lock)
            if str(
                entry.get("identity")
                or entry.get("package")
                or ""
            ).lower() == IDENTITY
        )
        state = pin.get("state", {})
        revision = state.get("revision")
        manifest = (
            root / "ios/Packages/LegadoKit/Package.swift"
        ).read_text(encoding="utf-8")
        if package.get("status") != "enabled":
            divergence = "policy.status"
        elif package.get("exact_version") != VERSION:
            divergence = "policy.exact_version"
        elif package.get("expected_revision") != revision:
            divergence = "policy.expected_revision"
        elif state.get("version") != VERSION:
            divergence = "resolved.version"
        elif not isinstance(revision, str) or not REVISION.fullmatch(
            revision
        ):
            divergence = "resolved.revision"
        elif "DatabaseGRDB" not in manifest or "GRDB" not in manifest:
            divergence = "package.target"
    except (
        FileNotFoundError,
        json.JSONDecodeError,
        KeyError,
        StopIteration,
        TypeError,
    ) as error:
        divergence = f"activation.{type(error).__name__}"

    print(
        json.dumps(
            {
                "schema_version": 1,
                "fixture_id": FIXTURE_ID,
                "status": (
                    "equal" if divergence is None else "different"
                ),
                "package_identity": IDENTITY,
                "exact_version": VERSION,
                "target": TARGET,
                "resolved_revision": revision,
                "first_divergence": divergence,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
