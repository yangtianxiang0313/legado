#!/usr/bin/env python3
"""Reference-only external journal and isolated patch verification runner."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import hmac
import json
import os
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

try:
    from .harness import path_matches, sha256_json
except ImportError:
    from harness import path_matches, sha256_json  # type: ignore


SCHEMA_VERSION = 1
RUNNER_VERSION = "trusted-supervisor-reference-v1"
SAFE_ENV = ("PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME")
EVENTS = {
    "AttemptStarted",
    "AgentCompleted",
    "CandidateFrozen",
    "VerificationPassed",
    "AttemptVerified",
    "AttemptRejected",
}


class TrustedSupervisorError(RuntimeError):
    def __init__(self, reason_code: str, message: str):
        super().__init__(message)
        self.reason_code = reason_code


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _read_key(path: Path) -> bytes:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise TrustedSupervisorError("KEY_PATH_INVALID", str(path))
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise TrustedSupervisorError("KEY_PERMISSIONS_INVALID", str(path))
    key = path.read_bytes()
    if len(key) < 32:
        raise TrustedSupervisorError("KEY_TOO_SHORT", str(len(key)))
    return key


def _outside(path: Path, repo: Path, label: str) -> Path:
    if not path.is_absolute() or path.is_symlink():
        raise TrustedSupervisorError(f"{label}_PATH_INVALID", str(path))
    resolved = path.resolve()
    try:
        resolved.relative_to(repo)
    except ValueError:
        return resolved
    raise TrustedSupervisorError(f"{label}_INSIDE_REPO", str(path))


def _git(repo: Path, *args: str, input_bytes: Optional[bytes] = None) -> bytes:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=30,
        check=False,
    )
    if result.returncode != 0:
        raise TrustedSupervisorError(
            "GIT_COMMAND_FAILED", f"{' '.join(args)}:{result.returncode}"
        )
    return result.stdout


class SignedJournal:
    def __init__(self, path: Path, key: bytes):
        self.path = path
        self.key = key

    def verify(self) -> List[Mapping[str, Any]]:
        if not self.path.exists():
            return []
        if self.path.is_symlink() or not self.path.is_file():
            raise TrustedSupervisorError("JOURNAL_PATH_INVALID", str(self.path))
        events: List[Mapping[str, Any]] = []
        previous = None
        attempt_states: Dict[str, str] = {}
        allowed = {
            None: {"AttemptStarted": "started"},
            "started": {"AgentCompleted": "agent_completed", "AttemptRejected": "terminal"},
            "agent_completed": {"CandidateFrozen": "frozen", "AttemptRejected": "terminal"},
            "frozen": {"VerificationPassed": "passed", "AttemptRejected": "terminal"},
            "passed": {"AttemptVerified": "terminal", "AttemptRejected": "terminal"},
            "terminal": {},
        }
        for index, raw in enumerate(self.path.read_bytes().splitlines(), 1):
            try:
                event = json.loads(raw)
            except json.JSONDecodeError as error:
                raise TrustedSupervisorError("JOURNAL_JSON_INVALID", str(index)) from error
            if not isinstance(event, dict):
                raise TrustedSupervisorError("JOURNAL_EVENT_INVALID", str(index))
            signature = event.get("signature")
            unsigned = {key: value for key, value in event.items() if key != "signature"}
            event_hash = unsigned.get("event_hash")
            body = {key: value for key, value in unsigned.items() if key != "event_hash"}
            if unsigned.get("sequence") != index:
                raise TrustedSupervisorError("JOURNAL_SEQUENCE_INVALID", str(index))
            if unsigned.get("previous_event_hash") != previous:
                raise TrustedSupervisorError("JOURNAL_CHAIN_INVALID", str(index))
            if unsigned.get("event") not in EVENTS:
                raise TrustedSupervisorError("JOURNAL_EVENT_UNKNOWN", str(index))
            if event_hash != _sha(_canonical(body)):
                raise TrustedSupervisorError("JOURNAL_HASH_INVALID", str(index))
            expected = hmac.new(self.key, event_hash.encode(), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(str(signature), expected):
                raise TrustedSupervisorError("JOURNAL_SIGNATURE_INVALID", str(index))
            attempt = unsigned.get("attempt_id")
            current_state = attempt_states.get(str(attempt))
            transition = allowed[current_state].get(str(unsigned.get("event")))
            if transition is None:
                raise TrustedSupervisorError("JOURNAL_TRANSITION_INVALID", str(index))
            attempt_states[str(attempt)] = transition
            previous = event_hash
            events.append(event)
        return events

    def append(
        self,
        event_name: str,
        attempt_id: str,
        work_item_id: str,
        base_commit: str,
        work_item_sha256: str,
        payload: Mapping[str, Any],
    ) -> Mapping[str, Any]:
        if event_name not in EVENTS:
            raise TrustedSupervisorError("JOURNAL_EVENT_UNKNOWN", event_name)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            with os.fdopen(descriptor, "r+b", closefd=True) as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
                current = self.verify()
                previous = current[-1]["event_hash"] if current else None
                body = {
                    "schema_version": SCHEMA_VERSION,
                    "sequence": len(current) + 1,
                    "event": event_name,
                    "attempt_id": attempt_id,
                    "work_item_id": work_item_id,
                    "base_commit": base_commit,
                    "work_item_sha256": work_item_sha256,
                    "previous_event_hash": previous,
                    "payload": dict(payload),
                }
                event_hash = _sha(_canonical(body))
                event = {
                    **body,
                    "event_hash": event_hash,
                    "signature": hmac.new(
                        self.key, event_hash.encode(), hashlib.sha256
                    ).hexdigest(),
                }
                handle.seek(0, os.SEEK_END)
                handle.write(_canonical(event) + b"\n")
                handle.flush()
                os.fsync(handle.fileno())
                return event
        finally:
            # fd is owned by fdopen after success; only close when fdopen failed.
            try:
                os.close(descriptor)
            except OSError:
                pass


def _process_group_exists(pid: int) -> bool:
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _wait_for_process_group_exit(
    pid: int,
    *,
    timeout_seconds: float = 1.0,
    poll_seconds: float = 0.01,
) -> bool:
    """Allow a signalled process group a bounded OS reaping window."""
    deadline = time.monotonic() + timeout_seconds
    while _process_group_exists(pid):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(poll_seconds, remaining))
    return True


def _run_argv(
    argv: Sequence[str],
    cwd: Path,
    timeout: int,
    source_environment: Mapping[str, str],
) -> Mapping[str, Any]:
    if not argv or any(not isinstance(value, str) or not value for value in argv):
        raise TrustedSupervisorError("ARGV_INVALID", repr(argv))
    environment = {
        key: source_environment[key] for key in SAFE_ENV if key in source_environment
    }
    started = time.monotonic()
    process = subprocess.Popen(
        list(argv),
        cwd=cwd,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    timed_out = False
    cleanup_error = None
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError) as error:
            cleanup_error = type(error).__name__
        try:
            stdout, stderr = process.communicate(timeout=0.25)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError) as error:
                cleanup_error = cleanup_error or type(error).__name__
            try:
                stdout, stderr = process.communicate(timeout=1)
            except subprocess.TimeoutExpired as error:
                stdout = error.output or b""
                stderr = error.stderr or b""
                cleanup_error = cleanup_error or "communicate_timeout"
    leak = not _wait_for_process_group_exit(process.pid)
    return {
        "exit_code": process.returncode,
        "timed_out": timed_out,
        "process_leak": leak,
        "cleanup_error": cleanup_error,
        "duration_ms": int((time.monotonic() - started) * 1000),
        "stdout_sha256": _sha(stdout or b""),
        "stderr_sha256": _sha(stderr or b""),
        "stdout_bytes": len(stdout or b""),
        "stderr_bytes": len(stderr or b""),
    }


def _replace(argv: Sequence[str], values: Mapping[str, str]) -> List[str]:
    result = []
    for part in argv:
        value = part
        for key, replacement in values.items():
            value = value.replace("{" + key + "}", replacement)
        result.append(value)
    return result


class ReferenceSupervisor:
    def __init__(self, repo: Path, control_root: Path, key_path: Path):
        self.repo = repo.resolve()
        self.control_root = _outside(control_root, self.repo, "CONTROL_ROOT")
        self.key_path = _outside(key_path, self.repo, "KEY")
        self.key = _read_key(self.key_path)
        self.journal = SignedJournal(self.control_root / "journal.jsonl", self.key)

    def doctor(self, base_commit: str) -> Mapping[str, Any]:
        if not self.repo.is_dir() or self.repo.is_symlink():
            raise TrustedSupervisorError("REPO_INVALID", str(self.repo))
        top = _git(self.repo, "rev-parse", "--show-toplevel").decode().strip()
        if Path(top).resolve() != self.repo:
            raise TrustedSupervisorError("REPO_ROOT_MISMATCH", top)
        if _git(self.repo, "status", "--porcelain").strip():
            raise TrustedSupervisorError("REPO_DIRTY", str(self.repo))
        _git(self.repo, "cat-file", "-e", f"{base_commit}^{{commit}}")
        self.journal.verify()
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "ready",
            "reason_code": "REFERENCE_SUPERVISOR_READY",
            "base_commit": base_commit,
        }

    def _work_item(self, base_commit: str, item_id: str) -> Mapping[str, Any]:
        raw = _git(
            self.repo,
            "show",
            f"{base_commit}:ios/harness/work-items/{item_id}.json",
        )
        try:
            item = json.loads(raw)
        except json.JSONDecodeError as error:
            raise TrustedSupervisorError("WORK_ITEM_INVALID", item_id) from error
        if item.get("metadata", {}).get("id") != item_id:
            raise TrustedSupervisorError("WORK_ITEM_INVALID", item_id)
        return item

    def _scope(
        self, worktree: Path, item: Mapping[str, Any]
    ) -> Tuple[List[str], int, bytes, str]:
        _git(worktree, "add", "-A", "--", ".")
        raw = _git(
            worktree,
            "diff",
            "--cached",
            "--name-status",
            "-z",
            "--find-renames",
            "HEAD",
        )
        tokens = raw.decode("utf-8", errors="strict").split("\0")
        paths: List[str] = []
        index = 0
        while index < len(tokens) and tokens[index]:
            status_code = tokens[index]
            index += 1
            count = 2 if status_code.startswith(("R", "C")) else 1
            for _ in range(count):
                if index >= len(tokens) or not tokens[index]:
                    raise TrustedSupervisorError("DIFF_PARSE_INVALID", status_code)
                paths.append(tokens[index])
                index += 1
        paths = sorted(set(paths))
        scope = item["spec"]["scope"]
        protected = [
            "ios/project/state.json",
            "ios/project/status.md",
            "ios/project/events.jsonl",
            "ios/harness/evidence/runs/**",
            "ios/project/approvals/**",
            "ios/harness/goldens/**",
        ]
        errors = []
        for relative in paths:
            path = worktree / relative
            if path.is_symlink() or (path.exists() and path.is_dir()):
                errors.append(f"UNSAFE_PATH:{relative}")
            if path_matches(relative, protected):
                errors.append(f"PROTECTED:{relative}")
            elif path_matches(relative, scope.get("deny_write", [])):
                errors.append(f"DENY:{relative}")
            elif not path_matches(relative, scope.get("allow_write", [])):
                errors.append(f"ALLOW:{relative}")
            stage = _git(worktree, "ls-files", "--stage", "--", relative).decode()
            if stage.startswith("160000 "):
                errors.append(f"SUBMODULE:{relative}")
        numstat = _git(worktree, "diff", "--cached", "--numstat", "HEAD").decode()
        changed_lines = 0
        for line in numstat.splitlines():
            added, deleted, _ = line.split("\t", 2)
            if added.isdigit():
                changed_lines += int(added)
            if deleted.isdigit():
                changed_lines += int(deleted)
        if len(paths) > int(scope["max_files_changed"]):
            errors.append("FILE_BUDGET")
        if changed_lines > int(scope["max_changed_lines"]):
            errors.append("LINE_BUDGET")
        if not paths:
            errors.append("NO_CHANGES")
        if errors:
            raise TrustedSupervisorError("SCOPE_REJECTED", ";".join(errors))
        patch = _git(
            worktree,
            "diff",
            "--cached",
            "--binary",
            "--full-index",
            "HEAD",
        )
        tree = _git(worktree, "write-tree").decode().strip()
        return paths, changed_lines, patch, tree

    def run_attempt(
        self,
        *,
        base_commit: str,
        work_item_id: str,
        config_path: Path,
        environment: Optional[Mapping[str, str]] = None,
    ) -> Mapping[str, Any]:
        self.doctor(base_commit)
        config_path = _outside(config_path, self.repo, "CONFIG")
        config = json.loads(config_path.read_text(encoding="utf-8"))
        agent_argv = config.get("agent_argv")
        verifier_argv = config.get("verifier_argv")
        if not isinstance(agent_argv, list) or not isinstance(verifier_argv, list):
            raise TrustedSupervisorError("CONFIG_INVALID", str(config_path))
        agent_timeout = int(config.get("agent_timeout_seconds", 3600))
        verifier_timeout = int(config.get("verifier_timeout_seconds", 600))
        item = self._work_item(base_commit, work_item_id)
        item_sha = sha256_json(item)
        attempt_id = "attempt-" + secrets.token_hex(12)
        worktrees = self.control_root / "worktrees"
        agent_tree = worktrees / f"{attempt_id}-agent"
        verify_tree = worktrees / f"{attempt_id}-verify"
        artifact_dir = self.control_root / "artifacts" / attempt_id
        source_environment = dict(os.environ if environment is None else environment)
        self.journal.append(
            "AttemptStarted",
            attempt_id,
            work_item_id,
            base_commit,
            item_sha,
            {"config_sha256": _sha(config_path.read_bytes())},
        )
        try:
            worktrees.mkdir(parents=True, exist_ok=True)
            _git(
                self.repo,
                "worktree",
                "add",
                "--detach",
                str(agent_tree),
                base_commit,
            )
            values = {
                "repo_root": str(agent_tree),
                "work_item_id": work_item_id,
                "attempt_id": attempt_id,
            }
            agent_result = _run_argv(
                _replace(agent_argv, values),
                agent_tree,
                agent_timeout,
                source_environment,
            )
            if (
                agent_result["exit_code"] != 0
                or agent_result["timed_out"]
                or agent_result["process_leak"]
                or agent_result["cleanup_error"]
            ):
                raise TrustedSupervisorError("AGENT_FAILED", sha256_json(agent_result))
            self.journal.append(
                "AgentCompleted",
                attempt_id,
                work_item_id,
                base_commit,
                item_sha,
                agent_result,
            )
            paths, lines, patch, candidate_tree = self._scope(agent_tree, item)
            self.journal.append(
                "CandidateFrozen",
                attempt_id,
                work_item_id,
                base_commit,
                item_sha,
                {
                    "paths": paths,
                    "changed_lines": lines,
                    "patch_sha256": _sha(patch),
                    "candidate_tree": candidate_tree,
                },
            )
            _git(
                self.repo,
                "worktree",
                "add",
                "--detach",
                str(verify_tree),
                base_commit,
            )
            _git(verify_tree, "apply", "--index", input_bytes=patch)
            replay_tree = _git(verify_tree, "write-tree").decode().strip()
            if replay_tree != candidate_tree:
                raise TrustedSupervisorError("REPLAY_TREE_DRIFT", replay_tree)
            verify_values = {
                "repo_root": str(verify_tree),
                "work_item_id": work_item_id,
                "attempt_id": attempt_id,
            }
            verifier_result = _run_argv(
                _replace(verifier_argv, verify_values),
                verify_tree,
                verifier_timeout,
                source_environment,
            )
            if (
                verifier_result["exit_code"] != 0
                or verifier_result["timed_out"]
                or verifier_result["process_leak"]
                or verifier_result["cleanup_error"]
            ):
                raise TrustedSupervisorError(
                    "VERIFIER_FAILED", sha256_json(verifier_result)
                )
            verified_event = self.journal.append(
                "VerificationPassed",
                attempt_id,
                work_item_id,
                base_commit,
                item_sha,
                {
                    **verifier_result,
                    "definition_sha256": sha256_json(verifier_argv),
                    "replay_tree": replay_tree,
                },
            )
            manifest_unsigned = {
                "schema_version": SCHEMA_VERSION,
                "runner_version": RUNNER_VERSION,
                "attempt_id": attempt_id,
                "work_item_id": work_item_id,
                "work_item_sha256": item_sha,
                "base_commit": base_commit,
                "patch_sha256": _sha(patch),
                "candidate_tree": candidate_tree,
                "paths": paths,
                "changed_lines": lines,
                "verifier_definition_sha256": sha256_json(verifier_argv),
                "verifier_result_sha256": sha256_json(verifier_result),
                "journal_head": verified_event["event_hash"],
            }
            manifest = {
                **manifest_unsigned,
                "signature": hmac.new(
                    self.key, _canonical(manifest_unsigned), hashlib.sha256
                ).hexdigest(),
            }
            manifest_path = self._write_artifact_pair(artifact_dir, patch, manifest)
            final_event = self.journal.append(
                "AttemptVerified",
                attempt_id,
                work_item_id,
                base_commit,
                item_sha,
                {
                    "manifest_sha256": _sha(manifest_path.read_bytes()),
                    "patch_sha256": _sha(patch),
                },
            )
            return {
                "schema_version": SCHEMA_VERSION,
                "outcome": "verified_artifact",
                "attempt_id": attempt_id,
                "artifact_dir": str(artifact_dir),
                "journal_head": final_event["event_hash"],
            }
        except Exception as error:
            reason = (
                error.reason_code
                if isinstance(error, TrustedSupervisorError)
                else type(error).__name__
            )
            self.journal.append(
                "AttemptRejected",
                attempt_id,
                work_item_id,
                base_commit,
                item_sha,
                {"reason_code": reason, "detail_sha256": _sha(str(error).encode())},
            )
            if artifact_dir.exists():
                for path in artifact_dir.iterdir():
                    path.unlink(missing_ok=True)
                artifact_dir.rmdir()
            raise
        finally:
            for tree in (verify_tree, agent_tree):
                if tree.exists():
                    subprocess.run(
                        ["git", "worktree", "remove", "--force", str(tree)],
                        cwd=self.repo,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        check=False,
                    )
            subprocess.run(
                ["git", "worktree", "prune"],
                cwd=self.repo,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    @staticmethod
    def _write_artifact_pair(
        artifact_dir: Path,
        patch: bytes,
        manifest: Mapping[str, Any],
    ) -> Path:
        artifact_parent = artifact_dir.parent
        artifact_parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(
            tempfile.mkdtemp(
                dir=artifact_parent,
                prefix=f".{artifact_dir.name}.artifact.",
            )
        )
        try:
            patch_path = temporary / "candidate.patch"
            manifest_path = temporary / "manifest.json"
            patch_path.write_bytes(patch)
            manifest_path.write_bytes(
                json.dumps(
                    manifest,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                ).encode()
                + b"\n"
            )
            os.chmod(patch_path, 0o600)
            os.chmod(manifest_path, 0o600)
            os.replace(temporary, artifact_dir)
            return artifact_dir / "manifest.json"
        finally:
            if temporary.exists():
                for path in temporary.iterdir():
                    path.unlink(missing_ok=True)
                temporary.rmdir()

    def verify_artifact(self, manifest_path: Path) -> Mapping[str, Any]:
        manifest_path = _outside(manifest_path, self.repo, "MANIFEST")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        signature = manifest.pop("signature", None)
        expected = hmac.new(self.key, _canonical(manifest), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(str(signature), expected):
            raise TrustedSupervisorError("ARTIFACT_SIGNATURE_INVALID", str(manifest_path))
        patch = manifest_path.parent / "candidate.patch"
        if _sha(patch.read_bytes()) != manifest.get("patch_sha256"):
            raise TrustedSupervisorError("ARTIFACT_PATCH_INVALID", str(patch))
        events = self.journal.verify()
        terminal = next(
            (
                event
                for event in events
                if event.get("event") == "AttemptVerified"
                and event.get("attempt_id") == manifest.get("attempt_id")
            ),
            None,
        )
        if terminal is None:
            raise TrustedSupervisorError("ARTIFACT_JOURNAL_MISSING", str(manifest_path))
        if (
            terminal.get("payload", {}).get("manifest_sha256")
            != _sha(manifest_path.read_bytes())
            or terminal.get("payload", {}).get("patch_sha256")
            != manifest.get("patch_sha256")
        ):
            raise TrustedSupervisorError("ARTIFACT_JOURNAL_DRIFT", str(manifest_path))
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "valid",
            "attempt_id": manifest.get("attempt_id"),
        }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Reference external attempt verifier")
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--control-root", type=Path, required=True)
    parser.add_argument("--key-file", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    doctor_parser = sub.add_parser("doctor")
    doctor_parser.add_argument("--base", required=True)
    run_parser = sub.add_parser("run-attempt")
    run_parser.add_argument("--base", required=True)
    run_parser.add_argument("--work-item", required=True)
    run_parser.add_argument("--config", type=Path, required=True)
    sub.add_parser("verify-journal")
    artifact = sub.add_parser("verify-artifact")
    artifact.add_argument("manifest", type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        supervisor = ReferenceSupervisor(args.repo, args.control_root, args.key_file)
        if args.command == "doctor":
            result = supervisor.doctor(args.base)
        elif args.command == "run-attempt":
            result = supervisor.run_attempt(
                base_commit=args.base,
                work_item_id=args.work_item,
                config_path=args.config,
            )
        elif args.command == "verify-journal":
            events = supervisor.journal.verify()
            result = {
                "schema_version": SCHEMA_VERSION,
                "status": "valid",
                "events": len(events),
                "head": events[-1]["event_hash"] if events else None,
            }
        else:
            result = supervisor.verify_artifact(args.manifest)
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        return 0
    except TrustedSupervisorError as error:
        print(
            json.dumps(
                {
                    "schema_version": SCHEMA_VERSION,
                    "status": "failed",
                    "reason_code": error.reason_code,
                    "detail_sha256": _sha(str(error).encode()),
                },
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
