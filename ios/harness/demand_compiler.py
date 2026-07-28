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
REQUIREMENT_CATALOG = "ios/project/requirements/catalog.json"
KNOWLEDGE_CATALOG = "ios/project/business-knowledge/catalog.json"
GOLDEN_MANIFEST = "ios/harness/goldens/manifest.json"
DELIVERY_BLUEPRINT_ROOT = "ios/project/work-item-proposals/delivery-blueprints"
POLICY = "structured-delivery-intent-v1"
INTENT_ID = re.compile(r"^DINT-[A-Z][A-Z0-9-]*-[0-9]{3}$")
WORK_ITEM_ID = re.compile(r"^IOS-[A-Z][A-Z0-9-]*-[0-9]{3}$")
REQUIREMENT_ID = re.compile(r"^REQ-[A-Z0-9-]+$")
CAPABILITY_ID = re.compile(r"^CAP-[A-Z0-9-]+$")
KNOWLEDGE_ID = re.compile(r"^(BKP|DRV)-[A-Z][A-Z0-9-]*-[0-9]{3}$")


class DemandCompilerError(RuntimeError):
    pass


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


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

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": 1,
            "policy": POLICY,
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

    def compile(self, intent_path: Path) -> DemandPlan:
        try:
            relative = intent_path.resolve().relative_to(self.root).as_posix()
        except ValueError as error:
            raise DemandCompilerError("INTENT_OUTSIDE_REPOSITORY") from error
        intent = _load_object(intent_path, "INTENT")
        self._validate_intent(intent, relative)
        self._head_regular(
            (
                relative,
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
            record_sha = _sha256(record_path.read_bytes())
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

    def plans(
        self,
    ) -> Tuple[Tuple[DemandPlan, ...], Tuple[Mapping[str, Any], ...]]:
        intent_root = self.resolve(INTENT_ROOT)
        if not intent_root.exists():
            return (), ()
        if intent_root.is_symlink() or not intent_root.is_dir():
            return (), ({"reason_code": "INTENT_ROOT_INVALID"},)
        plans: List[DemandPlan] = []
        blockers: List[Mapping[str, Any]] = []
        for path in sorted(intent_root.glob("*.json")):
            try:
                plans.append(self.compile(path))
            except DemandCompilerError as error:
                blockers.append(
                    {
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
