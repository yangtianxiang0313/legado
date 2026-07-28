import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_DIR))

import run_journal  # noqa: E402


SHA_A = "a" * 64
SHA_B = "b" * 64
SHA_C = "c" * 64
HEAD = "d" * 40


def binding(**overrides):
    value = {
        "work_item_id": "IOS-JOURNAL-001",
        "attempt": 1,
        "phase": "implementation",
        "work_item_sha256": SHA_A,
        "head_commit": HEAD,
        "control_binding_sha256": SHA_B,
        "candidate_snapshot_sha256": SHA_C,
    }
    value.update(overrides)
    return value


class RunJournalTests(unittest.TestCase):
    def test_atomic_hash_chained_completion_is_replayable_and_secret_free(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            journal = run_journal.RunJournal(root)
            first = journal.append_completion(**binding())
            second = journal.append_completion(
                **binding(phase="memory_close")
            )

            self.assertEqual("recorded", first["status"])
            self.assertEqual(2, second["sequence"])
            verdict = journal.inspect_completion(**binding())
            self.assertEqual("match", verdict["status"])
            self.assertEqual(first["record_sha256"], verdict["record_sha256"])

            journal_root = root / ".harness-runtime/loop-runs"
            journal_path = (
                journal_root / "ios-journal-001--attempt-1.json"
            )
            self.assertEqual(
                0o700,
                stat.S_IMODE(journal_root.stat().st_mode),
            )
            self.assertEqual(0o600, stat.S_IMODE(journal_path.stat().st_mode))
            self.assertEqual(
                0o600,
                stat.S_IMODE((journal_root / ".journal.lock").stat().st_mode),
            )
            raw = journal_path.read_text(encoding="utf-8")
            for forbidden in (
                "prompt",
                "context",
                "stdout",
                "stderr",
                "environment",
                "auth.json",
                "SECRET_SENTINEL",
            ):
                self.assertNotIn(forbidden, raw)
            document = json.loads(raw)
            self.assertEqual(
                document["records"][0]["record_sha256"],
                document["records"][1]["previous_record_sha256"],
            )

    def test_candidate_or_control_drift_never_grants_replay(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = run_journal.RunJournal(Path(directory))
            journal.append_completion(**binding())
            candidate = journal.inspect_completion(
                **binding(candidate_snapshot_sha256="e" * 64)
            )
            control = journal.inspect_completion(
                **binding(control_binding_sha256="f" * 64)
            )
            self.assertEqual("stale", candidate["status"])
            self.assertEqual(
                ["candidate_snapshot_sha256"],
                candidate["mismatches"],
            )
            self.assertEqual("stale", control["status"])
            self.assertEqual(
                ["control_binding_sha256"],
                control["mismatches"],
            )

    def test_tamper_truncation_and_broad_permissions_are_invalid(self):
        for mutation in ("tamper", "truncate", "permissions"):
            with self.subTest(mutation=mutation):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    journal = run_journal.RunJournal(root)
                    journal.append_completion(**binding())
                    path = (
                        root
                        / ".harness-runtime/loop-runs"
                        / "ios-journal-001--attempt-1.json"
                    )
                    if mutation == "tamper":
                        document = json.loads(path.read_text(encoding="utf-8"))
                        document["records"][0]["head_commit"] = "e" * 40
                        path.write_text(
                            json.dumps(document) + "\n",
                            encoding="utf-8",
                        )
                    elif mutation == "truncate":
                        path.write_bytes(path.read_bytes()[:20])
                    else:
                        os.chmod(path, 0o644)
                    verdict = journal.inspect_completion(**binding())
                    self.assertEqual("invalid", verdict["status"])
                    self.assertTrue(
                        verdict["reason_code"].startswith("JOURNAL_")
                    )

    def test_symlink_directory_and_record_limit_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / ".harness-runtime"
            runtime.mkdir(mode=0o700)
            outside = root / "outside"
            outside.mkdir()
            (runtime / "loop-runs").symlink_to(outside, target_is_directory=True)
            journal = run_journal.RunJournal(root)
            verdict = journal.inspect_completion(**binding())
            self.assertEqual("invalid", verdict["status"])
            with self.assertRaisesRegex(
                run_journal.RunJournalError,
                "JOURNAL_DIRECTORY_INVALID",
            ):
                journal.append_completion(**binding())

        with tempfile.TemporaryDirectory() as directory:
            journal = run_journal.RunJournal(Path(directory))
            for _ in range(run_journal.MAX_RECORDS):
                journal.append_completion(**binding())
            with self.assertRaisesRegex(
                run_journal.RunJournalError,
                "JOURNAL_RECORD_LIMIT_REACHED",
            ):
                journal.append_completion(**binding())

    def test_old_attempt_and_other_phase_are_not_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = run_journal.RunJournal(Path(directory))
            journal.append_completion(**binding())
            old_attempt = journal.inspect_completion(**binding(attempt=2))
            other_phase = journal.inspect_completion(
                **binding(phase="memory_close")
            )
            self.assertEqual("missing", old_attempt["status"])
            self.assertEqual("missing", other_phase["status"])

    def test_failed_supervisor_consumption_invalidates_phase_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = run_journal.RunJournal(Path(directory))
            journal.append_completion(**binding())
            invalidation = journal.invalidate_completion(**binding())
            self.assertEqual(
                "AgentPhaseInvalidated",
                invalidation["event"],
            )
            verdict = journal.inspect_completion(**binding())
            self.assertEqual("stale", verdict["status"])
            self.assertEqual(
                "JOURNAL_PHASE_INVALIDATED",
                verdict["reason_code"],
            )


if __name__ == "__main__":
    unittest.main()
