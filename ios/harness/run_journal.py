#!/usr/bin/env python3
"""Local, non-authoritative replay journal for Loop Supervisor.

The journal may prevent duplicate cooperative Agent turns after a local process
crash.  It is deliberately not a trust anchor: the Agent and this module share
the same user and filesystem permissions.
"""

from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import stat
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Mapping


SCHEMA_VERSION = 1
POLICY = "local-replay-journal-v1"
RUNTIME_DIRECTORY = ".harness-runtime"
JOURNAL_DIRECTORY = "loop-runs"
MAX_JOURNAL_BYTES = 256 * 1024
MAX_RECORDS = 64
MAX_JOURNAL_FILES = 128
PHASES = {"implementation", "memory_close"}
EVENTS = {"AgentPhaseCompleted", "AgentPhaseInvalidated"}
_ITEM_ID = re.compile(r"[A-Z0-9][A-Z0-9-]{0,127}")
_SHA256 = re.compile(r"[0-9a-f]{64}")
_GIT_HEAD = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?")
_DOCUMENT_KEYS = {
    "schema_version",
    "policy",
    "work_item_id",
    "attempt",
    "records",
}
_RECORD_KEYS = {
    "schema_version",
    "sequence",
    "event",
    "work_item_id",
    "attempt",
    "phase",
    "work_item_sha256",
    "head_commit",
    "control_binding_sha256",
    "candidate_snapshot_sha256",
    "occurred_at",
    "previous_record_sha256",
    "record_sha256",
}


class RunJournalError(RuntimeError):
    """A local journal cannot be trusted for replay."""

    def __init__(self, reason_code: str):
        super().__init__(reason_code)
        self.reason_code = reason_code


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _validate_identity(
    *,
    work_item_id: str,
    attempt: int,
    phase: str,
    work_item_sha256: str,
    head_commit: str,
    control_binding_sha256: str,
    candidate_snapshot_sha256: str,
) -> None:
    if not _ITEM_ID.fullmatch(work_item_id):
        raise RunJournalError("JOURNAL_WORK_ITEM_ID_INVALID")
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        raise RunJournalError("JOURNAL_ATTEMPT_INVALID")
    if phase not in PHASES:
        raise RunJournalError("JOURNAL_PHASE_INVALID")
    if not _SHA256.fullmatch(work_item_sha256):
        raise RunJournalError("JOURNAL_WORK_ITEM_DIGEST_INVALID")
    if not _GIT_HEAD.fullmatch(head_commit):
        raise RunJournalError("JOURNAL_HEAD_INVALID")
    if not _SHA256.fullmatch(control_binding_sha256):
        raise RunJournalError("JOURNAL_CONTROL_DIGEST_INVALID")
    if not _SHA256.fullmatch(candidate_snapshot_sha256):
        raise RunJournalError("JOURNAL_CANDIDATE_DIGEST_INVALID")


class RunJournal:
    """Bounded local journal whose records grant only duplicate-turn skipping."""

    def __init__(self, repo_root: Path):
        self.repo_root = repo_root.resolve()
        self.runtime_root = self.repo_root / RUNTIME_DIRECTORY
        self.root = self.runtime_root / JOURNAL_DIRECTORY
        self.lock_path = self.root / ".journal.lock"

    def _path(self, work_item_id: str, attempt: int) -> Path:
        if not _ITEM_ID.fullmatch(work_item_id):
            raise RunJournalError("JOURNAL_WORK_ITEM_ID_INVALID")
        if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
            raise RunJournalError("JOURNAL_ATTEMPT_INVALID")
        return self.root / f"{work_item_id.lower()}--attempt-{attempt}.json"

    @staticmethod
    def _validate_directory(path: Path, *, create: bool) -> bool:
        if not path.exists() and not path.is_symlink():
            if not create:
                return False
            path.mkdir(mode=0o700)
        if path.is_symlink() or not path.is_dir():
            raise RunJournalError("JOURNAL_DIRECTORY_INVALID")
        if stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise RunJournalError("JOURNAL_DIRECTORY_PERMISSIONS_INVALID")
        return True

    def _prepare_root(self) -> None:
        if not self.runtime_root.exists() and not self.runtime_root.is_symlink():
            self.runtime_root.mkdir(mode=0o700)
        if self.runtime_root.is_symlink() or not self.runtime_root.is_dir():
            raise RunJournalError("JOURNAL_RUNTIME_DIRECTORY_INVALID")
        if not self.root.exists() and not self.root.is_symlink():
            self.root.mkdir(mode=0o700)
        self._validate_directory(self.root, create=False)

    @staticmethod
    def _read_regular(path: Path) -> bytes:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(path, flags)
        except FileNotFoundError:
            raise
        except OSError as error:
            raise RunJournalError("JOURNAL_FILE_OPEN_FAILED") from error
        try:
            file_stat = os.fstat(descriptor)
            if not stat.S_ISREG(file_stat.st_mode):
                raise RunJournalError("JOURNAL_FILE_INVALID")
            if stat.S_IMODE(file_stat.st_mode) != 0o600:
                raise RunJournalError("JOURNAL_FILE_PERMISSIONS_INVALID")
            if file_stat.st_size > MAX_JOURNAL_BYTES:
                raise RunJournalError("JOURNAL_FILE_TOO_LARGE")
            payload = b""
            while True:
                chunk = os.read(descriptor, min(65536, MAX_JOURNAL_BYTES + 1))
                if not chunk:
                    break
                payload += chunk
                if len(payload) > MAX_JOURNAL_BYTES:
                    raise RunJournalError("JOURNAL_FILE_TOO_LARGE")
            return payload
        finally:
            os.close(descriptor)

    @staticmethod
    def _verify_document(
        payload: bytes,
        *,
        work_item_id: str,
        attempt: int,
    ) -> Dict[str, Any]:
        try:
            document = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise RunJournalError("JOURNAL_JSON_INVALID") from error
        if not isinstance(document, dict) or set(document) != _DOCUMENT_KEYS:
            raise RunJournalError("JOURNAL_DOCUMENT_INVALID")
        if (
            document.get("schema_version") != SCHEMA_VERSION
            or document.get("policy") != POLICY
            or document.get("work_item_id") != work_item_id
            or document.get("attempt") != attempt
        ):
            raise RunJournalError("JOURNAL_DOCUMENT_IDENTITY_INVALID")
        records = document.get("records")
        if not isinstance(records, list) or len(records) > MAX_RECORDS:
            raise RunJournalError("JOURNAL_RECORDS_INVALID")
        previous = None
        for index, record in enumerate(records, 1):
            if not isinstance(record, dict) or set(record) != _RECORD_KEYS:
                raise RunJournalError("JOURNAL_RECORD_INVALID")
            body = {
                key: value
                for key, value in record.items()
                if key != "record_sha256"
            }
            if (
                record.get("schema_version") != SCHEMA_VERSION
                or record.get("sequence") != index
                or record.get("event") not in EVENTS
                or record.get("work_item_id") != work_item_id
                or record.get("attempt") != attempt
                or record.get("phase") not in PHASES
                or not _SHA256.fullmatch(str(record.get("work_item_sha256", "")))
                or not _GIT_HEAD.fullmatch(str(record.get("head_commit", "")))
                or not _SHA256.fullmatch(
                    str(record.get("control_binding_sha256", ""))
                )
                or not _SHA256.fullmatch(
                    str(record.get("candidate_snapshot_sha256", ""))
                )
                or not isinstance(record.get("occurred_at"), str)
                or record.get("previous_record_sha256") != previous
                or record.get("record_sha256") != _sha256(_canonical(body))
            ):
                raise RunJournalError("JOURNAL_RECORD_BINDING_INVALID")
            previous = record["record_sha256"]
        return document

    def _read_document(
        self,
        *,
        work_item_id: str,
        attempt: int,
    ) -> Dict[str, Any]:
        path = self._path(work_item_id, attempt)
        if not self._validate_directory(self.root, create=False):
            raise FileNotFoundError(path)
        payload = self._read_regular(path)
        return self._verify_document(
            payload,
            work_item_id=work_item_id,
            attempt=attempt,
        )

    def inspect_completion(
        self,
        *,
        work_item_id: str,
        attempt: int,
        phase: str,
        work_item_sha256: str,
        head_commit: str,
        control_binding_sha256: str,
        candidate_snapshot_sha256: str,
    ) -> Dict[str, Any]:
        """Return a controlled replay verdict without exposing journal content."""
        _validate_identity(
            work_item_id=work_item_id,
            attempt=attempt,
            phase=phase,
            work_item_sha256=work_item_sha256,
            head_commit=head_commit,
            control_binding_sha256=control_binding_sha256,
            candidate_snapshot_sha256=candidate_snapshot_sha256,
        )
        try:
            document = self._read_document(
                work_item_id=work_item_id,
                attempt=attempt,
            )
        except FileNotFoundError:
            return {"status": "missing", "reason_code": "NO_JOURNAL_RECORD"}
        except RunJournalError as error:
            return {"status": "invalid", "reason_code": error.reason_code}
        matching_phase = [
            record
            for record in document["records"]
            if record["phase"] == phase
        ]
        if not matching_phase:
            return {"status": "missing", "reason_code": "NO_PHASE_COMPLETION"}
        record = matching_phase[-1]
        if record["event"] != "AgentPhaseCompleted":
            return {
                "status": "stale",
                "reason_code": "JOURNAL_PHASE_INVALIDATED",
            }
        expected = {
            "work_item_sha256": work_item_sha256,
            "head_commit": head_commit,
            "control_binding_sha256": control_binding_sha256,
            "candidate_snapshot_sha256": candidate_snapshot_sha256,
        }
        mismatches = [
            key
            for key, value in expected.items()
            if record.get(key) != value
        ]
        if mismatches:
            return {
                "status": "stale",
                "reason_code": "JOURNAL_BINDING_MISMATCH",
                "mismatches": mismatches,
            }
        return {
            "status": "match",
            "reason_code": "AGENT_PHASE_ALREADY_COMPLETED",
            "sequence": record["sequence"],
            "record_sha256": record["record_sha256"],
        }

    def _open_lock(self) -> int:
        self._prepare_root()
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.lock_path, flags, 0o600)
        except OSError as error:
            raise RunJournalError("JOURNAL_LOCK_OPEN_FAILED") from error
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            os.close(descriptor)
            raise RunJournalError("JOURNAL_LOCK_INVALID")
        os.fchmod(descriptor, 0o600)
        return descriptor

    def _atomic_write(self, path: Path, payload: bytes) -> None:
        if len(payload) > MAX_JOURNAL_BYTES:
            raise RunJournalError("JOURNAL_FILE_TOO_LARGE")
        if path.exists() and (path.is_symlink() or not path.is_file()):
            raise RunJournalError("JOURNAL_FILE_INVALID")
        descriptor, raw_temporary = tempfile.mkstemp(
            dir=str(self.root),
            prefix=f".{path.name}.",
        )
        temporary = Path(raw_temporary)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, path)
            directory_descriptor = os.open(self.root, os.O_RDONLY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        finally:
            temporary.unlink(missing_ok=True)

    def _append_phase_event(
        self,
        *,
        event: str,
        work_item_id: str,
        attempt: int,
        phase: str,
        work_item_sha256: str,
        head_commit: str,
        control_binding_sha256: str,
        candidate_snapshot_sha256: str,
    ) -> Dict[str, Any]:
        if event not in EVENTS:
            raise RunJournalError("JOURNAL_EVENT_INVALID")
        _validate_identity(
            work_item_id=work_item_id,
            attempt=attempt,
            phase=phase,
            work_item_sha256=work_item_sha256,
            head_commit=head_commit,
            control_binding_sha256=control_binding_sha256,
            candidate_snapshot_sha256=candidate_snapshot_sha256,
        )
        path = self._path(work_item_id, attempt)
        lock_descriptor = self._open_lock()
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
            if path.exists() or path.is_symlink():
                document = self._read_document(
                    work_item_id=work_item_id,
                    attempt=attempt,
                )
            else:
                journal_count = len(
                    [
                        candidate
                        for candidate in self.root.glob("*.json")
                        if candidate.is_file() and not candidate.is_symlink()
                    ]
                )
                if journal_count >= MAX_JOURNAL_FILES:
                    raise RunJournalError("JOURNAL_FILE_LIMIT_REACHED")
                document = {
                    "schema_version": SCHEMA_VERSION,
                    "policy": POLICY,
                    "work_item_id": work_item_id,
                    "attempt": attempt,
                    "records": [],
                }
            records: List[Mapping[str, Any]] = document["records"]
            if len(records) >= MAX_RECORDS:
                raise RunJournalError("JOURNAL_RECORD_LIMIT_REACHED")
            previous = records[-1]["record_sha256"] if records else None
            body = {
                "schema_version": SCHEMA_VERSION,
                "sequence": len(records) + 1,
                "event": event,
                "work_item_id": work_item_id,
                "attempt": attempt,
                "phase": phase,
                "work_item_sha256": work_item_sha256,
                "head_commit": head_commit,
                "control_binding_sha256": control_binding_sha256,
                "candidate_snapshot_sha256": candidate_snapshot_sha256,
                "occurred_at": _utc_now(),
                "previous_record_sha256": previous,
            }
            record = {**body, "record_sha256": _sha256(_canonical(body))}
            document["records"].append(record)
            self._atomic_write(path, _canonical(document) + b"\n")
            return {
                "status": "recorded",
                "policy": POLICY,
                "event": event,
                "sequence": record["sequence"],
                "record_sha256": record["record_sha256"],
            }
        finally:
            try:
                fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
            finally:
                os.close(lock_descriptor)

    def append_completion(
        self,
        *,
        work_item_id: str,
        attempt: int,
        phase: str,
        work_item_sha256: str,
        head_commit: str,
        control_binding_sha256: str,
        candidate_snapshot_sha256: str,
    ) -> Dict[str, Any]:
        return self._append_phase_event(
            event="AgentPhaseCompleted",
            work_item_id=work_item_id,
            attempt=attempt,
            phase=phase,
            work_item_sha256=work_item_sha256,
            head_commit=head_commit,
            control_binding_sha256=control_binding_sha256,
            candidate_snapshot_sha256=candidate_snapshot_sha256,
        )

    def invalidate_completion(
        self,
        *,
        work_item_id: str,
        attempt: int,
        phase: str,
        work_item_sha256: str,
        head_commit: str,
        control_binding_sha256: str,
        candidate_snapshot_sha256: str,
    ) -> Dict[str, Any]:
        return self._append_phase_event(
            event="AgentPhaseInvalidated",
            work_item_id=work_item_id,
            attempt=attempt,
            phase=phase,
            work_item_sha256=work_item_sha256,
            head_commit=head_commit,
            control_binding_sha256=control_binding_sha256,
            candidate_snapshot_sha256=candidate_snapshot_sha256,
        )
