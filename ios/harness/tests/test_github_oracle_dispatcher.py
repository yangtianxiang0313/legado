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
    def __init__(self, *, branch="", runs=None, failures=None,
                 status="", head=SOURCE,
                 remote_url="git@github.com:owner/legado.git"):
        self.branch = branch
        self.runs = [] if runs is None else runs
        self.failures = {} if failures is None else failures
        self.status = status
        self.head = head
        self.remote_url = remote_url
        self.calls = []

    def __call__(self, argv):
        self.calls.append(tuple(argv))
        failure = self.failures.get(tuple(argv[:3]))
        if failure:
            return subprocess.CompletedProcess(argv, 1, "secret stdout", failure)
        if argv[:3] == ("git", "status", "--porcelain=v1"):
            output = self.status
        elif argv[:3] == ("git", "rev-parse", "HEAD"):
            output = self.head
        elif argv[:3] == ("git", "remote", "get-url"):
            output = self.remote_url
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
    @staticmethod
    def make_run(identity, **changes):
        value = {
            "databaseId": 42, "attempt": 1, "status": "queued",
            "conclusion": "", "url": "https://example.invalid/42",
            "headSha": SOURCE, "headBranch": identity.branch, "event": "push",
        }
        value.update(changes)
        return value

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

    def test_first_push_is_only_creation_then_existing_branch_is_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeRunner()
            target = dispatcher(Path(directory), fake)
            self.assertEqual("dispatched", target.dispatch()["outcome"])
            self.assertEqual(1, sum(call[:3] == ("git", "push", "origin")
                                    for call in fake.calls))
            self.assertEqual(1, sum(call[:3] == ("gh", "run", "list")
                                    for call in fake.calls))
            fake.calls.clear()
            self.assertEqual("pending", target.dispatch()["outcome"])
            self.assertFalse(any(call[:2] == ("git", "push") for call in fake.calls))
            query = next(call for call in fake.calls
                         if call[:3] == ("gh", "run", "list"))
            self.assertIn("push", query)
            self.assertIn("2", query)
            self.assertNotIn("workflow_dispatch", query)

    def test_existing_branch_and_run_are_reused(self):
        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        run = self.make_run(identity, status="completed", conclusion="success")
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
        base = self.make_run(identity, databaseId=1)
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
        run = self.make_run(identity, databaseId=7, status="completed",
                       conclusion="success")
        branch = f"{SOURCE}\trefs/heads/{identity.branch}"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dispatcher(root, FakeRunner(branch=branch, runs=[run])).dispatch()
            changed = dict(run, conclusion="failure")
            with self.assertRaisesRegex(
                    GitHubOracleError, "JOURNAL_TERMINAL_REWRITE"):
                dispatcher(root, FakeRunner(branch=branch, runs=[changed])).dispatch()

    def test_run_states_map_and_response_drift_fails_closed(self):
        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        branch = f"{SOURCE}\trefs/heads/{identity.branch}"
        cases = (
            ({"status": "queued"}, "pending"),
            ({"status": "in_progress"}, "running"),
            ({"status": "completed", "conclusion": "success"}, "succeeded"),
            ({"status": "completed", "conclusion": "failure"}, "failed"),
        )
        for changes, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                run = self.make_run(identity, **changes)
                self.assertEqual(
                    expected,
                    dispatcher(Path(directory),
                               FakeRunner(branch=branch, runs=[run])).dispatch()["outcome"])
        invalid = (
            self.make_run(identity, event="workflow_dispatch"),
            self.make_run(identity, databaseId=True),
            self.make_run(identity, attempt=0),
            self.make_run(identity, status="waiting"),
            self.make_run(identity, conclusion="success"),
            self.make_run(identity, status="completed", conclusion=""),
            dict(self.make_run(identity), unexpected="field"),
        )
        for run in invalid:
            with self.subTest(run=run), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(GitHubOracleError):
                    dispatcher(Path(directory),
                               FakeRunner(branch=branch, runs=[run])).dispatch()

    def test_invalid_json_preflight_and_errors_are_stable(self):
        class InvalidJSON(FakeRunner):
            def __call__(self, argv):
                result = super().__call__(argv)
                if argv[:3] == ("gh", "run", "list"):
                    return subprocess.CompletedProcess(argv, 0, "{token", "")
                return result

        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        branch = f"{SOURCE}\trefs/heads/{identity.branch}"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(GitHubOracleError,
                                        "^GITHUB_RUN_RESPONSE_INVALID$"):
                dispatcher(Path(directory),
                           InvalidJSON(branch=branch)).dispatch()
        cases = (
            (FakeRunner(status="dirty"), "GIT_WORKTREE_DIRTY"),
            (FakeRunner(head="b" * 40), "EXTERNAL_EXECUTION_HEAD_MISMATCH"),
            (FakeRunner(remote_url="git@github.com:other/repo.git"),
             "EXTERNAL_EXECUTION_REMOTE_REPOSITORY_MISMATCH"),
            (FakeRunner(failures={("gh", "auth", "status"): "token=secret"}),
             "GITHUB_AUTH_REQUIRED"),
        )
        for fake, code in cases:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(GitHubOracleError, f"^{code}$") as caught:
                    dispatcher(Path(directory), fake).dispatch()
                self.assertNotIn("secret", str(caught.exception))

    def test_journal_rejects_run_disappearance_id_attempt_and_status_regression(self):
        identity = execution_identity(
            repository="owner/legado", workflow_path=WORKFLOW_PATH,
            scenario="sl-post-form-001", source_digest=SOURCE, remote="origin")
        branch = f"{SOURCE}\trefs/heads/{identity.branch}"
        initial = self.make_run(identity, databaseId=7, attempt=2,
                           status="in_progress")
        regressions = (
            [],
            [self.make_run(identity, databaseId=8, attempt=2, status="in_progress")],
            [self.make_run(identity, databaseId=7, attempt=1, status="in_progress")],
            [self.make_run(identity, databaseId=7, attempt=2, status="queued")],
        )
        for runs in regressions:
            with self.subTest(runs=runs), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                dispatcher(root, FakeRunner(branch=branch,
                                            runs=[initial])).dispatch()
                with self.assertRaisesRegex(
                        GitHubOracleError, "JOURNAL_RUN_REGRESSION"):
                    dispatcher(root, FakeRunner(branch=branch,
                                                runs=runs)).dispatch()

    def test_journal_identity_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = dispatcher(root, FakeRunner())
            target.journal_path.parent.mkdir(parents=True)
            target.journal_path.write_text(json.dumps({
                "schema_version": 1, "binding": {}, "outcome": "pending",
                "run": None, "created_at": "x", "updated_at": "x",
            }))
            with self.assertRaisesRegex(GitHubOracleError,
                                        "JOURNAL_IDENTITY_MISMATCH"):
                dispatcher(root, FakeRunner()).dispatch()


if __name__ == "__main__":
    unittest.main()
