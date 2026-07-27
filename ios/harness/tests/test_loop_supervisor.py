import contextlib
import http.client
import io
import json
import shutil
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import urlparse


HARNESS_DIR = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(HARNESS_DIR))
sys.path.insert(0, str(TESTS_DIR))

import harness as harness_module  # noqa: E402
import loop_supervisor  # noqa: E402
from test_harness import HarnessFixture  # noqa: E402


class InspectHarness:
    def __init__(self):
        self.errors = []
        self.warnings = []
        self.items = {
            "IOS-READY-001": {
                "metadata": {"priority": 10},
                "spec": {"depends_on": []},
            }
        }
        self.state_value = {
            "active_work_items": [],
            "work_items": {
                "IOS-READY-001": {"status": "ready"},
            },
        }
        self.events = []
        self.selected = "IOS-READY-001"

    def doctor(self):
        return self.errors, self.warnings

    def work_items(self):
        return self.items

    def state(self):
        return self.state_value

    def select_next(self, state, items):
        return self.selected

    def event_lines(self):
        return self.events


class LoopSupervisorInspectTests(unittest.TestCase):
    def test_inspect_distinguishes_doctor_ready_and_active_states(self):
        harness = InspectHarness()
        supervisor = loop_supervisor.LoopSupervisor(harness)
        self.assertEqual("ready", supervisor.inspect().state)
        self.assertEqual("READY_WORK_ITEM", supervisor.inspect().reason_code)

        harness.errors = ["broken event chain"]
        decision = supervisor.inspect()
        self.assertEqual("doctor_red", decision.state)
        self.assertEqual("DOCTOR_FAILED", decision.reason_code)
        self.assertTrue(decision.requires_human)

        harness.errors = []
        for status, expected, human in (
            ("implementing", "implementing", False),
            ("verified", "verified", False),
            ("awaiting_human", "awaiting_human", True),
        ):
            harness.state_value["active_work_items"] = ["IOS-READY-001"]
            harness.state_value["work_items"]["IOS-READY-001"]["status"] = status
            decision = supervisor.inspect()
            self.assertEqual(expected, decision.state)
            self.assertEqual(human, decision.requires_human)

    def test_inspect_distinguishes_dependency_terminal_and_empty(self):
        harness = InspectHarness()
        supervisor = loop_supervisor.LoopSupervisor(harness)
        harness.selected = None
        harness.items["IOS-READY-001"]["spec"]["depends_on"] = ["IOS-MISSING-001"]
        decision = supervisor.inspect()
        self.assertEqual("dependency_blocked", decision.state)
        self.assertEqual(
            ["IOS-MISSING-001"],
            decision.blockers[0]["incomplete_dependencies"],
        )

        harness.state_value["work_items"]["IOS-READY-001"]["status"] = "exhausted"
        harness.events = [
            {"sequence": 1, "event": "WorkItemCompleted", "work_item_id": "IOS-OLD-001"},
            {"sequence": 2, "event": "WorkItemExhausted", "work_item_id": "IOS-READY-001"},
        ]
        decision = supervisor.inspect()
        self.assertEqual("terminal_recovery", decision.state)
        self.assertEqual("IOS-READY-001", decision.work_item_id)

        harness.events.append(
            {"sequence": 3, "event": "WorkItemCompleted", "work_item_id": "IOS-FIX-001"}
        )
        decision = supervisor.inspect()
        self.assertEqual("queue_empty", decision.state)
        self.assertEqual("NO_MATERIALIZED_READY_WORK_ITEM", decision.reason_code)

        harness.state_value["work_items"]["IOS-READY-001"] = {
            "status": "blocked",
            "blocker": "baseline_red",
        }
        decision = supervisor.inspect()
        self.assertEqual("terminal_recovery", decision.state)
        self.assertEqual("BLOCKED_WORK_ITEM_REQUIRES_RESOLUTION", decision.reason_code)


class MaterializationFixture:
    def __init__(self, root: Path):
        self.root = root
        self.fixture = HarnessFixture(root)
        self.harness = self.fixture.initialize()
        self.candidate_root = root / loop_supervisor.CANDIDATE_ROOT

    def candidate(self, item_id: str = "IOS-CANDIDATE-001"):
        item = self.fixture.item(item_id, "CAP-BOOT", 80)
        path = self.candidate_root / f"{item_id}.json"
        self.fixture.write_json(
            str(path.relative_to(self.root)),
            item,
        )
        return path, item

    def refresh_status(self):
        state = self.harness.state()
        self.fixture.write_text(
            "ios/project/status.md",
            self.harness.render_status(state, self.harness.work_items()),
        )


class MaterializationTests(unittest.TestCase):
    def test_preflight_rejects_outside_symlink_and_incomplete_dependency(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            outside = fixture.root / "outside.json"
            fixture.fixture.write_json("outside.json", fixture.fixture.item("IOS-OUTSIDE-001", "CAP-BOOT", 1))
            with self.assertRaisesRegex(loop_supervisor.MaterializationConflict, "必须位于"):
                supervisor.preflight_candidate(outside)

            path, item = fixture.candidate()
            item["spec"]["depends_on"] = ["IOS-BOOT-001"]
            fixture.fixture.write_json(str(path.relative_to(fixture.root)), item)
            with self.assertRaisesRegex(loop_supervisor.MaterializationConflict, "依赖尚未"):
                supervisor.preflight_candidate(path)

            path.unlink()
            path.symlink_to(outside)
            with self.assertRaisesRegex(loop_supervisor.MaterializationConflict, "必须位于|普通 JSON"):
                supervisor.preflight_candidate(path)

    def test_preflight_rejects_explicit_allow_path_that_is_protected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate()
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/goldens/manifest.json"
            ]
            fixture.fixture.write_json(str(path.relative_to(fixture.root)), item)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "SCOPE_UNSATISFIABLE",
            ):
                supervisor.preflight_candidate(path)

    def test_materialize_writes_work_item_event_state_and_status(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate()
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            preview = supervisor.preflight_candidate(path)
            item_id = supervisor.materialize(preview, reason="unit test")
            self.assertEqual("IOS-CANDIDATE-001", item_id)
            target = fixture.root / "ios/harness/work-items/IOS-CANDIDATE-001.json"
            self.assertEqual(item, json.loads(target.read_text()))
            state = fixture.harness.state()
            self.assertEqual("ready", state["work_items"][item_id]["status"])
            event = fixture.harness.event_lines()[-1]
            self.assertEqual("WorkItemMaterialized", event["event"])
            self.assertEqual(preview.work_item_sha256, event["payload"]["work_item_sha256"])
            self.assertEqual(
                fixture.harness.render_status(state, fixture.harness.work_items()),
                (fixture.root / "ios/project/status.md").read_text(),
            )

    def test_materialization_rolls_back_all_files_on_partial_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, _ = fixture.candidate()
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            preview = supervisor.preflight_candidate(path)
            controlled = [
                fixture.root / "ios/project/events.jsonl",
                fixture.root / "ios/project/state.json",
                fixture.root / "ios/project/status.md",
            ]
            before = {path: path.read_bytes() for path in controlled}
            with mock.patch.object(
                fixture.harness,
                "write_state",
                side_effect=RuntimeError("simulated state failure"),
            ):
                with self.assertRaisesRegex(RuntimeError, "simulated"):
                    supervisor.materialize(preview, reason="unit test")
            self.assertFalse(
                (fixture.root / "ios/harness/work-items/IOS-CANDIDATE-001.json").exists()
            )
            self.assertEqual(before, {path: path.read_bytes() for path in controlled})

    def test_candidate_drift_and_event_head_drift_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate()
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            preview = supervisor.preflight_candidate(path)
            item["metadata"]["title"] = "changed"
            fixture.fixture.write_json(str(path.relative_to(fixture.root)), item)
            with self.assertRaisesRegex(loop_supervisor.MaterializationConflict, "发生变化"):
                supervisor.materialize(preview, reason="unit test")

            fixture = MaterializationFixture(Path(directory) / "second")
            path, _ = fixture.candidate()
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            preview = supervisor.preflight_candidate(path)
            state = fixture.harness.state()
            state["event_head"] = "f" * 64
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()
            with mock.patch.object(fixture.harness, "doctor", return_value=([], [])):
                with self.assertRaisesRegex(loop_supervisor.MaterializationConflict, "发生变化"):
                    supervisor.materialize(preview, reason="unit test")

    def test_cancelled_producer_keeps_permanent_output_reservation(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            old_id = "IOS-KNOWLEDGE-OLD-001"
            old = fixture.fixture.item(old_id, "CAP-BOOT", 1)
            old["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "produce",
                "claim_refs": [],
                "driver_refs": [],
                "coverage_refs": [],
                "produces": [
                    {"kind": "packet", "id": "BKP-TEST-001", "revision": 2}
                ],
                "expected_ledger_transitions": [],
                "context_budget": {"max_claims": 20, "max_bytes": 32768},
                "none_reason": None,
            }
            old["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = []
            fixture.fixture.write_json(f"ios/harness/work-items/{old_id}.json", old)
            state = fixture.harness.state()
            state["work_items"][old_id] = {
                "status": "cancelled",
                "attempt": 1,
                "last_evidence": None,
            }
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()

            candidate_id = "IOS-KNOWLEDGE-NEW-001"
            candidate = fixture.fixture.item(candidate_id, "CAP-BOOT", 1)
            candidate["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "produce",
                "claim_refs": [],
                "driver_refs": [],
                "coverage_refs": [],
                "produces": [
                    {"kind": "packet", "id": "BKP-TEST-001", "revision": 2}
                ],
                "expected_ledger_transitions": [],
                "context_budget": {"max_claims": 20, "max_bytes": 32768},
                "none_reason": None,
            }
            candidate["spec"]["scope"]["allow_write"] = [
                "ios/project/business-knowledge/packets/proposals/BKP-TEST-001/r0002.json"
            ]
            candidate["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = []
            candidate_path = fixture.candidate_root / f"{candidate_id}.json"
            fixture.fixture.write_json(
                str(candidate_path.relative_to(fixture.root)),
                candidate,
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(fixture.harness, "doctor", return_value=([], [])):
                with self.assertRaisesRegex(
                    loop_supervisor.MaterializationConflict,
                    r"owner=IOS-KNOWLEDGE-OLD-001 suggested_revision=3",
                ):
                    supervisor.preflight_candidate(candidate_path)


class MaterializationUITests(unittest.TestCase):
    @staticmethod
    def request(
        session,
        method,
        path,
        *,
        token="",
        origin=None,
    ):
        connection = http.client.HTTPConnection(
            loop_supervisor.LOOPBACK_HOST,
            session.port,
            timeout=3,
        )
        headers = {}
        body = None
        if method == "POST":
            body = "{}"
            headers = {
                "Content-Type": "application/json",
                "Origin": origin or session.expected_origin,
                "Sec-Fetch-Site": "same-origin",
                "X-Materialization-Token": token,
            }
        connection.request(method, path, body=body, headers=headers)
        response = connection.getresponse()
        payload = response.read()
        result = (response.status, dict(response.getheaders()), payload)
        connection.close()
        return result

    def test_one_click_materializes_and_token_is_not_public(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, _ = fixture.candidate()
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            session = loop_supervisor.MaterializationReviewSession(supervisor, path)
            opened = []
            session.open(opened.append)
            token = urlparse(opened[0]).fragment
            self.assertTrue(token)
            self.assertFalse(hasattr(session, "token"))
            self.assertFalse(hasattr(session, "approve"))
            thread = threading.Thread(target=session.serve)
            thread.start()
            status, headers, _ = self.request(
                session,
                "POST",
                "/api/approve",
                token=token,
            )
            thread.join(timeout=3)
            self.assertEqual(200, status)
            self.assertEqual("no-store, max-age=0", headers["Cache-Control"])
            self.assertEqual("IOS-CANDIDATE-001", session.outcome)
            self.assertTrue(
                (fixture.root / "ios/harness/work-items/IOS-CANDIDATE-001.json").exists()
            )

    def test_cross_origin_cancel_and_replay_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, _ = fixture.candidate()
            session = loop_supervisor.MaterializationReviewSession(
                loop_supervisor.LoopSupervisor(fixture.harness),
                path,
            )
            opened = []
            session.open(opened.append)
            token = urlparse(opened[0]).fragment
            thread = threading.Thread(target=session.serve)
            thread.start()
            status, _, _ = self.request(
                session,
                "POST",
                "/api/approve",
                token=token,
                origin="http://evil.invalid",
            )
            self.assertEqual(403, status)
            status, _, _ = self.request(
                session,
                "POST",
                "/api/cancel",
                token=token,
            )
            thread.join(timeout=3)
            self.assertEqual(200, status)
            self.assertEqual("cancelled", session.outcome)
            self.assertFalse(
                (fixture.root / "ios/harness/work-items/IOS-CANDIDATE-001.json").exists()
            )

    def test_cli_has_review_but_no_noninteractive_materialize(self):
        parser = loop_supervisor.build_parser()
        help_text = parser.format_help()
        self.assertIn("materialize-review", help_text)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(["materialize", "candidate.json"])


class DriveTests(unittest.TestCase):
    def test_drive_without_adapter_does_not_claim(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            config = fixture.root / "supervisor.json"
            fixture.fixture.write_json("supervisor.json", {"agent_invocation": None})
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            result = supervisor.drive(
                config_path=config,
                agent_id="unit-test",
                max_transitions=1,
            )
            self.assertEqual("agent_invocation_required", result["outcome"])
            self.assertEqual(
                "ready",
                fixture.harness.state()["work_items"]["IOS-BOOT-001"]["status"],
            )

    def test_drive_uses_argv_adapter_and_transition_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            config = root / "supervisor.json"
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [
                            sys.executable,
                            "-c",
                            "import os; print(os.environ['LEGADO_WORK_ITEM_ID'])",
                        ],
                        "timeout_seconds": 10,
                    }
                },
            )
            subprocess = __import__("subprocess")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            result = supervisor.drive(
                config_path=config,
                agent_id="unit-test",
                max_transitions=1,
            )
            self.assertEqual("transition_budget_reached", result["outcome"])
            self.assertEqual(0, result["transitions"][0]["exit_code"])
            self.assertEqual(
                "implementing",
                fixture.harness.state()["work_items"]["IOS-BOOT-001"]["status"],
            )


if __name__ == "__main__":
    unittest.main()
