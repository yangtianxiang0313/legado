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


SCHEMA_VERSION = 1
CANDIDATE_ROOT = "ios/project/work-item-proposals/candidates"
TERMINAL_RECOVERY_STATUSES = {"blocked", "rejected", "exhausted", "cancelled"}
ACTIVE_DECISIONS = {
    "implementing": ("agent_required", False),
    "verified": ("memory_close_required", False),
    "awaiting_human": ("human_review_required", True),
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


def _sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _tail(value: str, limit: int = 2000) -> str:
    return value[-limit:]


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

        return LoopDecision(
            state="queue_empty",
            reason_code="NO_MATERIALIZED_READY_WORK_ITEM",
            work_item_id=None,
            requires_human=True,
            commands=(
                (
                    sys.executable,
                    "ios/harness/loop_supervisor.py",
                    "materialize-review",
                    "<candidate.json>",
                ),
            ),
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
            self.harness.append_event(
                "WorkItemMaterialized",
                current.item_id,
                {
                    "authorized_by": local_reviewer(),
                    "initial_status": "ready",
                    "reason": reason,
                    "work_item_sha256": current.work_item_sha256,
                },
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

        transitions: List[Dict[str, Any]] = []
        for _ in range(max_transitions):
            before = self.inspect()
            if before.state not in {"ready", "implementing"}:
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": before.reason_code.lower(),
                    "decision": before.to_dict(),
                    "transitions": transitions,
                }
            item_id = before.work_item_id
            assert item_id is not None
            context = self.harness.context_packet(item_id)
            descriptor, raw_context = tempfile.mkstemp(
                prefix=f"legado-{item_id.lower()}-",
                suffix=".json",
            )
            context_path = Path(raw_context)
            try:
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(json.dumps(context, ensure_ascii=False, indent=2).encode())
                    handle.write(b"\n")
                if before.state == "ready":
                    with self.harness.mutation_lock():
                        self.harness.claim(item_id, agent_id)
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
                        "PYTHONDONTWRITEBYTECODE": "1",
                        "TZ": "UTC",
                    }
                )
                started = time.monotonic()
                result = subprocess.run(
                    argv,
                    cwd=str(self.harness.root),
                    env=environment,
                    capture_output=True,
                    text=True,
                    timeout=timeout_seconds,
                    check=False,
                )
                transition = {
                    "work_item_id": item_id,
                    "argv": argv,
                    "exit_code": result.returncode,
                    "duration_ms": int((time.monotonic() - started) * 1000),
                    "stdout_sha256": _sha256_bytes(result.stdout.encode()),
                    "stderr_sha256": _sha256_bytes(result.stderr.encode()),
                    "stdout_tail": _tail(result.stdout),
                    "stderr_tail": _tail(result.stderr),
                }
                transitions.append(transition)
                if result.returncode != 0:
                    return {
                        "schema_version": SCHEMA_VERSION,
                        "outcome": "agent_failed",
                        "decision": self.inspect().to_dict(),
                        "transitions": transitions,
                    }
            except subprocess.TimeoutExpired as error:
                transitions.append(
                    {
                        "work_item_id": item_id,
                        "argv": argv if "argv" in locals() else [],
                        "timed_out": True,
                        "timeout_seconds": timeout_seconds,
                        "stdout_tail": _tail((error.stdout or "") if isinstance(error.stdout, str) else ""),
                        "stderr_tail": _tail((error.stderr or "") if isinstance(error.stderr, str) else ""),
                    }
                )
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": "agent_timeout",
                    "decision": self.inspect().to_dict(),
                    "transitions": transitions,
                }
            finally:
                context_path.unlink(missing_ok=True)

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
        if args.command == "drive":
            result = supervisor.drive(
                config_path=args.config,
                agent_id=args.agent,
                max_transitions=args.max_transitions,
            )
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result["outcome"] not in {"agent_failed", "agent_timeout"} else 1
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
