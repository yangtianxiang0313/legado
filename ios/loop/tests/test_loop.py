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
    def init_git(self, root: Path) -> None:
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

    def run_test_count_acceptance(
        self,
        root: Path,
        count: int,
    ) -> tuple[bool, list[dict]]:
        self.init_git(root)
        subprocess.run(
            ["git", "commit", "--allow-empty", "-qm", "base"],
            cwd=root,
            check=True,
        )
        task = {
            "id": "IOS-TEST-001",
            "acceptance": {
                "commands": [
                    {
                        "id": "tests",
                        "argv": [
                            sys.executable,
                            "-c",
                            (
                                "print('Executed "
                                f"{count} tests, with 0 failures')"
                            ),
                        ],
                        "required_output_pattern": (
                            r"Executed [1-9][0-9]* tests?, with 0 failures"
                        ),
                    }
                ]
            },
        }
        passed, checks, _ = loop.run_acceptance(
            root,
            task,
            attempt=1,
            paths=[],
        )
        return passed, checks

    def write(self, root: Path, relative: str, value) -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(loop.canonical(value))

    def test_superseded_task_is_terminal_and_projection_returns_idle(self):
        events = [
            {
                "schema_version": 2,
                "sequence": 1,
                "at": "2026-07-30T00:00:00Z",
                "event": "task_started",
                "task_id": "IOS-OLD-001",
            },
            {
                "schema_version": 2,
                "sequence": 2,
                "at": "2026-07-30T00:01:00Z",
                "event": "task_superseded",
                "task_id": "IOS-OLD-001",
                "details": {
                    "reason": "验证粒度已调整",
                    "replacement": "按完整 UI 能力切片验收",
                },
            },
        ]

        projected = loop.project_current(events)

        self.assertEqual("idle", projected["status"])
        self.assertEqual("IOS-OLD-001", projected["last_completed"]["task_id"])
        self.assertEqual(
            "superseded",
            projected["last_completed"]["outcome"],
        )

    def test_completed_task_ids_exclude_superseded_tasks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            events_path = root / "ios/project/loop/events.jsonl"
            events_path.parent.mkdir(parents=True)
            events_path.write_bytes(
                loop.canonical(
                    {
                        "schema_version": 2,
                        "sequence": 1,
                        "at": "2026-07-30T00:00:00Z",
                        "event": "task_superseded",
                        "task_id": "IOS-OLD-001",
                        "details": {
                            "reason": "验证粒度已调整",
                            "replacement": "按完整 UI 能力切片验收",
                        },
                    }
                )
            )

            self.assertEqual(
                set(),
                loop.completed_task_ids(root),
            )

    def test_superseded_claim_can_reuse_existing_android_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = (
                "ios/harness/goldens/android-legado-v1/existing.json"
            )
            self.write(root, evidence, {"fixture_id": "existing"})
            events_path = root / "ios/project/loop/events.jsonl"
            events_path.parent.mkdir(parents=True, exist_ok=True)
            events_path.write_bytes(
                loop.canonical(
                    {
                        "schema_version": 2,
                        "sequence": 1,
                        "at": "2026-07-30T00:00:00Z",
                        "event": "task_superseded",
                        "task_id": "IOS-CHARACTERIZE-OLD-001",
                        "details": {
                            "reason": "已有相同语义真值",
                            "replacement": "直接实现",
                            "replacement_evidence": evidence,
                            "knowledge": {
                                "candidate_claim_refs": [
                                    {"id": "BKC-SOURCE-001", "revision": 1}
                                ]
                            },
                        },
                    }
                )
            )

            self.assertEqual(
                {("BKC-SOURCE-001", 1): evidence},
                loop.reused_claim_evidence(root),
            )
            self.assertIn(
                ("BKC-SOURCE-001", 1),
                loop.satisfied_dependency_claim_refs(root),
            )

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
            source_runtime_check = next(
                check
                for check in task["acceptance"]["commands"]
                if check["id"] == "structured-source-acceptance"
            )
            self.assertNotIn(
                "package-contract",
                {
                    check["id"]
                    for check in task["acceptance"]["commands"]
                },
            )
            self.assertNotIn("required_output_pattern", source_runtime_check)
            self.assertEqual(1, len(task["acceptance"]["commands"]))
            self.assertNotIn("recipe", task)
            self.assertNotIn("recovery", task)
            loop.validate_task(root, task)
            self.assertLess(len(loop.canonical(task)), 8_000)

    def test_active_priority_policy_defers_unmapped_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            coverage_path = (
                root
                / "ios/project/business-knowledge/coverage/BKL-POST.json"
            )
            coverage = loop.read_json(coverage_path)
            coverage["entries"].append(
                {
                    "claim_ref": {"id": "BKC-REMOTE-BOOK", "revision": 1},
                    "delivery": {
                        "state": "planned",
                        "work_item_refs": [
                            "IOS-LIBRARY-DOMAIN-REMOTE-BOOK-001"
                        ],
                        "requirement_refs": [
                            "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-01"
                        ],
                    },
                    "validation": {"evidence_refs": []},
                }
            )
            self.write(
                root,
                "ios/project/business-knowledge/coverage/BKL-POST.json",
                coverage,
            )
            self.write(
                root,
                loop.PRIORITY_PATH.as_posix(),
                {
                    "schema_version": 1,
                    "id": "MILESTONE-P0",
                    "status": "active",
                    "mode": "critical_path_only",
                    "stages": [
                        {
                            "id": "P0-SEARCH",
                            "title": "Search",
                            "selectors": [
                                {
                                    "id": "POST",
                                    "claim_ids": ["BKC-POST"],
                                }
                            ],
                        }
                    ],
                },
            )

            task = loop.next_task(root)
            queue = loop.queue_status(root)

            self.assertEqual("IOS-SOURCE-RUNTIME-POST-FORM-001", task["id"])
            self.assertEqual("MILESTONE-P0", task["selection"]["milestone_id"])
            self.assertEqual("P0-SEARCH", task["selection"]["stage_id"])
            self.assertEqual(1, queue["eligible_count"])
            self.assertEqual(1, queue["priority_policy"]["deferred_count"])

    def test_active_priority_policy_orders_stage_before_kind(self):
        policy = {
            "stages": [
                {
                    "id": "P0-FIRST",
                    "title": "First",
                    "selectors": [
                        {"id": "FIRST", "claim_ids": ["BKC-FIRST"]}
                    ],
                },
                {
                    "id": "P0-LATER",
                    "title": "Later",
                    "selectors": [
                        {"id": "LATER", "claim_ids": ["BKC-LATER"]}
                    ],
                },
            ]
        }
        first = loop.priority_match(
            policy,
            task_id="IOS-CHARACTERIZE-FIRST",
            claim_ids={"BKC-FIRST"},
        )
        later = loop.priority_match(
            policy,
            task_id="IOS-DELIVERY-LATER",
            claim_ids={"BKC-LATER"},
        )

        self.assertEqual((0, 0), first[:2])
        self.assertEqual((1, 0), later[:2])

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

    def test_ui_bootstrap_derives_simulator_delivery_without_android_golden(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-IOS-UI-BOOTSTRAP-001.json",
                {"id": "REQ-IOS-UI-BOOTSTRAP-001"},
            )
            self.write(
                root,
                "ios/harness/ui/expected/ui-bootstrap-roots-v1.json",
                {"scenario_id": "ui-bootstrap-roots-v1"},
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/published/"
                "BKP-UI-BOOTSTRAP-001/r0001.json",
                {
                    "claims": [
                        {
                            "id": "BKC-UI-ROOTS-001",
                            "revision": 4,
                            "support": {
                                "source_anchors": [
                                    {
                                        "android_commit": "a" * 40,
                                        "path": "MainActivity.kt",
                                        "symbol_id": "MainActivity",
                                        "git_blob": "b" * 40,
                                    }
                                ]
                            },
                        }
                    ]
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/drivers/published/"
                "DRV-UI-BOOTSTRAP-001/r0001.json",
                {
                    "id": "DRV-UI-BOOTSTRAP-001",
                    "revision": 1,
                    "title": "原生 UI Bootstrap",
                    "claim_refs": [
                        {"id": "BKC-UI-ROOTS-001", "revision": 4}
                    ],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/coverage/"
                "BKL-UI-BOOTSTRAP-001.json",
                {
                    "status": "current",
                    "packet_refs": [
                        {
                            "id": "BKP-UI-BOOTSTRAP-001",
                            "revision": 1,
                            "sha256": "c" * 64,
                        }
                    ],
                    "entries": [
                        {
                            "claim_ref": {
                                "id": "BKC-UI-ROOTS-001",
                                "revision": 4,
                            },
                            "delivery": {
                                "state": "planned",
                                "work_item_refs": ["IOS-UI-BOOTSTRAP-001"],
                                "requirement_refs": [
                                    "REQ-IOS-UI-BOOTSTRAP-001@1#RC-01"
                                ],
                            },
                            "validation": {"evidence_refs": []},
                        }
                    ],
                },
            )

            task = loop.next_task(root)

            self.assertEqual("IOS-UI-BOOTSTRAP-001", task["id"])
            self.assertEqual("AppShell", task["architecture"]["owner"])
            self.assertEqual(
                "ios_product_decision",
                task["source"]["authority"],
            )
            self.assertNotIn("android_golden", task["source"])
            self.assertEqual(
                "ui-simulator-acceptance",
                task["acceptance"]["structured_output"]["command_id"],
            )
            loop.validate_task(root, task)

    def test_app_navigation_startup_derives_structured_and_ui_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {"id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001"},
            )
            golden_path = (
                "ios/harness/goldens/android-legado-v1/"
                "rl-app-startup-first-use-and-restore-001.json"
            )
            self.write(
                root,
                golden_path,
                {
                    "fixture_id": (
                        "rl-app-startup-first-use-and-restore-001"
                    ),
                    "oracle": {"android_git_commit": "a" * 40},
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/published/"
                "BKP-APP-STARTUP-FIRST-USE-AND-RESTORE-001/r0001.json",
                {
                    "claims": [
                        {
                            "id": "BKC-APP-STARTUP-001",
                            "revision": 2,
                            "support": {
                                "source_anchors": [
                                    {
                                        "android_commit": "a" * 40,
                                        "path": "WelcomeActivity.kt",
                                        "symbol_id": "startMainActivity",
                                        "git_blob": "b" * 40,
                                    }
                                ]
                            },
                        }
                    ]
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/drivers/published/"
                "DRV-APP-STARTUP-FIRST-USE-AND-RESTORE-001/r0001.json",
                {
                    "id": (
                        "DRV-APP-STARTUP-FIRST-USE-AND-RESTORE-001"
                    ),
                    "revision": 1,
                    "title": "启动状态机",
                    "claim_refs": [
                        {"id": "BKC-APP-STARTUP-001", "revision": 2}
                    ],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/coverage/"
                "BKL-APP-STARTUP-FIRST-USE-AND-RESTORE-001.json",
                {
                    "status": "current",
                    "packet_refs": [
                        {
                            "id": (
                                "BKP-APP-STARTUP-FIRST-USE-AND-RESTORE-001"
                            ),
                            "revision": 1,
                            "sha256": "c" * 64,
                        }
                    ],
                    "entries": [
                        {
                            "claim_ref": {
                                "id": "BKC-APP-STARTUP-001",
                                "revision": 2,
                            },
                            "delivery": {
                                "state": "planned",
                                "work_item_refs": [
                                    (
                                        "IOS-APP-NAVIGATION-STARTUP-"
                                        "FIRST-USE-RESTORE-001"
                                    )
                                ],
                                "requirement_refs": [
                                    (
                                        "REQ-ANDROID-MIGRATION-"
                                        "CHARACTERIZATION-001@1#RC-01"
                                    )
                                ],
                            },
                            "validation": {
                                "evidence_refs": [
                                    f"{golden_path}#/artifact/result/value"
                                ]
                            },
                        }
                    ],
                },
            )

            task = loop.next_task(root)

            self.assertEqual(
                "IOS-APP-NAVIGATION-STARTUP-FIRST-USE-RESTORE-001",
                task["id"],
            )
            self.assertEqual(
                "AppNavigation",
                task["architecture"]["owner"],
            )
            self.assertEqual(
                "testStartupFirstUseAndRestore",
                task["source"]["ui_acceptance"]["test_method"],
            )
            self.assertEqual("ui_slice", task["acceptance"]["profile"])
            self.assertEqual(
                1,
                len(task["source"]["ui_acceptance"]["simulators"]),
            )
            self.assertEqual(
                {"android_commit": "a" * 40},
                task["source"]["android_baseline"],
            )
            self.assertEqual(
                "WelcomeActivity.kt",
                task["source"]["anchors"][0]["path"],
            )
            command_ids = {
                command["id"]
                for command in task["acceptance"]["commands"]
            }
            self.assertIn("structured-app-startup-acceptance", command_ids)
            self.assertIn("ui-simulator-acceptance", command_ids)
            loop.validate_task(root, task)

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

    def test_next_characterization_comes_from_smallest_ready_android_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-SOURCE-PIPELINE-001.json",
                {"id": "REQ-ANDROID-SOURCE-PIPELINE-001"},
            )
            self.write(
                root,
                "ios/project/migration-intents/MINT-SOURCE-REQUEST-001.json",
                {
                    "id": "MINT-SOURCE-REQUEST-001",
                    "android_baseline": {"commit": "a" * 40},
                    "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                    "requirement_binding": {
                        "id": "REQ-ANDROID-SOURCE-PIPELINE-001",
                        "revision": 1,
                        "clauses": ["RC-01"],
                    },
                },
            )
            creator = "IOS-ANDROID-SOURCE-KNOWLEDGE-001"
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-SOURCE-REQUEST-001/r0001.json",
                {
                    "id": "BKP-SOURCE-REQUEST-001",
                    "revision": 1,
                    "status": "candidate",
                    "created_by": creator,
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-HEADER-001",
                            "revision": 1,
                            "semantic_key": "source.request.header-cookie-retry",
                            "topic": "Header Cookie Retry",
                            "subject_keys": ["request", "session", "transport"],
                            "depends_on": [
                                {"id": "BKC-BODY-001", "revision": 1}
                            ],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "android_characterization",
                                "source_anchors": [
                                    {"path": "AnalyzeUrl.kt"},
                                    {"path": "Cookie.kt"},
                                ],
                            },
                        },
                        {
                            "id": "BKC-XML-001",
                            "revision": 1,
                            "semantic_key": "source.response.xml-normalization",
                            "topic": "XML normalization",
                            "statement": "Android may prepend an XML declaration.",
                            "subject_keys": ["transport"],
                            "depends_on": [
                                {"id": "BKC-BODY-001", "revision": 1}
                            ],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "android_characterization",
                                "source_anchors": [
                                    {"path": "AnalyzeUrl.kt"}
                                ],
                            },
                        },
                    ],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/drivers/proposals/"
                "DRV-SOURCE-REQUEST-001/r0001.json",
                {
                    "id": "DRV-SOURCE-REQUEST-001",
                    "revision": 1,
                    "created_by": creator,
                    "claim_refs": [
                        {"id": "BKC-HEADER-001", "revision": 1},
                        {"id": "BKC-XML-001", "revision": 1},
                    ],
                },
            )
            self.write(
                root,
                loop.EVENTS_PATH.as_posix(),
                {
                    "schema_version": 2,
                    "sequence": 1,
                    "at": "2026-07-29T00:00:00Z",
                    "event": "task_completed",
                    "task_id": "IOS-PRIOR-001",
                    "details": {
                        "knowledge": {
                            "candidate_claim_refs": [
                                {"id": "BKC-BODY-001", "revision": 1}
                            ]
                        }
                    },
                },
            )

            task = loop.next_task(root)

            self.assertEqual("characterization", task["kind"])
            self.assertEqual(
                "BKC-XML-001",
                task["source"]["knowledge"]["candidate_claim"]["id"],
            )
            self.assertEqual(
                "sl-source-response-xml-normalization-001",
                task["source"]["fixture_id"],
            )
            self.assertFalse(
                (root / task["source"]["android_golden"]).exists()
            )
            loop.validate_task(root, task)
            self.assertLess(len(loop.canonical(task)), 8_000)

    def test_next_characterization_uses_latest_packet_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {
                    "id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001",
                    "revision": 1,
                    "status": "accepted",
                    "origin": {
                        "kind": "ios_product_decision",
                        "baseline_commit": "a" * 40,
                        "admission": "policy_auto",
                    },
                    "clauses": [{"id": "RC-01"}],
                },
            )
            for packet_revision, claim_revision in ((1, 1), (2, 2)):
                self.write(
                    root,
                    "ios/project/business-knowledge/packets/proposals/"
                    f"BKP-REVISIONED-001/r{packet_revision:04d}.json",
                    {
                        "id": "BKP-REVISIONED-001",
                        "revision": packet_revision,
                        "status": "candidate",
                        "baseline": {"android_commit": "a" * 40},
                        "claims": [
                            {
                                "id": "BKC-REVISIONED-001",
                                "revision": claim_revision,
                                "semantic_key": (
                                    "source.rule.revision-selection"
                                ),
                                "topic": f"Revision {claim_revision}",
                                "subject_keys": ["source.rule"],
                                "depends_on": [],
                                "support": {
                                    "state": "candidate_source_anchored",
                                    "runtime_requirement": (
                                        "android_characterization"
                                    ),
                                    "source_anchors": [
                                        {"path": "AnalyzeRule.kt"}
                                    ],
                                },
                            }
                        ],
                    },
                )

            task = loop.next_task(root)

            self.assertEqual(
                2,
                task["source"]["knowledge"]["packet"]["revision"],
            )
            self.assertEqual(
                2,
                task["source"]["knowledge"]["candidate_claim"]["revision"],
            )
            self.assertEqual("Revision 2", task["title"])

    def test_new_packet_claim_suppresses_older_runtime_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old_claim = {
                "id": "BKC-UI-001",
                "revision": 1,
                "semantic_key": "ui.source.bulk-selection-menu",
                "subject_keys": ["ui.action"],
                "depends_on": [],
                "support": {
                    "state": "candidate_source_anchored",
                    "runtime_requirement": "android_characterization",
                    "source_anchors": [{"path": "Old.kt"}],
                },
            }
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-OLD/r0001.json",
                {
                    "id": "BKP-OLD",
                    "revision": 1,
                    "status": "candidate",
                    "claims": [old_claim],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-NEW/r0001.json",
                {
                    "id": "BKP-NEW",
                    "revision": 1,
                    "status": "candidate",
                    "claims": [
                        {
                            **old_claim,
                            "revision": 2,
                            "kind": "static_declaration",
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "none",
                                "source_anchors": [{"path": "New.kt"}],
                            },
                        }
                    ],
                },
            )

            self.assertEqual([], loop.pending_characterizations(root))

    def test_verified_candidate_evidence_satisfies_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = (
                "ios/harness/goldens/android-legado-v1/existing.json"
            )
            self.write(root, artifact, {"fixture_id": "existing"})
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-VERIFIED/r0001.json",
                {
                    "id": "BKP-VERIFIED",
                    "revision": 1,
                    "status": "candidate",
                    "claims": [
                        {
                            "id": "BKC-VERIFIED",
                            "revision": 2,
                            "support": {
                                "state": "runtime_verified",
                                "runtime_requirement": (
                                    "android_characterization"
                                ),
                                "runtime_evidence": [
                                    {"artifact_uri": artifact}
                                ],
                            },
                        }
                    ],
                },
            )

            self.assertIn(
                ("BKC-VERIFIED", 2),
                loop.satisfied_dependency_claim_refs(root),
            )

    def test_business_inference_never_becomes_android_runtime_task(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {
                    "id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001",
                    "revision": 1,
                    "status": "accepted",
                    "origin": {
                        "kind": "ios_product_decision",
                        "baseline_commit": "a" * 40,
                        "admission": "policy_auto",
                    },
                    "clauses": [{"id": "RC-01"}],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-DEPENDENCY-001/r0001.json",
                {
                    "id": "BKP-DEPENDENCY-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-DEPENDENCY-001",
                            "revision": 1,
                            "kind": "business_inference",
                            "semantic_key": "integration.dependencies.client",
                            "subject_keys": ["integration.dependencies"],
                            "depends_on": [],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": (
                                    "android_characterization"
                                ),
                                "source_anchors": [
                                    {"path": "AndroidClient.kt"}
                                ],
                            },
                        }
                    ],
                },
            )

            self.assertIsNone(loop.next_task(root))

    def test_newer_published_claim_suppresses_historical_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {
                    "id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001",
                    "revision": 1,
                    "status": "accepted",
                    "origin": {
                        "kind": "ios_product_decision",
                        "baseline_commit": "a" * 40,
                        "admission": "policy_auto",
                    },
                    "clauses": [{"id": "RC-01"}],
                },
            )
            claim = {
                "id": "BKC-WEBDAV-DEPENDENCY-001",
                "revision": 2,
                "kind": "runtime_behavior",
                "semantic_key": "integration.dependencies.webdav",
                "subject_keys": ["integration.dependencies"],
                "depends_on": [],
                "support": {
                    "state": "candidate_source_anchored",
                    "runtime_requirement": "android_characterization",
                    "source_anchors": [{"path": "WebDav.kt"}],
                },
            }
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-WEBDAV-CANDIDATE-001/r0001.json",
                {
                    "id": "BKP-WEBDAV-CANDIDATE-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [claim],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/published/"
                "BKP-WEBDAV-DECISION-001/r0001.json",
                {
                    "id": "BKP-WEBDAV-DECISION-001",
                    "revision": 1,
                    "status": "published",
                    "claims": [
                        {
                            "id": "BKC-WEBDAV-DEPENDENCY-001",
                            "revision": 3,
                        }
                    ],
                },
            )

            self.assertIsNone(loop.next_task(root))

    def test_driver_for_uses_current_published_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            claim_ref = {"id": "BKC-RUNTIME-001", "revision": 1}
            for revision in (1, 2):
                self.write(
                    root,
                    "ios/project/business-knowledge/drivers/published/"
                    f"DRV-RUNTIME-001/r{revision:04d}.json",
                    {
                        "id": "DRV-RUNTIME-001",
                        "revision": revision,
                        "claim_refs": [claim_ref],
                    },
                )

            selected = loop.driver_for(root, [claim_ref])

            self.assertIsNotNone(selected)
            self.assertEqual(2, selected[1]["revision"])

    def test_static_source_claim_unlocks_runtime_characterization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/migration-intents/MINT-SOURCE-REQUEST-001.json",
                {
                    "id": "MINT-SOURCE-REQUEST-001",
                    "android_baseline": {"commit": "a" * 40},
                    "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                    "requirement_binding": {
                        "id": "REQ-ANDROID-SOURCE-PIPELINE-001",
                        "revision": 1,
                        "clauses": ["RC-01"],
                    },
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-SOURCE-REQUEST-001/r0001.json",
                {
                    "id": "BKP-SOURCE-REQUEST-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-STATIC-OPTION-001",
                            "revision": 1,
                            "semantic_key": "source.request.option-contract",
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "none",
                                "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                            },
                        },
                        {
                            "id": "BKC-RUNTIME-TEMPLATE-001",
                            "revision": 1,
                            "semantic_key": "source.request.template-runtime",
                            "subject_keys": ["source.request"],
                            "depends_on": [
                                {"id": "BKC-STATIC-OPTION-001", "revision": 1}
                            ],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "android_characterization",
                                "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                            },
                        },
                    ],
                },
            )

            task = loop.next_task(root)

            self.assertIsNotNone(task)
            self.assertEqual("characterization", task["kind"])
            self.assertEqual(
                "BKC-RUNTIME-TEMPLATE-001",
                task["source"]["knowledge"]["candidate_claim"]["id"],
            )

    def test_project_charter_continues_unclaimed_android_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {
                    "id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001",
                    "revision": 1,
                    "status": "accepted",
                    "origin": {
                        "kind": "ios_product_decision",
                        "baseline_commit": "a" * 40,
                        "admission": "policy_auto",
                    },
                    "clauses": [{"id": "RC-01"}],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-UNCLAIMED-001/r0001.json",
                {
                    "id": "BKP-UNCLAIMED-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-UNCLAIMED-RUNTIME-001",
                            "revision": 1,
                            "semantic_key": "source.rule.unclaimed-runtime",
                            "subject_keys": ["source.rule"],
                            "depends_on": [],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "android_characterization",
                                "source_anchors": [
                                    {"path": "AnalyzeRule.kt"}
                                ],
                            },
                        }
                    ],
                },
            )

            task = loop.next_task(root)

            self.assertIsNotNone(task)
            self.assertEqual("characterization", task["kind"])
            self.assertEqual(
                ["REQ-ANDROID-MIGRATION-CHARACTERIZATION-001@1#RC-01"],
                task["requirements"],
            )
            loop.validate_task(root, task)

    def test_reader_characterization_routes_to_runtime_lab_and_reader_core(self):
        claim = {
            "semantic_key": "reader.bookmark.search-runtime-risk",
            "subject_keys": ["reader.bookmark"],
        }

        contract = loop.characterization_contract(claim)

        self.assertEqual("ReaderCore", contract["owner"])
        self.assertEqual("runtime-lab", contract["fixture_root"])
        self.assertEqual(
            "rl-reader-bookmark-search-runtime-risk-001",
            loop.characterization_fixture_id(
                claim["semantic_key"],
                contract["fixture_prefix"],
            ),
        )
        delivery = loop.owner_contract(
            "IOS-READER-CORE-BOOKMARK-SEARCH-001"
        )
        self.assertEqual("ReaderCore", delivery["owner"])
        self.assertIn(
            "ios/Packages/LegadoKit/Sources/ReaderCore/**",
            delivery["allowed_paths"],
        )

    def test_characterization_reuses_existing_android_runtime_fixture(self):
        self.assertEqual(
            "rl-library-chapter-toc-update-runtime-001",
            loop.characterization_fixture_id(
                "reader.session.toc-refresh",
                "rl",
            ),
        )
        self.assertEqual(
            "rl-reader-content-index-load-dedup-001",
            loop.characterization_fixture_id(
                "reader.session.late-result-risk",
                "rl",
            ),
        )

    def test_completed_lightweight_characterization_becomes_delivery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {
                    "id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001",
                    "revision": 1,
                    "status": "accepted",
                    "origin": {
                        "kind": "ios_product_decision",
                        "baseline_commit": "a" * 40,
                        "admission": "policy_auto",
                    },
                    "clauses": [{"id": "RC-01"}],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-READER-001/r0001.json",
                {
                    "id": "BKP-READER-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-READER-NORMALIZE-001",
                            "revision": 1,
                            "semantic_key":
                                "reader.content.display-normalization",
                            "topic": "正文归一化",
                            "subject_keys": ["reader.content"],
                            "depends_on": [],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement":
                                    "android_characterization",
                                "source_anchors": [
                                    {
                                        "android_commit": "a" * 40,
                                        "path": "ContentProcessor.kt",
                                        "git_blob": "b" * 40,
                                    }
                                ],
                            },
                        }
                    ],
                },
            )
            self.write(
                root,
                "ios/harness/goldens/android-legado-v1/"
                "rl-reader-content-display-normalization-001.json",
                {
                    "fixture_id":
                        "rl-reader-content-display-normalization-001",
                    "oracle": {"android_git_commit": "a" * 40},
                },
            )
            self.write(
                root,
                loop.EVENTS_PATH.as_posix(),
                {
                    "schema_version": 2,
                    "sequence": 1,
                    "event": "task_completed",
                    "task_id": (
                        "IOS-CHARACTERIZE-READER-CONTENT-"
                        "DISPLAY-NORMALIZATION-001"
                    ),
                    "details": {
                        "knowledge": {
                            "candidate_claim_refs": [
                                {
                                    "id": "BKC-READER-NORMALIZE-001",
                                    "revision": 1,
                                }
                            ]
                        }
                    },
                },
            )

            task = loop.next_task(root)

            self.assertEqual(
                "IOS-READER-CORE-CONTENT-DISPLAY-NORMALIZATION-001",
                task["id"],
            )
            self.assertEqual("delivery", task["kind"])
            self.assertEqual("ReaderCore", task["architecture"]["owner"])
            self.assertEqual(
                "rl-reader-content-display-normalization-001",
                task["source"]["fixture_id"],
            )
            self.assertEqual(
                "ContentProcessor.kt",
                task["source"]["anchors"][0]["path"],
            )
            loop.validate_task(root, task)

    def test_app_characterization_routes_to_navigation_runtime_lab(self):
        claim = {
            "semantic_key": "app.startup.first-use-and-restore",
            "subject_keys": ["app.startup", "app.navigation"],
        }

        contract = loop.characterization_contract(claim)

        self.assertEqual("AppNavigation", contract["owner"])
        self.assertEqual("runtime-lab", contract["fixture_root"])
        self.assertEqual(
            "rl-app-startup-first-use-and-restore-001",
            loop.characterization_fixture_id(
                claim["semantic_key"],
                contract["fixture_prefix"],
            ),
        )
        self.assertIn("ARCH-010", contract["architecture_refs"])

    def test_duplicate_progress_remap_claim_reuses_android_golden(self):
        self.assertEqual(
            "rl-reader-progress-toc-remap-001",
            loop.characterization_fixture_id(
                "reader.progress.toc-remap-runtime",
                "rl",
            ),
        )

    def test_app_navigation_delivery_uses_feature_specific_ui_contract(self):
        startup = loop.app_navigation_delivery_contract(
            "rl-app-startup-first-use-and-restore-001"
        )
        detail = loop.app_navigation_delivery_contract(
            "rl-ui-book-detail-conditional-actions-001"
        )
        search = loop.app_navigation_delivery_contract(
            "rl-ui-discovery-search-flow-001"
        )
        toc = loop.app_navigation_delivery_contract(
            "rl-library-chapter-toc-update-runtime-001"
        )
        reader = loop.app_navigation_delivery_contract(
            "rl-ui-reader-toc-result-001"
        )
        reader_menu = loop.app_navigation_delivery_contract(
            "source-ui-reader-multilevel-menu-v1"
        )
        source_management = loop.app_navigation_delivery_contract(
            "source-ui-source-bulk-management-v1"
        )
        progress_restore = loop.app_navigation_delivery_contract(
            "milestone-reader-progress-restore-v1"
        )

        self.assertEqual(
            "testStartupFirstUseAndRestore",
            startup["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            "testBookDetailConditionalActions",
            detail["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            "testDiscoverySearchFlow",
            search["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            "testChapterTOCFlow",
            toc["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            "testReaderContentFlow",
            reader["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            "testReaderMultilevelMenuFlow",
            reader_menu["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            "source-bulk-management-build-acceptance",
            source_management["acceptance_id"],
        )
        self.assertEqual(
            "testReaderProgressPersistsAcrossRelaunch",
            progress_restore["ui_acceptance"]["test_method"],
        )
        self.assertEqual(
            (
                "ios/harness/ui/expected/"
                "ui-book-detail-conditional-actions-v1.json"
            ),
            detail["ui_acceptance"]["expected"],
        )
        self.assertIn("书籍详情操作矩阵", detail["goal"])
        self.assertIn("移除静态样例", search["goal"])
        self.assertIn("目录抓取", toc["goal"])
        self.assertIn("正文", reader["goal"])
        self.assertIn("主操作层", reader_menu["goal"])
        self.assertIn("App 重启后恢复", progress_restore["goal"])
        with self.assertRaisesRegex(
            loop.LoopError,
            "APP_NAVIGATION_UI_CONTRACT_NOT_MAPPED",
        ):
            loop.app_navigation_delivery_contract("rl-unmapped-001")

    def test_integration_characterization_bootstraps_protocol_lab_only(self):
        claim = {
            "id": "BKC-INTEGRATION-WEBDAV-001",
            "revision": 2,
            "semantic_key": "integration.backup.webdav",
            "topic": "WebDAV 备份与恢复",
            "subject_keys": ["integration.backup", "integration.remote"],
            "support": {
                "source_anchors": [{"path": "WebDav.kt"}],
            },
        }
        contract = loop.characterization_contract(claim)

        self.assertEqual("IntegrationKit", contract["owner"])
        self.assertEqual("integration-lab", contract["fixture_root"])
        self.assertEqual(
            "il-integration-backup-webdav-001",
            loop.characterization_fixture_id(
                claim["semantic_key"],
                contract["fixture_prefix"],
            ),
        )
        task = loop.build_characterization_task(
            Path("/tmp/unused"),
            {
                "packet_path": "packet.json",
                "packet": {
                    "id": "BKP-INTEGRATIONS-001",
                    "revision": 4,
                    "baseline": {"android_commit": "a" * 40},
                },
                "claim": claim,
                "requirements": [
                    "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001@1#RC-01"
                ],
                "task_id": (
                    "IOS-CHARACTERIZE-INTEGRATION-BACKUP-WEBDAV-001"
                ),
            },
        )

        self.assertEqual("IntegrationKit", task["architecture"]["owner"])
        self.assertEqual("slice", task["acceptance"]["profile"])
        self.assertEqual([], task["acceptance"]["commands"])
        self.assertIn(
            "ios/harness/integration-lab/**",
            task["scope"]["allowed_paths"],
        )
        self.assertIn(
            "ios/harness/oracle/ci_proposal.py",
            task["scope"]["allowed_paths"],
        )
        self.assertNotIn(
            "ios/publisher/android_golden_publisher.py",
            task["scope"]["allowed_paths"],
        )
        self.assertIn(
            "ios/harness/tests/test_oracle_control.py",
            task["scope"]["allowed_paths"],
        )
        architecture = loop.owner_contract(
            "IOS-INTEGRATION-WEBDAV-ARCHITECTURE-001"
        )
        self.assertEqual(
            "ArchitectureControl",
            architecture["owner"],
        )
        self.assertEqual(
            "ADR-0008",
            architecture["decision_contract"]["id"],
        )
        with self.assertRaisesRegex(loop.LoopError, "OWNER_NOT_MAPPED"):
            loop.owner_contract("IOS-INTEGRATION-WEBDAV-RUNTIME-001")

    def test_unresolved_integration_driver_derives_architecture_task(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requirement = (
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001"
            )
            self.write(
                root,
                "ios/project/requirements/accepted/"
                f"{requirement}.json",
                {"id": requirement},
            )
            golden_path = (
                "ios/harness/goldens/android-legado-v1/"
                "il-integration-backup-webdav-001.json"
            )
            self.write(
                root,
                golden_path,
                {
                    "fixture_id": "il-integration-backup-webdav-001",
                    "oracle": {"android_git_commit": "a" * 40},
                },
            )
            claim_ref = {
                "id": "BKC-INTEGRATION-WEBDAV-001",
                "revision": 3,
            }
            self.write(
                root,
                "ios/project/business-knowledge/packets/published/"
                "BKP-INTEGRATION-WEBDAV-001/r0001.json",
                {
                    "claims": [
                        {
                            **claim_ref,
                            "support": {
                                "source_anchors": [
                                    {
                                        "android_commit": "a" * 40,
                                        "path": "WebDav.kt",
                                        "symbol_id": "WebDav",
                                        "git_blob": "b" * 40,
                                    }
                                ]
                            },
                        }
                    ]
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/drivers/published/"
                "DRV-INTEGRATION-WEBDAV-RUNTIME-001/r0001.json",
                {
                    "id": "DRV-INTEGRATION-WEBDAV-RUNTIME-001",
                    "revision": 1,
                    "status": "active",
                    "title": "WebDAV 架构决策",
                    "claim_refs": [claim_ref],
                    "resolution": {
                        "state": "requires_adr",
                        "adr_refs": [],
                        "work_item_refs": [],
                    },
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/coverage/"
                "BKL-INTEGRATION-WEBDAV.json",
                {
                    "status": "current",
                    "packet_refs": [
                        {
                            "id": "BKP-INTEGRATION-WEBDAV-001",
                            "revision": 1,
                        }
                    ],
                    "entries": [
                        {
                            "claim_ref": claim_ref,
                            "validation": {
                                "evidence_refs": [golden_path]
                            },
                            "product_disposition": {
                                "kind": "architecture_driver",
                                "refs": [
                                    "DRV-INTEGRATION-WEBDAV-RUNTIME-001@1"
                                ],
                            },
                            "delivery": {
                                "state": "planned",
                                "requirement_refs": [
                                    f"{requirement}@1#RC-01"
                                ],
                                "work_item_refs": [
                                    (
                                        "IOS-INTEGRATION-WEBDAV-"
                                        "ARCHITECTURE-001"
                                    )
                                ],
                            },
                        }
                    ],
                },
            )

            task = loop.next_task(root)

            self.assertEqual(
                "IOS-INTEGRATION-WEBDAV-ARCHITECTURE-001",
                task["id"],
            )
            self.assertEqual(
                "ArchitectureControl",
                task["architecture"]["owner"],
            )
            self.assertEqual(
                "ADR-0008",
                task["source"]["architecture_decision"]["id"],
            )
            self.assertEqual(
                "architecture_decision",
                task["acceptance"]["structured_output"]["mode"],
            )
            self.assertNotIn(
                "ios/Packages/LegadoKit/Package.swift",
                task["scope"]["allowed_paths"],
            )
            loop.validate_task(root, task)
            decision = task["source"]["architecture_decision"]
            adr_path = root / decision["path"]
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            sections = "\n".join(
                f"## {value}\n内容"
                for value in (
                    "Context",
                    "Decision",
                    "Alternatives",
                    "Consequences",
                    "Architecture / Capability Impact",
                    "Compatibility / Data Migration",
                    "Validation",
                    "Rollback",
                    "Human Review",
                )
            )
            adr_path.write_text(
                "---\nid: ADR-0008\nstatus: accepted\n---\n"
                "首版不引入 WebDAV 三方库，使用 URLSession 和 XMLParser。\n"
                f"{sections}\n",
                encoding="utf-8",
            )
            architecture_path = root / "ios/docs/architecture.md"
            architecture_path.parent.mkdir(parents=True, exist_ok=True)
            architecture_path.write_text(
                "ADR-0008 `IntegrationKit` `WebDAVFoundation` "
                "`AppUseCases`\n",
                encoding="utf-8",
            )
            self.write(
                root,
                "ios/harness/architecture-rules.json",
                {
                    "known_project_modules": list(
                        decision["required_targets"]
                    ),
                    "targets": {
                        key: {"dependencies": value}
                        for key, value in decision[
                            "required_targets"
                        ].items()
                    },
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/drivers/published/"
                "DRV-INTEGRATION-WEBDAV-RUNTIME-001/r0002.json",
                {
                    "id": "DRV-INTEGRATION-WEBDAV-RUNTIME-001",
                    "revision": 2,
                    "status": "resolved",
                    "resolution": {
                        "state": "resolved",
                        "adr_refs": ["ADR-0008"],
                    },
                    "supersedes": {
                        "id": "DRV-INTEGRATION-WEBDAV-RUNTIME-001",
                        "revision": 1,
                    },
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/coverage/"
                "BKL-INTEGRATION-WEBDAV.json",
                {
                    "entries": [
                        {
                            "claim_ref": claim_ref,
                            "product_disposition": {
                                "refs": [
                                    "DRV-INTEGRATION-WEBDAV-RUNTIME-001@2"
                                ]
                            },
                            "delivery": {"state": "not_ready"},
                        }
                    ]
                },
            )

            failures, observed = loop.validate_architecture_decision(
                root,
                task,
                task["acceptance"]["structured_output"],
            )

            self.assertEqual([], failures)
            self.assertIsNotNone(observed)

    def test_project_charter_fails_closed_on_android_baseline_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/requirements/accepted/"
                "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001.json",
                {
                    "id": "REQ-ANDROID-MIGRATION-CHARACTERIZATION-001",
                    "revision": 1,
                    "status": "accepted",
                    "origin": {
                        "kind": "ios_product_decision",
                        "baseline_commit": "b" * 40,
                        "admission": "policy_auto",
                    },
                    "clauses": [{"id": "RC-01"}],
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-UNCLAIMED-001/r0001.json",
                {
                    "id": "BKP-UNCLAIMED-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-UNCLAIMED-RUNTIME-001",
                            "revision": 1,
                            "semantic_key": "source.rule.unclaimed-runtime",
                            "subject_keys": ["source.rule"],
                            "depends_on": [],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "android_characterization",
                                "source_anchors": [
                                    {"path": "AnalyzeRule.kt"}
                                ],
                            },
                        }
                    ],
                },
            )

            self.assertIsNone(loop.next_task(root))

    def test_human_decision_claim_does_not_unlock_characterization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write(
                root,
                "ios/project/migration-intents/MINT-SOURCE-REQUEST-001.json",
                {
                    "id": "MINT-SOURCE-REQUEST-001",
                    "android_baseline": {"commit": "a" * 40},
                    "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                    "requirement_binding": {
                        "id": "REQ-ANDROID-SOURCE-PIPELINE-001",
                        "revision": 1,
                        "clauses": ["RC-01"],
                    },
                },
            )
            self.write(
                root,
                "ios/project/business-knowledge/packets/proposals/"
                "BKP-SOURCE-REQUEST-001/r0001.json",
                {
                    "id": "BKP-SOURCE-REQUEST-001",
                    "revision": 1,
                    "status": "candidate",
                    "baseline": {"android_commit": "a" * 40},
                    "claims": [
                        {
                            "id": "BKC-HUMAN-DECISION-001",
                            "revision": 1,
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "human_decision",
                                "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                            },
                        },
                        {
                            "id": "BKC-RUNTIME-TEMPLATE-001",
                            "revision": 1,
                            "semantic_key": "source.request.template-runtime",
                            "subject_keys": ["source.request"],
                            "depends_on": [
                                {"id": "BKC-HUMAN-DECISION-001", "revision": 1}
                            ],
                            "support": {
                                "state": "candidate_source_anchored",
                                "runtime_requirement": "android_characterization",
                                "source_anchors": [{"path": "AnalyzeUrl.kt"}],
                            },
                        },
                    ],
                },
            )

            self.assertIsNone(loop.next_task(root))

    def test_changed_paths_preserves_first_porcelain_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.init_git(root)
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

    def test_acceptance_requires_nonzero_test_count(self):
        for count, expected in ((0, False), (36, True)):
            with self.subTest(count=count):
                with tempfile.TemporaryDirectory() as directory:
                    passed, checks = self.run_test_count_acceptance(
                        Path(directory),
                        count,
                    )
                self.assertEqual(expected, passed)
                self.assertEqual(
                    expected,
                    checks[0]["output_assertion_passed"],
                )

    def test_acceptance_rejects_exit_zero_with_invalid_structured_output(self):
        cases = [
            (
                {
                    "fixture_id": "fixture",
                    "status": "equal",
                    "android_expected": {},
                },
                False,
            ),
            (
                {
                    "fixture_id": "fixture",
                    "status": "equal",
                    "android_expected": {},
                    "ios_actual": {},
                    "canonical_request_plan": [],
                    "first_divergence": None,
                },
                True,
            ),
        ]
        for payload, expected in cases:
            with self.subTest(expected=expected):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    self.init_git(root)
                    subprocess.run(
                        ["git", "commit", "--allow-empty", "-qm", "base"],
                        cwd=root,
                        check=True,
                    )
                    task = {
                        "id": "IOS-TEST-STRUCTURED-001",
                        "acceptance": {
                            "commands": [
                                {
                                    "id": "structured",
                                    "argv": [
                                        sys.executable,
                                        "-c",
                                        "import sys;sys.stdout.write(sys.argv[1])",
                                        json.dumps(payload),
                                    ],
                                }
                            ],
                            "structured_output": {
                                "mode": "command_json",
                                "command_id": "structured",
                                "fixture_id": "fixture",
                                "expected": "golden.json",
                                "required_fields": [
                                    "android_expected",
                                    "ios_actual",
                                    "canonical_request_plan",
                                    "first_divergence",
                                ],
                                "expected_values": {
                                    "fixture_id": "fixture",
                                    "status": "equal",
                                    "first_divergence": None,
                                },
                            },
                        },
                    }

                    passed, checks, _ = loop.run_acceptance(
                        root,
                        task,
                        attempt=1,
                        paths=[],
                    )

                self.assertEqual(expected, passed)
                self.assertEqual(
                    expected,
                    checks[-1]["structured_output_passed"],
                )

    def test_android_golden_contract_uses_the_golden_directly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture_id = "sl-contract-001"
            golden_relative = (
                "ios/harness/goldens/android-legado-v1/"
                f"{fixture_id}.json"
            )
            golden = {
                "fixture_id": fixture_id,
                "artifact": {
                    "fixture_id": fixture_id,
                    "request_plan": [],
                    "result": {
                        "value": {"portable_known_projection": {}}
                    },
                },
                "oracle": {
                    "android_git_commit": "a" * 40,
                    "runner_digest": "b" * 64,
                },
            }
            self.write(root, golden_relative, golden)
            golden_sha256 = loop.digest((root / golden_relative).read_bytes())
            contract = {
                "fixture_id": fixture_id,
                "expected": golden_relative,
                "required_fields": [
                    "artifact.request_plan",
                    "artifact.result.value.portable_known_projection",
                    "oracle.android_git_commit",
                    "oracle.runner_digest",
                ],
            }

            failures, observed = loop.validate_android_golden(
                root,
                contract,
            )

            self.assertEqual([], failures)
            self.assertEqual(golden_sha256, observed)

    def test_projection_replays_task_lifecycle_and_memory(self):
        events = [
            {
                "schema_version": 2,
                "sequence": 1,
                "at": "2026-07-29T00:00:00Z",
                "event": "task_started",
                "task_id": "IOS-TEST-001",
            },
            {
                "schema_version": 2,
                "sequence": 2,
                "at": "2026-07-29T00:01:00Z",
                "event": "verification_passed",
                "task_id": "IOS-TEST-001",
                "details": {
                    "attempt": 1,
                    "passed": True,
                },
            },
            {
                "schema_version": 2,
                "sequence": 3,
                "at": "2026-07-29T00:02:00Z",
                "event": "task_completed",
                "task_id": "IOS-TEST-001",
                "details": {
                    "summary": "done",
                    "current_status": "capability available",
                    "architecture_change": "none",
                    "pitfalls": [],
                    "next_step": "next",
                },
            },
        ]

        projected = loop.project_current(events)

        self.assertEqual("idle", projected["status"])
        self.assertEqual(
            {
                "task_id": "IOS-TEST-001",
                "sequence": 3,
                "at": "2026-07-29T00:02:00Z",
            },
            projected["last_completed"],
        )

    def test_exclusive_lock_rejects_concurrent_driver(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            with loop.exclusive_lock(root):
                with self.assertRaisesRegex(loop.LoopError, "LOOP_BUSY"):
                    with loop.exclusive_lock(root):
                        self.fail("second driver acquired the same lock")

    def test_advance_starts_once_and_waits_for_product_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.init_git(root)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "fixture"],
                cwd=root,
                check=True,
            )

            started = loop.advance(root)
            waiting = loop.advance(root)

            self.assertEqual("implement", started["action"])
            self.assertEqual("implement", waiting["action"])
            self.assertEqual(
                "IOS-SOURCE-RUNTIME-POST-FORM-001",
                waiting["task"]["id"],
            )
            self.assertEqual(1, len(loop.load_events(root)))

    def test_advance_does_not_repeat_unchanged_failed_workspace(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.init_git(root)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "fixture"],
                cwd=root,
                check=True,
            )
            loop.advance(root)
            changed = (
                root
                / "ios/Packages/LegadoKit/Sources/SourceRuntime/Change.swift"
            )
            changed.parent.mkdir(parents=True)
            changed.write_text("struct Change {}\n", encoding="utf-8")

            failed = loop.advance(root)
            unchanged = loop.advance(root)

            self.assertEqual("verification_failed", failed["status"])
            self.assertEqual("repair", unchanged["action"])
            self.assertEqual(1, unchanged["verification"]["attempt"])
            self.assertEqual(2, len(loop.load_events(root)))

    def test_reconcile_rebuilds_current_projection_after_interruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.init_git(root)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "fixture"],
                cwd=root,
                check=True,
            )
            loop.advance(root)
            loop.write_json(root / loop.CURRENT_PATH, loop.initial_current())

            result = loop.reconcile(root)

            self.assertEqual("reconciled", result["status"])
            self.assertIn("rebuilt_current_projection", result["repairs"])
            self.assertEqual("running", loop.current(root)["status"])

    def test_advance_records_real_memory_and_closes_verified_task(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            self.init_git(root)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "fixture"],
                cwd=root,
                check=True,
            )
            loop.advance(root)
            task = loop.read_json(root / loop.TASK_PATH)
            paths = loop.changed_paths(root, task["base_commit"])
            verification = {
                "passed": True,
                "attempt": 1,
                "head_commit": loop.git(root, "rev-parse", "HEAD"),
                "workspace_sha256": loop.workspace_digest(root, paths),
                "changed_paths": paths,
                "runtime": ".harness-runtime/loop/test/attempt-1",
                "checks": [],
            }
            loop.append_event(
                root,
                "verification_passed",
                task_id=task["id"],
                details=verification,
            )
            loop.write_json(
                root / loop.CURRENT_PATH,
                loop.project_current(loop.load_events(root)),
            )

            result = loop.advance(
                root,
                summary="implemented",
                current_status="available with one known boundary",
                architecture_change="none",
                pitfall=["keep inputs deterministic"],
                next_step="continue",
            )

            self.assertEqual("done", result["action"])
            self.assertEqual("queue_empty", result["status"])
            self.assertFalse((root / loop.TASK_PATH).exists())
            completed = loop.load_events(root)[-1]
            self.assertEqual("task_completed", completed["event"])
            self.assertEqual(
                "available with one known boundary",
                completed["details"]["current_status"],
            )

    def test_completion_rejects_empty_project_memory(self):
        with self.assertRaisesRegex(
            loop.LoopError,
            "COMPLETION_KNOWLEDGE_INVALID",
        ):
            loop.complete(
                Path("."),
                summary="",
                current_status="",
                architecture_change="",
                pitfall=[],
                next_step="",
            )

    def test_detail_staging_delivery_order_and_contracts_are_explicit(self):
        policy = {
            "id": "MILESTONE-P0",
            "stages": [
                {
                    "id": "P0-BOOK",
                    "title": "Book",
                    "selectors": [
                        {
                            "id": "GRDB",
                            "task_ids": [
                                "IOS-DEPENDENCY-GRDB-PERSISTENCE-001"
                            ],
                        },
                        {
                            "id": "DOMAIN",
                            "task_ids": [
                                (
                                    "IOS-LIBRARY-DOMAIN-BOOK-DETAIL-"
                                    "STAGING-RUNTIME-001"
                                )
                            ],
                        },
                        {
                            "id": "UI",
                            "task_ids": [
                                (
                                    "IOS-APP-NAVIGATION-BOOK-DETAIL-"
                                    "STAGING-001"
                                )
                            ],
                        },
                    ],
                }
            ],
        }
        expected = [
            ("IOS-DEPENDENCY-GRDB-PERSISTENCE-001", "GRDB"),
            (
                "IOS-LIBRARY-DOMAIN-BOOK-DETAIL-STAGING-RUNTIME-001",
                "DOMAIN",
            ),
            (
                "IOS-APP-NAVIGATION-BOOK-DETAIL-STAGING-001",
                "UI",
            ),
        ]
        for task_id, selector_id in expected:
            match = loop.priority_match(
                policy,
                task_id=task_id,
                claim_ids={"BKC-BOOK-DETAIL-STAGING-001"},
            )
            self.assertIsNotNone(match)
            self.assertEqual(selector_id, match[3]["id"])

        dependency = loop.owner_contract(
            "IOS-DEPENDENCY-GRDB-PERSISTENCE-001"
        )
        self.assertEqual("DependencyControl", dependency["owner"])
        ui = loop.app_navigation_delivery_contract(
            "rl-library-book-detail-staging-runtime-001"
        )
        self.assertEqual(
            "testBookDetailStagingPersistence",
            ui["ui_acceptance"]["test_method"],
        )
        ui_owner = loop.owner_contract(
            "IOS-APP-NAVIGATION-BOOK-DETAIL-STAGING-001"
        )
        self.assertIn(
            "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
            ui_owner["allowed_paths"],
        )
        self.assertIn(
            "ios/Packages/LegadoKit/Tests/DatabaseGRDBTests/**",
            ui_owner["allowed_paths"],
        )

        toc_ui = loop.app_navigation_delivery_contract(
            "rl-library-chapter-toc-update-runtime-001"
        )
        self.assertEqual(
            "testChapterTOCFlow",
            toc_ui["ui_acceptance"]["test_method"],
        )
        toc_owner = loop.owner_contract(
            "IOS-APP-NAVIGATION-CHAPTER-TOC-001"
        )
        for path in (
            "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
            "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
            "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
        ):
            self.assertIn(path, toc_owner["allowed_paths"])

        reader_ui = loop.app_navigation_delivery_contract(
            "rl-ui-reader-toc-result-001"
        )
        self.assertEqual(
            "testReaderContentFlow",
            reader_ui["ui_acceptance"]["test_method"],
        )
        reader_owner = loop.owner_contract(
            "IOS-APP-NAVIGATION-READER-CONTENT-001"
        )
        for path in (
            "ios/Packages/LegadoKit/Sources/LibraryDomain/**",
            "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
            "ios/Packages/LegadoKit/Sources/ReaderCore/**",
            "ios/Packages/LegadoKit/Sources/DatabaseGRDB/**",
        ):
            self.assertIn(path, reader_owner["allowed_paths"])


if __name__ == "__main__":
    unittest.main()
