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
from typing import Any, Dict, List, Mapping, Optional, Sequence, Set, Tuple

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
    from .demand_compiler import (
        CHARACTERIZATION_BLUEPRINT_ROOT,
        MIGRATION_BLUEPRINT_ROOT,
        MIGRATION_POLICY,
        ORACLE_BLUEPRINT_ROOT,
        TRUSTED_ORACLE_BLUEPRINT_ROOT,
        DemandCompiler,
        DemandPlan,
    )
    from .proposal_compiler import (
        COMPILER_VERSION,
        DAG_PATH,
        MANIFEST_ROOT,
        RECIPE_ROOT,
        ProposalCompiler,
        ProposalCompilerError,
    )
    from .run_journal import RunJournal, RunJournalError
    from .github_oracle_dispatcher import GitHubOracleDispatcher, GitHubOracleError
    from .github_golden_publisher import (
        WORKFLOW_PATH as GOLDEN_PUBLISHER_WORKFLOW_PATH,
        GitHubGoldenPublisherDispatcher,
        GitHubGoldenPublisherError,
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
    from demand_compiler import (  # type: ignore
        CHARACTERIZATION_BLUEPRINT_ROOT,
        MIGRATION_BLUEPRINT_ROOT,
        MIGRATION_POLICY,
        ORACLE_BLUEPRINT_ROOT,
        TRUSTED_ORACLE_BLUEPRINT_ROOT,
        DemandCompiler,
        DemandPlan,
    )
    from proposal_compiler import (  # type: ignore
        COMPILER_VERSION,
        DAG_PATH,
        MANIFEST_ROOT,
        RECIPE_ROOT,
        ProposalCompiler,
        ProposalCompilerError,
    )
    from run_journal import RunJournal, RunJournalError  # type: ignore
    from github_oracle_dispatcher import (  # type: ignore
        GitHubOracleDispatcher,
        GitHubOracleError,
    )
    from github_golden_publisher import (  # type: ignore
        WORKFLOW_PATH as GOLDEN_PUBLISHER_WORKFLOW_PATH,
        GitHubGoldenPublisherDispatcher,
        GitHubGoldenPublisherError,
    )


SCHEMA_VERSION = 1
CANDIDATE_ROOT = "ios/project/work-item-proposals/candidates"
AUTO_MATERIALIZATION_POLICY = "compiled-control-plane-v1"
DELIVERY_BLUEPRINT_ROOT = "ios/project/work-item-proposals/delivery-blueprints"
DELIVERY_MATERIALIZATION_POLICY = "bound-delivery-blueprint-v1"
MIGRATION_MATERIALIZATION_POLICY = MIGRATION_POLICY
CHARACTERIZATION_MATERIALIZATION_POLICY = (
    "source-anchored-characterization-v1"
)
SYNTHETIC_PROVENANCE_POLICY = "synthetic-source-provenance-v1"
ORACLE_MATERIALIZATION_POLICY = "source-anchored-android-oracle-v1"
TRUSTED_ORACLE_MATERIALIZATION_POLICY = (
    "source-anchored-trusted-android-oracle-v1"
)
SUPERVISOR_VERIFICATION_POLICY = "supervisor-owned-verification-v1"
BUSINESS_KNOWLEDGE_CATALOG_STALE = "Business Knowledge catalog 已过期"
TERMINAL_RECOVERY_STATUSES = {"blocked", "rejected", "exhausted", "cancelled"}
ACTIVE_DECISIONS = {
    "implementing": ("agent_required", False),
    "verified": ("memory_close_required", False),
    "awaiting_human": ("human_decision_required", True),
}
AUTO_SAFE_HARNESS_PATHS = {
    "ios/harness/demand_compiler.py",
    "ios/harness/github_oracle_dispatcher.py",
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
DELIVERY_FORBIDDEN_PREFIXES = (
    ".github/",
    "app/",
    "modules/",
    "ios/docs/",
    "ios/harness/goldens/",
    "ios/harness/schemas/",
    "ios/harness/business-knowledge/",
    "ios/harness/android-intake/",
    "ios/harness/oracle/",
    "ios/project/approvals/",
    "ios/project/requirements/",
    "ios/project/work-item-proposals/",
)
DELIVERY_FORBIDDEN_EXACT = {
    "ios/Packages/LegadoKit/Package.swift",
    "ios/harness/harness.py",
    "ios/harness/loop_supervisor.py",
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
    recovers: Optional[str]
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
            self.recovers,
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
            "recovers": self.recovers,
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
    recovers: Optional[str] = None

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
            "recovers": self.recovers,
        }


@dataclass(frozen=True)
class DeliveryMaterializationCandidate:
    blueprint_id: str
    priority: int
    head_commit: str
    blueprint_relative: str
    blueprint_sha256: str
    work_item_sha256: str
    requirement_bindings: Tuple[Tuple[str, int, str, str], ...]
    capability_binding: Tuple[str, int, str]
    golden_bindings: Tuple[Tuple[str, str, str], ...]
    dependency_bindings: Tuple[Tuple[str, str, str], ...]

    def to_dict(self) -> Dict[str, Any]:
        capability_id, revision, digest = self.capability_binding
        return {
            "blueprint_id": self.blueprint_id,
            "priority": self.priority,
            "policy": DELIVERY_MATERIALIZATION_POLICY,
            "head_commit": self.head_commit,
            "blueprint": self.blueprint_relative,
            "blueprint_sha256": self.blueprint_sha256,
            "work_item_sha256": self.work_item_sha256,
            "requirements": [
                {
                    "id": identifier,
                    "revision": revision_value,
                    "catalog_sha256": catalog_sha,
                    "record_sha256": record_sha,
                }
                for identifier, revision_value, catalog_sha, record_sha
                in self.requirement_bindings
            ],
            "capability": {
                "id": capability_id,
                "revision": revision,
                "sha256": digest,
            },
            "goldens": [
                {
                    "fixture_id": fixture_id,
                    "golden_sha256": golden_sha,
                    "receipt_sha256": receipt_sha,
                }
                for fixture_id, golden_sha, receipt_sha in self.golden_bindings
            ],
            "dependencies": [
                {
                    "work_item_id": item_id,
                    "evidence_sha256": evidence_sha,
                    "checkpoint_sha256": checkpoint_sha,
                }
                for item_id, evidence_sha, checkpoint_sha
                in self.dependency_bindings
            ],
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

    def _terminal_resolution(
        self,
        item_id: str,
        items: Mapping[str, Mapping[str, Any]],
        state_items: Mapping[str, Mapping[str, Any]],
    ) -> Mapping[str, Any]:
        return ProposalCompiler(self.harness).resolve_dependency(
            item_id,
            items,
            state_items,
        )

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

    def _trusted_oracle_recovery_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            ".github/workflows/android-oracle-attestation.yml",
            "ios/harness/oracle/contract.py",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/harness/oracle/README.md",
            "ios/harness/tests/test_oracle_contract.py",
            "ios/harness/tests/test_oracle_ci_proposal.py",
            "ios/harness/tests/test_oracle_trusted_import.py",
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "control-plane",
            "android-oracle",
            "trusted-proposal",
            "candidate-only",
            "attestation",
            "github-actions",
            "corrective",
            "recovery",
        }
        issues: List[str] = []
        if (
            spec.get("capability") != "CAP-CONFORMANCE"
            or not isinstance(spec.get("recovers"), str)
            or not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_TRUSTED_ORACLE_RECOVERY_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_TRUSTED_ORACLE_RECOVERY_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/goldens/manifest.json",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_TRUSTED_ORACLE_RECOVERY_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

    def _android_oracle_workflow_hardening_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            ".github/workflows/android-oracle-attestation.yml",
            "ios/harness/source-lab/tests/test_source_lab.py",
            "ios/harness/oracle/README.md",
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "external-execution",
            "workflow-hardening",
            "android-oracle",
            "corrective",
        }
        issues: List[str] = []
        if (
            not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_ANDROID_ORACLE_WORKFLOW_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_ANDROID_ORACLE_WORKFLOW_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            ".github/workflows/change.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/goldens/manifest.json",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_ANDROID_ORACLE_WORKFLOW_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

    def _android_oracle_ci_packager_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/tests/test_oracle_ci_proposal.py",
            "ios/harness/oracle/README.md",
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "external-execution",
            "android-oracle",
            "ci-packager",
            "corrective",
        }
        issues: List[str] = []
        if (
            not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_ANDROID_ORACLE_CI_PACKAGER_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or len(allow_write) != len(expected_allow)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_ANDROID_ORACLE_CI_PACKAGER_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            ".github/workflows/android-oracle-attestation.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/github_oracle_dispatcher.py",
            "ios/harness/oracle/contract.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/goldens/manifest.json",
            "ios/project/baseline.json",
            "ios/project/requirements/catalog.json",
            "ios/project/business-knowledge/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_ANDROID_ORACLE_CI_PACKAGER_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

    def _github_oracle_receipt_settlement_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            "ios/harness/github_oracle_receipt.py",
            "ios/harness/tests/test_github_oracle_receipt.py",
            "ios/harness/demand_compiler.py",
            "ios/harness/tests/test_demand_compiler.py",
            "ios/harness/loop_supervisor.py",
            "ios/harness/tests/test_loop_supervisor.py",
            "ios/harness/README.md",
            "ios/project/capabilities/CAP-KNOWLEDGE-CONTROL.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "external-execution",
            "android-oracle",
            "receipt-settlement",
            "corrective",
        }
        issues: List[str] = []
        if (
            not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or spec.get("source_lab", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_GITHUB_ORACLE_RECEIPT_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or len(allow_write) != len(expected_allow)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_GITHUB_ORACLE_RECEIPT_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            ".github/workflows/android-oracle-attestation.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/github_oracle_dispatcher.py",
            "ios/harness/oracle/contract.py",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/goldens/manifest.json",
            "ios/project/baseline.json",
            "ios/project/requirements/catalog.json",
            "ios/project/business-knowledge/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_GITHUB_ORACLE_RECEIPT_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

    def _github_golden_publisher_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            ".github/workflows/android-golden-publisher.yml",
            "ios/publisher/android_golden_publisher.py",
            "ios/publisher/README.md",
            "ios/harness/tests/test_android_golden_publisher.py",
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "external-execution",
            "android-oracle",
            "golden-publisher",
            "corrective",
        }
        issues: List[str] = []
        if (
            not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or spec.get("source_lab", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_GITHUB_GOLDEN_PUBLISHER_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or len(allow_write) != len(expected_allow)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_GITHUB_GOLDEN_PUBLISHER_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            ".github/workflows/android-oracle-attestation.yml",
            ".github/workflows/change.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/harness/harness.py",
            "ios/harness/demand_compiler.py",
            "ios/harness/loop_supervisor.py",
            "ios/harness/github_golden_publisher.py",
            "ios/harness/github_oracle_dispatcher.py",
            "ios/harness/github_oracle_receipt.py",
            "ios/harness/oracle/contract.py",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/goldens/manifest.json",
            "ios/project/external-execution-receipts/receipt.json",
            "ios/project/baseline.json",
            "ios/project/requirements/catalog.json",
            "ios/project/business-knowledge/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_GITHUB_GOLDEN_PUBLISHER_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

    def _github_golden_dispatcher_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            "ios/harness/github_golden_publisher.py",
            "ios/harness/tests/test_github_golden_publisher.py",
            "ios/harness/loop_supervisor.py",
            "ios/harness/tests/test_loop_supervisor.py",
            "ios/harness/supervisor.example.json",
            "ios/harness/README.md",
            "ios/project/capabilities/CAP-KNOWLEDGE-CONTROL.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "external-execution",
            "android-oracle",
            "golden-dispatcher",
            "corrective",
        }
        issues: List[str] = []
        if (
            not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or spec.get("source_lab", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_GITHUB_GOLDEN_DISPATCHER_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or len(allow_write) != len(expected_allow)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_GITHUB_GOLDEN_DISPATCHER_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            ".github/workflows/android-golden-publisher.yml",
            ".github/workflows/android-oracle-attestation.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/harness.py",
            "ios/harness/demand_compiler.py",
            "ios/harness/github_oracle_dispatcher.py",
            "ios/harness/github_oracle_receipt.py",
            "ios/harness/oracle/contract.py",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/goldens/manifest.json",
            "ios/project/external-execution-receipts/receipt.json",
            "ios/project/baseline.json",
            "ios/project/requirements/catalog.json",
            "ios/project/business-knowledge/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_GITHUB_GOLDEN_DISPATCHER_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

    def _harness_runtime_context_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        metadata = item.get("metadata", {})
        item_id = str(metadata.get("id", ""))
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            "ios/harness/harness.py",
            "ios/harness/tests/test_harness.py",
            "ios/harness/README.md",
            "ios/project/capabilities/CAP-KNOWLEDGE-CONTROL.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        required_labels = {
            "control-plane",
            "harness-runtime-context",
            "reproducibility",
            "corrective",
        }
        issues: List[str] = []
        if (
            not required_labels.issubset(labels)
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            != "not_applicable"
            or spec.get("source_lab", {}).get("mode")
            != "not_applicable"
            or set(spec.get("completion_effects", {})) - {"health"}
        ):
            issues.append(
                "AUTO_HARNESS_RUNTIME_CONTEXT_AUTHORITY_INVALID"
            )
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or len(allow_write) != len(expected_allow)
            or set(allow_write) != expected_allow
        ):
            issues.append(
                "AUTO_HARNESS_RUNTIME_CONTEXT_SCOPE_ALLOW_INVALID"
            )
        required_denials = (
            ".github/workflows/android-golden-publisher.yml",
            "app/src/main/java/example.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/loop_supervisor.py",
            "ios/harness/demand_compiler.py",
            "ios/harness/github_golden_publisher.py",
            "ios/harness/github_oracle_dispatcher.py",
            "ios/harness/github_oracle_receipt.py",
            "ios/harness/goldens/manifest.json",
            "ios/harness/oracle/contract.py",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/work-items/IOS-OLD-001.json",
            "ios/project/state.json",
            "ios/project/events.jsonl",
            "ios/project/status.md",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    "AUTO_HARNESS_RUNTIME_CONTEXT_SCOPE_DENY_MISSING:"
                    + path
                )
        return issues

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
        manifest_recovery = manifest.get("recovery")
        if manifest_recovery is not None:
            if not isinstance(manifest_recovery, dict):
                raise MaterializationConflict("PROVENANCE_RECOVERY_INVALID")
            for key in ("work_item", "evidence", "checkpoint"):
                value = manifest_recovery.get(key)
                if isinstance(value, str):
                    provenance_paths.append(value)
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
        if preview.recovers is None:
            if manifest_recovery is not None:
                raise MaterializationConflict("PROVENANCE_RECOVERY_UNEXPECTED")
        elif (
            not isinstance(manifest_recovery, dict)
            or manifest_recovery.get("predecessor") != preview.recovers
        ):
            raise MaterializationConflict("PROVENANCE_RECOVERY_MISMATCH")

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
        trusted_oracle_recovery = (
            preview.recovers is not None
            and {
                "trusted-proposal",
                "candidate-only",
                "corrective",
                "recovery",
            }.issubset(labels)
        )
        workflow_hardening = {
            "external-execution",
            "workflow-hardening",
            "android-oracle",
            "corrective",
        }.issubset(labels)
        ci_packager_corrective = {
            "external-execution",
            "android-oracle",
            "ci-packager",
            "corrective",
        }.issubset(labels)
        receipt_settlement = {
            "external-execution",
            "android-oracle",
            "receipt-settlement",
            "corrective",
        }.issubset(labels)
        golden_publisher = {
            "external-execution",
            "android-oracle",
            "golden-publisher",
            "corrective",
        }.issubset(labels)
        golden_dispatcher = {
            "external-execution",
            "android-oracle",
            "golden-dispatcher",
            "corrective",
        }.issubset(labels)
        runtime_context_repro = {
            "control-plane",
            "harness-runtime-context",
            "reproducibility",
            "corrective",
        }.issubset(labels)
        if trusted_oracle_recovery:
            recovery_issues = (
                self._trusted_oracle_recovery_scope_issues(item)
            )
            if recovery_issues:
                raise MaterializationConflict(
                    ";".join(recovery_issues)
                )
        elif workflow_hardening:
            workflow_issues = (
                self._android_oracle_workflow_hardening_scope_issues(
                    item
                )
            )
            if workflow_issues:
                raise MaterializationConflict(
                    ";".join(workflow_issues)
                )
        elif ci_packager_corrective:
            packager_issues = (
                self._android_oracle_ci_packager_scope_issues(item)
            )
            if packager_issues:
                raise MaterializationConflict(
                    ";".join(packager_issues)
                )
        elif receipt_settlement:
            receipt_issues = (
                self._github_oracle_receipt_settlement_scope_issues(
                    item
                )
            )
            if receipt_issues:
                raise MaterializationConflict(
                    ";".join(receipt_issues)
                )
        elif golden_publisher:
            publisher_issues = (
                self._github_golden_publisher_scope_issues(item)
            )
            if publisher_issues:
                raise MaterializationConflict(
                    ";".join(publisher_issues)
                )
        elif golden_dispatcher:
            dispatcher_issues = (
                self._github_golden_dispatcher_scope_issues(item)
            )
            if dispatcher_issues:
                raise MaterializationConflict(
                    ";".join(dispatcher_issues)
                )
        elif runtime_context_repro:
            runtime_context_issues = (
                self._harness_runtime_context_scope_issues(item)
            )
            if runtime_context_issues:
                raise MaterializationConflict(
                    ";".join(runtime_context_issues)
                )
        else:
            rejected_scope = [
                pattern
                for pattern in allow_write
                if not isinstance(pattern, str)
                or not self._auto_scope_allowed(pattern)
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
            recovers=preview.recovers,
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
    def _static_pattern_prefix(pattern: str) -> str:
        indexes = [
            index
            for token in ("*", "?", "[")
            if (index := pattern.find(token)) >= 0
        ]
        return pattern[: min(indexes)] if indexes else pattern

    @classmethod
    def _pattern_within(cls, pattern: str, owner_pattern: str) -> bool:
        if pattern in {"*", "**", "ios/*", "ios/**"}:
            return False
        owner_prefix = cls._static_pattern_prefix(owner_pattern)
        pattern_prefix = cls._static_pattern_prefix(pattern)
        if not owner_prefix or not pattern_prefix.startswith(owner_prefix):
            return False
        if not any(token in owner_pattern for token in "*?["):
            return pattern == owner_pattern
        return True

    def _delivery_scope_issues(
        self,
        item: Mapping[str, Any],
        capability: Mapping[str, Any],
    ) -> List[str]:
        item_id = str(item.get("metadata", {}).get("id", ""))
        spec = item.get("spec", {})
        scope = spec.get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        owners = capability.get("owners", {})
        owner_paths = owners.get("paths", []) if isinstance(owners, dict) else []
        targets = owners.get("targets", []) if isinstance(owners, dict) else []
        capability_id = str(capability.get("id", ""))
        support_patterns = {
            f"ios/project/capabilities/{capability_id}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        support_patterns.update(
            f"ios/Packages/LegadoKit/Tests/{target}Tests/**"
            for target in targets
            if isinstance(target, str) and target
        )
        issues: List[str] = []
        for pattern in allow_write:
            if not isinstance(pattern, str):
                issues.append("DELIVERY_SCOPE_NON_STRING")
                continue
            if (
                pattern in DELIVERY_FORBIDDEN_EXACT
                or pattern.startswith(DELIVERY_FORBIDDEN_PREFIXES)
                or "entitlement" in pattern.lower()
                or "migration" in pattern.lower()
            ):
                issues.append(f"DELIVERY_SCOPE_FORBIDDEN:{pattern}")
                continue
            if any(
                self._pattern_within(pattern, owner)
                for owner in owner_paths
                if isinstance(owner, str)
            ):
                continue
            if any(
                self._pattern_within(pattern, support)
                for support in support_patterns
            ):
                continue
            issues.append(f"DELIVERY_SCOPE_OUTSIDE_OWNER:{pattern}")
        required_denials = (
            ".github/workflows/change.yml",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/harness/goldens/manifest.json",
            "ios/harness/schemas/work-item.schema.json",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(f"DELIVERY_SCOPE_DENY_MISSING:{path}")
        for pattern in allow_write:
            prefix = (
                self._static_pattern_prefix(pattern)
                if isinstance(pattern, str)
                else ""
            )
            if prefix and path_matches(prefix.rstrip("/"), deny_write):
                issues.append(f"DELIVERY_SCOPE_ALLOW_DENY_OVERLAP:{pattern}")
        return issues

    def _migration_scope_issues(
        self,
        item: Mapping[str, Any],
        proposal_path: str,
    ) -> List[str]:
        item_id = str(item.get("metadata", {}).get("id", ""))
        spec = item.get("spec", {})
        allow_write = spec.get("scope", {}).get("allow_write", [])
        deny_write = spec.get("scope", {}).get("deny_write", [])
        capability_id = str(spec.get("capability", ""))
        allowed_exact = {
            proposal_path,
            f"ios/project/capabilities/{capability_id}.json",
            f"ios/project/checkpoints/{item_id}.json",
        }
        allowed_prefixes = (
            "ios/project/business-knowledge/packets/proposals/",
            "ios/project/business-knowledge/drivers/proposals/",
        )
        issues: List[str] = []
        for pattern in allow_write:
            if not isinstance(pattern, str):
                issues.append("MIGRATION_SCOPE_NON_STRING")
                continue
            if pattern in allowed_exact:
                continue
            if pattern == "ios/project/pitfalls/PIT-*.json":
                continue
            if pattern.startswith(allowed_prefixes) and not any(
                token in pattern for token in "*?["
            ):
                continue
            issues.append(f"MIGRATION_SCOPE_FORBIDDEN:{pattern}")
        required_denials = (
            ".github/workflows/change.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/harness/goldens/manifest.json",
            "ios/harness/source-lab/coverage-policy-v1.json",
            "ios/harness/schemas/work-item.schema.json",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(f"MIGRATION_SCOPE_DENY_MISSING:{path}")
        return issues

    def _migration_plan_preview(
        self,
        plan: DemandPlan,
    ) -> MaterializationPreview:
        if (
            plan.policy != MIGRATION_MATERIALIZATION_POLICY
            or plan.intent_kind != "android_migration"
            or plan.state != "migration_intake_ready"
        ):
            raise MaterializationConflict("MIGRATION_PLAN_STATE_INVALID")
        blueprint = plan.bindings.get("blueprint", {})
        proposal = plan.bindings.get("requirement_proposal", {})
        blueprint_relative = blueprint.get("path")
        proposal_path = proposal.get("path")
        if (
            not isinstance(blueprint_relative, str)
            or not isinstance(proposal_path, str)
        ):
            raise MaterializationConflict(
                "MIGRATION_PLAN_BINDING_INVALID"
            )
        blueprint_path = self.harness.resolve(blueprint_relative)
        preview = self.preflight_candidate(
            blueprint_path,
            allowed_root=MIGRATION_BLUEPRINT_ROOT,
        )
        if (
            preview.item_id != plan.target_work_item_id
            or preview.work_item_sha256
            != blueprint.get("work_item_sha256")
            or preview.source_fingerprint != blueprint.get("sha256")
        ):
            raise MaterializationConflict(
                "MIGRATION_MATERIALIZATION_BINDING_DRIFT"
            )
        try:
            item = json.loads(blueprint_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"MIGRATION_BLUEPRINT_INVALID:{error}"
            ) from error
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        if (
            metadata.get("risk") == "critical"
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "control_plane"
            or spec.get("knowledge", {}).get("mode")
            not in {"produce", "not_applicable"}
            or set(spec.get("completion_effects", {})) - {"health"}
            or spec.get("capability") != "CAP-KNOWLEDGE-CONTROL"
        ):
            raise MaterializationConflict(
                "MIGRATION_BLUEPRINT_AUTHORITY_INVALID"
            )
        issues = self._migration_scope_issues(item, proposal_path)
        if issues:
            raise MaterializationConflict(";".join(issues))
        return preview

    def _characterization_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        item_id = str(item.get("metadata", {}).get("id", ""))
        spec = item.get("spec", {})
        source_lab = spec.get("source_lab", {})
        scenarios = source_lab.get("scenarios", [])
        scenario = scenarios[0] if len(scenarios) == 1 else ""
        capability_id = str(spec.get("capability", ""))
        allow_write = spec.get("scope", {}).get("allow_write", [])
        deny_write = spec.get("scope", {}).get("deny_write", [])
        expected_allow = {
            f"ios/harness/fixtures/source-lab/{scenario}/**",
            f"ios/project/capabilities/{capability_id}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        issues: List[str] = []
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or set(allow_write) != expected_allow
        ):
            issues.append("CHARACTERIZATION_SCOPE_ALLOW_INVALID")
        required_denials = (
            ".github/workflows/change.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/source-lab/manifest.json",
            "ios/harness/source-lab/coverage-policy-v1.json",
            "ios/harness/oracle/android_runner.py",
            "ios/harness/goldens/manifest.json",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    f"CHARACTERIZATION_SCOPE_DENY_MISSING:{path}"
                )
        return issues

    def _characterization_plan_preview(
        self,
        plan: DemandPlan,
    ) -> MaterializationPreview:
        if (
            plan.policy != MIGRATION_MATERIALIZATION_POLICY
            or plan.intent_kind != "android_migration"
            or plan.state != "characterization_ready"
        ):
            raise MaterializationConflict(
                "CHARACTERIZATION_PLAN_STATE_INVALID"
            )
        binding = plan.bindings.get("characterization_blueprint", {})
        relative = binding.get("path")
        if not isinstance(relative, str):
            raise MaterializationConflict(
                "CHARACTERIZATION_PLAN_BINDING_INVALID"
            )
        path = self.harness.resolve(relative)
        preview = self.preflight_candidate(
            path,
            allowed_root=CHARACTERIZATION_BLUEPRINT_ROOT,
            require_filename_match=False,
            policy_managed_gates=("scenario-provenance-review",),
        )
        if (
            preview.item_id != plan.target_work_item_id
            or preview.work_item_sha256
            != binding.get("work_item_sha256")
            or preview.source_fingerprint != binding.get("sha256")
        ):
            raise MaterializationConflict(
                "CHARACTERIZATION_MATERIALIZATION_BINDING_DRIFT"
            )
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"CHARACTERIZATION_BLUEPRINT_INVALID:{error}"
            ) from error
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        source_lab = spec.get("source_lab", {})
        requirements = spec.get("requirements", {})
        accepted = [
            artifact
            for artifact in plan.artifacts
            if artifact.get("kind") == "requirement"
            and artifact.get("status") == "accepted"
        ]
        expected_refs = [
            {
                "id": value.get("id"),
                "revision": value.get("revision"),
                "clauses": value.get("clauses"),
            }
            for value in accepted
        ]
        if (
            metadata.get("risk") == "critical"
            or spec.get("gates") != ["scenario-provenance-review"]
            or requirements.get("mode") != "characterization"
            or len(expected_refs) != 1
            or requirements.get("refs") != expected_refs
            or source_lab.get("mode") != "extend"
            or not isinstance(source_lab.get("behaviors"), list)
            or not source_lab.get("behaviors")
            or not isinstance(source_lab.get("scenarios"), list)
            or len(source_lab.get("scenarios")) != 1
            or set(spec.get("completion_effects", {})) - {"health"}
            or spec.get("capability") != "CAP-CONFORMANCE"
        ):
            raise MaterializationConflict(
                "CHARACTERIZATION_BLUEPRINT_AUTHORITY_INVALID"
            )
        issues = self._characterization_scope_issues(item)
        if issues:
            raise MaterializationConflict(";".join(issues))
        return preview

    def _oracle_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        item_id = str(item.get("metadata", {}).get("id", ""))
        capability_id = str(
            item.get("spec", {}).get("capability", "")
        )
        scope = item.get("spec", {}).get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            "ios/harness/oracle/android-runner/**",
            "ios/harness/oracle/README.md",
            "ios/harness/tests/test_android_oracle_runner.py",
            f"ios/project/capabilities/{capability_id}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        issues: List[str] = []
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or set(allow_write) != expected_allow
        ):
            issues.append("ORACLE_SCOPE_ALLOW_INVALID")
        required_denials = (
            ".github/workflows/change.yml",
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/goldens/manifest.json",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(f"ORACLE_SCOPE_DENY_MISSING:{path}")
        return issues

    def _oracle_plan_preview(
        self,
        plan: DemandPlan,
    ) -> MaterializationPreview:
        if (
            plan.policy != MIGRATION_MATERIALIZATION_POLICY
            or plan.intent_kind != "android_migration"
            or plan.state != "oracle_ready"
        ):
            raise MaterializationConflict("ORACLE_PLAN_STATE_INVALID")
        binding = plan.bindings.get("oracle_blueprint", {})
        relative = binding.get("path")
        if not isinstance(relative, str):
            raise MaterializationConflict(
                "ORACLE_PLAN_BINDING_INVALID"
            )
        path = self.harness.resolve(relative)
        preview = self.preflight_candidate(
            path,
            allowed_root=ORACLE_BLUEPRINT_ROOT,
            require_filename_match=False,
        )
        if (
            preview.item_id != plan.target_work_item_id
            or preview.work_item_sha256
            != binding.get("work_item_sha256")
            or preview.source_fingerprint != binding.get("sha256")
        ):
            raise MaterializationConflict(
                "ORACLE_MATERIALIZATION_BINDING_DRIFT"
            )
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"ORACLE_BLUEPRINT_INVALID:{error}"
            ) from error
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        source_lab = spec.get("source_lab", {})
        accepted = [
            artifact
            for artifact in plan.artifacts
            if artifact.get("kind") == "requirement"
            and artifact.get("status") == "accepted"
        ]
        scenarios = [
            artifact
            for artifact in plan.artifacts
            if artifact.get("kind") == "source_lab_scenario"
            and artifact.get("status") == "candidate"
        ]
        expected_refs = [
            {
                "id": value.get("id"),
                "revision": value.get("revision"),
                "clauses": value.get("clauses"),
            }
            for value in accepted
        ]
        if (
            metadata.get("risk") == "critical"
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "characterization"
            or len(expected_refs) != 1
            or spec.get("requirements", {}).get("refs")
            != expected_refs
            or source_lab.get("mode") != "reuse"
            or len(scenarios) != 1
            or source_lab.get("scenarios")
            != [scenarios[0].get("id")]
            or not isinstance(source_lab.get("behaviors"), list)
            or not source_lab.get("behaviors")
            or set(spec.get("completion_effects", {})) - {"health"}
            or spec.get("capability") != "CAP-CONFORMANCE"
        ):
            raise MaterializationConflict(
                "ORACLE_BLUEPRINT_AUTHORITY_INVALID"
            )
        issues = self._oracle_scope_issues(item)
        if issues:
            raise MaterializationConflict(";".join(issues))
        return preview

    def _trusted_oracle_scope_issues(
        self,
        item: Mapping[str, Any],
    ) -> List[str]:
        item_id = str(item.get("metadata", {}).get("id", ""))
        capability_id = str(
            item.get("spec", {}).get("capability", "")
        )
        scope = item.get("spec", {}).get("scope", {})
        allow_write = scope.get("allow_write", [])
        deny_write = scope.get("deny_write", [])
        expected_allow = {
            ".github/workflows/android-oracle-attestation.yml",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
            "ios/harness/oracle/README.md",
            "ios/harness/tests/test_oracle_ci_proposal.py",
            "ios/harness/tests/test_oracle_trusted_import.py",
            f"ios/project/capabilities/{capability_id}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        }
        issues: List[str] = []
        if (
            not isinstance(allow_write, list)
            or any(not isinstance(value, str) for value in allow_write)
            or set(allow_write) != expected_allow
        ):
            issues.append("TRUSTED_ORACLE_SCOPE_ALLOW_INVALID")
        required_denials = (
            "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt",
            "modules/book/src/main/java/example.kt",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/publisher/android_golden_publisher.py",
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json",
            "ios/harness/source-lab/source_lab.py",
            "ios/harness/goldens/manifest.json",
            "ios/harness/oracle/android-runner/orchestrator.py",
            "ios/project/requirements/catalog.json",
            "ios/project/approvals/decision.json",
            "ios/project/work-item-proposals/candidate.json",
            "ios/docs/architecture.md",
        )
        for path in required_denials:
            if not path_matches(path, deny_write):
                issues.append(
                    f"TRUSTED_ORACLE_SCOPE_DENY_MISSING:{path}"
                )
        return issues

    def _trusted_oracle_plan_preview(
        self,
        plan: DemandPlan,
    ) -> MaterializationPreview:
        if (
            plan.policy != MIGRATION_MATERIALIZATION_POLICY
            or plan.intent_kind != "android_migration"
            or plan.state != "trusted_oracle_ready"
        ):
            raise MaterializationConflict(
                "TRUSTED_ORACLE_PLAN_STATE_INVALID"
            )
        binding = plan.bindings.get(
            "trusted_oracle_blueprint",
            {},
        )
        relative = binding.get("path")
        if not isinstance(relative, str):
            raise MaterializationConflict(
                "TRUSTED_ORACLE_PLAN_BINDING_INVALID"
            )
        path = self.harness.resolve(relative)
        preview = self.preflight_candidate(
            path,
            allowed_root=TRUSTED_ORACLE_BLUEPRINT_ROOT,
            require_filename_match=False,
        )
        if (
            preview.item_id != plan.target_work_item_id
            or preview.work_item_sha256
            != binding.get("work_item_sha256")
            or preview.source_fingerprint != binding.get("sha256")
        ):
            raise MaterializationConflict(
                "TRUSTED_ORACLE_MATERIALIZATION_BINDING_DRIFT"
            )
        try:
            item = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"TRUSTED_ORACLE_BLUEPRINT_INVALID:{error}"
            ) from error
        metadata = item.get("metadata", {})
        labels = set(metadata.get("labels", []))
        spec = item.get("spec", {})
        source_lab = spec.get("source_lab", {})
        accepted = [
            artifact
            for artifact in plan.artifacts
            if artifact.get("kind") == "requirement"
            and artifact.get("status") == "accepted"
        ]
        scenarios = [
            artifact
            for artifact in plan.artifacts
            if artifact.get("kind") == "source_lab_scenario"
            and artifact.get("status") == "candidate"
        ]
        completions = [
            artifact
            for artifact in plan.artifacts
            if artifact.get("kind") == "oracle_completion"
            and artifact.get("status") == "completed"
        ]
        expected_refs = [
            {
                "id": value.get("id"),
                "revision": value.get("revision"),
                "clauses": value.get("clauses"),
            }
            for value in accepted
        ]
        if (
            metadata.get("risk") == "critical"
            or not {"android-oracle", "candidate-only"}.issubset(
                labels
            )
            or spec.get("gates") != []
            or spec.get("requirements", {}).get("mode")
            != "characterization"
            or len(expected_refs) != 1
            or spec.get("requirements", {}).get("refs")
            != expected_refs
            or source_lab.get("mode") != "reuse"
            or len(scenarios) != 1
            or source_lab.get("scenarios")
            != [scenarios[0].get("id")]
            or not isinstance(source_lab.get("behaviors"), list)
            or not source_lab.get("behaviors")
            or len(completions) != 1
            or spec.get("depends_on")
            != [completions[0].get("id")]
            or set(spec.get("completion_effects", {})) - {"health"}
            or spec.get("capability") != "CAP-CONFORMANCE"
        ):
            raise MaterializationConflict(
                "TRUSTED_ORACLE_BLUEPRINT_AUTHORITY_INVALID"
            )
        issues = self._trusted_oracle_scope_issues(item)
        if issues:
            raise MaterializationConflict(";".join(issues))
        return preview

    def _delivery_candidate(
        self,
        blueprint_path: Path,
        *,
        head_commit: Optional[str] = None,
    ) -> DeliveryMaterializationCandidate:
        head = head_commit or self._clean_head()
        preview = self.preflight_candidate(
            blueprint_path,
            allowed_root=DELIVERY_BLUEPRINT_ROOT,
        )
        blueprint_relative = preview.source_relative
        self._require_head_regular((blueprint_relative,))
        try:
            item = json.loads(blueprint_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"DELIVERY_BLUEPRINT_INVALID:{error}"
            ) from error
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        binding = spec.get("delivery_blueprint")
        if (
            not isinstance(binding, dict)
            or set(binding)
            != {"policy", "capability_revision", "golden_fixtures"}
            or binding.get("policy") != DELIVERY_MATERIALIZATION_POLICY
        ):
            raise MaterializationConflict("DELIVERY_BLUEPRINT_CONTRACT_INVALID")
        if metadata.get("risk") == "critical" or spec.get("gates") != []:
            raise MaterializationConflict("DELIVERY_DECISION_OR_RISK_REQUIRED")
        if spec.get("requirements", {}).get("mode") != "implementation":
            raise MaterializationConflict("DELIVERY_REQUIREMENT_MODE_INVALID")
        if spec.get("knowledge", {}).get("mode") not in {
            "not_applicable",
            "consume",
        }:
            raise MaterializationConflict("DELIVERY_KNOWLEDGE_AUTHORITY_DENIED")
        if set(spec.get("completion_effects", {})) - {"health"}:
            raise MaterializationConflict("DELIVERY_AUTHORITY_EFFECT_DENIED")
        priority = metadata.get("priority")
        if not isinstance(priority, int):
            raise MaterializationConflict("DELIVERY_PRIORITY_INVALID")

        catalog_relative = "ios/project/requirements/catalog.json"
        catalog_path = self.harness.resolve(catalog_relative)
        self._require_head_regular((catalog_relative,))
        try:
            catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(
                f"DELIVERY_REQUIREMENT_CATALOG_INVALID:{error}"
            ) from error
        catalog_entries = {
            (entry.get("id"), entry.get("revision")): entry
            for entry in catalog.get("requirements", [])
            if isinstance(entry, dict)
        }
        catalog_sha = _sha256_bytes(catalog_path.read_bytes())
        requirement_bindings: List[Tuple[str, int, str, str]] = []
        covered_clauses: Set[str] = set()
        for criterion in spec.get("acceptance", {}).get("criteria", []):
            if isinstance(criterion, dict):
                covered_clauses.update(
                    value
                    for value in criterion.get("requirement_clauses", [])
                    if isinstance(value, str)
                )
        for reference in spec.get("requirements", {}).get("refs", []):
            identifier = reference["id"]
            revision = reference["revision"]
            entry = catalog_entries.get((identifier, revision))
            if (
                not isinstance(entry, dict)
                or entry.get("status") != "accepted"
                or entry.get("readiness") != "implementation_ready"
                or not set(reference["clauses"]).issubset(
                    set(entry.get("clauses", []))
                )
            ):
                raise MaterializationConflict(
                    f"DELIVERY_REQUIREMENT_NOT_READY:{identifier}@{revision}"
                )
            expected_coverage = {
                f"{identifier}#{clause}" for clause in reference["clauses"]
            }
            if not expected_coverage.issubset(covered_clauses):
                raise MaterializationConflict(
                    f"DELIVERY_REQUIREMENT_ACCEPTANCE_GAP:{identifier}"
                )
            record_relative = entry.get("path")
            if not isinstance(record_relative, str):
                raise MaterializationConflict("DELIVERY_REQUIREMENT_PATH_INVALID")
            self._require_head_regular((record_relative,))
            record_path = self.harness.resolve(record_relative)
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record_sha = sha256_json(record)
            if record_sha != entry.get("record_sha256"):
                raise MaterializationConflict(
                    f"DELIVERY_REQUIREMENT_RECORD_DRIFT:{identifier}"
                )
            if (
                record.get("id") != identifier
                or record.get("revision") != revision
                or record.get("status") != "accepted"
                or record.get("readiness", {}).get("state")
                != "implementation_ready"
            ):
                raise MaterializationConflict(
                    f"DELIVERY_REQUIREMENT_RECORD_INVALID:{identifier}"
                )
            requirement_bindings.append(
                (identifier, revision, catalog_sha, record_sha)
            )

        capability_id = spec.get("capability")
        capability_relative = (
            f"ios/project/capabilities/{capability_id}.json"
        )
        self._require_head_regular((capability_relative,))
        capability_path = self.harness.resolve(capability_relative)
        capability_sha = _sha256_bytes(capability_path.read_bytes())
        capability = json.loads(capability_path.read_text(encoding="utf-8"))
        capability_revision = binding.get("capability_revision")
        if (
            capability.get("id") != capability_id
            or not isinstance(capability_revision, int)
            or capability.get("revision") != capability_revision
        ):
            raise MaterializationConflict("DELIVERY_CAPABILITY_BINDING_DRIFT")
        active_decisions = set(capability.get("active_decisions", []))
        unknown_decisions = [
            reference
            for reference in spec.get("architecture_refs", [])
            if isinstance(reference, str)
            and reference.startswith("ADR-")
            and reference not in active_decisions
        ]
        if unknown_decisions:
            raise MaterializationConflict(
                "DELIVERY_ARCHITECTURE_DECISION_DRIFT:"
                + ",".join(unknown_decisions)
            )
        scope_issues = self._delivery_scope_issues(item, capability)
        if scope_issues:
            raise MaterializationConflict(";".join(scope_issues))

        manifest_relative = "ios/harness/goldens/manifest.json"
        self._require_head_regular((manifest_relative,))
        manifest_path = self.harness.resolve(manifest_relative)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        fixture_ids = binding.get("golden_fixtures")
        if (
            not isinstance(fixture_ids, list)
            or not fixture_ids
            or len(fixture_ids) != len(set(fixture_ids))
            or any(not isinstance(value, str) for value in fixture_ids)
        ):
            raise MaterializationConflict("DELIVERY_GOLDEN_SELECTOR_INVALID")
        golden_bindings: List[Tuple[str, str, str]] = []
        for fixture_id in fixture_ids:
            entry = manifest.get("fixtures", {}).get(fixture_id)
            if not isinstance(entry, dict):
                raise MaterializationConflict(
                    f"DELIVERY_GOLDEN_MISSING:{fixture_id}"
                )
            golden_relative = entry.get("path")
            receipt_relative = entry.get("release_receipt")
            if not isinstance(golden_relative, str) or not isinstance(
                receipt_relative, str
            ):
                raise MaterializationConflict(
                    f"DELIVERY_GOLDEN_BINDING_INVALID:{fixture_id}"
                )
            self._require_head_regular((golden_relative, receipt_relative))
            golden_path = self.harness.resolve(golden_relative)
            receipt_path = self.harness.resolve(receipt_relative)
            golden_sha = _sha256_bytes(golden_path.read_bytes())
            receipt_sha = _sha256_bytes(receipt_path.read_bytes())
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
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
                raise MaterializationConflict(
                    f"DELIVERY_GOLDEN_RECEIPT_DRIFT:{fixture_id}"
                )
            golden_bindings.append((fixture_id, golden_sha, receipt_sha))

        state_items = self.harness.state().get("work_items", {})
        dependency_bindings: List[Tuple[str, str, str]] = []
        for dependency in spec.get("depends_on", []):
            runtime = state_items.get(dependency, {})
            evidence_relative = runtime.get("last_evidence")
            checkpoint_relative = (
                f"ios/project/checkpoints/{dependency}.json"
            )
            if (
                runtime.get("status") != "completed"
                or not isinstance(evidence_relative, str)
            ):
                raise MaterializationConflict(
                    f"DELIVERY_DEPENDENCY_INCOMPLETE:{dependency}"
                )
            self._require_head_regular(
                (evidence_relative, checkpoint_relative)
            )
            dependency_bindings.append(
                (
                    dependency,
                    _sha256_bytes(
                        self.harness.resolve(evidence_relative).read_bytes()
                    ),
                    _sha256_bytes(
                        self.harness.resolve(checkpoint_relative).read_bytes()
                    ),
                )
            )
        return DeliveryMaterializationCandidate(
            blueprint_id=preview.item_id,
            priority=priority,
            head_commit=head,
            blueprint_relative=blueprint_relative,
            blueprint_sha256=_sha256_bytes(blueprint_path.read_bytes()),
            work_item_sha256=preview.work_item_sha256,
            requirement_bindings=tuple(requirement_bindings),
            capability_binding=(
                str(capability_id),
                capability_revision,
                capability_sha,
            ),
            golden_bindings=tuple(golden_bindings),
            dependency_bindings=tuple(dependency_bindings),
        )

    def delivery_materialization_candidates(
        self,
    ) -> Tuple[
        Tuple[DeliveryMaterializationCandidate, ...],
        Tuple[Mapping[str, Any], ...],
    ]:
        if not isinstance(self.harness, Harness):
            return (), ()
        blueprint_root = self.harness.resolve(DELIVERY_BLUEPRINT_ROOT)
        if not blueprint_root.exists():
            return (), ()
        if blueprint_root.is_symlink() or not blueprint_root.is_dir():
            return (), ({"reason_code": "DELIVERY_BLUEPRINT_ROOT_INVALID"},)
        try:
            head = self._clean_head()
        except MaterializationConflict as error:
            return (), ({"reason_code": str(error)},)
        existing = set(self.harness.work_items()) | set(
            self.harness.state().get("work_items", {})
        )
        eligible: List[DeliveryMaterializationCandidate] = []
        blockers: List[Mapping[str, Any]] = []
        for path in sorted(blueprint_root.glob("*.json")):
            if path.stem in existing:
                continue
            try:
                eligible.append(
                    self._delivery_candidate(path, head_commit=head)
                )
            except (MaterializationConflict, HarnessError) as error:
                blockers.append(
                    {
                        "blueprint_id": path.stem,
                        "reason_code": str(error),
                    }
                )
        return tuple(
            sorted(
                eligible,
                key=lambda value: (-value.priority, value.blueprint_id),
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

    @staticmethod
    def _select_delivery_candidate(
        eligible: Sequence[DeliveryMaterializationCandidate],
    ) -> Tuple[
        Optional[DeliveryMaterializationCandidate],
        Optional[Mapping[str, Any]],
    ]:
        if not eligible:
            return None, None
        highest = eligible[0].priority
        tied = [value for value in eligible if value.priority == highest]
        if len(tied) != 1:
            return None, {
                "reason_code": "DELIVERY_MATERIALIZATION_PRIORITY_AMBIGUOUS",
                "priority": highest,
                "blueprint_ids": [value.blueprint_id for value in tied],
            }
        return tied[0], None

    def _demand_decision(
        self,
        warnings: Sequence[str],
    ) -> Optional[LoopDecision]:
        if not isinstance(self.harness, Harness):
            return None
        plans, blockers = DemandCompiler(self.harness.root).plans()
        if blockers:
            return LoopDecision(
                state="demand_invalid",
                reason_code="DEMAND_INTENT_INVALID",
                work_item_id=None,
                requires_human=False,
                blockers=blockers,
                warnings=tuple(warnings),
            )
        plans = tuple(
            plan for plan in plans if plan.state != "delivery_completed"
        )
        if not plans:
            return None
        highest = plans[0].priority
        tied = [plan for plan in plans if plan.priority == highest]
        if len(tied) != 1:
            return LoopDecision(
                state="demand_blocked",
                reason_code="DEMAND_PRIORITY_AMBIGUOUS",
                work_item_id=None,
                requires_human=False,
                blockers=(
                    {
                        "priority": highest,
                        "intent_ids": [plan.intent_id for plan in tied],
                    },
                ),
                warnings=tuple(warnings),
            )
        plan = tied[0]
        if plan.state == "migration_intake_ready":
            try:
                self._migration_plan_preview(plan)
            except (MaterializationConflict, HarnessError) as error:
                return LoopDecision(
                    state="demand_invalid",
                    reason_code="MIGRATION_BLUEPRINT_INVALID",
                    work_item_id=plan.target_work_item_id,
                    requires_human=False,
                    blockers=(
                        {
                            "intent_id": plan.intent_id,
                            "reason_code": str(error),
                        },
                    ),
                    warnings=tuple(warnings),
                    details={"demand_plan": plan.to_dict()},
                )
        if plan.state == "characterization_ready":
            try:
                self._characterization_plan_preview(plan)
            except (MaterializationConflict, HarnessError) as error:
                return LoopDecision(
                    state="demand_invalid",
                    reason_code="CHARACTERIZATION_BLUEPRINT_INVALID",
                    work_item_id=plan.target_work_item_id,
                    requires_human=False,
                    blockers=(
                        {
                            "intent_id": plan.intent_id,
                            "reason_code": str(error),
                        },
                    ),
                    warnings=tuple(warnings),
                    details={"demand_plan": plan.to_dict()},
                )
        if plan.state == "oracle_ready":
            try:
                self._oracle_plan_preview(plan)
            except (MaterializationConflict, HarnessError) as error:
                return LoopDecision(
                    state="demand_invalid",
                    reason_code="ORACLE_BLUEPRINT_INVALID",
                    work_item_id=plan.target_work_item_id,
                    requires_human=False,
                    blockers=(
                        {
                            "intent_id": plan.intent_id,
                            "reason_code": str(error),
                        },
                    ),
                    warnings=tuple(warnings),
                    details={"demand_plan": plan.to_dict()},
                )
        if plan.state == "trusted_oracle_ready":
            try:
                self._trusted_oracle_plan_preview(plan)
            except (MaterializationConflict, HarnessError) as error:
                return LoopDecision(
                    state="demand_invalid",
                    reason_code="TRUSTED_ORACLE_BLUEPRINT_INVALID",
                    work_item_id=plan.target_work_item_id,
                    requires_human=False,
                    blockers=(
                        {
                            "intent_id": plan.intent_id,
                            "reason_code": str(error),
                        },
                    ),
                    warnings=tuple(warnings),
                    details={"demand_plan": plan.to_dict()},
                )
        state_mapping = {
            "knowledge_authority_required": "authority_transition_required",
            "requirement_readiness_required": (
                "authority_transition_required"
            ),
            "blueprint_required": "demand_materialization_required",
            "delivery_ready": "demand_inconsistent",
            "migration_intake_ready": "migration_materialization_ready",
            "requirement_authority_required": (
                "authority_transition_required"
            ),
            "characterization_blueprint_required": (
                "demand_materialization_required"
            ),
            "characterization_ready": (
                "characterization_materialization_ready"
            ),
            "oracle_blueprint_required": (
                "demand_materialization_required"
            ),
            "oracle_ready": "oracle_materialization_ready",
            "trusted_oracle_blueprint_required": (
                "demand_materialization_required"
            ),
            "trusted_oracle_ready": (
                "trusted_oracle_materialization_ready"
            ),
            "trusted_oracle_execution_required": (
                "external_execution_required"
            ),
            "trusted_oracle_golden_publisher_required": (
                "external_publisher_required"
            ),
        }
        if plan.state not in state_mapping:
            return LoopDecision(
                state="demand_invalid",
                reason_code="DEMAND_STATE_UNSUPPORTED",
                work_item_id=plan.target_work_item_id,
                requires_human=False,
                blockers=(
                    {
                        "intent_id": plan.intent_id,
                        "state": plan.state,
                    },
                ),
                warnings=tuple(warnings),
                details={"demand_plan": plan.to_dict()},
            )
        details: Dict[str, Any] = {
            "authority_transition": plan.authority_transition,
            "demand_plan": plan.to_dict(),
        }
        if plan.state == "trusted_oracle_execution_required":
            details["external_execution"] = dict(
                plan.bindings.get("trusted_oracle_execution", {})
            )
        if plan.state == "trusted_oracle_golden_publisher_required":
            details["external_publisher"] = dict(
                plan.bindings.get("trusted_oracle_execution", {})
            )
        return LoopDecision(
            state=state_mapping[plan.state],
            reason_code=plan.reason_code,
            work_item_id=plan.target_work_item_id,
            requires_human=False,
            warnings=tuple(warnings),
            details=details,
        )

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

        blocked_items = []
        for item_id, runtime in sorted(state_items.items()):
            if not isinstance(runtime, dict) or runtime.get("status") != "blocked":
                continue
            resolution = self._terminal_resolution(
                item_id,
                items,
                state_items,
            )
            if resolution.get("status") == "resolved":
                continue
            blocked_items.append(
                {
                    "work_item_id": item_id,
                    "status": runtime.get("status"),
                    "blocker": runtime.get("blocker"),
                    "resolution": resolution,
                }
            )
        if blocked_items:
            recovery_ids = {
                str(entry["work_item_id"]) for entry in blocked_items
            }
            recovery_candidates, recovery_blockers = (
                self.auto_materialization_candidates()
            )
            recovery_candidates = tuple(
                candidate
                for candidate in recovery_candidates
                if candidate.recovers in recovery_ids
            )
            selected_recovery, recovery_ambiguity = (
                self._select_auto_candidate(recovery_candidates)
            )
            if selected_recovery is not None:
                return LoopDecision(
                    state="auto_materialization_ready",
                    reason_code="AUTO_RECOVERY_MATERIALIZATION_READY",
                    work_item_id=selected_recovery.proposal_id,
                    requires_human=False,
                    details={
                        "auto_materialization": selected_recovery.to_dict(),
                        "recovery_for": selected_recovery.recovers,
                    },
                )
            if recovery_ambiguity is not None:
                return LoopDecision(
                    state="auto_materialization_blocked",
                    reason_code="AUTO_RECOVERY_MATERIALIZATION_AMBIGUOUS",
                    work_item_id=None,
                    requires_human=False,
                    blockers=(recovery_ambiguity,),
                )
            return LoopDecision(
                state="terminal_recovery",
                reason_code="BLOCKED_WORK_ITEM_REQUIRES_RESOLUTION",
                work_item_id=str(blocked_items[-1]["work_item_id"]),
                requires_human=True,
                blockers=tuple(blocked_items),
            )

        terminal_events: Dict[str, Tuple[int, str]] = {}
        for event in self.harness.event_lines():
            sequence = int(event.get("sequence", 0))
            if event.get("event") in {
                "WorkItemRejected",
                "WorkItemExhausted",
                "WorkItemCancelled",
            }:
                terminal_events[str(event.get("work_item_id"))] = (
                    sequence,
                    str(event.get("event")),
                )
        unresolved = []
        for item_id, runtime in sorted(state_items.items()):
            if (
                not isinstance(runtime, dict)
                or runtime.get("status") not in TERMINAL_RECOVERY_STATUSES
                or runtime.get("status") == "blocked"
            ):
                continue
            resolution = self._terminal_resolution(
                item_id,
                items,
                state_items,
            )
            if resolution.get("status") == "resolved":
                continue
            sequence, event_name = terminal_events.get(
                item_id,
                (0, "TerminalState"),
            )
            unresolved.append(
                {
                    "sequence": sequence,
                    "work_item_id": item_id,
                    "terminal_event": event_name,
                    "status": runtime.get("status"),
                    "resolution": resolution,
                }
            )
        unresolved.sort(key=lambda entry: (entry["sequence"], entry["work_item_id"]))
        if unresolved:
            latest = unresolved[-1]
            recovery_candidates, _ = self.auto_materialization_candidates()
            recovery_candidates = tuple(
                candidate
                for candidate in recovery_candidates
                if candidate.recovers == latest["work_item_id"]
            )
            selected_recovery, recovery_ambiguity = (
                self._select_auto_candidate(recovery_candidates)
            )
            if selected_recovery is not None:
                return LoopDecision(
                    state="auto_materialization_ready",
                    reason_code="AUTO_RECOVERY_MATERIALIZATION_READY",
                    work_item_id=selected_recovery.proposal_id,
                    requires_human=False,
                    details={
                        "auto_materialization": selected_recovery.to_dict(),
                        "recovery_for": selected_recovery.recovers,
                    },
                )
            if recovery_ambiguity is not None:
                return LoopDecision(
                    state="auto_materialization_blocked",
                    reason_code="AUTO_RECOVERY_MATERIALIZATION_AMBIGUOUS",
                    work_item_id=None,
                    requires_human=False,
                    blockers=(recovery_ambiguity,),
                )
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
        auto_has_blockers = bool(blockers)
        eligible_delivery, delivery_blockers = (
            self.delivery_materialization_candidates()
        )
        selected_delivery, delivery_ambiguity = (
            self._select_delivery_candidate(eligible_delivery)
        )
        if selected_delivery is not None:
            return LoopDecision(
                state="delivery_materialization_ready",
                reason_code="DELIVERY_MATERIALIZATION_READY",
                work_item_id=selected_delivery.blueprint_id,
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
                details={
                    "delivery_materialization": selected_delivery.to_dict()
                },
            )
        blockers.extend(delivery_blockers)
        if delivery_ambiguity is not None:
            blockers.insert(0, delivery_ambiguity)
        delivery_has_blockers = bool(
            delivery_blockers or delivery_ambiguity is not None
        )
        if auto_has_blockers and delivery_has_blockers:
            blocked_state = "materialization_blocked"
            blocked_reason = "MATERIALIZATION_BLOCKED"
        elif auto_has_blockers:
            blocked_state = "auto_materialization_blocked"
            blocked_reason = "AUTO_MATERIALIZATION_BLOCKED"
        elif delivery_has_blockers:
            blocked_state = "delivery_materialization_blocked"
            blocked_reason = "DELIVERY_MATERIALIZATION_BLOCKED"
        else:
            demand_decision = self._demand_decision(warnings)
            if demand_decision is not None:
                return demand_decision
            blocked_state = "queue_empty"
            blocked_reason = "NO_ELIGIBLE_COMPILED_CANDIDATE"
        return LoopDecision(
            state=blocked_state,
            reason_code=blocked_reason,
            work_item_id=None,
            requires_human=False,
            blockers=tuple(blockers),
            warnings=tuple(warnings),
        )

    def _candidate_path(
        self,
        raw_path: Path,
        *,
        allowed_root: str = CANDIDATE_ROOT,
    ) -> Tuple[Path, str]:
        candidate_root = self.harness.resolve(allowed_root)
        if raw_path.is_absolute():
            candidate = raw_path.resolve()
        else:
            candidate = (self.harness.root / raw_path).resolve()
        try:
            candidate.relative_to(candidate_root.resolve())
        except ValueError as error:
            raise MaterializationConflict(
                f"candidate 必须位于 {allowed_root}"
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

    def preflight_candidate(
        self,
        raw_path: Path,
        *,
        allowed_root: str = CANDIDATE_ROOT,
        require_filename_match: bool = True,
        policy_managed_gates: Sequence[str] = (),
    ) -> MaterializationPreview:
        errors, _ = self.harness.doctor()
        if errors:
            raise MaterializationConflict("doctor 未通过：" + "；".join(errors))
        candidate_path, relative = self._candidate_path(
            raw_path,
            allowed_root=allowed_root,
        )
        try:
            item = json.loads(candidate_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MaterializationConflict(f"candidate JSON 无效：{error}") from error
        item_id = item.get("metadata", {}).get("id")
        if not isinstance(item_id, str):
            raise MaterializationConflict("candidate 缺少 metadata.id")
        if (
            require_filename_match
            and candidate_path.name != f"{item_id}.json"
        ):
            raise MaterializationConflict("candidate 文件名必须与 metadata.id 一致")
        validation = self.harness.validate_work_item(item, item_id)
        if validation:
            raise MaterializationConflict("Work Item 无效：" + "；".join(validation))
        gates = item.get("spec", {}).get("gates", [])
        gates_are_policy_managed = (
            bool(gates)
            and tuple(gates) == tuple(policy_managed_gates)
        )
        if gates and not gates_are_policy_managed:
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

        recovery_issues = self.harness.recovery_candidate_issues(
            item_id,
            item,
            items,
            state,
        )
        if recovery_issues:
            raise MaterializationConflict(
                "RECOVERY_PREFLIGHT_INVALID: " + "；".join(recovery_issues)
            )

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
            recovers=item["spec"].get("recovers"),
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
        if preview.source_relative.startswith(
            DELIVERY_BLUEPRINT_ROOT + "/"
        ):
            allowed_root = DELIVERY_BLUEPRINT_ROOT
        elif preview.source_relative.startswith(
            CHARACTERIZATION_BLUEPRINT_ROOT + "/"
        ):
            allowed_root = CHARACTERIZATION_BLUEPRINT_ROOT
        elif preview.source_relative.startswith(
            ORACLE_BLUEPRINT_ROOT + "/"
        ):
            allowed_root = ORACLE_BLUEPRINT_ROOT
        elif preview.source_relative.startswith(
            TRUSTED_ORACLE_BLUEPRINT_ROOT + "/"
        ):
            allowed_root = TRUSTED_ORACLE_BLUEPRINT_ROOT
        elif preview.source_relative.startswith(
            MIGRATION_BLUEPRINT_ROOT + "/"
        ):
            allowed_root = MIGRATION_BLUEPRINT_ROOT
        else:
            allowed_root = CANDIDATE_ROOT
        current = self.preflight_candidate(
            self.harness.resolve(preview.source_relative),
            allowed_root=allowed_root,
            require_filename_match=(
                allowed_root
                not in {
                    CHARACTERIZATION_BLUEPRINT_ROOT,
                    ORACLE_BLUEPRINT_ROOT,
                    TRUSTED_ORACLE_BLUEPRINT_ROOT,
                }
            ),
            policy_managed_gates=(
                ("scenario-provenance-review",)
                if allowed_root == CHARACTERIZATION_BLUEPRINT_ROOT
                else ()
            ),
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

    def auto_materialize_delivery(self, blueprint_id: str) -> str:
        blueprint_path = self.harness.resolve(
            f"{DELIVERY_BLUEPRINT_ROOT}/{blueprint_id}.json"
        )
        candidate = self._delivery_candidate(blueprint_path)
        preview = self.preflight_candidate(
            blueprint_path,
            allowed_root=DELIVERY_BLUEPRINT_ROOT,
        )
        if (
            preview.work_item_sha256 != candidate.work_item_sha256
            or preview.source_fingerprint != candidate.blueprint_sha256
        ):
            raise MaterializationConflict(
                "DELIVERY_MATERIALIZATION_BINDING_DRIFT"
            )
        return self.materialize(
            preview,
            reason=f"policy:{DELIVERY_MATERIALIZATION_POLICY}",
            provenance=candidate.to_dict(),
        )

    def auto_materialize_migration(self, intent_id: str) -> str:
        plans, blockers = DemandCompiler(self.harness.root).plans()
        if blockers:
            raise MaterializationConflict("MIGRATION_DEMAND_BLOCKED")
        eligible = tuple(
            plan
            for plan in plans
            if plan.state != "delivery_completed"
        )
        if not eligible:
            raise MaterializationConflict("MIGRATION_DEMAND_MISSING")
        highest = eligible[0].priority
        tied = [plan for plan in eligible if plan.priority == highest]
        if len(tied) != 1 or tied[0].intent_id != intent_id:
            raise MaterializationConflict(
                "MIGRATION_DEMAND_SELECTION_DRIFT"
            )
        plan = tied[0]
        preview = self._migration_plan_preview(plan)
        return self.materialize(
            preview,
            reason=f"policy:{MIGRATION_MATERIALIZATION_POLICY}",
            provenance=plan.to_dict(),
        )

    def auto_materialize_characterization(
        self,
        intent_id: str,
    ) -> str:
        plans, blockers = DemandCompiler(self.harness.root).plans()
        if blockers:
            raise MaterializationConflict(
                "CHARACTERIZATION_DEMAND_BLOCKED"
            )
        eligible = tuple(
            plan
            for plan in plans
            if plan.state != "delivery_completed"
        )
        if not eligible:
            raise MaterializationConflict(
                "CHARACTERIZATION_DEMAND_MISSING"
            )
        highest = eligible[0].priority
        tied = [plan for plan in eligible if plan.priority == highest]
        if len(tied) != 1 or tied[0].intent_id != intent_id:
            raise MaterializationConflict(
                "CHARACTERIZATION_DEMAND_SELECTION_DRIFT"
            )
        plan = tied[0]
        preview = self._characterization_plan_preview(plan)
        return self.materialize(
            preview,
            reason=f"policy:{CHARACTERIZATION_MATERIALIZATION_POLICY}",
            provenance=plan.to_dict(),
        )

    def auto_materialize_oracle(self, intent_id: str) -> str:
        plans, blockers = DemandCompiler(self.harness.root).plans()
        if blockers:
            raise MaterializationConflict("ORACLE_DEMAND_BLOCKED")
        eligible = tuple(
            plan
            for plan in plans
            if plan.state != "delivery_completed"
        )
        if not eligible:
            raise MaterializationConflict("ORACLE_DEMAND_MISSING")
        highest = eligible[0].priority
        tied = [plan for plan in eligible if plan.priority == highest]
        if len(tied) != 1 or tied[0].intent_id != intent_id:
            raise MaterializationConflict(
                "ORACLE_DEMAND_SELECTION_DRIFT"
            )
        plan = tied[0]
        preview = self._oracle_plan_preview(plan)
        return self.materialize(
            preview,
            reason=f"policy:{ORACLE_MATERIALIZATION_POLICY}",
            provenance=plan.to_dict(),
        )

    def auto_materialize_trusted_oracle(
        self,
        intent_id: str,
    ) -> str:
        plans, blockers = DemandCompiler(self.harness.root).plans()
        if blockers:
            raise MaterializationConflict(
                "TRUSTED_ORACLE_DEMAND_BLOCKED"
            )
        eligible = tuple(
            plan
            for plan in plans
            if plan.state != "delivery_completed"
        )
        if not eligible:
            raise MaterializationConflict(
                "TRUSTED_ORACLE_DEMAND_MISSING"
            )
        highest = eligible[0].priority
        tied = [plan for plan in eligible if plan.priority == highest]
        if len(tied) != 1 or tied[0].intent_id != intent_id:
            raise MaterializationConflict(
                "TRUSTED_ORACLE_DEMAND_SELECTION_DRIFT"
            )
        plan = tied[0]
        preview = self._trusted_oracle_plan_preview(plan)
        return self.materialize(
            preview,
            reason=(
                f"policy:{TRUSTED_ORACLE_MATERIALIZATION_POLICY}"
            ),
            provenance=plan.to_dict(),
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

    def _journal_binding(self, item_id: str, phase: str) -> Dict[str, Any]:
        state = self.harness.state()
        runtime = state.get("work_items", {}).get(item_id, {})
        attempt = runtime.get("attempt")
        if not isinstance(attempt, int) or isinstance(attempt, bool):
            raise RunJournalError("JOURNAL_ATTEMPT_INVALID")
        candidate_sha256, _ = self.harness.candidate_snapshot(runtime)
        item = self.harness.work_items().get(item_id)
        if item is None:
            raise RunJournalError("JOURNAL_WORK_ITEM_MISSING")
        return {
            "work_item_id": item_id,
            "attempt": attempt,
            "phase": phase,
            "work_item_sha256": sha256_json(item),
            "head_commit": self.harness.git_head(),
            "control_binding_sha256": sha256_json(
                list(self._control_binding(state, item_id))
            ),
            "candidate_snapshot_sha256": candidate_sha256,
        }

    def _journal_replay(
        self,
        journal: RunJournal,
        *,
        item_id: str,
        phase: str,
    ) -> Dict[str, Any]:
        try:
            return journal.inspect_completion(
                **self._journal_binding(item_id, phase)
            )
        except (HarnessError, RunJournalError, OSError):
            return {
                "status": "invalid",
                "reason_code": "JOURNAL_INSPECTION_FAILED",
            }

    def _journal_record_completion(
        self,
        journal: RunJournal,
        *,
        item_id: str,
        phase: str,
    ) -> Dict[str, Any]:
        try:
            return journal.append_completion(
                **self._journal_binding(item_id, phase)
            )
        except (HarnessError, RunJournalError, OSError) as error:
            reason_code = (
                error.reason_code
                if isinstance(error, RunJournalError)
                else "JOURNAL_RECORD_FAILED"
            )
            return {
                "status": "unavailable",
                "reason_code": reason_code,
            }

    def _journal_invalidate_completion(
        self,
        journal: RunJournal,
        *,
        item_id: str,
        phase: str,
    ) -> Dict[str, Any]:
        try:
            return journal.invalidate_completion(
                **self._journal_binding(item_id, phase)
            )
        except (HarnessError, RunJournalError, OSError) as error:
            reason_code = (
                error.reason_code
                if isinstance(error, RunJournalError)
                else "JOURNAL_INVALIDATION_FAILED"
            )
            return {
                "status": "unavailable",
                "reason_code": reason_code,
            }

    def _invoke_agent_phase(
        self,
        *,
        item_id: str,
        phase: str,
        policy: Optional[str],
        argv_template: Sequence[str],
        timeout_seconds: int,
        repair_errors: Optional[Sequence[str]] = None,
    ) -> Dict[str, Any]:
        try:
            context = self.harness.context_packet(item_id)
        except HarnessError:
            if not repair_errors:
                raise
            item = self.harness.work_items()[item_id]
            inputs = item.get("spec", {}).get("inputs", {})
            read_order = [
                f"ios/harness/work-items/{item_id}.json",
                *inputs.get("context_files", []),
                *inputs.get("android_source_anchors", []),
            ]
            context = {
                "schema_version": SCHEMA_VERSION,
                "work_item": item,
                "work_item_sha256": sha256_json(item),
                "runtime": self.harness.state()
                .get("work_items", {})
                .get(item_id, {}),
                "capability": self.harness.capability(
                    item.get("spec", {}).get("capability")
                ),
                "required_read_order": list(dict.fromkeys(read_order)),
                "repair_context": {
                    "reason_code": "ACTIVE_KNOWLEDGE_CANDIDATE_INVALID",
                    "doctor_errors": list(repair_errors),
                },
            }
        if policy is not None:
            runtime = self.harness.state().get("work_items", {}).get(item_id, {})
            context["supervisor_control"] = {
                "policy": policy,
                "phase": phase,
                "latest_evidence": runtime.get("last_evidence"),
                "verify_cycles": runtime.get("verify_cycles", 0),
            }
            if repair_errors:
                context["supervisor_control"]["repair"] = {
                    "reason_code": "ACTIVE_KNOWLEDGE_CANDIDATE_INVALID",
                    "doctor_errors": list(repair_errors),
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

    def _repairable_knowledge_item(
        self,
        decision: LoopDecision,
    ) -> Optional[Tuple[str, Tuple[str, ...]]]:
        if decision.state != "doctor_red":
            return None
        messages = tuple(
            str(blocker.get("message"))
            for blocker in decision.blockers
            if isinstance(blocker, dict) and blocker.get("message")
        )
        if not messages or any(
            "Business Knowledge control" not in message
            and "Business Knowledge selection" not in message
            for message in messages
        ):
            return None
        state = self.harness.state()
        active = state.get("active_work_items", [])
        if not isinstance(active, list) or len(active) != 1:
            return None
        item_id = active[0]
        runtime = state.get("work_items", {}).get(item_id, {})
        items = self.harness.work_items()
        item = items.get(item_id)
        if (
            not isinstance(item_id, str)
            or not isinstance(runtime, dict)
            or runtime.get("status") != "implementing"
            or not isinstance(item, dict)
            or not item.get("spec", {}).get("knowledge", {}).get("produces")
        ):
            return None
        changed = self.harness.changed_since_claim(runtime)
        policy_errors, _, _ = self.harness.scope_issues(
            item,
            runtime,
            changed,
        )
        if policy_errors:
            return None
        return item_id, messages

    def _refreshable_control_catalog(
        self,
        decision: LoopDecision,
    ) -> Optional[Tuple[str, Tuple[str, ...]]]:
        enabled = getattr(self.harness, "business_knowledge_enabled", None)
        if (
            decision.state != "doctor_red"
            or not callable(enabled)
            or not enabled()
        ):
            return None
        messages = tuple(
            str(blocker.get("message"))
            for blocker in decision.blockers
            if isinstance(blocker, dict) and blocker.get("message")
        )
        if not messages or any(
            BUSINESS_KNOWLEDGE_CATALOG_STALE not in message
            for message in messages
        ):
            return None
        state = self.harness.state()
        active = state.get("active_work_items", [])
        if not isinstance(active, list) or len(active) != 1:
            return None
        item_id = active[0]
        runtime = state.get("work_items", {}).get(item_id, {})
        item = self.harness.work_items().get(item_id)
        if (
            not isinstance(item_id, str)
            or not isinstance(runtime, dict)
            or runtime.get("status") != "implementing"
            or not isinstance(item, dict)
            or not Harness.business_knowledge_control_upgrade(item)
        ):
            return None
        changed = self.harness.changed_since_claim(runtime)
        if not changed or not any(
            path == "ios/harness/harness.py"
            or path.startswith("ios/harness/business-knowledge/")
            for path in changed
        ):
            return None
        policy_errors, _, _ = self.harness.scope_issues(
            item,
            runtime,
            changed,
        )
        if policy_errors:
            return None
        return item_id, messages

    def _synthetic_provenance_ready(
        self,
        item_id: str,
    ) -> Tuple[bool, str]:
        items = self.harness.work_items()
        item = items.get(item_id)
        state = self.harness.state()
        runtime = state.get("work_items", {}).get(item_id, {})
        if (
            not isinstance(item, dict)
            or not isinstance(runtime, dict)
            or runtime.get("status") != "awaiting_human"
            or item.get("spec", {}).get("gates")
            != ["scenario-provenance-review"]
            or runtime.get("awaiting_human_reasons")
            != ["缺少人工批准：scenario-provenance-review"]
            or not isinstance(runtime.get("review_subject_sha256"), str)
            or not isinstance(runtime.get("approval_requested_at"), str)
        ):
            return False, "SYNTHETIC_PROVENANCE_STATE_INVALID"
        spec = item.get("spec", {})
        source_lab = spec.get("source_lab", {})
        scenarios = source_lab.get("scenarios", [])
        if (
            source_lab.get("mode") != "extend"
            or len(scenarios) != 1
            or self._characterization_scope_issues(item)
        ):
            return False, "SYNTHETIC_PROVENANCE_CONTRACT_INVALID"
        scenario = scenarios[0]
        case_relative = (
            f"ios/harness/fixtures/source-lab/{scenario}/case.json"
        )
        try:
            case = json.loads(
                self.harness.resolve(case_relative).read_text(
                    encoding="utf-8"
                )
            )
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            return False, "SYNTHETIC_PROVENANCE_CASE_INVALID"
        provenance = case.get("provenance", {})
        anchors = set(
            value
            for value in spec.get("inputs", {}).get(
                "android_source_anchors", []
            )
            if isinstance(value, str)
        )
        source_refs = provenance.get("source_refs", [])
        if (
            case.get("id") != scenario
            or case.get("status") != "candidate"
            or case.get("operation") != "source_lab_site"
            or case.get("transport", {}).get("external_network") != "deny"
            or case.get("determinism", {}).get("network_allowed") is not False
            or provenance.get("kind") != "synthetic"
            or provenance.get("introduced_by") != item_id
            or not anchors
            or not anchors.issubset(set(source_refs))
        ):
            return False, "SYNTHETIC_PROVENANCE_BINDING_INVALID"
        changed = self.harness.changed_since_claim(runtime)
        policy_errors, _, _ = self.harness.scope_issues(
            item,
            runtime,
            changed,
        )
        if policy_errors:
            return False, "SYNTHETIC_PROVENANCE_SCOPE_INVALID"
        allowed_prefix = (
            f"ios/harness/fixtures/source-lab/{scenario}/"
        )
        allowed_memory = (
            f"ios/project/capabilities/{spec.get('capability')}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/",
        )
        for relative in changed:
            if (
                relative.startswith(allowed_prefix)
                or relative == allowed_memory[0]
                or relative == allowed_memory[1]
                or relative.startswith(allowed_memory[2])
                or path_matches(relative, self.harness.managed_paths())
            ):
                continue
            return False, "SYNTHETIC_PROVENANCE_CHANGED_PATH_INVALID"
        return True, "SYNTHETIC_PROVENANCE_POLICY_MATCH"

    def _auto_accept_synthetic_provenance(
        self,
        item_id: str,
    ) -> str:
        eligible, reason = self._synthetic_provenance_ready(item_id)
        if not eligible:
            raise MaterializationConflict(reason)
        items = self.harness.work_items()
        item = items[item_id]
        runtime = self.harness.state()["work_items"][item_id]
        now = dt.datetime.now(dt.timezone.utc)
        approval = {
            "schema_version": SCHEMA_VERSION,
            "work_item_id": item_id,
            "gate": "scenario-provenance-review",
            "work_item_sha256": sha256_json(item),
            "tree_sha256": runtime["review_subject_sha256"],
            "reviewer": (
                "trusted-policy:"
                + SYNTHETIC_PROVENANCE_POLICY
            ),
            "approved_at": now.isoformat().replace("+00:00", "Z"),
            "expires_at": (
                now + dt.timedelta(minutes=15)
            ).isoformat().replace("+00:00", "Z"),
            "signature": None,
        }
        approval_path = (
            self.harness.resolve(self.harness.config["approvals_dir"])
            / f"{item_id}--scenario-provenance-review.json"
        )
        _atomic_write_bytes(
            approval_path,
            canonical_bytes(approval) + b"\n",
        )
        result = self.harness.close(item_id)
        if result != "completed":
            raise MaterializationConflict(
                "SYNTHETIC_PROVENANCE_CLOSE_INCOMPLETE"
            )
        return result

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
        initial_decision = self.inspect()
        if initial_decision.state == "external_publisher_required":
            external_config = config.get("external_execution")
            github_config = (
                external_config.get("github_golden")
                if isinstance(external_config, dict)
                else None
            )
            if (
                isinstance(github_config, dict)
                and github_config.get("enabled") is True
            ):
                decision_details = (
                    initial_decision.details
                    if isinstance(initial_decision.details, Mapping)
                    else {}
                )
                binding = decision_details.get(
                    "external_publisher", {}
                )
                try:
                    external_result = GitHubGoldenPublisherDispatcher(
                        self.harness.root,
                        repository=github_config.get("repository"),
                        workflow_path=GOLDEN_PUBLISHER_WORKFLOW_PATH,
                        scenario=binding.get("scenario_id"),
                        request_sha=self.harness.git_head(),
                        receipt_path=binding.get("receipt"),
                        receipt_sha256=binding.get("receipt_sha256"),
                        remote=github_config.get("remote"),
                    ).dispatch()
                except GitHubGoldenPublisherError as error:
                    raise LoopSupervisorError(str(error)) from error
                result = {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": external_result["outcome"],
                    "decision": initial_decision.to_dict(),
                    "external_publisher": external_result,
                    "transitions": [],
                }
                if external_result["outcome"] == "settled":
                    result["continuation_decision"] = (
                        self.inspect().to_dict()
                    )
                return result
            return {
                "schema_version": SCHEMA_VERSION,
                "outcome": initial_decision.reason_code.lower(),
                "decision": initial_decision.to_dict(),
                "transitions": [],
            }
        if initial_decision.state == "external_execution_required":
            external_config = config.get("external_execution")
            github_config = (
                external_config.get("github_oracle")
                if isinstance(external_config, dict)
                else None
            )
            if isinstance(github_config, dict) and github_config.get("enabled") is True:
                binding = initial_decision.details.get("external_execution", {})
                try:
                    external_result = GitHubOracleDispatcher(
                        self.harness.root,
                        repository=github_config.get("repository"),
                        workflow_path=binding.get("workflow_path"),
                        scenario=binding.get("scenario_id"),
                        source_digest=binding.get("source_digest"),
                        remote=github_config.get("remote"),
                    ).dispatch()
                except GitHubOracleError as error:
                    raise LoopSupervisorError(str(error)) from error
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": external_result["outcome"],
                    "decision": initial_decision.to_dict(),
                    "external_execution": external_result,
                    "transitions": [],
                }
            return {
                "schema_version": SCHEMA_VERSION,
                "outcome": initial_decision.reason_code.lower(),
                "decision": initial_decision.to_dict(),
                "transitions": [],
            }
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
        delivery_config = config.get("delivery_materialization", {})
        if delivery_config is None:
            delivery_config = {}
        if not isinstance(delivery_config, dict):
            raise LoopSupervisorError(
                "delivery_materialization 必须是 object"
            )
        delivery_enabled = delivery_config.get("enabled") is True
        delivery_policy = delivery_config.get("policy")
        if (
            delivery_enabled
            and delivery_policy != DELIVERY_MATERIALIZATION_POLICY
        ):
            raise LoopSupervisorError(
                "启用 delivery_materialization 时 policy 必须是 "
                + DELIVERY_MATERIALIZATION_POLICY
            )
        migration_config = config.get("migration_materialization", {})
        if migration_config is None:
            migration_config = {}
        if not isinstance(migration_config, dict):
            raise LoopSupervisorError(
                "migration_materialization 必须是 object"
            )
        migration_enabled = migration_config.get("enabled") is True
        migration_policy = migration_config.get("policy")
        if (
            migration_enabled
            and migration_policy != MIGRATION_MATERIALIZATION_POLICY
        ):
            raise LoopSupervisorError(
                "启用 migration_materialization 时 policy 必须是 "
                + MIGRATION_MATERIALIZATION_POLICY
            )
        characterization_config = config.get(
            "characterization_materialization", {}
        )
        if characterization_config is None:
            characterization_config = {}
        if not isinstance(characterization_config, dict):
            raise LoopSupervisorError(
                "characterization_materialization 必须是 object"
            )
        characterization_enabled = (
            characterization_config.get("enabled") is True
        )
        characterization_policy = characterization_config.get("policy")
        if (
            characterization_enabled
            and characterization_policy
            != CHARACTERIZATION_MATERIALIZATION_POLICY
        ):
            raise LoopSupervisorError(
                "启用 characterization_materialization 时 policy 必须是 "
                + CHARACTERIZATION_MATERIALIZATION_POLICY
            )
        oracle_config = config.get("oracle_materialization", {})
        if oracle_config is None:
            oracle_config = {}
        if not isinstance(oracle_config, dict):
            raise LoopSupervisorError(
                "oracle_materialization 必须是 object"
            )
        oracle_enabled = oracle_config.get("enabled") is True
        oracle_policy = oracle_config.get("policy")
        if (
            oracle_enabled
            and oracle_policy != ORACLE_MATERIALIZATION_POLICY
        ):
            raise LoopSupervisorError(
                "启用 oracle_materialization 时 policy 必须是 "
                + ORACLE_MATERIALIZATION_POLICY
            )
        trusted_oracle_config = config.get(
            "trusted_oracle_materialization",
            {},
        )
        if trusted_oracle_config is None:
            trusted_oracle_config = {}
        if not isinstance(trusted_oracle_config, dict):
            raise LoopSupervisorError(
                "trusted_oracle_materialization 必须是 object"
            )
        trusted_oracle_enabled = (
            trusted_oracle_config.get("enabled") is True
        )
        trusted_oracle_policy = trusted_oracle_config.get("policy")
        if (
            trusted_oracle_enabled
            and trusted_oracle_policy
            != TRUSTED_ORACLE_MATERIALIZATION_POLICY
        ):
            raise LoopSupervisorError(
                "启用 trusted_oracle_materialization 时 policy 必须是 "
                + TRUSTED_ORACLE_MATERIALIZATION_POLICY
            )
        synthetic_config = config.get("synthetic_provenance", {})
        if synthetic_config is None:
            synthetic_config = {}
        if not isinstance(synthetic_config, dict):
            raise LoopSupervisorError(
                "synthetic_provenance 必须是 object"
            )
        synthetic_enabled = synthetic_config.get("enabled") is True
        synthetic_policy = synthetic_config.get("policy")
        if (
            synthetic_enabled
            and synthetic_policy != SYNTHETIC_PROVENANCE_POLICY
        ):
            raise LoopSupervisorError(
                "启用 synthetic_provenance 时 policy 必须是 "
                + SYNTHETIC_PROVENANCE_POLICY
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
        run_journal = (
            RunJournal(self.harness.root) if trusted_verification else None
        )

        transitions: List[Dict[str, Any]] = []
        repaired_items: Set[str] = set()
        for _ in range(max_transitions):
            before = self.inspect()
            if trusted_verification and before.state == "doctor_red":
                catalog_resume = self._refreshable_control_catalog(before)
                if catalog_resume is not None:
                    item_id, catalog_errors = catalog_resume
                    control_before = self._control_binding(
                        self.harness.state(),
                        item_id,
                    )
                    catalog_path = self.harness.business_knowledge_catalog_path
                    catalog_before = (
                        _sha256_bytes(catalog_path.read_bytes())
                        if catalog_path.is_file()
                        else "missing"
                    )
                    try:
                        with self.harness.mutation_lock():
                            self.harness.refresh_business_knowledge_catalog()
                    except (HarnessError, OSError) as error:
                        transitions.append(
                            {
                                "kind": "supervisor_catalog_refresh",
                                "work_item_id": item_id,
                                "result": "failed",
                                "error": str(error),
                                "catalog_before_sha256": catalog_before,
                            }
                        )
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "supervisor_catalog_refresh_failed",
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    catalog_after = (
                        _sha256_bytes(catalog_path.read_bytes())
                        if catalog_path.is_file()
                        else "missing"
                    )
                    control_after = self._control_binding(
                        self.harness.state(),
                        item_id,
                    )
                    transitions.append(
                        {
                            "kind": "supervisor_catalog_refresh",
                            "work_item_id": item_id,
                            "result": "refreshed",
                            "reason_code": "ACTIVE_CONTROL_CATALOG_STALE",
                            "doctor_error_count": len(catalog_errors),
                            "catalog_before_sha256": catalog_before,
                            "catalog_after_sha256": catalog_after,
                        }
                    )
                    if control_after != control_before:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "supervisor_catalog_control_mutation",
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    before = self.inspect()
                    if before.state != "implementing":
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": (
                                "supervisor_catalog_refresh_not_recovered"
                            ),
                            "decision": before.to_dict(),
                            "transitions": transitions,
                        }
                    repaired_items.add(item_id)
                else:
                    repair = self._repairable_knowledge_item(before)
                    if repair is None:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": before.reason_code.lower(),
                            "decision": before.to_dict(),
                            "transitions": transitions,
                        }
                    item_id, repair_errors = repair
                    control_before = self._control_binding(
                        self.harness.state(), item_id
                    )
                    transition = self._invoke_agent_phase(
                        item_id=item_id,
                        phase="implementation",
                        policy=str(verification_policy),
                        argv_template=argv_template,
                        timeout_seconds=timeout_seconds,
                        repair_errors=repair_errors,
                    )
                    transition["repair"] = True
                    transitions.append(transition)
                    failure_outcome = self._agent_failure_outcome(transition)
                    if failure_outcome is not None:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": failure_outcome,
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    if self._control_binding(self.harness.state(), item_id) != control_before:
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "agent_control_plane_mutation",
                            "decision": self.inspect().to_dict(),
                            "transitions": transitions,
                        }
                    after_repair = self.inspect()
                    if after_repair.state == "implementing":
                        repaired_items.add(item_id)
                    continue
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
            if before.state == "delivery_materialization_ready":
                if not delivery_enabled:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": "delivery_materialization_disabled",
                        "decision": before.to_dict(),
                        "transitions": transitions,
                    }
                item_id = before.work_item_id
                assert item_id is not None
                with self.harness.mutation_lock():
                    materialized_id = self.auto_materialize_delivery(item_id)
                transitions.append(
                    {
                        "kind": "delivery_materialization",
                        "work_item_id": materialized_id,
                        "policy": delivery_policy,
                    }
                )
                before = self.inspect()
            if before.state == "migration_materialization_ready":
                if not migration_enabled:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": "migration_materialization_disabled",
                        "decision": before.to_dict(),
                        "transitions": transitions,
                    }
                demand_plan = (
                    before.details.get("demand_plan", {})
                    if isinstance(before.details, dict)
                    else {}
                )
                intent_id = demand_plan.get("intent_id")
                if not isinstance(intent_id, str):
                    raise LoopSupervisorError(
                        "migration decision 缺少 intent_id"
                    )
                with self.harness.mutation_lock():
                    materialized_id = self.auto_materialize_migration(
                        intent_id
                    )
                transitions.append(
                    {
                        "kind": "migration_materialization",
                        "work_item_id": materialized_id,
                        "intent_id": intent_id,
                        "policy": migration_policy,
                    }
                )
                before = self.inspect()
            if before.state == "characterization_materialization_ready":
                if not characterization_enabled:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": (
                            "characterization_materialization_disabled"
                        ),
                        "decision": before.to_dict(),
                        "transitions": transitions,
                    }
                demand_plan = (
                    before.details.get("demand_plan", {})
                    if isinstance(before.details, dict)
                    else {}
                )
                intent_id = demand_plan.get("intent_id")
                if not isinstance(intent_id, str):
                    raise LoopSupervisorError(
                        "characterization decision 缺少 intent_id"
                    )
                with self.harness.mutation_lock():
                    materialized_id = (
                        self.auto_materialize_characterization(
                            intent_id
                        )
                    )
                transitions.append(
                    {
                        "kind": "characterization_materialization",
                        "work_item_id": materialized_id,
                        "intent_id": intent_id,
                        "policy": characterization_policy,
                    }
                )
                before = self.inspect()
            if before.state == "oracle_materialization_ready":
                if not oracle_enabled:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": "oracle_materialization_disabled",
                        "decision": before.to_dict(),
                        "transitions": transitions,
                    }
                demand_plan = (
                    before.details.get("demand_plan", {})
                    if isinstance(before.details, dict)
                    else {}
                )
                intent_id = demand_plan.get("intent_id")
                if not isinstance(intent_id, str):
                    raise LoopSupervisorError(
                        "oracle decision 缺少 intent_id"
                    )
                with self.harness.mutation_lock():
                    materialized_id = self.auto_materialize_oracle(
                        intent_id
                    )
                transitions.append(
                    {
                        "kind": "oracle_materialization",
                        "work_item_id": materialized_id,
                        "intent_id": intent_id,
                        "policy": oracle_policy,
                    }
                )
                before = self.inspect()
            if before.state == "trusted_oracle_materialization_ready":
                if not trusted_oracle_enabled:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": (
                            "trusted_oracle_materialization_disabled"
                        ),
                        "decision": before.to_dict(),
                        "transitions": transitions,
                    }
                demand_plan = (
                    before.details.get("demand_plan", {})
                    if isinstance(before.details, dict)
                    else {}
                )
                intent_id = demand_plan.get("intent_id")
                if not isinstance(intent_id, str):
                    raise LoopSupervisorError(
                        "trusted oracle decision 缺少 intent_id"
                    )
                with self.harness.mutation_lock():
                    materialized_id = (
                        self.auto_materialize_trusted_oracle(
                            intent_id
                        )
                    )
                transitions.append(
                    {
                        "kind": (
                            "trusted_oracle_materialization"
                        ),
                        "work_item_id": materialized_id,
                        "intent_id": intent_id,
                        "policy": trusted_oracle_policy,
                    }
                )
                before = self.inspect()
            if before.state == "awaiting_human" and synthetic_enabled:
                item_id = before.work_item_id
                assert item_id is not None
                eligible, reason = self._synthetic_provenance_ready(
                    item_id
                )
                if eligible:
                    with self.harness.mutation_lock():
                        result = (
                            self._auto_accept_synthetic_provenance(
                                item_id
                            )
                        )
                    transitions.append(
                        {
                            "kind": "synthetic_provenance_decision",
                            "work_item_id": item_id,
                            "result": result,
                            "policy": synthetic_policy,
                        }
                    )
                    before = self.inspect()
                else:
                    transitions.append(
                        {
                            "kind": "synthetic_provenance_decision",
                            "work_item_id": item_id,
                            "result": "not_eligible",
                            "reason_code": reason,
                            "policy": synthetic_policy,
                        }
                    )
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
                    if item_id in repaired_items:
                        repaired_items.remove(item_id)
                    else:
                        replay = (
                            self._journal_replay(
                                run_journal,
                                item_id=item_id,
                                phase="implementation",
                            )
                            if run_journal is not None
                            else {"status": "missing"}
                        )
                        if replay.get("status") == "match":
                            transitions.append(
                                {
                                    "kind": "supervisor_replay",
                                    "work_item_id": item_id,
                                    "phase": "implementation",
                                    "result": "agent_turn_skipped",
                                    "reason_code": replay["reason_code"],
                                    "sequence": replay["sequence"],
                                    "record_sha256": replay["record_sha256"],
                                }
                            )
                        else:
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
                            if replay.get("status") in {"invalid", "stale"}:
                                transition["journal_replay"] = replay
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
                            if run_journal is not None:
                                transition["run_journal"] = (
                                    self._journal_record_completion(
                                        run_journal,
                                        item_id=item_id,
                                        phase="implementation",
                                    )
                                )
                    try:
                        with self.harness.mutation_lock():
                            evidence_path = self.harness.verify(item_id)
                    except HarnessError as error:
                        verification_transition = {
                            "kind": "supervisor_verification",
                            "work_item_id": item_id,
                            "result": "error_before_evidence",
                            "error": str(error),
                        }
                        if run_journal is not None:
                            verification_transition["run_journal"] = (
                                self._journal_invalidate_completion(
                                    run_journal,
                                    item_id=item_id,
                                    phase="implementation",
                                )
                            )
                        transitions.append(verification_transition)
                        after_error = self.inspect()
                        if self._repairable_knowledge_item(after_error) is not None:
                            continue
                        return {
                            "schema_version": SCHEMA_VERSION,
                            "outcome": "supervisor_verification_error",
                            "decision": after_error.to_dict(),
                            "transitions": transitions,
                        }
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
                    replay = (
                        self._journal_replay(
                            run_journal,
                            item_id=item_id,
                            phase="memory_close",
                        )
                        if run_journal is not None
                        else {"status": "missing"}
                    )
                    if replay.get("status") == "match":
                        transitions.append(
                            {
                                "kind": "supervisor_replay",
                                "work_item_id": item_id,
                                "phase": "memory_close",
                                "result": "agent_turn_skipped",
                                "reason_code": replay["reason_code"],
                                "sequence": replay["sequence"],
                                "record_sha256": replay["record_sha256"],
                            }
                        )
                    else:
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
                        if replay.get("status") in {"invalid", "stale"}:
                            transition["journal_replay"] = replay
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
                        if run_journal is not None:
                            transition["run_journal"] = (
                                self._journal_record_completion(
                                    run_journal,
                                    item_id=item_id,
                                    phase="memory_close",
                                )
                            )
                    try:
                        with self.harness.mutation_lock():
                            close_outcome = self.harness.close(item_id)
                    except HarnessError as error:
                        close_transition = {
                            "kind": "supervisor_close",
                            "work_item_id": item_id,
                            "result": "failed",
                            "error": str(error),
                        }
                        if run_journal is not None:
                            close_transition["run_journal"] = (
                                self._journal_invalidate_completion(
                                    run_journal,
                                    item_id=item_id,
                                    phase="memory_close",
                                )
                            )
                        transitions.append(close_transition)
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
