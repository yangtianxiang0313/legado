#!/usr/bin/env python3
"""Candidate-only Android WebBook runner over a deterministic SourceLab site."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional, Sequence


RUNNER_VERSION = "android-webbook-instrumentation-v1"
COMMANDS = ("doctor", "run")
DEFAULT_SCENARIO_ID = "sl-html-basic-001"
SCENARIO_ID = DEFAULT_SCENARIO_ID
LOGICAL_ORIGIN = "http://sourcelab.test"
BASELINE_PATH = "ios/project/baseline.json"
INVENTORY_PATH = "ios/project/android-intake/inventory-manifest.json"
FIXTURE_MANIFEST_PATH = "ios/harness/fixtures/manifest.json"
SOURCE_LAB_MANIFEST_PATH = "ios/harness/source-lab/manifest.json"
CANONICALIZER_PATH = "ios/harness/normalization/canonical-v1.json"
KOTLIN_RUNNER = "LegadoOracleInstrumentedTest.kt"
OVERLAY_RELATIVE = (
    "app/src/androidTest/java/io/legado/app/oracle/"
    "LegadoOracleInstrumentedTest.kt"
)
RAW_DEVICE_PATH = "files/legado-oracle-raw.json"
TARGET_PACKAGE = "io.legado.app.debug"
TEST_PACKAGE = "io.legado.app.debug.test"
INSTRUMENTATION = (
    "io.legado.app.debug.test/androidx.test.runner.AndroidJUnitRunner"
)
TEST_CLASS = (
    "io.legado.app.oracle.LegadoOracleInstrumentedTest"
    "#runSourceLabCharacterization"
)
EXPECTED_CASES = (
    ("search-hit", "search"),
    ("search-empty", "search"),
    ("book-detail", "book_info"),
    ("book-detail-missing-cover", "book_info"),
    ("toc", "chapters"),
    ("toc-empty", "chapters"),
    ("chapter", "content"),
    ("chapter-second", "content"),
)
NOMINAL_CASES = {
    "search-hit",
    "book-detail",
    "toc",
    "chapter",
    "chapter-second",
}
SCENARIO_CONTRACTS = {
    "sl-html-basic-001": {
        "status": "reference",
        "expected_cases": EXPECTED_CASES,
        "nominal_cases": frozenset(NOMINAL_CASES),
    },
    "sl-post-form-001": {
        "status": "candidate",
        "expected_cases": (
            ("post-form-nominal", "search"),
            ("post-form-boundary", "search"),
        ),
        "nominal_cases": frozenset({"post-form-nominal"}),
    },
    "sl-source-response-xml-declaration-normalization-001": {
        "status": "candidate",
        "expected_cases": (
            ("xml-missing-declaration", "raw_response"),
            ("xml-existing-declaration", "raw_response"),
            ("non-xml-content-type", "raw_response"),
        ),
        "nominal_cases": frozenset({"xml-missing-declaration"}),
    },
    "sl-source-request-header-cookie-retry-layering-001": {
        "status": "candidate",
        "expected_cases": (
            ("retry-two-with-header-cookie", "request_options"),
            ("retry-default", "request_options"),
        ),
        "nominal_cases": frozenset({"retry-two-with-header-cookie"}),
    },
    "sl-source-request-field-encoding-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("utf8-preserved-and-duplicate", "field_encoding"),
            ("declared-gbk", "field_encoding"),
            ("escape-mode", "field_encoding"),
            ("invalid-charset", "field_encoding"),
        ),
        "nominal_cases": frozenset({
            "utf8-preserved-and-duplicate",
            "declared-gbk",
        }),
    },
}
ANDROID_PRODUCT_PATHS = (
    "app/src/main",
    "app/build.gradle",
    "modules",
    "build.gradle",
    "settings.gradle",
    "gradle",
    "gradle.properties",
)


class AndroidOracleRunnerError(RuntimeError):
    def __init__(self, reason_code: str, detail: str = ""):
        super().__init__(reason_code)
        self.reason_code = reason_code
        self.detail = detail


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AndroidOracleRunnerError(
            "CONTROL_JSON_INVALID",
            path.as_posix(),
        ) from error


def _run(
    argv: Sequence[str],
    *,
    cwd: Path,
    timeout: int,
    check: bool = True,
    input_bytes: Optional[bytes] = None,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            list(argv),
            cwd=cwd,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AndroidOracleRunnerError(
            "COMMAND_EXECUTION_FAILED",
            Path(argv[0]).name,
        ) from error
    if check and result.returncode != 0:
        raise AndroidOracleRunnerError(
            "COMMAND_FAILED",
            f"{Path(argv[0]).name}:{result.returncode}",
        )
    return result


def _git(root: Path, *arguments: str, check: bool = True) -> bytes:
    return _run(
        ["git", *arguments],
        cwd=root,
        timeout=60,
        check=check,
    ).stdout


def _safe_regular(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise AndroidOracleRunnerError(
            "REGULAR_FILE_REQUIRED",
            path.as_posix(),
        )
    return path


def _file_sha(path: Path) -> str:
    return _sha256(_safe_regular(path).read_bytes())


def _runner_files() -> tuple[Path, ...]:
    directory = Path(__file__).resolve().parent
    return (
        directory / KOTLIN_RUNNER,
        directory / "orchestrator.py",
    )


def runner_digest() -> str:
    entries = [
        {
            "path": path.name,
            "sha256": _file_sha(path),
        }
        for path in sorted(_runner_files(), key=lambda value: value.name)
    ]
    return _sha256(_canonical(entries))


def frozen_identity(root: Path) -> Dict[str, str]:
    baseline = _read_json(root / BASELINE_PATH)
    inventory = _read_json(root / INVENTORY_PATH)
    oracle = baseline.get("android_oracle")
    if not isinstance(oracle, dict):
        raise AndroidOracleRunnerError("ANDROID_BASELINE_MISSING")
    commit = oracle.get("git_commit")
    if (
        not isinstance(commit, str)
        or inventory.get("android_git_commit") != commit
    ):
        raise AndroidOracleRunnerError("ANDROID_COMMIT_BINDING_DRIFT")
    tree = (
        _git(root, "rev-parse", f"{commit}^{{tree}}")
        .decode("ascii")
        .strip()
    )
    if inventory.get("android_tree") != tree:
        raise AndroidOracleRunnerError("ANDROID_TREE_BINDING_DRIFT")
    product_diff = _git(
        root,
        "diff",
        "--name-only",
        commit,
        "--",
        *ANDROID_PRODUCT_PATHS,
    )
    dirty_product = _git(
        root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        *ANDROID_PRODUCT_PATHS,
    )
    if product_diff.strip() or dirty_product.strip():
        raise AndroidOracleRunnerError("ANDROID_PRODUCT_TREE_DRIFT")
    return {"android_git_commit": commit, "android_git_tree": tree}


def _scenario_contract(scenario_id: str) -> Mapping[str, Any]:
    contract = SCENARIO_CONTRACTS.get(scenario_id)
    if contract is None:
        raise AndroidOracleRunnerError(
            "SCENARIO_NOT_SUPPORTED",
            scenario_id,
        )
    return contract


def repository_bindings(
    root: Path,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, str]:
    identity = frozen_identity(root)
    contract = _scenario_contract(scenario_id)
    fixture_manifest = _read_json(root / FIXTURE_MANIFEST_PATH)
    source_lab_manifest = _read_json(root / SOURCE_LAB_MANIFEST_PATH)
    fixture_entries = {
        entry.get("id"): entry
        for entry in fixture_manifest.get("fixtures", [])
        if isinstance(entry, dict)
    }
    source_lab_entries = {
        entry.get("id"): entry
        for entry in source_lab_manifest.get("scenarios", [])
        if isinstance(entry, dict)
    }
    fixture_entry = fixture_entries.get(scenario_id)
    scenario_entry = source_lab_entries.get(scenario_id)
    if (
        not isinstance(fixture_entry, dict)
        or not isinstance(scenario_entry, dict)
        or scenario_entry.get("status") != contract["status"]
    ):
        raise AndroidOracleRunnerError("SOURCE_LAB_BINDING_MISSING")
    fixture_path = fixture_entry.get("path")
    expected_path = f"ios/harness/fixtures/source-lab/{scenario_id}"
    if (
        fixture_path != expected_path
        or scenario_entry.get("path") != expected_path
    ):
        raise AndroidOracleRunnerError("SOURCE_LAB_PATH_DRIFT")
    fixture_root = root / expected_path
    source_path = fixture_root / "source.template.json"
    input_path = fixture_root / "input.json"
    case_path = fixture_root / "case.json"
    return {
        **identity,
        "scenario_id": scenario_id,
        "runner_id": RUNNER_VERSION,
        "runner_digest": runner_digest(),
        "fixture_sha256": str(fixture_entry.get("sha256")),
        "scenario_sha256": str(scenario_entry.get("sha256")),
        "source_template_sha256": _file_sha(source_path),
        "input_sha256": _file_sha(input_path),
        "case_sha256": _file_sha(case_path),
        "fixture_manifest_sha256": _sha256(
            _canonical(fixture_manifest)
        ),
        "source_lab_manifest_sha256": _sha256(
            _canonical(source_lab_manifest)
        ),
        "canonicalizer_sha256": _sha256(
            _canonical(_read_json(root / CANONICALIZER_PATH))
        ),
    }


def _recursive_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for entry in value:
            yield from _recursive_strings(entry)
    elif isinstance(value, dict):
        for entry in value.values():
            yield from _recursive_strings(entry)


def normalize_raw_artifact(
    raw: Mapping[str, Any],
    bindings: Mapping[str, str],
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    contract = _scenario_contract(scenario_id)
    expected_cases = tuple(contract["expected_cases"])
    nominal_cases = set(contract["nominal_cases"])
    if (
        raw.get("schema_version") != 1
        or raw.get("scenario_id") != scenario_id
        or raw.get("logical_origin") != LOGICAL_ORIGIN
    ):
        raise AndroidOracleRunnerError("RAW_ARTIFACT_IDENTITY_INVALID")
    device_origin = raw.get("device_origin")
    if (
        not isinstance(device_origin, str)
        or not device_origin.startswith("http://127.0.0.1:")
    ):
        raise AndroidOracleRunnerError("RAW_DEVICE_ORIGIN_INVALID")
    request_plan = raw.get("request_plan")
    cases = raw.get("cases")
    if not isinstance(request_plan, list) or not isinstance(cases, list):
        raise AndroidOracleRunnerError("RAW_ARTIFACT_SHAPE_INVALID")
    actual_cases = [
        (entry.get("id"), entry.get("operation"))
        for entry in cases
        if isinstance(entry, dict)
    ]
    if actual_cases != list(expected_cases) or len(request_plan) != len(cases):
        raise AndroidOracleRunnerError("RAW_CASE_SELECTION_DRIFT")
    source_lab_observation = None
    if scenario_id == "sl-source-request-header-cookie-retry-layering-001":
        route_counts = raw.get("source_lab_route_counts")
        expected_route_ids = [case_id for case_id, _ in expected_cases]
        if (
            not isinstance(route_counts, dict)
            or set(route_counts) != set(expected_route_ids)
            or any(
                not isinstance(route_counts[route_id], int)
                or isinstance(route_counts[route_id], bool)
                or route_counts[route_id] < 1
                for route_id in expected_route_ids
            )
        ):
            raise AndroidOracleRunnerError(
                "SOURCE_LAB_OBSERVATION_INVALID"
            )
        source_lab_observation = {
            "route_request_counts": [
                {
                    "route_id": route_id,
                    "request_count": route_counts[route_id],
                }
                for route_id in expected_route_ids
            ]
        }
    portable_cases = []
    issues = []
    android_exceptions = []
    for index, entry in enumerate(cases):
        if not isinstance(entry, dict) or set(entry) != {
            "id",
            "operation",
            "request",
            "result",
            "issue",
        }:
            raise AndroidOracleRunnerError("RAW_CASE_INVALID")
        issue = entry["issue"]
        result = entry["result"]
        if entry["id"] in nominal_cases and (
            issue is not None or not isinstance(result, dict)
        ):
            raise AndroidOracleRunnerError(
                "ANDROID_CHARACTERIZATION_FAILED",
                str(entry.get("id")),
            )
        if issue is not None and (
            not isinstance(issue, dict)
            or issue.get("code") != "android_exception"
            or not isinstance(issue.get("exception_type"), str)
            or result is not None
        ):
            raise AndroidOracleRunnerError("RAW_ISSUE_INVALID")
        if issue is None and not isinstance(result, dict):
            raise AndroidOracleRunnerError("RAW_RESULT_INVALID")
        if entry["request"] != request_plan[index]:
            raise AndroidOracleRunnerError("RAW_REQUEST_BINDING_DRIFT")
        request = request_plan[index]
        expected_request_keys = {
            "method",
            "url",
            "headers",
            "body",
            "timeout_ms",
        }
        if scenario_id == "sl-post-form-001":
            expected_request_keys.update(
                {"body_base64", "form_fields"}
            )
        if (
            not isinstance(request, dict)
            or (
                request.get("method") not in {"GET", "POST"}
                if scenario_id
                == "sl-source-request-field-encoding-runtime-001"
                else request.get("method")
                != (
                    "POST"
                    if scenario_id == "sl-post-form-001"
                    else "GET"
                )
            )
            or not str(request.get("url", "")).startswith(LOGICAL_ORIGIN + "/")
            or set(request) != expected_request_keys
        ):
            raise AndroidOracleRunnerError("RAW_REQUEST_INVALID")
        if scenario_id == "sl-post-form-001":
            body = request.get("body")
            body_base64 = request.get("body_base64")
            fields = request.get("form_fields")
            if (
                not isinstance(body, str)
                or not isinstance(body_base64, str)
                or not isinstance(fields, list)
                or any(
                    not isinstance(value, dict)
                    or set(value) != {"key", "value"}
                    or not isinstance(value["key"], str)
                    or not isinstance(value["value"], str)
                    for value in fields
                )
            ):
                raise AndroidOracleRunnerError(
                    "RAW_POST_REQUEST_INVALID"
                )
            try:
                decoded_body = base64.b64decode(
                    body_base64,
                    validate=True,
                ).decode("utf-8")
            except (ValueError, UnicodeDecodeError) as error:
                raise AndroidOracleRunnerError(
                    "RAW_POST_BODY_INVALID"
                ) from error
            if decoded_body != body:
                raise AndroidOracleRunnerError(
                    "RAW_POST_BODY_BINDING_DRIFT"
                )
        portable_issue = (
            {
                "code": "rule_failed",
                "stage": "field_evaluation",
            }
            if issue is not None
            else None
        )
        portable_cases.append(
            {
                "id": entry["id"],
                "operation": entry["operation"],
                "result": result,
                "issue": portable_issue,
            }
        )
        if issue is not None:
            issues.append(
                {
                    "case_id": entry["id"],
                    "code": "rule_failed",
                    "stage": "field_evaluation",
                }
            )
            android_exceptions.append(
                {
                    "case_id": entry["id"],
                    "exception_type": issue["exception_type"],
                }
            )
    normalized_values = list(_recursive_strings(portable_cases))
    if any(device_origin in value for value in normalized_values):
        raise AndroidOracleRunnerError("DEVICE_ORIGIN_LEAK")
    stages = []
    issue_cases = {entry["case_id"] for entry in issues}
    for case_id, _ in expected_cases:
        for stage in (
            "url_template",
            "request_build",
            "transport",
            "response_decode",
            "document_creation",
            "field_evaluation",
            "url_completion",
            "result_mapping",
        ):
            stages.append(
                {
                    "case_id": case_id,
                    "stage": stage,
                    "outcome": (
                        "failed"
                        if case_id in issue_cases
                        and stage == "field_evaluation"
                        else "completed"
                    ),
                    "issue_code": (
                        "rule_failed"
                        if case_id in issue_cases
                        and stage == "field_evaluation"
                        else None
                    ),
                }
            )
            if (
                case_id in issue_cases
                and stage == "field_evaluation"
            ):
                break
    artifact = {
        "schema_version": 1,
        "fixture_id": scenario_id,
        "engine": {
            "platform": "android",
            "revision": bindings["android_git_commit"],
            "compatibility_profile": "android-legado-v1",
        },
        "request_plan": request_plan,
        "decode": None,
        "stages": stages,
        "result": {
            "type": "source_pipeline",
            "value": {
                "fixture_integrity": {
                    "fixture_sha256": bindings["fixture_sha256"],
                    "scenario_sha256": bindings["scenario_sha256"],
                    "source_template_sha256": bindings[
                        "source_template_sha256"
                    ],
                    "input_sha256": bindings["input_sha256"],
                },
                "portable_known_projection": {
                    "cases": portable_cases,
                },
                "android_characterization": {
                    "runner_id": bindings["runner_id"],
                    "runner_digest": bindings["runner_digest"],
                    "case_count": len(portable_cases),
                    "exceptions": android_exceptions,
                },
            },
        },
        "issues": issues,
    }
    if source_lab_observation is not None:
        artifact["result"]["value"]["android_characterization"][
            "source_lab_observation"
        ] = source_lab_observation
    return artifact


def local_run_document(
    artifact: Mapping[str, Any],
    bindings: Mapping[str, str],
    *,
    emulator_serial: str,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    artifact_sha256 = _sha256(_canonical(artifact))
    return {
        "schema_version": 1,
        "kind": "android_oracle_local_run",
        "authority": "local_unverified",
        "status": "candidate_only",
        "scenario_id": scenario_id,
        "emulator": {
            "serial_sha256": _sha256(emulator_serial.encode("utf-8")),
        },
        "bindings": dict(bindings),
        "artifact_sha256": artifact_sha256,
        "artifact": dict(artifact),
    }


def _atomic_private_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise AndroidOracleRunnerError("OUTPUT_DIRECTORY_INVALID")
    if stat.S_IMODE(path.parent.stat().st_mode) & 0o077:
        os.chmod(path.parent, 0o700)
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise AndroidOracleRunnerError("OUTPUT_PATH_INVALID")
    descriptor, raw_temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(raw_temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.write(b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _output_path(
    root: Path,
    requested: Optional[Path],
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Path:
    output_root = root / ".harness-runtime/android-oracle"
    if requested is None:
        return output_root / f"{scenario_id}-local-run.json"
    candidate = requested if requested.is_absolute() else root / requested
    candidate = candidate.absolute()
    try:
        candidate.relative_to(output_root.absolute())
    except ValueError as error:
        raise AndroidOracleRunnerError("OUTPUT_OUTSIDE_RUNTIME") from error
    return candidate


def _package_present(
    root: Path,
    adb: Path,
    serial: str,
    package: str,
) -> bool:
    result = _run(
        [str(adb), "-s", serial, "shell", "pm", "path", package],
        cwd=root,
        timeout=30,
        check=False,
    )
    return result.returncode == 0 and result.stdout.startswith(b"package:")


def _device_ready(root: Path, adb: Path, serial: str) -> None:
    _safe_regular(adb)
    state = _run(
        [str(adb), "-s", serial, "get-state"],
        cwd=root,
        timeout=30,
    ).stdout.strip()
    booted = _run(
        [
            str(adb),
            "-s",
            serial,
            "shell",
            "getprop",
            "sys.boot_completed",
        ],
        cwd=root,
        timeout=30,
    ).stdout.strip()
    if state != b"device" or booted != b"1":
        raise AndroidOracleRunnerError("EMULATOR_NOT_READY")
    for package in (TARGET_PACKAGE, TEST_PACKAGE):
        if _package_present(root, adb, serial, package):
            raise AndroidOracleRunnerError(
                "DEVICE_PACKAGE_PRESENT",
                package,
            )


def _single_apk(worktree: Path, pattern: str) -> Path:
    matches = [
        path
        for path in worktree.glob(pattern)
        if path.is_file() and not path.is_symlink()
    ]
    if len(matches) != 1:
        raise AndroidOracleRunnerError(
            "APK_DISCOVERY_FAILED",
            pattern,
        )
    return matches[0]


def _render_source(
    root: Path,
    origin: str,
    scenario_id: str,
) -> Dict[str, Any]:
    source_lab_directory = root / "ios/harness/source-lab"
    if str(source_lab_directory) not in sys.path:
        sys.path.insert(0, str(source_lab_directory))
    import source_lab  # type: ignore

    return source_lab.build_source(root, scenario_id, origin)


def _source_lab_server(root: Path, scenario_id: str):
    source_lab_directory = root / "ios/harness/source-lab"
    if str(source_lab_directory) not in sys.path:
        sys.path.insert(0, str(source_lab_directory))
    import source_lab  # type: ignore

    return source_lab.running_server(root, scenario_id)


def _render_inputs(root: Path, scenario_id: str) -> Dict[str, Any]:
    path = (
        root
        / "ios/harness/fixtures/source-lab"
        / scenario_id
        / "input.json"
    )
    value = _read_json(path)
    if not isinstance(value, dict):
        raise AndroidOracleRunnerError("INPUT_DOCUMENT_INVALID")
    return value


def run_characterization(
    root: Path,
    *,
    adb: Path,
    serial: str,
    output: Optional[Path] = None,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    contract = _scenario_contract(scenario_id)
    expected_cases = tuple(contract["expected_cases"])
    bindings = repository_bindings(root, scenario_id)
    _device_ready(root, adb, serial)
    temporary_root = Path(
        tempfile.mkdtemp(prefix="legado-android-oracle-")
    ).resolve()
    worktree = temporary_root / "android"
    worktree_registered = False
    installed_packages: list[str] = []
    reverse_port: Optional[int] = None
    try:
        _git(
            root,
            "worktree",
            "add",
            "--detach",
            str(worktree),
            bindings["android_git_commit"],
        )
        worktree_registered = True
        overlay = worktree / OVERLAY_RELATIVE
        overlay.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            Path(__file__).resolve().parent / KOTLIN_RUNNER,
            overlay,
        )
        status = _git(
            worktree,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        ).decode("utf-8").splitlines()
        expected_status = f"?? {OVERLAY_RELATIVE}"
        if status != [expected_status]:
            raise AndroidOracleRunnerError(
                "WORKTREE_OVERLAY_DRIFT",
                ",".join(status),
            )
        _run(
            [
                str(worktree / "gradlew"),
                ":app:assembleAppDebug",
                ":app:assembleAppDebugAndroidTest",
                "--offline",
                "--no-daemon",
            ],
            cwd=worktree,
            timeout=1800,
        )
        main_apk = _single_apk(
            worktree,
            "app/build/outputs/apk/app/debug/*.apk",
        )
        test_apk = _single_apk(
            worktree,
            "app/build/outputs/apk/androidTest/app/debug/*.apk",
        )
        _run(
            [str(adb), "-s", serial, "install", str(main_apk)],
            cwd=root,
            timeout=180,
        )
        installed_packages.append(TARGET_PACKAGE)
        _run(
            [str(adb), "-s", serial, "install", str(test_apk)],
            cwd=root,
            timeout=180,
        )
        installed_packages.append(TEST_PACKAGE)

        with _source_lab_server(root, scenario_id) as server:
            reverse_port = int(server.server_address[1])
            _run(
                [
                    str(adb),
                    "-s",
                    serial,
                    "reverse",
                    f"tcp:{reverse_port}",
                    f"tcp:{reverse_port}",
                ],
                cwd=root,
                timeout=30,
            )
            device_origin = f"http://127.0.0.1:{reverse_port}"
            source = _render_source(
                root,
                device_origin,
                scenario_id,
            )
            inputs = _render_inputs(root, scenario_id)
            source_base64 = base64.b64encode(
                _canonical(source)
            ).decode("ascii")
            input_base64 = base64.b64encode(
                _canonical(inputs)
            ).decode("ascii")
            instrumentation = _run(
                [
                    str(adb),
                    "-s",
                    serial,
                    "shell",
                    "am",
                    "instrument",
                    "-w",
                    "-r",
                    "-e",
                    "class",
                    TEST_CLASS,
                    "-e",
                    "sourceBase64",
                    source_base64,
                    "-e",
                    "logicalOrigin",
                    LOGICAL_ORIGIN,
                    "-e",
                    "scenarioId",
                    scenario_id,
                    "-e",
                    "inputBase64",
                    input_base64,
                    INSTRUMENTATION,
                ],
                cwd=root,
                timeout=300,
            )
            if (
                b"OK (" not in instrumentation.stdout
                or b"FAILURES!!!" in instrumentation.stdout
            ):
                raise AndroidOracleRunnerError(
                    "INSTRUMENTATION_FAILED"
                )
            raw_bytes = _run(
                [
                    str(adb),
                    "-s",
                    serial,
                    "exec-out",
                    "run-as",
                    TARGET_PACKAGE,
                    "cat",
                    RAW_DEVICE_PATH,
                ],
                cwd=root,
                timeout=30,
            ).stdout
            source_lab_route_counts = dict(
                server.route_request_counts
            )
        try:
            raw = json.loads(raw_bytes)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise AndroidOracleRunnerError(
                "RAW_ARTIFACT_JSON_INVALID"
            ) from error
        if not isinstance(raw, dict):
            raise AndroidOracleRunnerError("RAW_ARTIFACT_SHAPE_INVALID")
        if (
            scenario_id
            == "sl-source-request-header-cookie-retry-layering-001"
        ):
            raw["source_lab_route_counts"] = source_lab_route_counts
        artifact = normalize_raw_artifact(
            raw,
            bindings,
            scenario_id,
        )
        document = local_run_document(
            artifact,
            bindings,
            emulator_serial=serial,
            scenario_id=scenario_id,
        )
        output_path = _output_path(
            root,
            output,
            scenario_id,
        )
        payload = _canonical(document)
        _atomic_private_write(output_path, payload)
        return {
            "schema_version": 1,
            "authority": "local_unverified",
            "status": "candidate_only",
            "scenario_id": scenario_id,
            "runner_digest": bindings["runner_digest"],
            "artifact_sha256": document["artifact_sha256"],
            "local_run_sha256": _sha256(payload),
            "output": output_path.relative_to(root).as_posix(),
            "case_count": len(expected_cases),
        }
    finally:
        if reverse_port is not None:
            _run(
                [
                    str(adb),
                    "-s",
                    serial,
                    "reverse",
                    "--remove",
                    f"tcp:{reverse_port}",
                ],
                cwd=root,
                timeout=30,
                check=False,
            )
        for package in reversed(installed_packages):
            _run(
                [str(adb), "-s", serial, "uninstall", package],
                cwd=root,
                timeout=60,
                check=False,
            )
        if worktree_registered:
            _git(
                root,
                "worktree",
                "remove",
                "--force",
                str(worktree),
                check=False,
            )
        if temporary_root.name.startswith("legado-android-oracle-"):
            shutil.rmtree(temporary_root, ignore_errors=True)


def doctor(
    root: Path,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    bindings = repository_bindings(root, scenario_id)
    forbidden = {
        "accept",
        "publish",
        "promote",
        "record",
        "update-golden",
    }
    if forbidden.intersection(COMMANDS):
        raise AndroidOracleRunnerError("AUTHORITY_COMMAND_EXPOSED")
    return {
        "schema_version": 1,
        "ok": True,
        "commands": list(COMMANDS),
        "scenario_id": scenario_id,
        "android_git_commit": bindings["android_git_commit"],
        "android_git_tree": bindings["android_git_tree"],
        "runner_digest": bindings["runner_digest"],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="android-oracle-runner")
    commands = parser.add_subparsers(dest="command", required=True)
    doctor_parser = commands.add_parser("doctor")
    doctor_parser.add_argument("--root", type=Path, required=True)
    doctor_parser.add_argument(
        "--scenario",
        default=DEFAULT_SCENARIO_ID,
        choices=sorted(SCENARIO_CONTRACTS),
    )
    run_parser = commands.add_parser("run")
    run_parser.add_argument("--root", type=Path, required=True)
    run_parser.add_argument("--adb", type=Path, required=True)
    run_parser.add_argument("--serial", required=True)
    run_parser.add_argument("--output", type=Path)
    run_parser.add_argument(
        "--scenario",
        default=DEFAULT_SCENARIO_ID,
        choices=sorted(SCENARIO_CONTRACTS),
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "doctor":
        report = doctor(args.root, args.scenario)
    else:
        report = run_characterization(
            args.root,
            adb=args.adb.resolve(strict=True),
            serial=args.serial,
            output=args.output,
            scenario_id=args.scenario,
        )
    sys.stdout.buffer.write(_canonical(report) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AndroidOracleRunnerError as error:
        report = {
            "schema_version": 1,
            "ok": False,
            "reason_code": error.reason_code,
            "detail": error.detail,
        }
        sys.stdout.buffer.write(_canonical(report) + b"\n")
        raise SystemExit(2)
