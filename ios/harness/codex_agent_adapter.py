#!/usr/bin/env python3
"""Secret-minimizing Codex exec adapter for the local Loop Supervisor."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple

try:
    from .harness import sha256_json
except ImportError:
    from harness import sha256_json  # type: ignore


SCHEMA_VERSION = 1
ADAPTER_VERSION = "codex-exec-adapter-v2"
THREAD_ID = re.compile(r"^[A-Za-z0-9_-]{8,128}$")
SAFE_ENVIRONMENT = ("PATH", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME")
SAFE_SANDBOX_MODES = {"read-only", "workspace-write"}


class AdapterError(RuntimeError):
    def __init__(self, reason_code: str, message: str):
        super().__init__(message)
        self.reason_code = reason_code


def _sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw = tempfile.mkstemp(
        dir=str(path.parent), prefix=f".{path.name}.codex-adapter."
    )
    temporary = Path(raw)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _resolve_executable(raw: str, environment: Mapping[str, str]) -> Path:
    if "/" in raw:
        path = Path(raw)
        if not path.is_absolute():
            raise AdapterError("EXECUTABLE_PATH_NOT_ABSOLUTE", raw)
    else:
        found = shutil.which(raw, path=environment.get("PATH"))
        if found is None:
            raise AdapterError("EXECUTABLE_NOT_FOUND", raw)
        path = Path(found)
    if path.is_symlink():
        raise AdapterError("EXECUTABLE_SYMLINK_REJECTED", str(path))
    if not path.is_file():
        raise AdapterError("EXECUTABLE_NOT_FILE", str(path))
    if not os.access(path, os.X_OK):
        raise AdapterError("EXECUTABLE_NOT_EXECUTABLE", str(path))
    return path


def doctor(
    executable: str,
    environment: Optional[Mapping[str, str]] = None,
) -> Mapping[str, Any]:
    source_environment = dict(os.environ if environment is None else environment)
    try:
        path = _resolve_executable(executable, source_environment)
        child_environment = {
            key: source_environment[key]
            for key in SAFE_ENVIRONMENT
            if key in source_environment
        }
        try:
            result = subprocess.run(
                [str(path), "--version"],
                env=child_environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            raise AdapterError("VERSION_TIMEOUT", str(path))
        except OSError as error:
            raise AdapterError("EXECUTABLE_BROKEN", f"{type(error).__name__}")
        version = result.stdout.decode("utf-8", errors="replace").strip()
        if result.returncode != 0:
            raise AdapterError("VERSION_EXIT_NONZERO", str(result.returncode))
        if not version:
            raise AdapterError("VERSION_EMPTY", str(path))
        help_root = tempfile.gettempdir()
        help_contracts = (
            (
                "EXEC",
                [
                    str(path),
                    "--sandbox",
                    "read-only",
                    "--ask-for-approval",
                    "never",
                    "--cd",
                    help_root,
                    "exec",
                    "--help",
                ],
                ("--json", "--ignore-user-config"),
            ),
            (
                "RESUME",
                [
                    str(path),
                    "--sandbox",
                    "read-only",
                    "--ask-for-approval",
                    "never",
                    "--cd",
                    help_root,
                    "exec",
                    "resume",
                    "--help",
                ],
                ("SESSION_ID", "--json", "--ignore-user-config"),
            ),
        )
        for label, argv, required in help_contracts:
            try:
                help_result = subprocess.run(
                    argv,
                    env=child_environment,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                raise AdapterError(f"{label}_HELP_TIMEOUT", str(path))
            except OSError as error:
                raise AdapterError(
                    f"{label}_HELP_BROKEN", type(error).__name__
                ) from error
            if help_result.returncode != 0:
                raise AdapterError(
                    f"{label}_HELP_EXIT_NONZERO",
                    str(help_result.returncode),
                )
            help_text = help_result.stdout.decode("utf-8", errors="replace")
            missing = [value for value in required if value not in help_text]
            if missing:
                raise AdapterError(
                    f"{label}_HELP_CONTRACT_MISMATCH",
                    ",".join(missing),
                )
        return {
            "schema_version": SCHEMA_VERSION,
            "adapter_version": ADAPTER_VERSION,
            "status": "available",
            "reason_code": "CODEX_EXECUTABLE_READY",
            "executable": str(path),
            "version": version[:200],
            "version_sha256": _sha256(result.stdout),
        }
    except AdapterError as error:
        return {
            "schema_version": SCHEMA_VERSION,
            "adapter_version": ADAPTER_VERSION,
            "status": "unavailable",
            "reason_code": error.reason_code,
            "detail": str(error),
        }


def _git_binding(repo: Path, environment: Mapping[str, str]) -> Tuple[str, str]:
    try:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=repo,
            env=dict(environment),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
            text=True,
        )
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo,
            env=dict(environment),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
            text=True,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AdapterError("GIT_DIAGNOSTIC_FAILED", type(error).__name__) from error
    if top.returncode != 0 or head.returncode != 0:
        raise AdapterError("GIT_REPOSITORY_REQUIRED", str(repo))
    actual = Path(top.stdout.strip()).resolve()
    if actual != repo:
        raise AdapterError("REPO_ROOT_MISMATCH", f"{repo} != {actual}")
    commit = head.stdout.strip()
    return commit, sha256_json({"repo": str(repo), "base_commit": commit})


def _load_context(
    context_path: Path,
    work_item_id: str,
    environment: Mapping[str, str],
) -> Mapping[str, Any]:
    if not context_path.is_absolute():
        raise AdapterError("CONTEXT_PATH_NOT_ABSOLUTE", str(context_path))
    if context_path.is_symlink() or not context_path.is_file():
        raise AdapterError("CONTEXT_NOT_REGULAR", str(context_path))
    mode = stat.S_IMODE(context_path.stat().st_mode)
    if mode & 0o077:
        raise AdapterError("CONTEXT_PERMISSIONS_TOO_BROAD", oct(mode))
    if environment.get("LEGADO_WORK_ITEM_ID") != work_item_id:
        raise AdapterError("WORK_ITEM_ENV_MISMATCH", work_item_id)
    env_context = environment.get("LEGADO_CONTEXT_PATH")
    if env_context is None or Path(env_context).resolve() != context_path.resolve():
        raise AdapterError("CONTEXT_ENV_MISMATCH", str(context_path))
    try:
        context = json.loads(context_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AdapterError("CONTEXT_JSON_INVALID", type(error).__name__) from error
    if not isinstance(context, dict):
        raise AdapterError("CONTEXT_JSON_INVALID", "not_object")
    item = context.get("work_item")
    context_id = (
        item.get("metadata", {}).get("id") if isinstance(item, dict) else None
    )
    if context_id != work_item_id:
        raise AdapterError("CONTEXT_WORK_ITEM_MISMATCH", str(context_id))
    expected_sha = context.get("work_item_sha256")
    if not isinstance(expected_sha, str) or sha256_json(item) != expected_sha:
        raise AdapterError("CONTEXT_WORK_ITEM_SHA_MISMATCH", work_item_id)
    return context


def _session(
    path: Path,
    work_item_id: str,
    work_item_sha256: str,
    repo_sha256: str,
) -> Optional[Mapping[str, Any]]:
    if path.is_symlink():
        raise AdapterError("SESSION_SYMLINK_REJECTED", str(path))
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AdapterError("SESSION_INVALID", type(error).__name__) from error
    if not isinstance(value, dict):
        raise AdapterError("SESSION_INVALID", "not_object")
    if (
        value.get("schema_version") != SCHEMA_VERSION
        or value.get("adapter_version") != ADAPTER_VERSION
    ):
        raise AdapterError("SESSION_VERSION_UNSUPPORTED", work_item_id)
    binding = (
        value.get("work_item_id"),
        value.get("work_item_sha256"),
        value.get("repo_sha256"),
    )
    expected = (work_item_id, work_item_sha256, repo_sha256)
    if binding != expected:
        raise AdapterError("SESSION_BINDING_DRIFT", work_item_id)
    thread_id = value.get("thread_id")
    if not isinstance(thread_id, str) or THREAD_ID.fullmatch(thread_id) is None:
        raise AdapterError("SESSION_THREAD_INVALID", str(thread_id))
    return value


def _prompt(work_item_id: str, context_path: Path) -> str:
    return (
        "You are the implementation Agent for exactly one already-claimed Legado iOS "
        f"Harness Work Item: {work_item_id}. Read the immutable context packet at "
        f"{context_path}. Follow required_read_order and the Work Item scope, AC, "
        "budget, stop_on, architecture, Requirement, SourceLab and knowledge contracts. "
        "Do not claim another item, edit protected inputs, approve gates, materialize "
        "candidates, update golden/published authority, or bypass Harness state. "
        "Implement only allowed changes, run the declared verification, update "
        "Capability/Checkpoint/Pitfall memory after passing Evidence, call close, and "
        "stop cleanly when a human gate or blocker is reached."
    )


def _codex_argv(
    executable: Path,
    repo: Path,
    *,
    sandbox_mode: str,
    thread_id: Optional[str],
) -> Sequence[str]:
    if sandbox_mode not in SAFE_SANDBOX_MODES:
        raise AdapterError("SANDBOX_MODE_UNSAFE", sandbox_mode)
    if thread_id is not None and THREAD_ID.fullmatch(thread_id) is None:
        raise AdapterError("THREAD_ID_INVALID", thread_id)
    top_level = [
        str(executable),
        "--sandbox",
        sandbox_mode,
        "--ask-for-approval",
        "never",
        "--cd",
        str(repo),
    ]
    exec_options = ["--json", "--ignore-user-config"]
    if thread_id is None:
        return [*top_level, "exec", *exec_options, "-"]
    return [
        *top_level,
        "exec",
        "resume",
        *exec_options,
        thread_id,
        "-",
    ]


def _parse_jsonl(
    payload: bytes,
    expected_thread: Optional[str],
    max_bytes: int,
) -> Mapping[str, Any]:
    if len(payload) > max_bytes:
        raise AdapterError("JSONL_OUTPUT_LIMIT_EXCEEDED", str(len(payload)))
    counts: Dict[str, int] = {}
    thread_ids = []
    terminal = None
    usage: Dict[str, int] = {}
    for line_number, raw_line in enumerate(payload.splitlines(), 1):
        if not raw_line.strip():
            continue
        try:
            event = json.loads(raw_line)
        except json.JSONDecodeError as error:
            raise AdapterError("JSONL_MALFORMED", str(line_number)) from error
        if not isinstance(event, dict) or not isinstance(event.get("type"), str):
            raise AdapterError("JSONL_EVENT_INVALID", str(line_number))
        event_type = event["type"]
        counts[event_type] = counts.get(event_type, 0) + 1
        if event_type == "thread.started":
            thread_id = event.get("thread_id")
            if not isinstance(thread_id, str) or THREAD_ID.fullmatch(thread_id) is None:
                raise AdapterError("THREAD_ID_INVALID", str(line_number))
            thread_ids.append(thread_id)
        elif event_type in {"error", "turn.failed"}:
            raise AdapterError(
                "CODEX_ERROR_EVENT" if event_type == "error" else "TURN_FAILED",
                event_type,
            )
        elif event_type == "turn.completed":
            if terminal is not None:
                raise AdapterError("MULTIPLE_TERMINAL_EVENTS", event_type)
            terminal = event_type
            raw_usage = event.get("usage", {})
            if isinstance(raw_usage, dict):
                usage = {
                    key: value
                    for key, value in raw_usage.items()
                    if isinstance(key, str)
                    and isinstance(value, int)
                    and not isinstance(value, bool)
                }
        elif event_type.startswith("turn.") and event_type != "turn.started":
            raise AdapterError("UNKNOWN_TERMINAL_EVENT", event_type)
    if len(thread_ids) != 1:
        raise AdapterError("THREAD_EVENT_COUNT_INVALID", str(len(thread_ids)))
    thread_id = thread_ids[0]
    if expected_thread is not None and thread_id != expected_thread:
        raise AdapterError("THREAD_ID_DRIFT", thread_id)
    if counts.get("turn.started") != 1:
        raise AdapterError(
            "TURN_STARTED_COUNT_INVALID", str(counts.get("turn.started", 0))
        )
    if terminal != "turn.completed":
        raise AdapterError("TURN_COMPLETION_MISSING", str(terminal))
    return {
        "thread_id": thread_id,
        "event_counts": dict(sorted(counts.items())),
        "usage": dict(sorted(usage.items())),
        "jsonl_sha256": _sha256(payload),
    }


def run_adapter(
    *,
    executable: str,
    codex_home: Path,
    repo: Path,
    context_path: Path,
    work_item_id: str,
    sandbox_mode: str = "workspace-write",
    max_jsonl_bytes: int = 10 * 1024 * 1024,
    environment: Optional[Mapping[str, str]] = None,
) -> Mapping[str, Any]:
    source_environment = dict(os.environ if environment is None else environment)
    if sandbox_mode not in SAFE_SANDBOX_MODES:
        raise AdapterError("SANDBOX_MODE_UNSAFE", sandbox_mode)
    diagnostic = doctor(executable, source_environment)
    if diagnostic["status"] != "available":
        raise AdapterError(str(diagnostic["reason_code"]), str(diagnostic.get("detail")))
    executable_path = Path(str(diagnostic["executable"]))
    if not codex_home.is_absolute():
        raise AdapterError("CODEX_HOME_NOT_ABSOLUTE", str(codex_home))
    if codex_home.is_symlink() or not codex_home.is_dir():
        raise AdapterError("CODEX_HOME_INVALID", str(codex_home))
    repo = repo.resolve()
    if not repo.is_dir():
        raise AdapterError("REPO_INVALID", str(repo))
    git_environment = {
        key: source_environment[key]
        for key in SAFE_ENVIRONMENT
        if key in source_environment
    }
    _, repo_sha256 = _git_binding(repo, git_environment)
    context = _load_context(context_path, work_item_id, source_environment)
    work_item_sha256 = str(context["work_item_sha256"])
    session_root = repo / ".harness-runtime" / "codex-sessions"
    session_path = session_root / f"{work_item_id}.json"
    prior = _session(
        session_path,
        work_item_id,
        work_item_sha256,
        repo_sha256,
    )
    if prior is None:
        argv = list(
            _codex_argv(
                executable_path,
                repo,
                sandbox_mode=sandbox_mode,
                thread_id=None,
            )
        )
        expected_thread = None
        invocation = "new"
    else:
        expected_thread = str(prior["thread_id"])
        argv = list(
            _codex_argv(
                executable_path,
                repo,
                sandbox_mode=sandbox_mode,
                thread_id=expected_thread,
            )
        )
        invocation = "resume"
    forbidden = {"--yolo", "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "danger-full-access"}
    if any(value in forbidden for value in argv):
        raise AdapterError("UNSAFE_CODEX_ARGUMENT", work_item_id)
    child_environment = {
        key: source_environment[key]
        for key in SAFE_ENVIRONMENT
        if key in source_environment
    }
    child_environment.update(
        {
            "CODEX_HOME": str(codex_home),
            "LEGADO_WORK_ITEM_ID": work_item_id,
            "LEGADO_CONTEXT_PATH": str(context_path),
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
        }
    )
    try:
        process = subprocess.Popen(
            argv,
            cwd=repo,
            env=child_environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout, stderr = process.communicate(
            input=_prompt(work_item_id, context_path).encode("utf-8")
        )
    except OSError as error:
        raise AdapterError("CODEX_SPAWN_FAILED", type(error).__name__) from error
    try:
        parsed = _parse_jsonl(stdout, expected_thread, max_jsonl_bytes)
    except AdapterError as error:
        if error.reason_code in {"CODEX_ERROR_EVENT", "TURN_FAILED"}:
            raise
        if process.returncode != 0:
            raise AdapterError("CODEX_EXIT_NONZERO", str(process.returncode)) from error
        raise
    if process.returncode != 0:
        raise AdapterError("CODEX_EXIT_NONZERO", str(process.returncode))
    session_value = {
        "schema_version": SCHEMA_VERSION,
        "adapter_version": ADAPTER_VERSION,
        "work_item_id": work_item_id,
        "work_item_sha256": work_item_sha256,
        "repo_sha256": repo_sha256,
        "thread_id": parsed["thread_id"],
        "last_completed_event_sha256": parsed["jsonl_sha256"],
    }
    _atomic_json(session_path, session_value)
    return {
        "schema_version": SCHEMA_VERSION,
        "adapter_version": ADAPTER_VERSION,
        "outcome": "completed_turn",
        "reason_code": "CODEX_TURN_COMPLETED",
        "invocation": invocation,
        "thread_id": parsed["thread_id"],
        "event_counts": parsed["event_counts"],
        "usage": parsed["usage"],
        "jsonl_sha256": parsed["jsonl_sha256"],
        "stderr_sha256": _sha256(stderr),
        "stderr_bytes": len(stderr),
    }


def _smoke_git(repo: Path, environment: Mapping[str, str], *arguments: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=repo,
            env=dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AdapterError("SMOKE_GIT_FAILED", type(error).__name__) from error
    if result.returncode != 0:
        raise AdapterError("SMOKE_GIT_EXIT_NONZERO", str(result.returncode))
    return result.stdout


def _smoke_turn(
    argv: Sequence[str],
    prompt: str,
    environment: Mapping[str, str],
    expected_thread: Optional[str],
    max_jsonl_bytes: int,
) -> Mapping[str, Any]:
    try:
        result = subprocess.run(
            list(argv),
            env=dict(environment),
            input=prompt.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=300,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise AdapterError("SMOKE_TURN_TIMEOUT", "300") from error
    except OSError as error:
        raise AdapterError("SMOKE_TURN_SPAWN_FAILED", type(error).__name__) from error
    try:
        parsed = _parse_jsonl(result.stdout, expected_thread, max_jsonl_bytes)
    except AdapterError as error:
        if result.returncode != 0 and error.reason_code not in {
            "CODEX_ERROR_EVENT",
            "TURN_FAILED",
        }:
            raise AdapterError(
                "SMOKE_CODEX_EXIT_NONZERO",
                str(result.returncode),
            ) from error
        raise
    if result.returncode != 0:
        raise AdapterError("SMOKE_CODEX_EXIT_NONZERO", str(result.returncode))
    return {
        **parsed,
        "stderr_sha256": _sha256(result.stderr),
        "stderr_bytes": len(result.stderr),
    }


def real_smoke(
    *,
    executable: str,
    codex_home: Path,
    max_jsonl_bytes: int = 10 * 1024 * 1024,
    environment: Optional[Mapping[str, str]] = None,
) -> Mapping[str, Any]:
    source_environment = dict(os.environ if environment is None else environment)
    diagnostic = doctor(executable, source_environment)
    if diagnostic["status"] != "available":
        raise AdapterError(
            str(diagnostic["reason_code"]),
            str(diagnostic.get("detail")),
        )
    executable_path = Path(str(diagnostic["executable"]))
    if not codex_home.is_absolute():
        raise AdapterError("CODEX_HOME_NOT_ABSOLUTE", str(codex_home))
    if codex_home.is_symlink() or not codex_home.is_dir():
        raise AdapterError("CODEX_HOME_INVALID", str(codex_home))
    child_environment = {
        key: source_environment[key]
        for key in SAFE_ENVIRONMENT
        if key in source_environment
    }
    child_environment.update(
        {
            "CODEX_HOME": str(codex_home),
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
        }
    )
    with tempfile.TemporaryDirectory(prefix="legado-codex-smoke-") as directory:
        repo = Path(directory).resolve()
        _smoke_git(repo, child_environment, "init", "-q")
        _smoke_git(repo, child_environment, "config", "user.name", "Codex Smoke")
        _smoke_git(
            repo,
            child_environment,
            "config",
            "user.email",
            "codex-smoke@example.invalid",
        )
        marker = repo / "README.md"
        marker.write_text("Legado Codex adapter read-only smoke\n", encoding="utf-8")
        _smoke_git(repo, child_environment, "add", "README.md")
        _smoke_git(repo, child_environment, "commit", "-qm", "smoke baseline")
        first = _smoke_turn(
            _codex_argv(
                executable_path,
                repo,
                sandbox_mode="read-only",
                thread_id=None,
            ),
            (
                "This is a read-only adapter integration smoke. Do not run commands "
                "and do not modify files. Reply with exactly CODEX_ADAPTER_SMOKE_FIRST."
            ),
            child_environment,
            None,
            max_jsonl_bytes,
        )
        thread_id = str(first["thread_id"])
        resumed = _smoke_turn(
            _codex_argv(
                executable_path,
                repo,
                sandbox_mode="read-only",
                thread_id=thread_id,
            ),
            (
                "Continue the read-only integration smoke. Do not run commands and "
                "do not modify files. Reply with exactly CODEX_ADAPTER_SMOKE_RESUME."
            ),
            child_environment,
            thread_id,
            max_jsonl_bytes,
        )
        status = _smoke_git(
            repo,
            child_environment,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        )
        if status:
            raise AdapterError("SMOKE_REPO_MUTATED", _sha256(status))
    return {
        "schema_version": SCHEMA_VERSION,
        "adapter_version": ADAPTER_VERSION,
        "outcome": "real_smoke_passed",
        "reason_code": "CODEX_FIRST_RESUME_READ_ONLY_VERIFIED",
        "executable": diagnostic["executable"],
        "version": diagnostic["version"],
        "version_sha256": diagnostic["version_sha256"],
        "thread_id": thread_id,
        "first": {
            "event_counts": first["event_counts"],
            "usage": first["usage"],
            "jsonl_sha256": first["jsonl_sha256"],
            "stderr_sha256": first["stderr_sha256"],
            "stderr_bytes": first["stderr_bytes"],
        },
        "resume": {
            "event_counts": resumed["event_counts"],
            "usage": resumed["usage"],
            "jsonl_sha256": resumed["jsonl_sha256"],
            "stderr_sha256": resumed["stderr_sha256"],
            "stderr_bytes": resumed["stderr_bytes"],
        },
        "repo_clean": True,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Codex exec adapter for Loop Supervisor")
    subparsers = parser.add_subparsers(dest="command", required=True)
    doctor_parser = subparsers.add_parser("doctor", help="Diagnose one Codex executable")
    doctor_parser.add_argument("--codex", default="codex")
    run_parser = subparsers.add_parser("run", help="Run or resume one bound Harness turn")
    run_parser.add_argument("--codex", required=True)
    run_parser.add_argument("--codex-home", type=Path, required=True)
    run_parser.add_argument("--repo", type=Path, required=True)
    run_parser.add_argument("--context", type=Path, required=True)
    run_parser.add_argument("--work-item", required=True)
    run_parser.add_argument(
        "--sandbox-mode",
        choices=sorted(SAFE_SANDBOX_MODES),
        default="workspace-write",
    )
    run_parser.add_argument("--max-jsonl-bytes", type=int, default=10 * 1024 * 1024)
    smoke_parser = subparsers.add_parser(
        "smoke",
        help="Run a read-only real first-turn/resume compatibility smoke",
    )
    smoke_parser.add_argument("--codex", required=True)
    smoke_parser.add_argument("--codex-home", type=Path, required=True)
    smoke_parser.add_argument(
        "--max-jsonl-bytes",
        type=int,
        default=10 * 1024 * 1024,
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "doctor":
            result = doctor(args.codex)
            exit_code = 0 if result["status"] == "available" else 2
        elif args.command == "run":
            if not 1024 <= args.max_jsonl_bytes <= 100 * 1024 * 1024:
                raise AdapterError("JSONL_LIMIT_INVALID", str(args.max_jsonl_bytes))
            result = run_adapter(
                executable=args.codex,
                codex_home=args.codex_home,
                repo=args.repo,
                context_path=args.context,
                work_item_id=args.work_item,
                sandbox_mode=args.sandbox_mode,
                max_jsonl_bytes=args.max_jsonl_bytes,
            )
            exit_code = 0
        else:
            if not 1024 <= args.max_jsonl_bytes <= 100 * 1024 * 1024:
                raise AdapterError("JSONL_LIMIT_INVALID", str(args.max_jsonl_bytes))
            result = real_smoke(
                executable=args.codex,
                codex_home=args.codex_home,
                max_jsonl_bytes=args.max_jsonl_bytes,
            )
            exit_code = 0
    except AdapterError as error:
        result = {
            "schema_version": SCHEMA_VERSION,
            "adapter_version": ADAPTER_VERSION,
            "outcome": "failed",
            "reason_code": error.reason_code,
            "detail_sha256": _sha256(str(error).encode("utf-8")),
        }
        exit_code = 2
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
