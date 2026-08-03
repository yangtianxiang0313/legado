#!/usr/bin/env python3
"""Fail-closed settlement of a GitHub Android Oracle candidate artifact."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from github_oracle_dispatcher import WORKFLOW_PATH, execution_identity


HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_FILES = {
    "SHA256SUMS",
    "android-oracle-evidence.tar",
    "android-oracle-proposal.tar",
    "evidence-attestation.json",
    "proposal-attestation.json",
}
MAX_FILE_BYTES = 128 * 1024 * 1024
AUTHORITY_PATHS = (
    WORKFLOW_PATH,
    "ios/harness/fixtures/manifest.json",
    "ios/harness/oracle/contract.py",
    "ios/harness/oracle/ci_proposal.py",
    "ios/harness/oracle/request-registry.json",
    "ios/harness/oracle/trusted_import.py",
    "ios/harness/source-lab/manifest.json",
    "ios/harness/integration-lab/integration_lab.py",
    "ios/harness/integration-lab/coverage-policy-v1.json",
    "ios/harness/integration-lab/manifest.json",
    "ios/harness/schemas/integration-lab-scenario.schema.json",
)


class GitHubOracleReceiptError(RuntimeError):
    pass


Runner = Callable[[Sequence[str], Path], subprocess.CompletedProcess[bytes]]


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _canonical(value: Any) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        .encode("utf-8") + b"\n"
    )


def receipt_path(scenario: str, source_digest: str, run_id: int,
                 attempt: int) -> str:
    return (
        "ios/project/external-execution-receipts/"
        f"android-oracle-{scenario}-{source_digest}-{run_id}-{attempt}.json"
    )


class GitHubOracleReceiptSettler:
    def __init__(self, root: Path, *, repository: str, scenario: str,
                 source_digest: str, run_id: int, attempt: int,
                 branch: str | None = None, runner: Runner | None = None,
                 gh: Path | None = None,
                 now: Callable[[], dt.datetime] | None = None,
                 max_file_bytes: int = MAX_FILE_BYTES):
        self.root = root.resolve(strict=True)
        self.identity = execution_identity(
            repository=repository, workflow_path=WORKFLOW_PATH,
            scenario=scenario, source_digest=source_digest, remote="origin")
        if isinstance(run_id, bool) or not isinstance(run_id, int) or run_id < 1:
            raise GitHubOracleReceiptError("GITHUB_RUN_ID_INVALID")
        if isinstance(attempt, bool) or not isinstance(attempt, int) or attempt < 1:
            raise GitHubOracleReceiptError("GITHUB_RUN_ATTEMPT_INVALID")
        if branch is not None and branch != self.identity.branch:
            raise GitHubOracleReceiptError("GITHUB_RUN_BRANCH_INVALID")
        self.run_id = run_id
        self.attempt = attempt
        self.runner = runner or self._run
        discovered_gh = shutil.which("gh") if gh is None else str(gh)
        if not discovered_gh:
            raise GitHubOracleReceiptError("GH_EXECUTABLE_INVALID")
        candidate_gh = Path(discovered_gh)
        try:
            resolved_gh = candidate_gh.resolve(strict=True)
            resolved_metadata = resolved_gh.stat()
        except (OSError, RuntimeError) as error:
            raise GitHubOracleReceiptError("GH_EXECUTABLE_INVALID") from error
        if (
            not stat.S_ISREG(resolved_metadata.st_mode)
            or not os.access(resolved_gh, os.X_OK)
        ):
            raise GitHubOracleReceiptError("GH_EXECUTABLE_INVALID")
        self.gh = resolved_gh
        self.now = now or (lambda: dt.datetime.now(dt.timezone.utc))
        self.max_file_bytes = max_file_bytes

    @staticmethod
    def _run(argv: Sequence[str], cwd: Path) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(list(argv), cwd=cwd, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=120, check=False)

    def _command(self, argv: Sequence[str], cwd: Path, reason: str,
                 *, max_output: int = 16 * 1024 * 1024) -> bytes:
        try:
            result = self.runner(tuple(argv), cwd)
        except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
            raise GitHubOracleReceiptError(reason) from error
        stdout = result.stdout or b""
        if isinstance(stdout, str):
            try:
                stdout = stdout.encode("utf-8")
            except UnicodeError as error:
                raise GitHubOracleReceiptError(reason) from error
        if result.returncode != 0 or len(stdout) > max_output:
            raise GitHubOracleReceiptError(reason)
        return stdout

    def _json(self, argv: Sequence[str], reason: str) -> Any:
        raw = self._command(argv, self.root, reason)
        try:
            return json.loads(raw)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubOracleReceiptError(reason) from error

    def _git(self, *args: str, cwd: Path | None = None) -> str:
        raw = self._command(("git", *args), cwd or self.root,
                            "GIT_BINDING_FAILED")
        try:
            return raw.decode("ascii").strip()
        except UnicodeDecodeError as error:
            raise GitHubOracleReceiptError("GIT_BINDING_FAILED") from error

    def _verify_run(self) -> Mapping[str, Any]:
        values = self._json((
            str(self.gh), "run", "list", "--repo", self.identity.repository,
            "--workflow", WORKFLOW_PATH, "--branch", self.identity.branch,
            "--event", "push", "--limit", "2", "--json",
            "databaseId,attempt,status,conclusion,url,headSha,headBranch,event",
        ), "GITHUB_RUN_LOOKUP_FAILED")
        fields = {"databaseId", "attempt", "status", "conclusion", "url",
                  "headSha", "headBranch", "event"}
        if (not isinstance(values, list) or len(values) != 1
                or not isinstance(values[0], dict)):
            raise GitHubOracleReceiptError("GITHUB_RUN_NOT_UNIQUE")
        value = values[0]
        if (set(value) != fields
                or value["databaseId"] != self.run_id
                or value["attempt"] != self.attempt
                or value["status"] != "completed"
                or value["conclusion"] != "success"
                or value["headSha"] != self.identity.source_digest
                or value["headBranch"] != self.identity.branch
                or value["event"] != "push"
                or not isinstance(value["url"], str) or not value["url"]):
            raise GitHubOracleReceiptError("GITHUB_RUN_BINDING_DRIFT")
        return value

    def _verify_artifact(self) -> Mapping[str, Any]:
        payload = self._json((
            str(self.gh), "api", "--method", "GET",
            f"repos/{self.identity.repository}/actions/runs/{self.run_id}/artifacts",
            "-f", "per_page=100",
        ), "GITHUB_ARTIFACT_LOOKUP_FAILED")
        expected = (
            f"android-oracle-candidate-{self.identity.scenario}-"
            f"{self.run_id}-{self.attempt}"
        )
        if not isinstance(payload, dict) or not isinstance(
                payload.get("artifacts"), list):
            raise GitHubOracleReceiptError("GITHUB_ARTIFACT_RESPONSE_INVALID")
        matches = [x for x in payload["artifacts"]
                   if isinstance(x, dict) and x.get("name") == expected]
        if len(matches) != 1:
            raise GitHubOracleReceiptError("GITHUB_ARTIFACT_NOT_UNIQUE")
        artifact = matches[0]
        provenance = artifact.get("workflow_run")
        if (artifact.get("expired") is not False
                or isinstance(artifact.get("id"), bool)
                or not isinstance(artifact.get("id"), int)
                or artifact["id"] < 1
                or isinstance(artifact.get("size_in_bytes"), bool)
                or not isinstance(artifact.get("size_in_bytes"), int)
                or artifact["size_in_bytes"] < 1
                or artifact["size_in_bytes"] > self.max_file_bytes * 5
                or not isinstance(provenance, dict)
                or provenance.get("id") != self.run_id
                or provenance.get("head_sha") != self.identity.source_digest
                or provenance.get("head_branch") != self.identity.branch):
            raise GitHubOracleReceiptError("GITHUB_ARTIFACT_INVALID")
        return artifact

    def _fixture_path(self, reference: str) -> str:
        manifest_path = "ios/harness/fixtures/manifest.json"
        try:
            manifest = json.loads(
                self._git("show", f"{reference}:{manifest_path}")
            )
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubOracleReceiptError("AUTHORITY_TREE_INVALID") from error
        matches = [
            entry
            for entry in manifest.get("fixtures", [])
            if isinstance(entry, dict)
            and entry.get("id") == self.identity.scenario
        ] if isinstance(manifest, dict) else []
        if len(matches) != 1 or not isinstance(matches[0].get("path"), str):
            raise GitHubOracleReceiptError("AUTHORITY_TREE_INVALID")
        fixture = str(matches[0]["path"])
        allowed = {
            f"ios/harness/fixtures/source-lab/{self.identity.scenario}",
            f"ios/harness/fixtures/runtime-lab/{self.identity.scenario}",
            f"ios/harness/fixtures/real-source/{self.identity.scenario}",
            (
                "ios/harness/fixtures/integration-lab/"
                f"{self.identity.scenario}"
            ),
        }
        if fixture not in allowed:
            raise GitHubOracleReceiptError("AUTHORITY_TREE_INVALID")
        return fixture

    def _authority_paths(self, source: str) -> tuple[str, ...]:
        fixture = self._fixture_path("HEAD")
        if fixture != self._fixture_path(source):
            raise GitHubOracleReceiptError("AUTHORITY_TREE_INVALID")
        current_files = tuple(x for x in self._git(
            "ls-tree", "-r", "--name-only", "HEAD", "--", fixture
        ).splitlines() if x)
        source_files = tuple(x for x in self._git(
            "ls-tree", "-r", "--name-only", source, "--", fixture
        ).splitlines() if x)
        if not current_files or current_files != source_files:
            raise GitHubOracleReceiptError("AUTHORITY_TREE_INVALID")
        return (*AUTHORITY_PATHS, *current_files)

    def _verify_source(self) -> dict[str, str]:
        source = self.identity.source_digest
        if self._git("merge-base", "--is-ancestor", source, "HEAD") != "":
            # merge-base --is-ancestor succeeds with empty stdout.
            raise GitHubOracleReceiptError("SOURCE_NOT_ANCESTOR")
        bindings: dict[str, str] = {}
        for path in self._authority_paths(source):
            current = self._git("rev-parse", f"HEAD:{path}")
            historical = self._git("rev-parse", f"{source}:{path}")
            if current != historical or not HEX40.fullmatch(current):
                raise GitHubOracleReceiptError("AUTHORITY_TREE_DRIFT")
            bindings[path] = current
        return bindings

    def _download(self, directory: Path, artifact: Mapping[str, Any]) -> dict[str, str]:
        self._command((
            str(self.gh), "run", "download", str(self.run_id), "--repo",
            self.identity.repository, "--name", str(artifact["name"]),
            "--dir", str(directory),
        ), self.root, "GITHUB_ARTIFACT_DOWNLOAD_FAILED", max_output=1024 * 1024)
        found: set[str] = set()
        try:
            for entry in directory.iterdir():
                metadata = entry.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(
                        metadata.st_mode):
                    raise GitHubOracleReceiptError("ARTIFACT_FILE_INVALID")
                found.add(entry.name)
                if metadata.st_size > self.max_file_bytes:
                    raise GitHubOracleReceiptError("ARTIFACT_FILE_TOO_LARGE")
        except GitHubOracleReceiptError:
            raise
        except (OSError, UnicodeError) as error:
            raise GitHubOracleReceiptError("ARTIFACT_IO_FAILED") from error
        if found != EXPECTED_FILES:
            raise GitHubOracleReceiptError("ARTIFACT_FILE_SET_INVALID")
        try:
            sums = (directory / "SHA256SUMS").read_text(encoding="ascii")
        except (OSError, UnicodeError) as error:
            raise GitHubOracleReceiptError("SHA256SUMS_INVALID") from error
        expected: dict[str, str] = {}
        for line in sums.splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
            if not match or match.group(2) == "SHA256SUMS":
                raise GitHubOracleReceiptError("SHA256SUMS_INVALID")
            if match.group(2) in expected:
                raise GitHubOracleReceiptError("SHA256SUMS_INVALID")
            expected[match.group(2)] = match.group(1)
        if set(expected) != EXPECTED_FILES - {"SHA256SUMS"}:
            raise GitHubOracleReceiptError("SHA256SUMS_INVALID")
        try:
            digests = {name: _sha((directory / name).read_bytes())
                       for name in EXPECTED_FILES}
        except OSError as error:
            raise GitHubOracleReceiptError("ARTIFACT_IO_FAILED") from error
        if any(digests[name] != digest for name, digest in expected.items()):
            raise GitHubOracleReceiptError("ARTIFACT_DIGEST_DRIFT")
        return digests

    def _trusted_import(self, worktree: Path, artifact_dir: Path) -> Mapping[str, Any]:
        argv = (
            "python3", "-B", "ios/harness/oracle/trusted_import.py", "verify",
            "--root", ".", "--proposal-archive",
            str(artifact_dir / "android-oracle-proposal.tar"),
            "--proposal-attestation-bundle",
            str(artifact_dir / "proposal-attestation.json"),
            "--evidence-archive", str(artifact_dir / "android-oracle-evidence.tar"),
            "--evidence-attestation-bundle",
            str(artifact_dir / "evidence-attestation.json"),
            "--repository", self.identity.repository, "--gh", str(self.gh),
            "--scenario", self.identity.scenario,
        )
        raw = self._command(argv, worktree, "TRUSTED_IMPORT_FAILED")
        try:
            report = json.loads(raw)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise GitHubOracleReceiptError("TRUSTED_IMPORT_REPORT_INVALID") from error
        required = {
            "authority": "candidate_only",
            "status": "verified_for_human_review",
            "repository": self.identity.repository,
            "source_digest": self.identity.source_digest,
            "scenario_id": self.identity.scenario,
            "next_authority": "independent_golden_publisher",
        }
        if (not isinstance(report, dict)
                or any(report.get(k) != v for k, v in required.items())
                or report.get("fixture_ids") != [self.identity.scenario]):
            raise GitHubOracleReceiptError("TRUSTED_IMPORT_REPORT_INVALID")
        return report

    def settle(self) -> Mapping[str, Any]:
        run = self._verify_run()
        artifact = self._verify_artifact()
        authority = self._verify_source()
        with tempfile.TemporaryDirectory(prefix="legado-oracle-receipt-") as temp:
            private = Path(temp)
            os.chmod(private, 0o700)
            artifact_dir = private / "artifact"
            artifact_dir.mkdir(mode=0o700)
            digests = self._download(artifact_dir, artifact)
            worktree = private / "source"
            self._git("worktree", "add", "--detach", str(worktree),
                      self.identity.source_digest)
            try:
                report = self._trusted_import(worktree, artifact_dir)
            finally:
                try:
                    self._git("worktree", "remove", "--force", str(worktree))
                except GitHubOracleReceiptError as error:
                    raise GitHubOracleReceiptError("CLEANUP_FAILED") from error
        report_sha = _sha(_canonical(report)[:-1])
        receipt = {
            "schema_version": 1,
            "authority": "verified_candidate",
            "next_authority": "independent_golden_publisher",
            "repository": self.identity.repository,
            "workflow_path": WORKFLOW_PATH,
            "scenario_id": self.identity.scenario,
            "source_digest": self.identity.source_digest,
            "branch": self.identity.branch,
            "run": {"id": self.run_id, "attempt": self.attempt,
                    "url": run["url"], "event": "push"},
            "artifact": {"id": artifact["id"], "name": artifact["name"],
                         "sha256sums_sha256": digests["SHA256SUMS"]},
            "files": {name: digests[name] for name in sorted(
                EXPECTED_FILES - {"SHA256SUMS"})},
            "trusted_report": dict(report),
            "trusted_report_sha256": report_sha,
            "authority_tree": authority,
        }
        destination = self.root / receipt_path(
            self.identity.scenario, self.identity.source_digest,
            self.run_id, self.attempt)
        payload = _canonical(receipt)
        self._prepare_receipt_parent(destination.parent)
        try:
            exists = destination.exists() or destination.is_symlink()
        except OSError as error:
            raise GitHubOracleReceiptError("RECEIPT_IO_FAILED") from error
        if exists:
            try:
                matches = (
                    not destination.is_symlink()
                    and destination.is_file()
                    and destination.read_bytes() == payload
                )
            except OSError as error:
                raise GitHubOracleReceiptError("RECEIPT_IO_FAILED") from error
            if not matches:
                raise GitHubOracleReceiptError("RECEIPT_CONFLICT")
            return receipt
        try:
            descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                                 0o600)
        except FileExistsError:
            try:
                matches = (
                    not destination.is_symlink()
                    and destination.is_file()
                    and destination.read_bytes() == payload
                )
            except OSError as error:
                raise GitHubOracleReceiptError("RECEIPT_IO_FAILED") from error
            if not matches:
                raise GitHubOracleReceiptError("RECEIPT_CONFLICT")
            return receipt
        except OSError as error:
            raise GitHubOracleReceiptError("RECEIPT_IO_FAILED") from error
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
        except OSError as error:
            raise GitHubOracleReceiptError("RECEIPT_IO_FAILED") from error
        return receipt

    def _prepare_receipt_parent(self, parent: Path) -> None:
        try:
            relative = parent.relative_to(self.root)
        except ValueError as error:
            raise GitHubOracleReceiptError("RECEIPT_PATH_INVALID") from error
        cursor = self.root
        try:
            for component in relative.parts:
                cursor = cursor / component
                if cursor.exists() or cursor.is_symlink():
                    if cursor.is_symlink() or not cursor.is_dir():
                        raise GitHubOracleReceiptError(
                            "RECEIPT_PATH_INVALID"
                        )
                else:
                    cursor.mkdir(mode=0o700)
            if parent.resolve(strict=True) != parent:
                raise GitHubOracleReceiptError("RECEIPT_PATH_INVALID")
        except GitHubOracleReceiptError:
            raise
        except (OSError, RuntimeError) as error:
            raise GitHubOracleReceiptError("RECEIPT_PATH_INVALID") from error


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--source-digest", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--attempt", type=int, required=True)
    args = parser.parse_args(argv)
    result = GitHubOracleReceiptSettler(
        args.root, repository=args.repository, scenario=args.scenario,
        source_digest=args.source_digest, run_id=args.run_id,
        attempt=args.attempt).settle()
    print(_canonical(result).decode(), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GitHubOracleReceiptError as error:
        print(json.dumps({"schema_version": 1, "ok": False,
                          "reason_code": str(error)}, sort_keys=True,
                         separators=(",", ":")))
        raise SystemExit(2)
