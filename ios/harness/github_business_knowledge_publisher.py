#!/usr/bin/env python3
"""Recoverable GitHub dispatcher for Business Knowledge publication."""

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
from typing import Any, Callable, Mapping, Optional, Sequence
from urllib.parse import urlparse


WORKFLOW_PATH = ".github/workflows/business-knowledge-publisher.yml"
REQUEST_PATH = ".business-knowledge-publication-request.json"
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
REMOTE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
BATCH = re.compile(r"^KPUB-[A-Z][A-Z0-9-]*-[0-9]{3}$")
WORK_ITEM = re.compile(r"^IOS-[A-Z][A-Z0-9-]*-[0-9]{3}$")
REQUIREMENT_REF = re.compile(
    r"^REQ-[A-Z0-9-]+@[1-9][0-9]*#RC-[0-9]{2}$"
)
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
RESULT_FILES = {
    "SHA256SUMS",
    "publisher-result.json",
    "transaction.json",
}
STATUS_ORDER = {"queued", "in_progress", "completed"}
MAX_ARTIFACT_FILE_BYTES = 8 * 1024 * 1024


class GitHubBusinessKnowledgePublisherError(RuntimeError):
    """Stable fail-closed dispatcher error."""


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


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _relative(value: str, prefix: str) -> str:
    if not isinstance(value, str):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_PATH_INVALID"
        )
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or path.as_posix() != value
        or any(part in {"", ".", ".."} for part in path.parts)
        or not value.startswith(prefix)
    ):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_PATH_INVALID"
        )
    return value


@dataclass(frozen=True)
class KnowledgePublicationIdentity:
    repository: str
    workflow_path: str
    batch_id: str
    source_sha: str
    remote: str
    execution_id: str
    request_branch: str
    result_branch: str
    request: Mapping[str, Any]

    def binding(self) -> Mapping[str, Any]:
        return {
            "repository": self.repository,
            "workflow_path": self.workflow_path,
            "batch_id": self.batch_id,
            "source_sha": self.source_sha,
            "remote": self.remote,
            "execution_id": self.execution_id,
            "request_branch": self.request_branch,
            "result_branch": self.result_branch,
            "request": dict(self.request),
        }


def knowledge_publication_identity(
    *,
    repository: str,
    workflow_path: str,
    batch_id: str,
    source_sha: str,
    remote: str,
    publication: Mapping[str, Any],
    producer: Mapping[str, Any],
    next_delivery_intent_id: str,
) -> KnowledgePublicationIdentity:
    if not isinstance(repository, str) or not REPOSITORY.fullmatch(
        repository
    ):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_REPOSITORY_INVALID"
        )
    if workflow_path != WORKFLOW_PATH:
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_WORKFLOW_INVALID"
        )
    if not isinstance(batch_id, str) or not BATCH.fullmatch(batch_id):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_BATCH_INVALID"
        )
    if not isinstance(source_sha, str) or not HEX40.fullmatch(source_sha):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_SOURCE_SHA_INVALID"
        )
    if not isinstance(remote, str) or not REMOTE.fullmatch(remote):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_REMOTE_INVALID"
        )
    packet = _relative(
        publication.get("packet_proposal"),
        "ios/project/business-knowledge/packets/proposals/",
    )
    driver = _relative(
        publication.get("driver_proposal"),
        "ios/project/business-knowledge/drivers/proposals/",
    )
    golden = _relative(
        publication.get("golden_receipt"),
        "ios/harness/goldens/releases/",
    )
    producer_work_item = _relative(
        producer.get("work_item"),
        "ios/harness/work-items/",
    )
    producer_evidence = _relative(
        producer.get("evidence"),
        "ios/harness/evidence/runs/",
    )
    producer_checkpoint = _relative(
        producer.get("checkpoint"),
        "ios/project/checkpoints/",
    )
    digests = {
        "packet_proposal_sha256": publication.get(
            "packet_proposal_sha256"
        ),
        "driver_proposal_sha256": publication.get(
            "driver_proposal_sha256"
        ),
        "golden_receipt_sha256": publication.get(
            "golden_receipt_sha256"
        ),
        "producer_work_item_sha256": producer.get(
            "work_item_sha256"
        ),
        "producer_evidence_sha256": producer.get("evidence_sha256"),
        "producer_checkpoint_sha256": producer.get(
            "checkpoint_sha256"
        ),
    }
    if any(
        not isinstance(value, str) or not HEX64.fullmatch(value)
        for value in digests.values()
    ):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_DIGEST_INVALID"
        )
    requirement_refs = publication.get("requirement_refs")
    target = publication.get("target_work_item_id")
    if (
        not isinstance(requirement_refs, list)
        or not requirement_refs
        or requirement_refs != sorted(set(requirement_refs))
        or any(
            not isinstance(value, str)
            or not REQUIREMENT_REF.fullmatch(value)
            for value in requirement_refs
        )
        or not isinstance(target, str)
        or not WORK_ITEM.fullmatch(target)
        or not isinstance(next_delivery_intent_id, str)
        or not next_delivery_intent_id.startswith("DINT-")
    ):
        raise GitHubBusinessKnowledgePublisherError(
            "KNOWLEDGE_PUBLICATION_TARGET_INVALID"
        )
    request = {
        "schema_version": 1,
        "kind": "business_knowledge_publication_request",
        "repository": repository.lower(),
        "workflow_path": workflow_path,
        "batch_id": batch_id,
        "source_sha": source_sha,
        "packet_proposal": packet,
        "driver_proposal": driver,
        "golden_receipt": golden,
        "producer_work_item": producer_work_item,
        "producer_evidence": producer_evidence,
        "producer_checkpoint": producer_checkpoint,
        **digests,
        "requirement_refs": requirement_refs,
        "target_work_item_id": target,
        "next_delivery_intent_id": next_delivery_intent_id,
    }
    execution_id = _sha256(_canonical(request))
    slug = batch_id.removeprefix("KPUB-").lower()
    return KnowledgePublicationIdentity(
        repository=repository.lower(),
        workflow_path=workflow_path,
        batch_id=batch_id,
        source_sha=source_sha,
        remote=remote,
        execution_id=execution_id,
        request_branch=f"knowledge/request-{slug}-{source_sha}",
        result_branch=f"knowledge/result-{slug}-{source_sha}",
        request=request,
    )


Runner = Callable[
    [Sequence[str], Path, Optional[Mapping[str, str]]],
    subprocess.CompletedProcess[bytes],
]


class GitHubBusinessKnowledgePublisherDispatcher:
    """Create an immutable request commit and later verify its result."""

    def __init__(
        self,
        root: Path,
        *,
        repository: str,
        workflow_path: str,
        batch_id: str,
        source_sha: str,
        remote: str,
        publication: Mapping[str, Any],
        producer: Mapping[str, Any],
        next_delivery_intent_id: str,
        runner: Optional[Runner] = None,
        now: Optional[Callable[[], dt.datetime]] = None,
    ):
        try:
            self.root = root.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_ROOT_INVALID"
            ) from error
        self.identity = knowledge_publication_identity(
            repository=repository,
            workflow_path=workflow_path,
            batch_id=batch_id,
            source_sha=source_sha,
            remote=remote,
            publication=publication,
            producer=producer,
            next_delivery_intent_id=next_delivery_intent_id,
        )
        self.runner = runner or self._run
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.journal_path = (
            self.root
            / ".harness-runtime"
            / "github-business-knowledge"
            / f"{self.identity.execution_id}.json"
        )

    @staticmethod
    def _run(
        argv: Sequence[str],
        cwd: Path,
        environment: Optional[Mapping[str, str]],
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            list(argv),
            cwd=cwd,
            env=dict(environment) if environment is not None else None,
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
        environment: Optional[Mapping[str, str]] = None,
    ) -> bytes:
        try:
            result = self.runner(
                tuple(argv),
                cwd or self.root,
                environment,
            )
        except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
            raise GitHubBusinessKnowledgePublisherError(reason) from error
        payload = result.stdout or b""
        if isinstance(payload, str):
            payload = payload.encode("utf-8")
        if result.returncode != 0 or len(payload) > 16 * 1024 * 1024:
            raise GitHubBusinessKnowledgePublisherError(reason)
        return payload

    def _text(
        self,
        argv: Sequence[str],
        reason: str,
        *,
        cwd: Path | None = None,
        environment: Optional[Mapping[str, str]] = None,
    ) -> str:
        try:
            return self._command(
                argv,
                reason,
                cwd=cwd,
                environment=environment,
            ).decode("utf-8").strip()
        except UnicodeDecodeError as error:
            raise GitHubBusinessKnowledgePublisherError(reason) from error

    @staticmethod
    def _remote_repository(url: str) -> str | None:
        value = url.strip()
        match = re.fullmatch(
            r"git@[^:]+:([^/]+/[^/]+?)(?:\.git)?",
            value,
        )
        if match:
            return match.group(1).lower()
        parsed = urlparse(value)
        if parsed.scheme not in {"https", "ssh"} or not parsed.hostname:
            return None
        path = parsed.path.lstrip("/")
        path = path[:-4] if path.endswith(".git") else path
        return path.lower() if REPOSITORY.fullmatch(path) else None

    def _clean_source(self) -> None:
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
            "KNOWLEDGE_PUBLICATION_GIT_STATUS_FAILED",
        )
        if status:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_WORKTREE_DIRTY"
            )
        if (
            self._text(
                ["git", "rev-parse", "HEAD"],
                "KNOWLEDGE_PUBLICATION_HEAD_REQUIRED",
            )
            != self.identity.source_sha
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_SOURCE_HEAD_MISMATCH"
            )

    def _preflight(self) -> None:
        self._clean_source()
        self._validate_authority_inputs()

    def _validate_authority_inputs(self) -> None:
        remote_url = self._text(
            ["git", "remote", "get-url", self.identity.remote],
            "KNOWLEDGE_PUBLICATION_REMOTE_REQUIRED",
        )
        if self._remote_repository(remote_url) != self.identity.repository:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REMOTE_REPOSITORY_MISMATCH"
            )
        for path_key, digest_key in (
            ("packet_proposal", "packet_proposal_sha256"),
            ("driver_proposal", "driver_proposal_sha256"),
            ("golden_receipt", "golden_receipt_sha256"),
            ("producer_work_item", "producer_work_item_sha256"),
            ("producer_evidence", "producer_evidence_sha256"),
            ("producer_checkpoint", "producer_checkpoint_sha256"),
        ):
            relative = self.identity.request[path_key]
            payload = self._command(
                [
                    "git",
                    "show",
                    f"{self.identity.source_sha}:{relative}",
                ],
                "KNOWLEDGE_PUBLICATION_INPUT_NOT_COMMITTED",
            )
            if _sha256(payload) != self.identity.request[digest_key]:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_INPUT_DIGEST_DRIFT"
                )
        self._command(
            ["gh", "auth", "status", "--hostname", "github.com"],
            "KNOWLEDGE_PUBLICATION_GITHUB_AUTH_REQUIRED",
        )

    def request_manifest(self) -> bytes:
        return _canonical(self.identity.request)

    def _remote_ref(self, branch: str, reason: str) -> Optional[str]:
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
        if (
            len(fields) != 2
            or fields[1] != ref
            or not HEX40.fullmatch(fields[0])
        ):
            raise GitHubBusinessKnowledgePublisherError(reason)
        return fields[0]

    def _validate_request_commit(self, commit: str) -> None:
        if not HEX40.fullmatch(commit):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REQUEST_COMMIT_INVALID"
            )
        parents = self._text(
            ["git", "rev-list", "--parents", "-n", "1", commit],
            "KNOWLEDGE_PUBLICATION_REQUEST_COMMIT_INVALID",
        ).split()
        if parents != [commit, self.identity.source_sha]:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REQUEST_PARENT_INVALID"
            )
        changed = self._text(
            [
                "git",
                "diff-tree",
                "--no-commit-id",
                "--name-only",
                "--no-renames",
                "-r",
                self.identity.source_sha,
                commit,
            ],
            "KNOWLEDGE_PUBLICATION_REQUEST_DELTA_INVALID",
        ).splitlines()
        if changed != [REQUEST_PATH]:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REQUEST_DELTA_INVALID"
            )
        manifest = self._command(
            ["git", "show", f"{commit}:{REQUEST_PATH}"],
            "KNOWLEDGE_PUBLICATION_REQUEST_MANIFEST_INVALID",
        )
        if manifest != self.request_manifest():
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REQUEST_MANIFEST_INVALID"
            )

    def _create_request_commit(self) -> str:
        with tempfile.TemporaryDirectory(
            prefix="legado-knowledge-request-"
        ) as directory:
            worktree = Path(directory) / "worktree"
            self._command(
                [
                    "git",
                    "worktree",
                    "add",
                    "--detach",
                    str(worktree),
                    self.identity.source_sha,
                ],
                "KNOWLEDGE_PUBLICATION_REQUEST_WORKTREE_FAILED",
            )
            try:
                (worktree / REQUEST_PATH).write_bytes(
                    self.request_manifest()
                )
                self._command(
                    ["git", "add", "--", REQUEST_PATH],
                    "KNOWLEDGE_PUBLICATION_REQUEST_STAGE_FAILED",
                    cwd=worktree,
                )
                environment = dict(os.environ)
                environment.update(
                    {
                        "GIT_AUTHOR_NAME": "legado-loop",
                        "GIT_AUTHOR_EMAIL": "loop@localhost",
                        "GIT_COMMITTER_NAME": "legado-loop",
                        "GIT_COMMITTER_EMAIL": "loop@localhost",
                    }
                )
                self._command(
                    [
                        "git",
                        "commit",
                        "-m",
                        (
                            "chore(ios): request business knowledge "
                            f"publication {self.identity.batch_id}"
                        ),
                    ],
                    "KNOWLEDGE_PUBLICATION_REQUEST_COMMIT_FAILED",
                    cwd=worktree,
                    environment=environment,
                )
                commit = self._text(
                    ["git", "rev-parse", "HEAD"],
                    "KNOWLEDGE_PUBLICATION_REQUEST_COMMIT_FAILED",
                    cwd=worktree,
                )
                self._command(
                    [
                        "git",
                        "push",
                        self.identity.remote,
                        (
                            f"{commit}:refs/heads/"
                            f"{self.identity.request_branch}"
                        ),
                    ],
                    "KNOWLEDGE_PUBLICATION_REQUEST_BRANCH_CREATE_FAILED",
                    cwd=worktree,
                )
            except OSError as error:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_REQUEST_MANIFEST_WRITE_FAILED"
                ) from error
            finally:
                self._command(
                    [
                        "git",
                        "worktree",
                        "remove",
                        "--force",
                        str(worktree),
                    ],
                    "KNOWLEDGE_PUBLICATION_REQUEST_WORKTREE_CLEANUP_FAILED",
                )
        return commit

    def _ensure_request_branch(self) -> str:
        commit = self._remote_ref(
            self.identity.request_branch,
            "KNOWLEDGE_PUBLICATION_REQUEST_BRANCH_LOOKUP_FAILED",
        )
        if commit is None:
            commit = self._create_request_commit()
        remote = self._remote_ref(
            self.identity.request_branch,
            "KNOWLEDGE_PUBLICATION_REQUEST_BRANCH_RECHECK_FAILED",
        )
        if remote != commit:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REQUEST_BRANCH_CONFLICT"
            )
        self._command(
            [
                "git",
                "fetch",
                "--no-tags",
                self.identity.remote,
                (
                    f"+refs/heads/{self.identity.request_branch}:"
                    f"refs/harness/business-knowledge-request/"
                    f"{self.identity.execution_id}"
                ),
            ],
            "KNOWLEDGE_PUBLICATION_REQUEST_FETCH_FAILED",
        )
        self._validate_request_commit(commit)
        return commit

    def _json(self, argv: Sequence[str], reason: str) -> Any:
        try:
            return json.loads(self._command(argv, reason))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubBusinessKnowledgePublisherError(reason) from error

    def _runs(self, request_commit: str) -> list[Mapping[str, Any]]:
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
            "KNOWLEDGE_PUBLICATION_RUN_LOOKUP_FAILED",
        )
        if (
            not isinstance(value, list)
            or len(value) > 1
            or any(
                not isinstance(run, dict) or set(run) != RUN_FIELDS
                for run in value
            )
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RUN_RESPONSE_INVALID"
            )
        if not value:
            return []
        run = value[0]
        if (
            run.get("headSha") != request_commit
            or run.get("headBranch") != self.identity.request_branch
            or run.get("event") != "push"
            or isinstance(run.get("databaseId"), bool)
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
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RUN_BINDING_DRIFT"
            )
        return value

    def _verify_run(self, run: Mapping[str, Any], request_commit: str) -> None:
        value = self._json(
            [
                "gh",
                "api",
                (
                    f"repos/{self.identity.repository}/actions/runs/"
                    f"{run['databaseId']}"
                ),
            ],
            "KNOWLEDGE_PUBLICATION_RUN_PROVENANCE_INVALID",
        )
        if (
            not isinstance(value, dict)
            or value.get("id") != run["databaseId"]
            or value.get("run_attempt") != run["attempt"]
            or value.get("path") != self.identity.workflow_path
            or value.get("event") != "push"
            or value.get("status") != "completed"
            or value.get("conclusion") != "success"
            or value.get("head_sha") != request_commit
            or value.get("head_branch") != self.identity.request_branch
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RUN_PROVENANCE_INVALID"
            )

    def _artifact(
        self,
        run: Mapping[str, Any],
        request_commit: str,
    ) -> Mapping[str, Any]:
        name = (
            f"business-knowledge-result-{self.identity.execution_id}-"
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
            "KNOWLEDGE_PUBLICATION_ARTIFACT_LOOKUP_FAILED",
        )
        if not isinstance(value, dict) or not isinstance(
            value.get("artifacts"), list
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_ARTIFACT_RESPONSE_INVALID"
            )
        matches = [
            artifact
            for artifact in value["artifacts"]
            if isinstance(artifact, dict)
            and artifact.get("name") == name
        ]
        if len(matches) != 1:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_ARTIFACT_NOT_UNIQUE"
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
            or workflow_run.get("head_sha") != request_commit
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_ARTIFACT_INVALID"
            )
        return artifact

    def _download_result(
        self,
        run: Mapping[str, Any],
        artifact: Mapping[str, Any],
    ) -> tuple[Mapping[str, Any], Mapping[str, Any]]:
        with tempfile.TemporaryDirectory(
            prefix="legado-knowledge-result-"
        ) as directory:
            root = Path(directory)
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
                    str(root),
                ],
                "KNOWLEDGE_PUBLICATION_RESULT_DOWNLOAD_FAILED",
            )
            entries = list(root.iterdir())
            if {path.name for path in entries} != RESULT_FILES:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_RESULT_FILE_SET_INVALID"
                )
            payloads: dict[str, bytes] = {}
            for path in entries:
                if (
                    path.is_symlink()
                    or not path.is_file()
                    or path.stat().st_size > MAX_ARTIFACT_FILE_BYTES
                ):
                    raise GitHubBusinessKnowledgePublisherError(
                        "KNOWLEDGE_PUBLICATION_RESULT_FILE_INVALID"
                    )
                payloads[path.name] = path.read_bytes()
            expected_checksums = "".join(
                f"{_sha256(payloads[name])}  {name}\n"
                for name in sorted(RESULT_FILES - {"SHA256SUMS"})
            ).encode("ascii")
            if payloads["SHA256SUMS"] != expected_checksums:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_RESULT_CHECKSUM_INVALID"
                )
            try:
                report = json.loads(payloads["publisher-result.json"])
                transaction = json.loads(payloads["transaction.json"])
            except (UnicodeError, json.JSONDecodeError) as error:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_RESULT_JSON_INVALID"
                ) from error
            if (
                not isinstance(report, dict)
                or not isinstance(transaction, dict)
                or _canonical(report)
                != payloads["publisher-result.json"]
                or _canonical(transaction) != payloads["transaction.json"]
            ):
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_RESULT_JSON_INVALID"
                )
            return report, transaction

    def _expected_transaction_paths(
        self,
        run: Mapping[str, Any],
    ) -> tuple[set[str], set[str], str]:
        packet = self.identity.request["packet_proposal"]
        driver = self.identity.request["driver_proposal"]
        packet_id = PurePosixPath(packet).parent.name
        revision = PurePosixPath(packet).name.removeprefix("r").removesuffix(
            ".json"
        )
        if not revision.isdigit() or len(revision) != 4:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_PACKET_REVISION_INVALID"
            )
        published_packet = packet.replace(
            "/packets/proposals/",
            "/packets/published/",
            1,
        )
        published_driver = driver.replace(
            "/drivers/proposals/",
            "/drivers/published/",
            1,
        )
        ledger_id = "BKL-" + packet_id.removeprefix("BKP-")
        ledger = (
            "ios/project/business-knowledge/coverage/"
            f"{ledger_id}.json"
        )
        release = (
            "ios/project/business-knowledge/releases/"
            f"{packet_id}-r{revision}-{run['databaseId']}-"
            f"{run['attempt']}.json"
        )
        installs = {
            "ios/project/business-knowledge/catalog.json",
            ledger,
            published_packet,
            published_driver,
            release,
        }
        deletes = {packet, driver}
        return installs, deletes, release

    def _validate_result(
        self,
        report: Mapping[str, Any],
        transaction: Mapping[str, Any],
        run: Mapping[str, Any],
        request_commit: str,
    ) -> str:
        installs, deletes, release = self._expected_transaction_paths(run)
        install_entries = transaction.get("install")
        install_map = {
            entry.get("path"): entry.get("sha256")
            for entry in install_entries
            if isinstance(entry, dict)
        } if isinstance(install_entries, list) else {}
        result_commit = report.get("result_commit")
        if (
            set(transaction)
            != {
                "schema_version",
                "kind",
                "authority",
                "source_commit",
                "publisher_run_id",
                "install",
                "delete",
                "receipt",
                "knowledge_authority_sha256",
            }
            or transaction.get("schema_version") != 1
            or transaction.get("kind")
            != "business_knowledge_publication_transaction"
            or transaction.get("authority")
            != "protected_business_knowledge"
            or transaction.get("source_commit") != request_commit
            or transaction.get("publisher_run_id")
            != f"{run['databaseId']}/{run['attempt']}"
            or set(install_map) != installs
            or len(install_map) != len(install_entries)
            or any(
                not isinstance(value, str) or not HEX64.fullmatch(value)
                for value in install_map.values()
            )
            or transaction.get("delete") != sorted(deletes)
            or transaction.get("receipt") != release
            or not isinstance(
                transaction.get("knowledge_authority_sha256"), str
            )
            or not HEX64.fullmatch(
                transaction["knowledge_authority_sha256"]
            )
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_TRANSACTION_INVALID"
            )
        if (
            set(report)
            != {
                "schema_version",
                "status",
                "batch_id",
                "source_sha",
                "request_branch",
                "request_commit",
                "result_branch",
                "result_commit",
                "publisher_run",
                "transaction_sha256",
                "execution_id",
            }
            or report.get("schema_version") != 1
            or report.get("status") != "published"
            or report.get("batch_id") != self.identity.batch_id
            or report.get("source_sha") != self.identity.source_sha
            or report.get("request_branch")
            != self.identity.request_branch
            or report.get("request_commit") != request_commit
            or report.get("result_branch") != self.identity.result_branch
            or report.get("execution_id") != self.identity.execution_id
            or report.get("publisher_run")
            != {"id": run["databaseId"], "attempt": run["attempt"]}
            or report.get("transaction_sha256")
            != _sha256(_canonical(transaction))
            or not isinstance(result_commit, str)
            or not HEX40.fullmatch(result_commit)
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RESULT_REPORT_INVALID"
            )
        return result_commit

    def _fetch_result(self, result_commit: str) -> None:
        if (
            self._remote_ref(
                self.identity.result_branch,
                "KNOWLEDGE_PUBLICATION_RESULT_BRANCH_LOOKUP_FAILED",
            )
            != result_commit
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RESULT_BRANCH_COMMIT_MISMATCH"
            )
        local_ref = (
            "refs/harness/business-knowledge-result/"
            f"{self.identity.execution_id}"
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
            "KNOWLEDGE_PUBLICATION_RESULT_FETCH_FAILED",
        )
        if (
            self._text(
                ["git", "rev-parse", local_ref],
                "KNOWLEDGE_PUBLICATION_RESULT_FETCH_FAILED",
            )
            != result_commit
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RESULT_FETCH_MISMATCH"
            )

    def _verify_result_commit(
        self,
        result_commit: str,
        request_commit: str,
        transaction: Mapping[str, Any],
        run: Mapping[str, Any],
    ) -> None:
        parents = self._text(
            ["git", "rev-list", "--parents", "-n", "1", result_commit],
            "KNOWLEDGE_PUBLICATION_RESULT_COMMIT_INVALID",
        ).split()
        if parents != [result_commit, request_commit]:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RESULT_PARENT_INVALID"
            )
        installs, deletes, _ = self._expected_transaction_paths(run)
        from_request = set(
            self._text(
                [
                    "git",
                    "diff-tree",
                    "--no-commit-id",
                    "--name-only",
                    "--no-renames",
                    "-r",
                    request_commit,
                    result_commit,
                ],
                "KNOWLEDGE_PUBLICATION_RESULT_DELTA_INVALID",
            ).splitlines()
        )
        from_source = set(
            self._text(
                [
                    "git",
                    "diff-tree",
                    "--no-commit-id",
                    "--name-only",
                    "--no-renames",
                    "-r",
                    self.identity.source_sha,
                    result_commit,
                ],
                "KNOWLEDGE_PUBLICATION_RESULT_DELTA_INVALID",
            ).splitlines()
        )
        if (
            from_request != installs | deletes | {REQUEST_PATH}
            or from_source != installs | deletes
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RESULT_DELTA_INVALID"
            )
        install_map = {
            entry["path"]: entry["sha256"]
            for entry in transaction["install"]
        }
        for relative, expected in install_map.items():
            payload = self._command(
                ["git", "show", f"{result_commit}:{relative}"],
                "KNOWLEDGE_PUBLICATION_RESULT_OBJECT_INVALID",
            )
            if _sha256(payload) != expected:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_RESULT_DIGEST_MISMATCH"
                )
        for relative in deletes | {REQUEST_PATH}:
            result = self.runner(
                ("git", "cat-file", "-e", f"{result_commit}:{relative}"),
                self.root,
                None,
            )
            if result.returncode == 0:
                raise GitHubBusinessKnowledgePublisherError(
                    "KNOWLEDGE_PUBLICATION_RESULT_DELETION_INVALID"
                )

    def _merge_result(self, result_commit: str) -> None:
        self._clean_source()
        if (
            self._remote_ref(
                self.identity.result_branch,
                "KNOWLEDGE_PUBLICATION_RESULT_BRANCH_RECHECK_FAILED",
            )
            != result_commit
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_RESULT_BRANCH_REWRITE"
            )
        self._command(
            ["git", "merge", "--ff-only", result_commit],
            "KNOWLEDGE_PUBLICATION_FAST_FORWARD_FAILED",
        )
        if (
            self._text(
                ["git", "rev-parse", "HEAD"],
                "KNOWLEDGE_PUBLICATION_FAST_FORWARD_FAILED",
            )
            != result_commit
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_FAST_FORWARD_FAILED"
            )
        self._command(
            [
                "python3",
                "-B",
                "ios/harness/business-knowledge/business_knowledge.py",
                "doctor",
                "--root",
                ".",
            ],
            "KNOWLEDGE_PUBLICATION_POST_MERGE_DOCTOR_FAILED",
        )
        self._command(
            ["python3", "-B", "ios/harness/harness.py", "doctor"],
            "KNOWLEDGE_PUBLICATION_POST_MERGE_HARNESS_FAILED",
        )

    def _write_journal(
        self,
        outcome: str,
        *,
        request_commit: str,
        run: Optional[Mapping[str, Any]] = None,
        result_commit: Optional[str] = None,
    ) -> None:
        record = {
            "schema_version": 1,
            "execution_id": self.identity.execution_id,
            "identity": self.identity.binding(),
            "outcome": outcome,
            "request_commit": request_commit,
            "run": (
                {
                    "id": run["databaseId"],
                    "attempt": run["attempt"],
                    "status": run["status"],
                    "conclusion": run["conclusion"],
                    "url": run["url"],
                }
                if run is not None
                else None
            ),
            "result_commit": result_commit,
            "updated_at": self.now().isoformat().replace("+00:00", "Z"),
        }
        self.journal_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.journal_path.with_suffix(".tmp")
        temporary.write_bytes(_canonical(record))
        os.replace(temporary, self.journal_path)

    def _read_journal(self) -> Optional[Mapping[str, Any]]:
        if not self.journal_path.exists():
            return None
        try:
            value = json.loads(self.journal_path.read_bytes())
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_JOURNAL_INVALID"
            ) from error
        if (
            not isinstance(value, dict)
            or set(value)
            != {
                "schema_version",
                "execution_id",
                "identity",
                "outcome",
                "request_commit",
                "run",
                "result_commit",
                "updated_at",
            }
            or value.get("schema_version") != 1
            or value.get("execution_id")
            != self.identity.execution_id
            or value.get("identity") != self.identity.binding()
            or value.get("outcome")
            not in {
                "pending",
                "running",
                "failed",
                "verified",
                "settled",
            }
            or not isinstance(value.get("request_commit"), str)
            or not HEX40.fullmatch(value["request_commit"])
        ):
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_JOURNAL_INVALID"
            )
        return value

    @staticmethod
    def _run_outcome(run: Mapping[str, Any]) -> str:
        if run["status"] == "completed":
            return (
                "succeeded"
                if run["conclusion"] == "success"
                else "failed"
            )
        return (
            "running"
            if run["status"] == "in_progress"
            else "pending"
        )

    def _response(
        self,
        outcome: str,
        request_commit: str,
        run: Optional[Mapping[str, Any]],
        result_commit: Optional[str] = None,
    ) -> dict[str, Any]:
        return {
            "schema_version": 1,
            "outcome": outcome,
            "execution_id": self.identity.execution_id,
            "request_branch": self.identity.request_branch,
            "request_commit": request_commit,
            "result_branch": self.identity.result_branch,
            "run": (
                {
                    "id": run["databaseId"],
                    "attempt": run["attempt"],
                    "status": run["status"],
                    "conclusion": run["conclusion"],
                    "url": run["url"],
                }
                if run is not None
                else None
            ),
            "result_commit": result_commit,
            "journal": str(self.journal_path.relative_to(self.root)),
        }

    def _remote_result(
        self,
        request_commit: str,
        run: Mapping[str, Any],
    ) -> tuple[str, Mapping[str, Any]]:
        self._verify_run(run, request_commit)
        artifact = self._artifact(run, request_commit)
        report, transaction = self._download_result(run, artifact)
        result_commit = self._validate_result(
            report,
            transaction,
            run,
            request_commit,
        )
        self._fetch_result(result_commit)
        self._verify_result_commit(
            result_commit,
            request_commit,
            transaction,
            run,
        )
        return result_commit, transaction

    def _replay_merged(
        self,
        journal: Mapping[str, Any],
    ) -> Optional[dict[str, Any]]:
        result_commit = journal.get("result_commit")
        if (
            journal.get("outcome") not in {"verified", "settled"}
            or not isinstance(result_commit, str)
            or not HEX40.fullmatch(result_commit)
        ):
            return None
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
            "KNOWLEDGE_PUBLICATION_GIT_STATUS_FAILED",
        )
        if status:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_WORKTREE_DIRTY"
            )
        head = self._text(
            ["git", "rev-parse", "HEAD"],
            "KNOWLEDGE_PUBLICATION_HEAD_REQUIRED",
        )
        if head == self.identity.source_sha:
            return None
        if head != result_commit:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REPLAY_HEAD_INVALID"
            )
        self._validate_authority_inputs()
        request_commit = self._ensure_request_branch()
        if request_commit != journal["request_commit"]:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REPLAY_REQUEST_DRIFT"
            )
        runs = self._runs(request_commit)
        if len(runs) != 1 or self._run_outcome(runs[0]) != "succeeded":
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REPLAY_RUN_INVALID"
            )
        run = runs[0]
        remote_result, _ = self._remote_result(request_commit, run)
        if remote_result != result_commit:
            raise GitHubBusinessKnowledgePublisherError(
                "KNOWLEDGE_PUBLICATION_REPLAY_RESULT_DRIFT"
            )
        self._command(
            [
                "python3",
                "-B",
                "ios/harness/business-knowledge/business_knowledge.py",
                "doctor",
                "--root",
                ".",
            ],
            "KNOWLEDGE_PUBLICATION_POST_MERGE_DOCTOR_FAILED",
        )
        self._command(
            ["python3", "-B", "ios/harness/harness.py", "doctor"],
            "KNOWLEDGE_PUBLICATION_POST_MERGE_HARNESS_FAILED",
        )
        self._write_journal(
            "settled",
            request_commit=request_commit,
            run=run,
            result_commit=result_commit,
        )
        return self._response(
            "settled",
            request_commit,
            run,
            result_commit,
        )

    def dispatch(self) -> dict[str, Any]:
        previous = self._read_journal()
        if previous is not None:
            replay = self._replay_merged(previous)
            if replay is not None:
                return replay
        self._preflight()
        request_commit = self._ensure_request_branch()
        runs = self._runs(request_commit)
        if not runs:
            self._write_journal(
                "pending",
                request_commit=request_commit,
            )
            return self._response("pending", request_commit, None)
        run = runs[0]
        outcome = self._run_outcome(run)
        if outcome != "succeeded":
            self._write_journal(
                outcome,
                request_commit=request_commit,
                run=run,
            )
            return self._response(outcome, request_commit, run)
        result_commit, _ = self._remote_result(request_commit, run)
        self._write_journal(
            "verified",
            request_commit=request_commit,
            run=run,
            result_commit=result_commit,
        )
        self._merge_result(result_commit)
        self._write_journal(
            "settled",
            request_commit=request_commit,
            run=run,
            result_commit=result_commit,
        )
        return self._response(
            "settled",
            request_commit,
            run,
            result_commit,
        )
