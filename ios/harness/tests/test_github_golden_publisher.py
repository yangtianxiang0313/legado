import datetime as dt
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from ios.harness.github_golden_publisher import (
        AUTHORIZATION,
        PROFILE,
        PUBLISHER,
        WORKFLOW_PATH,
        GitHubGoldenPublisherDispatcher,
        GitHubGoldenPublisherError,
        golden_execution_identity,
    )
except ImportError:
    from github_golden_publisher import (  # type: ignore
        AUTHORIZATION,
        PROFILE,
        PUBLISHER,
        WORKFLOW_PATH,
        GitHubGoldenPublisherDispatcher,
        GitHubGoldenPublisherError,
        golden_execution_identity,
    )


SCENARIO = "sl-post-form-001"
REPOSITORY = "owner/legado"
SOURCE_SHA = "a" * 40
PROPOSAL_SHA = "b" * 64
RUNNER_SHA = "c" * 64
CANONICALIZER_SHA = "d" * 64
ANDROID_SHA = "e" * 40
ORACLE_RUN_ID = 41
ORACLE_ATTEMPT = 2
PUBLISHER_RUN_ID = 71
PUBLISHER_ATTEMPT = 1


def canonical(value):
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        + b"\n"
    )


def sha256(payload):
    return hashlib.sha256(payload).hexdigest()


class GoldenRepository:
    def __init__(self, root):
        self.root = root
        self.remote = root.parent / "remote.git"
        subprocess.run(
            ["git", "init", "-q", "--bare", str(self.remote)],
            check=True,
        )
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("remote", "add", "origin", str(self.remote))
        self.write(".gitignore", b".harness-runtime/\n")
        self.receipt_path = (
            "ios/project/external-execution-receipts/"
            f"android-oracle-{SCENARIO}-{SOURCE_SHA}-"
            f"{ORACLE_RUN_ID}-{ORACLE_ATTEMPT}.json"
        )
        self.receipt = {
            "schema_version": 1,
            "authority": "verified_candidate",
            "next_authority": "independent_golden_publisher",
            "repository": REPOSITORY,
            "workflow_path": (
                ".github/workflows/android-oracle-attestation.yml"
            ),
            "scenario_id": SCENARIO,
            "source_digest": SOURCE_SHA,
            "run": {
                "id": ORACLE_RUN_ID,
                "attempt": ORACLE_ATTEMPT,
                "event": "push",
            },
            "trusted_report": {
                "scenario_id": SCENARIO,
                "source_digest": SOURCE_SHA,
                "next_authority": "independent_golden_publisher",
                "proposal_sha256": PROPOSAL_SHA,
            },
        }
        self.write(self.receipt_path, canonical(self.receipt))
        self.write(
            "ios/harness/goldens/manifest.json",
            canonical(
                {
                    "schema_version": 1,
                    "oracle": {
                        "android_git_commit": ANDROID_SHA,
                        "profile": PROFILE,
                        "runner_digest": RUNNER_SHA,
                        "runner_image_digest": "sha256:image",
                    },
                    "canonicalizer_sha256": CANONICALIZER_SHA,
                    "fixtures": {},
                }
            ),
        )
        self.git("add", ".")
        self.git("commit", "-qm", "request")
        self.request_sha = self.git("rev-parse", "HEAD").stdout.strip()
        self.receipt_sha = sha256(canonical(self.receipt))
        self.identity = golden_execution_identity(
            repository=REPOSITORY,
            workflow_path=WORKFLOW_PATH,
            scenario=SCENARIO,
            request_sha=self.request_sha,
            receipt_path=self.receipt_path,
            receipt_sha256=self.receipt_sha,
            remote="origin",
        )
        self.golden_path = (
            f"ios/harness/goldens/{PROFILE}/{SCENARIO}.json"
        )
        self.manifest_path = "ios/harness/goldens/manifest.json"
        self.release_path = (
            "ios/harness/goldens/releases/"
            f"{SCENARIO}-{ORACLE_RUN_ID}-{ORACLE_ATTEMPT}.json"
        )
        self.golden = canonical(
            {
                "schema_version": 1,
                "fixture_id": SCENARIO,
                "result": {"books": [{"name": "真实结果"}]},
            }
        )
        shared = {
            "proposal_archive_sha256": "1" * 64,
            "evidence_archive_sha256": "2" * 64,
            "proposal_attestation_sha256": "3" * 64,
            "evidence_attestation_sha256": "4" * 64,
        }
        self.entry = {
            "path": self.golden_path,
            "fixture_sha256": "5" * 64,
            "golden_sha256": sha256(self.golden),
            "operation": "source_lab_site",
            "proposal_sha256": PROPOSAL_SHA,
            **shared,
            "source_digest": SOURCE_SHA,
            "run_id": f"{ORACLE_RUN_ID}/{ORACLE_ATTEMPT}",
            "android_git_commit": ANDROID_SHA,
            "profile": PROFILE,
            "runner_digest": RUNNER_SHA,
            "runner_image_digest": "sha256:image",
            "canonicalizer_sha256": CANONICALIZER_SHA,
            "authorization": AUTHORIZATION,
            "release_receipt": self.release_path,
        }
        self.manifest = canonical(
            {
                "schema_version": 2,
                "oracle": {
                    "android_git_commit": ANDROID_SHA,
                    "profile": PROFILE,
                },
                "canonicalizer_sha256": CANONICALIZER_SHA,
                "fixtures": {SCENARIO: self.entry},
            }
        )
        self.release = canonical(
            {
                "schema_version": 2,
                "kind": "android_golden_release",
                "authority": "protected_android_golden",
                "publisher": PUBLISHER,
                "repository": REPOSITORY,
                "fixture_id": SCENARIO,
                "run_id": f"{ORACLE_RUN_ID}/{ORACLE_ATTEMPT}",
                "source_digest": SOURCE_SHA,
                "proposal_sha256": PROPOSAL_SHA,
                **shared,
                "golden_sha256": sha256(self.golden),
                "golden_path": self.golden_path,
                "previous_authority": "candidate_only",
                "authorization": AUTHORIZATION,
                "controls": {
                    "android_git_commit": ANDROID_SHA,
                    "profile": PROFILE,
                    "runner_digest": RUNNER_SHA,
                    "runner_image_digest": "sha256:image",
                    "canonicalizer_sha256": CANONICALIZER_SHA,
                },
            }
        )
        self.write(self.golden_path, self.golden)
        self.write(self.manifest_path, self.manifest)
        self.write(self.release_path, self.release)
        self.git("add", ".")
        self.git("commit", "-qm", "golden result")
        self.result_commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.git(
            "push",
            "-q",
            "origin",
            (
                f"{self.result_commit}:"
                f"refs/heads/{self.identity.result_branch}"
            ),
        )
        self.git("reset", "--hard", "-q", self.request_sha)
        self.report = {
            "schema_version": 1,
            "status": "published",
            "scenario_id": SCENARIO,
            "request_branch": self.identity.request_branch,
            "request_sha": self.request_sha,
            "result_branch": self.identity.result_branch,
            "result_commit": self.result_commit,
            "publisher_run": {
                "id": PUBLISHER_RUN_ID,
                "attempt": PUBLISHER_ATTEMPT,
            },
            "oracle_run": {
                "id": ORACLE_RUN_ID,
                "attempt": ORACLE_ATTEMPT,
            },
            "receipt": {
                "path": self.receipt_path,
                "sha256": self.receipt_sha,
            },
            "golden_sha256": sha256(self.golden),
            "manifest_sha256": sha256(self.manifest),
            "release_receipt_sha256": sha256(self.release),
            "files": {
                self.golden_path: sha256(self.golden),
                self.manifest_path: sha256(self.manifest),
                self.release_path: sha256(self.release),
            },
        }

    def git(self, *args):
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def write(self, relative, payload):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)


class HybridRunner:
    def __init__(
        self,
        fixture,
        *,
        report=None,
        checksum_valid=True,
        no_runs=False,
        duplicate_run=False,
        run_changes=None,
    ):
        self.fixture = fixture
        self.report = fixture.report if report is None else report
        self.checksum_valid = checksum_valid
        self.no_runs = no_runs
        self.duplicate_run = duplicate_run
        self.run_changes = {} if run_changes is None else run_changes
        self.calls = []

    def __call__(self, argv, cwd):
        self.calls.append(tuple(argv))
        if argv[:3] == ("git", "remote", "get-url"):
            return subprocess.CompletedProcess(
                argv,
                0,
                b"git@github.com:owner/legado.git\n",
                b"",
            )
        if argv[:3] == ("gh", "auth", "status"):
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        if argv[:3] == ("gh", "run", "list"):
            run = {
                "databaseId": PUBLISHER_RUN_ID,
                "attempt": PUBLISHER_ATTEMPT,
                "status": "completed",
                "conclusion": "success",
                "url": "https://example.invalid/run/71",
                "headSha": self.fixture.request_sha,
                "headBranch": self.fixture.identity.request_branch,
                "event": "push",
            }
            run.update(self.run_changes)
            runs = [] if self.no_runs else [run]
            if self.duplicate_run:
                runs.append(dict(run, databaseId=PUBLISHER_RUN_ID + 1))
            return subprocess.CompletedProcess(
                argv, 0, json.dumps(runs).encode(), b""
            )
        if argv[:2] == ("gh", "api"):
            target = next(
                (
                    value
                    for value in argv
                    if value.startswith("repos/")
                ),
                "",
            )
            if target.endswith("/artifacts"):
                value = {
                    "total_count": 1,
                    "artifacts": [
                        {
                            "id": 91,
                            "name": (
                                f"android-golden-result-{SCENARIO}-"
                                f"{PUBLISHER_RUN_ID}-{PUBLISHER_ATTEMPT}"
                            ),
                            "expired": False,
                            "workflow_run": {
                                "id": PUBLISHER_RUN_ID,
                                "head_sha": self.fixture.request_sha,
                            },
                        }
                    ],
                }
            else:
                value = {
                    "id": PUBLISHER_RUN_ID,
                    "run_attempt": PUBLISHER_ATTEMPT,
                    "path": WORKFLOW_PATH,
                    "event": "push",
                    "status": "completed",
                    "conclusion": "success",
                    "head_sha": self.fixture.request_sha,
                    "head_branch": self.fixture.identity.request_branch,
                }
            return subprocess.CompletedProcess(
                argv, 0, json.dumps(value).encode(), b""
            )
        if argv[:3] == ("gh", "run", "download"):
            destination = Path(argv[argv.index("--dir") + 1])
            payload = canonical(self.report)
            (destination / "publisher-result.json").write_bytes(payload)
            digest = sha256(payload) if self.checksum_valid else "0" * 64
            (destination / "SHA256SUMS").write_text(
                f"{digest}  publisher-result.json\n"
            )
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        return subprocess.run(
            list(argv),
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


def dispatcher(fixture, runner):
    return GitHubGoldenPublisherDispatcher(
        fixture.root,
        repository=REPOSITORY,
        workflow_path=WORKFLOW_PATH,
        scenario=SCENARIO,
        request_sha=fixture.request_sha,
        receipt_path=fixture.receipt_path,
        receipt_sha256=fixture.receipt_sha,
        remote="origin",
        runner=runner,
        now=lambda: dt.datetime(2026, 7, 29, tzinfo=dt.timezone.utc),
    )


class GitHubGoldenPublisherDispatcherTests(unittest.TestCase):
    def test_identity_binds_every_authoritative_input(self):
        values = {
            "repository": REPOSITORY,
            "workflow_path": WORKFLOW_PATH,
            "scenario": SCENARIO,
            "request_sha": "1" * 40,
            "receipt_path": (
                "ios/project/external-execution-receipts/"
                f"android-oracle-{SCENARIO}-x.json"
            ),
            "receipt_sha256": "2" * 64,
            "remote": "origin",
        }
        first = golden_execution_identity(**values)
        self.assertEqual(first, golden_execution_identity(**values))
        self.assertEqual(
            f"feature/golden-{SCENARIO}-{'1' * 40}",
            first.request_branch,
        )
        self.assertEqual(
            f"golden/result-{SCENARIO}-{'1' * 40}",
            first.result_branch,
        )
        for key, replacement in (
            ("repository", "other/legado"),
            ("request_sha", "3" * 40),
            (
                "receipt_path",
                (
                    "ios/project/external-execution-receipts/"
                    f"android-oracle-{SCENARIO}-other.json"
                ),
            ),
            ("receipt_sha256", "4" * 64),
            ("remote", "upstream"),
        ):
            changed = dict(values)
            changed[key] = replacement
            self.assertNotEqual(
                first.execution_id,
                golden_execution_identity(**changed).execution_id,
            )
        changed_scenario = dict(
            values,
            scenario="sl-other-001",
            receipt_path=(
                "ios/project/external-execution-receipts/"
                "android-oracle-sl-other-001-x.json"
            ),
        )
        self.assertNotEqual(
            first.execution_id,
            golden_execution_identity(**changed_scenario).execution_id,
        )
        with self.assertRaisesRegex(
            GitHubGoldenPublisherError,
            "GOLDEN_RECEIPT_PATH_INVALID",
        ):
            golden_execution_identity(
                **dict(values, receipt_path="../receipt.json")
            )

    def test_success_verifies_remote_artifact_commit_and_fast_forwards(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            runner = HybridRunner(fixture)
            target = dispatcher(fixture, runner)
            result = target.dispatch()
            self.assertEqual("settled", result["outcome"])
            self.assertEqual(fixture.result_commit, result["result_commit"])
            self.assertEqual(
                fixture.result_commit,
                fixture.git("rev-parse", "HEAD").stdout.strip(),
            )
            self.assertEqual("", fixture.git("status", "--short").stdout)
            self.assertTrue(target.journal_path.is_file())
            replay = target.dispatch()
            self.assertEqual("settled", replay["outcome"])
            self.assertEqual(fixture.result_commit, replay["result_commit"])
            self.assertEqual(
                1,
                sum(call[:2] == ("git", "push") for call in runner.calls),
            )

    def test_checksum_and_report_binding_fail_before_fetch_or_merge(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            bad_checksum = HybridRunner(fixture, checksum_valid=False)
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_RESULT_CHECKSUM_INVALID",
            ):
                dispatcher(fixture, bad_checksum).dispatch()
            self.assertEqual(
                fixture.request_sha,
                fixture.git("rev-parse", "HEAD").stdout.strip(),
            )
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            report = dict(fixture.report, request_sha="f" * 40)
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_RESULT_REPORT_INVALID",
            ):
                dispatcher(fixture, HybridRunner(fixture, report=report)).dispatch()
            self.assertEqual(
                fixture.request_sha,
                fixture.git("rev-parse", "HEAD").stdout.strip(),
            )

    def test_request_branch_run_uniqueness_and_journal_are_monotonic(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            runner = HybridRunner(fixture, no_runs=True)
            target = dispatcher(fixture, runner)
            self.assertEqual("dispatched", target.dispatch()["outcome"])
            self.assertEqual("pending", target.dispatch()["outcome"])
            self.assertEqual(
                1,
                sum(call[:2] == ("git", "push") for call in runner.calls),
            )
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            runner = HybridRunner(
                fixture,
                run_changes={
                    "status": "in_progress",
                    "conclusion": "",
                },
            )
            target = dispatcher(fixture, runner)
            self.assertEqual("running", target.dispatch()["outcome"])
            runner.run_changes = {"status": "queued", "conclusion": ""}
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_JOURNAL_RUN_REGRESSION",
            ):
                target.dispatch()
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_DUPLICATE_RUN",
            ):
                dispatcher(
                    fixture,
                    HybridRunner(fixture, duplicate_run=True),
                ).dispatch()
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            fixture.git(
                "push",
                "-q",
                "origin",
                (
                    f"{fixture.result_commit}:"
                    f"refs/heads/{fixture.identity.request_branch}"
                ),
            )
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_REQUEST_BRANCH_CONFLICT",
            ):
                dispatcher(fixture, HybridRunner(fixture)).dispatch()

    def test_receipt_must_be_the_exact_committed_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            fixture.write(fixture.receipt_path, canonical({}))
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_GIT_WORKTREE_DIRTY",
            ):
                dispatcher(fixture, HybridRunner(fixture)).dispatch()
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_RECEIPT_DIGEST_MISMATCH",
            ):
                GitHubGoldenPublisherDispatcher(
                    fixture.root,
                    repository=REPOSITORY,
                    workflow_path=WORKFLOW_PATH,
                    scenario=SCENARIO,
                    request_sha=fixture.request_sha,
                    receipt_path=fixture.receipt_path,
                    receipt_sha256="9" * 64,
                    remote="origin",
                    runner=HybridRunner(fixture),
                ).dispatch()

    def test_manifest_or_release_control_drift_never_merges(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            bad_release = json.loads(fixture.release)
            bad_release["authorization"] = "human"
            fixture.write(fixture.golden_path, fixture.golden)
            fixture.write(fixture.manifest_path, fixture.manifest)
            fixture.write(fixture.release_path, canonical(bad_release))
            fixture.git(
                "add",
                fixture.golden_path,
                fixture.manifest_path,
                fixture.release_path,
            )
            fixture.git("commit", "-qm", "bad result")
            bad_commit = fixture.git("rev-parse", "HEAD").stdout.strip()
            fixture.git(
                "push",
                "-q",
                "--force",
                "origin",
                (
                    f"{bad_commit}:"
                    f"refs/heads/{fixture.identity.result_branch}"
                ),
            )
            fixture.git("reset", "--hard", "-q", fixture.request_sha)
            bad_payload = canonical(bad_release)
            report = dict(fixture.report)
            report["result_commit"] = bad_commit
            report["release_receipt_sha256"] = sha256(bad_payload)
            report["files"] = dict(report["files"])
            report["files"][fixture.release_path] = sha256(bad_payload)
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_RELEASE_RECEIPT_INVALID",
            ):
                dispatcher(
                    fixture,
                    HybridRunner(fixture, report=report),
                ).dispatch()
            self.assertEqual(
                fixture.request_sha,
                fixture.git("rev-parse", "HEAD").stdout.strip(),
            )

    def test_result_must_be_single_child_with_exact_three_file_delta(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            fixture.write(fixture.golden_path, fixture.golden)
            fixture.write(fixture.manifest_path, fixture.manifest)
            fixture.write(fixture.release_path, fixture.release)
            fixture.write("unexpected.txt", b"not-authorized\n")
            fixture.git("add", ".")
            fixture.git("commit", "-qm", "extra result")
            bad_commit = fixture.git("rev-parse", "HEAD").stdout.strip()
            fixture.git(
                "push",
                "-q",
                "--force",
                "origin",
                (
                    f"{bad_commit}:"
                    f"refs/heads/{fixture.identity.result_branch}"
                ),
            )
            fixture.git("reset", "--hard", "-q", fixture.request_sha)
            report = dict(fixture.report, result_commit=bad_commit)
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_RESULT_DELTA_INVALID",
            ):
                dispatcher(
                    fixture,
                    HybridRunner(fixture, report=report),
                ).dispatch()
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenRepository(Path(directory) / "repo")
            fixture.git("checkout", "-q", "--detach", fixture.result_commit)
            fixture.write(fixture.golden_path, fixture.golden + b" ")
            fixture.git("add", fixture.golden_path)
            fixture.git("commit", "-qm", "not direct child")
            bad_commit = fixture.git("rev-parse", "HEAD").stdout.strip()
            fixture.git(
                "push",
                "-q",
                "--force",
                "origin",
                (
                    f"{bad_commit}:"
                    f"refs/heads/{fixture.identity.result_branch}"
                ),
            )
            fixture.git("checkout", "-q", "--detach", fixture.request_sha)
            report = dict(fixture.report, result_commit=bad_commit)
            with self.assertRaisesRegex(
                GitHubGoldenPublisherError,
                "GOLDEN_RESULT_PARENT_INVALID",
            ):
                dispatcher(
                    fixture,
                    HybridRunner(fixture, report=report),
                ).dispatch()


if __name__ == "__main__":
    unittest.main()
