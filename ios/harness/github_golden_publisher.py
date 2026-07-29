#!/usr/bin/env python3
"""Recoverable GitHub dispatcher and verifier for Android Golden publication."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlparse


WORKFLOW_PATH = ".github/workflows/android-golden-publisher.yml"
ORACLE_WORKFLOW_PATH = ".github/workflows/android-oracle-attestation.yml"
PROFILE = "android-legado-v1"
AUTHORIZATION = "github_actions_push_v2"
PUBLISHER = "github-actions:android-golden-publisher-v2"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SCENARIO = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
REMOTE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
STATUS_ORDER = {"queued": 0, "in_progress": 1, "completed": 2}
RUN_FIELDS = {
    "databaseId",
    "attempt",
    "status",
    "conclusion",
    "url",
    "headSha",
    "headBranch",
    "event",
}
RESULT_ARTIFACT_FILES = {"SHA256SUMS", "publisher-result.json"}
MAX_ARTIFACT_FILE_BYTES = 8 * 1024 * 1024


class GitHubGoldenPublisherError(RuntimeError):
    """Stable fail-closed error raised by the Golden dispatcher."""


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


@dataclass(frozen=True)
class GoldenExecutionIdentity:
    repository: str
    workflow_path: str
    scenario: str
    request_sha: str
    receipt_path: str
    receipt_sha256: str
    remote: str
    execution_id: str
    request_branch: str
    result_branch: str

    def binding(self) -> dict[str, str]:
        return {
            "repository": self.repository,
            "workflow_path": self.workflow_path,
            "scenario": self.scenario,
            "request_sha": self.request_sha,
            "receipt_path": self.receipt_path,
            "receipt_sha256": self.receipt_sha256,
            "remote": self.remote,
            "execution_id": self.execution_id,
            "request_branch": self.request_branch,
            "result_branch": self.result_branch,
        }


def _validated_receipt_path(value: str, scenario: str) -> str:
    if not isinstance(value, str) or not value:
        raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_PATH_INVALID")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
        or len(path.parts) != 4
        or path.parts[:3]
        != ("ios", "project", "external-execution-receipts")
        or not path.name.startswith(f"android-oracle-{scenario}-")
        or not path.name.endswith(".json")
    ):
        raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_PATH_INVALID")
    return value


def golden_execution_identity(
    *,
    repository: str,
    workflow_path: str,
    scenario: str,
    request_sha: str,
    receipt_path: str,
    receipt_sha256: str,
    remote: str,
) -> GoldenExecutionIdentity:
    if not isinstance(repository, str) or not REPOSITORY.fullmatch(repository):
        raise GitHubGoldenPublisherError("GOLDEN_REPOSITORY_INVALID")
    if workflow_path != WORKFLOW_PATH:
        raise GitHubGoldenPublisherError("GOLDEN_WORKFLOW_INVALID")
    if not isinstance(scenario, str) or not SCENARIO.fullmatch(scenario):
        raise GitHubGoldenPublisherError("GOLDEN_SCENARIO_INVALID")
    if not isinstance(request_sha, str) or not HEX40.fullmatch(request_sha):
        raise GitHubGoldenPublisherError("GOLDEN_REQUEST_SHA_INVALID")
    receipt_path = _validated_receipt_path(receipt_path, scenario)
    if (
        not isinstance(receipt_sha256, str)
        or not HEX64.fullmatch(receipt_sha256)
    ):
        raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_SHA256_INVALID")
    if not isinstance(remote, str) or not REMOTE.fullmatch(remote):
        raise GitHubGoldenPublisherError("GOLDEN_REMOTE_INVALID")
    canonical = {
        "remote": remote,
        "repository": repository.lower(),
        "request_sha": request_sha,
        "receipt_path": receipt_path,
        "receipt_sha256": receipt_sha256,
        "scenario": scenario,
        "workflow_path": workflow_path,
    }
    execution_id = _sha256(_canonical(canonical)[:-1])
    return GoldenExecutionIdentity(
        repository=repository.lower(),
        workflow_path=workflow_path,
        scenario=scenario,
        request_sha=request_sha,
        receipt_path=receipt_path,
        receipt_sha256=receipt_sha256,
        remote=remote,
        execution_id=execution_id,
        request_branch=f"feature/golden-{scenario}-{request_sha}",
        result_branch=f"golden/result-{scenario}-{request_sha}",
    )


Runner = Callable[[Sequence[str], Path], subprocess.CompletedProcess[bytes]]


class GitHubGoldenPublisherDispatcher:
    """Dispatch one Golden publication and accept only its verified child commit."""

    def __init__(
        self,
        root: Path,
        *,
        repository: str,
        workflow_path: str,
        scenario: str,
        request_sha: str,
        receipt_path: str,
        receipt_sha256: str,
        remote: str,
        runner: Runner | None = None,
        now: Callable[[], dt.datetime] | None = None,
        max_file_bytes: int = MAX_ARTIFACT_FILE_BYTES,
    ):
        try:
            self.root = root.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise GitHubGoldenPublisherError("GOLDEN_ROOT_INVALID") from error
        self.identity = golden_execution_identity(
            repository=repository,
            workflow_path=workflow_path,
            scenario=scenario,
            request_sha=request_sha,
            receipt_path=receipt_path,
            receipt_sha256=receipt_sha256,
            remote=remote,
        )
        self.runner = runner or self._run
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.max_file_bytes = max_file_bytes
        self.journal_path = (
            self.root
            / ".harness-runtime"
            / "github-golden"
            / f"{self.identity.execution_id}.json"
        )
        self._receipt: Mapping[str, Any] | None = None

    @staticmethod
    def _run(
        argv: Sequence[str], cwd: Path
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=120,
            check=False,
        )

    def _command(
        self,
        argv: Sequence[str],
        reason: str,
        *,
        cwd: Path | None = None,
        max_output: int = 16 * 1024 * 1024,
    ) -> bytes:
        try:
            result = self.runner(tuple(argv), cwd or self.root)
        except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
            raise GitHubGoldenPublisherError(reason) from error
        stdout = result.stdout or b""
        if isinstance(stdout, str):
            try:
                stdout = stdout.encode("utf-8")
            except UnicodeError as error:
                raise GitHubGoldenPublisherError(reason) from error
        if result.returncode != 0 or len(stdout) > max_output:
            raise GitHubGoldenPublisherError(reason)
        return stdout

    def _text(
        self,
        argv: Sequence[str],
        reason: str,
        *,
        cwd: Path | None = None,
    ) -> str:
        try:
            return self._command(argv, reason, cwd=cwd).decode("utf-8").strip()
        except UnicodeDecodeError as error:
            raise GitHubGoldenPublisherError(reason) from error

    def _json(self, argv: Sequence[str], reason: str) -> Any:
        try:
            return json.loads(self._command(argv, reason))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubGoldenPublisherError(reason) from error

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

    def _clean_head(self) -> None:
        self._clean_worktree()
        head = self._text(
            ["git", "rev-parse", "HEAD"], "GOLDEN_GIT_HEAD_REQUIRED"
        )
        if head != self.identity.request_sha:
            raise GitHubGoldenPublisherError("GOLDEN_REQUEST_HEAD_MISMATCH")

    def _clean_worktree(self) -> None:
        status = self._text(
            [
                "git",
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude).harness-runtime/**",
            ],
            "GOLDEN_GIT_STATUS_FAILED",
        )
        if status:
            raise GitHubGoldenPublisherError("GOLDEN_GIT_WORKTREE_DIRTY")

    def _load_receipt(self) -> Mapping[str, Any]:
        relative = self.identity.receipt_path
        candidate = self.root / relative
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(self.root)
        except (OSError, RuntimeError, ValueError) as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RECEIPT_REGULAR_FILE_REQUIRED"
            ) from error
        if candidate.is_symlink() or not resolved.is_file():
            raise GitHubGoldenPublisherError(
                "GOLDEN_RECEIPT_REGULAR_FILE_REQUIRED"
            )
        try:
            payload = candidate.read_bytes()
        except OSError as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RECEIPT_REGULAR_FILE_REQUIRED"
            ) from error
        if _sha256(payload) != self.identity.receipt_sha256:
            raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_DIGEST_MISMATCH")
        self._command(
            [
                "git",
                "ls-files",
                "--error-unmatch",
                "--",
                relative,
            ],
            "GOLDEN_RECEIPT_NOT_TRACKED",
        )
        committed = self._command(
            ["git", "show", f"{self.identity.request_sha}:{relative}"],
            "GOLDEN_RECEIPT_NOT_COMMITTED",
        )
        if committed != payload:
            raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_COMMIT_DRIFT")
        try:
            value = json.loads(payload)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_INVALID") from error
        if not isinstance(value, dict):
            raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_INVALID")
        if _canonical(value) != payload:
            raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_INVALID")
        run = value.get("run")
        trusted = value.get("trusted_report")
        if (
            value.get("schema_version") != 1
            or value.get("authority") != "verified_candidate"
            or value.get("next_authority") != "independent_golden_publisher"
            or value.get("repository", "").lower()
            != self.identity.repository
            or value.get("workflow_path") != ORACLE_WORKFLOW_PATH
            or value.get("scenario_id") != self.identity.scenario
            or not isinstance(value.get("source_digest"), str)
            or not HEX40.fullmatch(value["source_digest"])
            or not isinstance(run, dict)
            or isinstance(run.get("id"), bool)
            or not isinstance(run.get("id"), int)
            or run["id"] < 1
            or isinstance(run.get("attempt"), bool)
            or not isinstance(run.get("attempt"), int)
            or run["attempt"] < 1
            or run.get("event") != "push"
            or not isinstance(trusted, dict)
            or trusted.get("scenario_id") != self.identity.scenario
            or trusted.get("source_digest") != value["source_digest"]
            or trusted.get("next_authority")
            != "independent_golden_publisher"
            or not isinstance(trusted.get("proposal_sha256"), str)
            or not HEX64.fullmatch(trusted["proposal_sha256"])
        ):
            raise GitHubGoldenPublisherError("GOLDEN_RECEIPT_INVALID")
        self._receipt = value
        return value

    def _preflight(self) -> Mapping[str, Any]:
        self._clean_head()
        remote_url = self._text(
            ["git", "remote", "get-url", self.identity.remote],
            "GOLDEN_REMOTE_REQUIRED",
        )
        if self._remote_repository(remote_url) != self.identity.repository:
            raise GitHubGoldenPublisherError(
                "GOLDEN_REMOTE_REPOSITORY_MISMATCH"
            )
        self._command(
            ["gh", "auth", "status", "--hostname", "github.com"],
            "GOLDEN_GITHUB_AUTH_REQUIRED",
        )
        return self._load_receipt()

    def _remote_ref(self, branch: str, reason: str) -> str | None:
        ref = f"refs/heads/{branch}"
        output = self._text(
            [
                "git",
                "ls-remote",
                "--heads",
                self.identity.remote,
                ref,
            ],
            reason,
        )
        if not output:
            return None
        fields = output.split()
        if len(fields) != 2 or fields[1] != ref or not HEX40.fullmatch(fields[0]):
            raise GitHubGoldenPublisherError(reason)
        return fields[0]

    def _ensure_request_branch(self) -> bool:
        existing = self._remote_ref(
            self.identity.request_branch,
            "GOLDEN_REQUEST_BRANCH_LOOKUP_FAILED",
        )
        if existing is None:
            self._command(
                [
                    "git",
                    "push",
                    self.identity.remote,
                    (
                        f"{self.identity.request_sha}:"
                        f"refs/heads/{self.identity.request_branch}"
                    ),
                ],
                "GOLDEN_REQUEST_BRANCH_CREATE_FAILED",
            )
            if (
                self._remote_ref(
                    self.identity.request_branch,
                    "GOLDEN_REQUEST_BRANCH_RECHECK_FAILED",
                )
                != self.identity.request_sha
            ):
                raise GitHubGoldenPublisherError(
                    "GOLDEN_REQUEST_BRANCH_RECHECK_FAILED"
                )
            return True
        if existing != self.identity.request_sha:
            raise GitHubGoldenPublisherError(
                "GOLDEN_REQUEST_BRANCH_CONFLICT"
            )
        return False

    def _runs(self) -> list[Mapping[str, Any]]:
        value = self._json(
            [
                "gh",
                "run",
                "list",
                "--repo",
                self.identity.repository,
                "--workflow",
                self.identity.workflow_path,
                "--branch",
                self.identity.request_branch,
                "--event",
                "push",
                "--limit",
                "2",
                "--json",
                (
                    "databaseId,attempt,status,conclusion,url,"
                    "headSha,headBranch,event"
                ),
            ],
            "GOLDEN_RUN_LOOKUP_FAILED",
        )
        if (
            not isinstance(value, list)
            or any(not isinstance(run, dict) or set(run) != RUN_FIELDS for run in value)
        ):
            raise GitHubGoldenPublisherError("GOLDEN_RUN_RESPONSE_INVALID")
        if len(value) > 1:
            raise GitHubGoldenPublisherError("GOLDEN_DUPLICATE_RUN")
        if not value:
            return []
        run = value[0]
        if (
            run.get("headSha") != self.identity.request_sha
            or run.get("headBranch") != self.identity.request_branch
            or run.get("event") != "push"
        ):
            raise GitHubGoldenPublisherError("GOLDEN_RUN_BINDING_DRIFT")
        if (
            isinstance(run.get("databaseId"), bool)
            or not isinstance(run.get("databaseId"), int)
            or run["databaseId"] < 1
            or isinstance(run.get("attempt"), bool)
            or not isinstance(run.get("attempt"), int)
            or run["attempt"] < 1
            or run.get("status") not in STATUS_ORDER
            or not isinstance(run.get("conclusion"), str)
            or not isinstance(run.get("url"), str)
            or not run["url"]
            or (
                run["status"] == "completed"
                and not run["conclusion"]
            )
            or (
                run["status"] != "completed"
                and run["conclusion"]
            )
        ):
            raise GitHubGoldenPublisherError("GOLDEN_RUN_RESPONSE_INVALID")
        return value

    def _verify_run_api(self, run: Mapping[str, Any]) -> None:
        value = self._json(
            [
                "gh",
                "api",
                (
                    f"repos/{self.identity.repository}/actions/runs/"
                    f"{run['databaseId']}"
                ),
            ],
            "GOLDEN_RUN_PROVENANCE_INVALID",
        )
        if (
            not isinstance(value, dict)
            or value.get("id") != run["databaseId"]
            or value.get("run_attempt") != run["attempt"]
            or value.get("path") != self.identity.workflow_path
            or value.get("event") != "push"
            or value.get("status") != "completed"
            or value.get("conclusion") != "success"
            or value.get("head_sha") != self.identity.request_sha
            or value.get("head_branch") != self.identity.request_branch
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RUN_PROVENANCE_INVALID"
            )

    def _artifact(self, run: Mapping[str, Any]) -> Mapping[str, Any]:
        artifact_name = (
            f"android-golden-result-{self.identity.scenario}-"
            f"{run['databaseId']}-{run['attempt']}"
        )
        value = self._json(
            [
                "gh",
                "api",
                "--method",
                "GET",
                (
                    f"repos/{self.identity.repository}/actions/runs/"
                    f"{run['databaseId']}/artifacts"
                ),
                "-f",
                "per_page=100",
            ],
            "GOLDEN_ARTIFACT_LOOKUP_FAILED",
        )
        if not isinstance(value, dict) or not isinstance(
            value.get("artifacts"), list
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_ARTIFACT_RESPONSE_INVALID"
            )
        matches = [
            item
            for item in value["artifacts"]
            if isinstance(item, dict) and item.get("name") == artifact_name
        ]
        if len(matches) != 1:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_ARTIFACT_NOT_UNIQUE"
            )
        artifact = matches[0]
        workflow_run = artifact.get("workflow_run")
        if (
            isinstance(artifact.get("id"), bool)
            or not isinstance(artifact.get("id"), int)
            or artifact["id"] < 1
            or artifact.get("expired") is not False
            or not isinstance(workflow_run, dict)
            or workflow_run.get("id") != run["databaseId"]
            or workflow_run.get("head_sha") != self.identity.request_sha
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_ARTIFACT_INVALID"
            )
        return artifact

    def _download_report(
        self, directory: Path, run: Mapping[str, Any], artifact: Mapping[str, Any]
    ) -> Mapping[str, Any]:
        try:
            if not directory.is_dir() or any(directory.iterdir()):
                raise GitHubGoldenPublisherError(
                    "GOLDEN_RESULT_DOWNLOAD_DIRECTORY_INVALID"
                )
            os.chmod(directory, 0o700)
        except OSError as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_DOWNLOAD_DIRECTORY_INVALID"
            ) from error
        self._command(
            [
                "gh",
                "run",
                "download",
                str(run["databaseId"]),
                "--repo",
                self.identity.repository,
                "--name",
                str(artifact["name"]),
                "--dir",
                str(directory),
            ],
            "GOLDEN_RESULT_DOWNLOAD_FAILED",
        )
        try:
            entries = list(directory.iterdir())
        except OSError as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_ARTIFACT_INVALID"
            ) from error
        if {path.name for path in entries} != RESULT_ARTIFACT_FILES:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_FILE_SET_INVALID"
            )
        payloads: dict[str, bytes] = {}
        for path in entries:
            try:
                if (
                    path.is_symlink()
                    or not path.is_file()
                    or path.stat().st_size > self.max_file_bytes
                ):
                    raise GitHubGoldenPublisherError(
                        "GOLDEN_RESULT_FILE_INVALID"
                    )
                payloads[path.name] = path.read_bytes()
            except OSError as error:
                raise GitHubGoldenPublisherError(
                    "GOLDEN_RESULT_FILE_INVALID"
                ) from error
        checksum = payloads["SHA256SUMS"]
        try:
            checksum_text = checksum.decode("ascii")
        except UnicodeDecodeError as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_CHECKSUM_INVALID"
            ) from error
        expected_line = (
            f"{_sha256(payloads['publisher-result.json'])}"
            "  publisher-result.json\n"
        )
        if checksum_text != expected_line:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_CHECKSUM_INVALID"
            )
        try:
            report = json.loads(payloads["publisher-result.json"])
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_REPORT_INVALID"
            ) from error
        if not isinstance(report, dict):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_REPORT_INVALID"
            )
        if _canonical(report) != payloads["publisher-result.json"]:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_REPORT_INVALID"
            )
        return report

    def _expected_paths(
        self, receipt: Mapping[str, Any]
    ) -> tuple[str, str, str]:
        run = receipt["run"]
        golden = (
            f"ios/harness/goldens/{PROFILE}/{self.identity.scenario}.json"
        )
        manifest = "ios/harness/goldens/manifest.json"
        release = (
            "ios/harness/goldens/releases/"
            f"{self.identity.scenario}-{run['id']}-{run['attempt']}.json"
        )
        return golden, manifest, release

    def _validate_report(
        self,
        report: Mapping[str, Any],
        run: Mapping[str, Any],
        receipt: Mapping[str, Any],
    ) -> tuple[str, Mapping[str, str]]:
        expected_paths = set(self._expected_paths(receipt))
        files = report.get("files")
        publisher_run = report.get("publisher_run")
        oracle_run = report.get("oracle_run")
        receipt_binding = report.get("receipt")
        result_commit = report.get("result_commit")
        if (
            set(report)
            != {
                "schema_version",
                "status",
                "scenario_id",
                "request_branch",
                "request_sha",
                "result_branch",
                "result_commit",
                "publisher_run",
                "oracle_run",
                "receipt",
                "golden_sha256",
                "manifest_sha256",
                "release_receipt_sha256",
                "files",
            }
            or report.get("schema_version") != 1
            or report.get("status") != "published"
            or report.get("scenario_id") != self.identity.scenario
            or report.get("request_branch") != self.identity.request_branch
            or report.get("request_sha") != self.identity.request_sha
            or report.get("result_branch") != self.identity.result_branch
            or not isinstance(result_commit, str)
            or not HEX40.fullmatch(result_commit)
            or not isinstance(publisher_run, dict)
            or publisher_run
            != {"id": run["databaseId"], "attempt": run["attempt"]}
            or not isinstance(oracle_run, dict)
            or oracle_run
            != {
                "id": receipt["run"]["id"],
                "attempt": receipt["run"]["attempt"],
            }
            or not isinstance(receipt_binding, dict)
            or receipt_binding
            != {
                "path": self.identity.receipt_path,
                "sha256": self.identity.receipt_sha256,
            }
            or not isinstance(files, dict)
            or set(files) != expected_paths
            or any(
                not isinstance(value, str) or not HEX64.fullmatch(value)
                for value in files.values()
            )
            or any(
                not isinstance(report.get(field), str)
                or not HEX64.fullmatch(report[field])
                for field in (
                    "golden_sha256",
                    "manifest_sha256",
                    "release_receipt_sha256",
                )
            )
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_REPORT_INVALID"
            )
        return result_commit, files

    def _fetch_result(self, result_commit: str) -> None:
        remote = self._remote_ref(
            self.identity.result_branch,
            "GOLDEN_RESULT_BRANCH_LOOKUP_FAILED",
        )
        if remote != result_commit:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_BRANCH_COMMIT_MISMATCH"
            )
        local_ref = (
            f"refs/harness/github-golden/{self.identity.execution_id}"
        )
        self._command(
            [
                "git",
                "fetch",
                "--no-tags",
                self.identity.remote,
                (
                    f"+refs/heads/{self.identity.result_branch}:"
                    f"{local_ref}"
                ),
            ],
            "GOLDEN_RESULT_FETCH_FAILED",
        )
        fetched = self._text(
            ["git", "rev-parse", local_ref],
            "GOLDEN_RESULT_FETCH_FAILED",
        )
        if fetched != result_commit:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_FETCH_MISMATCH"
            )

    def _git_object(self, commit: str, path: str) -> bytes:
        return self._command(
            ["git", "show", f"{commit}:{path}"],
            "GOLDEN_RESULT_OBJECT_INVALID",
        )

    @staticmethod
    def _json_object(payload: bytes, reason: str) -> Mapping[str, Any]:
        try:
            value = json.loads(payload)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubGoldenPublisherError(reason) from error
        if not isinstance(value, dict):
            raise GitHubGoldenPublisherError(reason)
        return value

    def _verify_result_commit(
        self,
        result_commit: str,
        report: Mapping[str, Any],
        receipt: Mapping[str, Any],
    ) -> None:
        parents = self._text(
            ["git", "rev-list", "--parents", "-n", "1", result_commit],
            "GOLDEN_RESULT_COMMIT_INVALID",
        ).split()
        if parents != [result_commit, self.identity.request_sha]:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_PARENT_INVALID"
            )
        changed_raw = self._command(
            [
                "git",
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "--no-renames",
                "-r",
                "-z",
                self.identity.request_sha,
                result_commit,
            ],
            "GOLDEN_RESULT_DELTA_INVALID",
        )
        try:
            changed = {
                entry.decode("utf-8")
                for entry in changed_raw.split(b"\0")
                if entry
            }
        except UnicodeDecodeError as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_DELTA_INVALID"
            ) from error
        golden_path, manifest_path, release_path = self._expected_paths(receipt)
        if changed != {golden_path, manifest_path, release_path}:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_DELTA_INVALID"
            )
        payloads = {
            path: self._git_object(result_commit, path)
            for path in (golden_path, manifest_path, release_path)
        }
        files = report["files"]
        if any(_sha256(payloads[path]) != files[path] for path in payloads):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_FILE_DIGEST_MISMATCH"
            )
        if (
            report["golden_sha256"] != _sha256(payloads[golden_path])
            or report["manifest_sha256"] != _sha256(payloads[manifest_path])
            or report["release_receipt_sha256"]
            != _sha256(payloads[release_path])
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_REPORT_DIGEST_MISMATCH"
            )
        manifest = self._json_object(
            payloads[manifest_path], "GOLDEN_MANIFEST_INVALID"
        )
        fixtures = manifest.get("fixtures")
        oracle = manifest.get("oracle")
        if (
            manifest.get("schema_version") != 2
            or not isinstance(fixtures, dict)
            or not isinstance(oracle, dict)
            or set(oracle) != {"android_git_commit", "profile"}
            or oracle.get("profile") != PROFILE
            or not isinstance(oracle.get("android_git_commit"), str)
            or not HEX40.fullmatch(oracle["android_git_commit"])
            or not isinstance(manifest.get("canonicalizer_sha256"), str)
            or not HEX64.fullmatch(manifest["canonicalizer_sha256"])
        ):
            raise GitHubGoldenPublisherError("GOLDEN_MANIFEST_INVALID")
        entry = fixtures.get(self.identity.scenario)
        trusted = receipt["trusted_report"]
        expected_run_id = (
            f"{receipt['run']['id']}/{receipt['run']['attempt']}"
        )
        if (
            not isinstance(entry, dict)
            or entry.get("path") != golden_path
            or entry.get("release_receipt") != release_path
            or entry.get("golden_sha256") != _sha256(payloads[golden_path])
            or entry.get("run_id") != expected_run_id
            or entry.get("source_digest") != receipt["source_digest"]
            or entry.get("proposal_sha256")
            != trusted["proposal_sha256"]
            or entry.get("authorization") != AUTHORIZATION
            or entry.get("android_git_commit")
            != oracle["android_git_commit"]
            or entry.get("profile") != PROFILE
            or entry.get("canonicalizer_sha256")
            != manifest["canonicalizer_sha256"]
            or not isinstance(entry.get("runner_digest"), str)
            or not HEX64.fullmatch(entry["runner_digest"])
            or not isinstance(entry.get("runner_image_digest"), str)
            or not entry["runner_image_digest"]
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_MANIFEST_ENTRY_INVALID"
            )
        release = self._json_object(
            payloads[release_path], "GOLDEN_RELEASE_RECEIPT_INVALID"
        )
        controls = {
            "android_git_commit": entry["android_git_commit"],
            "profile": entry["profile"],
            "runner_digest": entry["runner_digest"],
            "runner_image_digest": entry["runner_image_digest"],
            "canonicalizer_sha256": entry["canonicalizer_sha256"],
        }
        cross_fields = (
            "proposal_archive_sha256",
            "evidence_archive_sha256",
            "proposal_attestation_sha256",
            "evidence_attestation_sha256",
        )
        if (
            release.get("schema_version") != 2
            or release.get("kind") != "android_golden_release"
            or release.get("authority") != "protected_android_golden"
            or release.get("publisher") != PUBLISHER
            or str(release.get("repository", "")).lower()
            != self.identity.repository
            or release.get("fixture_id") != self.identity.scenario
            or release.get("run_id") != expected_run_id
            or release.get("source_digest") != receipt["source_digest"]
            or release.get("proposal_sha256")
            != trusted["proposal_sha256"]
            or release.get("golden_sha256")
            != _sha256(payloads[golden_path])
            or release.get("golden_path") != golden_path
            or release.get("previous_authority") != "candidate_only"
            or release.get("authorization") != AUTHORIZATION
            or release.get("controls") != controls
            or any(
                release.get(field) != entry.get(field)
                for field in cross_fields
            )
        ):
            raise GitHubGoldenPublisherError(
                "GOLDEN_RELEASE_RECEIPT_INVALID"
            )

    def _merge_result(self, result_commit: str) -> None:
        remote = self._remote_ref(
            self.identity.result_branch,
            "GOLDEN_RESULT_BRANCH_RECHECK_FAILED",
        )
        if remote != result_commit:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_BRANCH_REWRITE"
            )
        self._clean_head()
        self._command(
            ["git", "merge", "--ff-only", result_commit],
            "GOLDEN_RESULT_FAST_FORWARD_FAILED",
        )
        head = self._text(
            ["git", "rev-parse", "HEAD"], "GOLDEN_RESULT_FAST_FORWARD_FAILED"
        )
        if head != result_commit:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_FAST_FORWARD_FAILED"
            )
        status = self._text(
            [
                "git",
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                ".",
                ":(exclude).harness-runtime/**",
            ],
            "GOLDEN_GIT_STATUS_FAILED",
        )
        if status:
            raise GitHubGoldenPublisherError(
                "GOLDEN_RESULT_MERGE_DIRTY"
            )

    @staticmethod
    def _run_record(run: Mapping[str, Any] | None) -> Mapping[str, Any] | None:
        if run is None:
            return None
        return {
            "id": run["databaseId"],
            "attempt": run["attempt"],
            "status": run["status"],
            "conclusion": run["conclusion"],
            "url": run["url"],
        }

    def _read_journal(self) -> Mapping[str, Any] | None:
        if not self.journal_path.exists():
            return None
        try:
            value = json.loads(self.journal_path.read_bytes())
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise GitHubGoldenPublisherError(
                "GOLDEN_JOURNAL_INVALID"
            ) from error
        if (
            not isinstance(value, dict)
            or set(value)
            != {
                "schema_version",
                "binding",
                "outcome",
                "run",
                "result",
                "created_at",
                "updated_at",
            }
            or value.get("schema_version") != 1
            or value.get("binding") != self.identity.binding()
            or value.get("outcome")
            not in {"dispatched", "pending", "running", "failed", "settled"}
            or not isinstance(value.get("created_at"), str)
            or not isinstance(value.get("updated_at"), str)
        ):
            raise GitHubGoldenPublisherError("GOLDEN_JOURNAL_INVALID")
        run = value.get("run")
        if run is not None and (
            not isinstance(run, dict)
            or set(run)
            != {"id", "attempt", "status", "conclusion", "url"}
            or isinstance(run.get("id"), bool)
            or not isinstance(run.get("id"), int)
            or run["id"] < 1
            or isinstance(run.get("attempt"), bool)
            or not isinstance(run.get("attempt"), int)
            or run["attempt"] < 1
            or run.get("status") not in STATUS_ORDER
            or not isinstance(run.get("conclusion"), str)
            or not isinstance(run.get("url"), str)
            or not run["url"]
        ):
            raise GitHubGoldenPublisherError("GOLDEN_JOURNAL_INVALID")
        result = value.get("result")
        if value["outcome"] == "settled":
            if (
                not isinstance(result, dict)
                or set(result) != {"branch", "commit"}
                or result.get("branch") != self.identity.result_branch
                or not isinstance(result.get("commit"), str)
                or not HEX40.fullmatch(result["commit"])
            ):
                raise GitHubGoldenPublisherError("GOLDEN_JOURNAL_INVALID")
        elif result is not None:
            raise GitHubGoldenPublisherError("GOLDEN_JOURNAL_INVALID")
        expected_outcome = (
            "dispatched"
            if run is None and value["outcome"] == "dispatched"
            else "pending"
            if run is None
            else "settled"
            if value["outcome"] == "settled"
            else self._outcome(
                {
                    "status": run["status"],
                    "conclusion": run["conclusion"],
                }
            )
        )
        if value["outcome"] != expected_outcome:
            raise GitHubGoldenPublisherError("GOLDEN_JOURNAL_INVALID")
        return value

    def _write_journal(
        self,
        *,
        run: Mapping[str, Any] | None,
        outcome: str,
        result_commit: str | None = None,
    ) -> Mapping[str, Any]:
        previous = self._read_journal()
        current = self._run_record(run)
        if previous is not None:
            old = previous.get("run")
            if previous.get("outcome") == "settled":
                if (
                    outcome != "settled"
                    or previous.get("result")
                    != {
                        "branch": self.identity.result_branch,
                        "commit": result_commit,
                    }
                ):
                    raise GitHubGoldenPublisherError(
                        "GOLDEN_JOURNAL_TERMINAL_REWRITE"
                    )
                return previous
            if old is not None:
                if current is None or old["id"] != current["id"]:
                    raise GitHubGoldenPublisherError(
                        "GOLDEN_JOURNAL_RUN_REGRESSION"
                    )
                if (
                    current["attempt"] < old["attempt"]
                    or STATUS_ORDER[current["status"]]
                    < STATUS_ORDER[old["status"]]
                ):
                    raise GitHubGoldenPublisherError(
                        "GOLDEN_JOURNAL_RUN_REGRESSION"
                    )
                if old["status"] == "completed" and old != current:
                    raise GitHubGoldenPublisherError(
                        "GOLDEN_JOURNAL_TERMINAL_REWRITE"
                    )
        stamp = self.now().isoformat().replace("+00:00", "Z")
        record = {
            "schema_version": 1,
            "binding": self.identity.binding(),
            "outcome": outcome,
            "run": current,
            "result": (
                {
                    "branch": self.identity.result_branch,
                    "commit": result_commit,
                }
                if result_commit is not None
                else None
            ),
            "created_at": (
                previous["created_at"] if previous is not None else stamp
            ),
            "updated_at": stamp,
        }
        self.journal_path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=self.journal_path.parent,
            prefix=f".{self.journal_path.name}.",
        )
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(_canonical(record))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.journal_path)
        finally:
            temporary.unlink(missing_ok=True)
        return record

    @staticmethod
    def _outcome(run: Mapping[str, Any]) -> str:
        if run["status"] == "completed":
            return "succeeded" if run["conclusion"] == "success" else "failed"
        return "running" if run["status"] == "in_progress" else "pending"

    def _response(
        self,
        outcome: str,
        run: Mapping[str, Any] | None,
        *,
        result_commit: str | None = None,
    ) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "outcome": outcome,
            "execution_id": self.identity.execution_id,
            "request_branch": self.identity.request_branch,
            "result_branch": self.identity.result_branch,
            "journal": str(self.journal_path.relative_to(self.root)),
            "run": self._run_record(run),
            "result_commit": result_commit,
        }

    def dispatch(self) -> dict[str, Any]:
        previous = self._read_journal()
        if previous is not None and previous["outcome"] == "settled":
            result_commit = previous["result"]["commit"]
            self._clean_worktree()
            head = self._text(
                ["git", "rev-parse", "HEAD"],
                "GOLDEN_SETTLED_HEAD_INVALID",
            )
            if head != result_commit:
                raise GitHubGoldenPublisherError(
                    "GOLDEN_SETTLED_HEAD_INVALID"
                )
            remote_url = self._text(
                ["git", "remote", "get-url", self.identity.remote],
                "GOLDEN_REMOTE_REQUIRED",
            )
            if self._remote_repository(remote_url) != self.identity.repository:
                raise GitHubGoldenPublisherError(
                    "GOLDEN_REMOTE_REPOSITORY_MISMATCH"
                )
            self._command(
                ["gh", "auth", "status", "--hostname", "github.com"],
                "GOLDEN_GITHUB_AUTH_REQUIRED",
            )
            receipt = self._load_receipt()
            if (
                self._remote_ref(
                    self.identity.request_branch,
                    "GOLDEN_REQUEST_BRANCH_LOOKUP_FAILED",
                )
                != self.identity.request_sha
            ):
                raise GitHubGoldenPublisherError(
                    "GOLDEN_REQUEST_BRANCH_CONFLICT"
                )
            runs = self._runs()
            if len(runs) != 1 or self._outcome(runs[0]) != "succeeded":
                raise GitHubGoldenPublisherError(
                    "GOLDEN_SETTLED_RUN_INVALID"
                )
            run = runs[0]
            self._verify_run_api(run)
            artifact = self._artifact(run)
            with tempfile.TemporaryDirectory(
                prefix="legado-golden-result-"
            ) as directory:
                report = self._download_report(
                    Path(directory), run, artifact
                )
            reported_commit, _ = self._validate_report(
                report, run, receipt
            )
            if reported_commit != result_commit:
                raise GitHubGoldenPublisherError(
                    "GOLDEN_JOURNAL_RESULT_MISMATCH"
                )
            self._fetch_result(result_commit)
            self._verify_result_commit(result_commit, report, receipt)
            return self._response(
                "settled",
                run,
                result_commit=result_commit,
            )
        receipt = self._preflight()
        created = self._ensure_request_branch()
        runs = self._runs()
        if not runs:
            outcome = "dispatched" if created else "pending"
            self._write_journal(run=None, outcome=outcome)
            return self._response(outcome, None)
        run = runs[0]
        outcome = self._outcome(run)
        if outcome != "succeeded":
            self._write_journal(run=run, outcome=outcome)
            return self._response(outcome, run)
        self._verify_run_api(run)
        artifact = self._artifact(run)
        with tempfile.TemporaryDirectory(
            prefix="legado-golden-result-"
        ) as directory:
            report = self._download_report(Path(directory), run, artifact)
        result_commit, _ = self._validate_report(report, run, receipt)
        self._fetch_result(result_commit)
        self._verify_result_commit(result_commit, report, receipt)
        self._merge_result(result_commit)
        self._write_journal(
            run=run,
            outcome="settled",
            result_commit=result_commit,
        )
        return self._response(
            "settled",
            run,
            result_commit=result_commit,
        )
