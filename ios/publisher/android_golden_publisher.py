#!/usr/bin/env python3
"""Stage a verified Android Oracle candidate for an external Golden publisher."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Tuple


COMMANDS = ("prepare",)
FIXTURE_ID = "sl-html-basic-001"
PROFILE = "android-legado-v1"
PUBLISHER_ID = "github-actions-environment:android-golden-publisher"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
RUN_ID = re.compile(r"[1-9][0-9]*/[1-9][0-9]*\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")


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
    if candidate.exists():
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
        from oracle import ci_proposal, trusted_import
        from oracle import exact_json
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


def prepare(
    root: Path,
    *,
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
    ci_proposal, trusted_import, exact_json = _oracle_modules(root)

    trusted_report = trusted_import.verify(
        root,
        proposal_archive=proposal_archive,
        proposal_attestation_bundle=proposal_attestation_bundle,
        evidence_archive=evidence_archive,
        evidence_attestation_bundle=evidence_attestation_bundle,
        repository=repository,
        gh=gh,
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
    ):
        raise GoldenPublisherError("TRUSTED_IMPORT_BINDING_DRIFT")

    proposal_members = ci_proposal.read_deterministic_tar(
        proposal_archive,
        ci_proposal.EXPECTED_PROPOSAL_MEMBERS,
    )
    evidence_members = ci_proposal.read_deterministic_tar(
        evidence_archive,
        ci_proposal.EXPECTED_EVIDENCE_MEMBERS,
    )
    proposal_bytes = proposal_members["proposal/proposal.json"]
    payload_name = f"proposal/payloads/{FIXTURE_ID}.json"
    evidence_payload_name = f"evidence/payloads/{FIXTURE_ID}.json"
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
        or fixtures[0].get("id") != FIXTURE_ID
        or fixtures[0].get("payload_sha256") != _sha256(payload_bytes)
        or trusted_report.get("proposal_sha256")
        != _sha256(proposal_bytes)
    ):
        raise GoldenPublisherError("PROPOSAL_AUTHORIZATION_DRIFT")
    fixture = _object(fixtures[0], "proposal.fixtures[0]")
    if (
        bindings.get("compatibility_profile") != PROFILE
        or fixture.get("fixture_path")
        != "ios/harness/fixtures/source-lab/sl-html-basic-001"
        or fixture.get("payload_path")
        != f"payloads/{FIXTURE_ID}.json"
    ):
        raise GoldenPublisherError("GOLDEN_FIXTURE_BINDING_DRIFT")

    manifest_path = root / "ios/harness/goldens/manifest.json"
    current_manifest = _object(
        exact_json.loads(_safe_regular(manifest_path).read_bytes()),
        "golden manifest",
    )
    current_fixtures = _object(
        current_manifest.get("fixtures"),
        "golden manifest fixtures",
    )
    if FIXTURE_ID in current_fixtures:
        raise GoldenPublisherError("GOLDEN_ALREADY_PUBLISHED")
    if current_fixtures:
        current_oracle = _object(
            current_manifest.get("oracle"),
            "golden manifest oracle",
        )
        if (
            current_oracle.get("android_git_commit")
            != bindings.get("android_git_commit")
            or current_oracle.get("profile") != PROFILE
            or current_oracle.get("runner_digest")
            != bindings.get("runner_digest")
            or current_manifest.get("canonicalizer_sha256")
            != bindings.get("canonicalizer_config_sha256")
        ):
            raise GoldenPublisherError(
                "EXISTING_GOLDEN_CONTROL_DRIFT"
            )

    proposal_archive_sha256 = _sha256(proposal_archive.read_bytes())
    evidence_archive_sha256 = _sha256(evidence_archive.read_bytes())
    proposal_attestation_sha256 = _sha256(
        proposal_attestation_bundle.read_bytes()
    )
    evidence_attestation_sha256 = _sha256(
        evidence_attestation_bundle.read_bytes()
    )
    golden_sha256 = _sha256(payload_bytes)
    golden_relative = (
        f"android-legado-v1/{FIXTURE_ID}.json"
    )
    release_relative = (
        "releases/"
        f"{FIXTURE_ID}-{authorized_run_id.replace('/', '-')}.json"
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
        "runner_image_digest": _string(
            bindings.get("runner_image_digest"),
            "runner_image_digest",
        ),
        "release_receipt": (
            f"ios/harness/goldens/{release_relative}"
        ),
    }
    next_fixtures = dict(current_fixtures)
    next_fixtures[FIXTURE_ID] = published_entry
    manifest = {
        "schema_version": 1,
        "oracle": {
            "android_git_commit": _string(
                bindings.get("android_git_commit"),
                "android_git_commit",
            ),
            "profile": PROFILE,
            "runner_digest": _string(
                bindings.get("runner_digest"),
                "runner_digest",
            ),
            "runner_image_digest": _string(
                bindings.get("runner_image_digest"),
                "runner_image_digest",
            ),
        },
        "canonicalizer_sha256": _string(
            bindings.get("canonicalizer_config_sha256"),
            "canonicalizer_config_sha256",
        ),
        "fixtures": {
            key: next_fixtures[key]
            for key in sorted(next_fixtures)
        },
    }
    receipt = {
        "schema_version": 1,
        "kind": "android_golden_release",
        "authority": "protected_android_golden",
        "publisher": PUBLISHER_ID,
        "repository": repository,
        "fixture_id": FIXTURE_ID,
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
        "authorization": "github_environment_review",
    }

    output = _external_empty_directory(root, output_dir)
    manifest_bytes = _canonical_bytes(exact_json, manifest)
    receipt_bytes = _canonical_bytes(exact_json, receipt)
    _private_write(output / "manifest.json", manifest_bytes)
    _private_write(output / golden_relative, payload_bytes)
    _private_write(output / release_relative, receipt_bytes)
    return {
        "schema_version": 1,
        "status": "staged_for_external_publisher",
        "authority": "protected_android_golden",
        "fixture_id": FIXTURE_ID,
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
