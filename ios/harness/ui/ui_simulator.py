#!/usr/bin/env python3
"""Run one real XCUITest milestone and retain its native result bundle."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence


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


def ui_test_method(ui: Mapping[str, Any]) -> str:
    value = ui.get("test_method", "testRootTopology")
    if (
        not isinstance(value, str)
        or re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", value) is None
    ):
        raise UIAcceptanceError("UI_TEST_METHOD_INVALID")
    return value


def run(root: Path, task_path: str) -> Mapping[str, Any]:
    task_file = safe_path(root, task_path)
    try:
        task = json.loads(task_file.read_text(encoding="utf-8"))
        ui = task["source"]["ui_acceptance"]
        matrix = ui["simulators"]
        project = safe_path(root, ui["project"])
        scheme = ui["scheme"]
        test_method = ui_test_method(ui)
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise UIAcceptanceError("UI_TASK_INVALID") from error
    if (
        not isinstance(matrix, list)
        or not matrix
        or not isinstance(scheme, str)
        or project.suffix != ".xcodeproj"
    ):
        raise UIAcceptanceError("UI_TASK_INVALID")

    runtime_root = root / RUNTIME / uuid.uuid4().hex
    runtime_root.mkdir(parents=True, exist_ok=False)
    simulator_results = []
    for entry in matrix:
        if not isinstance(entry, dict):
            raise UIAcceptanceError("UI_SIMULATOR_CONTRACT_INVALID")
        udid = ensure_simulator(root, entry)
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
        simulator_results.append(
            {
                "simulator_id": entry["simulator_id"],
                "result_bundle": result_bundle.relative_to(root).as_posix(),
            }
        )

    return {
        "schema_version": 1,
        "scenario_id": ui["scenario_id"],
        "status": "passed",
        "simulators": simulator_results,
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
