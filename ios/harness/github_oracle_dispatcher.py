#!/usr/bin/env python3
"""Restricted, recoverable GitHub Actions dispatcher for Android Oracle runs."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlparse

WORKFLOW_PATH = ".github/workflows/android-oracle-attestation.yml"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SCENARIO = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
REMOTE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
STATUS_ORDER = {"queued": 0, "in_progress": 1, "completed": 2}
RUN_FIELDS = {
    "databaseId", "attempt", "status", "conclusion", "url",
    "headSha", "headBranch", "event",
}

class GitHubOracleError(RuntimeError):
    pass

@dataclass(frozen=True)
class ExecutionIdentity:
    repository: str
    workflow_path: str
    scenario: str
    source_digest: str
    remote: str
    execution_id: str
    branch: str

    def binding(self) -> dict[str, str]:
        return dict(repository=self.repository, workflow_path=self.workflow_path,
                    scenario=self.scenario, source_digest=self.source_digest,
                    remote=self.remote, execution_id=self.execution_id,
                    branch=self.branch)

def execution_identity(*, repository: str, workflow_path: str, scenario: str,
                       source_digest: str, remote: str) -> ExecutionIdentity:
    if not isinstance(repository, str) or not REPOSITORY.fullmatch(repository):
        raise GitHubOracleError("EXTERNAL_EXECUTION_REPOSITORY_INVALID")
    if workflow_path != WORKFLOW_PATH:
        raise GitHubOracleError("EXTERNAL_EXECUTION_WORKFLOW_INVALID")
    if not isinstance(scenario, str) or not SCENARIO.fullmatch(scenario):
        raise GitHubOracleError("EXTERNAL_EXECUTION_SCENARIO_INVALID")
    if not isinstance(source_digest, str) or not HEX40.fullmatch(source_digest):
        raise GitHubOracleError("EXTERNAL_EXECUTION_SOURCE_DIGEST_INVALID")
    if not isinstance(remote, str) or not REMOTE.fullmatch(remote):
        raise GitHubOracleError("EXTERNAL_EXECUTION_REMOTE_INVALID")
    canonical = dict(remote=remote, repository=repository.lower(),
                     scenario=scenario, source_digest=source_digest,
                     workflow_path=workflow_path)
    execution_id = hashlib.sha256(json.dumps(
        canonical, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return ExecutionIdentity(repository.lower(), workflow_path, scenario,
                             source_digest, remote, execution_id,
                             f"feature/oracle-{scenario}-{source_digest}")

Runner = Callable[[Sequence[str]], subprocess.CompletedProcess[str]]

class GitHubOracleDispatcher:
    def __init__(self, root: Path, *, repository: str, workflow_path: str,
                 scenario: str, source_digest: str, remote: str,
                 runner: Runner | None = None,
                 now: Callable[[], dt.datetime] | None = None):
        self.root = root.resolve()
        self.identity = execution_identity(
            repository=repository, workflow_path=workflow_path, scenario=scenario,
            source_digest=source_digest, remote=remote)
        self.runner = runner or self._run
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.journal_path = self.root / ".harness-runtime/github-oracle" / (
            self.identity.execution_id + ".json")

    def _run(self, argv: Sequence[str]) -> subprocess.CompletedProcess[str]:
        return subprocess.run(list(argv), cwd=self.root, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              check=False)

    def _command(self, argv: Sequence[str], error: str) -> str:
        result = self.runner(tuple(argv))
        if result.returncode:
            raise GitHubOracleError(error)
        return result.stdout.strip()

    @staticmethod
    def _remote_repository(url: str) -> str | None:
        value = url.strip()
        match = re.fullmatch(r"git@[^:]+:([^/]+/[^/]+?)(?:\.git)?", value)
        if match:
            return match.group(1).lower()
        parsed = urlparse(value)
        if parsed.scheme not in {"https", "ssh"} or not parsed.hostname:
            return None
        path = parsed.path.lstrip("/")
        path = path[:-4] if path.endswith(".git") else path
        return path.lower() if REPOSITORY.fullmatch(path) else None

    def _preflight(self) -> None:
        status = self._command(
            ["git", "status", "--porcelain=v1", "--untracked-files=all", "--",
             ".", ":(exclude).harness-runtime/**"], "GIT_STATUS_FAILED")
        if status:
            raise GitHubOracleError("GIT_WORKTREE_DIRTY")
        if self._command(["git", "rev-parse", "HEAD"], "GIT_HEAD_REQUIRED") != \
                self.identity.source_digest:
            raise GitHubOracleError("EXTERNAL_EXECUTION_HEAD_MISMATCH")
        remote_url = self._command(
            ["git", "remote", "get-url", self.identity.remote],
            "EXTERNAL_EXECUTION_REMOTE_REQUIRED")
        if self._remote_repository(remote_url) != self.identity.repository:
            raise GitHubOracleError("EXTERNAL_EXECUTION_REMOTE_REPOSITORY_MISMATCH")
        self._command(["gh", "auth", "status", "--hostname", "github.com"],
                      "GITHUB_AUTH_REQUIRED")

    def _ensure_branch(self) -> bool:
        ref = "refs/heads/" + self.identity.branch
        output = self._command(
            ["git", "ls-remote", "--heads", self.identity.remote, ref],
            "REMOTE_BRANCH_LOOKUP_FAILED")
        if not output:
            self._command(["git", "push", self.identity.remote,
                           f"{self.identity.source_digest}:{ref}"],
                          "REMOTE_BRANCH_CREATE_FAILED")
            return True
        elif len(output.splitlines()) != 1 or output.split() != \
                [self.identity.source_digest, ref]:
            raise GitHubOracleError("REMOTE_BRANCH_CONFLICT")
        return False

    def _runs(self) -> list[Mapping[str, Any]]:
        raw = self._command([
            "gh", "run", "list", "--repo", self.identity.repository,
            "--workflow", self.identity.workflow_path, "--branch",
            self.identity.branch, "--event", "push", "--limit", "2",
            "--json",
            "databaseId,attempt,status,conclusion,url,headSha,headBranch,event",
        ], "GITHUB_RUN_LOOKUP_FAILED")
        try:
            runs = json.loads(raw)
        except json.JSONDecodeError as error:
            raise GitHubOracleError("GITHUB_RUN_RESPONSE_INVALID") from error
        if not isinstance(runs, list) or any(
                not isinstance(x, dict) or set(x) != RUN_FIELDS for x in runs):
            raise GitHubOracleError("GITHUB_RUN_RESPONSE_INVALID")
        if len(runs) > 1:
            raise GitHubOracleError("DUPLICATE_REMOTE_RUN")
        if runs:
            run = runs[0]
            if (run["headSha"] != self.identity.source_digest or
                    run["headBranch"] != self.identity.branch or
                    run["event"] != "push"):
                raise GitHubOracleError("GITHUB_RUN_BINDING_DRIFT")
            if (
                isinstance(run["databaseId"], bool)
                or not isinstance(run["databaseId"], int)
                or run["databaseId"] < 1
                or isinstance(run["attempt"], bool)
                or not isinstance(run["attempt"], int)
                or run["attempt"] < 1
                or run["status"] not in STATUS_ORDER
                or not isinstance(run["conclusion"], str)
                or not isinstance(run["url"], str)
                or not run["url"]
                or not isinstance(run["headSha"], str)
                or not isinstance(run["headBranch"], str)
                or not isinstance(run["event"], str)
                or (run["status"] == "completed" and not run["conclusion"])
                or (run["status"] != "completed" and run["conclusion"])
            ):
                raise GitHubOracleError("GITHUB_RUN_RESPONSE_INVALID")
        return runs

    def _read_journal(self) -> Mapping[str, Any] | None:
        if not self.journal_path.exists():
            return None
        try:
            value = json.loads(self.journal_path.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_INVALID") from error
        if not isinstance(value, dict):
            raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_INVALID")
        if value.get("binding") != self.identity.binding():
            raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_IDENTITY_MISMATCH")
        if (
            set(value) != {
                "schema_version", "binding", "outcome", "run",
                "created_at", "updated_at",
            }
            or value["schema_version"] != 1
            or value["outcome"] not in {
                "dispatched", "pending", "running", "succeeded", "failed",
            }
            or not isinstance(value["created_at"], str)
            or not isinstance(value["updated_at"], str)
        ):
            raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_INVALID")
        run = value["run"]
        if run is not None and (
            not isinstance(run, dict)
            or set(run) != {"id", "attempt", "status", "conclusion", "url"}
            or isinstance(run["id"], bool)
            or not isinstance(run["id"], int)
            or run["id"] < 1
            or isinstance(run["attempt"], bool)
            or not isinstance(run["attempt"], int)
            or run["attempt"] < 1
            or run["status"] not in STATUS_ORDER
            or not isinstance(run["conclusion"], str)
            or not isinstance(run["url"], str)
            or not run["url"]
            or (run["status"] == "completed" and not run["conclusion"])
            or (run["status"] != "completed" and run["conclusion"])
        ):
            raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_INVALID")
        expected_outcome = (
            "dispatched" if run is None and value["outcome"] == "dispatched"
            else "pending" if run is None
            else self._outcome(run)
        )
        if value["outcome"] != expected_outcome:
            raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_INVALID")
        return value

    def _write_journal(self, run: Mapping[str, Any] | None,
                       outcome: str) -> dict[str, Any]:
        previous = self._read_journal()
        current = None if run is None else {
            "id": run.get("databaseId"), "attempt": run.get("attempt"),
            "status": run.get("status"), "conclusion": run.get("conclusion"),
            "url": run.get("url")}
        if previous and previous.get("run") is not None:
            old = previous["run"]
            if current is None or old.get("id") != current.get("id"):
                raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_RUN_REGRESSION")
            if current["attempt"] < old.get("attempt", 0):
                raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_RUN_REGRESSION")
            if STATUS_ORDER.get(current.get("status"), -1) < \
                    STATUS_ORDER.get(old.get("status"), -1):
                raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_RUN_REGRESSION")
            if old.get("status") == "completed" and old != current:
                raise GitHubOracleError("GITHUB_ORACLE_JOURNAL_TERMINAL_REWRITE")
        stamp = self.now().isoformat().replace("+00:00", "Z")
        record = {"schema_version": 1, "binding": self.identity.binding(),
                  "outcome": outcome, "run": current,
                  "created_at": previous.get("created_at", stamp) if previous else stamp,
                  "updated_at": stamp}
        self.journal_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, name = tempfile.mkstemp(dir=self.journal_path.parent,
                                            prefix="." + self.journal_path.name)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "w") as handle:
                json.dump(record, handle, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.journal_path)
        finally:
            temporary.unlink(missing_ok=True)
        return record

    @staticmethod
    def _outcome(run: Mapping[str, Any]) -> str:
        if run.get("status") == "completed":
            return "succeeded" if run.get("conclusion") == "success" else "failed"
        return "running" if run.get("status") == "in_progress" else "pending"

    def dispatch(self) -> dict[str, Any]:
        self._preflight()
        created = self._ensure_branch()
        runs = self._runs()
        if not runs:
            outcome = "dispatched" if created else "pending"
            record = self._write_journal(None, outcome)
        else:
            outcome = self._outcome(runs[0])
            record = self._write_journal(runs[0], outcome)
        return {"schema_version": 1, "outcome": outcome,
                "execution_id": self.identity.execution_id,
                "branch": self.identity.branch,
                "journal": str(self.journal_path.relative_to(self.root)),
                "run": record["run"]}
