import datetime as dt
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from ios.harness.github_oracle_dispatcher import (
        GitHubOracleDispatcher,
        GitHubOracleError,
        WORKFLOW_PATH,
        execution_identity,
    )
except ImportError:
    from github_oracle_dispatcher import (  # type: ignore
        GitHubOracleDispatcher,
        GitHubOracleError,
        WORKFLOW_PATH,
        execution_identity,
    )


SOURCE = "a" * 40


class FakeRunner:
    def __init__(self, *, branch="", runs=None):
        self.branch = branch
        self.runs = [] if runs is None else runs
        self.calls = []

    def __call__(self, argv):
        self.calls.append(tuple(argv))
        if argv[:3] == ("git", "status", "--porcelain=v1"):
            output = ""
        elif argv[:3] == ("git", "rev-parse", "HEAD"):
            output = SOURCE
        elif argv[:3] == ("git", "remote", "get-url"):
            output = "git@github.com:owner/legado.git"
        elif argv[:3] == ("git", "ls-remote", "--heads"):
            output = self.branch
        elif argv[:2] == ("git", "push"):
            ref = argv[3].split(":", 1)[1]
            self.branch = f"{SOURCE}\t{ref}"
            output = ""
        elif argv[:3] == ("gh", "run", "list"):
            output = json.dumps(self.runs)
        else:
            output = ""
        return subprocess.CompletedProcess(argv, 0, output, "")


def dispatcher(root, runner):
    return GitHubOracleDispatcher(
        root, repository="owner/legado", workflow_path=WORKFLOW_PATH,
        scenario="sl-post-form-001", source_digest=SOURCE, remote="origin",
        runner=runner,
        now=lambda: dt.datetime(2026, 7, 28, tzinfo=dt.timezone.utc),
    )


class GitHubOracleDispatcherTests(unittest.TestCase):
    def test_identity_is_stable_and_all_inputs_are_bound(self):
        values = dict(repository="owner/legado", workflow_path=WORKFLOW_PATH,
                      scenario="sl-post-form-001", source_digest=SOURCE,
                      remote="origin")
        first = execution_identity(**values)
        self.assertEqual(first, execution_identity(**values))
        self.assertTrue(first.branch.startswith("feature/oracle-sl-post-form-001-"))
        for key, replacement in (
            ("repository", "other/legado"), ("scenario", "sl-other-001"),
            ("source_digest", "b" * 40), ("remote", "upstream"),
        ):
            changed = dict(values)
            changed[key] = replacement
            self.assertNotEqual(first.execution_id,
                                execution_identity(**changed).execution_id)

    def test_schema_and_workflow_allowlist_fail_closed(self):
        with self.assertRaises(GitHubOracleError):
            execution_identity(repository="legado", workflow_path=WORKFLOW_PATH,
                               scenario="x", source_digest=SOURCE, remote="origin")
        with self.assertRaises(GitHubOracleError):
            execution_identity(repository="owner/legado", workflow_path="other.yml",
                               scenario="x", source_digest=SOURCE, remote="origin")
        with self.assertRaises(GitHubOracleError):
            execution_identity(repository="owner/legado", workflow_path=WORKFLOW_PATH,
                               scenario="../x", source_digest=SOURCE, remote="origin")

    def test_first_call_pushes_and_dispatches_once_then_recovers_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeRunner()
            target = dispatcher(Path(directory), fake)
            self.assertEqual("dispatched", target.dispatch()["outcome"])
            self.assertEqual(1, sum(call[:3] == ("git", "push", "origin")
                                    for call in fake.calls))
            self.assertEqual(1, sum(call[:3] == ("gh", "workflow", "run")
                                    for call in fake.calls))
            fake.calls.clear()
            self.assertEqual("pending", target.dispatch()["outcome"])
            self.assertFalse(any(call[:3] == ("gh", "workflow", "run")
                                 for call in fake.calls))

    def test_existing_branch_and_run_are_reused(self):
        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        run = {"databaseId": 42, "attempt": 1, "status": "completed",
               "conclusion": "success", "url": "https://example.invalid/42",
               "headSha": SOURCE, "headBranch": identity.branch}
        branch = f"{SOURCE}\trefs/heads/{identity.branch}"
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeRunner(branch=branch, runs=[run])
            result = dispatcher(Path(directory), fake).dispatch()
            self.assertEqual("succeeded", result["outcome"])
            self.assertEqual(42, result["run"]["id"])
            self.assertFalse(any(call[:2] == ("git", "push") for call in fake.calls))

    def test_branch_conflict_duplicate_run_and_head_drift_fail_closed(self):
        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeRunner(branch=f"{'b' * 40}\trefs/heads/{identity.branch}")
            with self.assertRaisesRegex(GitHubOracleError, "REMOTE_BRANCH_CONFLICT"):
                dispatcher(Path(directory), fake).dispatch()
        base = {"databaseId": 1, "attempt": 1, "status": "queued",
                "conclusion": "", "url": "u", "headSha": SOURCE,
                "headBranch": identity.branch}
        for runs, message in (([base, dict(base, databaseId=2)],
                               "DUPLICATE_REMOTE_RUN"),
                              ([dict(base, headSha="b" * 40)],
                               "GITHUB_RUN_BINDING_DRIFT")):
            with tempfile.TemporaryDirectory() as directory:
                fake = FakeRunner(
                    branch=f"{SOURCE}\trefs/heads/{identity.branch}", runs=runs)
                with self.assertRaisesRegex(GitHubOracleError, message):
                    dispatcher(Path(directory), fake).dispatch()

    def test_journal_rejects_terminal_rewrite(self):
        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        run = {"databaseId": 7, "attempt": 1, "status": "completed",
               "conclusion": "success", "url": "u", "headSha": SOURCE,
               "headBranch": identity.branch}
        branch = f"{SOURCE}\trefs/heads/{identity.branch}"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dispatcher(root, FakeRunner(branch=branch, runs=[run])).dispatch()
            changed = dict(run, conclusion="failure")
            with self.assertRaisesRegex(
                    GitHubOracleError, "JOURNAL_TERMINAL_REWRITE"):
                dispatcher(root, FakeRunner(branch=branch, runs=[changed])).dispatch()


if __name__ == "__main__":
    unittest.main()
