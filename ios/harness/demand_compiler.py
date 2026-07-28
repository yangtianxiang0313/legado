#!/usr/bin/env python3
"""Compile committed delivery intents into deterministic prerequisite plans."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple


INTENT_ROOT = "ios/project/delivery-intents"
MIGRATION_INTENT_ROOT = "ios/project/migration-intents"
REQUIREMENT_CATALOG = "ios/project/requirements/catalog.json"
KNOWLEDGE_CATALOG = "ios/project/business-knowledge/catalog.json"
GOLDEN_MANIFEST = "ios/harness/goldens/manifest.json"
DELIVERY_BLUEPRINT_ROOT = "ios/project/work-item-proposals/delivery-blueprints"
MIGRATION_BLUEPRINT_ROOT = (
    "ios/project/work-item-proposals/migration-blueprints"
)
BASELINE_PATH = "ios/project/baseline.json"
SOURCE_LAB_COVERAGE_POLICY = (
    "ios/harness/source-lab/coverage-policy-v1.json"
)
STATE_PATH = "ios/project/state.json"
WORK_ITEM_ROOT = "ios/harness/work-items"
CHECKPOINT_ROOT = "ios/project/checkpoints"
EVIDENCE_ROOT = "ios/harness/evidence/runs"
POLICY = "structured-delivery-intent-v1"
MIGRATION_POLICY = "source-anchored-android-migration-v1"
INTENT_ID = re.compile(r"^DINT-[A-Z][A-Z0-9-]*-[0-9]{3}$")
MIGRATION_INTENT_ID = re.compile(r"^MINT-[A-Z][A-Z0-9-]*-[0-9]{3}$")
WORK_ITEM_ID = re.compile(r"^IOS-[A-Z][A-Z0-9-]*-[0-9]{3}$")
REQUIREMENT_ID = re.compile(r"^REQ-[A-Z0-9-]+$")
REQUIREMENT_PROPOSAL_ID = re.compile(r"^ARQ-[A-Z][A-Z0-9-]*$")
CAPABILITY_ID = re.compile(r"^CAP-[A-Z0-9-]+$")
KNOWLEDGE_ID = re.compile(r"^(BKP|DRV)-[A-Z][A-Z0-9-]*-[0-9]{3}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")


class DemandCompilerError(RuntimeError):
    pass


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_json(value: Any) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return _sha256(payload)


def _load_object(path: Path, reason: str) -> Dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise DemandCompilerError(f"{reason}_NOT_REGULAR")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DemandCompilerError(f"{reason}_INVALID:{error}") from error
    if not isinstance(value, dict):
        raise DemandCompilerError(f"{reason}_INVALID")
    return value


@dataclass(frozen=True)
class DemandPlan:
    intent_id: str
    priority: int
    target_work_item_id: str
    state: str
    reason_code: str
    authority_transition: bool
    artifacts: Tuple[Mapping[str, Any], ...]
    bindings: Mapping[str, Any]
    policy: str = POLICY
    intent_kind: str = "delivery"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": 1,
            "policy": self.policy,
            "intent_kind": self.intent_kind,
            "intent_id": self.intent_id,
            "priority": self.priority,
            "target_work_item_id": self.target_work_item_id,
            "state": self.state,
            "reason_code": self.reason_code,
            "authority_transition": self.authority_transition,
            "artifacts": [dict(value) for value in self.artifacts],
            "bindings": dict(self.bindings),
        }


class DemandCompiler:
    def __init__(self, root: Path):
        self.root = root.resolve()

    def resolve(self, relative: str) -> Path:
        candidate = (self.root / relative).resolve()
        try:
            candidate.relative_to(self.root)
        except ValueError as error:
            raise DemandCompilerError("PATH_OUTSIDE_REPOSITORY") from error
        return candidate

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            ["git", *arguments],
            cwd=str(self.root),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def _head_regular(self, relatives: Sequence[str]) -> None:
        for relative in relatives:
            path = self.resolve(relative)
            if path.is_symlink() or not path.is_file():
                raise DemandCompilerError(
                    f"DEMAND_INPUT_NOT_REGULAR:{relative}"
                )
            listing = self._git("ls-tree", "HEAD", "--", relative)
            if listing.returncode != 0 or not listing.stdout:
                raise DemandCompilerError(
                    f"DEMAND_INPUT_NOT_IN_HEAD:{relative}"
                )
            mode = listing.stdout.decode("utf-8").split(None, 1)[0]
            if mode not in {"100644", "100755"}:
                raise DemandCompilerError(
                    f"DEMAND_INPUT_HEAD_MODE_INVALID:{relative}"
                )
            head_payload = self._git("show", f"HEAD:{relative}")
            if (
                head_payload.returncode != 0
                or head_payload.stdout != path.read_bytes()
            ):
                raise DemandCompilerError(
                    f"DEMAND_INPUT_HEAD_DRIFT:{relative}"
                )

    @staticmethod
    def _selector(
        value: Any,
        *,
        label: str,
        identifier_pattern: re.Pattern[str],
    ) -> Tuple[str, int]:
        if not isinstance(value, dict) or set(value) != {"id", "revision"}:
            raise DemandCompilerError(
                f"INTENT_{label}_SELECTOR_INVALID"
            )
        identifier = value.get("id")
        revision = value.get("revision")
        if (
            not isinstance(identifier, str)
            or identifier_pattern.fullmatch(identifier) is None
            or not isinstance(revision, int)
            or isinstance(revision, bool)
            or revision < 1
        ):
            raise DemandCompilerError(
                f"INTENT_{label}_SELECTOR_INVALID"
            )
        return identifier, revision

    def _validate_intent(
        self,
        intent: Mapping[str, Any],
        relative: str,
    ) -> None:
        required = {
            "schema_version",
            "kind",
            "id",
            "priority",
            "target_work_item_id",
            "capability",
            "requirements",
            "knowledge",
            "golden_fixtures",
            "blueprint",
        }
        if set(intent) != required:
            raise DemandCompilerError("INTENT_FIELDS_INVALID")
        intent_id = intent.get("id")
        target = intent.get("target_work_item_id")
        priority = intent.get("priority")
        if (
            intent.get("schema_version") != 1
            or intent.get("kind") != "DeliveryIntent"
            or not isinstance(intent_id, str)
            or INTENT_ID.fullmatch(intent_id) is None
            or relative != f"{INTENT_ROOT}/{intent_id}.json"
            or not isinstance(target, str)
            or WORK_ITEM_ID.fullmatch(target) is None
            or not isinstance(priority, int)
            or isinstance(priority, bool)
            or not 0 <= priority <= 100
        ):
            raise DemandCompilerError("INTENT_IDENTITY_INVALID")
        capability = intent.get("capability")
        if (
            not isinstance(capability, dict)
            or set(capability) != {"id", "revision"}
        ):
            raise DemandCompilerError("INTENT_CAPABILITY_INVALID")
        capability_id, _ = self._selector(
            capability,
            label="CAPABILITY",
            identifier_pattern=CAPABILITY_ID,
        )
        if not capability_id:
            raise DemandCompilerError("INTENT_CAPABILITY_INVALID")
        requirements = intent.get("requirements")
        if not isinstance(requirements, list) or not requirements:
            raise DemandCompilerError("INTENT_REQUIREMENTS_INVALID")
        seen_requirements = set()
        for reference in requirements:
            if (
                not isinstance(reference, dict)
                or set(reference) != {"id", "revision", "clauses"}
            ):
                raise DemandCompilerError("INTENT_REQUIREMENTS_INVALID")
            identifier = reference.get("id")
            revision = reference.get("revision")
            clauses = reference.get("clauses")
            key = (identifier, revision)
            if (
                not isinstance(identifier, str)
                or REQUIREMENT_ID.fullmatch(identifier) is None
                or not isinstance(revision, int)
                or isinstance(revision, bool)
                or revision < 1
                or not isinstance(clauses, list)
                or not clauses
                or len(clauses) != len(set(clauses))
                or any(
                    not isinstance(clause, str)
                    or re.fullmatch(r"RC-[0-9]{2}", clause) is None
                    for clause in clauses
                )
                or key in seen_requirements
            ):
                raise DemandCompilerError("INTENT_REQUIREMENTS_INVALID")
            seen_requirements.add(key)
        knowledge = intent.get("knowledge")
        if (
            not isinstance(knowledge, dict)
            or set(knowledge) != {"packets", "drivers"}
        ):
            raise DemandCompilerError("INTENT_KNOWLEDGE_INVALID")
        seen_knowledge = set()
        for label in ("packets", "drivers"):
            selectors = knowledge.get(label)
            if not isinstance(selectors, list) or not selectors:
                raise DemandCompilerError("INTENT_KNOWLEDGE_INVALID")
            for selector in selectors:
                key = self._selector(
                    selector,
                    label="KNOWLEDGE",
                    identifier_pattern=KNOWLEDGE_ID,
                )
                expected_prefix = "BKP-" if label == "packets" else "DRV-"
                if not key[0].startswith(expected_prefix) or key in seen_knowledge:
                    raise DemandCompilerError("INTENT_KNOWLEDGE_INVALID")
                seen_knowledge.add(key)
        fixtures = intent.get("golden_fixtures")
        if (
            not isinstance(fixtures, list)
            or not fixtures
            or len(fixtures) != len(set(fixtures))
            or any(not isinstance(value, str) or not value for value in fixtures)
        ):
            raise DemandCompilerError("INTENT_GOLDEN_SELECTOR_INVALID")
        expected_blueprint = (
            f"{DELIVERY_BLUEPRINT_ROOT}/{target}.json"
        )
        if intent.get("blueprint") != expected_blueprint:
            raise DemandCompilerError("INTENT_BLUEPRINT_PATH_INVALID")

    def _validate_migration_intent(
        self,
        intent: Mapping[str, Any],
        relative: str,
    ) -> None:
        required = {
            "schema_version",
            "kind",
            "id",
            "priority",
            "phase",
            "target_work_item_id",
            "capability",
            "android_baseline",
            "source_anchors",
            "source_lab",
            "requirement_proposal",
            "intake_blueprint",
        }
        if set(intent) != required:
            raise DemandCompilerError("MIGRATION_INTENT_FIELDS_INVALID")
        intent_id = intent.get("id")
        target = intent.get("target_work_item_id")
        priority = intent.get("priority")
        phase = intent.get("phase")
        if (
            intent.get("schema_version") != 1
            or intent.get("kind") != "AndroidMigrationIntent"
            or not isinstance(intent_id, str)
            or MIGRATION_INTENT_ID.fullmatch(intent_id) is None
            or relative
            != f"{MIGRATION_INTENT_ROOT}/{intent_id}.json"
            or not isinstance(target, str)
            or WORK_ITEM_ID.fullmatch(target) is None
            or not isinstance(priority, int)
            or isinstance(priority, bool)
            or not 0 <= priority <= 100
            or not isinstance(phase, int)
            or isinstance(phase, bool)
            or not 1 <= phase <= 4
        ):
            raise DemandCompilerError("MIGRATION_INTENT_IDENTITY_INVALID")

        capability = intent.get("capability")
        if (
            not isinstance(capability, dict)
            or set(capability) != {"id", "revision"}
        ):
            raise DemandCompilerError("MIGRATION_CAPABILITY_INVALID")
        self._selector(
            capability,
            label="MIGRATION_CAPABILITY",
            identifier_pattern=CAPABILITY_ID,
        )

        baseline = intent.get("android_baseline")
        if (
            not isinstance(baseline, dict)
            or set(baseline) != {"commit"}
            or not isinstance(baseline.get("commit"), str)
            or HEX40.fullmatch(baseline["commit"]) is None
        ):
            raise DemandCompilerError("MIGRATION_BASELINE_INVALID")

        anchors = intent.get("source_anchors")
        if not isinstance(anchors, list) or not anchors:
            raise DemandCompilerError("MIGRATION_SOURCE_ANCHORS_INVALID")
        paths = set()
        for anchor in anchors:
            if (
                not isinstance(anchor, dict)
                or set(anchor) != {"path", "git_blob", "symbols"}
            ):
                raise DemandCompilerError(
                    "MIGRATION_SOURCE_ANCHORS_INVALID"
                )
            path = anchor.get("path")
            blob = anchor.get("git_blob")
            symbols = anchor.get("symbols")
            components = (
                path.split("/") if isinstance(path, str) else []
            )
            if (
                not isinstance(path, str)
                or not path.startswith("app/")
                or "\\" in path
                or "\0" in path
                or any(value in {"", ".", ".."} for value in components)
                or path in paths
                or not isinstance(blob, str)
                or HEX40.fullmatch(blob) is None
                or not isinstance(symbols, list)
                or not symbols
                or len(symbols) != len(set(symbols))
                or any(
                    not isinstance(symbol, str)
                    or not symbol.startswith("kotlin://")
                    for symbol in symbols
                )
            ):
                raise DemandCompilerError(
                    "MIGRATION_SOURCE_ANCHORS_INVALID"
                )
            paths.add(path)

        source_lab = intent.get("source_lab")
        if (
            not isinstance(source_lab, dict)
            or set(source_lab) != {"behavior", "expected_status"}
            or not isinstance(source_lab.get("behavior"), str)
            or not source_lab["behavior"]
            or source_lab.get("expected_status")
            not in {"planned", "active"}
        ):
            raise DemandCompilerError("MIGRATION_SOURCE_LAB_INVALID")

        proposal = intent.get("requirement_proposal")
        if (
            not isinstance(proposal, dict)
            or set(proposal)
            != {"id", "target_requirement_id", "dedupe_key", "path"}
        ):
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_PROPOSAL_INVALID"
            )
        proposal_id = proposal.get("id")
        requirement_id = proposal.get("target_requirement_id")
        proposal_path = proposal.get("path")
        if (
            not isinstance(proposal_id, str)
            or REQUIREMENT_PROPOSAL_ID.fullmatch(proposal_id) is None
            or not isinstance(requirement_id, str)
            or REQUIREMENT_ID.fullmatch(requirement_id) is None
            or not isinstance(proposal.get("dedupe_key"), str)
            or not proposal["dedupe_key"]
            or proposal_path
            != f"ios/project/requirement-proposals/{proposal_id}.json"
        ):
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_PROPOSAL_INVALID"
            )

        expected_blueprint = (
            f"{MIGRATION_BLUEPRINT_ROOT}/{target}.json"
        )
        if intent.get("intake_blueprint") != expected_blueprint:
            raise DemandCompilerError(
                "MIGRATION_BLUEPRINT_PATH_INVALID"
            )

    def _git_object(self, revision: str, path: str) -> str:
        result = self._git("rev-parse", f"{revision}:{path}")
        if result.returncode != 0:
            raise DemandCompilerError(
                f"MIGRATION_SOURCE_UNRESOLVED:{path}"
            )
        value = result.stdout.decode("utf-8").strip()
        if HEX40.fullmatch(value) is None:
            raise DemandCompilerError(
                f"MIGRATION_SOURCE_UNRESOLVED:{path}"
            )
        return value

    def compile_migration(self, intent_path: Path) -> DemandPlan:
        try:
            relative = intent_path.resolve().relative_to(
                self.root
            ).as_posix()
        except ValueError as error:
            raise DemandCompilerError(
                "MIGRATION_INTENT_OUTSIDE_REPOSITORY"
            ) from error
        intent = _load_object(intent_path, "MIGRATION_INTENT")
        self._validate_migration_intent(intent, relative)
        blueprint_relative = str(intent["intake_blueprint"])
        capability = intent["capability"]
        capability_relative = (
            f"ios/project/capabilities/{capability['id']}.json"
        )
        source_paths = tuple(
            str(anchor["path"]) for anchor in intent["source_anchors"]
        )
        self._head_regular(
            (
                relative,
                BASELINE_PATH,
                SOURCE_LAB_COVERAGE_POLICY,
                capability_relative,
                blueprint_relative,
                *source_paths,
            )
        )

        baseline_path = self.resolve(BASELINE_PATH)
        baseline = _load_object(baseline_path, "MIGRATION_BASELINE")
        baseline_commit = baseline.get("android_oracle", {}).get(
            "git_commit"
        )
        if baseline_commit != intent["android_baseline"]["commit"]:
            raise DemandCompilerError("MIGRATION_BASELINE_DRIFT")

        source_bindings = []
        for anchor in intent["source_anchors"]:
            path = str(anchor["path"])
            expected = str(anchor["git_blob"])
            if (
                self._git_object(baseline_commit, path) != expected
                or self._git_object("HEAD", path) != expected
            ):
                raise DemandCompilerError(
                    f"MIGRATION_SOURCE_BLOB_DRIFT:{path}"
                )
            source_bindings.append(
                {
                    "path": path,
                    "git_blob": expected,
                    "symbols": list(anchor["symbols"]),
                }
            )

        coverage_path = self.resolve(SOURCE_LAB_COVERAGE_POLICY)
        coverage = _load_object(
            coverage_path,
            "MIGRATION_SOURCE_LAB_COVERAGE",
        )
        behavior_id = intent["source_lab"]["behavior"]
        matching = [
            value
            for value in coverage.get("behaviors", [])
            if isinstance(value, dict)
            and value.get("id") == behavior_id
        ]
        if len(matching) != 1:
            raise DemandCompilerError(
                f"MIGRATION_BEHAVIOR_MISSING:{behavior_id}"
            )
        behavior = matching[0]
        if (
            behavior.get("status")
            != intent["source_lab"]["expected_status"]
            or not isinstance(behavior.get("phase"), int)
            or behavior["phase"] > intent["phase"]
        ):
            raise DemandCompilerError(
                f"MIGRATION_BEHAVIOR_BINDING_DRIFT:{behavior_id}"
            )

        capability_path = self.resolve(capability_relative)
        capability_record = _load_object(
            capability_path,
            "MIGRATION_CAPABILITY",
        )
        if (
            capability_record.get("id") != capability["id"]
            or capability_record.get("revision")
            != capability["revision"]
        ):
            raise DemandCompilerError(
                "MIGRATION_CAPABILITY_BINDING_DRIFT"
            )

        blueprint_path = self.resolve(blueprint_relative)
        blueprint = _load_object(
            blueprint_path,
            "MIGRATION_BLUEPRINT",
        )
        target = str(intent["target_work_item_id"])
        spec = blueprint.get("spec", {})
        if (
            blueprint.get("api_version") != "legado.harness/v1"
            or blueprint.get("kind") != "WorkItem"
            or blueprint.get("metadata", {}).get("id") != target
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("gates") != []
        ):
            raise DemandCompilerError(
                "MIGRATION_BLUEPRINT_CONTRACT_INVALID"
            )

        settlement = self._completed_migration_intake(intent)
        if settlement is not None:
            accepted = self._accepted_migration_requirement(intent)
            state = (
                "characterization_planning_required"
                if accepted is not None
                else "requirement_authority_required"
            )
            reason = (
                "MIGRATION_REQUIREMENT_ACCEPTED"
                if accepted is not None
                else "MIGRATION_REQUIREMENT_AUTHORITY_REQUIRED"
            )
            artifacts = list(settlement["artifacts"])
            if accepted is not None:
                artifacts.append(accepted)
            return DemandPlan(
                intent_id=str(intent["id"]),
                priority=int(intent["priority"]),
                target_work_item_id=target,
                state=state,
                reason_code=reason,
                authority_transition=accepted is None,
                artifacts=tuple(artifacts),
                bindings=settlement["bindings"],
                policy=MIGRATION_POLICY,
                intent_kind="android_migration",
            )

        return DemandPlan(
            intent_id=str(intent["id"]),
            priority=int(intent["priority"]),
            target_work_item_id=target,
            state="migration_intake_ready",
            reason_code="MIGRATION_INTAKE_INPUTS_READY",
            authority_transition=False,
            artifacts=(
                {
                    "kind": "source_lab_behavior",
                    "id": behavior_id,
                    "status": behavior["status"],
                    "phase": behavior["phase"],
                },
                {
                    "kind": "requirement_proposal",
                    "id": intent["requirement_proposal"]["id"],
                    "status": "missing",
                    "path": intent["requirement_proposal"]["path"],
                },
                {
                    "kind": "migration_blueprint",
                    "id": target,
                    "status": "committed",
                    "path": blueprint_relative,
                    "sha256": _sha256(blueprint_path.read_bytes()),
                },
            ),
            bindings={
                "android_baseline": {
                    "commit": baseline_commit,
                    "path": BASELINE_PATH,
                    "sha256": _sha256(baseline_path.read_bytes()),
                },
                "sources": source_bindings,
                "source_lab_coverage_sha256": _sha256(
                    coverage_path.read_bytes()
                ),
                "capability": {
                    **capability,
                    "path": capability_relative,
                    "sha256": _sha256(capability_path.read_bytes()),
                },
                "blueprint": {
                    "path": blueprint_relative,
                    "sha256": _sha256(blueprint_path.read_bytes()),
                    "work_item_sha256": _sha256_json(blueprint),
                },
                "requirement_proposal": dict(
                    intent["requirement_proposal"]
                ),
            },
            policy=MIGRATION_POLICY,
            intent_kind="android_migration",
        )

    def compile(self, intent_path: Path) -> DemandPlan:
        try:
            relative = intent_path.resolve().relative_to(self.root).as_posix()
        except ValueError as error:
            raise DemandCompilerError("INTENT_OUTSIDE_REPOSITORY") from error
        intent = _load_object(intent_path, "INTENT")
        self._validate_intent(intent, relative)
        self._head_regular((relative,))
        settlement = self._completed_delivery(intent)
        if settlement is not None:
            return DemandPlan(
                intent_id=str(intent["id"]),
                priority=int(intent["priority"]),
                target_work_item_id=str(intent["target_work_item_id"]),
                state="delivery_completed",
                reason_code="DELIVERY_EVIDENCE_SETTLED",
                authority_transition=False,
                artifacts=tuple(settlement["artifacts"]),
                bindings=settlement["bindings"],
            )
        self._head_regular(
            (
                REQUIREMENT_CATALOG,
                KNOWLEDGE_CATALOG,
                GOLDEN_MANIFEST,
            )
        )
        artifacts: List[Mapping[str, Any]] = []
        bindings: Dict[str, Any] = {}

        capability = intent["capability"]
        capability_relative = (
            f"ios/project/capabilities/{capability['id']}.json"
        )
        self._head_regular((capability_relative,))
        capability_path = self.resolve(capability_relative)
        capability_record = _load_object(
            capability_path,
            "CAPABILITY_RECORD",
        )
        if (
            capability_record.get("id") != capability["id"]
            or capability_record.get("revision") != capability["revision"]
        ):
            raise DemandCompilerError("CAPABILITY_BINDING_DRIFT")
        bindings["capability"] = {
            **capability,
            "path": capability_relative,
            "sha256": _sha256(capability_path.read_bytes()),
        }

        golden_manifest_path = self.resolve(GOLDEN_MANIFEST)
        golden_manifest = _load_object(
            golden_manifest_path,
            "GOLDEN_MANIFEST",
        )
        golden_bindings = []
        for fixture_id in intent["golden_fixtures"]:
            entry = golden_manifest.get("fixtures", {}).get(fixture_id)
            if not isinstance(entry, dict):
                raise DemandCompilerError(f"GOLDEN_MISSING:{fixture_id}")
            golden_relative = entry.get("path")
            receipt_relative = entry.get("release_receipt")
            if not isinstance(golden_relative, str) or not isinstance(
                receipt_relative, str
            ):
                raise DemandCompilerError(
                    f"GOLDEN_BINDING_INVALID:{fixture_id}"
                )
            self._head_regular((golden_relative, receipt_relative))
            golden_path = self.resolve(golden_relative)
            receipt_path = self.resolve(receipt_relative)
            receipt = _load_object(receipt_path, "GOLDEN_RECEIPT")
            golden_sha = _sha256(golden_path.read_bytes())
            expected = {
                "authority": "protected_android_golden",
                "authorization": "github_environment_review",
                "fixture_id": fixture_id,
                "golden_path": golden_relative,
                "golden_sha256": golden_sha,
                "run_id": entry.get("run_id"),
                "source_digest": entry.get("source_digest"),
                "proposal_sha256": entry.get("proposal_sha256"),
            }
            if (
                golden_sha != entry.get("golden_sha256")
                or any(receipt.get(key) != value for key, value in expected.items())
            ):
                raise DemandCompilerError(
                    f"GOLDEN_RECEIPT_DRIFT:{fixture_id}"
                )
            golden_bindings.append(
                {
                    "fixture_id": fixture_id,
                    "golden_sha256": golden_sha,
                    "receipt": receipt_relative,
                    "receipt_sha256": _sha256(receipt_path.read_bytes()),
                }
            )
        bindings["goldens"] = golden_bindings

        knowledge_catalog_path = self.resolve(KNOWLEDGE_CATALOG)
        knowledge_catalog = _load_object(
            knowledge_catalog_path,
            "KNOWLEDGE_CATALOG",
        )
        published = {
            (entry.get("id"), entry.get("revision")): entry
            for group in ("packets", "architecture_drivers")
            for entry in knowledge_catalog.get(group, [])
            if isinstance(entry, dict)
        }
        proposals = {
            (entry.get("id"), entry.get("revision")): entry
            for entry in knowledge_catalog.get("proposals", [])
            if isinstance(entry, dict)
        }
        missing_knowledge = []
        for group in ("packets", "drivers"):
            for selector in intent["knowledge"][group]:
                key = (selector["id"], selector["revision"])
                entry = published.get(key)
                if entry is not None:
                    artifacts.append(
                        {
                            "kind": "business_knowledge",
                            "id": key[0],
                            "revision": key[1],
                            "status": "published",
                            "path": entry.get("path"),
                            "sha256": entry.get("sha256"),
                        }
                    )
                    continue
                proposal = proposals.get(key)
                artifact = {
                    "kind": "business_knowledge",
                    "id": key[0],
                    "revision": key[1],
                    "status": (
                        "proposal_only" if proposal is not None else "missing"
                    ),
                    "path": proposal.get("path") if proposal else None,
                    "sha256": proposal.get("sha256") if proposal else None,
                }
                artifacts.append(artifact)
                missing_knowledge.append(artifact)
        bindings["knowledge_catalog_sha256"] = _sha256(
            knowledge_catalog_path.read_bytes()
        )

        requirement_catalog_path = self.resolve(REQUIREMENT_CATALOG)
        requirement_catalog = _load_object(
            requirement_catalog_path,
            "REQUIREMENT_CATALOG",
        )
        requirements = {
            (entry.get("id"), entry.get("revision")): entry
            for entry in requirement_catalog.get("requirements", [])
            if isinstance(entry, dict)
        }
        unready_requirements = []
        for selector in intent["requirements"]:
            key = (selector["id"], selector["revision"])
            entry = requirements.get(key)
            if not isinstance(entry, dict) or entry.get("status") != "accepted":
                raise DemandCompilerError(
                    f"REQUIREMENT_NOT_ACCEPTED:{key[0]}@{key[1]}"
                )
            if not set(selector["clauses"]).issubset(
                set(entry.get("clauses", []))
            ):
                raise DemandCompilerError(
                    f"REQUIREMENT_CLAUSE_DRIFT:{key[0]}"
                )
            record_relative = entry.get("path")
            if not isinstance(record_relative, str):
                raise DemandCompilerError("REQUIREMENT_PATH_INVALID")
            self._head_regular((record_relative,))
            record_path = self.resolve(record_relative)
            record = _load_object(record_path, "REQUIREMENT_RECORD")
            record_sha = _sha256_json(record)
            if (
                record_sha != entry.get("record_sha256")
                or record.get("id") != key[0]
                or record.get("revision") != key[1]
            ):
                raise DemandCompilerError(
                    f"REQUIREMENT_RECORD_DRIFT:{key[0]}"
                )
            readiness = record.get("readiness", {}).get("state")
            artifact = {
                "kind": "requirement",
                "id": key[0],
                "revision": key[1],
                "status": "accepted",
                "readiness": readiness,
                "path": record_relative,
                "sha256": record_sha,
            }
            artifacts.append(artifact)
            if readiness != "implementation_ready":
                unready_requirements.append(artifact)
        bindings["requirement_catalog_sha256"] = _sha256(
            requirement_catalog_path.read_bytes()
        )

        blueprint_relative = intent["blueprint"]
        blueprint_path = self.resolve(blueprint_relative)
        blueprint_exists = blueprint_path.is_file() and not blueprint_path.is_symlink()
        if blueprint_exists:
            self._head_regular((blueprint_relative,))
            blueprint = _load_object(blueprint_path, "DELIVERY_BLUEPRINT")
            if (
                blueprint.get("kind") != "WorkItem"
                or blueprint.get("metadata", {}).get("id")
                != intent["target_work_item_id"]
            ):
                raise DemandCompilerError(
                    "DELIVERY_BLUEPRINT_IDENTITY_INVALID"
                )
        artifacts.append(
            {
                "kind": "delivery_blueprint",
                "id": intent["target_work_item_id"],
                "status": "committed" if blueprint_exists else "missing",
                "path": blueprint_relative,
                "sha256": (
                    _sha256(blueprint_path.read_bytes())
                    if blueprint_exists
                    else None
                ),
            }
        )

        if missing_knowledge:
            state = "knowledge_authority_required"
            reason = "KNOWLEDGE_AUTHORITY_REQUIRED"
            authority = True
        elif unready_requirements:
            state = "requirement_readiness_required"
            reason = "REQUIREMENT_READINESS_REQUIRED"
            authority = True
        elif not blueprint_exists:
            state = "blueprint_required"
            reason = "DELIVERY_BLUEPRINT_REQUIRED"
            authority = False
        else:
            state = "delivery_ready"
            reason = "DELIVERY_INPUTS_READY"
            authority = False
        return DemandPlan(
            intent_id=str(intent["id"]),
            priority=int(intent["priority"]),
            target_work_item_id=str(intent["target_work_item_id"]),
            state=state,
            reason_code=reason,
            authority_transition=authority,
            artifacts=tuple(artifacts),
            bindings=bindings,
        )

    def _completed_delivery(
        self,
        intent: Mapping[str, Any],
    ) -> Optional[Mapping[str, Any]]:
        state_path = self.resolve(STATE_PATH)
        if not state_path.is_file() or state_path.is_symlink():
            return None
        state = _load_object(state_path, "PROJECT_STATE")
        target = str(intent["target_work_item_id"])
        runtime = state.get("work_items", {}).get(target)
        if not isinstance(runtime, dict) or runtime.get("status") != "completed":
            return None

        work_item_relative = f"{WORK_ITEM_ROOT}/{target}.json"
        checkpoint_relative = f"{CHECKPOINT_ROOT}/{target}.json"
        evidence_relative = runtime.get("last_evidence")
        if (
            not isinstance(evidence_relative, str)
            or not evidence_relative.startswith(EVIDENCE_ROOT + "/")
        ):
            raise DemandCompilerError("DELIVERY_SETTLEMENT_INVALID")
        capability = intent["capability"]
        capability_relative = (
            f"ios/project/capabilities/{capability['id']}.json"
        )
        try:
            self._head_regular(
                (
                    STATE_PATH,
                    work_item_relative,
                    checkpoint_relative,
                    evidence_relative,
                    capability_relative,
                )
            )
            work_item_path = self.resolve(work_item_relative)
            checkpoint_path = self.resolve(checkpoint_relative)
            evidence_path = self.resolve(evidence_relative)
            capability_path = self.resolve(capability_relative)
            work_item = _load_object(work_item_path, "SETTLED_WORK_ITEM")
            checkpoint = _load_object(checkpoint_path, "SETTLED_CHECKPOINT")
            evidence = _load_object(evidence_path, "SETTLED_EVIDENCE")
            capability_record = _load_object(
                capability_path,
                "SETTLED_CAPABILITY",
            )
        except DemandCompilerError as error:
            raise DemandCompilerError("DELIVERY_SETTLEMENT_INVALID") from error

        work_item_sha = _sha256_json(work_item)
        evidence_sha = _sha256(evidence_path.read_bytes())
        spec = work_item.get("spec", {})
        blueprint = spec.get("delivery_blueprint", {})
        requirements = spec.get("requirements", {})
        source_lab = spec.get("source_lab", {})
        checkpoint_requirements = checkpoint.get("requirements", {})
        checkpoint_source_lab = checkpoint.get("source_lab", {})
        updates = checkpoint.get("capability_updates", [])
        update = next(
            (
                value
                for value in updates
                if isinstance(value, dict)
                and value.get("id") == capability["id"]
            ),
            None,
        )
        valid_update = (
            isinstance(update, dict)
            and update.get("from_revision") == capability["revision"]
            and isinstance(update.get("to_revision"), int)
            and update["to_revision"] > capability["revision"]
        )
        if (
            work_item.get("metadata", {}).get("id") != target
            or runtime.get("work_item_sha256") != work_item_sha
            or blueprint.get("capability_revision") != capability["revision"]
            or blueprint.get("golden_fixtures") != intent["golden_fixtures"]
            or requirements.get("mode") != "implementation"
            or requirements.get("refs") != intent["requirements"]
            or source_lab.get("scenarios") != intent["golden_fixtures"]
            or checkpoint.get("work_item_id") != target
            or checkpoint.get("evidence") != evidence_relative
            or checkpoint_requirements.get("mode") != "implementation"
            or checkpoint_requirements.get("refs") != intent["requirements"]
            or checkpoint_source_lab.get("scenarios")
            != intent["golden_fixtures"]
            or not valid_update
            or capability_record.get("id") != capability["id"]
            or not isinstance(capability_record.get("revision"), int)
            or capability_record["revision"] < update["to_revision"]
            or evidence.get("work_item_id") != target
            or evidence.get("work_item_sha256") != work_item_sha
            or evidence.get("result") != "passed"
            or runtime.get("last_evidence_sha256") != evidence_sha
        ):
            raise DemandCompilerError("DELIVERY_SETTLEMENT_INVALID")
        return {
            "artifacts": [
                {
                    "kind": "delivery_completion",
                    "id": target,
                    "status": "completed",
                    "evidence": evidence_relative,
                    "evidence_sha256": evidence_sha,
                    "checkpoint": checkpoint_relative,
                    "checkpoint_sha256": _sha256(
                        checkpoint_path.read_bytes()
                    ),
                }
            ],
            "bindings": {
                "settlement": {
                    "work_item": work_item_relative,
                    "work_item_sha256": work_item_sha,
                    "capability": capability["id"],
                    "from_revision": capability["revision"],
                    "to_revision": update["to_revision"],
                }
            },
        }

    def _completed_migration_intake(
        self,
        intent: Mapping[str, Any],
    ) -> Optional[Mapping[str, Any]]:
        state_path = self.resolve(STATE_PATH)
        if not state_path.is_file() or state_path.is_symlink():
            return None
        state = _load_object(state_path, "PROJECT_STATE")
        target = str(intent["target_work_item_id"])
        runtime = state.get("work_items", {}).get(target)
        if not isinstance(runtime, dict) or runtime.get("status") != "completed":
            return None

        work_item_relative = f"{WORK_ITEM_ROOT}/{target}.json"
        checkpoint_relative = f"{CHECKPOINT_ROOT}/{target}.json"
        evidence_relative = runtime.get("last_evidence")
        proposal = intent["requirement_proposal"]
        proposal_relative = str(proposal["path"])
        if (
            not isinstance(evidence_relative, str)
            or not evidence_relative.startswith(EVIDENCE_ROOT + "/")
        ):
            raise DemandCompilerError("MIGRATION_SETTLEMENT_INVALID")
        try:
            work_item_path = self.resolve(work_item_relative)
            checkpoint_path = self.resolve(checkpoint_relative)
            evidence_path = self.resolve(evidence_relative)
            proposal_path = self.resolve(proposal_relative)
            work_item = _load_object(work_item_path, "MIGRATION_WORK_ITEM")
            checkpoint = _load_object(
                checkpoint_path,
                "MIGRATION_CHECKPOINT",
            )
            evidence = _load_object(evidence_path, "MIGRATION_EVIDENCE")
            proposal_record = _load_object(
                proposal_path,
                "MIGRATION_REQUIREMENT_PROPOSAL",
            )
            capability_id = work_item.get("spec", {}).get("capability")
            if (
                not isinstance(capability_id, str)
                or CAPABILITY_ID.fullmatch(capability_id) is None
            ):
                raise DemandCompilerError(
                    "MIGRATION_WORK_ITEM_CAPABILITY_INVALID"
                )
            capability_relative = (
                f"ios/project/capabilities/{capability_id}.json"
            )
            capability_path = self.resolve(capability_relative)
            capability_record = _load_object(
                capability_path,
                "MIGRATION_SETTLED_CAPABILITY",
            )
            self._head_regular(
                (
                    STATE_PATH,
                    work_item_relative,
                    checkpoint_relative,
                    evidence_relative,
                    proposal_relative,
                    capability_relative,
                )
            )
        except DemandCompilerError as error:
            raise DemandCompilerError(
                "MIGRATION_SETTLEMENT_INVALID"
            ) from error

        work_item_sha = _sha256_json(work_item)
        evidence_sha = _sha256(evidence_path.read_bytes())
        updates = checkpoint.get("capability_updates", [])
        update = next(
            (
                value
                for value in updates
                if isinstance(value, dict)
                and value.get("id") == capability_id
            ),
            None,
        )
        valid_update = (
            isinstance(update, dict)
            and isinstance(update.get("from_revision"), int)
            and isinstance(update.get("to_revision"), int)
            and update["to_revision"] > update["from_revision"]
        )
        valid_proposal = (
            proposal_record.get("schema_version") == 1
            and proposal_record.get("id") == proposal["id"]
            and proposal_record.get("status") == "proposed"
            and proposal_record.get("dedupe_key") == proposal["dedupe_key"]
            and proposal_record.get("target_requirement_id")
            == proposal["target_requirement_id"]
            and proposal_record.get("auto_action")
            == "create_characterization_dag"
            and isinstance(proposal_record.get("source_facts"), list)
            and bool(proposal_record["source_facts"])
            and isinstance(proposal_record.get("unknowns"), list)
            and isinstance(proposal_record.get("source_lab_gap"), list)
        )
        if (
            work_item.get("metadata", {}).get("id") != target
            or runtime.get("work_item_sha256") != work_item_sha
            or work_item.get("spec", {}).get("requirements", {}).get("mode")
            != "control_plane"
            or work_item.get("spec", {}).get("gates") != []
            or checkpoint.get("work_item_id") != target
            or checkpoint.get("evidence") != evidence_relative
            or not valid_update
            or capability_record.get("id") != capability_id
            or not isinstance(capability_record.get("revision"), int)
            or capability_record["revision"] < update["to_revision"]
            or evidence.get("work_item_id") != target
            or evidence.get("work_item_sha256") != work_item_sha
            or evidence.get("result") != "passed"
            or runtime.get("last_evidence_sha256") != evidence_sha
            or not valid_proposal
        ):
            raise DemandCompilerError("MIGRATION_SETTLEMENT_INVALID")
        proposal_sha = _sha256(proposal_path.read_bytes())
        return {
            "artifacts": [
                {
                    "kind": "migration_intake_completion",
                    "id": target,
                    "status": "completed",
                    "evidence": evidence_relative,
                    "evidence_sha256": evidence_sha,
                    "checkpoint": checkpoint_relative,
                    "checkpoint_sha256": _sha256(
                        checkpoint_path.read_bytes()
                    ),
                },
                {
                    "kind": "requirement_proposal",
                    "id": proposal["id"],
                    "status": "proposed",
                    "path": proposal_relative,
                    "sha256": proposal_sha,
                },
            ],
            "bindings": {
                "settlement": {
                    "work_item": work_item_relative,
                    "work_item_sha256": work_item_sha,
                    "capability": capability_id,
                    "from_revision": update["from_revision"],
                    "to_revision": update["to_revision"],
                },
                "requirement_proposal": {
                    **dict(proposal),
                    "sha256": proposal_sha,
                },
            },
        }

    def _accepted_migration_requirement(
        self,
        intent: Mapping[str, Any],
    ) -> Optional[Mapping[str, Any]]:
        proposal = intent["requirement_proposal"]
        requirement_id = str(proposal["target_requirement_id"])
        catalog_path = self.resolve(REQUIREMENT_CATALOG)
        try:
            self._head_regular((REQUIREMENT_CATALOG,))
            catalog = _load_object(
                catalog_path,
                "MIGRATION_REQUIREMENT_CATALOG",
            )
        except DemandCompilerError as error:
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_AUTHORITY_INVALID"
            ) from error
        matching = [
            entry
            for entry in catalog.get("requirements", [])
            if isinstance(entry, dict) and entry.get("id") == requirement_id
        ]
        if not matching:
            return None
        if len(matching) != 1:
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_AUTHORITY_INVALID"
            )
        entry = matching[0]
        record_relative = entry.get("path")
        if (
            entry.get("status") != "accepted"
            or not isinstance(entry.get("revision"), int)
            or not isinstance(record_relative, str)
        ):
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_AUTHORITY_INVALID"
            )
        try:
            self._head_regular((record_relative,))
            record_path = self.resolve(record_relative)
            record = _load_object(
                record_path,
                "MIGRATION_REQUIREMENT_RECORD",
            )
        except DemandCompilerError as error:
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_AUTHORITY_INVALID"
            ) from error
        record_sha = _sha256_json(record)
        if (
            entry.get("record_sha256") != record_sha
            or record.get("id") != requirement_id
            or record.get("revision") != entry["revision"]
            or record.get("status") != "accepted"
        ):
            raise DemandCompilerError(
                "MIGRATION_REQUIREMENT_AUTHORITY_INVALID"
            )
        return {
            "kind": "requirement",
            "id": requirement_id,
            "revision": entry["revision"],
            "status": "accepted",
            "readiness": record.get("readiness", {}).get("state"),
            "path": record_relative,
            "sha256": record_sha,
            "catalog_sha256": _sha256(catalog_path.read_bytes()),
        }

    def plans(
        self,
    ) -> Tuple[Tuple[DemandPlan, ...], Tuple[Mapping[str, Any], ...]]:
        plans: List[DemandPlan] = []
        blockers: List[Mapping[str, Any]] = []
        sources = (
            (INTENT_ROOT, self.compile, "INTENT_ROOT_INVALID", "delivery"),
            (
                MIGRATION_INTENT_ROOT,
                self.compile_migration,
                "MIGRATION_INTENT_ROOT_INVALID",
                "android_migration",
            ),
        )
        for root_relative, compile_one, invalid_reason, intent_kind in sources:
            intent_root = self.resolve(root_relative)
            if not intent_root.exists():
                continue
            if intent_root.is_symlink() or not intent_root.is_dir():
                blockers.append(
                    {
                        "intent_kind": intent_kind,
                        "reason_code": invalid_reason,
                    }
                )
                continue
            for path in sorted(intent_root.glob("*.json")):
                try:
                    plans.append(compile_one(path))
                except DemandCompilerError as error:
                    blockers.append(
                        {
                            "intent_kind": intent_kind,
                            "intent_id": path.stem,
                            "reason_code": str(error),
                        }
                    )
        return tuple(
            sorted(plans, key=lambda plan: (-plan.priority, plan.intent_id))
        ), tuple(blockers)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("command", choices=("plan",))
    parser.add_argument("--intent")
    arguments = parser.parse_args(argv)
    compiler = DemandCompiler(arguments.root)
    try:
        plans, blockers = compiler.plans()
        if arguments.intent:
            plans = tuple(
                plan for plan in plans if plan.intent_id == arguments.intent
            )
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "policy": POLICY,
                    "plans": [plan.to_dict() for plan in plans],
                    "blockers": list(blockers),
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0 if plans and not blockers else 2
    except DemandCompilerError as error:
        print(str(error))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
