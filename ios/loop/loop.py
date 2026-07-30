#!/usr/bin/env python3
"""Minimal Loop v2: one derived task, one event stream, one current projection."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = 2
LOOP_ROOT = Path("ios/project/loop")
TASK_PATH = LOOP_ROOT / "task.json"
CURRENT_PATH = LOOP_ROOT / "current.json"
EVENTS_PATH = LOOP_ROOT / "events.jsonl"
PRIORITY_PATH = Path("ios/project/migration-priorities/active.json")
RUNTIME_ROOT = Path(".harness-runtime/loop")
LOCK_PATH = RUNTIME_ROOT / "loop.lock"
CONTROL_PATHS = {
    TASK_PATH.as_posix(),
    CURRENT_PATH.as_posix(),
    EVENTS_PATH.as_posix(),
}
ANDROID_CHARACTERIZATION_REQUIREMENT_ID = (
    "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001"
)
ANDROID_CHARACTERIZATION_REQUIREMENT_CLAUSE = "RC-01"
NON_RUNTIME_CLAIM_KINDS = frozenset(
    {
        "business_inference",
        "composite_static_fact",
    }
)
DIRECT_SOURCE_DELIVERY_CONTRACTS = {
    "ui.reader.multilevel-menu": {
        "target": "IOS-APP-NAVIGATION-READER-MULTILEVEL-MENU-001",
        "fixture_id": "source-ui-reader-multilevel-menu-v1",
        "validation": "simulator",
    },
    "ui.source.bulk-selection-menu": {
        "target": "IOS-APP-NAVIGATION-SOURCE-BULK-MANAGEMENT-001",
        "fixture_id": "source-ui-source-bulk-management-v1",
        "validation": "build",
    },
    "ui.discovery.explore-flow": {
        "target": "IOS-APP-NAVIGATION-DISCOVERY-EXPLORE-FLOW-001",
        "fixture_id": "source-ui-discovery-explore-flow-v1",
        "validation": "simulator",
    },
    "library.shelf.sort-and-unread-runtime": {
        "target": "IOS-LIBRARY-DOMAIN-SHELF-SORT-UNREAD-001",
        "fixture_id": "source-library-shelf-sort-unread-v1",
        "validation": "tests",
        "test_filter": "LibraryDomainTests",
    },
    "library.shelf.batch-partial-commit-runtime": {
        "target": "IOS-LIBRARY-DOMAIN-SHELF-BATCH-PARTIAL-COMMIT-001",
        "fixture_id": "source-library-shelf-batch-partial-v1",
        "validation": "tests",
        "test_filter": "LibraryDomainTests",
    },
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
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temporary = stream.name
            stream.write(canonical(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None and os.path.exists(temporary):
            os.unlink(temporary)


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
        stream.flush()
        os.fsync(stream.fileno())
    return record


@contextlib.contextmanager
def exclusive_lock(root: Path) -> Iterable[None]:
    path = root / LOCK_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise LoopError("LOOP_BUSY") from error
        try:
            yield
        finally:
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


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
        if event.get("event") != "task_completed":
            continue
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


def reused_claim_evidence(root: Path) -> dict[tuple[str, int], str]:
    """Claims resolved by reusing an existing checked-in Android artifact."""
    result: dict[tuple[str, int], str] = {}
    for event in load_events(root):
        if event.get("event") != "task_superseded":
            continue
        details = event.get("details")
        if not isinstance(details, dict):
            continue
        evidence = details.get("replacement_evidence")
        knowledge = details.get("knowledge")
        if (
            not isinstance(evidence, str)
            or not (root / evidence).is_file()
            or not isinstance(knowledge, dict)
        ):
            continue
        for reference in knowledge.get("candidate_claim_refs", []):
            if (
                isinstance(reference, dict)
                and isinstance(reference.get("id"), str)
                and isinstance(reference.get("revision"), int)
                and not isinstance(reference.get("revision"), bool)
            ):
                result[(reference["id"], reference["revision"])] = evidence
    return result


def satisfied_dependency_claim_refs(root: Path) -> set[tuple[str, int]]:
    """Claims that may unlock a downstream characterization.

    Runtime behavior still requires an Android characterization event. Static
    declarations explicitly marked as requiring no runtime evidence can be
    consumed directly from the frozen source, while a human-decision claim
    remains blocked until it is published.
    """
    result = characterized_claim_refs(root)
    result.update(reused_claim_evidence(root))
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
    for _, packet in latest_json_revisions(
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
            elif (
                isinstance(support, dict)
                and support.get("state") == "runtime_verified"
                and isinstance(support.get("runtime_evidence"), list)
                and support["runtime_evidence"]
                and all(
                    isinstance(evidence, dict)
                    and isinstance(evidence.get("artifact_uri"), str)
                    and (root / evidence["artifact_uri"]).is_file()
                    for evidence in support["runtime_evidence"]
                )
                and isinstance(claim.get("id"), str)
                and isinstance(claim.get("revision"), int)
                and not isinstance(claim.get("revision"), bool)
            ):
                result.add((claim["id"], claim["revision"]))
    return result


def current_published_claim_revisions(root: Path) -> dict[str, int]:
    """Return the latest published revision for each current claim ID.

    Proposal packets are an append-only intake history. Once a newer revision
    of a claim is published, an older proposal must not re-enter the runtime
    queue merely because its original characterization event is absent.
    """
    result: dict[str, int] = {}
    for _, packet in latest_json_revisions(
        root,
        "ios/project/business-knowledge/packets/published",
    ):
        if packet.get("status") != "published":
            continue
        for claim in packet.get("claims", []):
            if not isinstance(claim, dict):
                continue
            identifier = claim.get("id")
            revision = claim.get("revision")
            if (
                isinstance(identifier, str)
                and isinstance(revision, int)
                and not isinstance(revision, bool)
            ):
                result[identifier] = max(
                    revision,
                    result.get(identifier, 0),
                )
    return result


def current_candidate_claim_revisions(root: Path) -> dict[str, int]:
    """Return the newest candidate revision for each claim across packets."""
    result: dict[str, int] = {}
    for _, packet in latest_json_revisions(
        root,
        "ios/project/business-knowledge/packets/proposals",
    ):
        if packet.get("status") != "candidate":
            continue
        for claim in packet.get("claims", []):
            if not isinstance(claim, dict):
                continue
            identifier = claim.get("id")
            revision = claim.get("revision")
            if (
                isinstance(identifier, str)
                and isinstance(revision, int)
                and not isinstance(revision, bool)
            ):
                result[identifier] = max(
                    revision,
                    result.get(identifier, 0),
                )
    return result


def is_android_runtime_claim(claim: Mapping[str, Any]) -> bool:
    """Whether Android execution can legitimately decide this claim.

    Android runtime evidence can characterize behavior, risks, invariants and
    open runtime questions. It cannot approve an iOS business inference or
    turn a static declaration into runtime truth. Those claims must be
    resolved through static evidence or an explicit human/ADR decision.
    """
    support = claim.get("support")
    return (
        isinstance(support, dict)
        and support.get("runtime_requirement")
        == "android_characterization"
        and support.get("state") == "candidate_source_anchored"
        and claim.get("kind") not in NON_RUNTIME_CLAIM_KINDS
    )


def relative_jsons(root: Path, relative: str) -> Iterable[tuple[str, Mapping[str, Any]]]:
    directory = root / relative
    if not directory.exists():
        return
    for path in sorted(directory.rglob("*.json")):
        yield path.relative_to(root).as_posix(), read_json(path)


def latest_json_revisions(
    root: Path,
    relative: str,
) -> list[tuple[str, Mapping[str, Any]]]:
    latest: dict[str, tuple[int, str, Mapping[str, Any]]] = {}
    for path, value in relative_jsons(root, relative):
        identifier = value.get("id")
        revision = value.get("revision")
        if (
            not isinstance(identifier, str)
            or not isinstance(revision, int)
            or isinstance(revision, bool)
        ):
            continue
        current = latest.get(identifier)
        if current is not None and current[0] == revision:
            raise LoopError(
                f"REVISION_DUPLICATE:{identifier}@{revision}:"
                f"{current[1]},{path}"
            )
        if current is None or revision > current[0]:
            latest[identifier] = (revision, path, value)
    return [
        (path, value)
        for _, path, value in sorted(
            latest.values(),
            key=lambda entry: (entry[1], entry[0]),
        )
    ]


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
    for path, driver in latest_json_revisions(
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


def source_anchors_for_claims(
    root: Path,
    claim_refs: Sequence[Mapping[str, Any]],
) -> list[Mapping[str, Any]]:
    wanted = {
        (value.get("id"), value.get("revision"))
        for value in claim_refs
        if isinstance(value, dict)
    }
    anchors: dict[tuple[str, str, str, str], Mapping[str, Any]] = {}
    for _, packet in relative_jsons(
        root,
        "ios/project/business-knowledge/packets/published",
    ):
        for claim in packet.get("claims", []):
            if (
                isinstance(claim, dict)
                and (claim.get("id"), claim.get("revision")) in wanted
            ):
                for anchor in claim.get("support", {}).get(
                    "source_anchors",
                    [],
                ):
                    if not isinstance(anchor, dict):
                        continue
                    key = (
                        str(anchor.get("android_commit", "")),
                        str(anchor.get("path", "")),
                        str(anchor.get("symbol_id", "")),
                        str(anchor.get("git_blob", "")),
                    )
                    anchors[key] = anchor
    return [anchors[key] for key in sorted(anchors)]


def owner_contract(target: str) -> Mapping[str, Any]:
    if target == "IOS-DEPENDENCY-GRDB-PERSISTENCE-001":
        return {
            "owner": "DependencyControl",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-002",
                "ARCH-005",
                "ARCH-008",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "allowed_paths": [
                "ios/Packages/LegadoKit/Package.swift",
                "ios/Packages/LegadoKit/Package.resolved",
                "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                "ios/harness/dependency-policy.json",
                "ios/harness/architecture-rules.json",
                "ios/harness/probes/dependency_contract.py",
                "ios/harness/probes/dependency_activation.py",
                "ios/harness/probes/package_contract.py",
                "ios/harness/dependencies/expected/"
                "dependency-grdb-persistence-v1.json",
                "ios/harness/tests/test_dependency_contract.py",
                "ios/harness/tests/test_package_contract.py",
                "ios/project/baseline.json",
                "ios/project/dependency-proposals/**",
                "ios/docs/dependencies.md",
                "ios/docs/third-party-notices.md",
                "ios/project/sbom/**",
            ],
        }
    if target == "IOS-INTEGRATION-WEBDAV-ARCHITECTURE-001":
        return {
            "owner": "ArchitectureControl",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-005",
                "ARCH-008",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "allowed_paths": [
                "ios/docs/adr/0008-integrationkit-webdav-boundary.md",
                "ios/docs/architecture.md",
                "ios/harness/architecture-rules.json",
                "ios/project/business-knowledge/catalog.json",
                (
                    "ios/project/business-knowledge/coverage/"
                    "BKL-INTEGRATION-BACKUP-WEBDAV-RUNTIME-001.json"
                ),
                (
                    "ios/project/business-knowledge/drivers/published/"
                    "DRV-INTEGRATION-WEBDAV-RUNTIME-001/**"
                ),
            ],
            "decision_contract": {
                "id": "ADR-0008",
                "path": (
                    "ios/docs/adr/"
                    "0008-integrationkit-webdav-boundary.md"
                ),
                "initial_driver": {
                    "id": "DRV-INTEGRATION-WEBDAV-RUNTIME-001",
                    "revision": 1,
                },
                "required_targets": {
                    "IntegrationKit": ["LegadoCore"],
                    "WebDAVFoundation": [
                        "LegadoCore",
                        "IntegrationKit",
                    ],
                    "AppUseCases": [
                        "LegadoCore",
                        "LibraryDomain",
                        "SourceRuntime",
                        "ReaderCore",
                        "IntegrationKit",
                    ],
                },
                "third_party_policy": "foundation_only_initially",
            },
        }
    if target == "IOS-UI-BOOTSTRAP-001":
        return {
            "owner": "AppShell",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-004",
                "ARCH-006",
                "ARCH-007",
                "ARCH-010",
                "ARCH-017",
            ],
            "allowed_paths": [
                "ios/Apps/Legado/**",
                "ios/Packages/LegadoKit/Package.swift",
                "ios/Packages/LegadoKit/Sources/AppNavigation/**",
                "ios/Packages/LegadoKit/Tests/AppNavigationTests/**",
            ],
        }
    if "APP-NAVIGATION" in target:
        allowed_paths = [
            "ios/Apps/Legado/**",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/Packages/LegadoKit/Sources/AppNavigation/**",
            "ios/Packages/LegadoKit/Sources/AppUseCases/**",
            "ios/Packages/LegadoKit/Sources/ConformanceCLI/**",
            "ios/Packages/LegadoKit/Sources/TestSupport/FixtureModel.swift",
            "ios/Packages/LegadoKit/Tests/AppNavigationTests/**",
            "ios/Packages/LegadoKit/Tests/ConformanceCLITests/**",
            "ios/harness/ui/ui_simulator.py",
            "ios/harness/ui/tests/test_ui_simulator.py",
        ]
        if target == "IOS-APP-NAVIGATION-BOOK-DETAIL-STAGING-001":
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == "IOS-APP-NAVIGATION-CHAPTER-TOC-001":
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Tests/LibraryDomainTests/**",
                    "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
                    "ios/Packages/LegadoKit/Tests/SourceRuntimeTests/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == "IOS-APP-NAVIGATION-READER-CONTENT-001":
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Tests/LibraryDomainTests/**",
                    "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
                    "ios/Packages/LegadoKit/Tests/SourceRuntimeTests/**",
                    "ios/Packages/LegadoKit/Sources/ReaderCore/**",
                    "ios/Packages/LegadoKit/Tests/ReaderCoreTests/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == "IOS-APP-NAVIGATION-READER-PROGRESS-RESTORE-001":
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Tests/LibraryDomainTests/**",
                    "ios/Packages/LegadoKit/Sources/ReaderCore/**",
                    "ios/Packages/LegadoKit/Tests/ReaderCoreTests/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == "IOS-APP-NAVIGATION-SOURCE-IMPORT-RUNTIME-001":
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/SourceFormat/**",
                    "ios/Packages/LegadoKit/Tests/SourceFormatTests/**",
                ]
            )
        if target == (
            "IOS-APP-NAVIGATION-SOURCE-MANAGEMENT-MILESTONE-001"
        ):
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Sources/ReaderCore/**",
                    "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == (
            "IOS-APP-NAVIGATION-SHELF-MANAGEMENT-MILESTONE-001"
        ):
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Tests/LibraryDomainTests/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == (
            "IOS-APP-NAVIGATION-BOOK-IMPORT-MILESTONE-001"
        ):
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Tests/LibraryDomainTests/**",
                    "ios/Packages/LegadoKit/Sources/ReaderCore/**",
                    "ios/Packages/LegadoKit/Tests/ReaderCoreTests/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        if target == (
            "IOS-APP-NAVIGATION-OFFLINE-CACHE-MILESTONE-001"
        ):
            allowed_paths.extend(
                [
                    "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                    "ios/Packages/LegadoKit/Sources/ReaderCore/**",
                    "ios/Packages/LegadoKit/Tests/ReaderCoreTests/**",
                    "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
                    "ios/Packages/LegadoKit/Tests/SourceRuntimeTests/**",
                    "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
                    "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
                ]
            )
        return {
            "owner": "AppNavigation",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-004",
                "ARCH-005",
                "ARCH-006",
                "ARCH-007",
                "ARCH-010",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "allowed_paths": allowed_paths,
        }
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
    if "READER-CORE" in target:
        return {
            "owner": "ReaderCore",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-002",
                "ARCH-005",
                "ARCH-008",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "allowed_paths": [
                "ios/Packages/LegadoKit/Package.swift",
                "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                "ios/Packages/LegadoKit/Sources/ReaderCore/**",
                "ios/Packages/LegadoKit/Tests/ReaderCoreTests/**",
                "ios/Packages/LegadoKit/Sources/ConformanceCLI/**",
                "ios/Packages/LegadoKit/Tests/ConformanceCLITests/**",
                "ios/Packages/LegadoKit/Sources/TestSupport/FixtureModel.swift",
            ],
        }
    if "LIBRARY-DOMAIN" in target:
        return {
            "owner": "LibraryDomain",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-002",
                "ARCH-005",
                "ARCH-008",
                "ARCH-014",
                "ARCH-015",
                "ARCH-017",
                "ARCH-018",
            ],
            "allowed_paths": [
                "ios/Packages/LegadoKit/Package.swift",
                "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
                "ios/Packages/LegadoKit/Tests/LibraryDomainTests/**",
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


def direct_characterization_deliveries(
    root: Path,
) -> list[Mapping[str, Any]]:
    """Turn a completed lightweight characterization directly into delivery.

    Publishing a packet/driver/coverage trio is useful for cross-cutting
    architecture decisions, but it must not be required for an ordinary
    source-aligned slice. The completed event and checked-in Android Golden
    already provide enough authority to implement the corresponding module.
    """
    completed = completed_task_ids(root)
    characterized = characterized_claim_refs(root)
    reused_evidence = reused_claim_evidence(root)
    ledger_claim_ids = {
        entry.get("claim_ref", {}).get("id")
        for _, ledger in relative_jsons(
            root,
            "ios/project/business-knowledge/coverage",
        )
        for entry in ledger.get("entries", [])
        if isinstance(entry, dict)
        and isinstance(entry.get("claim_ref"), dict)
    }
    owner_prefix = {
        "ReaderCore": "IOS-READER-CORE",
        "SourceRuntime": "IOS-SOURCE-RUNTIME",
        "LibraryDomain": "IOS-LIBRARY-DOMAIN",
        "AppNavigation": "IOS-APP-NAVIGATION",
    }
    deliveries: list[Mapping[str, Any]] = []
    for packet_path, packet in latest_json_revisions(
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
            claim_ref = (claim_id, revision)
            if (
                not isinstance(claim_id, str)
                or not isinstance(revision, int)
                or isinstance(revision, bool)
                or (
                    claim_ref not in characterized
                    and claim_ref not in reused_evidence
                )
                or claim_id in ledger_claim_ids
            ):
                continue
            domain = characterization_contract(claim)
            prefix = owner_prefix.get(str(domain["owner"]))
            if prefix is None:
                continue
            semantic_key = str(claim.get("semantic_key") or claim_id)
            semantic_slug = re.sub(
                r"[^A-Z0-9]+",
                "-",
                semantic_key.upper(),
            ).strip("-")
            domain_slug = {
                "ReaderCore": "READER-",
                "SourceRuntime": "SOURCE-",
                "LibraryDomain": "LIBRARY-",
                "AppNavigation": "APP-",
            }[str(domain["owner"])]
            if semantic_slug.startswith(domain_slug):
                semantic_slug = semantic_slug[len(domain_slug):]
            target = f"{prefix}-{semantic_slug}-001"
            if target in completed:
                continue
            fixture_id = characterization_fixture_id(
                semantic_key,
                str(domain["fixture_prefix"]),
            )
            golden_path = reused_evidence.get(
                claim_ref,
                (
                    "ios/harness/goldens/android-legado-v1/"
                    f"{fixture_id}.json"
                ),
            )
            if not (root / golden_path).is_file():
                continue
            if claim_ref in reused_evidence:
                reused_fixture_id = read_json(root / golden_path).get(
                    "fixture_id"
                )
                if isinstance(reused_fixture_id, str):
                    fixture_id = reused_fixture_id
            requirements = requirement_refs_for_claim(
                root,
                packet,
                claim,
            )
            if not requirements:
                continue
            entry = {
                "claim_ref": {
                    "id": claim_id,
                    "revision": revision,
                },
                "validation": {
                    "required": "android_runtime",
                    "state": "verified",
                    "evidence_refs": [golden_path],
                },
                "delivery": {
                    "state": "planned",
                    "work_item_refs": [target],
                    "requirement_refs": requirements,
                },
            }
            deliveries.append(
                {
                    "target": target,
                    "title": str(claim.get("topic") or semantic_key),
                    "ledger_path": "ios/project/loop/events.jsonl",
                    "ledger": {
                        "packet_refs": [
                            {
                                "id": packet.get("id"),
                                "revision": packet.get("revision"),
                                "path": packet_path,
                            }
                        ]
                    },
                    "entries": [entry],
                    "source_anchors": claim.get("support", {}).get(
                        "source_anchors",
                        [],
                    ),
                }
            )
    return sorted(deliveries, key=lambda value: str(value["target"]))


def direct_source_deliveries(
    root: Path,
) -> list[Mapping[str, Any]]:
    """Turn an allow-listed frozen-source contract into an iOS delivery.

    Static topology and deterministic policies do not need a dedicated Android
    instrumented runner. Runtime branches must already be covered elsewhere or
    remain in the normal characterization queue. Simulator acceptance remains
    opt-in for complete visible flows.
    """
    completed = completed_task_ids(root)
    characterized = characterized_claim_refs(root)
    deliveries: list[Mapping[str, Any]] = []
    for packet_path, packet in latest_json_revisions(
        root,
        "ios/project/business-knowledge/packets/proposals",
    ):
        if packet.get("status") != "candidate":
            continue
        for claim in packet.get("claims", []):
            if not isinstance(claim, dict):
                continue
            claim_ref = (claim.get("id"), claim.get("revision"))
            contract = DIRECT_SOURCE_DELIVERY_CONTRACTS.get(
                str(claim.get("semantic_key"))
            )
            source_ready = (
                claim_ref in characterized
                or is_direct_source_claim(claim)
            )
            if (
                contract is None
                or not source_ready
                or contract["target"] in completed
            ):
                continue
            requirements = requirement_refs_for_claim(root, packet, claim)
            if not requirements:
                continue
            entry = {
                "claim_ref": {
                    "id": claim_ref[0],
                    "revision": claim_ref[1],
                },
                "validation": {
                    "required": "android_source",
                    "state": "verified",
                    "evidence_refs": [packet_path],
                },
                "delivery": {
                    "state": "planned",
                    "work_item_refs": [contract["target"]],
                    "requirement_refs": requirements,
                },
            }
            deliveries.append(
                {
                    "target": contract["target"],
                    "title": str(
                        claim.get("topic") or claim.get("semantic_key")
                    ),
                    "ledger_path": "ios/project/loop/events.jsonl",
                    "ledger": {
                        "packet_refs": [
                            {
                                "id": packet.get("id"),
                                "revision": packet.get("revision"),
                                "path": packet_path,
                            }
                        ]
                    },
                    "entries": [entry],
                    "source_anchors": claim.get("support", {}).get(
                        "source_anchors",
                        [],
                    ),
                    "source_contract": {
                        "path": packet_path,
                        "claim_ref": {
                            "id": claim_ref[0],
                            "revision": claim_ref[1],
                        },
                        "fixture_id": contract["fixture_id"],
                        "validation": contract["validation"],
                        **(
                            {"test_filter": contract["test_filter"]}
                            if "test_filter" in contract
                            else {}
                        ),
                    },
                }
            )
    return sorted(deliveries, key=lambda value: str(value["target"]))


def milestone_completion_deliveries(
    root: Path,
) -> list[Mapping[str, Any]]:
    target = "IOS-APP-NAVIGATION-READER-PROGRESS-RESTORE-001"
    if target in completed_task_ids(root):
        return []
    policy = active_priority_policy(root)
    if (
        not isinstance(policy, dict)
        or policy.get("id") != "MILESTONE-P0-USABLE-READING-001"
    ):
        return []
    requirement = (
        "REQ-IOS-UI-BOOTSTRAP-001@1#RC-01"
    )
    return [
        {
            "target": target,
            "title": "阅读进度持久化与重启恢复",
            "ledger_path": "ios/project/migration-priorities/active.json",
            "ledger": {
                "packet_refs": [],
            },
            "entries": [
                {
                    "validation": {
                        "required": "milestone_integration",
                        "state": "planned",
                        "evidence_refs": [
                            "ios/project/migration-priorities/active.json"
                        ],
                    },
                    "delivery": {
                        "state": "planned",
                        "work_item_refs": [target],
                        "requirement_refs": [requirement],
                    },
                }
            ],
            "source_anchors": [
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "9f03612aa904402fce4e1aabc2b176b23f4a6c2d",
                    "path":
                        "app/src/main/java/io/legado/app/model/ReadBook.kt",
                    "symbol_id":
                        "kotlin://io.legado.app.model.ReadBook/saveRead",
                },
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "b116c77fa2d48c9d1a1013e60a92236f71bea1bc",
                    "path": (
                        "app/src/main/java/io/legado/app/ui/book/read/"
                        "ReadBookActivity.kt"
                    ),
                    "symbol_id": (
                        "kotlin://io.legado.app.ui.book.read."
                        "ReadBookActivity/onPause"
                    ),
                },
            ],
            "source_contract": {
                "path": "ios/project/migration-priorities/active.json",
                "fixture_id": "milestone-reader-progress-restore-v1",
            },
        }
    ]


def source_management_milestone_deliveries(
    root: Path,
) -> list[Mapping[str, Any]]:
    target = "IOS-APP-NAVIGATION-SOURCE-MANAGEMENT-MILESTONE-001"
    completed = completed_task_ids(root)
    if target in completed:
        return []
    policy = active_priority_policy(root)
    prerequisites = {
        "IOS-APP-NAVIGATION-SOURCE-BULK-MANAGEMENT-001",
        "IOS-READER-CORE-LIBRARY-BOOK-SOURCE-SWITCH-MIGRATION-RUNTIME-001",
        "IOS-APP-NAVIGATION-SOURCE-IMPORT-RUNTIME-001",
    }
    if (
        not isinstance(policy, dict)
        or policy.get("id") != "MILESTONE-P1-SOURCE-MANAGEMENT-001"
        or not prerequisites.issubset(completed)
    ):
        return []
    requirement = "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001@1#RC-01"
    return [
        {
            "target": target,
            "title": "真实书源管理与整书换源里程碑",
            "ledger_path": "ios/project/migration-priorities/active.json",
            "ledger": {"packet_refs": []},
            "entries": [
                {
                    "validation": {
                        "required": "milestone_integration",
                        "state": "planned",
                        "evidence_refs": [
                            "ios/project/migration-priorities/active.json"
                        ],
                    },
                    "delivery": {
                        "state": "planned",
                        "work_item_refs": [target],
                        "requirement_refs": [requirement],
                    },
                }
            ],
            "source_anchors": [
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "a461b135ca389a687189b6661a0a02e04456c7f2",
                    "path": (
                        "app/src/main/java/io/legado/app/ui/book/info/"
                        "BookInfoViewModel.kt"
                    ),
                    "symbol_id": (
                        "kotlin://io.legado.app.ui.book.info."
                        "BookInfoViewModel/changeTo"
                    ),
                },
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "b116c77fa2d48c9d1a1013e60a92236f71bea1bc",
                    "path": (
                        "app/src/main/java/io/legado/app/ui/book/read/"
                        "ReadBookActivity.kt"
                    ),
                    "symbol_id": (
                        "kotlin://io.legado.app.ui.book.read."
                        "ReadBookActivity/changeTo"
                    ),
                },
            ],
            "source_contract": {
                "path": "ios/project/migration-priorities/active.json",
                "fixture_id": "milestone-source-management-v1",
                "validation": "simulator",
            },
        }
    ]


def shelf_management_milestone_deliveries(
    root: Path,
) -> list[Mapping[str, Any]]:
    target = "IOS-APP-NAVIGATION-SHELF-MANAGEMENT-MILESTONE-001"
    completed = completed_task_ids(root)
    if target in completed:
        return []
    policy = active_priority_policy(root)
    prerequisites = {
        "IOS-LIBRARY-DOMAIN-SHELF-SORT-UNREAD-001",
        "IOS-LIBRARY-DOMAIN-SHELF-BATCH-PARTIAL-COMMIT-001",
    }
    if (
        not isinstance(policy, dict)
        or policy.get("id") != "MILESTONE-P3-USABLE-SHELF-001"
        or not prerequisites.issubset(completed)
    ):
        return []
    requirement = "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001@1#RC-01"
    return [
        {
            "target": target,
            "title": "可排序、可识别新增章节的批量书架里程碑",
            "ledger_path": "ios/project/migration-priorities/active.json",
            "ledger": {"packet_refs": []},
            "entries": [
                {
                    "validation": {
                        "required": "milestone_integration",
                        "state": "planned",
                        "evidence_refs": [
                            "ios/project/migration-priorities/active.json"
                        ],
                    },
                    "delivery": {
                        "state": "planned",
                        "work_item_refs": [target],
                        "requirement_refs": [requirement],
                    },
                }
            ],
            "source_anchors": [
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "0bb1754bfa3eae7cb12ae1e30ddb72789bb05f90",
                    "path": (
                        "app/src/main/java/io/legado/app/ui/book/manage/"
                        "BookshelfManageViewModel.kt"
                    ),
                    "symbol_id": (
                        "kotlin://io.legado.app.ui.book.manage."
                        "BookshelfManageViewModel"
                    ),
                },
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "d0f564d8c17cceb37674e343e6fc2c1cef047bb5",
                    "path": (
                        "app/src/main/java/io/legado/app/ui/book/manage/"
                        "BookshelfManageActivity.kt"
                    ),
                    "symbol_id": (
                        "kotlin://io.legado.app.ui.book.manage."
                        "BookshelfManageActivity"
                    ),
                },
                {
                    "android_commit":
                        "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                    "git_blob":
                        "fe9977c72fd4506a4dce934a9b0a1491287860ed",
                    "path": (
                        "app/src/main/java/io/legado/app/ui/main/bookshelf/"
                        "style1/books/BooksFragment.kt"
                    ),
                    "symbol_id": (
                        "kotlin://io.legado.app.ui.main.bookshelf.style1."
                        "books.BooksFragment/upRecyclerData"
                    ),
                },
            ],
            "source_contract": {
                "path": "ios/project/migration-priorities/active.json",
                "fixture_id": "milestone-shelf-management-v1",
                "validation": "simulator",
            },
        }
    ]


def priority_policy_deliveries(
    root: Path,
) -> list[Mapping[str, Any]]:
    policy = active_priority_policy(root)
    if not isinstance(policy, dict):
        return []
    completed = completed_task_ids(root)
    deliveries = []
    for declaration in policy.get("deliveries", []):
        target = str(declaration["target"])
        prerequisites = set(declaration["prerequisite_task_ids"])
        if target in completed or not prerequisites.issubset(completed):
            continue
        requirement = str(declaration["requirement_ref"])
        deliveries.append(
            {
                "target": target,
                "title": str(declaration["title"]),
                "ledger_path": str(PRIORITY_PATH),
                "ledger": {"packet_refs": []},
                "entries": [
                    {
                        "validation": {
                            "required": "milestone_integration",
                            "state": "planned",
                            "evidence_refs": [str(PRIORITY_PATH)],
                        },
                        "delivery": {
                            "state": "planned",
                            "work_item_refs": [target],
                            "requirement_refs": [requirement],
                        },
                    }
                ],
                "source_anchors": declaration["source_anchors"],
                "source_contract": {
                    "path": str(PRIORITY_PATH),
                    "fixture_id": str(declaration["fixture_id"]),
                    "validation": str(
                        declaration.get("validation", "tests")
                    ),
                },
            }
        )
    return deliveries


def active_priority_policy(root: Path) -> Mapping[str, Any] | None:
    path = root / PRIORITY_PATH
    if not path.is_file():
        return None
    policy = read_json(path)
    stages = policy.get("stages")
    if (
        policy.get("schema_version") != 1
        or policy.get("status") != "active"
        or policy.get("mode") != "critical_path_only"
        or not isinstance(policy.get("id"), str)
        or not isinstance(stages, list)
        or not stages
    ):
        raise LoopError("PRIORITY_POLICY_INVALID")
    stage_ids: set[str] = set()
    for stage in stages:
        if not isinstance(stage, dict):
            raise LoopError("PRIORITY_POLICY_INVALID")
        stage_id = stage.get("id")
        selectors = stage.get("selectors")
        if (
            not isinstance(stage_id, str)
            or not stage_id
            or stage_id in stage_ids
            or not isinstance(stage.get("title"), str)
            or not isinstance(selectors, list)
            or not selectors
        ):
            raise LoopError("PRIORITY_POLICY_INVALID")
        stage_ids.add(stage_id)
        for selector in selectors:
            if not isinstance(selector, dict):
                raise LoopError("PRIORITY_POLICY_INVALID")
            claim_ids = selector.get("claim_ids", [])
            task_ids = selector.get("task_ids", [])
            if (
                not isinstance(selector.get("id"), str)
                or not isinstance(claim_ids, list)
                or not isinstance(task_ids, list)
                or not claim_ids
                and not task_ids
                or any(not isinstance(value, str) for value in claim_ids)
                or any(not isinstance(value, str) for value in task_ids)
            ):
                raise LoopError("PRIORITY_POLICY_INVALID")
    deliveries = policy.get("deliveries", [])
    if not isinstance(deliveries, list):
        raise LoopError("PRIORITY_POLICY_INVALID")
    delivery_targets: set[str] = set()
    for delivery in deliveries:
        if (
            not isinstance(delivery, dict)
            or not isinstance(delivery.get("target"), str)
            or not delivery["target"]
            or delivery["target"] in delivery_targets
            or not isinstance(delivery.get("title"), str)
            or not isinstance(delivery.get("fixture_id"), str)
            or not isinstance(delivery.get("requirement_ref"), str)
            or not isinstance(
                delivery.get("prerequisite_task_ids"),
                list,
            )
            or any(
                not isinstance(value, str)
                for value in delivery["prerequisite_task_ids"]
            )
            or not isinstance(delivery.get("source_anchors"), list)
            or not delivery["source_anchors"]
            or delivery.get("validation", "tests")
            not in {"build", "tests", "simulator"}
        ):
            raise LoopError("PRIORITY_POLICY_INVALID")
        delivery_targets.add(delivery["target"])
    return policy


def priority_match(
    policy: Mapping[str, Any],
    *,
    task_id: str,
    claim_ids: set[str],
) -> tuple[int, int, Mapping[str, Any], Mapping[str, Any]] | None:
    for stage_index, stage in enumerate(policy["stages"]):
        for selector_index, selector in enumerate(stage["selectors"]):
            if (
                task_id in selector.get("task_ids", [])
                or claim_ids.intersection(selector.get("claim_ids", []))
            ):
                return stage_index, selector_index, stage, selector
    return None


def prioritized_work(
    root: Path,
) -> list[
    tuple[
        tuple[int, int, int, str],
        str,
        Mapping[str, Any],
        Mapping[str, Any] | None,
    ]
]:
    published_deliveries = planned_deliveries(root)
    published_targets = {
        str(value["target"]) for value in published_deliveries
    }
    deliveries = published_deliveries + [
        value
        for value in direct_characterization_deliveries(root)
        if str(value["target"]) not in published_targets
    ]
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in direct_source_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in milestone_completion_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in source_management_milestone_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in shelf_management_milestone_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in priority_policy_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    characterizations = pending_characterizations(root)
    policy = active_priority_policy(root)
    if policy is None:
        return [
            ((0, 0, index, str(value["target"])), "delivery", value, None)
            for index, value in enumerate(deliveries)
        ] + [
            (
                (1, 0, index, str(value["task_id"])),
                "characterization",
                value,
                None,
            )
            for index, value in enumerate(characterizations)
        ]

    ranked = []
    for kind, values in (
        ("delivery", deliveries),
        ("characterization", characterizations),
    ):
        for value in values:
            if kind == "delivery":
                task_id = str(value["target"])
                claim_ids = {
                    str(entry.get("claim_ref", {}).get("id"))
                    for entry in value.get("entries", [])
                    if isinstance(entry, dict)
                    and isinstance(entry.get("claim_ref"), dict)
                    and isinstance(entry["claim_ref"].get("id"), str)
                }
            else:
                task_id = str(value["task_id"])
                claim_id = value.get("claim", {}).get("id")
                claim_ids = {claim_id} if isinstance(claim_id, str) else set()
            match = priority_match(
                policy,
                task_id=task_id,
                claim_ids=claim_ids,
            )
            if match is None:
                continue
            stage_index, selector_index, stage, selector = match
            kind_rank = 0 if kind == "delivery" else 1
            ranked.append(
                (
                    (stage_index, selector_index, kind_rank, task_id),
                    kind,
                    value,
                    {
                        "milestone_id": policy["id"],
                        "stage_id": stage["id"],
                        "stage_title": stage["title"],
                        "selector_id": selector["id"],
                    },
                )
            )
    return sorted(ranked, key=lambda item: item[0])


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
        return automatic_characterization_requirement_refs(root, packet)
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


def automatic_characterization_requirement_refs(
    root: Path,
    packet: Mapping[str, Any],
) -> list[str]:
    """Return the accepted project charter for an unclaimed Android candidate.

    A per-slice AndroidMigrationIntent remains the more specific authority. The
    charter is only a fail-closed fallback that keeps source-anchored runtime
    claims moving when no intent overlaps their frozen source paths.
    """
    path = (
        root
        / "ios/project/requirements/accepted"
        / f"{ANDROID_CHARACTERIZATION_REQUIREMENT_ID}.json"
    )
    if not path.is_file():
        return []
    requirement = read_json(path)
    origin = requirement.get("origin")
    packet_baseline = packet.get("baseline")
    clauses = requirement.get("clauses")
    if (
        requirement.get("id") != ANDROID_CHARACTERIZATION_REQUIREMENT_ID
        or requirement.get("status") != "accepted"
        or not isinstance(requirement.get("revision"), int)
        or isinstance(requirement.get("revision"), bool)
        or not isinstance(origin, dict)
        or origin.get("kind") != "ios_product_decision"
        or origin.get("admission") != "policy_auto"
        or not isinstance(packet_baseline, dict)
        or origin.get("baseline_commit")
        != packet_baseline.get("android_commit")
        or not isinstance(clauses, list)
        or ANDROID_CHARACTERIZATION_REQUIREMENT_CLAUSE
        not in {
            clause.get("id")
            for clause in clauses
            if isinstance(clause, dict)
        }
    ):
        return []
    return [
        (
            f"{ANDROID_CHARACTERIZATION_REQUIREMENT_ID}"
            f"@{requirement['revision']}"
            f"#{ANDROID_CHARACTERIZATION_REQUIREMENT_CLAUSE}"
        )
    ]


def pending_characterizations(root: Path) -> list[Mapping[str, Any]]:
    completed = completed_task_ids(root)
    characterized = characterized_claim_refs(root)
    reused = set(reused_claim_evidence(root))
    satisfied_dependencies = satisfied_dependency_claim_refs(root)
    satisfied_dependency_revisions = {
        identifier: max(
            revision,
            max(
                (
                    current_revision
                    for current_identifier, current_revision
                    in satisfied_dependencies
                    if current_identifier == identifier
                ),
                default=0,
            ),
        )
        for identifier, revision in satisfied_dependencies
    }
    published_revisions = current_published_claim_revisions(root)
    candidate_revisions = current_candidate_claim_revisions(root)
    candidates: list[tuple[int, int, str, Mapping[str, Any]]] = []
    for packet_path, packet in latest_json_revisions(
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
                or not is_android_runtime_claim(claim)
                or published_revisions.get(claim_id, 0) >= revision
                or candidate_revisions.get(claim_id, 0) > revision
                or (claim_id, revision) in characterized
                or (claim_id, revision) in reused
                or is_direct_source_claim(claim)
            ):
                continue
            dependencies = {
                (value.get("id"), value.get("revision"))
                for value in claim.get("depends_on", [])
                if isinstance(value, dict)
            }
            if any(
                satisfied_dependency_revisions.get(identifier, 0) < revision
                for identifier, revision in dependencies
            ):
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


def is_direct_source_claim(claim: Mapping[str, Any]) -> bool:
    """Whether an explicit contract can be implemented from frozen source.

    This is intentionally allow-listed. It prevents a broad "all UI is static"
    shortcut while avoiding an Android instrumented runner for topology whose
    implementation anchors are already frozen and content parsing is verified
    separately by SourceRuntime.
    """
    support = claim.get("support")
    return (
        str(claim.get("semantic_key")) in DIRECT_SOURCE_DELIVERY_CONTRACTS
        and isinstance(support, dict)
        and support.get("state") == "candidate_source_anchored"
        and bool(support.get("source_anchors"))
    )


def characterization_contract(claim: Mapping[str, Any]) -> Mapping[str, Any]:
    semantic_key = str(claim.get("semantic_key", ""))
    subject_keys = {
        str(value)
        for value in claim.get("subject_keys", [])
        if isinstance(value, str)
    }
    keys = {semantic_key, *subject_keys}
    if any(value.startswith(("app.", "ui.")) for value in keys):
        return {
            "owner": "AppNavigation",
            "fixture_prefix": "rl",
            "fixture_root": "runtime-lab",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-004",
                "ARCH-006",
                "ARCH-007",
                "ARCH-010",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "rule": (
                "先固定 Android 启动与导航决策的可观察状态转换，再决定"
                " AppNavigation、AppUseCases 和 AppShell 的职责；"
                "Android Activity、平台 I/O 与 Golden 不进入产品 Target。"
            ),
        }
    if any(
        value.startswith(("reader.",))
        for value in keys
    ):
        return {
            "owner": "ReaderCore",
            "fixture_prefix": "rl",
            "fixture_root": "runtime-lab",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-002",
                "ARCH-005",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "rule": (
                "先固定 Android 阅读运行时可观察结果，再扩展 ReaderCore；"
                "LibraryDomain 只承载值，Android Room 与 Golden 不进入产品 Target。"
            ),
        }
    if any(value.startswith("library.") for value in keys):
        return {
            "owner": "LibraryDomain",
            "fixture_prefix": "rl",
            "fixture_root": "runtime-lab",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-002",
                "ARCH-014",
                "ARCH-015",
                "ARCH-017",
                "ARCH-018",
            ],
            "rule": (
                "先固定 Android 领域运行时可观察结果，再扩展 LibraryDomain；"
                "数据库 Record、Android Room 与 Golden 不进入领域 Target。"
            ),
        }
    if any(
        value.startswith(("source.", "content.cache"))
        for value in keys
    ):
        return {
            "owner": "SourceRuntime",
            "fixture_prefix": "sl",
            "fixture_root": "source-lab",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-005",
                "ARCH-014",
                "ARCH-017",
            ],
            "rule": (
                "先固定 Android 可观察结果，再扩展独立 SourceRuntime；"
                "SourceLab 与 Golden 不进入 UI/Domain。"
            ),
        }
    if any(value.startswith("integration.") for value in keys):
        return {
            "owner": "IntegrationKit",
            "fixture_prefix": "il",
            "fixture_root": "integration-lab",
            "architecture_refs": [
                "ARCH-001",
                "ARCH-005",
                "ARCH-008",
                "ARCH-014",
                "ARCH-017",
                "ARCH-018",
            ],
            "rule": (
                "先用仅绑定 loopback 的 IntegrationLab 固定 Android 集成协议"
                "可观察结果；这只授权 characterization。IntegrationKit 的产品"
                "Target、依赖边和三方库必须由发布后的业务知识与 ADR 另行决定，"
                "凭据不得进入 fixture、Golden 或 trace。"
            ),
            "allowed_paths": [
                "ios/harness/integration-lab/**",
                "ios/harness/schemas/integration-lab-scenario.schema.json",
                "ios/harness/oracle/ci_proposal.py",
                "ios/harness/oracle/contract.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/harness/oracle/cli.py",
                "ios/harness/tests/test_oracle_ci_proposal.py",
                "ios/harness/tests/test_oracle_control.py",
                "ios/harness/tests/test_oracle_trusted_import.py",
            ],
        }
    raise LoopError(f"CHARACTERIZATION_DOMAIN_NOT_MAPPED:{semantic_key}")


def characterization_fixture_id(
    semantic_key: str,
    fixture_prefix: str = "sl",
) -> str:
    reusable_fixtures = {
        "reader.progress.toc-remap-runtime":
            "rl-reader-progress-toc-remap-001",
        "reader.session.late-result-risk":
            "rl-reader-content-index-load-dedup-001",
        "reader.session.toc-refresh":
            "rl-library-chapter-toc-update-runtime-001",
    }
    if semantic_key in reusable_fixtures:
        return reusable_fixtures[semantic_key]
    slug = re.sub(r"[^a-z0-9]+", "-", semantic_key.lower()).strip("-")
    return f"{fixture_prefix}-{slug}-001"


def app_ui_simulators(
    profile: str = "checkpoint",
) -> list[Mapping[str, str]]:
    simulators = [
        {
            "simulator_id": "SIM-PHONE-COMPACT-001",
            "name": "Legado Loop iPhone SE (3rd generation)",
            "device_type": (
                "com.apple.CoreSimulator.SimDeviceType."
                "iPhone-SE-3rd-generation"
            ),
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
            "projection": "compactStack",
        },
        {
            "simulator_id": "SIM-PAD-REGULAR-001",
            "name": "Legado Loop iPad Pro 13-inch (M4)",
            "device_type": (
                "com.apple.CoreSimulator.SimDeviceType."
                "iPad-Pro-13-inch-M4-8GB"
            ),
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-0",
            "projection": "regularSplit",
        },
    ]
    if profile == "slice":
        return simulators[:1]
    return simulators


def app_navigation_delivery_contract(
    fixture_id: str,
) -> Mapping[str, Any]:
    features = {
        "rl-app-startup-first-use-and-restore-001": {
            "goal": (
                "按照冻结 Android 启动运行结果，在 AppNavigation/AppUseCases "
                "中实现平台无关启动状态机与显式 effect，并由 AppShell 投影"
                "为原生 iPhone/iPad 导航和对话框。"
            ),
            "acceptance_id": "structured-app-startup-acceptance",
            "scenario_id": "ui-app-startup-first-use-and-restore-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-app-startup-first-use-and-restore-v1.json"
            ),
            "test_method": "testStartupFirstUseAndRestore",
        },
        "rl-ui-book-detail-conditional-actions-001": {
            "goal": (
                "按照冻结 Android 书籍详情操作矩阵，在 AppNavigation/"
                "AppUseCases 中实现平台无关的操作可用性，并由 AppShell "
                "投影为原生 iPhone/iPad 详情菜单。"
            ),
            "acceptance_id": "structured-book-detail-actions-acceptance",
            "scenario_id": "ui-book-detail-conditional-actions-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-book-detail-conditional-actions-v1.json"
            ),
            "test_method": "testBookDetailConditionalActions",
        },
        "rl-ui-discovery-search-flow-001": {
            "goal": (
                "按照冻结 Android 搜索流程，在 AppUseCases 中实现搜索会话与"
                "范围状态，在 AppNavigation 中传递稳定候选路由，并由 AppShell "
                "接入 SourceRuntime 与 LibraryDomain 的真实结果，移除静态样例。"
            ),
            "acceptance_id": "structured-search-flow-acceptance",
            "scenario_id": "ui-discovery-search-flow-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-discovery-search-flow-v1.json"
            ),
            "test_method": "testDiscoverySearchFlow",
        },
        "rl-ui-source-editor-debug-routes-001": {
            "goal": (
                "按照冻结 Android 书源编辑与调试状态转换，在 AppUseCases "
                "中实现编辑会话、保存边界、调试路由和调用方刷新策略，"
                "在 AppNavigation 中提供稳定页面路由，并由 AppShell "
                "接入设置页、详情页和阅读器入口。"
            ),
            "acceptance_id": "structured-source-editor-debug-acceptance",
            "scenario_id": "ui-source-editor-debug-routes-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-source-editor-debug-routes-v1.json"
            ),
            "test_method": "testSourceEditorDebugRoutes",
        },
        "rl-app-source-import-runtime-001": {
            "goal": (
                "按照冻结 Android 书源导入结果，在 SourceFormat 中实现"
                "定义集合 codec，在 AppUseCases 中实现预选、冲突合并与"
                "批量持久化，并由 AppShell 接入粘贴和文件导入。"
            ),
            "acceptance_id": "structured-source-import-acceptance",
            "scenario_id": "ui-source-import-v1",
            "expected": (
                "ios/harness/ui/expected/ui-source-import-v1.json"
            ),
            "test_method": "testSourceImportFlow",
        },
        "rl-library-book-detail-staging-runtime-001": {
            "goal": (
                "把稳定书籍身份、显式书架成员资格与 DatabaseGRDB 仓储接入"
                "详情和书架页面，在真实搜索结果上完成入架、终止重启与重开。"
            ),
            "acceptance_id": "structured-book-detail-staging-acceptance",
            "scenario_id": "ui-book-detail-staging-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-book-detail-staging-v1.json"
            ),
            "test_method": "testBookDetailStagingPersistence",
        },
        "rl-library-chapter-toc-update-runtime-001": {
            "goal": (
                "把稳定书源与章节身份、目录抓取、失败保留和 GRDB 原子替换"
                "接入详情与目录页面，在真实搜索结果上完成目录加载和章节选择。"
            ),
            "acceptance_id": "structured-chapter-toc-acceptance",
            "scenario_id": "ui-chapter-toc-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-chapter-toc-v1.json"
            ),
            "test_method": "testChapterTOCFlow",
        },
        "rl-ui-reader-toc-result-001": {
            "goal": (
                "按照冻结 Android 目录选择结果，把稳定章节身份和字符偏移"
                "从 AppNavigation 交给 AppUseCases，接通 SourceRuntime 正文"
                "抓取、ReaderCore 阅读文档与原生 iPhone/iPad Reader 页面。"
            ),
            "acceptance_id": "structured-reader-content-acceptance",
            "scenario_id": "ui-reader-content-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-reader-content-v1.json"
            ),
            "test_method": "testReaderContentFlow",
        },
        "source-ui-reader-multilevel-menu-v1": {
            "goal": (
                "按照冻结 Android 阅读器菜单源码拓扑，一次实现主操作层、"
                "外观层、更多设置层和文本操作层；平台控件允许 iOS 化，"
                "菜单层级、关键叶子和返回关系保持一致。"
            ),
            "acceptance_id": "structured-reader-menu-acceptance",
            "scenario_id": "ui-reader-multilevel-menu-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-reader-multilevel-menu-v1.json"
            ),
            "test_method": "testReaderMultilevelMenuFlow",
        },
        "source-ui-source-bulk-management-v1": {
            "goal": (
                "按照冻结 Android 书源管理源码合同，在 AppUseCases 中实现"
                "选择、启停、排序、分组、删除和导出策略，并由 AppShell "
                "提供 iOS 原生批量操作界面。该切片只做编译验收，完整"
                "书源管理流程在里程碑统一运行 Simulator。"
            ),
            "acceptance_id": "source-bulk-management-build-acceptance",
            "scenario_id": "ui-source-management-milestone-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-source-management-milestone-v1.json"
            ),
            "test_method": "testSourceManagementMilestone",
        },
        "source-ui-discovery-explore-flow-v1": {
            "goal": (
                "按照冻结 Android 发现页源码拓扑，把已启用发现的书源、分类、"
                "分页书单和稳定书籍详情路由接成完整主路径；书源解析继续由"
                "独立 SourceRuntime 承担，AppShell 只投影 iOS 原生界面。"
            ),
            "acceptance_id": "structured-discovery-explore-acceptance",
            "scenario_id": "ui-discovery-explore-flow-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-discovery-explore-flow-v1.json"
            ),
            "test_method": "testDiscoveryExploreFlow",
        },
        "milestone-reader-progress-restore-v1": {
            "goal": (
                "把 ReaderCore 已对齐的章节/字符坐标保存语义接入"
                " AppUseCases 与 DatabaseGRDB；阅读器切章、退后台或终止时"
                "持久化位置，App 重启后恢复到同一稳定章节和等价字符坐标。"
            ),
            "acceptance_id": "structured-reader-progress-restore-acceptance",
            "scenario_id": "ui-reader-progress-restore-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-reader-progress-restore-v1.json"
            ),
            "test_method": "testReaderProgressPersistsAcrossRelaunch",
        },
        "milestone-source-management-v1": {
            "goal": (
                "把书源批量管理与整书换源核心接入 DatabaseGRDB、详情页和"
                "阅读器，保证旧书、目录与阅读进度原子迁移；随后只在一台"
                "主 iPhone Simulator 上验收导入、批量管理和换源主流程。"
            ),
            "acceptance_id":
                "structured-source-management-milestone-acceptance",
            "scenario_id": "ui-source-management-milestone-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-source-management-milestone-v1.json"
            ),
            "test_method": "testSourceManagementMilestone",
        },
        "milestone-shelf-management-v1": {
            "goal": (
                "把 LibraryDomain 已对齐的五种排序、新增章节状态和逐书"
                "部分提交模型接入 AppUseCases 与 DatabaseGRDB，并由"
                " AppShell 提供书架排序、未读提示和批量管理。完成后只在"
                "一台主 iPhone Simulator 上验收完整书架管理主流程。"
            ),
            "acceptance_id":
                "structured-shelf-management-milestone-acceptance",
            "scenario_id": "ui-shelf-management-milestone-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-shelf-management-milestone-v1.json"
            ),
            "test_method": "testShelfManagementMilestone",
        },
        "milestone-book-import-v1": {
            "goal": (
                "把 LibraryDomain 已对齐的 URL、本地文件、归档和重复导入"
                "语义接入 AppUseCases、应用管理文件目录与 DatabaseGRDB；"
                "先以真实 TXT 完成导入、入架、目录、正文、阅读和重启恢复，"
                "格式解析能力必须真实存在，不能只按扩展名宣称支持。"
            ),
            "acceptance_id":
                "structured-book-import-milestone-acceptance",
            "scenario_id": "ui-book-import-milestone-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-book-import-milestone-v1.json"
            ),
            "test_method": "testBookImportMilestone",
        },
        "milestone-offline-cache-v1": {
            "goal": (
                "复用 SourceRuntime 已对齐的缓存队列状态机和 ReaderCore "
                "缓存优先策略，把远程正文成功结果写入 GRDB；由书架提供"
                "批量离线缓存入口，并在书源不可用和 App 重启后从持久"
                "缓存继续阅读。空正文、本地书和失败重试保持显式结果。"
            ),
            "acceptance_id":
                "structured-offline-cache-milestone-acceptance",
            "scenario_id": "ui-offline-cache-milestone-v1",
            "expected": (
                "ios/harness/ui/expected/"
                "ui-offline-cache-milestone-v1.json"
            ),
            "test_method": "testOfflineCacheMilestone",
        },
    }
    feature = features.get(fixture_id)
    if feature is None:
        raise LoopError(
            f"APP_NAVIGATION_UI_CONTRACT_NOT_MAPPED:{fixture_id}"
        )
    return {
        "goal": feature["goal"],
        "rule": (
            "AppNavigation 只承载稳定 Route、启动快照、检查点与 effect；"
            "AppUseCases 通过端口执行持久化，AppShell 只投影 UI，"
            "Android Activity、Dialog 与平台 I/O 不进入核心。"
        ),
        "test_id": "app-navigation-tests",
        "test_filter": "AppNavigationTests",
        "acceptance_id": feature["acceptance_id"],
        "ui_acceptance": {
            "scenario_id": feature["scenario_id"],
            "profile": "store_safe",
            "expected": feature["expected"],
            "project": "ios/Apps/Legado/Legado.xcodeproj",
            "scheme": "LegadoApp",
            "test_method": feature["test_method"],
            "simulators": app_ui_simulators("slice"),
        },
    }


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
    source_contract = delivery.get("source_contract")
    fixture_id = (
        source_contract.get("fixture_id")
        if isinstance(source_contract, dict)
        else None
    )
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
    title = str(delivery.get("title") or target)
    if driver_match:
        driver_path, driver = driver_match
        driver_ref = {
            "id": driver.get("id"),
            "revision": driver.get("revision"),
            "path": driver_path,
        }
        title = str(driver.get("title") or target)
    if architecture["owner"] == "ArchitectureControl":
        decision = architecture.get("decision_contract")
        if (
            not isinstance(decision, dict)
            or not isinstance(driver_ref, dict)
            or driver_ref.get("id")
            != decision.get("initial_driver", {}).get("id")
            or driver_ref.get("revision")
            != decision.get("initial_driver", {}).get("revision")
            or not isinstance(driver, dict)
            or driver.get("status") != "active"
            or driver.get("resolution", {}).get("state") != "requires_adr"
            or not golden_path
            or not fixture_id
        ):
            raise LoopError("ARCHITECTURE_DECISION_SOURCE_INVALID")
        return {
            "schema_version": SCHEMA_VERSION,
            "id": target,
            "kind": "delivery",
            "title": title,
            "status": "ready",
            "priority": 100,
            "goal": (
                "依据受保护 Android Golden 和 active Architecture Driver，"
                "先物化 IntegrationKit/WebDAV 的 Target、依赖边、凭据隔离、"
                "兼容差异与三方库决策；本任务不实现产品代码。"
            ),
            "source": {
                "android_baseline": {
                    "android_commit": read_json(root / golden_path)
                    .get("oracle", {})
                    .get("android_git_commit")
                },
                "anchors": source_anchors_for_claims(root, claim_refs),
                "fixture_id": fixture_id,
                "android_golden": golden_path,
                "knowledge": {
                    "coverage": delivery["ledger_path"],
                    "packets": ledger.get("packet_refs", []),
                    "driver": driver_ref,
                    "claims": claim_refs,
                },
                "architecture_decision": decision,
            },
            "requirements": requirement_refs,
            "architecture": {
                "owner": architecture["owner"],
                "refs": architecture["architecture_refs"],
                "rule": (
                    "先接受 ADR 并更新机器可读依赖矩阵，再允许创建产品 "
                    "Target 或引入依赖；凭据值不得进入业务数据与任何证据。"
                ),
            },
            "scope": {
                "allowed_paths": architecture["allowed_paths"],
                "forbidden": [
                    "ios/Packages/LegadoKit/Package.swift",
                    "ios/Packages/LegadoKit/Sources/**",
                    "accepted Requirement",
                    "产品实现",
                    "三方依赖代码",
                ],
            },
            "acceptance": {
                "profile": "slice",
                "commands": [
                    {
                        "id": "dependency-contract",
                        "argv": [
                            "python3",
                            "-B",
                            "ios/harness/probes/dependency_contract.py",
                            "--root",
                            ".",
                        ],
                        "timeout_seconds": 120,
                    },
                    {
                        "id": "business-knowledge-contract",
                        "argv": [
                            "python3",
                            "-B",
                            (
                                "ios/harness/business-knowledge/"
                                "business_knowledge.py"
                            ),
                            "doctor",
                            "--root",
                            ".",
                        ],
                        "timeout_seconds": 120,
                    },
                ],
                "structured_output": {
                    "mode": "architecture_decision",
                    "fixture_id": decision["id"],
                    "expected": decision["path"],
                    "required_fields": [
                        "decision",
                        "driver",
                        "dependency_contract",
                        "first_divergence",
                    ],
                    "expected_values": {
                        "task_id": target,
                        "fixture_id": decision["id"],
                        "status": "equal",
                        "first_divergence": None,
                    },
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
    if architecture["owner"] == "AppShell":
        expected_path = (
            "ios/harness/ui/expected/ui-bootstrap-roots-v1.json"
        )
        scenario_id = "ui-bootstrap-roots-v1"
        return {
            "schema_version": SCHEMA_VERSION,
            "id": target,
            "kind": "delivery",
            "title": title,
            "status": "ready",
            "priority": 100,
            "goal": (
                "物化最小原生 iOS App、共享 Route 状态和 UITest Target；"
                "在固定 iPhone/iPad Simulator 上验证四 Root 与书架搜索结构。"
            ),
            "source": {
                "authority": "ios_product_decision",
                "decision_refs": ["ADR-0001", "ADR-0005", "ADR-0006"],
                "anchors": source_anchors_for_claims(root, claim_refs),
                "knowledge": {
                    "coverage": delivery["ledger_path"],
                    "packets": ledger.get("packet_refs", []),
                    "driver": driver_ref,
                    "claims": claim_refs,
                },
                "ui_acceptance": {
                    "scenario_id": scenario_id,
                    "profile": "store_safe",
                    "expected": expected_path,
                    "project": "ios/Apps/Legado/Legado.xcodeproj",
                    "scheme": "LegadoApp",
                    "simulators": [
                        {
                            "simulator_id": "SIM-PHONE-COMPACT-001",
                            "name": "Legado Loop iPhone SE (3rd generation)",
                            "device_type": (
                                "com.apple.CoreSimulator.SimDeviceType."
                                "iPhone-SE-3rd-generation"
                            ),
                            "runtime": (
                                "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
                            ),
                            "projection": "compactStack",
                        },
                        {
                            "simulator_id": "SIM-PAD-REGULAR-001",
                            "name": "Legado Loop iPad Pro 13-inch (M4)",
                            "device_type": (
                                "com.apple.CoreSimulator.SimDeviceType."
                                "iPad-Pro-13-inch-M4-8GB"
                            ),
                            "runtime": (
                                "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
                            ),
                            "projection": "regularSplit",
                        },
                    ],
                },
            },
            "requirements": requirement_refs,
            "architecture": {
                "owner": architecture["owner"],
                "refs": architecture["architecture_refs"],
                "rule": (
                    "App 只做 composition；Route 只携带稳定值；"
                    "compact/regular 共用同一 Router，Feature 不直接 I/O。"
                ),
            },
            "scope": {
                "allowed_paths": architecture["allowed_paths"],
                "forbidden": [
                    "Android source",
                    "Business Knowledge",
                    "accepted Requirement",
                    "architecture rules",
                    "三方依赖",
                ],
            },
            "acceptance": {
                "profile": "checkpoint",
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
                        "id": "app-navigation-tests",
                        "argv": [
                            "swift",
                            "test",
                            "--package-path",
                            "ios/Packages/LegadoKit",
                            "--disable-automatic-resolution",
                            "--filter",
                            "AppNavigationTests",
                        ],
                        "required_output_pattern": (
                            r"Executed [1-9][0-9]* tests?, with 0 failures"
                        ),
                        "timeout_seconds": 300,
                    },
                    {
                        "id": "ui-simulator-acceptance",
                        "argv": [
                            "python3",
                            "-B",
                            "ios/harness/ui/ui_simulator.py",
                            "verify",
                            "--root",
                            ".",
                            "--task",
                            "ios/project/loop/task.json",
                        ],
                        "timeout_seconds": 1800,
                    },
                ],
                "structured_output": {
                    "mode": "command_json",
                    "command_id": "ui-simulator-acceptance",
                    "fixture_id": scenario_id,
                    "expected": expected_path,
                    "required_fields": [
                        "expected",
                        "actual",
                        "simulator_matrix",
                        "first_divergence",
                    ],
                    "expected_values": {
                        "scenario_id": scenario_id,
                        "status": "equal",
                        "first_divergence": None,
                    },
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
    source_anchors = delivery.get("source_anchors", [])
    if not source_anchors:
        source_anchors = (
            migration.get("source_anchors", [])
            if isinstance(migration, dict)
            else []
        )
    if not source_anchors:
        source_anchors = source_anchors_for_claims(root, claim_refs)
    android_baseline = (
        migration.get("android_baseline")
        if isinstance(migration, dict)
        else None
    )
    if android_baseline is None and golden_path:
        android_commit = (
            read_json(root / golden_path)
            .get("oracle", {})
            .get("android_git_commit")
        )
        if isinstance(android_commit, str):
            android_baseline = {"android_commit": android_commit}
    delivery_contracts = {
        "DependencyControl": {},
        "SourceRuntime": {
            "goal": (
                "按照冻结 Android 运行结果，在独立 SourceRuntime 中实现该书源能力；"
                "源码对齐为主，结构化测试为辅。"
            ),
            "rule": (
                "SourceRuntime 生成确定性 RequestPlan；Transport 只执行，"
                "UI/Domain 不解释请求语义。"
            ),
            "test_id": "source-runtime-tests",
            "test_filter": "SourceRuntimeTests",
            "acceptance_id": "structured-source-acceptance",
        },
        "ReaderCore": {
            "goal": (
                "按照冻结 Android 运行结果，在 ReaderCore 与 LibraryDomain 的既定"
                "边界内实现阅读能力；源码对齐为主，结构化测试为辅。"
            ),
            "rule": (
                "ReaderCore 只依赖自有 Sendable 领域值和消费方协议；"
                "Android Room、平台数据库与 UI 不进入内核。"
            ),
            "test_id": "reader-core-tests",
            "test_filter": "ReaderCoreTests",
            "acceptance_id": "structured-reader-acceptance",
        },
        "LibraryDomain": {
            "goal": (
                "按照冻结 Android 运行结果实现平台无关领域值与规则；"
                "Record、DTO 与 Domain Model 保持分离。"
            ),
            "rule": (
                "LibraryDomain 只承载平台无关、不可变、Sendable 的领域语义；"
                "数据库查询和 Android Room 留在适配器或验收层。"
            ),
            "test_id": "library-domain-tests",
            "test_filter": "LibraryDomainTests",
            "acceptance_id": "structured-domain-acceptance",
        },
    }
    if architecture["owner"] == "AppNavigation":
        delivery_contract = app_navigation_delivery_contract(
            str(fixture_id)
        )
    else:
        delivery_contract = delivery_contracts.get(
            str(architecture["owner"])
        )
    if delivery_contract is None:
        raise LoopError(f"DELIVERY_CONTRACT_NOT_MAPPED:{architecture['owner']}")
    source = {
        "android_baseline": android_baseline,
        "anchors": source_anchors,
        "fixture_id": fixture_id,
        "android_golden": golden_path,
        "knowledge": {
            "coverage": delivery["ledger_path"],
            "packets": ledger.get("packet_refs", []),
            "driver": driver_ref,
            "claims": claim_refs,
        },
    }
    if isinstance(source_contract, dict):
        source_validation = source_contract.get("validation", "simulator")
        ui_acceptance = (
            delivery_contract.get("ui_acceptance")
            if source_validation == "simulator"
            else None
        )
        if (
            source_validation not in {"build", "simulator", "tests"}
            or source_validation == "simulator"
            and not isinstance(ui_acceptance, dict)
            or source_validation == "tests"
            and (
                not isinstance(source_contract.get("test_filter"), str)
                or not source_contract["test_filter"].strip()
            )
        ):
            raise LoopError("SOURCE_VALIDATION_INVALID")
        source = {
            "authority": "android_source_contract",
            "anchors": source_anchors,
            "fixture_id": fixture_id,
            "source_contract": source_contract,
            "knowledge": {
                "coverage": delivery["ledger_path"],
                "packets": ledger.get("packet_refs", []),
                "driver": driver_ref,
                "claims": claim_refs,
            },
        }
        allowed_paths = list(architecture["allowed_paths"])
        if source_validation in {"build", "tests"}:
            if source_validation == "tests":
                acceptance_command = {
                    "id": "focused-swift-tests",
                    "argv": [
                        "swift",
                        "test",
                        "--package-path",
                        "ios/Packages/LegadoKit",
                        "--disable-automatic-resolution",
                        "--filter",
                        source_contract["test_filter"],
                    ],
                    "required_output_pattern": (
                        r"Executed [1-9][0-9]* tests?, with 0 failures"
                    ),
                    "timeout_seconds": 600,
                }
            else:
                acceptance_command = {
                    "id": "ios-app-build",
                    "argv": [
                        "xcodebuild",
                        "-project",
                        "ios/Apps/Legado/Legado.xcodeproj",
                        "-scheme",
                        "LegadoApp",
                        "-destination",
                        "generic/platform=iOS Simulator",
                        "CODE_SIGNING_ALLOWED=NO",
                        "build",
                    ],
                    "timeout_seconds": 900,
                }
            return {
                "schema_version": SCHEMA_VERSION,
                "id": target,
                "kind": "delivery",
                "title": title,
                "status": "ready",
                "priority": 100,
                "goal": delivery_contract["goal"],
                "source": source,
                "requirements": requirement_refs,
                "architecture": {
                    "owner": architecture["owner"],
                    "refs": architecture["architecture_refs"],
                    "rule": delivery_contract["rule"],
                },
                "scope": {
                    "allowed_paths": allowed_paths,
                    "forbidden": [
                        "Android golden",
                        "accepted Requirement",
                        "架构依赖边",
                        "三方依赖",
                        "切片级 Simulator fixture",
                    ],
                },
                "acceptance": {
                    "profile": "slice",
                    "commands": [acceptance_command],
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
        source["ui_acceptance"] = ui_acceptance
        expected_path = str(ui_acceptance["expected"])
        if expected_path not in allowed_paths:
            allowed_paths.append(expected_path)
        return {
            "schema_version": SCHEMA_VERSION,
            "id": target,
            "kind": "delivery",
            "title": title,
            "status": "ready",
            "priority": 100,
            "goal": delivery_contract["goal"],
            "source": source,
            "requirements": requirement_refs,
            "architecture": {
                "owner": architecture["owner"],
                "refs": architecture["architecture_refs"],
                "rule": delivery_contract["rule"],
            },
            "scope": {
                "allowed_paths": allowed_paths,
                "forbidden": [
                    "Android golden",
                    "accepted Requirement",
                    "架构依赖边",
                    "三方依赖",
                ],
            },
            "acceptance": {
                "profile": "ui_slice",
                "commands": [
                    {
                        "id": "ui-simulator-acceptance",
                        "argv": [
                            "python3",
                            "-B",
                            "ios/harness/ui/ui_simulator.py",
                            "verify",
                            "--root",
                            ".",
                            "--task",
                            "ios/project/loop/task.json",
                        ],
                        "timeout_seconds": 1800,
                    }
                ],
                "structured_output": {
                    "mode": "command_json",
                    "command_id": "ui-simulator-acceptance",
                    "fixture_id": ui_acceptance["scenario_id"],
                    "expected": expected_path,
                    "required_fields": [
                        "expected",
                        "actual",
                        "simulator_matrix",
                        "first_divergence",
                    ],
                    "expected_values": {
                        "scenario_id": ui_acceptance["scenario_id"],
                        "status": "equal",
                        "first_divergence": None,
                    },
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
    if architecture["owner"] == "DependencyControl":
        expected = (
            "ios/harness/dependencies/expected/"
            "dependency-grdb-persistence-v1.json"
        )
        return {
            "schema_version": SCHEMA_VERSION,
            "id": target,
            "kind": "delivery",
            "title": title,
            "status": "ready",
            "priority": 100,
            "goal": (
                "只启用已批准的 GRDB.swift 7.11.1：精确锁定 revision，"
                "物化 DatabaseGRDB 边界和最小冒烟测试，并更新 dependency "
                "policy、lock、baseline、SBOM 与 notices；不实现书架业务。"
            ),
            "source": source,
            "requirements": requirement_refs,
            "architecture": {
                "owner": "DependencyControl",
                "refs": architecture["architecture_refs"],
                "rule": (
                    "本任务只允许一个外部包 GRDB.swift；GRDB 类型只能存在于"
                    " DatabaseGRDB，领域、用例、UI 和 ConformanceCLI 不得导入。"
                ),
            },
            "scope": {
                "allowed_paths": architecture["allowed_paths"],
                "forbidden": [
                    "Android golden",
                    "accepted Requirement",
                    "书架业务实现",
                    "除 GRDB.swift 外的三方依赖",
                ],
            },
            "acceptance": {
                "profile": "checkpoint",
                "commands": [
                    {
                        "id": "dependency-contract",
                        "argv": [
                            "python3",
                            "-B",
                            "ios/harness/probes/dependency_contract.py",
                            "--root",
                            ".",
                        ],
                        "timeout_seconds": 180,
                    },
                    {
                        "id": "package-contract",
                        "argv": [
                            "python3",
                            "-B",
                            "ios/harness/probes/package_contract.py",
                            "--root",
                            ".",
                        ],
                        "timeout_seconds": 180,
                    },
                    {
                        "id": "database-grdb-tests",
                        "argv": [
                            "swift",
                            "test",
                            "--package-path",
                            "ios/Packages/LegadoKit",
                            "--disable-automatic-resolution",
                            "--filter",
                            "DatabaseGRDBTests",
                        ],
                        "required_output_pattern": (
                            r"Executed [1-9][0-9]* tests?, with 0 failures"
                        ),
                        "timeout_seconds": 600,
                    },
                    {
                        "id": "dependency-activation-acceptance",
                        "argv": [
                            "python3",
                            "-B",
                            "ios/harness/probes/dependency_activation.py",
                            "--root",
                            ".",
                        ],
                        "timeout_seconds": 180,
                    },
                ],
                "structured_output": {
                    "mode": "command_json",
                    "command_id": "dependency-activation-acceptance",
                    "fixture_id": "dependency-grdb-persistence-v1",
                    "expected": expected,
                    "required_fields": [
                        "package_identity",
                        "exact_version",
                        "target",
                        "resolved_revision",
                        "first_divergence",
                    ],
                    "expected_values": {
                        "fixture_id": "dependency-grdb-persistence-v1",
                        "status": "equal",
                        "package_identity": "grdb.swift",
                        "exact_version": "7.11.1",
                        "target": "DatabaseGRDB",
                        "first_divergence": None,
                    },
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
    commands = [
        {
            "id": delivery_contract["acceptance_id"],
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
    ]
    ui_acceptance = delivery_contract.get("ui_acceptance")
    allowed_paths = list(architecture["allowed_paths"])
    if isinstance(ui_acceptance, dict):
        source["ui_acceptance"] = ui_acceptance
        expected_path = ui_acceptance.get("expected")
        if (
            isinstance(expected_path, str)
            and expected_path not in allowed_paths
        ):
            allowed_paths.append(expected_path)
        commands.append(
            {
                "id": "ui-simulator-acceptance",
                "argv": [
                    "python3",
                    "-B",
                    "ios/harness/ui/ui_simulator.py",
                    "verify",
                    "--root",
                    ".",
                    "--task",
                    "ios/project/loop/task.json",
                ],
                "timeout_seconds": 1800,
            }
        )
    task = {
        "schema_version": SCHEMA_VERSION,
        "id": target,
        "kind": "delivery",
        "title": title,
        "status": "ready",
        "priority": 100,
        "goal": delivery_contract["goal"],
        "source": source,
        "requirements": requirement_refs,
        "architecture": {
            "owner": architecture["owner"],
            "refs": architecture["architecture_refs"],
            "rule": delivery_contract["rule"],
        },
        "scope": {
            "allowed_paths": allowed_paths,
            "forbidden": [
                "Android golden",
                "accepted Requirement",
                "架构依赖边",
                "三方依赖",
            ],
        },
        "acceptance": {
            "profile": (
                "ui_slice"
                if isinstance(ui_acceptance, dict)
                else "slice"
            ),
            "commands": commands,
            "structured_output": {
                "mode": "command_json",
                "command_id": delivery_contract["acceptance_id"],
                "fixture_id": fixture_id,
                "expected": golden_path,
                "required_fields": [
                    "android_expected",
                    "ios_actual",
                    "canonical_request_plan",
                    "first_divergence",
                ],
                "expected_values": {
                    "fixture_id": fixture_id,
                    "status": "equal",
                    "first_divergence": None,
                },
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
    domain = characterization_contract(claim)
    fixture_id = characterization_fixture_id(
        semantic_key,
        str(domain["fixture_prefix"]),
    )
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
    domain_allowed_paths = [
        str(value)
        for value in domain.get("allowed_paths", [])
        if isinstance(value, str)
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "id": candidate["task_id"],
        "kind": "characterization",
        "title": str(claim.get("topic") or semantic_key),
        "status": "ready",
        "priority": 100,
        "goal": (
            "从冻结 Android 源码声明出发扩展确定性 Characterization 场景，"
            "由真实 Android runner 一次产出结构化 Golden，并记录对应业务"
            "知识与 Coverage；不得用手写 expected 或 iOS 测试替代源码语义。"
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
            "owner": domain["owner"],
            "refs": domain["architecture_refs"],
            "rule": domain["rule"],
        },
        "scope": {
            "allowed_paths": [
                (
                    "ios/harness/fixtures/"
                    f"{domain['fixture_root']}/{fixture_id}/**"
                ),
                "ios/harness/fixtures/manifest.json",
                "ios/harness/source-lab/manifest.json",
                "ios/harness/source-lab/coverage-policy-v1.json",
                "ios/harness/source-lab/source_lab.py",
                "ios/harness/source-lab/tests/test_source_lab.py",
                "ios/harness/schemas/source-lab-scenario.schema.json",
                "ios/harness/android-intake/**",
                "ios/project/android-intake/inventory-manifest.json",
                "ios/project/requirements/catalog.json",
                "ios/harness/oracle/request-registry.json",
                "ios/harness/oracle/scenario_selector.py",
                "ios/harness/oracle/android-runner/**",
                "ios/harness/tests/test_android_oracle_runner.py",
                golden_path,
                "ios/harness/goldens/manifest.json",
                "ios/project/business-knowledge/packets/proposals/**",
                "ios/project/business-knowledge/packets/published/**",
                "ios/project/business-knowledge/drivers/proposals/**",
                "ios/project/business-knowledge/drivers/published/**",
                "ios/project/business-knowledge/coverage/**",
                "ios/project/business-knowledge/catalog.json",
                *domain_allowed_paths,
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
            "profile": "slice",
            "commands": [],
            "structured_output": {
                "mode": "android_golden",
                "fixture_id": fixture_id,
                "expected": golden_path,
                "required_fields": [
                    "artifact.request_plan",
                    "artifact.result.value.portable_known_projection",
                    "oracle.android_git_commit",
                    "oracle.runner_digest",
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
    work = prioritized_work(root)
    if not work:
        return None
    rank, kind, value, selection = work[0]
    task = (
        build_task(root, value)
        if kind == "delivery"
        else build_characterization_task(root, value)
    )
    if selection is None:
        return task
    return {
        **task,
        "priority": 10 + rank[0] * 10 + rank[1],
        "selection": selection,
    }


def queue_status(root: Path) -> Mapping[str, Any]:
    policy = active_priority_policy(root)
    published_deliveries = planned_deliveries(root)
    published_targets = {
        str(value["target"]) for value in published_deliveries
    }
    deliveries = published_deliveries + [
        value
        for value in direct_characterization_deliveries(root)
        if str(value["target"]) not in published_targets
    ]
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in direct_source_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in milestone_completion_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in source_management_milestone_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in shelf_management_milestone_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    known_targets = {str(value["target"]) for value in deliveries}
    deliveries.extend(
        value
        for value in priority_policy_deliveries(root)
        if str(value["target"]) not in known_targets
    )
    characterizations = pending_characterizations(root)
    eligible = prioritized_work(root)
    result: dict[str, Any] = {
        "delivery_count": len(deliveries),
        "characterization_count": len(characterizations),
        "eligible_count": len(eligible),
    }
    if policy is not None:
        result["priority_policy"] = {
            "id": policy["id"],
            "mode": policy["mode"],
            "deferred_count": (
                len(deliveries) + len(characterizations) - len(eligible)
            ),
        }
    return result


def initial_current() -> Mapping[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "idle",
        "active_task": None,
        "attempt": 0,
        "verification": None,
        "last_completed": None,
    }


def project_current(
    events: Sequence[Mapping[str, Any]],
) -> Mapping[str, Any]:
    state = dict(initial_current())
    for event in events:
        event_name = event["event"]
        task_id = event.get("task_id")
        sequence = event["sequence"]
        if event_name == "task_started":
            if state["status"] != "idle" or not isinstance(task_id, str):
                raise LoopError(f"EVENT_TRANSITION_INVALID:{sequence}")
            state = {
                "schema_version": SCHEMA_VERSION,
                "status": "running",
                "active_task": task_id,
                "attempt": 0,
                "verification": None,
                "last_completed": state.get("last_completed"),
            }
        elif event_name in {"verification_passed", "verification_failed"}:
            details = event.get("details")
            expected_passed = event_name == "verification_passed"
            if (
                state["status"] not in {"running", "verified"}
                or state["active_task"] != task_id
                or not isinstance(details, dict)
                or details.get("passed") is not expected_passed
                or not isinstance(details.get("attempt"), int)
                or isinstance(details.get("attempt"), bool)
                or details["attempt"] <= int(state["attempt"])
            ):
                raise LoopError(f"EVENT_TRANSITION_INVALID:{sequence}")
            state = {
                **state,
                "status": "verified" if expected_passed else "running",
                "attempt": details["attempt"],
                "verification": details,
            }
        elif event_name == "task_completed":
            details = event.get("details")
            if (
                state["status"] != "verified"
                or state["active_task"] != task_id
                or not isinstance(task_id, str)
                or not isinstance(details, dict)
            ):
                raise LoopError(f"EVENT_TRANSITION_INVALID:{sequence}")
            required_memory = {
                "summary": str,
                "current_status": str,
                "architecture_change": str,
                "pitfalls": list,
                "next_step": str,
            }
            if any(
                not isinstance(details.get(field), expected_type)
                for field, expected_type in required_memory.items()
            ):
                raise LoopError(f"EVENT_MEMORY_INVALID:{sequence}")
            state = {
                "schema_version": SCHEMA_VERSION,
                "status": "idle",
                "active_task": None,
                "attempt": 0,
                "verification": None,
                "last_completed": {
                    "task_id": task_id,
                    "sequence": sequence,
                    "at": event["at"],
                },
            }
        elif event_name == "task_superseded":
            details = event.get("details")
            if (
                state["status"] not in {"running", "verified"}
                or state["active_task"] != task_id
                or not isinstance(task_id, str)
                or not isinstance(details, dict)
                or not isinstance(details.get("reason"), str)
                or not details["reason"].strip()
                or not isinstance(details.get("replacement"), str)
                or not details["replacement"].strip()
            ):
                raise LoopError(f"EVENT_TRANSITION_INVALID:{sequence}")
            state = {
                "schema_version": SCHEMA_VERSION,
                "status": "idle",
                "active_task": None,
                "attempt": 0,
                "verification": None,
                "last_completed": {
                    "task_id": task_id,
                    "sequence": sequence,
                    "at": event["at"],
                    "outcome": "superseded",
                },
            }
    return state


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
    authority = source.get("authority", "android_golden")
    if authority == "android_golden":
        golden = source.get("android_golden")
        if not isinstance(golden, str):
            raise LoopError("TASK_SOURCE_MISSING:android_golden")
        if task.get("kind") == "delivery" and not (root / golden).is_file():
            raise LoopError("TASK_SOURCE_MISSING:android_golden")
    elif authority == "ios_product_decision":
        decision_refs = source.get("decision_refs")
        ui_acceptance = source.get("ui_acceptance")
        expected = (
            ui_acceptance.get("expected")
            if isinstance(ui_acceptance, dict)
            else None
        )
        if (
            task.get("kind") != "delivery"
            or not isinstance(decision_refs, list)
            or not decision_refs
            or any(not isinstance(value, str) for value in decision_refs)
            or not isinstance(expected, str)
            or not (root / expected).is_file()
        ):
            raise LoopError("TASK_SOURCE_INVALID:ios_product_decision")
    elif authority == "android_source_contract":
        source_contract = source.get("source_contract")
        anchors = source.get("anchors")
        ui_acceptance = source.get("ui_acceptance")
        expected = (
            ui_acceptance.get("expected")
            if isinstance(ui_acceptance, dict)
            else None
        )
        if (
            task.get("kind") != "delivery"
            or not isinstance(source_contract, dict)
            or not isinstance(source_contract.get("path"), str)
            or not (root / source_contract["path"]).is_file()
            or not isinstance(anchors, list)
            or not anchors
            or (
                ui_acceptance is not None
                and (
                    not isinstance(ui_acceptance, dict)
                    or not isinstance(expected, str)
                )
            )
        ):
            raise LoopError("TASK_SOURCE_INVALID:android_source_contract")
    else:
        raise LoopError("TASK_SOURCE_AUTHORITY_INVALID")
    acceptance = task.get("acceptance")
    commands = (
        acceptance.get("commands")
        if isinstance(acceptance, dict)
        else None
    )
    structured = (
        acceptance.get("structured_output")
        if isinstance(acceptance, dict)
        else None
    )
    validation_profile = (
        acceptance.get("profile")
        if isinstance(acceptance, dict)
        else None
    )
    if (
        not isinstance(commands, list)
        or (
            not commands
            and not (
                task.get("kind") == "characterization"
                and isinstance(structured, dict)
                and structured.get("mode") == "android_golden"
            )
        )
    ):
        raise LoopError("TASK_ACCEPTANCE_INVALID")
    if structured is not None and (
        not isinstance(structured, dict)
        or structured.get("mode")
        not in {
            "command_json",
            "android_golden",
            "architecture_decision",
        }
        or not isinstance(structured.get("fixture_id"), str)
        or not isinstance(structured.get("expected"), str)
        or not isinstance(structured.get("required_fields"), list)
        or not structured["required_fields"]
        or not all(
            isinstance(value, str) and value
            for value in structured["required_fields"]
        )
    ):
        raise LoopError("TASK_ACCEPTANCE_INVALID")
    if validation_profile not in {
        None,
        "slice",
        "ui_slice",
        "checkpoint",
    }:
        raise LoopError("TASK_ACCEPTANCE_INVALID")
    command_ids = [
        command.get("id")
        for command in commands
        if isinstance(command, dict)
    ]
    if (
        len(command_ids) != len(commands)
        or not all(isinstance(value, str) and value for value in command_ids)
        or not all(
            re.fullmatch(r"[A-Za-z0-9._-]+", value)
            for value in command_ids
        )
        or len(set(command_ids)) != len(command_ids)
    ):
        raise LoopError("TASK_ACCEPTANCE_INVALID")
    architecture_owner = task.get("architecture", {}).get("owner")
    if (
        task["kind"] == "delivery"
        and architecture_owner == "ArchitectureControl"
        and (
            not isinstance(structured, dict)
            or structured.get("mode") != "architecture_decision"
        )
    ) or (
        task["kind"] == "delivery"
        and architecture_owner != "ArchitectureControl"
        and isinstance(structured, dict)
        and structured.get("mode") != "command_json"
    ) or (
        task["kind"] == "characterization"
        and (
            not isinstance(structured, dict)
            or structured.get("mode") != "android_golden"
        )
    ):
        raise LoopError("TASK_ACCEPTANCE_INVALID")
    if (
        isinstance(structured, dict)
        and structured.get("mode") == "command_json"
    ):
        expected_values = structured.get("expected_values")
        if (
            structured.get("command_id") not in command_ids
            or not isinstance(expected_values, dict)
            or not expected_values
        ):
            raise LoopError("TASK_ACCEPTANCE_INVALID")
    knowledge_updates = task.get("knowledge_updates")
    required_memory = (
        knowledge_updates.get("required_on_completion")
        if isinstance(knowledge_updates, dict)
        else None
    )
    if required_memory != [
        "summary",
        "current_status",
        "architecture_change",
        "pitfalls",
        "next_step",
    ]:
        raise LoopError("TASK_KNOWLEDGE_INVALID")


def doctor(root: Path) -> Mapping[str, Any]:
    active_priority_policy(root)
    state = current(root)
    events = load_events(root)
    projected = project_current(events)
    if state != projected:
        raise LoopError("CURRENT_EVENT_PROJECTION_DRIFT")
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
        "queue": queue_status(root),
    }


def reconcile(root: Path) -> Mapping[str, Any]:
    events = load_events(root)
    projected = project_current(events)
    task_path = root / TASK_PATH
    repairs = []
    if projected["status"] == "idle":
        if task_path.exists():
            task_path.unlink()
            repairs.append("removed_orphan_task")
    else:
        if not task_path.is_file():
            raise LoopError("ACTIVE_TASK_MISSING")
        task = read_json(task_path)
        validate_task(root, task)
        if task.get("id") != projected["active_task"]:
            raise LoopError("ACTIVE_TASK_ID_DRIFT")
        if (
            projected.get("status") == "running"
            and projected.get("attempt") == 0
            and projected.get("verification") is None
            and not git(root, "status", "--porcelain")
        ):
            head = git(root, "rev-parse", "HEAD")
            if task.get("base_commit") != head:
                task = dict(task)
                task["base_commit"] = head
                write_json(task_path, task)
                repairs.append("rebased_unstarted_task")
    try:
        state = current(root)
    except LoopError:
        state = None
    if state != projected:
        write_json(root / CURRENT_PATH, projected)
        repairs.append("rebuilt_current_projection")
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "reconciled" if repairs else "unchanged",
        "repairs": repairs,
        "current": projected,
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


def json_field(
    document: Mapping[str, Any],
    field: str,
) -> tuple[bool, Any]:
    value: Any = document
    for component in field.split("."):
        if not isinstance(value, dict) or component not in value:
            return False, None
        value = value[component]
    return True, value


def validate_command_json(
    runtime: Path,
    contract: Mapping[str, Any],
) -> tuple[list[str], str | None]:
    command_id = str(contract["command_id"])
    stdout_path = runtime / f"{command_id}.stdout"
    try:
        payload = stdout_path.read_bytes()
        document = json.loads(payload)
    except (OSError, UnicodeError, json.JSONDecodeError):
        return ["command_stdout_invalid_json"], None
    if not isinstance(document, dict):
        return ["command_stdout_not_object"], digest(payload)
    failures = [
        f"missing:{field}"
        for field in contract["required_fields"]
        if not json_field(document, field)[0]
    ]
    for field, expected in contract["expected_values"].items():
        present, actual = json_field(document, field)
        if not present:
            failures.append(f"missing:{field}")
        elif actual != expected:
            failures.append(f"mismatch:{field}")
    return sorted(set(failures)), digest(payload)


def validate_android_golden(
    root: Path,
    contract: Mapping[str, Any],
) -> tuple[list[str], str | None]:
    fixture_id = str(contract["fixture_id"])
    golden_relative = str(contract["expected"])
    golden_path = root / golden_relative
    try:
        payload = golden_path.read_bytes()
        golden = json.loads(payload)
    except (OSError, UnicodeError, json.JSONDecodeError):
        return ["golden_invalid_or_missing"], None
    if not isinstance(golden, dict):
        return ["golden_not_object"], digest(payload)
    failures = [
        f"missing:{field}"
        for field in contract["required_fields"]
        if not json_field(golden, field)[0]
    ]
    if golden.get("fixture_id") != fixture_id:
        failures.append("mismatch:fixture_id")
    present, artifact_fixture = json_field(golden, "artifact.fixture_id")
    if not present or artifact_fixture != fixture_id:
        failures.append("mismatch:artifact.fixture_id")
    golden_sha256 = digest(payload)
    return sorted(set(failures)), golden_sha256


def validate_architecture_decision(
    root: Path,
    task: Mapping[str, Any],
    contract: Mapping[str, Any],
) -> tuple[list[str], str | None]:
    failures: list[str] = []
    decision = task.get("source", {}).get("architecture_decision", {})
    decision_id = decision.get("id")
    expected_path = decision.get("path")
    initial_driver = decision.get("initial_driver", {})
    required_targets = decision.get("required_targets", {})
    if (
        decision_id != contract.get("fixture_id")
        or expected_path != contract.get("expected")
        or not isinstance(initial_driver, dict)
        or not isinstance(required_targets, dict)
        or not required_targets
    ):
        return ["architecture_contract_invalid"], None

    adr_path = root / str(expected_path)
    try:
        adr_payload = adr_path.read_bytes()
        adr_text = adr_payload.decode("utf-8")
    except (OSError, UnicodeError):
        return ["adr_invalid_or_missing"], None
    frontmatter_match = re.match(
        r"\A---\n(?P<body>.*?)\n---\n",
        adr_text,
        re.DOTALL,
    )
    metadata = {}
    if frontmatter_match:
        metadata = {
            key.strip(): value.strip()
            for line in frontmatter_match.group("body").splitlines()
            for key, separator, value in [line.partition(":")]
            if separator
        }
    if metadata.get("id") != decision_id:
        failures.append("mismatch:adr.id")
    if metadata.get("status") != "accepted":
        failures.append("mismatch:adr.status")
    for section in (
        "Context",
        "Decision",
        "Alternatives",
        "Consequences",
        "Architecture / Capability Impact",
        "Compatibility / Data Migration",
        "Validation",
        "Rollback",
        "Human Review",
    ):
        if f"## {section}" not in adr_text:
            failures.append(f"missing:adr.section.{section}")
    if decision.get("third_party_policy") == "foundation_only_initially":
        for marker in (
            "首版不引入 WebDAV 三方库",
            "URLSession",
            "XMLParser",
        ):
            if marker not in adr_text:
                failures.append(f"missing:adr.dependency.{marker}")
    try:
        architecture_text = (
            root / "ios/docs/architecture.md"
        ).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        architecture_text = ""
    if str(decision_id) not in architecture_text:
        failures.append("missing:architecture.adr")

    driver_id = initial_driver.get("id")
    initial_revision = initial_driver.get("revision")
    drivers = []
    if isinstance(driver_id, str):
        for path in sorted(
            (
                root
                / "ios/project/business-knowledge/drivers/published"
                / driver_id
            ).glob("r*.json")
        ):
            try:
                value = read_json(path)
            except LoopError:
                continue
            if value.get("id") == driver_id and isinstance(
                value.get("revision"), int
            ):
                drivers.append((value["revision"], value))
    driver = max(drivers, default=(0, {}), key=lambda value: value[0])[1]
    driver_revision = driver.get("revision")
    if (
        not isinstance(initial_revision, int)
        or not isinstance(driver_revision, int)
        or driver_revision <= initial_revision
        or driver.get("status") != "resolved"
        or driver.get("resolution", {}).get("state") != "resolved"
        or decision_id
        not in driver.get("resolution", {}).get("adr_refs", [])
        or driver.get("supersedes") != initial_driver
    ):
        failures.append("driver_not_resolved")

    knowledge = task.get("source", {}).get("knowledge", {})
    claim_refs = knowledge.get("claims", [])
    coverage_path = knowledge.get("coverage")
    wanted_claims = {
        (value.get("id"), value.get("revision"))
        for value in claim_refs
        if isinstance(value, dict)
    }
    entries = []
    if isinstance(coverage_path, str):
        try:
            ledger = read_json(root / coverage_path)
            entries = [
                value
                for value in ledger.get("entries", [])
                if isinstance(value, dict)
                and isinstance(value.get("claim_ref"), dict)
                and (
                    value["claim_ref"].get("id"),
                    value["claim_ref"].get("revision"),
                )
                in wanted_claims
            ]
        except LoopError:
            entries = []
    if len(entries) != 1:
        failures.append("coverage_binding_invalid")
    else:
        entry = entries[0]
        disposition = entry.get("product_disposition", {})
        delivery = entry.get("delivery", {})
        expected_driver = f"{driver_id}@{driver_revision}"
        if expected_driver not in disposition.get("refs", []):
            failures.append("coverage_driver_stale")
        if delivery.get("state") == "planned":
            if (
                task.get("id") in delivery.get("work_item_refs", [])
                or not delivery.get("work_item_refs")
                or not delivery.get("requirement_refs")
            ):
                failures.append("product_delivery_not_authorized")
        elif delivery.get("state") != "not_ready":
            failures.append("coverage_delivery_invalid")

    try:
        rules = read_json(root / "ios/harness/architecture-rules.json")
    except LoopError:
        rules = {}
    known_modules = rules.get("known_project_modules", [])
    target_rules = rules.get("targets", {})
    observed_targets = {}
    for target, dependencies in required_targets.items():
        target_rule = (
            target_rules.get(target)
            if isinstance(target_rules, dict)
            else None
        )
        if (
            target not in known_modules
            or not isinstance(target_rule, dict)
            or target_rule.get("dependencies") != dependencies
            or f"`{target}`" not in architecture_text
        ):
            failures.append(f"dependency_mismatch:{target}")
        else:
            observed_targets[target] = dependencies
    projection = {
        "decision": {"id": decision_id, "status": metadata.get("status")},
        "driver": {"id": driver_id, "revision": driver_revision},
        "dependency_contract": observed_targets,
    }
    return sorted(set(failures)), digest(canonical(projection))


def validate_structured_output(
    root: Path,
    task: Mapping[str, Any],
    runtime: Path,
) -> Mapping[str, Any]:
    contract = task["acceptance"]["structured_output"]
    mode = contract["mode"]
    if mode == "command_json":
        failures, observed_sha256 = validate_command_json(
            runtime,
            contract,
        )
    elif mode == "android_golden":
        failures, observed_sha256 = validate_android_golden(
            root,
            contract,
        )
    elif mode == "architecture_decision":
        failures, observed_sha256 = validate_architecture_decision(
            root,
            task,
            contract,
        )
    else:
        raise LoopError("TASK_ACCEPTANCE_INVALID")
    passed = not failures
    result: dict[str, Any] = {
        "id": "structured-output-contract",
        "exit_code": 0 if passed else 1,
        "structured_output_passed": passed,
        "mode": mode,
    }
    if observed_sha256 is not None:
        result["observed_sha256"] = observed_sha256
    if failures:
        result["failures"] = failures
    return result


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
        if re.fullmatch(r"[A-Za-z0-9._-]+", check_id) is None:
            raise LoopError(f"ACCEPTANCE_COMMAND_INVALID:{check_id}")
        (runtime / f"{check_id}.stdout").write_bytes(stdout)
        (runtime / f"{check_id}.stderr").write_bytes(stderr)
        result_record = {
            "id": check_id,
            "exit_code": exit_code,
            "stdout_sha256": digest(stdout),
            "stderr_sha256": digest(stderr),
        }
        required_output_pattern = check.get("required_output_pattern")
        output_assertion_passed = True
        if required_output_pattern is not None:
            if not isinstance(required_output_pattern, str):
                raise LoopError(
                    f"ACCEPTANCE_OUTPUT_PATTERN_INVALID:{check_id}"
                )
            try:
                output_assertion_passed = (
                    re.search(
                        required_output_pattern,
                        (stdout + b"\n" + stderr).decode(
                            "utf-8",
                            errors="replace",
                        ),
                    )
                    is not None
                )
            except re.error as error:
                raise LoopError(
                    f"ACCEPTANCE_OUTPUT_PATTERN_INVALID:{check_id}"
                ) from error
            result_record["output_assertion_passed"] = (
                output_assertion_passed
            )
        results.append(result_record)
        if exit_code != 0 or not output_assertion_passed:
            passed = False
            break
    if passed and isinstance(
        task.get("acceptance", {}).get("structured_output"),
        dict,
    ):
        structured_result = validate_structured_output(
            root,
            task,
            runtime,
        )
        results.append(structured_result)
        passed = structured_result["structured_output_passed"] is True
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
    current_status: str,
    architecture_change: str,
    pitfall: Sequence[str],
    next_step: str,
) -> Mapping[str, Any]:
    if (
        not isinstance(summary, str)
        or not summary.strip()
        or not isinstance(current_status, str)
        or not current_status.strip()
        or not isinstance(architecture_change, str)
        or not architecture_change.strip()
        or not isinstance(next_step, str)
        or not next_step.strip()
        or any(
            not isinstance(value, str) or not value.strip()
            for value in pitfall
        )
    ):
        raise LoopError("COMPLETION_KNOWLEDGE_INVALID")
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
        "current_status": current_status,
        "architecture_change": architecture_change,
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


def supersede(
    root: Path,
    *,
    reason: str,
    replacement: str,
    replacement_evidence: str | None = None,
) -> Mapping[str, Any]:
    if not reason.strip() or not replacement.strip():
        raise LoopError("SUPERSEDE_REASON_INVALID")
    reconcile(root)
    state = current(root)
    if state["status"] not in {"running", "verified"}:
        raise LoopError("NO_ACTIVE_TASK")
    task = read_json(root / TASK_PATH)
    details: dict[str, Any] = {
        "reason": reason.strip(),
        "replacement": replacement.strip(),
    }
    if replacement_evidence is not None:
        evidence = replacement_evidence.strip()
        if not evidence or not (root / evidence).is_file():
            raise LoopError("SUPERSEDE_EVIDENCE_INVALID")
        details["replacement_evidence"] = evidence
    knowledge_updates = task.get("knowledge_updates")
    if isinstance(knowledge_updates, dict):
        candidate_refs = knowledge_updates.get("candidate_claim_refs")
        if isinstance(candidate_refs, list) and candidate_refs:
            details["knowledge"] = {
                "candidate_claim_refs": candidate_refs,
            }
    event = append_event(
        root,
        "task_superseded",
        task_id=str(task["id"]),
        details=details,
    )
    (root / TASK_PATH).unlink()
    write_json(
        root / CURRENT_PATH,
        project_current(load_events(root)),
    )
    return event


def advance(
    root: Path,
    *,
    summary: str | None = None,
    current_status: str | None = None,
    architecture_change: str | None = None,
    pitfall: Sequence[str] = (),
    next_step: str | None = None,
) -> Mapping[str, Any]:
    reconciliation = reconcile(root)
    doctor(root)
    state = current(root)
    if state["status"] == "idle":
        task = next_task(root)
        if task is None:
            return {
                "schema_version": SCHEMA_VERSION,
                "status": "queue_empty",
                "action": "done",
                "queue": queue_status(root),
                "reconciliation": reconciliation,
            }
        started = start(root)
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "running",
            "action": "implement",
            "task": started,
            "reconciliation": reconciliation,
        }

    task = read_json(root / TASK_PATH)
    paths = changed_paths(root, str(task["base_commit"]))
    work_paths = [
        path
        for path in paths
        if path not in CONTROL_PATHS
        and not path.startswith(".harness-runtime/")
    ]
    verification = state.get("verification")
    workspace_sha256 = workspace_digest(root, paths)
    if state["status"] == "verified" and isinstance(verification, dict):
        if workspace_sha256 == verification.get("workspace_sha256"):
            memory_supplied = any(
                value is not None
                for value in (
                    summary,
                    current_status,
                    architecture_change,
                    next_step,
                )
            ) or bool(pitfall)
            if not memory_supplied:
                return {
                    "schema_version": SCHEMA_VERSION,
                    "status": "verified",
                    "action": "record_completion",
                    "task_id": task["id"],
                    "required_knowledge": task["knowledge_updates"][
                        "required_on_completion"
                    ],
                    "verification": verification,
                    "reconciliation": reconciliation,
                }
            completed = complete(
                root,
                summary=summary or "",
                current_status=current_status or "",
                architecture_change=architecture_change or "",
                pitfall=pitfall,
                next_step=next_step or "",
            )
            next_task_value = next_task(root)
            if next_task_value is None:
                return {
                    "schema_version": SCHEMA_VERSION,
                    "status": "queue_empty",
                    "action": "done",
                    "completed": completed,
                    "queue": queue_status(root),
                    "reconciliation": reconciliation,
                }
            started = start(root)
            return {
                "schema_version": SCHEMA_VERSION,
                "status": "running",
                "action": "implement",
                "completed": completed,
                "task": started,
                "reconciliation": reconciliation,
            }

    if (
        state["status"] == "running"
        and isinstance(verification, dict)
        and verification.get("passed") is False
        and workspace_sha256 == verification.get("workspace_sha256")
    ):
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "verification_failed",
            "action": "repair",
            "task_id": task["id"],
            "verification": verification,
            "reconciliation": reconciliation,
        }
    if not work_paths:
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "running",
            "action": "implement",
            "task": task,
            "reconciliation": reconciliation,
        }

    result = verify(root)
    memory_supplied = any(
        value is not None
        for value in (
            summary,
            current_status,
            architecture_change,
            next_step,
        )
    ) or bool(pitfall)
    if result["passed"] and memory_supplied:
        return advance(
            root,
            summary=summary,
            current_status=current_status,
            architecture_change=architecture_change,
            pitfall=pitfall,
            next_step=next_step,
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "status": "verified" if result["passed"] else "verification_failed",
        "action": "record_completion" if result["passed"] else "repair",
        "task_id": task["id"],
        "verification": result,
        "reconciliation": reconciliation,
    }


def output(value: Any) -> None:
    sys.stdout.buffer.write(canonical(value))


def dispatch(root: Path, args: argparse.Namespace) -> Mapping[str, Any]:
    if args.command == "doctor":
        return doctor(root)
    if args.command == "status":
        return current(root)
    if args.command == "next":
        return next_task(root) or {
            "schema_version": SCHEMA_VERSION,
            "status": "queue_empty",
            "queue": queue_status(root),
        }
    if args.command == "start":
        return start(root)
    if args.command == "verify":
        return verify(root)
    if args.command == "reconcile":
        return reconcile(root)
    if args.command == "complete":
        return complete(
            root,
            summary=args.summary,
            current_status=args.current_status,
            architecture_change=args.architecture_change,
            pitfall=args.pitfall,
            next_step=args.next_step,
        )
    if args.command == "supersede":
        return supersede(
            root,
            reason=args.reason,
            replacement=args.replacement,
            replacement_evidence=args.replacement_evidence,
        )
    if args.command == "advance":
        return advance(
            root,
            summary=args.summary,
            current_status=args.current_status,
            architecture_change=args.architecture_change,
            pitfall=args.pitfall,
            next_step=args.next_step,
        )
    raise AssertionError(args.command)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor")
    subparsers.add_parser("status")
    subparsers.add_parser("next")
    subparsers.add_parser("start")
    subparsers.add_parser("verify")
    subparsers.add_parser("reconcile")
    complete_parser = subparsers.add_parser("complete")
    complete_parser.add_argument("--summary", required=True)
    complete_parser.add_argument("--current-status", required=True)
    complete_parser.add_argument("--architecture-change", required=True)
    complete_parser.add_argument("--pitfall", action="append", default=[])
    complete_parser.add_argument("--next-step", required=True)
    supersede_parser = subparsers.add_parser("supersede")
    supersede_parser.add_argument("--reason", required=True)
    supersede_parser.add_argument("--replacement", required=True)
    supersede_parser.add_argument("--replacement-evidence")
    advance_parser = subparsers.add_parser("advance")
    advance_parser.add_argument("--summary")
    advance_parser.add_argument("--current-status")
    advance_parser.add_argument("--architecture-change")
    advance_parser.add_argument("--pitfall", action="append", default=[])
    advance_parser.add_argument("--next-step")
    args = parser.parse_args(argv)
    try:
        root = repository_root(args.root.resolve())
        if args.command in {
            "start",
            "verify",
            "reconcile",
            "complete",
            "supersede",
            "advance",
        }:
            with exclusive_lock(root):
                value = dispatch(root, args)
        else:
            value = dispatch(root, args)
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
