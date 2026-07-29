"""Fail-closed validation for candidate-only Android Oracle proposals."""

from __future__ import annotations

import hashlib
import os
import re
import stat
from pathlib import Path, PurePosixPath

from oracle import SHARED_CHANNELS
from oracle.canonicalizer import canonicalize_bytes, load_config
from oracle.exact_json import JSONNode, NumberToken, dumps, file_digest, integer, loads
from oracle.request_registry import (
    RequestRegistryError,
    load_registry,
    request_by_id,
)


ALLOWED_COMMANDS = ("doctor", "canonicalize", "compare", "verify-proposal")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
DIGEST = re.compile(r"(?:sha256:)?[0-9a-f]{64}\Z")
FIXTURE_ID = re.compile(r"[a-z0-9][a-z0-9-]+\Z")


class ProposalError(ValueError):
    pass


def doctor(root: Path) -> list[str]:
    try:
        root = root.resolve(strict=True)
        load_config(root / "ios/harness/normalization/canonical-v1.json")
        fixture_manifest = _read_json(root / "ios/harness/fixtures/manifest.json")
        _fixture_index(fixture_manifest)
        load_registry(root)
        for relative in (
            "ios/project/baseline.json",
            "ios/project/android-intake/inventory-manifest.json",
            "ios/project/requirements/catalog.json",
            "ios/harness/schemas/execution-envelope.schema.json",
            "ios/harness/goldens/manifest.json",
        ):
            _read_json(root / relative)
        if set(ALLOWED_COMMANDS) & {
            "publish",
            "accept",
            "record",
            "promote",
            "update-golden",
        }:
            raise ProposalError("write command exposed")
        return []
    except (OSError, ValueError) as error:
        return [str(error)]


def verify_proposal(
    root: Path,
    proposal_path: Path,
    expected_request_id: str,
) -> dict[str, JSONNode]:
    root = root.resolve(strict=True)
    proposal_path = proposal_path.absolute()
    if proposal_path.is_symlink():
        raise ProposalError("proposal file may not be a symlink")
    proposal_path = proposal_path.resolve(strict=True)
    if _is_relative_to(proposal_path, root / "ios/harness/goldens"):
        raise ProposalError("candidate proposal may not live in goldens")
    proposal_bytes = _read_candidate(proposal_path)
    proposal = loads(proposal_bytes)
    if not isinstance(proposal, dict):
        raise ProposalError("proposal must be an object")
    _exact_keys(
        proposal,
        {
            "schema_version",
            "kind",
            "authority",
            "status",
            "proposal_id",
            "request",
            "producer",
            "bindings",
            "fixtures",
        },
        "proposal",
    )
    _schema_one(proposal["schema_version"], "proposal.schema_version")
    _equals(proposal["kind"], "android_oracle_proposal", "proposal.kind")
    _equals(proposal["authority"], "candidate_only", "proposal.authority")
    _equals(proposal["status"], "proposed", "proposal.status")
    proposal_id = _string(proposal["proposal_id"], "proposal.proposal_id")
    if FIXTURE_ID.fullmatch(proposal_id) is None:
        raise ProposalError("proposal_id must use lowercase stable-id syntax")

    request = _object(proposal["request"], "proposal.request")
    request_fields = set(request)
    legacy_request_fields = {"work_item_id", "fixture_ids"}
    scenario_request_fields = legacy_request_fields | {"scenario_id"}
    if request_fields not in (legacy_request_fields, scenario_request_fields):
        raise ProposalError("proposal.request fields mismatch")
    scenario_aware = request_fields == scenario_request_fields
    request_id = _string(request["work_item_id"], "proposal.request.work_item_id")
    if re.fullmatch(r"IOS-[A-Z][A-Z0-9-]*-[0-9]{3}", request_id) is None:
        raise ProposalError("request.work_item_id is invalid")
    if request_id != expected_request_id:
        raise ProposalError("proposal request does not match the caller's trusted request")
    try:
        request_node = request_by_id(root, request_id)
    except RequestRegistryError as error:
        raise ProposalError("request is not registered") from error
    if request_node.get("authority") != "android_oracle_candidate_only":
        raise ProposalError("request is not authorized for Oracle golden generation")
    expected_fixture_ids = request_node["fixture_ids"]
    fixture_ids = _string_list(request["fixture_ids"], "proposal.request.fixture_ids")
    if fixture_ids != sorted(set(fixture_ids)) or not fixture_ids:
        raise ProposalError("request.fixture_ids must be a non-empty sorted unique set")
    if fixture_ids != sorted(_string_list(expected_fixture_ids, "request fixtures")):
        raise ProposalError("proposal fixture selection drifts from request registry")
    if scenario_aware:
        scenario_id = _string(request["scenario_id"], "proposal.request.scenario_id")
        if fixture_ids != [scenario_id]:
            raise ProposalError("proposal scenario must equal the unique selected fixture")
        if request_node.get("scenario_id") != scenario_id:
            raise ProposalError("proposal scenario drifts from request registry")

    producer = _object(proposal["producer"], "proposal.producer")
    _exact_keys(
        producer,
        {"system", "workflow_ref", "run_id", "attestation_uri", "attestation_sha256"},
        "proposal.producer",
    )
    for field in ("system", "workflow_ref", "run_id"):
        _nonempty(producer[field], f"proposal.producer.{field}")
    if not _string(producer["attestation_uri"], "attestation_uri").startswith("https://"):
        raise ProposalError("attestation_uri must use https")
    _hex64(producer["attestation_sha256"], "attestation_sha256")

    manifest = _read_json(root / "ios/harness/fixtures/manifest.json")
    bindings = _object(proposal["bindings"], "proposal.bindings")
    _validate_bindings(root, bindings, request_node, manifest, scenario_aware)
    config = load_config(root / "ios/harness/normalization/canonical-v1.json")
    indexed = _fixture_index(manifest)

    fixtures = proposal["fixtures"]
    if not isinstance(fixtures, list):
        raise ProposalError("proposal.fixtures must be an array")
    proposal_root = proposal_path.parent.resolve(strict=True)
    validated_ids: list[str] = []
    for entry in fixtures:
        fixture_id = _verify_fixture_entry(
            root, proposal_root, entry, indexed, bindings, config, scenario_aware
        )
        validated_ids.append(fixture_id)
    if validated_ids != fixture_ids:
        raise ProposalError("proposal fixtures must exactly match request.fixture_ids order")
    return {
        "authority": "candidate_only",
        "proposal_id": proposal_id,
        "request_work_item": request_id,
        "proposal_sha256": hashlib.sha256(dumps(proposal)).hexdigest(),
        "fixture_ids": validated_ids,
        "shared_channels": list(SHARED_CHANNELS),
    }


def fixture_digest(directory: Path) -> str:
    directory = directory.resolve(strict=True)
    inventory: list[JSONNode] = []
    for current, directories, files in os.walk(directory, followlinks=False):
        current_path = Path(current)
        for name in directories:
            if (current_path / name).is_symlink():
                raise ProposalError("fixture directory contains a symlink")
        for name in files:
            path = current_path / name
            if path.is_symlink() or not path.is_file():
                raise ProposalError("fixture entry must be a regular non-symlink file")
            inventory.append(
                {
                    "path": path.relative_to(directory).as_posix(),
                    "sha256": file_digest(path),
                }
            )
    inventory.sort(key=lambda item: item["path"])
    return hashlib.sha256(dumps(inventory)).hexdigest()


def canonical_file_digest(path: Path) -> str:
    return hashlib.sha256(dumps(_read_json(path))).hexdigest()


def implementation_digest(*names: str) -> str:
    directory = Path(__file__).parent
    inventory = [{"path": name, "sha256": file_digest(directory / name)} for name in sorted(names)]
    return hashlib.sha256(dumps(inventory)).hexdigest()


def _validate_bindings(
    root: Path,
    bindings: dict[str, JSONNode],
    request: JSONNode,
    fixture_manifest: JSONNode,
    scenario_aware: bool,
) -> None:
    expected = {
        "compatibility_profile",
        "android_git_commit",
        "android_git_tree",
        "checkout_clean",
        "runner_digest",
        "runner_image_digest",
        "request_work_item_sha256",
        "android_baseline_sha256",
        "fixture_manifest_sha256",
        "android_fact_inventory_sha256",
        "requirement_catalog_sha256",
        "execution_envelope_schema_sha256",
        "canonicalizer_id",
        "canonicalizer_config_sha256",
        "canonicalizer_implementation_sha256",
        "comparator_id",
        "comparator_implementation_sha256",
    }
    if scenario_aware:
        expected.add("source_lab_manifest_sha256")
    _exact_keys(bindings, expected, "proposal.bindings")
    _equals(bindings["compatibility_profile"], "android-legado-v1", "compatibility_profile")
    commit = _string(bindings["android_git_commit"], "android_git_commit")
    tree = _string(bindings["android_git_tree"], "android_git_tree")
    if HEX40.fullmatch(commit) is None or HEX40.fullmatch(tree) is None:
        raise ProposalError("android commit/tree must be 40 lowercase hex characters")
    if bindings["checkout_clean"] is not True:
        raise ProposalError("oracle checkout must be clean")
    for field in ("runner_digest", "runner_image_digest"):
        value = _string(bindings[field], field)
        if DIGEST.fullmatch(value) is None:
            raise ProposalError(f"{field} must be an immutable sha256 digest")
    if scenario_aware:
        runner_inventory = [
            {
                "path": path.relative_to(root).as_posix(),
                "sha256": file_digest(path),
            }
            for path in sorted(
                (
                    root
                    / "ios/harness/oracle/android-runner/"
                    "LegadoOracleInstrumentedTest.kt",
                    root
                    / "ios/harness/oracle/android-runner/orchestrator.py",
                    root
                    / "ios/harness/integration-lab/integration_lab.py",
                ),
                key=lambda value: value.relative_to(root).as_posix(),
            )
        ]
        if (
            bindings["runner_digest"]
            != hashlib.sha256(dumps(runner_inventory)).hexdigest()
        ):
            raise ProposalError("binding drift: runner_digest")

    baseline = _object(_read_json(root / "ios/project/baseline.json"), "baseline")
    oracle = _object(baseline.get("android_oracle"), "baseline.android_oracle")
    if oracle.get("git_commit") != commit:
        raise ProposalError("android commit is not the frozen baseline")
    inventory = _object(
        _read_json(root / "ios/project/android-intake/inventory-manifest.json"),
        "android fact inventory",
    )
    if inventory.get("android_git_commit") != commit or inventory.get("android_tree") != tree:
        raise ProposalError("android commit/tree drift from fact inventory")

    expected_digests = {
        "android_baseline_sha256": canonical_file_digest(root / "ios/project/baseline.json"),
        "request_work_item_sha256": hashlib.sha256(dumps(request)).hexdigest(),
        "fixture_manifest_sha256": hashlib.sha256(dumps(fixture_manifest)).hexdigest(),
        "android_fact_inventory_sha256": canonical_file_digest(
            root / "ios/project/android-intake/inventory-manifest.json"
        ),
        "requirement_catalog_sha256": canonical_file_digest(root / "ios/project/requirements/catalog.json"),
        "execution_envelope_schema_sha256": canonical_file_digest(
            root / "ios/harness/schemas/execution-envelope.schema.json"
        ),
        "canonicalizer_config_sha256": canonical_file_digest(
            root / "ios/harness/normalization/canonical-v1.json"
        ),
        "canonicalizer_implementation_sha256": implementation_digest("canonicalizer.py", "exact_json.py"),
        "comparator_implementation_sha256": implementation_digest(
            "__init__.py", "canonicalizer.py", "comparator.py", "exact_json.py"
        ),
    }
    if scenario_aware:
        expected_digests["source_lab_manifest_sha256"] = canonical_file_digest(
            root / "ios/harness/source-lab/manifest.json"
        )
    for field, expected_digest in expected_digests.items():
        _hex64(bindings[field], field)
        if bindings[field] != expected_digest:
            raise ProposalError(f"binding drift: {field}")
    _equals(bindings["canonicalizer_id"], "canonical-v1", "canonicalizer_id")
    _equals(bindings["comparator_id"], "shared-exact-v1", "comparator_id")


def _verify_fixture_entry(
    root: Path,
    proposal_root: Path,
    entry: JSONNode,
    indexed: dict[str, dict[str, JSONNode]],
    bindings: dict[str, JSONNode],
    config: dict[str, JSONNode],
    scenario_aware: bool,
) -> str:
    entry = _object(entry, "proposal fixture")
    _exact_keys(
        entry,
        {
            "id",
            "operation",
            "fixture_path",
            "fixture_sha256",
            "payload_path",
            "payload_sha256",
            "payload_bytes",
        },
        "proposal fixture",
    )
    fixture_id = _string(entry["id"], "fixture.id")
    manifest_entry = indexed.get(fixture_id)
    if manifest_entry is None:
        raise ProposalError(f"fixture is not indexed: {fixture_id}")
    for field in ("fixture_path", "fixture_sha256"):
        if entry[field] != manifest_entry[field.removeprefix("fixture_")]:
            raise ProposalError(f"fixture manifest drift: {fixture_id}.{field}")
    fixture_path = _string(entry["fixture_path"], "fixture_path")
    fixture_directory = _safe_directory(root, fixture_path)
    if fixture_directory.name != fixture_id or fixture_digest(fixture_directory) != entry["fixture_sha256"]:
        raise ProposalError(f"fixture content drift: {fixture_id}")
    case = _object(_read_json(fixture_directory / "case.json"), "fixture case")
    operation = _string(entry["operation"], "fixture.operation")
    if case.get("id") != fixture_id or case.get("operation") != operation:
        raise ProposalError(f"fixture case identity drift: {fixture_id}")

    payload_relative = _string(entry["payload_path"], "payload_path")
    if payload_relative != f"payloads/{fixture_id}.json":
        raise ProposalError("payload_path must be payloads/<fixture-id>.json")
    payload_path = _safe_file(proposal_root, payload_relative)
    payload = _read_candidate(payload_path)
    if integer(entry["payload_bytes"], "payload_bytes") != len(payload):
        raise ProposalError(f"payload byte count drift: {fixture_id}")
    _hex64(entry["payload_sha256"], "payload_sha256")
    if hashlib.sha256(payload).hexdigest() != entry["payload_sha256"]:
        raise ProposalError(f"payload hash drift: {fixture_id}")
    if canonicalize_bytes(payload, config) != payload:
        raise ProposalError(f"payload is not canonical-v1 bytes: {fixture_id}")
    _validate_payload(loads(payload), fixture_id, entry, bindings, root, scenario_aware)
    return fixture_id


def _validate_payload(
    payload: JSONNode,
    fixture_id: str,
    fixture: dict[str, JSONNode],
    bindings: dict[str, JSONNode],
    root: Path,
    scenario_aware: bool,
) -> None:
    payload = _object(payload, "oracle payload")
    expected_payload_fields = {
            "schema_version",
            "kind",
            "fixture_id",
            "fixture_sha256",
            "operation",
            "compatibility_profile",
            "oracle",
            "artifact",
    }
    if scenario_aware:
        expected_payload_fields.update(
            {
                "scenario_id",
                "scenario_sha256",
                "source_lab_manifest_sha256",
                "input_sha256",
            }
        )
    _exact_keys(payload, expected_payload_fields, "oracle payload")
    _schema_one(payload["schema_version"], "payload.schema_version")
    _equals(payload["kind"], "android_oracle_payload", "payload.kind")
    payload_bindings = {
        "fixture_id": fixture["id"],
        "fixture_sha256": fixture["fixture_sha256"],
        "operation": fixture["operation"],
    }
    for field, expected in payload_bindings.items():
        if payload[field] != expected:
            raise ProposalError(f"payload binding drift: {fixture_id}.{field}")
    if payload["compatibility_profile"] != bindings["compatibility_profile"]:
        raise ProposalError("payload compatibility profile drift")
    if scenario_aware:
        if payload["scenario_id"] != fixture_id:
            raise ProposalError("payload scenario identity drift")
        source_lab_manifest = _object(
            _read_json(root / "ios/harness/source-lab/manifest.json"),
            "source lab manifest",
        )
        scenarios = [
            value
            for value in source_lab_manifest.get("scenarios", [])
            if isinstance(value, dict) and value.get("id") == fixture_id
        ]
        if len(scenarios) != 1:
            raise ProposalError("source lab scenario must be unique")
        scenario = scenarios[0]
        if (
            scenario.get("path") != fixture["fixture_path"]
            or payload["scenario_sha256"] != scenario.get("sha256")
            or payload["source_lab_manifest_sha256"]
            != bindings["source_lab_manifest_sha256"]
            or payload["input_sha256"]
            != file_digest(root / fixture["fixture_path"] / "input.json")
        ):
            raise ProposalError("payload source lab binding drift")
    oracle = _object(payload["oracle"], "payload.oracle")
    _exact_keys(oracle, {"android_git_commit", "runner_digest", "runner_image_digest"}, "payload.oracle")
    for field in oracle:
        if oracle[field] != bindings[field]:
            raise ProposalError(f"payload oracle binding drift: {field}")

    artifact = _object(payload["artifact"], "payload.artifact")
    required = {"schema_version", "fixture_id", "engine", "request_plan", "decode", "stages", "result", "issues"}
    if not required.issubset(artifact):
        raise ProposalError("execution artifact is missing required fields")
    _schema_one(artifact["schema_version"], "artifact.schema_version")
    if artifact["fixture_id"] != fixture_id:
        raise ProposalError("artifact fixture identity drift")
    engine = _object(artifact["engine"], "artifact.engine")
    if engine.get("platform") != "android" or engine.get("compatibility_profile") != bindings["compatibility_profile"]:
        raise ProposalError("artifact engine identity drift")
    if engine.get("revision") != bindings["android_git_commit"]:
        raise ProposalError("artifact engine revision must bind the Android commit")
    if not isinstance(artifact["request_plan"], list) or not isinstance(artifact["stages"], list):
        raise ProposalError("artifact request_plan/stages must be arrays")
    if artifact["decode"] is not None and not isinstance(artifact["decode"], dict):
        raise ProposalError("artifact decode must be object or null")
    if not isinstance(artifact["issues"], list):
        raise ProposalError("artifact issues must be an array")
    result = _object(artifact["result"], "artifact.result")
    if not isinstance(result.get("type"), str) or not isinstance(result.get("value"), dict):
        raise ProposalError("artifact result is invalid")
    lanes = result["value"]
    if "portable_known_projection" not in lanes or "android_characterization" not in lanes:
        raise ProposalError("Android artifact must expose portable and characterization lanes")
    if "ios_lossless_extension" in lanes:
        raise ProposalError("Android artifact may not claim the iOS lossless extension")
    if not set(lanes).issubset(
        {"fixture_integrity", "portable_known_projection", "android_characterization"}
    ):
        raise ProposalError("Android artifact contains an undeclared result lane")


def _fixture_index(manifest: JSONNode) -> dict[str, dict[str, JSONNode]]:
    manifest = _object(manifest, "fixture manifest")
    _exact_keys(manifest, {"schema_version", "compatibility_profile", "canonicalizer", "fixtures"}, "fixture manifest")
    _schema_one(manifest["schema_version"], "fixture manifest schema")
    _equals(manifest["compatibility_profile"], "android-legado-v1", "fixture manifest profile")
    _equals(manifest["canonicalizer"], "canonical-v1", "fixture manifest canonicalizer")
    if not isinstance(manifest["fixtures"], list):
        raise ProposalError("fixture manifest entries must be an array")
    result: dict[str, dict[str, JSONNode]] = {}
    paths: set[str] = set()
    for value in manifest["fixtures"]:
        entry = _object(value, "fixture manifest entry")
        _exact_keys(entry, {"id", "path", "sha256"}, "fixture manifest entry")
        fixture_id = _string(entry["id"], "fixture manifest id")
        path = _string(entry["path"], "fixture manifest path")
        _hex64(entry["sha256"], "fixture manifest sha256")
        if FIXTURE_ID.fullmatch(fixture_id) is None or fixture_id in result or path in paths:
            raise ProposalError("fixture manifest contains duplicate/invalid identity")
        if not path.startswith("ios/harness/fixtures/"):
            raise ProposalError("fixture manifest path is outside fixture root")
        result[fixture_id] = entry
        paths.add(path)
    return result


def _safe_file(base: Path, relative: str) -> Path:
    path = _safe_path(base, relative)
    if not path.is_file():
        raise ProposalError("referenced path must be a regular file")
    return path


def _safe_directory(base: Path, relative: str) -> Path:
    path = _safe_path(base, relative)
    if not path.is_dir():
        raise ProposalError("referenced path must be a directory")
    return path


def _safe_path(base: Path, relative: str) -> Path:
    if not relative or "\\" in relative or "\0" in relative or ":" in relative:
        raise ProposalError("invalid relative POSIX path")
    pure = PurePosixPath(relative)
    raw_parts = relative.split("/")
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in raw_parts):
        raise ProposalError("path escapes its authority root")
    base = base.resolve(strict=True)
    current = base
    for part in pure.parts:
        current = current / part
        if current.is_symlink():
            raise ProposalError("symlink path is forbidden")
    resolved = current.resolve(strict=True)
    if not _is_relative_to(resolved, base):
        raise ProposalError("path escapes its authority root")
    return resolved


def _read_json(path: Path) -> JSONNode:
    return loads(path.read_bytes())


def _read_candidate(path: Path) -> bytes:
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ProposalError("candidate must be a single-link regular file")
    value = path.read_bytes()
    after = os.lstat(path)
    identity = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
    if identity(before) != identity(after) or len(value) != after.st_size:
        raise ProposalError("candidate changed while it was being read")
    return value


def _object(value: JSONNode, field: str) -> dict[str, JSONNode]:
    if not isinstance(value, dict):
        raise ProposalError(f"{field} must be an object")
    return value


def _string(value: JSONNode, field: str) -> str:
    if not isinstance(value, str):
        raise ProposalError(f"{field} must be a string")
    return value


def _nonempty(value: JSONNode, field: str) -> str:
    value = _string(value, field)
    if not value:
        raise ProposalError(f"{field} may not be empty")
    return value


def _string_list(value: JSONNode, field: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ProposalError(f"{field} must be a string array")
    return value


def _exact_keys(value: dict, expected: set[str], field: str) -> None:
    if set(value) != expected:
        raise ProposalError(f"{field} fields mismatch")


def _schema_one(value: JSONNode, field: str) -> None:
    if not isinstance(value, NumberToken) or value.token != "1":
        raise ProposalError(f"{field} must be 1")


def _equals(value: JSONNode, expected: JSONNode, field: str) -> None:
    if value != expected:
        raise ProposalError(f"{field} must equal {expected}")


def _hex64(value: JSONNode, field: str) -> str:
    value = _string(value, field)
    if HEX64.fullmatch(value) is None:
        raise ProposalError(f"{field} must be 64 lowercase hex characters")
    return value


def _is_relative_to(path: Path, base: Path) -> bool:
    try:
        path.relative_to(base.resolve())
        return True
    except ValueError:
        return False
