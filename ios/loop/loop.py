#!/usr/bin/env python3
"""Minimal Loop v2: one derived task, one event stream, one current projection."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 2
LOOP_ROOT = Path("ios/project/loop")
TASK_PATH = LOOP_ROOT / "task.json"
CURRENT_PATH = LOOP_ROOT / "current.json"
EVENTS_PATH = LOOP_ROOT / "events.jsonl"
RUNTIME_ROOT = Path(".harness-runtime/loop")
CONTROL_PATHS = {
    TASK_PATH.as_posix(),
    CURRENT_PATH.as_posix(),
    EVENTS_PATH.as_posix(),
}


class LoopError(RuntimeError):
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


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def read_json(path: Path) -> Mapping[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise LoopError(f"JSON_INVALID:{path}") from error
    if not isinstance(value, dict):
        raise LoopError(f"JSON_OBJECT_REQUIRED:{path}")
    return value


def write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical(value))


def utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def git(root: Path, *arguments: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise LoopError(f"GIT_FAILED:{' '.join(arguments)}:{result.stderr.strip()}")
    return result.stdout.rstrip()


def repository_root(path: Path) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=path,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise LoopError("NOT_A_GIT_REPOSITORY")
    return Path(result.stdout.strip()).resolve()


def load_events(root: Path) -> list[Mapping[str, Any]]:
    path = root / EVENTS_PATH
    if not path.exists():
        return []
    events: list[Mapping[str, Any]] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as error:
            raise LoopError(f"EVENT_INVALID:{number}") from error
        if (
            not isinstance(event, dict)
            or event.get("schema_version") != SCHEMA_VERSION
            or event.get("sequence") != number
            or not isinstance(event.get("event"), str)
        ):
            raise LoopError(f"EVENT_INVALID:{number}")
        events.append(event)
    return events


def append_event(
    root: Path,
    event: str,
    *,
    task_id: str | None,
    details: Mapping[str, Any] | None = None,
) -> Mapping[str, Any]:
    events = load_events(root)
    record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "sequence": len(events) + 1,
        "at": utc_now(),
        "event": event,
        "task_id": task_id,
    }
    if details:
        record["details"] = dict(details)
    path = root / EVENTS_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("ab") as stream:
        stream.write(canonical(record))
    return record


def completed_task_ids(root: Path) -> set[str]:
    completed = {
        str(event["task_id"])
        for event in load_events(root)
        if event["event"] == "task_completed"
        and isinstance(event.get("task_id"), str)
    }
    for event in load_events(root):
        if event["event"] != "legacy_history_imported":
            continue
        details = event.get("details")
        if not isinstance(details, dict):
            continue
        completed.update(
            value
            for value in details.get("completed_task_ids", [])
            if isinstance(value, str)
        )
    return completed


def characterized_claim_refs(root: Path) -> set[tuple[str, int]]:
    result: set[tuple[str, int]] = set()
    for event in load_events(root):
        details = event.get("details")
        if not isinstance(details, dict):
            continue
        knowledge = details.get("knowledge")
        if not isinstance(knowledge, dict):
            continue
        for reference in knowledge.get("candidate_claim_refs", []):
            if (
                isinstance(reference, dict)
                and isinstance(reference.get("id"), str)
                and isinstance(reference.get("revision"), int)
                and not isinstance(reference.get("revision"), bool)
            ):
                result.add((reference["id"], reference["revision"]))
    return result


def satisfied_dependency_claim_refs(root: Path) -> set[tuple[str, int]]:
    """Claims that may unlock a downstream characterization.

    Runtime behavior still requires an Android characterization event. Static
    declarations explicitly marked as requiring no runtime evidence can be
    consumed directly from the frozen source, while a human-decision claim
    remains blocked until it is published.
    """
    result = characterized_claim_refs(root)
    for _, packet in relative_jsons(
        root,
        "ios/project/business-knowledge/packets/published",
    ):
        for claim in packet.get("claims", []):
            if (
                isinstance(claim, dict)
                and isinstance(claim.get("id"), str)
                and isinstance(claim.get("revision"), int)
                and not isinstance(claim.get("revision"), bool)
            ):
                result.add((claim["id"], claim["revision"]))
    for _, packet in relative_jsons(
        root,
        "ios/project/business-knowledge/packets/proposals",
    ):
        if packet.get("status") != "candidate":
            continue
        for claim in packet.get("claims", []):
            support = claim.get("support") if isinstance(claim, dict) else None
            if (
                isinstance(support, dict)
                and support.get("state") == "candidate_source_anchored"
                and support.get("runtime_requirement") == "none"
                and isinstance(claim.get("id"), str)
                and isinstance(claim.get("revision"), int)
                and not isinstance(claim.get("revision"), bool)
            ):
                result.add((claim["id"], claim["revision"]))
    return result


def relative_jsons(root: Path, relative: str) -> Iterable[tuple[str, Mapping[str, Any]]]:
    directory = root / relative
    if not directory.exists():
        return
    for path in sorted(directory.rglob("*.json")):
        yield path.relative_to(root).as_posix(), read_json(path)


def migration_for(
    root: Path,
    requirement_refs: Sequence[str],
    target: str,
) -> Mapping[str, Any] | None:
    requirement_ids = {value.split("@", 1)[0] for value in requirement_refs}
    scored: list[tuple[int, Mapping[str, Any]]] = []
    target_tokens = set(target.split("-"))
    for _, intent in relative_jsons(root, "ios/project/migration-intents"):
        binding = intent.get("requirement_binding")
        requirement_id = binding.get("id") if isinstance(binding, dict) else None
        if requirement_id not in requirement_ids:
            continue
        score = len(target_tokens & set(str(intent.get("id", "")).split("-")))
        scored.append((score, intent))
    if not scored:
        return None
    return sorted(
        scored,
        key=lambda item: (-item[0], str(item[1].get("id", ""))),
    )[0][1]


def driver_for(
    root: Path,
    claim_refs: Sequence[Mapping[str, Any]],
) -> tuple[str, Mapping[str, Any]] | None:
    claims = {
        (value.get("id"), value.get("revision"))
        for value in claim_refs
        if isinstance(value, dict)
    }
    candidates = []
    for path, driver in relative_jsons(
        root,
        "ios/project/business-knowledge/drivers/published",
    ):
        refs = {
            (value.get("id"), value.get("revision"))
            for value in driver.get("claim_refs", [])
            if isinstance(value, dict)
        }
        overlap = len(claims & refs)
        if overlap:
            candidates.append((overlap, path, driver))
    if not candidates:
        return None
    _, path, driver = sorted(
        candidates,
        key=lambda item: (-item[0], item[1]),
    )[0]
    return path, driver


def owner_contract(target: str) -> Mapping[str, Any]:
    if "SOURCE-RUNTIME" in target:
        return {
            "owner": "SourceRuntime",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-005",
                "ARCH-008",
                "ARCH-011",
                "ARCH-017",
                "ARCH-018",
            ],
            "allowed_paths": [
                "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
                "ios/Packages/LegadoKit/Tests/SourceRuntimeTests/**",
                "ios/Packages/LegadoKit/Sources/ConformanceCLI/**",
                "ios/Packages/LegadoKit/Tests/ConformanceCLITests/**",
                "ios/Packages/LegadoKit/Sources/TestSupport/FixtureModel.swift",
            ],
        }
    raise LoopError(f"OWNER_NOT_MAPPED:{target}")


def planned_deliveries(root: Path) -> list[Mapping[str, Any]]:
    completed = completed_task_ids(root)
    deliveries: dict[str, dict[str, Any]] = {}
    for ledger_path, ledger in relative_jsons(
        root,
        "ios/project/business-knowledge/coverage",
    ):
        if ledger.get("status") != "current":
            continue
        for entry in ledger.get("entries", []):
            if not isinstance(entry, dict):
                continue
            delivery = entry.get("delivery")
            if not isinstance(delivery, dict) or delivery.get("state") != "planned":
                continue
            for target in delivery.get("work_item_refs", []):
                if not isinstance(target, str) or target in completed:
                    continue
                candidate = deliveries.setdefault(
                    target,
                    {
                        "target": target,
                        "ledger_path": ledger_path,
                        "ledger": ledger,
                        "entries": [],
                    },
                )
                candidate["entries"].append(entry)
    return [deliveries[key] for key in sorted(deliveries)]


def requirement_refs_for_claim(
    root: Path,
    packet: Mapping[str, Any],
    claim: Mapping[str, Any],
) -> list[str]:
    packet_commit = packet.get("baseline", {}).get("android_commit")
    claim_paths = {
        value.get("path")
        for value in claim.get("support", {}).get("source_anchors", [])
        if isinstance(value, dict) and isinstance(value.get("path"), str)
    }
    matches: list[tuple[str, Mapping[str, Any]]] = []
    for path, intent in relative_jsons(root, "ios/project/migration-intents"):
        baseline = intent.get("android_baseline")
        anchors = intent.get("source_anchors")
        binding = intent.get("requirement_binding")
        if (
            not isinstance(baseline, dict)
            or baseline.get("commit") != packet_commit
            or not isinstance(anchors, list)
            or not isinstance(binding, dict)
        ):
            continue
        intent_paths = {
            value.get("path")
            for value in anchors
            if isinstance(value, dict) and isinstance(value.get("path"), str)
        }
        if claim_paths and not (claim_paths & intent_paths):
            continue
        matches.append((path, binding))
    if not matches:
        return []
    _, binding = sorted(matches, key=lambda value: value[0])[0]
    identifier = binding.get("id")
    revision = binding.get("revision")
    clauses = binding.get("clauses")
    if (
        not isinstance(identifier, str)
        or not isinstance(revision, int)
        or isinstance(revision, bool)
        or not isinstance(clauses, list)
        or not clauses
        or any(not isinstance(value, str) for value in clauses)
    ):
        return []
    return [
        f"{identifier}@{revision}#{clause}"
        for clause in sorted(set(clauses))
    ]


def pending_characterizations(root: Path) -> list[Mapping[str, Any]]:
    completed = completed_task_ids(root)
    characterized = characterized_claim_refs(root)
    satisfied_dependencies = satisfied_dependency_claim_refs(root)
    candidates: list[tuple[int, int, str, Mapping[str, Any]]] = []
    for packet_path, packet in relative_jsons(
        root,
        "ios/project/business-knowledge/packets/proposals",
    ):
        if packet.get("status") != "candidate":
            continue
        for claim in packet.get("claims", []):
            if not isinstance(claim, dict):
                continue
            claim_id = claim.get("id")
            revision = claim.get("revision")
            support = claim.get("support")
            if (
                not isinstance(claim_id, str)
                or not isinstance(revision, int)
                or isinstance(revision, bool)
                or not isinstance(support, dict)
                or support.get("runtime_requirement")
                != "android_characterization"
                or support.get("state") != "candidate_source_anchored"
                or (claim_id, revision) in characterized
            ):
                continue
            dependencies = {
                (value.get("id"), value.get("revision"))
                for value in claim.get("depends_on", [])
                if isinstance(value, dict)
            }
            if not dependencies.issubset(satisfied_dependencies):
                continue
            requirements = requirement_refs_for_claim(root, packet, claim)
            if not requirements:
                continue
            semantic_key = str(claim.get("semantic_key") or claim_id)
            task_id = characterization_task_id(semantic_key)
            if task_id in completed:
                continue
            value = {
                "packet_path": packet_path,
                "packet": packet,
                "claim": claim,
                "requirements": requirements,
                "task_id": task_id,
            }
            candidates.append(
                (
                    len(claim.get("subject_keys", [])),
                    len(support.get("source_anchors", [])),
                    semantic_key,
                    value,
                )
            )
    return [value for _, _, _, value in sorted(candidates, key=lambda item: item[:3])]


def characterization_task_id(semantic_key: str) -> str:
    slug = re.sub(r"[^A-Z0-9]+", "-", semantic_key.upper()).strip("-")
    return f"IOS-CHARACTERIZE-{slug}-001"


def characterization_fixture_id(semantic_key: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", semantic_key.lower()).strip("-")
    return f"sl-{slug}-001"


def build_task(root: Path, delivery: Mapping[str, Any]) -> Mapping[str, Any]:
    target = str(delivery["target"])
    ledger = delivery["ledger"]
    entries = delivery["entries"]
    requirement_refs = sorted(
        {
            value
            for entry in entries
            for value in entry["delivery"].get("requirement_refs", [])
            if isinstance(value, str)
        }
    )
    evidence_refs = sorted(
        {
            value
            for entry in entries
            for value in entry.get("validation", {}).get("evidence_refs", [])
            if isinstance(value, str)
        }
    )
    claim_refs = [
        entry["claim_ref"]
        for entry in entries
        if isinstance(entry.get("claim_ref"), dict)
    ]
    architecture = owner_contract(target)
    migration = migration_for(root, requirement_refs, target)
    driver_match = driver_for(root, claim_refs)
    fixture_id = None
    golden_path = next(
        (
            value.split("#", 1)[0]
            for value in evidence_refs
            if "/goldens/android-legado-v1/" in value
        ),
        None,
    )
    if golden_path:
        fixture_id = read_json(root / golden_path).get("fixture_id")
    driver_ref = None
    title = target
    if driver_match:
        driver_path, driver = driver_match
        driver_ref = {
            "id": driver.get("id"),
            "revision": driver.get("revision"),
            "path": driver_path,
        }
        title = str(driver.get("title") or target)
    source_anchors = (
        migration.get("source_anchors", [])
        if isinstance(migration, dict)
        else []
    )
    task = {
        "schema_version": SCHEMA_VERSION,
        "id": target,
        "kind": "delivery",
        "title": title,
        "status": "ready",
        "priority": 100,
        "goal": (
            "按照冻结 Android 运行结果，在独立 SourceRuntime 中实现该书源能力；"
            "源码对齐为主，结构化测试为辅。"
        ),
        "source": {
            "android_baseline": (
                migration.get("android_baseline")
                if isinstance(migration, dict)
                else None
            ),
            "anchors": source_anchors,
            "fixture_id": fixture_id,
            "android_golden": golden_path,
            "knowledge": {
                "coverage": delivery["ledger_path"],
                "packets": ledger.get("packet_refs", []),
                "driver": driver_ref,
                "claims": claim_refs,
            },
        },
        "requirements": requirement_refs,
        "architecture": {
            "owner": architecture["owner"],
            "refs": architecture["architecture_refs"],
            "rule": (
                "SourceRuntime 生成确定性 RequestPlan；Transport 只执行，"
                "UI/Domain 不解释请求语义。"
            ),
        },
        "scope": {
            "allowed_paths": architecture["allowed_paths"],
            "forbidden": [
                "Android golden",
                "accepted Requirement",
                "架构依赖边",
                "三方依赖",
            ],
        },
        "acceptance": {
            "commands": [
                {
                    "id": "package-contract",
                    "argv": [
                        "python3",
                        "-B",
                        "ios/harness/probes/package_contract.py",
                        "--root",
                        ".",
                    ],
                    "timeout_seconds": 120,
                },
                {
                    "id": "source-runtime-tests",
                    "argv": [
                        "swift",
                        "test",
                        "--package-path",
                        "ios/Packages/LegadoKit",
                        "--disable-automatic-resolution",
                        "--filter",
                        "SourceRuntimeTests",
                    ],
                    "timeout_seconds": 300,
                },
                {
                    "id": "structured-source-acceptance",
                    "argv": [
                        "swift",
                        "run",
                        "--package-path",
                        "ios/Packages/LegadoKit",
                        "--disable-automatic-resolution",
                        "ConformanceCLI",
                        "run-task",
                        "ios/project/loop/task.json",
                    ],
                    "timeout_seconds": 300,
                },
            ],
            "structured_output": {
                "fixture_id": fixture_id,
                "expected": golden_path,
                "required_fields": [
                    "android_expected",
                    "ios_actual",
                    "canonical_request_plan",
                    "first_divergence",
                ],
            },
        },
        "knowledge_updates": {
            "required_on_completion": [
                "summary",
                "current_status",
                "architecture_change",
                "pitfalls",
                "next_step",
            ]
        },
    }
    return task


def build_characterization_task(
    root: Path,
    candidate: Mapping[str, Any],
) -> Mapping[str, Any]:
    packet = candidate["packet"]
    claim = candidate["claim"]
    semantic_key = str(claim["semantic_key"])
    fixture_id = characterization_fixture_id(semantic_key)
    golden_path = (
        f"ios/harness/goldens/android-legado-v1/{fixture_id}.json"
    )
    creator = packet.get("created_by")
    driver_ref = None
    claim_key = (claim.get("id"), claim.get("revision"))
    for path, driver in relative_jsons(
        root,
        "ios/project/business-knowledge/drivers/proposals",
    ):
        refs = {
            (value.get("id"), value.get("revision"))
            for value in driver.get("claim_refs", [])
            if isinstance(value, dict)
        }
        if driver.get("created_by") == creator and claim_key in refs:
            driver_ref = {
                "id": driver.get("id"),
                "revision": driver.get("revision"),
                "path": path,
            }
            break
    return {
        "schema_version": SCHEMA_VERSION,
        "id": candidate["task_id"],
        "kind": "characterization",
        "title": str(claim.get("topic") or semantic_key),
        "status": "ready",
        "priority": 100,
        "goal": (
            "从冻结 Android 源码声明出发扩展 SourceLab 场景，"
            "由真实 Android runner 产出结构化 Golden，并发布对应业务知识与"
            "Coverage；测试只验证权威链，不能替代源码语义或手写 expected。"
        ),
        "source": {
            "android_baseline": packet.get("baseline"),
            "anchors": claim.get("support", {}).get("source_anchors", []),
            "fixture_id": fixture_id,
            "android_golden": golden_path,
            "knowledge": {
                "packet": {
                    "id": packet.get("id"),
                    "revision": packet.get("revision"),
                    "path": candidate["packet_path"],
                },
                "candidate_claim": {
                    "id": claim.get("id"),
                    "revision": claim.get("revision"),
                    "semantic_key": semantic_key,
                    "statement": claim.get("statement"),
                },
                "driver": driver_ref,
            },
        },
        "requirements": candidate["requirements"],
        "architecture": {
            "owner": "SourceRuntime",
            "refs": ["ARCH-001", "ARCH-005", "ARCH-014", "ARCH-017"],
            "rule": (
                "先固定 Android 可观察结果，再扩展独立 SourceRuntime；"
                "SourceLab 与 Golden 不进入 UI/Domain。"
            ),
        },
        "scope": {
            "allowed_paths": [
                f"ios/harness/fixtures/source-lab/{fixture_id}/**",
                "ios/harness/fixtures/manifest.json",
                "ios/harness/source-lab/manifest.json",
                "ios/harness/source-lab/coverage-policy-v1.json",
                "ios/harness/oracle/request-registry.json",
                "ios/harness/oracle/scenario_selector.py",
                "ios/harness/oracle/android-runner/**",
                "ios/harness/tests/test_android_oracle_runner.py",
                "ios/harness/source-lab/source_lab.py",
                "ios/harness/source-lab/tests/test_source_lab.py",
                ".github/workflows/android-oracle-attestation.yml",
                golden_path,
                "ios/harness/goldens/manifest.json",
                "ios/harness/goldens/releases/**",
                "ios/project/external-execution-receipts/**",
                "ios/project/business-knowledge/packets/proposals/**",
                "ios/project/business-knowledge/packets/published/**",
                "ios/project/business-knowledge/drivers/proposals/**",
                "ios/project/business-knowledge/drivers/published/**",
                "ios/project/business-knowledge/coverage/**",
                "ios/project/business-knowledge/releases/**",
                "ios/project/business-knowledge/catalog.json",
            ],
            "forbidden": [
                "手写 Android expected",
                "iOS 产品实现",
                "accepted Requirement",
                "架构依赖边",
                "三方依赖",
            ],
        },
        "acceptance": {
            "commands": [
                {
                    "id": "source-lab-contract",
                    "argv": [
                        "python3",
                        "-B",
                        "ios/harness/source-lab/source_lab.py",
                        "doctor",
                        "--root",
                        ".",
                    ],
                    "timeout_seconds": 120,
                },
                {
                    "id": "oracle-contract-tests",
                    "argv": [
                        "python3",
                        "-B",
                        "-m",
                        "unittest",
                        "ios.harness.tests.test_oracle_control",
                        "ios.harness.tests.test_oracle_ci_proposal",
                        "ios.harness.tests.test_oracle_trusted_import",
                    ],
                    "timeout_seconds": 180,
                },
                {
                    "id": "android-golden-contract",
                    "argv": [
                        "python3",
                        "-B",
                        "-m",
                        "unittest",
                        "ios.harness.tests.test_android_golden_publisher",
                    ],
                    "timeout_seconds": 300,
                },
                {
                    "id": "business-knowledge-contract",
                    "argv": [
                        "python3",
                        "-B",
                        "ios/harness/business-knowledge/business_knowledge.py",
                        "doctor",
                        "--root",
                        ".",
                    ],
                    "timeout_seconds": 120,
                },
            ],
            "structured_output": {
                "fixture_id": fixture_id,
                "expected": golden_path,
                "required_fields": [
                    "android_expected",
                    "source_lab_transcript",
                    "oracle_bindings",
                    "golden_receipt",
                ],
            },
        },
        "knowledge_updates": {
            "candidate_claim_refs": [
                {"id": claim.get("id"), "revision": claim.get("revision")}
            ],
            "required_on_completion": [
                "summary",
                "current_status",
                "architecture_change",
                "pitfalls",
                "next_step",
            ],
        },
    }


def next_task(root: Path) -> Mapping[str, Any] | None:
    deliveries = planned_deliveries(root)
    if deliveries:
        return build_task(root, deliveries[0])
    characterizations = pending_characterizations(root)
    if characterizations:
        return build_characterization_task(root, characterizations[0])
    return None


def initial_current() -> Mapping[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "idle",
        "active_task": None,
        "attempt": 0,
        "verification": None,
        "last_completed": None,
    }


def current(root: Path) -> Mapping[str, Any]:
    path = root / CURRENT_PATH
    return read_json(path) if path.exists() else initial_current()


def validate_task(root: Path, task: Mapping[str, Any]) -> None:
    if (
        task.get("schema_version") != SCHEMA_VERSION
        or not isinstance(task.get("id"), str)
        or task.get("kind") not in {"delivery", "characterization"}
        or task.get("status") not in {"ready", "in_progress"}
        or not isinstance(task.get("requirements"), list)
        or not task["requirements"]
    ):
        raise LoopError("TASK_INVALID")
    for reference in task["requirements"]:
        requirement_id = str(reference).split("@", 1)[0]
        path = (
            root
            / "ios/project/requirements/accepted"
            / f"{requirement_id}.json"
        )
        if not path.is_file():
            raise LoopError(f"REQUIREMENT_MISSING:{reference}")
    source = task.get("source")
    if not isinstance(source, dict):
        raise LoopError("TASK_SOURCE_INVALID")
    golden = source.get("android_golden")
    if not isinstance(golden, str):
        raise LoopError("TASK_SOURCE_MISSING:android_golden")
    if task.get("kind") == "delivery" and not (root / golden).is_file():
        raise LoopError("TASK_SOURCE_MISSING:android_golden")


def doctor(root: Path) -> Mapping[str, Any]:
    state = current(root)
    events = load_events(root)
    task_path = root / TASK_PATH
    active = state.get("active_task")
    if state.get("schema_version") != SCHEMA_VERSION:
        raise LoopError("CURRENT_INVALID")
    if state.get("status") == "idle":
        if active is not None or task_path.exists():
            raise LoopError("IDLE_PROJECTION_DRIFT")
    elif state.get("status") in {"running", "verified"}:
        if not isinstance(active, str) or not task_path.is_file():
            raise LoopError("ACTIVE_TASK_MISSING")
        task = read_json(task_path)
        validate_task(root, task)
        if task.get("id") != active:
            raise LoopError("ACTIVE_TASK_ID_DRIFT")
    else:
        raise LoopError("CURRENT_STATUS_INVALID")
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "ok",
        "current": state,
        "event_count": len(events),
    }


def start(root: Path) -> Mapping[str, Any]:
    doctor(root)
    state = current(root)
    if state["status"] != "idle":
        raise LoopError(f"TASK_ALREADY_ACTIVE:{state['active_task']}")
    task = next_task(root)
    if task is None:
        raise LoopError("QUEUE_EMPTY")
    task = dict(task)
    task["status"] = "in_progress"
    task["base_commit"] = git(root, "rev-parse", "HEAD")
    validate_task(root, task)
    write_json(root / TASK_PATH, task)
    append_event(
        root,
        "task_started",
        task_id=str(task["id"]),
        details={"base_commit": task["base_commit"]},
    )
    state = {
        "schema_version": SCHEMA_VERSION,
        "status": "running",
        "active_task": task["id"],
        "attempt": 0,
        "verification": None,
        "last_completed": state.get("last_completed"),
    }
    write_json(root / CURRENT_PATH, state)
    return task


def changed_paths(root: Path, base_commit: str) -> list[str]:
    paths = set(
        filter(
            None,
            git(
                root,
                "diff",
                "--name-only",
                "--diff-filter=ACMRDTUXB",
                base_commit,
                "--",
            ).splitlines(),
        )
    )
    porcelain = git(root, "status", "--porcelain=v1", "--untracked-files=all")
    for line in porcelain.splitlines():
        if len(line) >= 4:
            path = line[3:]
            if " -> " in path:
                path = path.split(" -> ", 1)[1]
            paths.add(path)
    return sorted(paths)


def path_allowed(path: str, patterns: Sequence[str]) -> bool:
    if path in CONTROL_PATHS or path.startswith(".harness-runtime/"):
        return True
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)


def workspace_digest(root: Path, paths: Sequence[str]) -> str:
    inventory = []
    for relative in sorted(
        path
        for path in paths
        if path not in CONTROL_PATHS
        and not path.startswith(".harness-runtime/")
    ):
        path = root / relative
        if path.is_symlink():
            value = {
                "path": relative,
                "kind": "symlink",
                "target": os.readlink(path),
            }
        elif path.is_file():
            value = {
                "path": relative,
                "kind": "file",
                "sha256": digest(path.read_bytes()),
            }
        elif path.exists():
            value = {"path": relative, "kind": "other"}
        else:
            value = {"path": relative, "kind": "deleted"}
        inventory.append(value)
    return digest(canonical(inventory))


def run_acceptance(
    root: Path,
    task: Mapping[str, Any],
    attempt: int,
    paths: Sequence[str],
) -> tuple[bool, list[Mapping[str, Any]], Path]:
    runtime = root / RUNTIME_ROOT / str(task["id"]) / f"attempt-{attempt}"
    runtime.mkdir(parents=True, exist_ok=True)
    results = []
    passed = True
    for check in task["acceptance"]["commands"]:
        argv = check.get("argv")
        if (
            not isinstance(argv, list)
            or not argv
            or not all(isinstance(value, str) for value in argv)
        ):
            raise LoopError(f"ACCEPTANCE_COMMAND_INVALID:{check.get('id')}")
        try:
            result = subprocess.run(
                argv,
                cwd=root,
                capture_output=True,
                timeout=int(check.get("timeout_seconds", 300)),
                check=False,
            )
            stdout = result.stdout
            stderr = result.stderr
            exit_code = result.returncode
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or b""
            stderr = error.stderr or b""
            exit_code = 124
        check_id = str(check.get("id"))
        (runtime / f"{check_id}.stdout").write_bytes(stdout)
        (runtime / f"{check_id}.stderr").write_bytes(stderr)
        result_record = {
            "id": check_id,
            "exit_code": exit_code,
            "stdout_sha256": digest(stdout),
            "stderr_sha256": digest(stderr),
        }
        results.append(result_record)
        if exit_code != 0:
            passed = False
            break
    report = {
        "schema_version": SCHEMA_VERSION,
        "task_id": task["id"],
        "attempt": attempt,
        "passed": passed,
        "head_commit": git(root, "rev-parse", "HEAD"),
        "workspace_sha256": workspace_digest(root, paths),
        "changed_paths": list(paths),
        "checks": results,
    }
    write_json(runtime / "verification.json", report)
    return passed, results, runtime.relative_to(root)


def verify(root: Path) -> Mapping[str, Any]:
    doctor(root)
    state = current(root)
    if state["status"] not in {"running", "verified"}:
        raise LoopError("NO_ACTIVE_TASK")
    task = read_json(root / TASK_PATH)
    paths = changed_paths(root, str(task["base_commit"]))
    allowed = task["scope"]["allowed_paths"]
    violations = [
        path for path in paths if not path_allowed(path, allowed)
    ]
    if violations:
        raise LoopError("SCOPE_VIOLATION:" + ",".join(violations))
    attempt = int(state.get("attempt", 0)) + 1
    passed, checks, runtime = run_acceptance(root, task, attempt, paths)
    head = git(root, "rev-parse", "HEAD")
    verification = {
        "passed": passed,
        "attempt": attempt,
        "head_commit": head,
        "workspace_sha256": workspace_digest(root, paths),
        "changed_paths": paths,
        "runtime": runtime.as_posix(),
        "checks": checks,
    }
    append_event(
        root,
        "verification_passed" if passed else "verification_failed",
        task_id=str(task["id"]),
        details=verification,
    )
    next_state = dict(state)
    next_state["status"] = "verified" if passed else "running"
    next_state["attempt"] = attempt
    next_state["verification"] = verification
    write_json(root / CURRENT_PATH, next_state)
    return verification


def complete(
    root: Path,
    *,
    summary: str,
    pitfall: Sequence[str],
    next_step: str,
) -> Mapping[str, Any]:
    doctor(root)
    state = current(root)
    verification = state.get("verification")
    if (
        state.get("status") != "verified"
        or not isinstance(verification, dict)
        or verification.get("passed") is not True
    ):
        raise LoopError("TASK_NOT_VERIFIED")
    task = read_json(root / TASK_PATH)
    paths = changed_paths(root, str(task["base_commit"]))
    if workspace_digest(root, paths) != verification.get("workspace_sha256"):
        raise LoopError("TASK_CHANGED_AFTER_VERIFY")
    details = {
        "summary": summary,
        "current_status": "completed",
        "architecture_change": "none",
        "pitfalls": list(pitfall),
        "next_step": next_step,
        "verification": {
            "attempt": verification["attempt"],
            "head_commit": verification["head_commit"],
            "workspace_sha256": verification["workspace_sha256"],
            "runtime": verification["runtime"],
        },
    }
    knowledge_updates = task.get("knowledge_updates")
    if isinstance(knowledge_updates, dict):
        candidate_refs = knowledge_updates.get("candidate_claim_refs")
        if isinstance(candidate_refs, list) and candidate_refs:
            details["knowledge"] = {
                "candidate_claim_refs": candidate_refs,
            }
    event = append_event(
        root,
        "task_completed",
        task_id=str(task["id"]),
        details=details,
    )
    (root / TASK_PATH).unlink()
    write_json(
        root / CURRENT_PATH,
        {
            "schema_version": SCHEMA_VERSION,
            "status": "idle",
            "active_task": None,
            "attempt": 0,
            "verification": None,
            "last_completed": {
                "task_id": task["id"],
                "sequence": event["sequence"],
                "at": event["at"],
            },
        },
    )
    return event


def output(value: Any) -> None:
    sys.stdout.buffer.write(canonical(value))


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor")
    subparsers.add_parser("status")
    subparsers.add_parser("next")
    subparsers.add_parser("start")
    subparsers.add_parser("verify")
    complete_parser = subparsers.add_parser("complete")
    complete_parser.add_argument("--summary", required=True)
    complete_parser.add_argument("--pitfall", action="append", default=[])
    complete_parser.add_argument("--next-step", required=True)
    args = parser.parse_args(argv)
    try:
        root = repository_root(args.root.resolve())
        if args.command == "doctor":
            value = doctor(root)
        elif args.command == "status":
            value = current(root)
        elif args.command == "next":
            value = next_task(root) or {
                "schema_version": SCHEMA_VERSION,
                "status": "queue_empty",
            }
        elif args.command == "start":
            value = start(root)
        elif args.command == "verify":
            value = verify(root)
        elif args.command == "complete":
            value = complete(
                root,
                summary=args.summary,
                pitfall=args.pitfall,
                next_step=args.next_step,
            )
        else:
            raise AssertionError(args.command)
        output(value)
        return 0
    except LoopError as error:
        output(
            {
                "schema_version": SCHEMA_VERSION,
                "status": "error",
                "reason": str(error),
            }
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
