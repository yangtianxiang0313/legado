#!/usr/bin/env python3
"""Stage a protected Requirement readiness transition without mutating the repo."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any, Dict, Iterable


PUBLISHER_ID = "github-actions-environment:requirement-readiness-publisher"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REQUIREMENT_ID = "REQ-ANDROID-SOURCE-PIPELINE-001"
REQUIREMENT_REVISION = 1
TARGET_WORK_ITEM = "IOS-SOURCE-RUNTIME-HTML-CSS-001"
EXPECTED_REFS = tuple(
    f"{REQUIREMENT_ID}@1#RC-{index:02d}" for index in range(1, 5)
)


class RequirementPublisherError(RuntimeError):
    pass


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def _json_digest(value: Any) -> str:
    return _sha(
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    )


def _json(path: Path, label: str) -> Dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise RequirementPublisherError(f"{label}_NOT_REGULAR")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RequirementPublisherError(f"{label}_INVALID:{error}") from error
    if not isinstance(value, dict):
        raise RequirementPublisherError(f"{label}_INVALID")
    return value


def _git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RequirementPublisherError(
            "GIT_FAILED:" + result.stderr.decode("utf-8", errors="replace")
        )
    return result.stdout.decode("utf-8").strip()


def _checked_file(
    root: Path,
    relative: str,
    expected_sha256: str,
    label: str,
) -> Path:
    if not isinstance(relative, str) or relative.startswith("/"):
        raise RequirementPublisherError(f"{label}_PATH_INVALID")
    path = (root / relative).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise RequirementPublisherError(f"{label}_PATH_INVALID") from error
    if HEX64.fullmatch(expected_sha256 or "") is None:
        raise RequirementPublisherError(f"{label}_SHA256_INVALID")
    if path.is_symlink() or not path.is_file():
        raise RequirementPublisherError(f"{label}_NOT_REGULAR")
    if _sha(path.read_bytes()) != expected_sha256:
        raise RequirementPublisherError(f"{label}_SHA256_DRIFT")
    return path


def _output_directory(root: Path, raw: Path) -> Path:
    output = raw.resolve()
    try:
        output.relative_to(root)
    except ValueError:
        pass
    else:
        raise RequirementPublisherError("OUTPUT_MUST_BE_OUTSIDE_REPOSITORY")
    if output.exists():
        if output.is_symlink() or not output.is_dir() or any(output.iterdir()):
            raise RequirementPublisherError("OUTPUT_NOT_EMPTY")
    else:
        output.mkdir(parents=True, mode=0o700)
    return output


def _write(root: Path, relative: str, payload: bytes) -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(
        target,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(payload)


def _require_refs(values: Iterable[Any], label: str) -> None:
    if set(values) != set(EXPECTED_REFS):
        raise RequirementPublisherError(f"{label}_REQUIREMENT_COVERAGE_INVALID")


def prepare(
    root: Path,
    *,
    source_commit: str,
    authorized_run_id: str,
    requirement_record: str,
    requirement_record_sha256: str,
    requirement_catalog: str,
    requirement_catalog_sha256: str,
    golden_receipt: str,
    golden_receipt_sha256: str,
    knowledge_release: str,
    knowledge_release_sha256: str,
    coverage_ledger: str,
    coverage_ledger_sha256: str,
    approved_by: str,
    published_at: str,
    output_dir: Path,
) -> Dict[str, Any]:
    root = root.resolve()
    if HEX40.fullmatch(source_commit or "") is None:
        raise RequirementPublisherError("SOURCE_COMMIT_INVALID")
    if not re.fullmatch(r"[0-9]+/[1-9][0-9]*", authorized_run_id or ""):
        raise RequirementPublisherError("AUTHORIZED_RUN_ID_INVALID")
    if _git(root, "rev-parse", "HEAD") != source_commit:
        raise RequirementPublisherError("SOURCE_COMMIT_DRIFT")
    if _git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise RequirementPublisherError("SOURCE_WORKTREE_DIRTY")

    record_path = _checked_file(
        root, requirement_record, requirement_record_sha256, "REQUIREMENT_RECORD"
    )
    catalog_path = _checked_file(
        root, requirement_catalog, requirement_catalog_sha256, "REQUIREMENT_CATALOG"
    )
    golden_path = _checked_file(
        root, golden_receipt, golden_receipt_sha256, "GOLDEN_RECEIPT"
    )
    release_path = _checked_file(
        root, knowledge_release, knowledge_release_sha256, "KNOWLEDGE_RELEASE"
    )
    coverage_path = _checked_file(
        root, coverage_ledger, coverage_ledger_sha256, "COVERAGE_LEDGER"
    )
    record = _json(record_path, "REQUIREMENT_RECORD")
    catalog = _json(catalog_path, "REQUIREMENT_CATALOG")
    golden = _json(golden_path, "GOLDEN_RECEIPT")
    release = _json(release_path, "KNOWLEDGE_RELEASE")
    coverage = _json(coverage_path, "COVERAGE_LEDGER")

    clauses = [entry.get("id") for entry in record.get("clauses", [])]
    if (
        record.get("id") != REQUIREMENT_ID
        or record.get("revision") != REQUIREMENT_REVISION
        or record.get("status") != "accepted"
        or record.get("readiness", {}).get("state")
        != "characterization_required"
        or clauses != [f"RC-{index:02d}" for index in range(1, 5)]
    ):
        raise RequirementPublisherError("REQUIREMENT_NOT_CHARACTERIZATION_READY")
    entries = [
        entry
        for entry in catalog.get("requirements", [])
        if entry.get("id") == REQUIREMENT_ID
        and entry.get("revision") == REQUIREMENT_REVISION
    ]
    if (
        len(entries) != 1
        or entries[0].get("path") != requirement_record
        or entries[0].get("readiness") != "characterization_required"
        or entries[0].get("record_sha256")
        != _json_digest(record)
    ):
        raise RequirementPublisherError("REQUIREMENT_CATALOG_BINDING_INVALID")
    if (
        golden.get("authority") != "protected_android_golden"
        or golden.get("authorization") != "github_environment_review"
        or golden.get("fixture_id") != "sl-html-basic-001"
    ):
        raise RequirementPublisherError("GOLDEN_AUTHORITY_INVALID")
    if (
        release.get("kind") != "business_knowledge_release"
        or release.get("authority") != "protected_business_knowledge"
        or release.get("authorization") != "github_environment_review"
        or release.get("inputs", {}).get("golden_receipt") != golden_receipt
        or release.get("inputs", {}).get("golden_receipt_sha256")
        != golden_receipt_sha256
        or release.get("bindings", {}).get("target_work_item")
        != TARGET_WORK_ITEM
    ):
        raise RequirementPublisherError("KNOWLEDGE_RELEASE_BINDING_INVALID")
    _require_refs(
        release.get("bindings", {}).get("requirement_refs", []),
        "KNOWLEDGE_RELEASE",
    )
    if (
        release.get("outputs", {}).get(coverage_ledger)
        != coverage_ledger_sha256
        or coverage.get("id") != "BKL-SOURCE-RUNTIME-HTML-CSS-001"
        or coverage.get("status") != "current"
        or len(coverage.get("entries", [])) != 4
    ):
        raise RequirementPublisherError("COVERAGE_LEDGER_BINDING_INVALID")
    covered = set()
    for entry in coverage["entries"]:
        validation = entry.get("validation", {})
        disposition = entry.get("product_disposition", {})
        delivery = entry.get("delivery", {})
        if (
            validation.get("required") != "android_runtime"
            or validation.get("state") != "verified"
            or validation.get("blockers") != []
            or golden_receipt not in validation.get("evidence_refs", [])
            or disposition.get("kind") != "covered_by_requirement"
            or delivery.get("state") != "planned"
            or TARGET_WORK_ITEM not in delivery.get("work_item_refs", [])
        ):
            raise RequirementPublisherError("COVERAGE_ENTRY_NOT_VERIFIED")
        covered.update(disposition.get("refs", []))
        _require_refs(delivery.get("requirement_refs", []), "COVERAGE_DELIVERY")
    _require_refs(covered, "COVERAGE_LEDGER")

    updated_record = json.loads(json.dumps(record))
    updated_record["readiness"] = {
        "state": "implementation_ready",
        "blockers": [],
        "next_action": (
            "生成 IOS-SOURCE-RUNTIME-HTML-CSS-001 交付蓝图，"
            "以 protected Android Golden 执行 first-divergence 实现"
        ),
    }
    record_bytes = _canonical(updated_record)
    updated_catalog = json.loads(json.dumps(catalog))
    target_entry = next(
        entry
        for entry in updated_catalog["requirements"]
        if entry.get("id") == REQUIREMENT_ID
        and entry.get("revision") == REQUIREMENT_REVISION
    )
    target_entry["readiness"] = "implementation_ready"
    target_entry["record_sha256"] = _json_digest(updated_record)
    catalog_bytes = _canonical(updated_catalog)
    release_relative = (
        "ios/project/requirements/releases/"
        f"{REQUIREMENT_ID}-r0001-{authorized_run_id.replace('/', '-')}.json"
    )
    if (root / release_relative).exists():
        raise RequirementPublisherError("RELEASE_TARGET_EXISTS")
    outputs = {
        requirement_record: _sha(record_bytes),
        requirement_catalog: _sha(catalog_bytes),
    }
    receipt = {
        "schema_version": 1,
        "kind": "requirement_readiness_release",
        "authority": "protected_requirement_readiness",
        "authorization": "github_environment_review",
        "publisher": PUBLISHER_ID,
        "publisher_run_id": authorized_run_id,
        "approved_by": approved_by,
        "published_at": published_at,
        "source_commit": source_commit,
        "binding": {
            "requirement": f"{REQUIREMENT_ID}@{REQUIREMENT_REVISION}",
            "from": "characterization_required",
            "to": "implementation_ready",
            "clauses": list(EXPECTED_REFS),
            "target_work_item": TARGET_WORK_ITEM,
        },
        "inputs": {
            requirement_record: requirement_record_sha256,
            requirement_catalog: requirement_catalog_sha256,
            golden_receipt: golden_receipt_sha256,
            knowledge_release: knowledge_release_sha256,
            coverage_ledger: coverage_ledger_sha256,
        },
        "outputs": outputs,
    }
    receipt_bytes = _canonical(receipt)
    outputs[release_relative] = _sha(receipt_bytes)
    output = _output_directory(root, output_dir)
    payloads = {
        requirement_record: record_bytes,
        requirement_catalog: catalog_bytes,
        release_relative: receipt_bytes,
    }
    for relative, payload in sorted(payloads.items()):
        _write(output, relative, payload)
    transaction = {
        "schema_version": 1,
        "kind": "requirement_readiness_transaction",
        "authority": "protected_requirement_readiness",
        "source_commit": source_commit,
        "publisher_run_id": authorized_run_id,
        "install": [
            {"path": relative, "sha256": _sha(payload)}
            for relative, payload in sorted(payloads.items())
        ],
        "receipt": release_relative,
    }
    _write(output, "transaction.json", _canonical(transaction))
    return {
        "schema_version": 1,
        "status": "staged_for_external_publisher",
        "requirement": f"{REQUIREMENT_ID}@{REQUIREMENT_REVISION}",
        "readiness": "implementation_ready",
        "install_count": 3,
        "receipt": release_relative,
    }


def main(argv: Any = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("prepare")
    command.add_argument("--root", type=Path, default=Path("."))
    command.add_argument("--source-commit", required=True)
    command.add_argument("--authorized-run-id", required=True)
    for name in (
        "requirement-record",
        "requirement-record-sha256",
        "requirement-catalog",
        "requirement-catalog-sha256",
        "golden-receipt",
        "golden-receipt-sha256",
        "knowledge-release",
        "knowledge-release-sha256",
        "coverage-ledger",
        "coverage-ledger-sha256",
        "approved-by",
        "published-at",
    ):
        command.add_argument(f"--{name}", required=True)
    command.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        result = prepare(
            args.root,
            source_commit=args.source_commit,
            authorized_run_id=args.authorized_run_id,
            requirement_record=args.requirement_record,
            requirement_record_sha256=args.requirement_record_sha256,
            requirement_catalog=args.requirement_catalog,
            requirement_catalog_sha256=args.requirement_catalog_sha256,
            golden_receipt=args.golden_receipt,
            golden_receipt_sha256=args.golden_receipt_sha256,
            knowledge_release=args.knowledge_release,
            knowledge_release_sha256=args.knowledge_release_sha256,
            coverage_ledger=args.coverage_ledger,
            coverage_ledger_sha256=args.coverage_ledger_sha256,
            approved_by=args.approved_by,
            published_at=args.published_at,
            output_dir=args.output_dir,
        )
    except RequirementPublisherError as error:
        print(f"requirement-readiness-publisher: {error}")
        return 2
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
