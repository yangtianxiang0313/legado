#!/usr/bin/env python3
"""Run deterministic XCUITest scenarios and compare structured UI output."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence


MARKER = "LEGADO_UI_OBSERVED_BASE64:"
RUNTIME = Path(".harness-runtime/ui")


class UIAcceptanceError(RuntimeError):
    pass


def canonical(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def safe_path(root: Path, relative: str) -> Path:
    path = PurePosixPath(relative)
    if (
        not relative
        or path.is_absolute()
        or path.as_posix() != relative
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise UIAcceptanceError("UI_PATH_INVALID")
    resolved = (root / relative).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise UIAcceptanceError("UI_PATH_ESCAPES_ROOT") from error
    return resolved


def command(
    argv: Sequence[str],
    *,
    cwd: Path,
    timeout: int = 600,
    environment: Mapping[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
            env=dict(environment) if environment is not None else None,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise UIAcceptanceError(f"UI_COMMAND_FAILED:{argv[0]}") from error


def json_command(argv: Sequence[str], *, cwd: Path) -> Any:
    result = command(argv, cwd=cwd, timeout=120)
    if result.returncode != 0:
        raise UIAcceptanceError(f"UI_COMMAND_FAILED:{argv[0]}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise UIAcceptanceError(f"UI_COMMAND_JSON_INVALID:{argv[0]}") from error


def ensure_simulator(root: Path, entry: Mapping[str, Any]) -> str:
    required = ("simulator_id", "name", "device_type", "runtime")
    if any(not isinstance(entry.get(key), str) for key in required):
        raise UIAcceptanceError("UI_SIMULATOR_CONTRACT_INVALID")
    devices = json_command(["xcrun", "simctl", "list", "devices", "--json"], cwd=root)
    runtime_key = entry["runtime"]
    candidates = devices.get("devices", {}).get(runtime_key, [])
    for device in candidates:
        if (
            isinstance(device, dict)
            and device.get("name") == entry["name"]
            and device.get("isAvailable", True)
            and isinstance(device.get("udid"), str)
        ):
            return device["udid"]
    result = command(
        [
            "xcrun",
            "simctl",
            "create",
            entry["name"],
            entry["device_type"],
            entry["runtime"],
        ],
        cwd=root,
        timeout=120,
    )
    udid = result.stdout.strip()
    if result.returncode != 0 or not udid:
        raise UIAcceptanceError("UI_SIMULATOR_CREATE_FAILED")
    return udid


def observed_payload(output: str) -> Mapping[str, Any]:
    markers = [
        line.split(MARKER, 1)[1].strip()
        for line in output.splitlines()
        if MARKER in line
    ]
    if len(markers) != 1:
        raise UIAcceptanceError("UI_OBSERVED_MARKER_INVALID")
    try:
        payload = base64.b64decode(markers[0], validate=True)
        value = json.loads(payload)
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise UIAcceptanceError("UI_OBSERVED_INVALID") from error
    if not isinstance(value, dict):
        raise UIAcceptanceError("UI_OBSERVED_INVALID")
    return value


def escaped(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def first_difference(expected: Any, actual: Any, pointer: str = "") -> str | None:
    if type(expected) is not type(actual):
        return pointer or "/"
    if isinstance(expected, dict):
        for key in sorted(set(expected) | set(actual)):
            child = f"{pointer}/{escaped(key)}"
            if key not in expected or key not in actual:
                return child
            difference = first_difference(expected[key], actual[key], child)
            if difference is not None:
                return difference
        return None
    if isinstance(expected, list):
        for index in range(max(len(expected), len(actual))):
            child = f"{pointer}/{index}"
            if index >= len(expected) or index >= len(actual):
                return child
            difference = first_difference(expected[index], actual[index], child)
            if difference is not None:
                return difference
        return None
    return None if expected == actual else (pointer or "/")


def ui_test_method(ui: Mapping[str, Any]) -> str:
    value = ui.get("test_method", "testRootTopology")
    if (
        not isinstance(value, str)
        or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", value) is None
    ):
        raise UIAcceptanceError("UI_TEST_METHOD_INVALID")
    return value


def expected_for_simulators(
    expected: Mapping[str, Any],
    simulator_ids: list[str],
) -> Mapping[str, Any]:
    expected_simulators = expected.get("simulators")
    if not isinstance(expected_simulators, list):
        raise UIAcceptanceError("UI_EXPECTED_SIMULATORS_INVALID")
    selected = [
        value
        for value in expected_simulators
        if (
            isinstance(value, dict)
            and value.get("simulator_id") in simulator_ids
        )
    ]
    selected_ids = {
        value.get("simulator_id")
        for value in selected
    }
    if selected_ids != set(simulator_ids) or len(selected) != len(simulator_ids):
        raise UIAcceptanceError("UI_EXPECTED_SIMULATOR_MISSING")
    return {
        **expected,
        "simulators": sorted(
            selected,
            key=lambda value: str(value.get("simulator_id")),
        ),
    }


def run(root: Path, task_path: str) -> Mapping[str, Any]:
    task_file = safe_path(root, task_path)
    try:
        task = json.loads(task_file.read_text(encoding="utf-8"))
        ui = task["source"]["ui_acceptance"]
        expected_path = safe_path(root, ui["expected"])
        expected = json.loads(expected_path.read_text(encoding="utf-8"))
        matrix = ui["simulators"]
        project = safe_path(root, ui["project"])
        scheme = ui["scheme"]
        test_method = ui_test_method(ui)
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise UIAcceptanceError("UI_TASK_INVALID") from error
    if (
        not isinstance(expected, dict)
        or not isinstance(matrix, list)
        or not matrix
        or not isinstance(scheme, str)
        or project.suffix != ".xcodeproj"
    ):
        raise UIAcceptanceError("UI_TASK_INVALID")

    runtime_root = root / RUNTIME / uuid.uuid4().hex
    runtime_root.mkdir(parents=True, exist_ok=False)
    observations = []
    simulator_ids = []
    for entry in matrix:
        if not isinstance(entry, dict):
            raise UIAcceptanceError("UI_SIMULATOR_CONTRACT_INVALID")
        udid = ensure_simulator(root, entry)
        simulator_ids.append(entry["simulator_id"])
        command(["xcrun", "simctl", "boot", udid], cwd=root, timeout=120)
        boot = command(
            ["xcrun", "simctl", "bootstatus", udid, "-b"],
            cwd=root,
            timeout=180,
        )
        if boot.returncode != 0:
            raise UIAcceptanceError("UI_SIMULATOR_BOOT_FAILED")
        result_bundle = runtime_root / f"{entry['simulator_id']}.xcresult"
        environment = dict(os.environ)
        environment["LEGADO_SIMULATOR_ID"] = entry["simulator_id"]
        environment["LEGADO_EXPECTED_PROJECTION"] = entry["projection"]
        result = command(
            [
                "xcodebuild",
                "test",
                "-project",
                str(project),
                "-scheme",
                scheme,
                "-destination",
                f"id={udid}",
                "-derivedDataPath",
                str(root / RUNTIME / "DerivedData"),
                "-resultBundlePath",
                str(result_bundle),
                "-parallel-testing-enabled",
                "NO",
                (
                    "-only-testing:LegadoAppUITests/LegadoAppUITests/"
                    f"{test_method}"
                ),
            ],
            cwd=root,
            timeout=900,
            environment=environment,
        )
        (runtime_root / f"{entry['simulator_id']}.log").write_text(
            result.stdout,
            encoding="utf-8",
        )
        if result.returncode != 0:
            raise UIAcceptanceError(
                f"UI_XCODEBUILD_FAILED:{entry['simulator_id']}"
            )
        observation = observed_payload(result.stdout)
        if observation.get("simulator_id") != entry["simulator_id"]:
            raise UIAcceptanceError("UI_SIMULATOR_ID_MISMATCH")
        observations.append(observation)

    actual = {
        "schema_version": 1,
        "scenario_id": ui["scenario_id"],
        "profile": ui["profile"],
        "simulators": sorted(
            observations,
            key=lambda value: str(value.get("simulator_id")),
        ),
    }
    selected_expected = expected_for_simulators(expected, simulator_ids)
    difference = first_difference(selected_expected, actual)
    return {
        "schema_version": 1,
        "scenario_id": ui["scenario_id"],
        "status": "equal" if difference is None else "different",
        "expected": selected_expected,
        "actual": actual,
        "simulator_matrix": sorted(simulator_ids),
        "first_divergence": difference,
        "runtime": runtime_root.relative_to(root).as_posix(),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["verify"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--task", required=True)
    args = parser.parse_args(argv)
    try:
        result = run(Path(args.root).resolve(), args.task)
    except UIAcceptanceError as error:
        print(str(error), file=sys.stderr)
        return 1
    sys.stdout.buffer.write(canonical(result))
    return 0 if result["status"] == "equal" else 5


if __name__ == "__main__":
    raise SystemExit(main())
