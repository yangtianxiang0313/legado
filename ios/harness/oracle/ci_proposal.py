#!/usr/bin/env python3
"""Deterministic two-stage packaging for attested Android Oracle proposals."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import stat
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Mapping, Optional, Sequence


HARNESS_ROOT = Path(__file__).resolve().parents[1]
if str(HARNESS_ROOT) not in sys.path:
    sys.path.insert(0, str(HARNESS_ROOT))

from oracle.canonicalizer import canonicalize_bytes, load_config  # noqa: E402
from oracle.contract import (  # noqa: E402
    canonical_file_digest,
    fixture_digest,
    implementation_digest,
)
from oracle.exact_json import (  # noqa: E402
    NumberToken,
    dumps,
    file_digest,
    integer,
    loads,
)


COMMANDS = ("environment", "prepare", "finalize")
WORK_ITEM_ID = "IOS-ANDROID-ORACLE-ATTESTATION-001"
POST_FORM_WORK_ITEM_ID = "IOS-ANDROID-POST-FORM-ATTESTATION-001"
FIXTURE_ID = "sl-html-basic-001"
SOURCE_LAB_MANIFEST_PATH = "ios/harness/source-lab/manifest.json"
SUPPORTED_SCENARIOS = {
    "sl-html-basic-001": {
        "status": "reference",
        "request_work_item": WORK_ITEM_ID,
    },
    "sl-post-form-001": {
        "status": "candidate",
        "request_work_item": POST_FORM_WORK_ITEM_ID,
    },
}
EVIDENCE_ARCHIVE_NAME = "android-oracle-evidence.tar"
PROPOSAL_ARCHIVE_NAME = "android-oracle-proposal.tar"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
RUN_ID = re.compile(r"[1-9][0-9]*(?:/[1-9][0-9]*)?\Z")
WORKFLOW_PATH = ".github/workflows/android-oracle-attestation.yml"
def expected_evidence_members(scenario_id: str) -> tuple[str, ...]:
    return (
        f"evidence/payloads/{scenario_id}.json",
        "evidence/run.json",
        "evidence/runner-environment.json",
    )


def expected_proposal_members(scenario_id: str) -> tuple[str, ...]:
    return (
        f"proposal/payloads/{scenario_id}.json",
        "proposal/proposal.json",
    )


EXPECTED_EVIDENCE_MEMBERS = expected_evidence_members(FIXTURE_ID)
EXPECTED_PROPOSAL_MEMBERS = expected_proposal_members(FIXTURE_ID)


class CIProposalError(RuntimeError):
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
    raise CIProposalError("UNSUPPORTED_JSON_VALUE", type(value).__name__)


def _dump(value: Any) -> bytes:
    return dumps(_exact_node(value))


def _safe_regular(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise CIProposalError("REGULAR_FILE_REQUIRED", path.as_posix())
    return path


def _read_bytes(path: Path, limit: int = 16 * 1024 * 1024) -> bytes:
    payload = _safe_regular(path).read_bytes()
    if len(payload) > limit:
        raise CIProposalError("FILE_TOO_LARGE", path.name)
    return payload


def _read_json(path: Path) -> Any:
    try:
        return loads(_read_bytes(path))
    except (OSError, UnicodeDecodeError, ValueError) as error:
        raise CIProposalError("JSON_INVALID", path.name) from error


def _canonical_json(
    path: Path,
    *,
    allow_trailing_newline: bool = False,
) -> tuple[Any, bytes]:
    raw = _read_bytes(path)
    value = _read_json(path)
    payload = dumps(value)
    accepted = {payload}
    if allow_trailing_newline:
        accepted.add(payload + b"\n")
    if raw not in accepted:
        raise CIProposalError("JSON_NOT_CANONICAL", path.name)
    return value, raw


def _object(value: Any, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise CIProposalError("OBJECT_REQUIRED", label)
    return value


def _string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise CIProposalError("STRING_REQUIRED", label)
    return value


def _exact_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise CIProposalError("OBJECT_KEYS_INVALID", label)


def _validate_repository(value: str) -> str:
    if REPOSITORY.fullmatch(value) is None:
        raise CIProposalError("REPOSITORY_INVALID")
    return value


def _validate_source_digest(value: str) -> str:
    if HEX40.fullmatch(value) is None:
        raise CIProposalError("SOURCE_DIGEST_INVALID")
    return value


def _validate_scenario_id(value: str) -> str:
    if (
        value not in SUPPORTED_SCENARIOS
        or "/" in value
        or "\\" in value
        or value in {".", ".."}
    ):
        raise CIProposalError("SCENARIO_SELECTOR_INVALID", value)
    return value


def _request_for_scenario(scenario_id: str) -> str:
    return str(SUPPORTED_SCENARIOS[_validate_scenario_id(scenario_id)]["request_work_item"])


def _validate_run_id(value: str) -> str:
    if RUN_ID.fullmatch(value) is None:
        raise CIProposalError("RUN_ID_INVALID")
    return value


def _validate_workflow_ref(value: str, repository: str) -> str:
    prefix = f"{repository}/{WORKFLOW_PATH}@refs/"
    if not value.startswith(prefix) or any(character.isspace() for character in value):
        raise CIProposalError("WORKFLOW_REF_INVALID")
    return value


def _private_directory(path: Path, *, empty: bool) -> Path:
    path = path.absolute()
    if path.exists():
        if path.is_symlink() or not path.is_dir():
            raise CIProposalError("OUTPUT_DIRECTORY_INVALID", path.as_posix())
        if empty and any(path.iterdir()):
            raise CIProposalError("OUTPUT_DIRECTORY_NOT_EMPTY", path.as_posix())
    else:
        path.mkdir(parents=True, mode=0o700)
    os.chmod(path, 0o700)
    return path


def _external_output(root: Path, path: Path) -> Path:
    root = root.resolve(strict=True)
    candidate = path.absolute()
    try:
        candidate.relative_to(root)
    except ValueError:
        return candidate
    raise CIProposalError("OUTPUT_INSIDE_REPOSITORY", candidate.as_posix())


def _private_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise CIProposalError("OUTPUT_DIRECTORY_INVALID", path.parent.as_posix())
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise CIProposalError("OUTPUT_PATH_INVALID", path.as_posix())
    descriptor, raw_temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(raw_temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _deterministic_tar_bytes(members: Mapping[str, bytes]) -> bytes:
    expected_names = sorted(members)
    if not expected_names:
        raise CIProposalError("ARCHIVE_EMPTY")
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name in expected_names:
            pure = PurePosixPath(name)
            if (
                pure.is_absolute()
                or ".." in pure.parts
                or "." in pure.parts
                or pure.as_posix() != name
            ):
                raise CIProposalError("ARCHIVE_MEMBER_INVALID", name)
            payload = members[name]
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mtime = 0
            info.type = tarfile.REGTYPE
            archive.addfile(info, io.BytesIO(payload))
    return buffer.getvalue()


def deterministic_tar(path: Path, members: Mapping[str, bytes]) -> str:
    archive_bytes = _deterministic_tar_bytes(members)
    _private_write(path, archive_bytes)
    return _sha256(archive_bytes)


def read_deterministic_tar(
    path: Path,
    expected_members: Sequence[str],
) -> Dict[str, bytes]:
    archive_bytes = _read_bytes(path, limit=64 * 1024 * 1024)
    result: Dict[str, bytes] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode="r:") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            if names != sorted(expected_members) or len(names) != len(set(names)):
                raise CIProposalError("ARCHIVE_MANIFEST_INVALID", path.name)
            for member in members:
                pure = PurePosixPath(member.name)
                if (
                    not member.isreg()
                    or member.issym()
                    or member.islnk()
                    or pure.is_absolute()
                    or ".." in pure.parts
                    or member.mode != 0o644
                    or member.uid != 0
                    or member.gid != 0
                    or member.mtime != 0
                ):
                    raise CIProposalError("ARCHIVE_MEMBER_INVALID", member.name)
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise CIProposalError("ARCHIVE_MEMBER_UNREADABLE", member.name)
                payload = extracted.read()
                if len(payload) != member.size:
                    raise CIProposalError("ARCHIVE_MEMBER_SIZE_DRIFT", member.name)
                result[member.name] = payload
    except (tarfile.TarError, OSError) as error:
        raise CIProposalError("ARCHIVE_INVALID", path.name) from error
    if set(result) != set(expected_members):
        raise CIProposalError("ARCHIVE_MANIFEST_INVALID", path.name)
    if _deterministic_tar_bytes(result) != archive_bytes:
        raise CIProposalError("ARCHIVE_NOT_DETERMINISTIC", path.name)
    return result


def runner_environment_document(
    root: Path,
    *,
    image_os: str,
    image_version: str,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    workflow = root / WORKFLOW_PATH
    wrapper = root / "gradle/wrapper/gradle-wrapper.properties"
    runner_files = (
        root / "ios/harness/oracle/android-runner/LegadoOracleInstrumentedTest.kt",
        root / "ios/harness/oracle/android-runner/orchestrator.py",
    )
    return {
        "schema_version": 1,
        "kind": "android_oracle_runner_environment",
        "github_hosted": True,
        "runner_label": "ubuntu-24.04",
        "image_os": _string(image_os, "image_os"),
        "image_version": _string(image_version, "image_version"),
        "java": {
            "distribution": "temurin",
            "major_version": 17,
        },
        "android": {
            "api_level": 35,
            "system_image": "system-images;android-35;google_apis;x86_64",
            "avd_name": "legado-oracle-api35",
        },
        "workflow_sha256": file_digest(_safe_regular(workflow)),
        "gradle_wrapper_properties_sha256": file_digest(_safe_regular(wrapper)),
        "runner_files": [
            {
                "path": path.relative_to(root).as_posix(),
                "sha256": file_digest(_safe_regular(path)),
            }
            for path in runner_files
        ],
    }


def write_environment(
    root: Path,
    output: Path,
    *,
    image_os: str,
    image_version: str,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    output = _external_output(root, output)
    document = runner_environment_document(
        root,
        image_os=image_os,
        image_version=image_version,
    )
    payload = _dump(document)
    _private_write(output, payload)
    return {
        "schema_version": 1,
        "runner_image_digest": f"sha256:{_sha256(payload)}",
        "output": output.as_posix(),
    }


def _validate_environment(
    value: Any,
    payload: bytes,
    *,
    root: Optional[Path] = None,
) -> str:
    value = _object(value, "runner_environment")
    _exact_keys(
        value,
        {
            "schema_version",
            "kind",
            "github_hosted",
            "runner_label",
            "image_os",
            "image_version",
            "java",
            "android",
            "workflow_sha256",
            "gradle_wrapper_properties_sha256",
            "runner_files",
        },
        "runner_environment",
    )
    if (
        integer(value["schema_version"], "runner_environment.schema_version")
        != 1
        or value["kind"] != "android_oracle_runner_environment"
        or value["github_hosted"] is not True
        or value["runner_label"] != "ubuntu-24.04"
    ):
        raise CIProposalError("RUNNER_ENVIRONMENT_INVALID")
    for field in (
        "image_os",
        "image_version",
        "workflow_sha256",
        "gradle_wrapper_properties_sha256",
    ):
        _string(value[field], f"runner_environment.{field}")
    for field in ("workflow_sha256", "gradle_wrapper_properties_sha256"):
        if HEX64.fullmatch(value[field]) is None:
            raise CIProposalError("RUNNER_ENVIRONMENT_DIGEST_INVALID", field)
    java = _object(value["java"], "runner_environment.java")
    android = _object(value["android"], "runner_environment.android")
    _exact_keys(java, {"distribution", "major_version"}, "runner_environment.java")
    _exact_keys(
        android,
        {"api_level", "system_image", "avd_name"},
        "runner_environment.android",
    )
    if (
        java.get("distribution") != "temurin"
        or integer(java.get("major_version"), "java.major_version") != 17
    ):
        raise CIProposalError("RUNNER_ENVIRONMENT_JAVA_INVALID")
    if (
        integer(android.get("api_level"), "android.api_level") != 35
        or android.get("system_image")
        != "system-images;android-35;google_apis;x86_64"
        or android.get("avd_name") != "legado-oracle-api35"
    ):
        raise CIProposalError("RUNNER_ENVIRONMENT_ANDROID_INVALID")
    runner_files = value["runner_files"]
    if not isinstance(runner_files, list) or len(runner_files) != 2:
        raise CIProposalError("RUNNER_ENVIRONMENT_FILES_INVALID")
    if root is not None:
        expected = runner_environment_document(
            root,
            image_os=value["image_os"],
            image_version=value["image_version"],
        )
        if _dump(expected) != payload:
            raise CIProposalError("RUNNER_ENVIRONMENT_CONTROL_DRIFT")
    return f"sha256:{_sha256(payload)}"


def _control_bindings(root: Path, request: Any) -> Dict[str, Any]:
    baseline = _object(_read_json(root / "ios/project/baseline.json"), "baseline")
    inventory = _object(
        _read_json(root / "ios/project/android-intake/inventory-manifest.json"),
        "inventory",
    )
    android = _object(baseline.get("android_oracle"), "baseline.android_oracle")
    commit = _string(android.get("git_commit"), "android_git_commit")
    tree = _string(inventory.get("android_tree"), "android_git_tree")
    if inventory.get("android_git_commit") != commit:
        raise CIProposalError("ANDROID_BASELINE_DRIFT")
    return {
        "compatibility_profile": "android-legado-v1",
        "android_git_commit": commit,
        "android_git_tree": tree,
        "checkout_clean": True,
        "request_work_item_sha256": _sha256(dumps(request)),
        "android_baseline_sha256": canonical_file_digest(
            root / "ios/project/baseline.json"
        ),
        "fixture_manifest_sha256": canonical_file_digest(
            root / "ios/harness/fixtures/manifest.json"
        ),
        "source_lab_manifest_sha256": canonical_file_digest(
            root / SOURCE_LAB_MANIFEST_PATH
        ),
        "android_fact_inventory_sha256": canonical_file_digest(
            root / "ios/project/android-intake/inventory-manifest.json"
        ),
        "requirement_catalog_sha256": canonical_file_digest(
            root / "ios/project/requirements/catalog.json"
        ),
        "execution_envelope_schema_sha256": canonical_file_digest(
            root / "ios/harness/schemas/execution-envelope.schema.json"
        ),
        "canonicalizer_id": "canonical-v1",
        "canonicalizer_config_sha256": canonical_file_digest(
            root / "ios/harness/normalization/canonical-v1.json"
        ),
        "canonicalizer_implementation_sha256": implementation_digest(
            "canonicalizer.py",
            "exact_json.py",
        ),
        "comparator_id": "shared-exact-v1",
        "comparator_implementation_sha256": implementation_digest(
            "__init__.py",
            "canonicalizer.py",
            "comparator.py",
            "exact_json.py",
        ),
    }


def _repository_runner_digest(root: Path) -> str:
    runner_root = root / "ios/harness/oracle/android-runner"
    entries = [
        {"path": path.name, "sha256": file_digest(_safe_regular(path))}
        for path in sorted(
            (
                runner_root / "LegadoOracleInstrumentedTest.kt",
                runner_root / "orchestrator.py",
            ),
            key=lambda value: value.name,
        )
    ]
    return _sha256(_dump(entries))


def _fixture_entry(
    root: Path,
    scenario_id: str,
) -> tuple[Dict[str, Any], Dict[str, Any], Dict[str, Any]]:
    scenario_id = _validate_scenario_id(scenario_id)
    manifest = _object(
        _read_json(root / "ios/harness/fixtures/manifest.json"),
        "fixture_manifest",
    )
    matches = [
        entry
        for entry in manifest.get("fixtures", [])
        if isinstance(entry, dict) and entry.get("id") == scenario_id
    ]
    if len(matches) != 1:
        raise CIProposalError("FIXTURE_MANIFEST_BINDING_MISSING")
    entry = matches[0]
    fixture_path = _string(entry.get("path"), "fixture.path")
    expected_path = f"ios/harness/fixtures/source-lab/{scenario_id}"
    if fixture_path != expected_path:
        raise CIProposalError("FIXTURE_PATH_DRIFT")
    if fixture_digest(root / fixture_path) != entry.get("sha256"):
        raise CIProposalError("FIXTURE_DIGEST_DRIFT")
    case = _object(_read_json(root / fixture_path / "case.json"), "fixture_case")
    if case.get("id") != scenario_id:
        raise CIProposalError("FIXTURE_CASE_DRIFT")
    source_lab = _object(
        _read_json(root / SOURCE_LAB_MANIFEST_PATH),
        "source_lab_manifest",
    )
    scenario_matches = [
        value for value in source_lab.get("scenarios", [])
        if isinstance(value, dict) and value.get("id") == scenario_id
    ]
    if len(scenario_matches) != 1:
        raise CIProposalError("SOURCE_LAB_SCENARIO_MISSING")
    scenario = scenario_matches[0]
    contract = SUPPORTED_SCENARIOS[scenario_id]
    if (
        scenario.get("path") != expected_path
        or scenario.get("status") != contract["status"]
    ):
        raise CIProposalError("SOURCE_LAB_SCENARIO_DRIFT")
    return entry, case, scenario


def _payload(
    *,
    scenario_id: str,
    fixture: Mapping[str, Any],
    scenario: Mapping[str, Any],
    source_lab_manifest_sha256: str,
    input_sha256: str,
    operation: str,
    artifact: Any,
    android_git_commit: str,
    runner_digest: str,
    runner_image_digest: str,
) -> Dict[str, Any]:
    return {
        "schema_version": 1,
        "kind": "android_oracle_payload",
        "fixture_id": scenario_id,
        "fixture_sha256": fixture["sha256"],
        "scenario_id": scenario_id,
        "scenario_sha256": scenario["sha256"],
        "source_lab_manifest_sha256": source_lab_manifest_sha256,
        "input_sha256": input_sha256,
        "operation": operation,
        "compatibility_profile": "android-legado-v1",
        "oracle": {
            "android_git_commit": android_git_commit,
            "runner_digest": runner_digest,
            "runner_image_digest": runner_image_digest,
        },
        "artifact": artifact,
    }


def prepare(
    root: Path,
    *,
    local_run: Path,
    runner_environment: Path,
    output_dir: Path,
    repository: str,
    workflow_ref: str,
    run_id: str,
    source_digest: str,
    scenario_id: str = FIXTURE_ID,
    request_work_item: Optional[str] = None,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    scenario_id = _validate_scenario_id(scenario_id)
    expected_request = _request_for_scenario(scenario_id)
    request_work_item = request_work_item or expected_request
    repository = _validate_repository(repository)
    workflow_ref = _validate_workflow_ref(workflow_ref, repository)
    run_id = _validate_run_id(run_id)
    source_digest = _validate_source_digest(source_digest)
    if request_work_item != expected_request:
        raise CIProposalError("REQUEST_WORK_ITEM_INVALID")
    request = _read_json(root / f"ios/harness/work-items/{request_work_item}.json")
    request = _object(request, "request_work_item")
    if (
        request.get("metadata", {}).get("id") != request_work_item
        or request.get("spec", {}).get("inputs", {}).get("fixtures") != [scenario_id]
        or not (
            "oracle-golden-request" in request.get("metadata", {}).get("labels", [])
            or "trusted-proposal" in request.get("metadata", {}).get("labels", [])
        )
    ):
        raise CIProposalError("REQUEST_WORK_ITEM_UNAUTHORIZED")
    local_value, local_bytes = _canonical_json(
        local_run,
        allow_trailing_newline=True,
    )
    local_value = _object(local_value, "local_run")
    _exact_keys(
        local_value,
        {
            "schema_version",
            "kind",
            "authority",
            "status",
            "scenario_id",
            "emulator",
            "bindings",
            "artifact_sha256",
            "artifact",
        },
        "local_run",
    )
    if (
        integer(local_value["schema_version"], "local_run.schema_version")
        != 1
        or local_value["kind"] != "android_oracle_local_run"
        or local_value["authority"] != "local_unverified"
        or local_value["status"] != "candidate_only"
        or local_value["scenario_id"] != scenario_id
    ):
        raise CIProposalError("LOCAL_RUN_IDENTITY_INVALID")
    artifact = _object(local_value["artifact"], "local_run.artifact")
    artifact_bytes = dumps(artifact)
    if _sha256(artifact_bytes) != local_value["artifact_sha256"]:
        raise CIProposalError("LOCAL_RUN_ARTIFACT_DIGEST_DRIFT")
    environment_value, environment_bytes = _canonical_json(runner_environment)
    runner_image_digest = _validate_environment(
        environment_value,
        environment_bytes,
        root=root,
    )
    bindings = _object(local_value["bindings"], "local_run.bindings")
    controls = _control_bindings(root, request)
    for field in ("android_git_commit", "android_git_tree"):
        if bindings.get(field) != controls[field]:
            raise CIProposalError("LOCAL_RUN_CONTROL_DRIFT", field)
    runner_digest = _string(bindings.get("runner_digest"), "runner_digest")
    if (
        HEX64.fullmatch(runner_digest) is None
        or runner_digest != _repository_runner_digest(root)
    ):
        raise CIProposalError("RUNNER_DIGEST_INVALID")
    if artifact.get("engine", {}).get("revision") != controls["android_git_commit"]:
        raise CIProposalError("ARTIFACT_REVISION_DRIFT")
    fixture, case, scenario = _fixture_entry(root, scenario_id)
    expected_scenario_bindings = {
        "fixture_sha256": fixture["sha256"],
        "scenario_sha256": scenario["sha256"],
        "source_lab_manifest_sha256": controls["source_lab_manifest_sha256"],
        "input_sha256": file_digest(
            root / fixture["path"] / "input.json"
        ),
    }
    for field, expected in expected_scenario_bindings.items():
        if bindings.get(field) != expected:
            raise CIProposalError("LOCAL_RUN_SCENARIO_DRIFT", field)
    payload_value = _payload(
        scenario_id=scenario_id,
        fixture=fixture,
        scenario=scenario,
        source_lab_manifest_sha256=controls["source_lab_manifest_sha256"],
        input_sha256=expected_scenario_bindings["input_sha256"],
        operation=_string(case.get("operation"), "fixture.operation"),
        artifact=artifact,
        android_git_commit=controls["android_git_commit"],
        runner_digest=runner_digest,
        runner_image_digest=runner_image_digest,
    )
    config = load_config(root / "ios/harness/normalization/canonical-v1.json")
    payload_bytes = canonicalize_bytes(_dump(payload_value), config)
    if payload_bytes != _dump(payload_value):
        raise CIProposalError("PAYLOAD_CANONICALIZATION_DRIFT")
    run_value = {
        "schema_version": 1,
        "kind": "android_oracle_execution_evidence",
        "authority": "candidate_only",
        "status": "produced",
        "request": {
            "work_item_id": request_work_item,
            "fixture_ids": [scenario_id],
            "scenario_id": scenario_id,
        },
        "producer": {
            "system": "github-actions",
            "repository": repository,
            "workflow_ref": workflow_ref,
            "run_id": run_id,
            "source_digest": source_digest,
        },
        "bindings": {
            **controls,
            "runner_digest": runner_digest,
            "runner_image_digest": runner_image_digest,
            "local_run_sha256": _sha256(local_bytes),
            "artifact_sha256": _sha256(artifact_bytes),
        },
        "payloads": [
            {
                "id": scenario_id,
                "path": f"evidence/payloads/{scenario_id}.json",
                "sha256": _sha256(payload_bytes),
                "bytes": len(payload_bytes),
            }
        ],
    }
    run_bytes = _dump(run_value)
    output_dir = _private_directory(
        _external_output(root, output_dir),
        empty=True,
    )
    members = {
        f"evidence/payloads/{scenario_id}.json": payload_bytes,
        "evidence/run.json": run_bytes,
        "evidence/runner-environment.json": environment_bytes,
    }
    for name, payload in members.items():
        _private_write(output_dir / name, payload)
    archive_path = output_dir / EVIDENCE_ARCHIVE_NAME
    archive_sha256 = deterministic_tar(archive_path, members)
    return {
        "schema_version": 1,
        "authority": "candidate_only",
        "status": "evidence_prepared",
        "archive": archive_path.as_posix(),
        "archive_sha256": archive_sha256,
        "payload_sha256": _sha256(payload_bytes),
        "scenario_id": scenario_id,
        "runner_image_digest": runner_image_digest,
    }


def _validate_evidence(
    root: Path,
    members: Mapping[str, bytes],
    request: Any,
    scenario_id: str,
) -> tuple[Dict[str, Any], Dict[str, Any], bytes]:
    scenario_id = _validate_scenario_id(scenario_id)
    try:
        run = _object(loads(members["evidence/run.json"]), "evidence.run")
        payload_bytes = members[f"evidence/payloads/{scenario_id}.json"]
        payload = _object(loads(payload_bytes), "evidence.payload")
        environment_bytes = members["evidence/runner-environment.json"]
        environment = loads(environment_bytes)
    except (KeyError, UnicodeDecodeError, ValueError) as error:
        raise CIProposalError("EVIDENCE_JSON_INVALID") from error
    for label, raw, value in (
        ("run", members["evidence/run.json"], run),
        ("payload", payload_bytes, payload),
        ("environment", environment_bytes, environment),
    ):
        if dumps(value) != raw:
            raise CIProposalError("EVIDENCE_JSON_NOT_CANONICAL", label)
    _exact_keys(
        run,
        {
            "schema_version",
            "kind",
            "authority",
            "status",
            "request",
            "producer",
            "bindings",
            "payloads",
        },
        "evidence.run",
    )
    if (
        integer(run["schema_version"], "evidence.schema_version") != 1
        or run["kind"] != "android_oracle_execution_evidence"
        or run["authority"] != "candidate_only"
        or run["status"] != "produced"
        or run["request"]
        != {
            "work_item_id": _request_for_scenario(scenario_id),
            "fixture_ids": [scenario_id],
            "scenario_id": scenario_id,
        }
    ):
        raise CIProposalError("EVIDENCE_IDENTITY_INVALID")
    producer = _object(run["producer"], "evidence.producer")
    repository = _validate_repository(_string(producer.get("repository"), "repository"))
    _validate_workflow_ref(
        _string(producer.get("workflow_ref"), "workflow_ref"),
        repository,
    )
    _validate_run_id(_string(producer.get("run_id"), "run_id"))
    _validate_source_digest(_string(producer.get("source_digest"), "source_digest"))
    if producer.get("system") != "github-actions":
        raise CIProposalError("EVIDENCE_PRODUCER_INVALID")
    bindings = _object(run["bindings"], "evidence.bindings")
    expected_controls = _control_bindings(root, request)
    for field, expected in expected_controls.items():
        if bindings.get(field) != expected:
            raise CIProposalError("EVIDENCE_CONTROL_DRIFT", field)
    runner_image_digest = _validate_environment(
        environment,
        environment_bytes,
        root=root,
    )
    if bindings.get("runner_image_digest") != runner_image_digest:
        raise CIProposalError("EVIDENCE_RUNNER_IMAGE_DRIFT")
    runner_digest = _string(bindings.get("runner_digest"), "runner_digest")
    if (
        HEX64.fullmatch(runner_digest) is None
        or runner_digest != _repository_runner_digest(root)
    ):
        raise CIProposalError("RUNNER_DIGEST_INVALID")
    payloads = run["payloads"]
    if (
        not isinstance(payloads, list)
        or len(payloads) != 1
        or payloads[0].get("id") != scenario_id
        or payloads[0].get("path")
        != f"evidence/payloads/{scenario_id}.json"
        or payloads[0].get("sha256") != _sha256(payload_bytes)
        or integer(payloads[0].get("bytes"), "payload.bytes")
        != len(payload_bytes)
    ):
        raise CIProposalError("EVIDENCE_PAYLOAD_BINDING_DRIFT")
    if payload.get("oracle") != {
        "android_git_commit": expected_controls["android_git_commit"],
        "runner_digest": runner_digest,
        "runner_image_digest": runner_image_digest,
    }:
        raise CIProposalError("EVIDENCE_PAYLOAD_ORACLE_DRIFT")
    fixture, _, scenario = _fixture_entry(root, scenario_id)
    if (
        payload.get("fixture_id") != scenario_id
        or payload.get("fixture_sha256") != fixture["sha256"]
        or payload.get("scenario_id") != scenario_id
        or payload.get("scenario_sha256") != scenario["sha256"]
        or payload.get("source_lab_manifest_sha256")
        != expected_controls["source_lab_manifest_sha256"]
        or payload.get("input_sha256")
        != file_digest(root / fixture["path"] / "input.json")
    ):
        raise CIProposalError("EVIDENCE_SCENARIO_BINDING_DRIFT")
    return run, payload, payload_bytes


def finalize(
    root: Path,
    *,
    evidence_archive: Path,
    evidence_attestation_bundle: Path,
    attestation_url: str,
    output_dir: Path,
    scenario_id: str = FIXTURE_ID,
    request_work_item: Optional[str] = None,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    scenario_id = _validate_scenario_id(scenario_id)
    expected_request = _request_for_scenario(scenario_id)
    request_work_item = request_work_item or expected_request
    if request_work_item != expected_request:
        raise CIProposalError("REQUEST_WORK_ITEM_INVALID")
    request_path = root / f"ios/harness/work-items/{request_work_item}.json"
    request = _read_json(request_path)
    members = read_deterministic_tar(
        evidence_archive,
        expected_evidence_members(scenario_id),
    )
    run, payload, payload_bytes = _validate_evidence(
        root, members, request, scenario_id
    )
    if not attestation_url.startswith("https://github.com/"):
        raise CIProposalError("ATTESTATION_URL_INVALID")
    attestation_bytes = _read_bytes(
        evidence_attestation_bundle,
        limit=16 * 1024 * 1024,
    )
    fixture, case, _ = _fixture_entry(root, scenario_id)
    bindings = dict(_object(run["bindings"], "evidence.bindings"))
    for local_only in ("local_run_sha256", "artifact_sha256"):
        bindings.pop(local_only, None)
    producer = _object(run["producer"], "evidence.producer")
    proposal_id = (
        f"{scenario_id}-{producer['source_digest'][:12]}"
    )
    proposal = {
        "schema_version": 1,
        "kind": "android_oracle_proposal",
        "authority": "candidate_only",
        "status": "proposed",
        "proposal_id": proposal_id,
        "request": {
            "work_item_id": request_work_item,
            "fixture_ids": [scenario_id],
            "scenario_id": scenario_id,
        },
        "producer": {
            "system": "github-actions",
            "workflow_ref": producer["workflow_ref"],
            "run_id": producer["run_id"],
            "attestation_uri": attestation_url,
            "attestation_sha256": _sha256(attestation_bytes),
        },
        "bindings": bindings,
        "fixtures": [
            {
                "id": scenario_id,
                "operation": case["operation"],
                "fixture_path": fixture["path"],
                "fixture_sha256": fixture["sha256"],
                "payload_path": f"payloads/{scenario_id}.json",
                "payload_sha256": _sha256(payload_bytes),
                "payload_bytes": len(payload_bytes),
            }
        ],
    }
    output_dir = _private_directory(
        _external_output(root, output_dir),
        empty=True,
    )
    proposal_bytes = _dump(proposal)
    proposal_path = output_dir / "proposal/proposal.json"
    payload_path = output_dir / f"proposal/payloads/{scenario_id}.json"
    _private_write(proposal_path, proposal_bytes)
    _private_write(payload_path, payload_bytes)
    report = {"proposal_sha256": _sha256(proposal_bytes)}
    archive_path = output_dir / PROPOSAL_ARCHIVE_NAME
    archive_sha256 = deterministic_tar(
        archive_path,
        {
            "proposal/proposal.json": proposal_bytes,
            f"proposal/payloads/{scenario_id}.json": payload_bytes,
        },
    )
    return {
        "schema_version": 1,
        "authority": "candidate_only",
        "status": "proposal_prepared",
        "archive": archive_path.as_posix(),
        "archive_sha256": archive_sha256,
        "proposal_sha256": report["proposal_sha256"],
        "evidence_archive_sha256": file_digest(evidence_archive),
        "evidence_attestation_sha256": _sha256(attestation_bytes),
        "scenario_id": scenario_id,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="android-oracle-ci-proposal")
    commands = parser.add_subparsers(dest="command", required=True)

    environment = commands.add_parser("environment")
    environment.add_argument("--root", type=Path, required=True)
    environment.add_argument("--output", type=Path, required=True)
    environment.add_argument("--image-os", required=True)
    environment.add_argument("--image-version", required=True)

    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--root", type=Path, required=True)
    prepare_parser.add_argument("--local-run", type=Path, required=True)
    prepare_parser.add_argument("--runner-environment", type=Path, required=True)
    prepare_parser.add_argument("--output-dir", type=Path, required=True)
    prepare_parser.add_argument("--repository", required=True)
    prepare_parser.add_argument("--workflow-ref", required=True)
    prepare_parser.add_argument("--run-id", required=True)
    prepare_parser.add_argument("--source-digest", required=True)
    prepare_parser.add_argument("--scenario", default=FIXTURE_ID)
    prepare_parser.add_argument(
        "--request-work-item",
        default=None,
    )

    finalize_parser = commands.add_parser("finalize")
    finalize_parser.add_argument("--root", type=Path, required=True)
    finalize_parser.add_argument("--evidence-archive", type=Path, required=True)
    finalize_parser.add_argument(
        "--evidence-attestation-bundle",
        type=Path,
        required=True,
    )
    finalize_parser.add_argument("--attestation-url", required=True)
    finalize_parser.add_argument("--output-dir", type=Path, required=True)
    finalize_parser.add_argument("--scenario", default=FIXTURE_ID)
    finalize_parser.add_argument(
        "--request-work-item",
        default=None,
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "environment":
        report = write_environment(
            args.root,
            args.output,
            image_os=args.image_os,
            image_version=args.image_version,
        )
    elif args.command == "prepare":
        report = prepare(
            args.root,
            local_run=args.local_run,
            runner_environment=args.runner_environment,
            output_dir=args.output_dir,
            repository=args.repository,
            workflow_ref=args.workflow_ref,
            run_id=args.run_id,
            source_digest=args.source_digest,
            scenario_id=args.scenario,
            request_work_item=args.request_work_item,
        )
    else:
        report = finalize(
            args.root,
            evidence_archive=args.evidence_archive,
            evidence_attestation_bundle=args.evidence_attestation_bundle,
            attestation_url=args.attestation_url,
            output_dir=args.output_dir,
            scenario_id=args.scenario,
            request_work_item=args.request_work_item,
        )
    sys.stdout.buffer.write(_dump(report) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CIProposalError, OSError, ValueError) as error:
        if isinstance(error, CIProposalError):
            reason_code = error.reason_code
            detail = error.detail
        else:
            reason_code = "CI_PROPOSAL_FAILED"
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
