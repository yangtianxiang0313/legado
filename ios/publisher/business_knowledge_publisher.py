#!/usr/bin/env python3
"""Stage an evidence-bound Business Knowledge publication transaction.

This program is intentionally staging-only.  It validates a completed proposal
batch and protected Android Golden, builds published Packet/Driver/Coverage
records in an isolated verifier tree, and writes the transaction to a new
directory outside the repository.  It never edits, commits, pushes, or opens a
pull request in the source repository.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Tuple


PUBLISHER_ID = "github-actions-environment:business-knowledge-publisher"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RUN_ID = re.compile(r"[1-9][0-9]*/[1-9][0-9]*\Z")
PACKET_ID = re.compile(r"BKP-[A-Z][A-Z0-9-]*-[0-9]{3}\Z")
DRIVER_ID = re.compile(r"DRV-[A-Z][A-Z0-9-]*-[0-9]{3}\Z")
CLAIM_ID = re.compile(r"BKC-[A-Z][A-Z0-9-]*-[0-9]{3}\Z")
WORK_ITEM_ID = re.compile(r"IOS-[A-Z][A-Z0-9-]*-[0-9]{3}\Z")
REQUIREMENT_REF = re.compile(
    r"(REQ-[A-Z0-9-]+)@([1-9][0-9]*)#(RC-[0-9]{2})\Z"
)


class KnowledgePublisherError(RuntimeError):
    def __init__(self, reason_code: str, detail: str = ""):
        super().__init__(reason_code)
        self.reason_code = reason_code
        self.detail = detail


def _canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _json(path: Path, label: str) -> Dict[str, Any]:
    path = _regular(path, label)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise KnowledgePublisherError("JSON_INVALID", label) from error
    if not isinstance(value, dict):
        raise KnowledgePublisherError("OBJECT_REQUIRED", label)
    return value


def _regular(path: Path, label: str) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise KnowledgePublisherError("REGULAR_FILE_REQUIRED", label) from error
    if path.is_symlink() or not resolved.is_file():
        raise KnowledgePublisherError("REGULAR_FILE_REQUIRED", label)
    return resolved


def _relative_regular(root: Path, raw: str, label: str) -> Tuple[Path, str]:
    path = Path(raw)
    if path.is_absolute() or ".." in path.parts:
        raise KnowledgePublisherError("REPOSITORY_PATH_INVALID", label)
    resolved = _regular(root / path, label)
    try:
        relative = resolved.relative_to(root).as_posix()
    except ValueError as error:
        raise KnowledgePublisherError("REPOSITORY_PATH_INVALID", label) from error
    if relative != path.as_posix():
        raise KnowledgePublisherError("REPOSITORY_PATH_DRIFT", label)
    return resolved, relative


def _external_empty_directory(root: Path, path: Path) -> Path:
    root = root.resolve(strict=True)
    try:
        candidate = path.parent.resolve(strict=True) / path.name
    except OSError as error:
        raise KnowledgePublisherError(
            "OUTPUT_PARENT_INVALID",
            path.parent.as_posix(),
        ) from error
    try:
        candidate.relative_to(root)
    except ValueError:
        pass
    else:
        raise KnowledgePublisherError(
            "OUTPUT_INSIDE_REPOSITORY",
            candidate.as_posix(),
        )
    if candidate.exists() or candidate.is_symlink():
        raise KnowledgePublisherError(
            "OUTPUT_ALREADY_EXISTS",
            candidate.as_posix(),
        )
    candidate.mkdir(mode=0o700)
    return candidate


def _private_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise KnowledgePublisherError(
            "OUTPUT_DIRECTORY_INVALID",
            path.parent.as_posix(),
        )
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=str(root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    if result.returncode != 0:
        raise KnowledgePublisherError(
            "GIT_COMMAND_FAILED",
            (result.stderr or result.stdout)[-1000:].strip(),
        )
    return result.stdout.strip()


def _business_module(root: Path) -> Any:
    path = _regular(
        root
        / "ios/harness/business-knowledge/business_knowledge.py",
        "business knowledge control",
    )
    spec = importlib.util.spec_from_file_location(
        "publisher_business_knowledge_control",
        path,
    )
    if spec is None or spec.loader is None:
        raise KnowledgePublisherError("BUSINESS_CONTROL_IMPORT_FAILED")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _validate_schema(
    control: Any,
    root: Path,
    value: Dict[str, Any],
    schema_name: str,
    label: str,
) -> None:
    schema = _json(
        root
        / "ios/harness/business-knowledge/schemas"
        / schema_name,
        schema_name,
    )
    errors = control.validate_schema(value, schema)
    if errors:
        raise KnowledgePublisherError(
            "SCHEMA_INVALID",
            f"{label}: {'; '.join(errors)}",
        )


def _pointer(document: Any, pointer: str) -> Any:
    if not isinstance(pointer, str) or not pointer.startswith("/"):
        raise KnowledgePublisherError("JSON_POINTER_INVALID", str(pointer))
    current = document
    for raw_token in pointer[1:].split("/"):
        token = raw_token.replace("~1", "/").replace("~0", "~")
        if isinstance(current, dict):
            if token not in current:
                raise KnowledgePublisherError(
                    "JSON_POINTER_MISSING",
                    pointer,
                )
            current = current[token]
        elif isinstance(current, list):
            if not token.isdigit() or (
                len(token) > 1 and token.startswith("0")
            ):
                raise KnowledgePublisherError(
                    "JSON_POINTER_INVALID_INDEX",
                    pointer,
                )
            index = int(token)
            if index >= len(current):
                raise KnowledgePublisherError(
                    "JSON_POINTER_MISSING",
                    pointer,
                )
            current = current[index]
        else:
            raise KnowledgePublisherError("JSON_POINTER_MISSING", pointer)
    return current


def _producer_completed(
    root: Path,
    *,
    producer_id: str,
    outputs: Sequence[Tuple[str, str, int]],
) -> Dict[str, str]:
    if WORK_ITEM_ID.fullmatch(producer_id) is None:
        raise KnowledgePublisherError("PRODUCER_ID_INVALID", producer_id)
    work_item = _json(
        root / "ios/harness/work-items" / f"{producer_id}.json",
        "producer Work Item",
    )
    if work_item.get("metadata", {}).get("id") != producer_id:
        raise KnowledgePublisherError("PRODUCER_WORK_ITEM_DRIFT")
    declared = {
        (
            output.get("kind"),
            output.get("id"),
            output.get("revision"),
        )
        for output in work_item.get("spec", {})
        .get("knowledge", {})
        .get("produces", [])
        if isinstance(output, dict)
    }
    if not set(outputs).issubset(declared):
        raise KnowledgePublisherError("PRODUCER_OUTPUT_UNDECLARED")
    state = _json(root / "ios/project/state.json", "Harness state")
    runtime = state.get("work_items", {}).get(producer_id)
    if not isinstance(runtime, dict) or runtime.get("status") != "completed":
        raise KnowledgePublisherError("PRODUCER_NOT_COMPLETED")
    evidence_ref = runtime.get("last_evidence")
    if not isinstance(evidence_ref, str):
        raise KnowledgePublisherError("PRODUCER_EVIDENCE_MISSING")
    evidence_path, evidence_ref = _relative_regular(
        root,
        evidence_ref,
        "producer Evidence",
    )
    checkpoint = _json(
        root / "ios/project/checkpoints" / f"{producer_id}.json",
        "producer Checkpoint",
    )
    if (
        checkpoint.get("work_item_id") != producer_id
        or checkpoint.get("evidence") != evidence_ref
    ):
        raise KnowledgePublisherError("PRODUCER_CHECKPOINT_DRIFT")
    return {
        "work_item": producer_id,
        "work_item_sha256": _sha256(
            (root / "ios/harness/work-items" / f"{producer_id}.json").read_bytes()
        ),
        "evidence": evidence_ref,
        "evidence_sha256": _sha256(evidence_path.read_bytes()),
        "checkpoint": (
            f"ios/project/checkpoints/{producer_id}.json"
        ),
        "checkpoint_sha256": _sha256(
            _canonical_bytes(checkpoint)
        ),
    }


def _requirement_refs(
    root: Path,
    references: Sequence[str],
) -> List[str]:
    if not references or len(set(references)) != len(references):
        raise KnowledgePublisherError("REQUIREMENT_REFS_INVALID")
    catalog = _json(
        root / "ios/project/requirements/catalog.json",
        "Requirement Catalog",
    )
    records = {
        (record.get("id"), record.get("revision")): record
        for record in catalog.get("requirements", [])
        if isinstance(record, dict)
    }
    result: List[str] = []
    for reference in references:
        match = REQUIREMENT_REF.fullmatch(reference)
        if match is None:
            raise KnowledgePublisherError(
                "REQUIREMENT_REF_INVALID",
                reference,
            )
        identifier, raw_revision, clause = match.groups()
        record = records.get((identifier, int(raw_revision)))
        if record is None or clause not in record.get("clauses", []):
            raise KnowledgePublisherError(
                "REQUIREMENT_REF_UNKNOWN",
                reference,
            )
        result.append(reference)
    return sorted(result)


def _validate_time(value: str) -> str:
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise KnowledgePublisherError("PUBLISHED_AT_INVALID") from error
    if parsed.tzinfo is None or not value.endswith("Z"):
        raise KnowledgePublisherError("PUBLISHED_AT_INVALID")
    return value


def _copy_path(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(source, destination)
    elif source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
    else:
        raise KnowledgePublisherError(
            "VERIFIER_INPUT_MISSING",
            source.as_posix(),
        )


def _verifier_tree(root: Path, destination: Path) -> Path:
    relative_paths = (
        "ios/harness/business-knowledge",
        "ios/harness/evidence",
        "ios/harness/harness.py",
        "ios/harness/work-items",
        "ios/docs/adr",
        "ios/project/android-intake/inventory-manifest.json",
        "ios/project/baseline.json",
        "ios/project/business-knowledge",
        "ios/project/capabilities",
        "ios/project/checkpoints",
        "ios/project/events.jsonl",
        "ios/project/requirements/catalog.json",
        "ios/project/state.json",
    )
    destination.mkdir(mode=0o700)
    for relative in relative_paths:
        _copy_path(root / relative, destination / relative)
    return destination


def _published_entries(
    control: Any,
    root: Path,
    relative_directory: str,
) -> List[Dict[str, Any]]:
    return control._records(root, relative_directory, "r*.json")


def _entry_id(claim_id: str) -> str:
    if CLAIM_ID.fullmatch(claim_id) is None:
        raise KnowledgePublisherError("CLAIM_ID_INVALID", claim_id)
    return "BKE-" + claim_id.removeprefix("BKC-")


def _install_bytes(
    root: Path,
    relative: str,
    payload: bytes,
) -> None:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def prepare(
    root: Path,
    *,
    source_commit: str,
    authorized_run_id: str,
    packet_proposal: str,
    packet_proposal_sha256: str,
    driver_proposal: str,
    driver_proposal_sha256: str,
    golden_receipt: str,
    golden_receipt_sha256: str,
    requirement_refs: Sequence[str],
    target_work_item: str,
    approved_by: str,
    published_at: str,
    output_dir: Path,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    if HEX40.fullmatch(source_commit) is None:
        raise KnowledgePublisherError("SOURCE_COMMIT_INVALID")
    if RUN_ID.fullmatch(authorized_run_id) is None:
        raise KnowledgePublisherError("AUTHORIZED_RUN_ID_INVALID")
    for label, digest in (
        ("packet", packet_proposal_sha256),
        ("driver", driver_proposal_sha256),
        ("golden receipt", golden_receipt_sha256),
    ):
        if HEX64.fullmatch(digest) is None:
            raise KnowledgePublisherError(
                "AUTHORIZED_SHA256_INVALID",
                label,
            )
    if WORK_ITEM_ID.fullmatch(target_work_item) is None:
        raise KnowledgePublisherError("TARGET_WORK_ITEM_INVALID")
    if not approved_by or any(
        character in approved_by for character in "\r\n"
    ):
        raise KnowledgePublisherError("APPROVED_BY_INVALID")
    published_at = _validate_time(published_at)
    if _git(root, "rev-parse", "HEAD") != source_commit:
        raise KnowledgePublisherError("SOURCE_COMMIT_DRIFT")
    if _git(root, "status", "--porcelain=v1", "--untracked-files=all"):
        raise KnowledgePublisherError("SOURCE_TREE_DIRTY")

    packet_path, packet_relative = _relative_regular(
        root,
        packet_proposal,
        "packet proposal",
    )
    driver_path, driver_relative = _relative_regular(
        root,
        driver_proposal,
        "driver proposal",
    )
    receipt_path, receipt_relative = _relative_regular(
        root,
        golden_receipt,
        "Golden release receipt",
    )
    if _sha256(packet_path.read_bytes()) != packet_proposal_sha256:
        raise KnowledgePublisherError("PACKET_PROPOSAL_SHA256_DRIFT")
    if _sha256(driver_path.read_bytes()) != driver_proposal_sha256:
        raise KnowledgePublisherError("DRIVER_PROPOSAL_SHA256_DRIFT")
    if _sha256(receipt_path.read_bytes()) != golden_receipt_sha256:
        raise KnowledgePublisherError("GOLDEN_RECEIPT_SHA256_DRIFT")

    control = _business_module(root)
    packet = _json(packet_path, "packet proposal")
    driver = _json(driver_path, "driver proposal")
    receipt = _json(receipt_path, "Golden release receipt")
    _validate_schema(
        control,
        root,
        packet,
        "business-knowledge-packet.schema.json",
        "Packet",
    )
    _validate_schema(
        control,
        root,
        driver,
        "architecture-driver.schema.json",
        "Driver",
    )
    if (
        packet.get("status") != "candidate"
        or not packet_relative.endswith(
            f"/packets/proposals/{packet.get('id')}/"
            f"r{packet.get('revision', 0):04d}.json"
        )
    ):
        raise KnowledgePublisherError("PACKET_PROPOSAL_AUTHORITY_INVALID")
    if (
        driver.get("status") != "proposed"
        or driver.get("promotion") is not None
        or not driver_relative.endswith(
            f"/drivers/proposals/{driver.get('id')}/"
            f"r{driver.get('revision', 0):04d}.json"
        )
    ):
        raise KnowledgePublisherError("DRIVER_PROPOSAL_AUTHORITY_INVALID")
    packet_id = packet.get("id")
    driver_id = driver.get("id")
    packet_revision = packet.get("revision")
    driver_revision = driver.get("revision")
    if (
        not isinstance(packet_id, str)
        or PACKET_ID.fullmatch(packet_id) is None
        or not isinstance(driver_id, str)
        or DRIVER_ID.fullmatch(driver_id) is None
        or not isinstance(packet_revision, int)
        or not isinstance(driver_revision, int)
    ):
        raise KnowledgePublisherError("PROPOSAL_ID_INVALID")
    if packet.get("created_by") != driver.get("created_by"):
        raise KnowledgePublisherError("PROPOSAL_BATCH_OWNER_DRIFT")
    producer = _producer_completed(
        root,
        producer_id=str(packet.get("created_by")),
        outputs=(
            ("packet", packet_id, packet_revision),
            ("driver", driver_id, driver_revision),
        ),
    )

    if (
        receipt.get("kind") != "android_golden_release"
        or receipt.get("authority") != "protected_android_golden"
        or receipt.get("authorization") != "github_environment_review"
    ):
        raise KnowledgePublisherError("GOLDEN_RECEIPT_AUTHORITY_INVALID")
    golden_path, golden_relative = _relative_regular(
        root,
        str(receipt.get("golden_path")),
        "protected Golden",
    )
    golden_bytes = golden_path.read_bytes()
    golden_sha256 = _sha256(golden_bytes)
    if golden_sha256 != receipt.get("golden_sha256"):
        raise KnowledgePublisherError("GOLDEN_PAYLOAD_SHA256_DRIFT")
    golden = _json(golden_path, "protected Golden")
    manifest = _json(
        root / "ios/harness/goldens/manifest.json",
        "Golden manifest",
    )
    fixture_id = receipt.get("fixture_id")
    manifest_entry = manifest.get("fixtures", {}).get(fixture_id)
    oracle = manifest.get("oracle")
    if (
        not isinstance(manifest_entry, dict)
        or not isinstance(oracle, dict)
        or manifest_entry.get("path") != golden_relative
        or manifest_entry.get("golden_sha256") != golden_sha256
        or manifest_entry.get("release_receipt") != receipt_relative
    ):
        raise KnowledgePublisherError("GOLDEN_MANIFEST_BINDING_DRIFT")
    if packet.get("baseline", {}).get(
        "android_commit"
    ) != oracle.get("android_git_commit"):
        raise KnowledgePublisherError("PACKET_ANDROID_BASELINE_DRIFT")

    claims = packet.get("claims")
    if not isinstance(claims, list) or not claims:
        raise KnowledgePublisherError("PACKET_CLAIMS_INVALID")
    claim_refs = []
    for claim in claims:
        if not isinstance(claim, dict):
            raise KnowledgePublisherError("CLAIM_INVALID")
        support = claim.get("support")
        evidence = (
            support.get("runtime_evidence")
            if isinstance(support, dict)
            else None
        )
        if (
            claim.get("kind") != "runtime_behavior"
            or support.get("state") != "runtime_verified"
            or support.get("runtime_requirement")
            != "android_characterization"
            or not isinstance(evidence, list)
            or len(evidence) != 1
        ):
            raise KnowledgePublisherError(
                "RUNTIME_CLAIM_NOT_PUBLISHABLE",
                str(claim.get("id")),
            )
        runtime = evidence[0]
        if (
            runtime.get("relation") != "supports"
            or runtime.get("kind") != "android_characterization"
            or runtime.get("artifact_uri") != golden_relative
            or runtime.get("artifact_sha256") != golden_sha256
            or runtime.get("android_commit")
            != oracle.get("android_git_commit")
            or runtime.get("runner_digest")
            != oracle.get("runner_digest")
            or runtime.get("canonicalizer_sha256")
            != manifest.get("canonicalizer_sha256")
        ):
            raise KnowledgePublisherError(
                "RUNTIME_EVIDENCE_BINDING_DRIFT",
                str(claim.get("id")),
            )
        projection = _pointer(
            golden,
            runtime.get("projection_pointer"),
        )
        actual_observed = _sha256(_canonical_bytes(projection))
        if actual_observed != runtime.get("observed_sha256"):
            raise KnowledgePublisherError(
                "OBSERVED_PROJECTION_SHA256_DRIFT",
                str(claim.get("id")),
            )
        claim_refs.append(
            {
                "id": claim.get("id"),
                "revision": claim.get("revision"),
            }
        )
    if sorted(
        (value.get("id"), value.get("revision"))
        for value in driver.get("claim_refs", [])
    ) != sorted(
        (value.get("id"), value.get("revision"))
        for value in claim_refs
    ):
        raise KnowledgePublisherError("DRIVER_CLAIM_SELECTION_DRIFT")
    if (
        driver.get("resolution", {}).get("state") != "resolved"
        or not driver.get("resolution", {}).get("adr_refs")
    ):
        raise KnowledgePublisherError("DRIVER_NOT_RESOLVED")

    resolved_requirements = _requirement_refs(root, requirement_refs)
    output = _external_empty_directory(root, output_dir)
    published_packet_relative = (
        "ios/project/business-knowledge/packets/published/"
        f"{packet_id}/r{packet_revision:04d}.json"
    )
    published_driver_relative = (
        "ios/project/business-knowledge/drivers/published/"
        f"{driver_id}/r{driver_revision:04d}.json"
    )
    ledger_id = "BKL-" + packet_id.removeprefix("BKP-")
    ledger_relative = (
        f"ios/project/business-knowledge/coverage/{ledger_id}.json"
    )
    release_relative = (
        "ios/project/business-knowledge/releases/"
        f"{packet_id}-r{packet_revision:04d}-"
        f"{authorized_run_id.replace('/', '-')}.json"
    )
    catalog_relative = "ios/project/business-knowledge/catalog.json"
    for relative in (
        published_packet_relative,
        published_driver_relative,
        ledger_relative,
        release_relative,
    ):
        if (root / relative).exists() or (root / relative).is_symlink():
            raise KnowledgePublisherError(
                "PUBLICATION_TARGET_ALREADY_EXISTS",
                relative,
            )

    published_packet = copy.deepcopy(packet)
    published_packet["status"] = "published"
    published_driver = copy.deepcopy(driver)
    published_driver["status"] = "resolved"
    published_driver["promotion"] = {
        "approval_ref": (
            f"{PUBLISHER_ID}:{authorized_run_id}"
        ),
        "approved_by": approved_by,
    }
    packet_bytes = _canonical_bytes(published_packet)
    driver_bytes = _canonical_bytes(published_driver)

    with tempfile.TemporaryDirectory(
        prefix="business-knowledge-verifier-"
    ) as raw_verifier:
        verifier = _verifier_tree(root, Path(raw_verifier) / "repo")
        (verifier / packet_relative).unlink()
        (verifier / driver_relative).unlink()
        _install_bytes(
            verifier,
            published_packet_relative,
            packet_bytes,
        )
        _install_bytes(
            verifier,
            published_driver_relative,
            driver_bytes,
        )
        verifier_control = _business_module(verifier)
        policy = _json(
            verifier
            / "ios/harness/business-knowledge/policy-v1.json",
            "Business Knowledge policy",
        )
        baseline = _json(
            verifier / "ios/project/baseline.json",
            "baseline",
        )
        inventory = _json(
            verifier
            / "ios/project/android-intake/inventory-manifest.json",
            "inventory",
        )
        packet_entries = _published_entries(
            verifier_control,
            verifier,
            policy["directories"]["published_packets"],
        )
        driver_entries = _published_entries(
            verifier_control,
            verifier,
            policy["directories"]["published_drivers"],
        )
        authority_sha256 = verifier_control._authority_digest(
            verifier,
            policy,
            baseline.get("android_oracle", {}).get("git_commit"),
            inventory.get("control_sha256"),
            packet_entries,
            driver_entries,
        )
        requirement_catalog = _json(
            verifier / "ios/project/requirements/catalog.json",
            "Requirement Catalog",
        )
        ledger = {
            "schema_version": 1,
            "kind": "BusinessKnowledgeCoverageLedger",
            "id": ledger_id,
            "revision": 1,
            "status": "current",
            "packet_refs": [
                {
                    "id": packet_id,
                    "revision": packet_revision,
                }
            ],
            "generated_from": {
                "knowledge_authority_sha256": authority_sha256,
                "requirement_catalog_sha256": (
                    verifier_control.sha256_json(requirement_catalog)
                ),
                "architecture_digest_sha256": (
                    baseline.get("architecture", {}).get("digest")
                ),
            },
            "entries": [
                {
                    "id": _entry_id(str(claim["id"])),
                    "claim_ref": {
                        "id": claim["id"],
                        "revision": claim["revision"],
                    },
                    "validation": {
                        "required": "android_runtime",
                        "state": "verified",
                        "evidence_refs": [
                            receipt_relative,
                            (
                                f"{golden_relative}#"
                                f"{claim['support']['runtime_evidence'][0]['projection_pointer']}"
                            ),
                        ],
                        "blockers": [],
                    },
                    "product_disposition": {
                        "kind": "covered_by_requirement",
                        "refs": resolved_requirements,
                        "reason": (
                            "受保护 Android Golden 已冻结该 HTML/CSS "
                            "纵向行为，交由绑定 Requirement 实现"
                        ),
                        "review_after": None,
                    },
                    "delivery": {
                        "state": "planned",
                        "requirement_refs": resolved_requirements,
                        "work_item_refs": [
                            target_work_item
                        ],
                        "capability_refs": sorted(
                            packet["scope"]["capability_refs"]
                        ),
                        "evidence_refs": [
                            receipt_relative
                        ],
                    },
                    "computed": {
                        "accounted": True,
                        "coverage_state": "covered",
                    },
                }
                for claim in claims
            ],
            "updated_by": str(packet.get("created_by")),
            "updated_at": published_at,
        }
        ledger_bytes = _canonical_bytes(ledger)
        _install_bytes(verifier, ledger_relative, ledger_bytes)
        try:
            catalog = verifier_control.catalog_value(verifier)
        except Exception as error:
            raise KnowledgePublisherError(
                "STAGED_GRAPH_INVALID",
                str(error),
            ) from error
        catalog_bytes = _canonical_bytes(catalog)
        _install_bytes(verifier, catalog_relative, catalog_bytes)
        errors = verifier_control.doctor(verifier)
        if errors:
            raise KnowledgePublisherError(
                "STAGED_GRAPH_INVALID",
                "; ".join(errors),
            )

    installed_payloads = {
        published_packet_relative: packet_bytes,
        published_driver_relative: driver_bytes,
        ledger_relative: ledger_bytes,
        catalog_relative: catalog_bytes,
    }
    receipt_record = {
        "schema_version": 1,
        "kind": "business_knowledge_release",
        "authority": "protected_business_knowledge",
        "authorization": "github_environment_review",
        "publisher": PUBLISHER_ID,
        "publisher_run_id": authorized_run_id,
        "approved_by": approved_by,
        "published_at": published_at,
        "source_commit": source_commit,
        "producer": producer,
        "inputs": {
            "packet_proposal": packet_relative,
            "packet_proposal_sha256": packet_proposal_sha256,
            "driver_proposal": driver_relative,
            "driver_proposal_sha256": driver_proposal_sha256,
            "golden_receipt": receipt_relative,
            "golden_receipt_sha256": golden_receipt_sha256,
            "golden_sha256": golden_sha256,
        },
        "bindings": {
            "packet": {
                "id": packet_id,
                "revision": packet_revision,
            },
            "driver": {
                "id": driver_id,
                "revision": driver_revision,
            },
            "ledger": {
                "id": ledger_id,
                "revision": 1,
            },
            "knowledge_authority_sha256": authority_sha256,
            "requirement_refs": resolved_requirements,
            "target_work_item": target_work_item,
        },
        "outputs": {
            relative: _sha256(payload)
            for relative, payload in sorted(installed_payloads.items())
        },
        "deletions": [
            driver_relative,
            packet_relative,
        ],
    }
    receipt_bytes = _canonical_bytes(receipt_record)
    installed_payloads[release_relative] = receipt_bytes
    for relative, payload in sorted(installed_payloads.items()):
        _private_write(output / relative, payload)
    transaction = {
        "schema_version": 1,
        "kind": "business_knowledge_publication_transaction",
        "authority": "protected_business_knowledge",
        "source_commit": source_commit,
        "publisher_run_id": authorized_run_id,
        "install": [
            {
                "path": relative,
                "sha256": _sha256(payload),
            }
            for relative, payload in sorted(installed_payloads.items())
        ],
        "delete": sorted(
            [
                driver_relative,
                packet_relative,
            ]
        ),
        "receipt": release_relative,
        "knowledge_authority_sha256": authority_sha256,
    }
    transaction_bytes = _canonical_bytes(transaction)
    _private_write(output / "transaction.json", transaction_bytes)
    return {
        "schema_version": 1,
        "status": "staged_for_external_publisher",
        "authority": "protected_business_knowledge",
        "packet": f"{packet_id}@{packet_revision}",
        "driver": f"{driver_id}@{driver_revision}",
        "ledger": f"{ledger_id}@1",
        "knowledge_authority_sha256": authority_sha256,
        "transaction_sha256": _sha256(transaction_bytes),
        "install_count": len(installed_payloads),
        "delete_count": 2,
    }


def main(argv: Any = None) -> int:
    parser = argparse.ArgumentParser(
        prog="business-knowledge-publisher",
    )
    subparsers = parser.add_subparsers(
        dest="command",
        required=True,
    )
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--root", type=Path, required=True)
    prepare_parser.add_argument("--source-commit", required=True)
    prepare_parser.add_argument("--authorized-run-id", required=True)
    prepare_parser.add_argument("--packet-proposal", required=True)
    prepare_parser.add_argument(
        "--packet-proposal-sha256",
        required=True,
    )
    prepare_parser.add_argument("--driver-proposal", required=True)
    prepare_parser.add_argument(
        "--driver-proposal-sha256",
        required=True,
    )
    prepare_parser.add_argument("--golden-receipt", required=True)
    prepare_parser.add_argument(
        "--golden-receipt-sha256",
        required=True,
    )
    prepare_parser.add_argument(
        "--requirement-ref",
        action="append",
        required=True,
    )
    prepare_parser.add_argument(
        "--target-work-item",
        required=True,
    )
    prepare_parser.add_argument("--approved-by", required=True)
    prepare_parser.add_argument("--published-at", required=True)
    prepare_parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
    )
    args = parser.parse_args(argv)
    try:
        report = prepare(
            args.root,
            source_commit=args.source_commit,
            authorized_run_id=args.authorized_run_id,
            packet_proposal=args.packet_proposal,
            packet_proposal_sha256=(
                args.packet_proposal_sha256
            ),
            driver_proposal=args.driver_proposal,
            driver_proposal_sha256=(
                args.driver_proposal_sha256
            ),
            golden_receipt=args.golden_receipt,
            golden_receipt_sha256=(
                args.golden_receipt_sha256
            ),
            requirement_refs=args.requirement_ref,
            target_work_item=args.target_work_item,
            approved_by=args.approved_by,
            published_at=args.published_at,
            output_dir=args.output_dir,
        )
    except KnowledgePublisherError as error:
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "ok": False,
                    "reason_code": error.reason_code,
                    "detail": error.detail,
                },
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            )
        )
        return 2
    print(
        json.dumps(
            report,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
