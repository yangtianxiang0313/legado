#!/usr/bin/env python3
"""Resolve one trusted Android Oracle scenario from the request registry."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
if str(HARNESS_ROOT) not in sys.path:
    sys.path.insert(0, str(HARNESS_ROOT))

from oracle.request_registry import load_registry  # noqa: E402


SHA = re.compile(r"[0-9a-f]{40}\Z")


class SelectorError(ValueError):
    pass


def select(
    root: Path,
    *,
    event: str,
    ref: str,
    sha: str,
    dispatch_scenario: str,
) -> str:
    scenarios = set(load_registry(root)["by_scenario"])
    if event == "workflow_dispatch":
        if dispatch_scenario not in scenarios:
            raise SelectorError("Invalid workflow_dispatch scenario")
        return dispatch_scenario
    if event != "push":
        raise SelectorError("Unsupported workflow event")
    if SHA.fullmatch(sha) is None:
        raise SelectorError(
            "Push GITHUB_SHA must be exactly 40 lowercase hex characters"
        )
    matches = [
        scenario
        for scenario in scenarios
        if ref == f"refs/heads/feature/oracle-{scenario}-{sha}"
    ]
    if len(matches) != 1:
        raise SelectorError(
            "Push ref is not bound to a registered scenario and GITHUB_SHA"
        )
    return matches[0]


def append_output(path: Path, key: str, value: str) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(f"{key}={value}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="android-oracle-scenario-selector")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--ref", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--dispatch-scenario", default="")
    parser.add_argument("--github-env", type=Path, required=True)
    parser.add_argument("--github-output", type=Path, required=True)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    root = args.root.resolve(strict=True)
    scenario = select(
        root,
        event=args.event,
        ref=args.ref,
        sha=args.sha,
        dispatch_scenario=args.dispatch_scenario,
    )
    append_output(args.github_env, "ORACLE_SCENARIO", scenario)
    append_output(args.github_output, "scenario", scenario)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValueError) as error:
        print(f"ANDROID_ORACLE_SELECTOR: {error}", file=sys.stderr)
        raise SystemExit(2)
