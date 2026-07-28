#!/usr/bin/env python3
"""Local cooperative driver for the Legado iOS Harness.

This module makes loop decisions deterministic and gives a human a one-click
way to materialize a pre-authored Work Item candidate.  It is intentionally not
the production trust boundary described by ``trusted-supervisor.md``.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
import secrets
import signal
import subprocess
import sys
import tempfile
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

try:
    from .approval_ui import (
        LOOPBACK_HOST,
        MAX_REQUEST_BYTES,
        REQUEST_IO_TIMEOUT_SECONDS,
        SESSION_TTL_SECONDS,
        LoopbackHTTPServer,
        canonical_bytes,
        local_reviewer,
        sha256_json,
    )
    from .harness import Harness, HarnessError, path_matches
    from .proposal_compiler import (
        COMPILER_VERSION,
        DAG_PATH,
        MANIFEST_ROOT,
        RECIPE_ROOT,
        ProposalCompiler,
        ProposalCompilerError,
    )
except ImportError:
    from approval_ui import (  # type: ignore
        LOOPBACK_HOST,
        MAX_REQUEST_BYTES,
        REQUEST_IO_TIMEOUT_SECONDS,
        SESSION_TTL_SECONDS,
        LoopbackHTTPServer,
        canonical_bytes,
        local_reviewer,
        sha256_json,
    )
    from harness import Harness, HarnessError, path_matches  # type: ignore
    from proposal_compiler import (  # type: ignore
        COMPILER_VERSION,
        DAG_PATH,
        MANIFEST_ROOT,
        RECIPE_ROOT,
        ProposalCompiler,
        ProposalCompilerError,
    )


SCHEMA_VERSION = 1
CANDIDATE_ROOT = "ios/project/work-item-proposals/candidates"
AUTO_MATERIALIZATION_POLICY = "compiled-control-plane-v1"
SUPERVISOR_VERIFICATION_POLICY = "supervisor-owned-verification-v1"
TERMINAL_RECOVERY_STATUSES = {"blocked", "rejected", "exhausted", "cancelled"}
ACTIVE_DECISIONS = {
    "implementing": ("agent_required", False),
    "verified": ("memory_close_required", False),
    "awaiting_human": ("human_decision_required", True),
}
AUTO_SAFE_HARNESS_PATHS = {
    "ios/harness/loop_supervisor.py",
    "ios/harness/proposal_compiler.py",
    "ios/harness/README.md",
    "ios/harness/supervisor.example.json",
}
AUTO_SAFE_PREFIXES = (
    "ios/harness/tests/",
    "ios/project/capabilities/",
    "ios/project/checkpoints/",
    "ios/project/pitfalls/",
)
AUTO_SAFE_PROPOSAL_MARKERS = (
    "/packets/proposals/",
    "/drivers/proposals/",
)
AUTO_FORBIDDEN_LABELS = {
    "acceptance",
    "architecture-change",
    "authority",
    "ci",
    "golden",
    "product",
    "promotion",
    "release",
}
AUTO_FORBIDDEN_SCOPE_PREFIXES = (
    ".github/",
    "app/",
    "modules/",
    "ios/Packages/",
    "ios/docs/",
    "ios/project/approvals/",
    "ios/project/requirements/",
    "ios/project/work-item-proposals/",
    "ios/harness/goldens/",
    "ios/harness/schemas/",
    "ios/harness/business-knowledge/",
    "ios/harness/android-intake/",
    "ios/harness/source-lab/",
    "ios/harness/oracle/",
)
AUTO_FORBIDDEN_SCOPE_EXACT = {
    "ios/harness/harness.py",
    "ios/harness/approval_ui.py",
    "ios/harness/codex_agent_adapter.py",
    "ios/harness/trusted_supervisor_reference.py",
    "ios/harness/config.json",
    "ios/harness/architecture-rules.json",
    "ios/harness/dependency-policy.json",
    "ios/project/baseline.json",
    "ios/project/events.jsonl",
    "ios/project/state.json",
    "ios/project/status.md",
}


class LoopSupervisorError(RuntimeError):
    pass


class MaterializationConflict(LoopSupervisorError):
    pass


class MaterializationRequestError(LoopSupervisorError):
    pass


@dataclass(frozen=True)
class LoopDecision:
    state: str
    reason_code: str
    work_item_id: Optional[str]
    requires_human: bool
    commands: Tuple[Tuple[str, ...], ...] = ()
    blockers: Tuple[Mapping[str, Any], ...] = ()
    warnings: Tuple[str, ...] = ()
    details: Optional[Mapping[str, Any]] = None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "state": self.state,
            "reason_code": self.reason_code,
            "work_item_id": self.work_item_id,
            "requires_human": self.requires_human,
            "commands": [list(command) for command in self.commands],
            "blockers": [dict(blocker) for blocker in self.blockers],
            "warnings": list(self.warnings),
            "details": dict(self.details) if self.details is not None else None,
        }


@dataclass(frozen=True)
class MaterializationPreview:
    source_relative: str
    item_id: str
    title: str
    work_item_sha256: str
    source_fingerprint: str
    event_head: str
    dependencies: Tuple[str, ...]
    allow_write: Tuple[str, ...]
    budgets: Tuple[Tuple[str, Any], ...]
    criteria: Tuple[Tuple[str, str], ...]
    gates: Tuple[str, ...]
    produces: Tuple[Tuple[str, str, int], ...]

    def binding(self) -> Tuple[Any, ...]:
        return (
            self.source_relative,
            self.item_id,
            self.work_item_sha256,
            self.source_fingerprint,
            self.event_head,
            self.dependencies,
            self.allow_write,
            self.budgets,
            self.criteria,
            self.gates,
            self.produces,
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": SCHEMA_VERSION,
            "source": self.source_relative,
            "work_item_id": self.item_id,
            "title": self.title,
            "work_item_sha256": self.work_item_sha256,
            "source_fingerprint": self.source_fingerprint,
            "event_head": self.event_head,
            "dependencies": list(self.dependencies),
            "allow_write": list(self.allow_write),
            "budget": dict(self.budgets),
            "acceptance": [
                {"id": identifier, "statement": statement}
                for identifier, statement in self.criteria
            ],
            "gates": list(self.gates),
            "produces": [
                {"kind": kind, "id": identifier, "revision": revision}
                for kind, identifier, revision in self.produces
            ],
        }


@dataclass(frozen=True)
class AutoMaterializationCandidate:
    proposal_id: str
    priority: int
    head_commit: str
    candidate_relative: str
    manifest_relative: str
    candidate_sha256: str
    manifest_sha256: str

    def to_dict(self) -> Dict[str, Any]:
        return {
            "proposal_id": self.proposal_id,
            "priority": self.priority,
            "policy": AUTO_MATERIALIZATION_POLICY,
            "head_commit": self.head_commit,
            "candidate": self.candidate_relative,
            "manifest": self.manifest_relative,
            "candidate_sha256": self.candidate_sha256,
            "manifest_sha256": self.manifest_sha256,
        }


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _atomic_write_bytes(path: Path, payload: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_temporary = tempfile.mkstemp(
        dir=str(path.parent),
        prefix=f".{path.name}.loop-supervisor.",
    )
    temporary = Path(raw_temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(str(temporary), str(path))
    finally:
        temporary.unlink(missing_ok=True)


class LoopSupervisor:
    def __init__(self, harness: Harness):
        self.harness = harness

    def _git(self, *arguments: str) -> subprocess.CompletedProcess[bytes]:
        try:
            return subprocess.run(
                ["git", *arguments],
                cwd=str(self.harness.root),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
        except OSError as error:
            raise MaterializationConflict(f"GIT_UNAVAILABLE: {error}") from error

    def _clean_head(self) -> str:
        top = self._git("rev-parse", "--show-toplevel")
        if top.returncode != 0:
            raise MaterializationConflict("GIT_REPOSITORY_REQUIRED")
        try:
            top_path = Path(top.stdout.decode("utf-8").strip()).resolve()
        except UnicodeDecodeError as error:
            raise MaterializationConflict("GIT_ROOT_INVALID") from error
        if top_path != self.harness.root.resolve():
            raise MaterializationConflict("GIT_ROOT_MISMATCH")
        head = self._git("rev-parse", "HEAD")
        if head.returncode != 0:
            raise MaterializationConflict("GIT_HEAD_REQUIRED")
        status = self._git(
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--",
            ".",
            ":(exclude).harness-runtime/**",
        )
        if status.returncode != 0:
            raise MaterializationConflict("GIT_STATUS_FAILED")
        if status.stdout:
            raise MaterializationConflict("GIT_WORKTREE_DIRTY")
        return head.stdout.decode("ascii").strip()

    def _require_head_regular(self, relatives: Sequence[str]) -> None:
        for relative in relatives:
            path = self.harness.resolve(relative)
            if path.is_symlink() or not path.is_file():
                raise MaterializationConflict(
                    f"PROVENANCE_FILE_NOT_REGULAR: {relative}"
                )
            listing = self._git("ls-tree", "HEAD", "--", relative)
            if listing.returncode != 0 or not listing.stdout:
                raise MaterializationConflict(
                    f"PROVENANCE_FILE_NOT_IN_HEAD: {relative}"
                )
            try:
                mode = listing.stdout.decode("utf-8").split(None, 1)[0]
            except (UnicodeDecodeError, IndexError) as error:
                raise MaterializationConflict(
                    f"PROVENANCE_HEAD_ENTRY_INVALID: {relative}"
                ) from error
            if mode not in {"100644", "100755"}:
                raise MaterializationConflict(
                    f"PROVENANCE_HEAD_ENTRY_NOT_REGULAR: {relative}"
                )

    @staticmethod
    def _auto_scope_allowed(pattern: str) -> bool:
        if pattern in {"*", "**", "ios/*", "ios/**"}:
            return False
        if pattern in AUTO_FORBIDDEN_SCOPE_EXACT:
            return False
        if pattern.startswith(AUTO_FORBIDDEN_SCOPE_PREFIXES):
            return False
        if pattern in AUTO_SAFE_HARNESS_PATHS:
            return True
        if pattern.startswith(AUTO_SAFE_PREFIXES):
            return True
        if pattern.startswith("ios/project/business-knowledge/") and any(
            marker in pattern for marker in AUTO_SAFE_PROPOSAL_MARKERS
        ):
            return True
        return False

    def _auto_candidate(
        self,
        proposal_id: str,
        *,
        head_commit: Optional[str] = None,
    ) -> AutoMaterializationCandidate:
        head = head_commit or self._clean_head()
        candidate_relative = f"{CANDIDATE_ROOT}/{proposal_id}.json"
        manifest_relative = f"{MANIFEST_ROOT}/{proposal_id}.json"
        recipe_relative = f"{RECIPE_ROOT}/{proposal_id}.json"
        provenance_paths = [
            candidate_relative,
            manifest_relative,
            recipe_relative,
            DAG_PATH,
        ]
        manifest_path = self.harness.resolve(manifest_relative)
        if manifest_path.is_symlink() or not manifest_path.is_file():
            raise MaterializationConflict("PROVENANCE_MANIFEST_NOT_REGULAR")
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"PROVENANCE_MANIFEST_INVALID: {error}"
            ) from error
        if not isinstance(manifest, dict):
            raise MaterializationConflict("PROVENANCE_MANIFEST_INVALID")
        if (
            manifest.get("schema_version") != 1
            or manifest.get("compiler_version") != COMPILER_VERSION
            or manifest.get("proposal_id") != proposal_id
            or manifest.get("authority") != "proposal_only"
            or manifest.get("queue_effect") != "none"
        ):
            raise MaterializationConflict("PROVENANCE_MANIFEST_CONTRACT_INVALID")
        for dependency in manifest.get("dependencies", []):
            if not isinstance(dependency, dict):
                raise MaterializationConflict("PROVENANCE_DEPENDENCY_INVALID")
            for key in ("checkpoint", "evidence"):
                value = dependency.get(key)
                if isinstance(value, str):
                    provenance_paths.append(value)
            resolved = dependency.get("resolved")
            if isinstance(resolved, str):
                provenance_paths.append(
                    f"ios/harness/work-items/{resolved}.json"
                )
        self._require_head_regular(provenance_paths)

        compiler_result = ProposalCompiler(self.harness).check(proposal_id)
        if compiler_result.get("status") != "current":
            reasons = ",".join(
                str(reason) for reason in compiler_result.get("reasons", [])
            )
            raise MaterializationConflict(
                f"PROPOSAL_COMPILER_STALE: {reasons or 'unknown'}"
            )
        preview = self.preflight_candidate(
            self.harness.resolve(candidate_relative)
        )
        if preview.item_id != proposal_id:
            raise MaterializationConflict("CANDIDATE_ID_MISMATCH")
        if manifest.get("candidate_sha256") != preview.work_item_sha256:
            raise MaterializationConflict("CANDIDATE_MANIFEST_HASH_MISMATCH")

        item = json.loads(
            self.harness.resolve(candidate_relative).read_text(encoding="utf-8")
        )
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        risk = metadata.get("risk")
        labels = set(metadata.get("labels", []))
        if risk == "critical":
            raise MaterializationConflict("AUTO_POLICY_CRITICAL_RISK")
        forbidden_labels = sorted(labels.intersection(AUTO_FORBIDDEN_LABELS))
        if forbidden_labels:
            raise MaterializationConflict(
                "AUTO_POLICY_AUTHORITY_LABEL: " + ",".join(forbidden_labels)
            )
        if spec.get("gates") != []:
            raise MaterializationConflict("AUTO_POLICY_DECISION_REQUIRED")
        requirements = spec.get("requirements", {})
        if requirements.get("mode") != "control_plane":
            raise MaterializationConflict("AUTO_POLICY_REQUIREMENT_MODE")
        knowledge = spec.get("knowledge", {})
        if knowledge.get("mode") not in {"not_applicable", "produce"}:
            raise MaterializationConflict("AUTO_POLICY_KNOWLEDGE_AUTHORITY")
        completion_effects = spec.get("completion_effects", {})
        if set(completion_effects) - {"health"}:
            raise MaterializationConflict("AUTO_POLICY_AUTHORITY_EFFECT")
        allow_write = spec.get("scope", {}).get("allow_write", [])
        rejected_scope = [
            pattern
            for pattern in allow_write
            if not isinstance(pattern, str) or not self._auto_scope_allowed(pattern)
        ]
        if rejected_scope:
            raise MaterializationConflict(
                "AUTO_POLICY_SCOPE_DENIED: "
                + ",".join(str(value) for value in rejected_scope)
            )
        priority = metadata.get("priority")
        if not isinstance(priority, int):
            raise MaterializationConflict("AUTO_POLICY_PRIORITY_INVALID")
        return AutoMaterializationCandidate(
            proposal_id=proposal_id,
            priority=priority,
            head_commit=head,
            candidate_relative=candidate_relative,
            manifest_relative=manifest_relative,
            candidate_sha256=preview.work_item_sha256,
            manifest_sha256=_sha256_bytes(manifest_path.read_bytes()),
        )

    def auto_materialization_candidates(
        self,
    ) -> Tuple[Tuple[AutoMaterializationCandidate, ...], Tuple[Mapping[str, Any], ...]]:
        if not isinstance(self.harness, Harness):
            return (), ()
        manifest_root = self.harness.resolve(MANIFEST_ROOT)
        if not manifest_root.exists():
            return (), ()
        if manifest_root.is_symlink() or not manifest_root.is_dir():
            return (), ({"reason_code": "PROVENANCE_MANIFEST_ROOT_INVALID"},)
        try:
            head = self._clean_head()
        except MaterializationConflict as error:
            return (), ({"reason_code": str(error)},)
        items = self.harness.work_items()
        state_items = self.harness.state().get("work_items", {})
        eligible: List[AutoMaterializationCandidate] = []
        blockers: List[Mapping[str, Any]] = []
        for manifest_path in sorted(manifest_root.glob("*.json")):
            proposal_id = manifest_path.stem
            if proposal_id in items or proposal_id in state_items:
                continue
            try:
                eligible.append(
                    self._auto_candidate(proposal_id, head_commit=head)
                )
            except (MaterializationConflict, ProposalCompilerError) as error:
                blockers.append(
                    {
                        "proposal_id": proposal_id,
                        "reason_code": str(error),
                    }
                )
        return tuple(
            sorted(
                eligible,
                key=lambda value: (-value.priority, value.proposal_id),
            )
        ), tuple(blockers)

    @staticmethod
    def _select_auto_candidate(
        eligible: Sequence[AutoMaterializationCandidate],
    ) -> Tuple[Optional[AutoMaterializationCandidate], Optional[Mapping[str, Any]]]:
        if not eligible:
            return None, None
        highest = eligible[0].priority
        tied = [value for value in eligible if value.priority == highest]
        if len(tied) != 1:
            return None, {
                "reason_code": "AUTO_MATERIALIZATION_PRIORITY_AMBIGUOUS",
                "priority": highest,
                "proposal_ids": [value.proposal_id for value in tied],
            }
        return tied[0], None

    def inspect(self) -> LoopDecision:
        errors, warnings = self.harness.doctor()
        if errors:
            return LoopDecision(
                state="doctor_red",
                reason_code="DOCTOR_FAILED",
                work_item_id=None,
                requires_human=True,
                blockers=tuple({"message": error} for error in errors),
                warnings=tuple(warnings),
            )

        items = self.harness.work_items()
        state = self.harness.state()
        state_items = state.get("work_items", {})
        active = state.get("active_work_items", [])
        if active:
            item_id = active[0]
            runtime = state_items.get(item_id, {})
            status = runtime.get("status")
            decision = ACTIVE_DECISIONS.get(status)
            if decision is None:
                return LoopDecision(
                    state="doctor_red",
                    reason_code="ACTIVE_STATUS_INVALID",
                    work_item_id=item_id,
                    requires_human=True,
                    blockers=({"status": status},),
                )
            reason, requires_human = decision
            command_name = {
                "implementing": "context",
                "verified": "close",
                "awaiting_human": "review",
            }[status]
            return LoopDecision(
                state=status,
                reason_code=reason.upper(),
                work_item_id=item_id,
                requires_human=requires_human,
                commands=(
                    (
                        sys.executable,
                        "ios/harness/harness.py",
                        command_name,
                        item_id,
                    ),
                ),
            )

        selected = self.harness.select_next(state, items)
        if selected is not None:
            return LoopDecision(
                state="ready",
                reason_code="READY_WORK_ITEM",
                work_item_id=selected,
                requires_human=False,
                commands=(
                    (
                        sys.executable,
                        "ios/harness/harness.py",
                        "claim",
                        selected,
                        "--agent",
                        "<agent-id>",
                    ),
                ),
            )

        dependency_blockers: List[Mapping[str, Any]] = []
        for item_id, item in sorted(items.items()):
            runtime = state_items.get(item_id, {})
            if runtime.get("status") != "ready":
                continue
            missing = [
                dependency
                for dependency in item.get("spec", {}).get("depends_on", [])
                if state_items.get(dependency, {}).get("status") != "completed"
            ]
            if missing:
                dependency_blockers.append(
                    {"work_item_id": item_id, "incomplete_dependencies": missing}
                )
        if dependency_blockers:
            return LoopDecision(
                state="dependency_blocked",
                reason_code="READY_ITEMS_HAVE_INCOMPLETE_DEPENDENCIES",
                work_item_id=None,
                requires_human=True,
                blockers=tuple(dependency_blockers),
            )

        blocked_items = [
            {
                "work_item_id": item_id,
                "status": runtime.get("status"),
                "blocker": runtime.get("blocker"),
            }
            for item_id, runtime in sorted(state_items.items())
            if isinstance(runtime, dict) and runtime.get("status") == "blocked"
        ]
        if blocked_items:
            return LoopDecision(
                state="terminal_recovery",
                reason_code="BLOCKED_WORK_ITEM_REQUIRES_RESOLUTION",
                work_item_id=str(blocked_items[-1]["work_item_id"]),
                requires_human=True,
                blockers=tuple(blocked_items),
            )

        latest_completed_sequence = 0
        terminal_events: List[Tuple[int, str, str]] = []
        for event in self.harness.event_lines():
            sequence = int(event.get("sequence", 0))
            if event.get("event") == "WorkItemCompleted":
                latest_completed_sequence = max(latest_completed_sequence, sequence)
            if event.get("event") in {
                "WorkItemRejected",
                "WorkItemExhausted",
                "WorkItemCancelled",
            }:
                terminal_events.append(
                    (sequence, str(event.get("work_item_id")), str(event.get("event")))
                )
        unresolved = [
            {
                "sequence": sequence,
                "work_item_id": item_id,
                "terminal_event": event_name,
                "status": state_items.get(item_id, {}).get("status"),
            }
            for sequence, item_id, event_name in terminal_events
            if sequence > latest_completed_sequence
            and state_items.get(item_id, {}).get("status") in TERMINAL_RECOVERY_STATUSES
        ]
        if unresolved:
            latest = unresolved[-1]
            return LoopDecision(
                state="terminal_recovery",
                reason_code="LATEST_ATTEMPT_REQUIRES_RECOVERY",
                work_item_id=str(latest["work_item_id"]),
                requires_human=True,
                blockers=tuple(unresolved),
            )

        eligible, auto_blockers = self.auto_materialization_candidates()
        selected_auto, ambiguity = self._select_auto_candidate(eligible)
        if selected_auto is not None:
            return LoopDecision(
                state="auto_materialization_ready",
                reason_code="AUTO_MATERIALIZATION_READY",
                work_item_id=selected_auto.proposal_id,
                requires_human=False,
                commands=(
                    (
                        sys.executable,
                        "ios/harness/loop_supervisor.py",
                        "drive",
                        "--config",
                        "ios/harness/supervisor.example.json",
                        "--agent",
                        "<agent-id>",
                    ),
                ),
                warnings=tuple(warnings),
                details={"auto_materialization": selected_auto.to_dict()},
            )
        blockers = list(auto_blockers)
        if ambiguity is not None:
            blockers.insert(0, ambiguity)
        return LoopDecision(
            state=(
                "auto_materialization_blocked"
                if blockers
                else "queue_empty"
            ),
            reason_code=(
                "AUTO_MATERIALIZATION_BLOCKED"
                if blockers
                else "NO_ELIGIBLE_COMPILED_CANDIDATE"
            ),
            work_item_id=None,
            requires_human=False,
            blockers=tuple(blockers),
            warnings=tuple(warnings),
        )

    def _candidate_path(self, raw_path: Path) -> Tuple[Path, str]:
        candidate_root = self.harness.resolve(CANDIDATE_ROOT)
        if raw_path.is_absolute():
            candidate = raw_path.resolve()
        else:
            candidate = (self.harness.root / raw_path).resolve()
        try:
            candidate.relative_to(candidate_root.resolve())
        except ValueError as error:
            raise MaterializationConflict(
                f"candidate 必须位于 {CANDIDATE_ROOT}"
            ) from error
        if candidate.is_symlink() or not candidate.is_file():
            raise MaterializationConflict("candidate 必须是普通 JSON 文件，不能是 symlink")
        relative = candidate.relative_to(self.harness.root.resolve()).as_posix()
        return candidate, relative

    def _reservations(
        self,
        items: Mapping[str, Mapping[str, Any]],
    ) -> Dict[Tuple[str, str, int], str]:
        result: Dict[Tuple[str, str, int], str] = {}
        for owner, item in sorted(items.items()):
            knowledge = item.get("spec", {}).get("knowledge", {})
            for output in knowledge.get("produces", []) if isinstance(knowledge, dict) else []:
                if not isinstance(output, dict):
                    continue
                kind = output.get("kind")
                identifier = output.get("id")
                revision = output.get("revision")
                if (
                    not isinstance(kind, str)
                    or not isinstance(identifier, str)
                    or not isinstance(revision, int)
                ):
                    continue
                key = (kind, identifier, revision)
                prior = result.get(key)
                if prior is not None and prior != owner:
                    raise MaterializationConflict(
                        f"既有 reservation 已重复：{kind} {identifier}@{revision} "
                        f"-> {prior}, {owner}"
                    )
                result[key] = owner
        return result

    def preflight_candidate(self, raw_path: Path) -> MaterializationPreview:
        errors, _ = self.harness.doctor()
        if errors:
            raise MaterializationConflict("doctor 未通过：" + "；".join(errors))
        candidate_path, relative = self._candidate_path(raw_path)
        try:
            item = json.loads(candidate_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(f"candidate JSON 无效：{error}") from error
        item_id = item.get("metadata", {}).get("id")
        if not isinstance(item_id, str):
            raise MaterializationConflict("candidate 缺少 metadata.id")
        if candidate_path.name != f"{item_id}.json":
            raise MaterializationConflict("candidate 文件名必须与 metadata.id 一致")
        validation = self.harness.validate_work_item(item, item_id)
        if validation:
            raise MaterializationConflict("Work Item 无效：" + "；".join(validation))
        gates = item.get("spec", {}).get("gates", [])
        if gates:
            contracts, decision_errors = self.harness.decision_gate_contracts(item)
            if (
                item.get("spec", {}).get("gate_contract_version") != 1
                or decision_errors
                or set(gates) != set(contracts)
            ):
                details = "；".join(decision_errors) or "缺少 v1 decision contract"
                raise MaterializationConflict(
                    "LEGACY_HUMAN_GATE_REJECTED: "
                    "新 candidate 的非空 gates 必须逐项声明结构化决策；"
                    + details
                )

        items = self.harness.work_items()
        state = self.harness.state()
        if item_id in items or item_id in state.get("work_items", {}):
            raise MaterializationConflict(f"Work Item 已存在：{item_id}")
        destination = self.harness.resolve(f"ios/harness/work-items/{item_id}.json")
        if destination.exists() or destination.is_symlink():
            raise MaterializationConflict(f"Work Item destination 已存在：{item_id}")

        dependencies = tuple(item["spec"].get("depends_on", []))
        incomplete = [
            dependency
            for dependency in dependencies
            if state.get("work_items", {}).get(dependency, {}).get("status") != "completed"
        ]
        if incomplete:
            raise MaterializationConflict(
                "依赖尚未 completed：" + ", ".join(incomplete)
            )

        reservations = self._reservations(items)
        produces: List[Tuple[str, str, int]] = []
        for output in item.get("spec", {}).get("knowledge", {}).get("produces", []):
            key = (output["kind"], output["id"], output["revision"])
            if key in reservations:
                revisions = [
                    revision
                    for kind, identifier, revision in reservations
                    if kind == key[0] and identifier == key[1]
                ]
                suggestion = max(revisions, default=0) + 1
                raise MaterializationConflict(
                    "KNOWLEDGE_OUTPUT_RESERVED: "
                    f"{key[0]} {key[1]}@{key[2]} owner={reservations[key]} "
                    f"suggested_revision={suggestion}"
                )
            existing = [
                revision
                for kind, identifier, revision in reservations
                if kind == key[0] and identifier == key[1]
            ]
            expected = max(existing, default=0) + 1
            if key[2] != expected:
                raise MaterializationConflict(
                    "KNOWLEDGE_REVISION_NONCONTIGUOUS: "
                    f"{key[0]} {key[1]}@{key[2]} expected={expected}"
                )
            if key in produces:
                raise MaterializationConflict(f"candidate 重复声明 output：{key}")
            produces.append(key)

        expected_paths = self.harness.knowledge_proposal_paths(item)
        allow_write = tuple(item["spec"]["scope"]["allow_write"])
        deny_write = tuple(item["spec"]["scope"].get("deny_write", []))
        protected_paths = tuple(self.harness.config.get("protected_paths", []))
        impossible_scope = [
            pattern
            for pattern in allow_write
            if not any(character in pattern for character in "*?[")
            and (
                path_matches(pattern, deny_write)
                or path_matches(pattern, protected_paths)
            )
        ]
        if impossible_scope:
            raise MaterializationConflict(
                "SCOPE_UNSATISFIABLE: allow_write 同时命中 deny/protected："
                + ", ".join(impossible_scope)
            )
        missing_scope = [
            path
            for path in expected_paths
            if not path_matches(path, allow_write)
        ]
        if missing_scope:
            raise MaterializationConflict(
                "knowledge output 不在 allow_write：" + ", ".join(missing_scope)
            )

        criteria = tuple(
            (str(criterion.get("id")), str(criterion.get("statement")))
            for criterion in item["spec"]["acceptance"]["criteria"]
        )
        event_head = state.get("event_head")
        if not isinstance(event_head, str) or not event_head:
            raise MaterializationConflict("state 缺少 event_head")
        payload = candidate_path.read_bytes()
        return MaterializationPreview(
            source_relative=relative,
            item_id=item_id,
            title=str(item["metadata"]["title"]),
            work_item_sha256=sha256_json(item),
            source_fingerprint=_sha256_bytes(payload),
            event_head=event_head,
            dependencies=dependencies,
            allow_write=allow_write,
            budgets=tuple(sorted(item["spec"]["budget"].items())),
            criteria=criteria,
            gates=tuple(item["spec"].get("gates", [])),
            produces=tuple(produces),
        )

    def materialize(
        self,
        preview: MaterializationPreview,
        *,
        reason: str,
        provenance: Optional[Mapping[str, Any]] = None,
    ) -> str:
        current = self.preflight_candidate(
            self.harness.resolve(preview.source_relative)
        )
        if current.binding() != preview.binding():
            raise MaterializationConflict("验收页打开后 candidate 或事件头发生变化")

        candidate_path = self.harness.resolve(current.source_relative)
        target = self.harness.resolve(
            f"ios/harness/work-items/{current.item_id}.json"
        )
        protected = [
            target,
            self.harness.events_path,
            self.harness.state_path,
            self.harness.status_path,
        ]
        originals: Dict[Path, Optional[bytes]] = {
            path: path.read_bytes() if path.exists() else None for path in protected
        }
        try:
            _atomic_write_bytes(target, candidate_path.read_bytes())
            items = self.harness.work_items()
            state = self.harness.state()
            state.setdefault("work_items", {})[current.item_id] = {
                "status": "ready",
                "attempt": 0,
                "last_evidence": None,
            }
            event_payload: Dict[str, Any] = {
                "authorized_by": local_reviewer(),
                "initial_status": "ready",
                "reason": reason,
                "work_item_sha256": current.work_item_sha256,
            }
            if provenance is not None:
                event_payload["provenance"] = dict(provenance)
            self.harness.append_event(
                "WorkItemMaterialized",
                current.item_id,
                event_payload,
            )
            self.harness.write_state(state, items)
        except Exception:
            for path, payload in originals.items():
                if payload is None:
                    path.unlink(missing_ok=True)
                else:
                    mode = path.stat().st_mode & 0o7777 if path.exists() else 0o644
                    _atomic_write_bytes(path, payload, mode)
            raise
        return current.item_id

    def auto_materialize(self, proposal_id: str) -> str:
        candidate = self._auto_candidate(proposal_id)
        preview = self.preflight_candidate(
            self.harness.resolve(candidate.candidate_relative)
        )
        if preview.work_item_sha256 != candidate.candidate_sha256:
            raise MaterializationConflict("AUTO_MATERIALIZATION_BINDING_DRIFT")
        return self.materialize(
            preview,
            reason=f"policy:{AUTO_MATERIALIZATION_POLICY}",
            provenance=candidate.to_dict(),
        )

    @staticmethod
    def _control_binding(state: Mapping[str, Any], item_id: str) -> Tuple[Any, ...]:
        runtime = state.get("work_items", {}).get(item_id, {})
        return (
            state.get("event_head"),
            runtime.get("status"),
            runtime.get("attempt"),
            runtime.get("verify_cycles"),
            runtime.get("last_evidence"),
            runtime.get("last_evidence_sha256"),
        )

    def _invoke_agent_phase(
        self,
        *,
        item_id: str,
        phase: str,
        policy: Optional[str],
        argv_template: Sequence[str],
        timeout_seconds: int,
    ) -> Dict[str, Any]:
        context = self.harness.context_packet(item_id)
        if policy is not None:
            runtime = self.harness.state().get("work_items", {}).get(item_id, {})
            context["supervisor_control"] = {
                "policy": policy,
                "phase": phase,
                "latest_evidence": runtime.get("last_evidence"),
                "verify_cycles": runtime.get("verify_cycles", 0),
            }
        descriptor, raw_context = tempfile.mkstemp(
            prefix=f"legado-{item_id.lower()}-",
            suffix=".json",
        )
        context_path = Path(raw_context)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(
                    json.dumps(context, ensure_ascii=False, indent=2).encode()
                )
                handle.write(b"\n")
            replacements = {
                "{work_item_id}": item_id,
                "{context_path}": str(context_path),
                "{repo_root}": str(self.harness.root),
            }
            argv = [
                _replace_placeholders(value, replacements)
                for value in argv_template
            ]
            environment = {
                key: os.environ[key]
                for key in (
                    "PATH",
                    "DEVELOPER_DIR",
                    "SDKROOT",
                    "TMPDIR",
                    "LANG",
                    "LC_ALL",
                )
                if key in os.environ
            }
            environment.update(
                {
                    "LEGADO_WORK_ITEM_ID": item_id,
                    "LEGADO_CONTEXT_PATH": str(context_path),
                    "LEGADO_SUPERVISOR_PHASE": phase,
                    "PYTHONDONTWRITEBYTECODE": "1",
                    "TZ": "UTC",
                }
            )
            started = time.monotonic()
            transition = self._run_agent_adapter(
                item_id=item_id,
                argv=argv,
                environment=environment,
                timeout_seconds=timeout_seconds,
            )
            transition.update(
                {
                    "kind": "agent",
                    "phase": phase,
                    "duration_ms": int((time.monotonic() - started) * 1000),
                }
            )
            return transition
        finally:
            context_path.unlink(missing_ok=True)

    @staticmethod
    def _agent_failure_outcome(transition: Mapping[str, Any]) -> Optional[str]:
        if transition.get("cleanup_error") is not None:
            return "agent_cleanup_failed"
        if transition.get("process_leak"):
            return "agent_process_leak"
        if transition.get("timed_out"):
            return "agent_timeout"
        if transition.get("exit_code") != 0:
            return "agent_failed"
        return None

    def drive(
        self,
        *,
        config_path: Path,
        agent_id: str,
        max_transitions: int,
    ) -> Dict[str, Any]:
        if max_transitions < 1 or max_transitions > 20:
            raise LoopSupervisorError("max_transitions 必须在 1...20")
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise LoopSupervisorError(f"Supervisor config 无效：{error}") from error
        invocation = config.get("agent_invocation")
        if not isinstance(invocation, dict):
            decision = self.inspect()
            return {
                "schema_version": SCHEMA_VERSION,
                "outcome": "agent_invocation_required",
                "decision": decision.to_dict(),
                "transitions": [],
            }
        argv_template = invocation.get("argv")
        timeout_seconds = invocation.get("timeout_seconds", 3600)
        if (
            not isinstance(argv_template, list)
            or not argv_template
            or any(not isinstance(value, str) or not value for value in argv_template)
            or not isinstance(timeout_seconds, int)
            or not 1 <= timeout_seconds <= 86400
        ):
            raise LoopSupervisorError(
                "agent_invocation 必须包含非空 argv 字符串数组和 1...86400 timeout_seconds"
            )
        auto_config = config.get("auto_materialization", {})
        if auto_config is None:
            auto_config = {}
        if not isinstance(auto_config, dict):
            raise LoopSupervisorError("auto_materialization 必须是 object")
        auto_enabled = auto_config.get("enabled") is True
        auto_policy = auto_config.get("policy")
        if auto_enabled and auto_policy != AUTO_MATERIALIZATION_POLICY:
            raise LoopSupervisorError(
                "启用 auto_materialization 时 policy 必须是 "
                + AUTO_MATERIALIZATION_POLICY
            )
        verification_config = config.get("trusted_verification", {})
        if verification_config is None:
            verification_config = {}
        if not isinstance(verification_config, dict):
            raise LoopSupervisorError("trusted_verification 必须是 object")
        trusted_verification = verification_config.get("enabled") is True
        verification_policy = verification_config.get("policy")
        if (
            trusted_verification
            and verification_policy != SUPERVISOR_VERIFICATION_POLICY
        ):
            raise LoopSupervisorError(
                "启用 trusted_verification 时 policy 必须是 "
                + SUPERVISOR_VERIFICATION_POLICY
            )

        transitions: List[Dict[str, Any]] = []
        for _ in range(max_transitions):
            before = self.inspect()
            if before.state == "auto_materialization_ready":
                if not auto_enabled:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": "auto_materialization_disabled",
                        "decision": before.to_dict(),
                        "transitions": transitions,
                    }
                item_id = before.work_item_id
                assert item_id is not None
                with self.harness.mutation_lock():
                    materialized_id = self.auto_materialize(item_id)
                transitions.append(
                    {
                        "kind": "auto_materialization",
                        "work_item_id": materialized_id,
                        "policy": auto_policy,
                    }
                )
                before = self.inspect()
            if trusted_verification:
                if before.state == "ready":
                    item_id = before.work_item_id
                    assert item_id is not None
                    with self.harness.mutation_lock():
                        self.harness.claim(item_id, agent_id)
                    before = self.inspect()

                if before.state == "implementing":
                    item_id = before.work_item_id
                    assert item_id is not None
                    control_before = self._control_binding(
                        self.harness.state(), item_id
                    )
                    transition = self._invoke_agent_phase(
                        item_id=item_id,
                        phase="implementation",
                        policy=str(verification_policy),
                        argv_template=argv_template,
                        timeout_seconds=timeout_seconds,
                    )
                    transitions.append(transition)
                    failure_outcome = self._agent_failure_outcome(transition)
                    if failure_outcome is not None:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": failure_outcome,
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    control_after = self._control_binding(
                        self.harness.state(), item_id
                    )
                    if control_after != control_before:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "agent_control_plane_mutation",
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    with self.harness.mutation_lock():
                        evidence_path = self.harness.verify(item_id)
                    evidence = json.loads(
                        evidence_path.read_text(encoding="utf-8")
                    )
                    transitions.append(
                        {
                            "kind": "supervisor_verification",
                            "work_item_id": item_id,
                            "evidence": self.harness.relative(evidence_path),
                            "result": evidence.get("result"),
                            "failure": evidence.get("failure"),
                        }
                    )
                    after_verify = self.inspect()
                    if evidence.get("result") != "passed":
                        if after_verify.state == "implementing":
                            continue
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": after_verify.reason_code.lower(),
                            "decision": after_verify.to_dict(),
                            "transitions": transitions,
                        }
                    continue

                if before.state == "verified":
                    item_id = before.work_item_id
                    assert item_id is not None
                    control_before = self._control_binding(
                        self.harness.state(), item_id
                    )
                    transition = self._invoke_agent_phase(
                        item_id=item_id,
                        phase="memory_close",
                        policy=str(verification_policy),
                        argv_template=argv_template,
                        timeout_seconds=timeout_seconds,
                    )
                    transitions.append(transition)
                    failure_outcome = self._agent_failure_outcome(transition)
                    if failure_outcome is not None:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": failure_outcome,
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    control_after = self._control_binding(
                        self.harness.state(), item_id
                    )
                    if control_after != control_before:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "agent_control_plane_mutation",
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    try:
                        with self.harness.mutation_lock():
                            close_outcome = self.harness.close(item_id)
                    except HarnessError as error:
                        transitions.append(
                            {
                                "kind": "supervisor_close",
                                "work_item_id": item_id,
                                "result": "failed",
                                "error": str(error),
                            }
                        )
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "supervisor_close_failed",
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    transitions.append(
                        {
                            "kind": "supervisor_close",
                            "work_item_id": item_id,
                            "result": close_outcome,
                        }
                    )
                    continue

                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": before.reason_code.lower(),
                    "decision": before.to_dict(),
                    "transitions": transitions,
                }

            if before.state not in {"ready", "implementing"}:
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": before.reason_code.lower(),
                    "decision": before.to_dict(),
                    "transitions": transitions,
                }
            item_id = before.work_item_id
            assert item_id is not None
            if before.state == "ready":
                with self.harness.mutation_lock():
                    self.harness.claim(item_id, agent_id)
            transition = self._invoke_agent_phase(
                item_id=item_id,
                phase="legacy",
                policy=None,
                argv_template=argv_template,
                timeout_seconds=timeout_seconds,
            )
            transitions.append(transition)
            failure_outcome = self._agent_failure_outcome(transition)
            if failure_outcome is not None:
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": failure_outcome,
                    "decision": self.inspect().to_dict(),
                    "transitions": transitions,
                }

            after = self.inspect()
            if after.to_dict() == before.to_dict():
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": "no_progress",
                    "decision": after.to_dict(),
                    "transitions": transitions,
                }
        return {
            "schema_version": SCHEMA_VERSION,
            "outcome": "transition_budget_reached",
            "decision": self.inspect().to_dict(),
            "transitions": transitions,
        }

    @staticmethod
    def _output_bytes(value: Any) -> bytes:
        if value is None:
            return b""
        if isinstance(value, bytes):
            return value
        if isinstance(value, str):
            return value.encode("utf-8")
        return bytes(value)

    @staticmethod
    def _process_group_exists(process_group_id: int) -> bool:
        try:
            os.killpg(process_group_id, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    @staticmethod
    def _signal_process_group(process_group_id: int, sig: signal.Signals) -> Optional[str]:
        try:
            os.killpg(process_group_id, sig)
            return None
        except ProcessLookupError:
            return None
        except PermissionError:
            return f"{sig.name.lower()}_permission_denied"

    def _run_agent_adapter(
        self,
        *,
        item_id: str,
        argv: Sequence[str],
        environment: Mapping[str, str],
        timeout_seconds: int,
    ) -> Dict[str, Any]:
        """Run one adapter without shell and reclaim its complete process group."""
        stdout = b""
        stderr = b""
        exit_code: Optional[int] = None
        timed_out = False
        process_leak = False
        cleanup_errors: List[str] = []

        def record_cleanup_error(value: Optional[str]) -> None:
            if value and value not in cleanup_errors:
                cleanup_errors.append(value)

        try:
            process = subprocess.Popen(
                list(argv),
                cwd=str(self.harness.root),
                env=dict(environment),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except OSError as error:
            stderr = str(error).encode("utf-8", errors="replace")
            return {
                "work_item_id": item_id,
                "argv": list(argv),
                "exit_code": None,
                "timeout_seconds": timeout_seconds,
                "timed_out": False,
                "process_leak": False,
                "cleanup_error": None,
                "stdout_bytes": 0,
                "stderr_bytes": len(stderr),
                "stdout_sha256": _sha256_bytes(stdout),
                "stderr_sha256": _sha256_bytes(stderr),
            }

        try:
            stdout, stderr = process.communicate(timeout=timeout_seconds)
            stdout = self._output_bytes(stdout)
            stderr = self._output_bytes(stderr)
            exit_code = process.returncode
        except subprocess.TimeoutExpired as error:
            timed_out = True
            stdout = self._output_bytes(error.output)
            stderr = self._output_bytes(error.stderr)
            record_cleanup_error(
                self._signal_process_group(process.pid, signal.SIGTERM)
            )
            try:
                final_stdout, final_stderr = process.communicate(timeout=0.25)
                stdout = self._output_bytes(final_stdout) or stdout
                stderr = self._output_bytes(final_stderr) or stderr
            except subprocess.TimeoutExpired as term_timeout:
                stdout = self._output_bytes(term_timeout.output) or stdout
                stderr = self._output_bytes(term_timeout.stderr) or stderr
                record_cleanup_error(
                    self._signal_process_group(process.pid, signal.SIGKILL)
                )
                try:
                    final_stdout, final_stderr = process.communicate(timeout=1.0)
                    stdout = self._output_bytes(final_stdout) or stdout
                    stderr = self._output_bytes(final_stderr) or stderr
                except subprocess.TimeoutExpired as kill_timeout:
                    stdout = self._output_bytes(kill_timeout.output) or stdout
                    stderr = self._output_bytes(kill_timeout.stderr) or stderr
                    record_cleanup_error("communicate_timeout_after_sigkill")
            exit_code = process.returncode

        if self._process_group_exists(process.pid):
            if not timed_out:
                process_leak = True
                record_cleanup_error(
                    self._signal_process_group(process.pid, signal.SIGTERM)
                )
                deadline = time.monotonic() + 0.25
                while (
                    time.monotonic() < deadline
                    and self._process_group_exists(process.pid)
                ):
                    time.sleep(0.01)
                if self._process_group_exists(process.pid):
                    record_cleanup_error(
                        self._signal_process_group(process.pid, signal.SIGKILL)
                    )
            deadline = time.monotonic() + 1.0
            while (
                time.monotonic() < deadline
                and self._process_group_exists(process.pid)
            ):
                time.sleep(0.01)
            if self._process_group_exists(process.pid):
                process_leak = True
                record_cleanup_error("process_group_survived_cleanup")

        return {
            "work_item_id": item_id,
            "argv": list(argv),
            "exit_code": exit_code,
            "timeout_seconds": timeout_seconds,
            "timed_out": timed_out,
            "process_leak": process_leak,
            "cleanup_error": ";".join(cleanup_errors) or None,
            "stdout_bytes": len(stdout),
            "stderr_bytes": len(stderr),
            "stdout_sha256": _sha256_bytes(stdout),
            "stderr_sha256": _sha256_bytes(stderr),
        }


def _replace_placeholders(value: str, replacements: Mapping[str, str]) -> str:
    result = value
    for placeholder, replacement in replacements.items():
        result = result.replace(placeholder, replacement)
    unknown = [
        part
        for part in ("{work_item_id}", "{context_path}", "{repo_root}")
        if part in result
    ]
    if unknown:
        raise LoopSupervisorError(f"无法解析 agent argv placeholder：{unknown}")
    return result


class MaterializationReviewSession:
    def __init__(
        self,
        supervisor: LoopSupervisor,
        candidate_path: Path,
        *,
        session_ttl_seconds: int = SESSION_TTL_SECONDS,
    ):
        self.supervisor = supervisor
        self.preview = supervisor.preflight_candidate(candidate_path)
        token = secrets.token_urlsafe(32)
        self.page_nonce = secrets.token_urlsafe(18)
        self.deadline = time.monotonic() + session_ttl_seconds
        self.consumed = False
        self.outcome: Optional[str] = None

        def validate_token(supplied: str) -> None:
            if self.consumed:
                raise MaterializationConflict("物化会话已使用，禁止重放")
            if time.monotonic() >= self.deadline:
                raise MaterializationConflict("物化会话已过期")
            if not secrets.compare_digest(supplied, token):
                raise MaterializationRequestError("materialization token 无效")

        def approve_callback(supplied: str) -> str:
            validate_token(supplied)
            with self.supervisor.harness.mutation_lock():
                item_id = self.supervisor.materialize(
                    self.preview,
                    reason="local one-click materialization review",
                )
            self.consumed = True
            self.outcome = item_id
            return item_id

        def cancel_callback(supplied: str) -> str:
            validate_token(supplied)
            self.consumed = True
            self.outcome = "cancelled"
            return self.outcome

        self.server = LoopbackHTTPServer(
            (LOOPBACK_HOST, 0),
            self._handler_type(approve_callback, cancel_callback),
        )
        self.port = int(self.server.server_address[1])
        self.expected_host = f"{LOOPBACK_HOST}:{self.port}"
        self.expected_origin = f"http://{self.expected_host}"
        self.__open_page = lambda opener: opener(f"{self.expected_origin}/#{token}")

    def _handler_type(self, approve_callback: Any, cancel_callback: Any) -> type:
        session = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def _headers(self) -> None:
                self.send_header("Cache-Control", "no-store, max-age=0")
                self.send_header("Pragma", "no-cache")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("X-Frame-Options", "DENY")
                self.send_header(
                    "Content-Security-Policy",
                    "default-src 'none'; "
                    f"style-src 'nonce-{session.page_nonce}'; "
                    f"script-src 'nonce-{session.page_nonce}'; "
                    "connect-src 'self'; base-uri 'none'; form-action 'none'; "
                    "frame-ancestors 'none'",
                )

            def _send(self, status: int, payload: bytes, content_type: str) -> None:
                self.send_response(status)
                self._headers()
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True

            def _json(self, status: int, value: Mapping[str, Any]) -> None:
                self._send(
                    status,
                    json.dumps(value, ensure_ascii=False).encode(),
                    "application/json; charset=utf-8",
                )

            def _valid_host(self) -> bool:
                return self.headers.get("Host") == session.expected_host

            def do_GET(self) -> None:
                if not self._valid_host():
                    self._json(400, {"error": "invalid_host"})
                elif self.path != "/":
                    self._json(404, {"error": "not_found"})
                else:
                    self._send(
                        200,
                        session.render_page().encode(),
                        "text/html; charset=utf-8",
                    )

            def do_POST(self) -> None:
                if not self._valid_host():
                    self._json(400, {"error": "invalid_host"})
                    return
                if self.path not in {"/api/approve", "/api/cancel"}:
                    self._json(404, {"error": "not_found"})
                    return
                if self.headers.get("Origin") != session.expected_origin:
                    self._json(403, {"error": "invalid_origin"})
                    return
                fetch_site = self.headers.get("Sec-Fetch-Site")
                if fetch_site is not None and fetch_site != "same-origin":
                    self._json(403, {"error": "invalid_fetch_site"})
                    return
                if not self.headers.get("Content-Type", "").lower().startswith(
                    "application/json"
                ):
                    self._json(415, {"error": "json_required"})
                    return
                try:
                    length = int(self.headers.get("Content-Length", ""))
                except ValueError:
                    self._json(400, {"error": "invalid_content_length"})
                    return
                if length < 0 or length > MAX_REQUEST_BYTES:
                    self._json(413, {"error": "request_too_large"})
                    return
                try:
                    body = json.loads(self.rfile.read(length).decode())
                except (UnicodeDecodeError, json.JSONDecodeError):
                    self._json(400, {"error": "invalid_json"})
                    return
                if body != {}:
                    self._json(400, {"error": "unexpected_fields"})
                    return
                supplied = self.headers.get("X-Materialization-Token", "")
                try:
                    outcome = (
                        approve_callback(supplied)
                        if self.path == "/api/approve"
                        else cancel_callback(supplied)
                    )
                except MaterializationRequestError as error:
                    self._json(403, {"error": str(error)})
                    return
                except MaterializationConflict as error:
                    self._json(409, {"error": str(error)})
                    return
                except Exception:
                    self._json(500, {"error": "物化失败；控制面已回滚或需人工恢复"})
                    return
                self._json(200, {"outcome": outcome})

        return Handler

    def render_page(self) -> str:
        preview = self.preview
        dependencies = "".join(
            f"<li><code>{html.escape(value)}</code></li>"
            for value in preview.dependencies
        ) or "<li>无</li>"
        scopes = "".join(
            f"<li><code>{html.escape(value)}</code></li>"
            for value in preview.allow_write
        )
        criteria = "".join(
            f"<li><strong>{html.escape(identifier)}</strong> "
            f"{html.escape(statement)}</li>"
            for identifier, statement in preview.criteria
        )
        outputs = "".join(
            f"<li><code>{html.escape(kind)} {html.escape(identifier)}@{revision}</code></li>"
            for kind, identifier, revision in preview.produces
        ) or "<li>无</li>"
        budget = html.escape(json.dumps(dict(preview.budgets), ensure_ascii=False))
        return f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Loop Supervisor 工作项物化</title>
<style nonce="{html.escape(self.page_nonce)}">
body{{margin:0;background:#f4f5f7;color:#17191d;font:15px -apple-system,BlinkMacSystemFont,sans-serif}}
main{{max-width:980px;margin:32px auto;padding:0 20px 48px}}
section{{background:#fff;border:1px solid #dfe2e7;border-radius:14px;padding:22px;margin:14px 0}}
.warn{{background:#fff4dc;border-color:#f1cd85}}code{{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere}}
button{{border:0;border-radius:10px;padding:12px 18px;font-weight:650;cursor:pointer}}
#approve{{background:#1677ff;color:#fff}}#cancel{{background:#e8eaed;margin-left:8px}}button:disabled{{opacity:.55}}
</style></head><body><main>
<h1>物化工作项：{html.escape(preview.title)}</h1>
<p><code>{html.escape(preview.item_id)}</code></p>
<section class="warn"><strong>本地 cooperative 决定</strong>
<p>点击会写入本地 WorkItemMaterialized/state/event；生产发布仍须受保护 Supervisor/CI 重验。</p></section>
<section><h2>冻结摘要</h2>
<p>Work Item：<code>{preview.work_item_sha256}</code></p>
<p>Event head：<code>{preview.event_head}</code></p>
<p>Candidate：<code>{html.escape(preview.source_relative)}</code></p>
<p>Budget：<code>{budget}</code></p></section>
<section><h2>依赖</h2><ul>{dependencies}</ul><h2>写范围</h2><ul>{scopes}</ul>
<h2>知识产出</h2><ul>{outputs}</ul><h2>验收</h2><ol>{criteria}</ol></section>
<section><button id="approve">批准并物化</button><button id="cancel">暂不物化</button>
<div id="result" role="status" aria-live="polite"></div></section>
</main><script nonce="{html.escape(self.page_nonce)}">
(()=>{{const a=document.getElementById("approve"),c=document.getElementById("cancel"),r=document.getElementById("result");
const t=location.hash.slice(1);history.replaceState(null,"","/");if(!t){{a.disabled=true;r.textContent="token 缺失";return;}}
async function send(path){{a.disabled=true;c.disabled=true;const response=await fetch(path,{{method:"POST",credentials:"omit",cache:"no-store",headers:{{"Content-Type":"application/json","X-Materialization-Token":t}},body:"{{}}"}});const value=await response.json();if(!response.ok)throw new Error(value.error||`HTTP ${{response.status}}`);return value;}}
a.onclick=async()=>{{r.textContent="正在重新校验并物化…";try{{const v=await send("/api/approve");r.textContent=`已物化：${{v.outcome}}`;}}catch(e){{r.textContent=`失败：${{e.message}}`;}}}};
c.onclick=async()=>{{r.textContent="正在取消…";try{{await send("/api/cancel");r.textContent="未物化，会话已结束";}}catch(e){{r.textContent=`失败：${{e.message}}`;}}}};
}})();</script></body></html>"""

    def open(self, opener: Any = webbrowser.open) -> None:
        self.__open_page(opener)

    def serve(self) -> str:
        self.server.timeout = min(1.0, float(REQUEST_IO_TIMEOUT_SECONDS))
        while self.outcome is None and time.monotonic() < self.deadline:
            self.server.handle_request()
        self.server.server_close()
        if self.outcome is None:
            self.outcome = "expired"
        return self.outcome


def run_materialization_review(
    supervisor: LoopSupervisor,
    candidate_path: Path,
    *,
    opener: Any = webbrowser.open,
) -> str:
    session = MaterializationReviewSession(supervisor, candidate_path)
    session.open(opener)
    print("本地物化页已在浏览器打开；等待人工点击（授权 token 不会输出）…")
    return session.serve()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Legado iOS Loop Supervisor")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("inspect", help="输出精确 loop decision")
    preflight = subparsers.add_parser(
        "preflight",
        help="只读校验 Work Item candidate 并输出冻结摘要",
    )
    preflight.add_argument("candidate", type=Path)
    drive = subparsers.add_parser("drive", help="有界调用外部 Agent adapter")
    drive.add_argument("--config", type=Path, required=True)
    drive.add_argument("--agent", required=True)
    drive.add_argument("--max-transitions", type=int, default=1)
    review = subparsers.add_parser(
        "materialize-review",
        help="打开 candidate 的本地一键物化页；无非交互 materialize 命令",
    )
    review.add_argument("candidate", type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        supervisor = LoopSupervisor(Harness(args.root))
        if args.command == "inspect":
            print(
                json.dumps(
                    supervisor.inspect().to_dict(),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.command == "preflight":
            print(
                json.dumps(
                    supervisor.preflight_candidate(args.candidate).to_dict(),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.command == "drive":
            result = supervisor.drive(
                config_path=args.config,
                agent_id=args.agent,
                max_transitions=args.max_transitions,
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return (
                0
                if result["outcome"]
                not in {
                    "agent_failed",
                    "agent_timeout",
                    "agent_process_leak",
                    "agent_cleanup_failed",
                }
                else 1
            )
        if args.command == "materialize-review":
            outcome = run_materialization_review(supervisor, args.candidate)
            print(f"materialize-review: {outcome}")
            return 0 if outcome not in {"expired", "cancelled"} else 2
    except (HarnessError, LoopSupervisorError) as error:
        print(f"loop-supervisor: {error}", file=sys.stderr)
        return 1
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
