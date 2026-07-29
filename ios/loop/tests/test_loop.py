import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


LOOP_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOOP_ROOT))

import loop  # noqa: E402


class MinimalLoopTests(unittest.TestCase):
    def write(self, root: Path, relative: str, value) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(loop.canonical(value))

    def fixture(self, root: Path) -> None:
        self.write(
            root,
            "ios/project/requirements/accepted/REQ-ANDROID-SOURCE-PIPELINE-001.json",
            {"id": "REQ-ANDROID-SOURCE-PIPELINE-001"},
        )
        self.write(
            root,
            "ios/harness/goldens/android-legado-v1/sl-post-form-001.json",
            {"fixture_id": "sl-post-form-001"},
        )
        self.write(
            root,
            "ios/project/migration-intents/MINT-SOURCE-REQUEST-POST-FORM-001.json",
            {
                "id": "MINT-SOURCE-REQUEST-POST-FORM-001",
                "android_baseline": {"commit": "a" * 40},
                "source_anchors": [{"path": "AnalyzeUrl.kt", "git_blob": "b" * 40}],
                "requirement_binding": {
                    "id": "REQ-ANDROID-SOURCE-PIPELINE-001"
                },
            },
        )
        self.write(
            root,
            "ios/project/business-knowledge/drivers/published/"
            "DRV-SOURCE-RUNTIME-POST-FORM-001/r0001.json",
            {
                "id": "DRV-SOURCE-RUNTIME-POST-FORM-001",
                "revision": 1,
                "title": "实现 POST Form",
                "claim_refs": [{"id": "BKC-POST", "revision": 1}],
            },
        )
        self.write(
            root,
            "ios/project/business-knowledge/coverage/BKL-POST.json",
            {
                "status": "current",
                "packet_refs": [
                    {"id": "BKP-POST", "revision": 1, "sha256": "c" * 64}
                ],
                "entries": [
                    {
                        "claim_ref": {"id": "BKC-POST", "revision": 1},
                        "delivery": {
                            "state": "planned",
                            "work_item_refs": [
                                "IOS-SOURCE-RUNTIME-POST-FORM-001"
                            ],
                            "requirement_refs": [
                                "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-01"
                            ],
                        },
                        "validation": {
                            "evidence_refs": [
                                "ios/harness/goldens/android-legado-v1/"
                                "sl-post-form-001.json#/artifact/request_plan"
                            ]
                        },
                    }
                ],
            },
        )

    def test_plan_derives_one_compact_task_from_published_knowledge(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            task = loop.next_task(root)
            self.assertEqual(
                "IOS-SOURCE-RUNTIME-POST-FORM-001",
                task["id"],
            )
            self.assertEqual("SourceRuntime", task["architecture"]["owner"])
            self.assertEqual(
                "sl-post-form-001",
                task["source"]["fixture_id"],
            )
            self.assertNotIn("recipe", task)
            self.assertNotIn("recovery", task)
            self.assertLess(len(loop.canonical(task)), 8_000)

    def test_completed_event_removes_delivery_from_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.write(
                root,
                loop.EVENTS_PATH.as_posix(),
                {
                    "schema_version": 2,
                    "sequence": 1,
                    "at": "2026-07-29T00:00:00Z",
                    "event": "task_completed",
                    "task_id": "IOS-SOURCE-RUNTIME-POST-FORM-001",
                },
            )
            self.assertIsNone(loop.next_task(root))

    def test_legacy_completion_index_prevents_replanning(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.write(
                root,
                loop.EVENTS_PATH.as_posix(),
                {
                    "schema_version": 2,
                    "sequence": 1,
                    "at": "2026-07-29T00:00:00Z",
                    "event": "legacy_history_imported",
                    "task_id": None,
                    "details": {
                        "completed_task_ids": [
                            "IOS-SOURCE-RUNTIME-POST-FORM-001"
                        ]
                    },
                },
            )
            self.assertIsNone(loop.next_task(root))

    def test_changed_paths_preserves_first_porcelain_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "loop@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Loop Test"],
                cwd=root,
                check=True,
            )
            path = root / "ios/first.txt"
            path.parent.mkdir(parents=True)
            path.write_text("before\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=root, check=True)
            base = loop.git(root, "rev-parse", "HEAD")
            path.write_text("after\n")

            self.assertEqual(["ios/first.txt"], loop.changed_paths(root, base))

    def test_workspace_digest_changes_with_product_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "ios/value.txt"
            path.parent.mkdir(parents=True)
            path.write_text("one")
            first = loop.workspace_digest(root, ["ios/value.txt"])
            path.write_text("two")
            second = loop.workspace_digest(root, ["ios/value.txt"])

            self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
