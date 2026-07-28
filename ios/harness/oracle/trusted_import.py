#!/usr/bin/env python3
"""Fail-closed importer for doubly attested Android Oracle proposals."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence


HARNESS_ROOT = Path(__file__).resolve().parents[1]
if str(HARNESS_ROOT) not in sys.path:
    sys.path.insert(0, str(HARNESS_ROOT))

from oracle.ci_proposal import (  # noqa: E402
    FIXTURE_ID,
    WORKFLOW_PATH,
    _request_for_scenario,
    _validate_scenario_id,
    _validate_evidence,
    expected_evidence_members,
    expected_proposal_members,
    read_deterministic_tar,
)
from oracle.exact_json import (  # noqa: E402
    NumberToken,
    dumps,
    file_digest,
    integer,
    loads,
)
from oracle.contract import ProposalError, verify_proposal  # noqa: E402


COMMANDS = ("verify",)
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SLSA_PROVENANCE = "https://slsa.dev/provenance/v1"


class TrustedImportError(RuntimeError):
    def __init__(self, reason_code: str, detail: str = ""):
        super().__init__(reason_code)
        self.reason_code = reason_code
        self.detail = detail


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _exact_node(value: Any) -> Any:
    if isinstance(value, bool) or value is None or isinstance(
        value,
        (str, NumberToken),
    ):
        return value
    if isinstance(value, int):
        return NumberToken(str(value))
    if isinstance(value, list):
        return [_exact_node(entry) for entry in value]
    if isinstance(value, dict):
        return {key: _exact_node(entry) for key, entry in value.items()}
    raise TrustedImportError("UNSUPPORTED_JSON_VALUE", type(value).__name__)


def _dump(value: Any) -> bytes:
    return dumps(_exact_node(value))


def _safe_regular(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise TrustedImportError("REGULAR_FILE_REQUIRED", path.name)
    return path


def _safe_executable(path: Path) -> Path:
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise TrustedImportError("GH_EXECUTABLE_INVALID") from error
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise TrustedImportError("GH_EXECUTABLE_INVALID")
    return resolved


def _git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise TrustedImportError("GIT_BINDING_FAILED")
    try:
        return result.stdout.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise TrustedImportError("GIT_BINDING_FAILED") from error


def _verify_attestation(
    *,
    gh: Path,
    subject: Path,
    bundle: Path,
    repository: str,
    signer_workflow: str,
    source_digest: str,
) -> list[Dict[str, Any]]:
    subject = _safe_regular(subject)
    bundle = _safe_regular(bundle)
    argv = [
        str(gh),
        "attestation",
        "verify",
        str(subject),
        "--repo",
        repository,
        "--bundle",
        str(bundle),
        "--signer-workflow",
        signer_workflow,
        "--source-digest",
        source_digest,
        "--deny-self-hosted-runners",
        "--predicate-type",
        SLSA_PROVENANCE,
        "--format",
        "json",
    ]
    try:
        result = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise TrustedImportError("ATTESTATION_COMMAND_FAILED") from error
    if result.returncode != 0:
        raise TrustedImportError(
            "ATTESTATION_VERIFICATION_FAILED",
            subject.name,
        )
    if len(result.stdout) > 16 * 1024 * 1024:
        raise TrustedImportError("ATTESTATION_OUTPUT_TOO_LARGE")
    try:
        report = json.loads(result.stdout)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TrustedImportError("ATTESTATION_OUTPUT_INVALID") from error
    if (
        not isinstance(report, list)
        or len(report) != 1
        or not isinstance(report[0], dict)
    ):
        raise TrustedImportError("ATTESTATION_RESULT_EMPTY")
    return report


def _validate_provenance_identity(
    report: list[Dict[str, Any]],
    *,
    repository: str,
    workflow_ref: str,
    run_id: str,
) -> None:
    try:
        verification = report[0]["verificationResult"]
        predicate = verification["statement"]["predicate"]
        build_definition = predicate["buildDefinition"]
        workflow = build_definition["externalParameters"]["workflow"]
        run_details = predicate["runDetails"]
        invocation_id = run_details["metadata"]["invocationId"]
        builder_id = run_details["builder"]["id"]
    except (KeyError, TypeError, IndexError) as error:
        raise TrustedImportError(
            "ATTESTATION_PROVENANCE_SHAPE_INVALID"
        ) from error
    expected_invocation = (
        f"https://github.com/{repository}/actions/runs/"
        f"{run_id.replace('/', '/attempts/', 1)}"
    )
    expected_ref = workflow_ref.split("@", 1)[1]
    expected_builder = f"https://github.com/{workflow_ref}"
    if (
        workflow.get("repository") != f"https://github.com/{repository}"
        or workflow.get("path") != WORKFLOW_PATH
        or workflow.get("ref") != expected_ref
        or invocation_id != expected_invocation
        or builder_id != expected_builder
    ):
        raise TrustedImportError("ATTESTATION_PROVENANCE_IDENTITY_DRIFT")


def _object(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise TrustedImportError("OBJECT_REQUIRED", label)
    return value


def _write_temp(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_bytes(payload)
    os.chmod(path, 0o600)


def verify(
    root: Path,
    *,
    proposal_archive: Path,
    proposal_attestation_bundle: Path,
    evidence_archive: Path,
    evidence_attestation_bundle: Path,
    repository: str,
    gh: Path,
    scenario_id: str = FIXTURE_ID,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    try:
        scenario_id = _validate_scenario_id(scenario_id)
    except Exception as error:
        raise TrustedImportError("SCENARIO_SELECTOR_INVALID") from error
    request_work_item = _request_for_scenario(scenario_id)
    if REPOSITORY.fullmatch(repository) is None:
        raise TrustedImportError("REPOSITORY_INVALID")
    gh = _safe_executable(gh)
    source_digest = _git(root, "rev-parse", "HEAD")
    if HEX40.fullmatch(source_digest) is None:
        raise TrustedImportError("SOURCE_DIGEST_INVALID")
    signer_workflow = f"{repository}/{WORKFLOW_PATH}"
    proposal_attestation_report = _verify_attestation(
        gh=gh,
        subject=proposal_archive,
        bundle=proposal_attestation_bundle,
        repository=repository,
        signer_workflow=signer_workflow,
        source_digest=source_digest,
    )
    evidence_attestation_report = _verify_attestation(
        gh=gh,
        subject=evidence_archive,
        bundle=evidence_attestation_bundle,
        repository=repository,
        signer_workflow=signer_workflow,
        source_digest=source_digest,
    )
    proposal_members = read_deterministic_tar(
        proposal_archive,
        expected_proposal_members(scenario_id),
    )
    evidence_members = read_deterministic_tar(
        evidence_archive,
        expected_evidence_members(scenario_id),
    )
    request = loads(
        _safe_regular(
            root / f"ios/harness/work-items/{request_work_item}.json"
        ).read_bytes()
    )
    evidence_run, evidence_payload_value, evidence_payload = _validate_evidence(
        root,
        evidence_members,
        request,
        scenario_id,
    )
    try:
        proposal_bytes = proposal_members["proposal/proposal.json"]
        proposal_payload = proposal_members[
            f"proposal/payloads/{scenario_id}.json"
        ]
        proposal = _object(loads(proposal_bytes), "proposal")
    except (KeyError, UnicodeDecodeError, ValueError) as error:
        raise TrustedImportError("PROPOSAL_JSON_INVALID") from error
    if dumps(proposal) != proposal_bytes:
        raise TrustedImportError("PROPOSAL_JSON_NOT_CANONICAL")
    if proposal_payload != evidence_payload:
        raise TrustedImportError("EVIDENCE_PROPOSAL_PAYLOAD_DRIFT")
    expected_proposal_request = {
        "work_item_id": request_work_item,
        "fixture_ids": [scenario_id],
    }
    if scenario_id != FIXTURE_ID:
        expected_proposal_request["scenario_id"] = scenario_id
    if proposal.get("request") != expected_proposal_request:
        raise TrustedImportError("PROPOSAL_SCENARIO_BINDING_DRIFT")
    producer = _object(proposal.get("producer"), "proposal.producer")
    evidence_producer = _object(
        evidence_run.get("producer"),
        "evidence.producer",
    )
    if (
        producer.get("system") != "github-actions"
        or evidence_producer.get("system") != "github-actions"
        or evidence_producer.get("repository") != repository
        or evidence_producer.get("source_digest") != source_digest
        or producer.get("workflow_ref") != evidence_producer.get("workflow_ref")
        or producer.get("run_id") != evidence_producer.get("run_id")
    ):
        raise TrustedImportError("PRODUCER_BINDING_DRIFT")
    expected_workflow_prefix = f"{repository}/{WORKFLOW_PATH}@refs/"
    if not str(producer.get("workflow_ref", "")).startswith(
        expected_workflow_prefix
    ):
        raise TrustedImportError("WORKFLOW_BINDING_DRIFT")
    _validate_provenance_identity(
        proposal_attestation_report,
        repository=repository,
        workflow_ref=producer["workflow_ref"],
        run_id=producer["run_id"],
    )
    _validate_provenance_identity(
        evidence_attestation_report,
        repository=repository,
        workflow_ref=producer["workflow_ref"],
        run_id=producer["run_id"],
    )
    evidence_bundle_sha256 = file_digest(
        _safe_regular(evidence_attestation_bundle)
    )
    if (
        producer.get("attestation_sha256") != evidence_bundle_sha256
        or not str(producer.get("attestation_uri", "")).startswith(
            f"https://github.com/{repository}/attestations/"
        )
    ):
        raise TrustedImportError("EVIDENCE_ATTESTATION_BINDING_DRIFT")
    fixture = proposal.get("fixtures")
    if (
        not isinstance(fixture, list)
        or len(fixture) != 1
        or fixture[0].get("id") != scenario_id
        or fixture[0].get("payload_sha256") != _sha256(proposal_payload)
        or integer(fixture[0].get("payload_bytes"), "payload_bytes")
        != len(proposal_payload)
    ):
        raise TrustedImportError("PROPOSAL_PAYLOAD_BINDING_DRIFT")
    with tempfile.TemporaryDirectory(
        prefix="legado-oracle-import-"
    ) as temporary:
        temporary_root = Path(temporary)
        proposal_path = temporary_root / "proposal/proposal.json"
        payload_path = (
            temporary_root
            / f"proposal/payloads/{scenario_id}.json"
        )
        _write_temp(proposal_path, proposal_bytes)
        _write_temp(payload_path, proposal_payload)
        try:
            contract_report = verify_proposal(
                root,
                proposal_path,
                request_work_item,
            )
        except (OSError, ValueError, ProposalError) as error:
            raise TrustedImportError(
                "PROPOSAL_CONTRACT_INVALID",
                str(error),
            ) from error
    bindings = _object(proposal.get("bindings"), "proposal.bindings")
    evidence_bindings = _object(evidence_run.get("bindings"), "evidence.bindings")
    shared_binding_fields = [
        "android_baseline_sha256",
        "runner_digest",
        "runner_image_digest",
    ]
    if scenario_id != FIXTURE_ID:
        shared_binding_fields.append("source_lab_manifest_sha256")
    for field in shared_binding_fields:
        if bindings.get(field) != evidence_bindings.get(field):
            raise TrustedImportError("PROPOSAL_DIGEST_BINDING_DRIFT", field)
    scenario_fields = (
        "scenario_id",
        "scenario_sha256",
        "source_lab_manifest_sha256",
        "input_sha256",
    )
    if scenario_id != FIXTURE_ID:
        for field in scenario_fields:
            if evidence_payload_value.get(field) is None:
                raise TrustedImportError("PROPOSAL_DIGEST_BINDING_MISSING", field)
    report = {
        "schema_version": 1,
        "authority": "candidate_only",
        "status": "verified_for_human_review",
        "repository": repository,
        "source_digest": source_digest,
        "signer_workflow": signer_workflow,
        "proposal_archive_sha256": file_digest(proposal_archive),
        "evidence_archive_sha256": file_digest(evidence_archive),
        "proposal_attestation_count": len(
            proposal_attestation_report
        ),
        "evidence_attestation_count": len(
            evidence_attestation_report
        ),
        "proposal_sha256": contract_report["proposal_sha256"],
        "fixture_ids": contract_report["fixture_ids"],
        "scenario_id": scenario_id,
        "runner_digest": bindings["runner_digest"],
        "payload_sha256": _sha256(proposal_payload),
        "next_authority": "independent_golden_publisher",
    }
    if scenario_id != FIXTURE_ID:
        report.update(
            {
                "scenario_sha256": evidence_payload_value["scenario_sha256"],
                "source_lab_manifest_sha256": evidence_payload_value[
                    "source_lab_manifest_sha256"
                ],
            }
        )
    return report


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="android-oracle-trusted-import")
    commands = parser.add_subparsers(dest="command", required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--root", type=Path, required=True)
    verify_parser.add_argument(
        "--proposal-archive",
        type=Path,
        required=True,
    )
    verify_parser.add_argument(
        "--proposal-attestation-bundle",
        type=Path,
        required=True,
    )
    verify_parser.add_argument(
        "--evidence-archive",
        type=Path,
        required=True,
    )
    verify_parser.add_argument(
        "--evidence-attestation-bundle",
        type=Path,
        required=True,
    )
    verify_parser.add_argument("--repository", required=True)
    verify_parser.add_argument("--gh", type=Path, required=True)
    verify_parser.add_argument("--scenario", default=FIXTURE_ID)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    report = verify(
        args.root,
        proposal_archive=args.proposal_archive,
        proposal_attestation_bundle=args.proposal_attestation_bundle,
        evidence_archive=args.evidence_archive,
        evidence_attestation_bundle=args.evidence_attestation_bundle,
        repository=args.repository,
        gh=args.gh,
        scenario_id=args.scenario,
    )
    sys.stdout.buffer.write(_dump(report) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (TrustedImportError, OSError, ValueError) as error:
        if isinstance(error, TrustedImportError):
            reason_code = error.reason_code
            detail = error.detail
        else:
            reason_code = "TRUSTED_IMPORT_FAILED"
            detail = type(error).__name__
        sys.stdout.buffer.write(
            _dump(
                {
                    "schema_version": 1,
                    "ok": False,
                    "reason_code": reason_code,
                    "detail": detail,
                }
            )
            + b"\n"
        )
        raise SystemExit(2)
