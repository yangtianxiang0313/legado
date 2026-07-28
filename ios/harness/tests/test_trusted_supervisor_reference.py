import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HARNESS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_DIR))

import trusted_supervisor_reference as trusted  # noqa: E402


class TrustedFixture:
    item_id = "IOS-TRUSTED-TEST-001"

    def __init__(self, root):
        self.root = root
        self.repo = root / "repo"
        self.control = root / "control"
        self.repo.mkdir()
        self.control.mkdir()
        self.key_path = root / "journal.key"
        self.key_path.write_bytes(b"k" * 32)
        os.chmod(self.key_path, 0o600)
        item = {
            "api_version": "legado.harness/v1",
            "kind": "WorkItem",
            "metadata": {
                "id": self.item_id,
                "title": "test",
                "priority": 1,
                "risk": "low",
                "labels": ["test"],
            },
            "spec": {
                "scope": {
                    "allow_write": ["allowed/**"],
                    "deny_write": ["allowed/denied/**"],
                    "max_files_changed": 8,
                    "max_changed_lines": 20,
                }
            },
        }
        path = self.repo / f"ios/harness/work-items/{self.item_id}.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(item))
        allowed = self.repo / "allowed"
        allowed.mkdir()
        (allowed / "old.txt").write_text("delete me")
        (allowed / "rename.txt").write_text("rename me")
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Trusted Test"],
            cwd=self.repo,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "trusted@example.invalid"],
            cwd=self.repo,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=self.repo, check=True)
        self.base = (
            subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo)
            .decode()
            .strip()
        )

    def config(self, agent_source, verifier_source=None):
        if verifier_source is None:
            verifier_source = (
                "from pathlib import Path;"
                "p=Path('allowed/result.bin');"
                "assert p.read_bytes()==b'\\x00trusted\\xff'"
            )
        value = {
            "agent_argv": [sys.executable, "-c", agent_source],
            "agent_timeout_seconds": 5,
            "verifier_argv": [sys.executable, "-c", verifier_source],
            "verifier_timeout_seconds": 5,
        }
        path = self.root / ("config-" + str(abs(hash(agent_source))) + ".json")
        path.write_text(json.dumps(value))
        return path

    def supervisor(self):
        return trusted.ReferenceSupervisor(self.repo, self.control, self.key_path)


class TrustedSupervisorReferenceTests(unittest.TestCase):
    def test_real_git_e2e_freezes_replays_verifies_and_signs(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = TrustedFixture(Path(directory))
            agent = (
                "import os;"
                "from pathlib import Path;"
                "p=Path('allowed/result.bin');p.parent.mkdir(exist_ok=True);"
                "p.write_bytes(b'\\x00trusted\\xff');"
                "Path('allowed/env.txt').write_text(str(os.environ.get('AWS_SECRET_ACCESS_KEY')));"
                "Path('allowed/old.txt').unlink();"
                "Path('allowed/rename.txt').rename('allowed/renamed.txt')"
            )
            config = fixture.config(
                agent,
                "from pathlib import Path;"
                "assert Path('allowed/result.bin').read_bytes()==b'\\x00trusted\\xff';"
                "assert Path('allowed/env.txt').read_text()=='None';"
                "assert not Path('allowed/old.txt').exists();"
                "assert Path('allowed/renamed.txt').read_text()=='rename me'",
            )
            supervisor = fixture.supervisor()
            result = supervisor.run_attempt(
                base_commit=fixture.base,
                work_item_id=fixture.item_id,
                config_path=config,
                environment={
                    "PATH": os.environ.get("PATH", ""),
                    "AWS_SECRET_ACCESS_KEY": "do-not-pass",
                    "CODEX_HOME": "/secret/codex",
                },
            )
            self.assertEqual("verified_artifact", result["outcome"])
            artifact = Path(result["artifact_dir"])
            self.assertTrue((artifact / "candidate.patch").is_file())
            self.assertEqual(
                "valid",
                supervisor.verify_artifact(artifact / "manifest.json")["status"],
            )
            events = supervisor.journal.verify()
            self.assertEqual(
                [
                    "AttemptStarted",
                    "AgentCompleted",
                    "CandidateFrozen",
                    "VerificationPassed",
                    "AttemptVerified",
                ],
                [event["event"] for event in events],
            )
            self.assertEqual("", subprocess.check_output(
                ["git", "status", "--porcelain"], cwd=fixture.repo
            ).decode())
            worktrees = subprocess.check_output(
                ["git", "worktree", "list", "--porcelain"], cwd=fixture.repo
            ).decode()
            self.assertEqual(1, worktrees.count("worktree "))

    def test_scope_violation_rejects_before_verifier_and_no_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = TrustedFixture(Path(directory))
            marker = fixture.root / "verifier-ran"
            config = fixture.config(
                "from pathlib import Path;Path('forbidden.txt').write_text('bad')",
                f"from pathlib import Path;Path({str(marker)!r}).write_text('ran')",
            )
            supervisor = fixture.supervisor()
            with self.assertRaises(trusted.TrustedSupervisorError) as caught:
                supervisor.run_attempt(
                    base_commit=fixture.base,
                    work_item_id=fixture.item_id,
                    config_path=config,
                )
            self.assertEqual("SCOPE_REJECTED", caught.exception.reason_code)
            self.assertFalse(marker.exists())
            self.assertEqual("AttemptRejected", supervisor.journal.verify()[-1]["event"])
            artifact_root = fixture.control / "artifacts"
            self.assertFalse(artifact_root.exists())

    def test_broken_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = TrustedFixture(Path(directory))
            config = fixture.config(
                "from pathlib import Path;"
                "Path('allowed/link').symlink_to('missing-target')"
            )
            supervisor = fixture.supervisor()
            with self.assertRaises(trusted.TrustedSupervisorError) as caught:
                supervisor.run_attempt(
                    base_commit=fixture.base,
                    work_item_id=fixture.item_id,
                    config_path=config,
                )
            self.assertEqual("SCOPE_REJECTED", caught.exception.reason_code)
            self.assertIn("UNSAFE_PATH", str(caught.exception))

    def test_timeout_reclaims_child_and_grandchild(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pid_file = root / "pids"
            grandchild = (
                "import os,sys,time;"
                "open(sys.argv[1],'a').write(str(os.getpid())+'\\n');"
                "time.sleep(60)"
            )
            child = (
                "import os,subprocess,sys,time;"
                "open(sys.argv[1],'a').write(str(os.getpid())+'\\n');"
                f"subprocess.Popen([sys.executable,'-c',{grandchild!r},sys.argv[1]]);"
                "time.sleep(60)"
            )
            parent = (
                "import os,subprocess,sys,time;"
                "open(sys.argv[1],'a').write(str(os.getpid())+'\\n');"
                f"subprocess.Popen([sys.executable,'-c',{child!r},sys.argv[1]]);"
                "time.sleep(60)"
            )
            result = trusted._run_argv(
                [sys.executable, "-c", parent, str(pid_file)],
                root,
                1,
                {"PATH": os.environ.get("PATH", "")},
            )
            self.assertTrue(result["timed_out"])
            self.assertFalse(result["process_leak"])
            self.assertIsNone(result["cleanup_error"])
            pids = [int(value) for value in pid_file.read_text().splitlines()]
            self.assertEqual(3, len(pids))
            deadline = __import__("time").monotonic() + 2
            while __import__("time").monotonic() < deadline:
                alive = []
                for pid in pids:
                    try:
                        os.kill(pid, 0)
                        alive.append(pid)
                    except ProcessLookupError:
                        pass
                if not alive:
                    break
                __import__("time").sleep(0.02)
            self.assertEqual([], alive)

    def test_journal_and_artifact_tampering_are_detected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = TrustedFixture(Path(directory))
            config = fixture.config(
                "from pathlib import Path;"
                "p=Path('allowed/result.bin');p.parent.mkdir(exist_ok=True);"
                "p.write_bytes(b'\\x00trusted\\xff')"
            )
            supervisor = fixture.supervisor()
            result = supervisor.run_attempt(
                base_commit=fixture.base,
                work_item_id=fixture.item_id,
                config_path=config,
            )
            artifact = Path(result["artifact_dir"])
            patch = artifact / "candidate.patch"
            patch.write_bytes(patch.read_bytes() + b"tamper")
            with self.assertRaises(trusted.TrustedSupervisorError) as caught:
                supervisor.verify_artifact(artifact / "manifest.json")
            self.assertEqual("ARTIFACT_PATCH_INVALID", caught.exception.reason_code)

            journal = fixture.control / "journal.jsonl"
            value = bytearray(journal.read_bytes())
            value[20] ^= 1
            journal.write_bytes(bytes(value))
            with self.assertRaises(trusted.TrustedSupervisorError):
                supervisor.journal.verify()

    def test_external_path_and_key_guards_fail_before_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = TrustedFixture(Path(directory))
            inside = fixture.repo / "control"
            with self.assertRaises(trusted.TrustedSupervisorError) as caught:
                trusted.ReferenceSupervisor(fixture.repo, inside, fixture.key_path)
            self.assertEqual("CONTROL_ROOT_INSIDE_REPO", caught.exception.reason_code)
            os.chmod(fixture.key_path, 0o644)
            with self.assertRaises(trusted.TrustedSupervisorError) as caught:
                fixture.supervisor()
            self.assertEqual("KEY_PERMISSIONS_INVALID", caught.exception.reason_code)

    def test_agent_failure_and_verifier_failure_never_create_artifact(self):
        for agent, verifier, reason in (
            ("raise SystemExit(7)", "pass", "AGENT_FAILED"),
            (
                "from pathlib import Path;"
                "p=Path('allowed/result.bin');p.parent.mkdir(exist_ok=True);"
                "p.write_bytes(b'\\x00trusted\\xff')",
                "raise SystemExit(8)",
                "VERIFIER_FAILED",
            ),
        ):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                fixture = TrustedFixture(Path(directory))
                supervisor = fixture.supervisor()
                with self.assertRaises(trusted.TrustedSupervisorError) as caught:
                    supervisor.run_attempt(
                        base_commit=fixture.base,
                        work_item_id=fixture.item_id,
                        config_path=fixture.config(agent, verifier),
                    )
                self.assertEqual(reason, caught.exception.reason_code)
                self.assertEqual(
                    "AttemptRejected", supervisor.journal.verify()[-1]["event"]
                )
                self.assertFalse((fixture.control / "artifacts").exists())

    def test_cli_has_no_promotion_or_authority_commands(self):
        help_text = trusted.build_parser().format_help().lower()
        for forbidden in (
            "promote",
            "merge",
            "commit",
            "push",
            "approve",
            "materialize",
            "publish",
        ):
            self.assertNotIn(forbidden, help_text)

    def test_artifact_pair_rolls_back_on_atomic_publish_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "artifacts/attempt-test"
            with mock.patch.object(
                trusted.os,
                "replace",
                side_effect=OSError("simulated publish failure"),
            ):
                with self.assertRaisesRegex(OSError, "simulated"):
                    trusted.ReferenceSupervisor._write_artifact_pair(
                        destination,
                        b"patch",
                        {"schema_version": 1},
                    )
            self.assertFalse(destination.exists())
            self.assertEqual(
                [],
                list((root / "artifacts").iterdir()),
            )


if __name__ == "__main__":
    unittest.main()
