#!/usr/bin/env python3
"""Read-only CLI for Android Oracle candidate artifacts."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
if str(HARNESS_ROOT) not in sys.path:
    sys.path.insert(0, str(HARNESS_ROOT))

from oracle.canonicalizer import canonicalize_bytes, load_config  # noqa: E402
from oracle.comparator import compare  # noqa: E402
from oracle.contract import ALLOWED_COMMANDS, doctor, verify_proposal  # noqa: E402
from oracle.exact_json import dumps  # noqa: E402


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="oracle-control")
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ALLOWED_COMMANDS:
        child = commands.add_parser(command)
        child.add_argument("--root", type=Path, required=True)
        if command == "canonicalize":
            child.add_argument("--input", type=Path, required=True)
        elif command == "compare":
            child.add_argument("--expected-payload", type=Path, required=True)
            child.add_argument("--actual-artifact", type=Path, required=True)
        elif command == "verify-proposal":
            child.add_argument("--proposal", type=Path, required=True)
            child.add_argument("--request-work-item", required=True)
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    root = args.root.resolve(strict=True)
    if args.command == "doctor":
        errors = doctor(root)
        report = {"ok": not errors, "errors": errors, "commands": list(ALLOWED_COMMANDS)}
        _write_json(report)
        return 0 if not errors else 1
    config = load_config(root / "ios/harness/normalization/canonical-v1.json")
    if args.command == "canonicalize":
        sys.stdout.buffer.write(canonicalize_bytes(args.input.read_bytes(), config))
        return 0
    if args.command == "compare":
        report = compare(
            args.expected_payload.read_bytes(),
            args.actual_artifact.read_bytes(),
            config,
        )
        _write_json(report)
        return 0 if report["equal"] else 1
    report = verify_proposal(root, args.proposal, args.request_work_item)
    _write_json(report)
    return 0


def _write_json(value) -> None:
    sys.stdout.buffer.write(dumps(value))
    sys.stdout.buffer.write(b"\n")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"ORACLE_CONTROL: {error}", file=sys.stderr)
        raise SystemExit(2)
