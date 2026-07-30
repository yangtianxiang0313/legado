#!/usr/bin/env python3
"""Stage an attested Android Oracle candidate as a deterministic Golden release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping, Tuple


COMMANDS = ("prepare",)
PROFILE = "android-legado-v1"
PUBLISHER_ID = "github-actions:android-golden-publisher-v2"
AUTHORIZATION = "github_actions_push_v2"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RUN_ID = re.compile(r"[1-9][0-9]*/[1-9][0-9]*\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SCENARIO = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")


class GoldenPublisherError(RuntimeError):
    def __init__(self, reason_code: str, detail: str = ""):
        super().__init__(reason_code)
        self.reason_code = reason_code
        self.detail = detail


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical_bytes(exact_json: Any, value: Any) -> bytes:
    def convert(node: Any) -> Any:
        if isinstance(node, bool) or node is None or isinstance(
            node,
            (str, exact_json.NumberToken),
        ):
            return node
        if isinstance(node, int):
            return exact_json.NumberToken(str(node))
        if isinstance(node, list):
            return [convert(entry) for entry in node]
        if isinstance(node, dict):
            return {
                key: convert(entry)
                for key, entry in node.items()
            }
        raise GoldenPublisherError(
            "UNSUPPORTED_JSON_VALUE",
            type(node).__name__,
        )

    return exact_json.dumps(convert(value))


def _safe_regular(path: Path) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise GoldenPublisherError(
            "REGULAR_FILE_REQUIRED",
            path.as_posix(),
        ) from error
    if path.is_symlink() or not resolved.is_file():
        raise GoldenPublisherError(
            "REGULAR_FILE_REQUIRED",
            path.as_posix(),
        )
    return resolved


def _external_empty_directory(root: Path, path: Path) -> Path:
    root = root.resolve(strict=True)
    try:
        candidate = path.parent.resolve(strict=True) / path.name
    except OSError as error:
        raise GoldenPublisherError(
            "OUTPUT_PARENT_INVALID",
            path.parent.as_posix(),
        ) from error
    try:
        candidate.relative_to(root)
    except ValueError:
        pass
    else:
        raise GoldenPublisherError(
            "OUTPUT_INSIDE_REPOSITORY",
            candidate.as_posix(),
        )
    if candidate.exists() or candidate.is_symlink():
        raise GoldenPublisherError(
            "OUTPUT_ALREADY_EXISTS",
            candidate.as_posix(),
        )
    candidate.mkdir(mode=0o700)
    if candidate.is_symlink() or not candidate.is_dir():
        raise GoldenPublisherError(
            "OUTPUT_DIRECTORY_INVALID",
            candidate.as_posix(),
        )
    return candidate


def _private_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise GoldenPublisherError(
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


def _oracle_modules(root: Path) -> Tuple[Any, Any, Any]:
    harness_root = root / "ios/harness"
    if not harness_root.is_dir():
        raise GoldenPublisherError("HARNESS_ROOT_INVALID")
    harness_text = str(harness_root)
    if harness_text not in sys.path:
        sys.path.insert(0, harness_text)
    try:
        from oracle import ci_proposal, exact_json, trusted_import
    except ImportError as error:
        raise GoldenPublisherError("ORACLE_IMPORT_FAILED") from error
    return ci_proposal, trusted_import, exact_json


def _object(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise GoldenPublisherError("OBJECT_REQUIRED", label)
    return value


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise GoldenPublisherError("STRING_REQUIRED", label)
    return value


def _scenario(value: str) -> str:
    if not isinstance(value, str) or SCENARIO.fullmatch(value) is None:
        raise GoldenPublisherError("SCENARIO_SELECTOR_INVALID")
    return value


def _fixture_binding(
    oracle_root: Path,
    scenario_id: str,
    exact_json: Any,
) -> Tuple[str, str]:
    manifest_path = (
        oracle_root / "ios/harness/fixtures/manifest.json"
    )
    manifest_bytes = _safe_regular(manifest_path).read_bytes()
    try:
        manifest = _object(
            exact_json.loads(manifest_bytes),
            "fixture manifest",
        )
    except (UnicodeError, ValueError) as error:
        raise GoldenPublisherError(
            "GOLDEN_FIXTURE_BINDING_DRIFT"
        ) from error
    fixtures = manifest.get("fixtures")
    matches = [
        entry
        for entry in fixtures
        if isinstance(entry, dict) and entry.get("id") == scenario_id
    ] if isinstance(fixtures, list) else []
    if len(matches) != 1:
        raise GoldenPublisherError("GOLDEN_FIXTURE_BINDING_DRIFT")
    entry = matches[0]
    path = entry.get("path")
    digest = entry.get("sha256")
    if (
        manifest.get("compatibility_profile") != PROFILE
        or path not in {
            f"ios/harness/fixtures/source-lab/{scenario_id}",
            f"ios/harness/fixtures/runtime-lab/{scenario_id}",
            f"ios/harness/fixtures/integration-lab/{scenario_id}",
        }
        or not isinstance(digest, str)
        or HEX64.fullmatch(digest) is None
    ):
        raise GoldenPublisherError("GOLDEN_FIXTURE_BINDING_DRIFT")
    return path, digest


def _migrate_manifest(
    manifest: Mapping[str, Any],
) -> tuple[Dict[str, Any], Dict[str, Any]]:
    schema_node = manifest.get("schema_version")
    schema_version = str(
        getattr(schema_node, "token", schema_node or "")
    )
    if schema_version not in {"1", "2"}:
        raise GoldenPublisherError("GOLDEN_MANIFEST_SCHEMA_INVALID")
    oracle = _object(manifest.get("oracle"), "golden manifest oracle")
    fixtures = _object(
        manifest.get("fixtures"),
        "golden manifest fixtures",
    )
    android_commit = _string(
        oracle.get("android_git_commit"),
        "golden manifest oracle android_git_commit",
    )
    profile = _string(
        oracle.get("profile"),
        "golden manifest oracle profile",
    )
    canonicalizer = _string(
        manifest.get("canonicalizer_sha256"),
        "golden manifest canonicalizer_sha256",
    )
    if (
        HEX40.fullmatch(android_commit) is None
        or HEX64.fullmatch(canonicalizer) is None
    ):
        raise GoldenPublisherError("GOLDEN_MANIFEST_CONTROL_INVALID")
    migrated: Dict[str, Any] = {}
    for fixture_id in sorted(fixtures):
        entry = dict(_object(fixtures[fixture_id], fixture_id))
        if schema_version == "1":
            entry.setdefault("android_git_commit", android_commit)
            entry.setdefault("profile", profile)
            entry.setdefault(
                "runner_digest",
                oracle.get("runner_digest"),
            )
            entry.setdefault(
                "runner_image_digest",
                oracle.get("runner_image_digest"),
            )
            entry.setdefault(
                "canonicalizer_sha256",
                canonicalizer,
            )
            entry.setdefault(
                "authorization",
                "github_environment_review",
            )
        required = {
            "android_git_commit": HEX40,
            "runner_digest": HEX64,
            "canonicalizer_sha256": HEX64,
        }
        if any(
            pattern.fullmatch(str(entry.get(field, ""))) is None
            for field, pattern in required.items()
        ):
            raise GoldenPublisherError(
                "GOLDEN_MANIFEST_FIXTURE_CONTROL_INVALID",
                fixture_id,
            )
        for field in (
            "profile",
            "runner_image_digest",
            "authorization",
        ):
            _string(entry.get(field), f"{fixture_id}.{field}")
        if (
            entry["android_git_commit"] != android_commit
            or entry["profile"] != profile
            or entry["canonicalizer_sha256"] != canonicalizer
        ):
            raise GoldenPublisherError(
                "GOLDEN_MANIFEST_BASELINE_DRIFT",
                fixture_id,
            )
        migrated[fixture_id] = entry
    controls = {
        "android_git_commit": android_commit,
        "profile": profile,
        "canonicalizer_sha256": canonicalizer,
    }
    return migrated, controls


def prepare(
    root: Path,
    *,
    oracle_root: Path | None = None,
    scenario_id: str,
    proposal_archive: Path,
    proposal_attestation_bundle: Path,
    evidence_archive: Path,
    evidence_attestation_bundle: Path,
    repository: str,
    gh: Path,
    authorized_run_id: str,
    authorized_source_digest: str,
    authorized_proposal_sha256: str,
    output_dir: Path,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    oracle_root = (
        root
        if oracle_root is None
        else oracle_root.resolve(strict=True)
    )
    scenario_id = _scenario(scenario_id)
    if REPOSITORY.fullmatch(repository) is None:
        raise GoldenPublisherError("REPOSITORY_INVALID")
    if RUN_ID.fullmatch(authorized_run_id) is None:
        raise GoldenPublisherError("AUTHORIZED_RUN_ID_INVALID")
    if HEX40.fullmatch(authorized_source_digest) is None:
        raise GoldenPublisherError("AUTHORIZED_SOURCE_DIGEST_INVALID")
    if HEX64.fullmatch(authorized_proposal_sha256) is None:
        raise GoldenPublisherError("AUTHORIZED_PROPOSAL_SHA256_INVALID")

    proposal_archive = _safe_regular(proposal_archive)
    proposal_attestation_bundle = _safe_regular(
        proposal_attestation_bundle
    )
    evidence_archive = _safe_regular(evidence_archive)
    evidence_attestation_bundle = _safe_regular(
        evidence_attestation_bundle
    )
    ci_proposal, trusted_import, exact_json = _oracle_modules(
        oracle_root
    )

    trusted_report = trusted_import.verify(
        oracle_root,
        proposal_archive=proposal_archive,
        proposal_attestation_bundle=proposal_attestation_bundle,
        evidence_archive=evidence_archive,
        evidence_attestation_bundle=evidence_attestation_bundle,
        repository=repository,
        gh=gh,
        scenario_id=scenario_id,
    )
    if (
        trusted_report.get("authority") != "candidate_only"
        or trusted_report.get("status") != "verified_for_human_review"
        or trusted_report.get("next_authority")
        != "independent_golden_publisher"
        or trusted_report.get("source_digest")
        != authorized_source_digest
        or trusted_report.get("proposal_sha256")
        != authorized_proposal_sha256
        or trusted_report.get("scenario_id") != scenario_id
        or trusted_report.get("fixture_ids") != [scenario_id]
    ):
        raise GoldenPublisherError("TRUSTED_IMPORT_BINDING_DRIFT")

    proposal_members = ci_proposal.read_deterministic_tar(
        proposal_archive,
        ci_proposal.expected_proposal_members(scenario_id),
    )
    evidence_members = ci_proposal.read_deterministic_tar(
        evidence_archive,
        ci_proposal.expected_evidence_members(scenario_id),
    )
    proposal_bytes = proposal_members["proposal/proposal.json"]
    payload_name = f"proposal/payloads/{scenario_id}.json"
    evidence_payload_name = f"evidence/payloads/{scenario_id}.json"
    payload_bytes = proposal_members[payload_name]
    if payload_bytes != evidence_members[evidence_payload_name]:
        raise GoldenPublisherError("EVIDENCE_PROPOSAL_PAYLOAD_DRIFT")
    proposal = _object(
        exact_json.loads(proposal_bytes),
        "proposal",
    )
    if exact_json.dumps(proposal) != proposal_bytes:
        raise GoldenPublisherError("PROPOSAL_JSON_NOT_CANONICAL")
    producer = _object(proposal.get("producer"), "proposal.producer")
    bindings = _object(proposal.get("bindings"), "proposal.bindings")
    fixtures = proposal.get("fixtures")
    if (
        proposal.get("authority") != "candidate_only"
        or producer.get("run_id") != authorized_run_id
        or not isinstance(fixtures, list)
        or len(fixtures) != 1
        or not isinstance(fixtures[0], dict)
        or fixtures[0].get("id") != scenario_id
        or fixtures[0].get("payload_sha256") != _sha256(payload_bytes)
        or trusted_report.get("proposal_sha256")
        != _sha256(proposal_bytes)
    ):
        raise GoldenPublisherError("PROPOSAL_AUTHORIZATION_DRIFT")
    fixture = _object(fixtures[0], "proposal.fixtures[0]")
    expected_fixture_path, expected_fixture_sha256 = _fixture_binding(
        oracle_root,
        scenario_id,
        exact_json,
    )
    if (
        bindings.get("compatibility_profile") != PROFILE
        or fixture.get("fixture_path")
        != expected_fixture_path
        or fixture.get("fixture_sha256")
        != expected_fixture_sha256
        or fixture.get("payload_path")
        != f"payloads/{scenario_id}.json"
    ):
        raise GoldenPublisherError("GOLDEN_FIXTURE_BINDING_DRIFT")

    manifest_path = root / "ios/harness/goldens/manifest.json"
    current_manifest = _object(
        exact_json.loads(_safe_regular(manifest_path).read_bytes()),
        "golden manifest",
    )
    current_fixtures, controls = _migrate_manifest(current_manifest)
    expected_controls = {
        "android_git_commit": _string(
            bindings.get("android_git_commit"),
            "android_git_commit",
        ),
        "profile": PROFILE,
        "canonicalizer_sha256": _string(
            bindings.get("canonicalizer_config_sha256"),
            "canonicalizer_config_sha256",
        ),
    }
    if controls != expected_controls:
        raise GoldenPublisherError("EXISTING_GOLDEN_BASELINE_DRIFT")

    proposal_archive_sha256 = _sha256(proposal_archive.read_bytes())
    evidence_archive_sha256 = _sha256(evidence_archive.read_bytes())
    proposal_attestation_sha256 = _sha256(
        proposal_attestation_bundle.read_bytes()
    )
    evidence_attestation_sha256 = _sha256(
        evidence_attestation_bundle.read_bytes()
    )
    golden_sha256 = _sha256(payload_bytes)
    golden_relative = f"{PROFILE}/{scenario_id}.json"
    release_relative = (
        "releases/"
        f"{scenario_id}-{authorized_run_id.replace('/', '-')}.json"
    )
    published_entry = {
        "path": f"ios/harness/goldens/{golden_relative}",
        "fixture_sha256": _string(
            fixture.get("fixture_sha256"),
            "fixture_sha256",
        ),
        "golden_sha256": golden_sha256,
        "operation": _string(fixture.get("operation"), "operation"),
        "proposal_sha256": authorized_proposal_sha256,
        "proposal_archive_sha256": proposal_archive_sha256,
        "evidence_archive_sha256": evidence_archive_sha256,
        "proposal_attestation_sha256": proposal_attestation_sha256,
        "evidence_attestation_sha256": evidence_attestation_sha256,
        "source_digest": authorized_source_digest,
        "run_id": authorized_run_id,
        "android_git_commit": expected_controls["android_git_commit"],
        "profile": PROFILE,
        "runner_digest": _string(
            bindings.get("runner_digest"),
            "runner_digest",
        ),
        "runner_image_digest": _string(
            bindings.get("runner_image_digest"),
            "runner_image_digest",
        ),
        "canonicalizer_sha256": expected_controls[
            "canonicalizer_sha256"
        ],
        "authorization": AUTHORIZATION,
        "release_receipt": (
            f"ios/harness/goldens/{release_relative}"
        ),
    }
    receipt = {
        "schema_version": 2,
        "kind": "android_golden_release",
        "authority": "protected_android_golden",
        "publisher": PUBLISHER_ID,
        "repository": repository,
        "fixture_id": scenario_id,
        "run_id": authorized_run_id,
        "source_digest": authorized_source_digest,
        "proposal_sha256": authorized_proposal_sha256,
        "proposal_archive_sha256": proposal_archive_sha256,
        "evidence_archive_sha256": evidence_archive_sha256,
        "proposal_attestation_sha256": proposal_attestation_sha256,
        "evidence_attestation_sha256": evidence_attestation_sha256,
        "golden_sha256": golden_sha256,
        "golden_path": (
            f"ios/harness/goldens/{golden_relative}"
        ),
        "previous_authority": "candidate_only",
        "authorization": AUTHORIZATION,
        "controls": {
            "android_git_commit": expected_controls[
                "android_git_commit"
            ],
            "profile": PROFILE,
            "runner_digest": published_entry["runner_digest"],
            "runner_image_digest": published_entry[
                "runner_image_digest"
            ],
            "canonicalizer_sha256": expected_controls[
                "canonicalizer_sha256"
            ],
        },
    }
    manifest = {
        "schema_version": 2,
        "oracle": {
            "android_git_commit": expected_controls[
                "android_git_commit"
            ],
            "profile": PROFILE,
        },
        "canonicalizer_sha256": expected_controls[
            "canonicalizer_sha256"
        ],
        "fixtures": {
            key: (
                published_entry
                if key == scenario_id
                else current_fixtures[key]
            )
            for key in sorted({*current_fixtures, scenario_id})
        },
    }
    manifest_bytes = _canonical_bytes(exact_json, manifest)
    receipt_bytes = _canonical_bytes(exact_json, receipt)

    existing = current_fixtures.get(scenario_id)
    if existing is not None:
        golden_path = root / published_entry["path"]
        receipt_path = root / published_entry["release_receipt"]
        try:
            exact_replay = (
                existing == published_entry
                and _safe_regular(golden_path).read_bytes()
                == payload_bytes
                and _safe_regular(receipt_path).read_bytes()
                == receipt_bytes
                and _safe_regular(manifest_path).read_bytes()
                == manifest_bytes
            )
        except GoldenPublisherError:
            exact_replay = False
        if not exact_replay:
            existing_golden_path = root / _string(
                existing.get("path"),
                "existing.path",
            )
            existing_receipt_relative = _string(
                existing.get("release_receipt"),
                "existing.release_receipt",
            )
            existing_receipt_path = root / existing_receipt_relative
            existing_golden_sha256 = _string(
                existing.get("golden_sha256"),
                "existing.golden_sha256",
            )
            existing_run_id = _string(
                existing.get("run_id"),
                "existing.run_id",
            )
            existing_source_digest = _string(
                existing.get("source_digest"),
                "existing.source_digest",
            )
            existing_proposal_sha256 = _string(
                existing.get("proposal_sha256"),
                "existing.proposal_sha256",
            )
            existing_receipt = _object(
                exact_json.loads(
                    _safe_regular(existing_receipt_path).read_bytes()
                ),
                "existing release receipt",
            )
            if (
                existing.get("path") != published_entry["path"]
                or _sha256(
                    _safe_regular(existing_golden_path).read_bytes()
                )
                != existing_golden_sha256
                or existing_receipt.get("authority")
                != "protected_android_golden"
                or existing_receipt.get("fixture_id") != scenario_id
                or existing_receipt.get("run_id") != existing_run_id
                or existing_receipt.get("source_digest")
                != existing_source_digest
                or existing_receipt.get("proposal_sha256")
                != existing_proposal_sha256
                or existing_receipt.get("golden_sha256")
                != existing_golden_sha256
                or existing_receipt.get("golden_path")
                != existing.get("path")
                or existing_run_id == authorized_run_id
                or receipt_path.exists()
            ):
                raise GoldenPublisherError(
                    "GOLDEN_ALREADY_PUBLISHED_CONFLICT"
                )
            receipt["supersedes"] = {
                "run_id": existing_run_id,
                "source_digest": existing_source_digest,
                "proposal_sha256": existing_proposal_sha256,
                "golden_sha256": existing_golden_sha256,
                "release_receipt": existing_receipt_relative,
            }
            receipt_bytes = _canonical_bytes(exact_json, receipt)
        else:
            return {
                "schema_version": 2,
                "status": "already_published",
                "authority": "protected_android_golden",
                "fixture_id": scenario_id,
                "run_id": authorized_run_id,
                "source_digest": authorized_source_digest,
                "golden_sha256": golden_sha256,
                "manifest_sha256": _sha256(manifest_bytes),
                "release_receipt_sha256": _sha256(receipt_bytes),
                "files": [],
            }

    output = _external_empty_directory(root, output_dir)
    _private_write(output / "manifest.json", manifest_bytes)
    _private_write(output / golden_relative, payload_bytes)
    _private_write(output / release_relative, receipt_bytes)
    return {
        "schema_version": 2,
        "status": "staged_for_external_publisher",
        "authority": "protected_android_golden",
        "fixture_id": scenario_id,
        "run_id": authorized_run_id,
        "source_digest": authorized_source_digest,
        "golden_sha256": golden_sha256,
        "manifest_sha256": _sha256(manifest_bytes),
        "release_receipt_sha256": _sha256(receipt_bytes),
        "files": [
            "manifest.json",
            golden_relative,
            release_relative,
        ],
    }


def main(argv: Any = None) -> int:
    parser = argparse.ArgumentParser(
        prog="android-golden-publisher",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--root", type=Path, required=True)
    prepare_parser.add_argument(
        "--oracle-root",
        type=Path,
        required=True,
    )
    prepare_parser.add_argument("--scenario", required=True)
    prepare_parser.add_argument(
        "--proposal-archive",
        type=Path,
        required=True,
    )
    prepare_parser.add_argument(
        "--proposal-attestation-bundle",
        type=Path,
        required=True,
    )
    prepare_parser.add_argument(
        "--evidence-archive",
        type=Path,
        required=True,
    )
    prepare_parser.add_argument(
        "--evidence-attestation-bundle",
        type=Path,
        required=True,
    )
    prepare_parser.add_argument("--repository", required=True)
    prepare_parser.add_argument("--gh", type=Path, required=True)
    prepare_parser.add_argument("--authorized-run-id", required=True)
    prepare_parser.add_argument(
        "--authorized-source-digest",
        required=True,
    )
    prepare_parser.add_argument(
        "--authorized-proposal-sha256",
        required=True,
    )
    prepare_parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
    )
    args = parser.parse_args(argv)
    try:
        report = prepare(
            args.root,
            oracle_root=args.oracle_root,
            scenario_id=args.scenario,
            proposal_archive=args.proposal_archive,
            proposal_attestation_bundle=(
                args.proposal_attestation_bundle
            ),
            evidence_archive=args.evidence_archive,
            evidence_attestation_bundle=(
                args.evidence_attestation_bundle
            ),
            repository=args.repository,
            gh=args.gh,
            authorized_run_id=args.authorized_run_id,
            authorized_source_digest=(
                args.authorized_source_digest
            ),
            authorized_proposal_sha256=(
                args.authorized_proposal_sha256
            ),
            output_dir=args.output_dir,
        )
    except GoldenPublisherError as error:
        print(
            json.dumps(
                {
                    "schema_version": 2,
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
