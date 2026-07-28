import contextlib
import datetime as dt
import http.client
import io
import importlib
import json
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import urlsplit


HARNESS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_DIR))

import approval_ui  # noqa: E402
import harness as harness_module  # noqa: E402


ITEM_ID = "IOS-TEST-APPROVAL-001"
FIXED_NOW = dt.datetime(2026, 7, 24, 3, 0, tzinfo=dt.timezone.utc)
TEST_TOKEN = "test-secret"


class FakeHarness:
    def __init__(self, root: Path, gates=None):
        self.root = root
        self.config = {"approvals_dir": "ios/project/approvals"}
        self.gates = (
            list(gates)
            if gates is not None
            else ["architecture-review", "security-review"]
        )
        self.decisions = [
            {
                "gate": gate,
                "trigger": "always",
                "question": f"{gate} 应选择哪个方案？",
                "why_human": "两个方案都满足机器约束，需要项目所有者取舍。",
                "options": [
                    {
                        "id": "recommended",
                        "label": "采用推荐方案",
                        "consequence": "按当前推荐方向继续。",
                        "reversible": True,
                    },
                    {
                        "id": "alternative",
                        "label": "采用备选方案",
                        "consequence": "改用明确的备选方向。",
                        "reversible": True,
                    },
                ],
                "recommended_option": "recommended",
            }
            for gate in self.gates
        ]
        self.item = {
            "metadata": {"id": ITEM_ID, "title": "测试人工审批"},
            "spec": {
                "gates": list(self.gates),
                "gate_contract_version": 1,
                "decision_gates": list(self.decisions),
            },
        }
        evidence_relative = "ios/harness/evidence/runs/test-evidence.json"
        evidence_path = self.resolve(evidence_relative)
        evidence_path.parent.mkdir(parents=True, exist_ok=True)
        evidence_path.write_text('{"result":"passed"}\n', encoding="utf-8")
        self.subject = "a" * 64
        self.subject_files = {
            "ios/implementation.swift": "b" * 64,
            "ios/project/checkpoints/test.json": "c" * 64,
        }
        self._state = {
            "work_items": {
                ITEM_ID: {
                    "status": "awaiting_human",
                    "attempt": 2,
                    "work_item_sha256": approval_ui.sha256_json(self.item),
                    "review_subject_sha256": self.subject,
                    "review_subject_files": dict(self.subject_files),
                    "last_evidence": evidence_relative,
                    "last_evidence_sha256": approval_ui.sha256_file(evidence_path),
                }
            }
        }
        self.close_calls = 0
        self.fail_close = False

    def resolve(self, value: str) -> Path:
        return (self.root / value).resolve()

    def work_items(self):
        return {ITEM_ID: self.item}

    def state(self):
        return self._state

    def changed_since_claim(self, runtime):
        return sorted(self.subject_files)

    def required_close_gates(self, item_id, item, changed):
        return list(self.gates), []

    def decision_gate_contracts(self, item):
        return {
            decision["gate"]: decision
            for decision in self.decisions
        }, []

    def candidate_snapshot(self, runtime, approval_paths):
        return self.subject, dict(self.subject_files)

    def mutation_lock(self):
        return contextlib.nullcontext()

    def close(self, item_id):
        self.close_calls += 1
        if self.fail_close:
            raise harness_module.HarnessError("simulated close failure")
        for gate in self.gates:
            path = self.resolve(
                f"ios/project/approvals/{ITEM_ID}--{gate}.json"
            )
            if not path.exists():
                self._state["work_items"][ITEM_ID]["status"] = "awaiting_human"
                return "awaiting_human"
            approval = json.loads(path.read_text(encoding="utf-8"))
            self.assert_approval(approval, gate)
        self._state["work_items"][ITEM_ID]["status"] = "completed"
        return "completed"

    def approval_issues(
        self,
        item_id,
        item,
        tree_sha256,
        gates,
        *,
        requested_at=None,
        preexisting_fingerprints=None,
        evidence_sha256=None,
    ):
        errors = []
        contracts, _ = self.decision_gate_contracts(item)
        for gate in gates:
            path = self.resolve(
                f"ios/project/approvals/{ITEM_ID}--{gate}.json"
            )
            if not path.exists():
                errors.append(f"缺少人工批准：{gate}")
                continue
            approval = json.loads(path.read_text(encoding="utf-8"))
            if approval.get("decision_contract_sha256") != approval_ui.sha256_json(
                contracts[gate]
            ):
                errors.append(f"decision contract 摘要漂移：{gate}")
            if approval.get("selected_option") not in {
                "recommended",
                "alternative",
            }:
                errors.append(f"decision selected_option 无效：{gate}")
            if approval.get("evidence_sha256") != evidence_sha256:
                errors.append(f"decision 未绑定当前 Evidence：{gate}")
        return errors

    def assert_approval(self, approval, gate):
        if approval["work_item_id"] != ITEM_ID:
            raise AssertionError("wrong work item")
        if approval["gate"] != gate:
            raise AssertionError("wrong gate")
        if approval["work_item_sha256"] != approval_ui.sha256_json(self.item):
            raise AssertionError("wrong work item hash")
        if approval["tree_sha256"] != self.subject:
            raise AssertionError("wrong subject")
        decision = next(
            value for value in self.decisions if value["gate"] == gate
        )
        if approval["decision_contract_sha256"] != approval_ui.sha256_json(
            decision
        ):
            raise AssertionError("wrong decision contract")
        if approval["selected_option"] not in {"recommended", "alternative"}:
            raise AssertionError("wrong selected option")


class ApprovalUITests(unittest.TestCase):
    def make_session(self, root: Path, harness=None, session_ttl_seconds=30):
        harness = harness or FakeHarness(root)
        with mock.patch.object(
            approval_ui.secrets,
            "token_urlsafe",
            side_effect=[TEST_TOKEN, "page-nonce"],
        ):
            session = approval_ui.LocalApprovalSession(
                harness,
                ITEM_ID,
                clock=lambda: FIXED_NOW,
                session_ttl_seconds=session_ttl_seconds,
            )
        return harness, session

    @staticmethod
    def approval_headers(session, token=TEST_TOKEN, origin=None):
        return {
            "Content-Type": "application/json",
            "Origin": origin or session.expected_origin,
            "Sec-Fetch-Site": "same-origin",
            "X-Approval-Token": token,
        }

    def request(
        self,
        session,
        method,
        path,
        *,
        body=None,
        headers=None,
        start_handler=True,
    ):
        worker = None
        if start_handler:
            worker = threading.Thread(
                target=session.server.handle_request,
                daemon=True,
            )
            worker.start()
        connection = http.client.HTTPConnection(
            approval_ui.LOOPBACK_HOST,
            session.port,
            timeout=3,
        )
        request_headers = {"Host": session.expected_host}
        request_headers.update(headers or {})
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        payload = response.read()
        result = (response.status, dict(response.getheaders()), payload)
        connection.close()
        if worker is not None:
            worker.join(timeout=3)
            self.assertFalse(worker.is_alive())
        return result

    def approval_paths(self, root: Path, gates):
        return [
            root / f"ios/project/approvals/{ITEM_ID}--{gate}.json"
            for gate in gates
        ]

    def test_get_is_read_only_and_token_only_reaches_url_fragment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                status, headers, payload = self.request(session, "GET", "/")
                text = payload.decode("utf-8")
                self.assertEqual(200, status)
                self.assertNotIn(TEST_TOKEN, text)
                self.assertEqual("DENY", headers["X-Frame-Options"])
                self.assertEqual("close", headers["Connection"])
                self.assertIn("no-store", headers["Cache-Control"])
                self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
                self.assertIn(session.snapshot.review_subject_sha256, text)
                self.assertIn(session.snapshot.evidence_sha256, text)
                self.assertIn("architecture-review 应选择哪个方案", text)
                self.assertIn("采用推荐方案", text)
                self.assertNotIn("批准全部", text)
                self.assertNotIn("/api/approve", text)
                self.assertFalse(
                    any(path.exists() for path in self.approval_paths(root, harness.gates))
                )
            finally:
                session.server.server_close()

    def test_each_decision_requires_a_separate_choice_before_close(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            opened = threading.Event()
            opened_urls = []
            result = {}

            def opener(url):
                opened_urls.append(url)
                opened.set()
                return True

            def serve():
                try:
                    result["outcome"] = session.serve(browser_opener=opener)
                except Exception as error:  # pragma: no cover - asserted below
                    result["error"] = error

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            self.assertTrue(opened.wait(timeout=3))
            parsed = urlsplit(opened_urls[0])
            self.assertEqual("", parsed.query)
            self.assertEqual(TEST_TOKEN, parsed.fragment)

            status, _, payload = self.request(
                session,
                "POST",
                "/api/decide",
                body='{"selected_option":"recommended"}',
                headers=self.approval_headers(session),
                start_handler=False,
            )
            self.assertEqual(200, status, payload)
            worker.join(timeout=3)
            self.assertFalse(worker.is_alive())
            self.assertNotIn("error", result)
            self.assertEqual("human_decision_pending", result["outcome"])
            self.assertEqual(1, harness.close_calls)

            paths = self.approval_paths(root, harness.gates)
            self.assertTrue(paths[0].exists())
            self.assertFalse(paths[1].exists())
            approval = json.loads(paths[0].read_text(encoding="utf-8"))
            self.assertEqual(1, approval["schema_version"])
            self.assertEqual("recommended", approval["selected_option"])
            self.assertTrue(approval["reviewer"].startswith("local-user:"))
            self.assertEqual("2026-07-24T03:00:00Z", approval["presented_at"])
            self.assertEqual("2026-07-24T03:00:00Z", approval["decided_at"])
            self.assertEqual("2026-07-24T03:00:00Z", approval["approved_at"])
            self.assertEqual("2026-07-25T03:00:00Z", approval["expires_at"])
            self.assertIsNone(approval["signature"])

            _, second = self.make_session(root, harness=harness)
            try:
                self.assertEqual("security-review", second.snapshot.active_gate)
                status, _, payload = self.request(
                    second,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"alternative"}',
                    headers=self.approval_headers(second),
                )
                self.assertEqual(200, status, payload)
                self.assertEqual("completed", second.outcome)
                self.assertEqual(2, harness.close_calls)
                self.assertTrue(paths[1].exists())
            finally:
                second.server.server_close()

    def test_wrong_token_and_cross_origin_cannot_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                common = {
                    "Content-Type": "application/json",
                    "Origin": session.expected_origin,
                    "X-Approval-Token": "wrong",
                }
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=common,
                )
                self.assertEqual(403, status)
                common["Origin"] = "https://attacker.invalid"
                common["X-Approval-Token"] = TEST_TOKEN
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=common,
                )
                self.assertEqual(403, status)
                self.assertEqual(0, harness.close_calls)
                self.assertFalse(
                    any(path.exists() for path in self.approval_paths(root, harness.gates))
                )
            finally:
                session.server.server_close()

    def test_missing_unknown_or_cross_gate_option_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body="{}",
                    headers=self.approval_headers(session),
                )
                self.assertEqual(400, status)
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"security-review"}',
                    headers=self.approval_headers(session),
                )
                self.assertEqual(403, status)
                self.assertEqual(0, harness.close_calls)
                self.assertFalse(
                    any(
                        path.exists()
                        for path in self.approval_paths(root, harness.gates)
                    )
                )
            finally:
                session.server.server_close()

    def test_legacy_unstructured_gate_has_no_local_bulk_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = FakeHarness(root, gates=["architecture-review"])
            harness.item["spec"].pop("gate_contract_version")
            harness.item["spec"].pop("decision_gates")
            harness._state["work_items"][ITEM_ID][
                "work_item_sha256"
            ] = approval_ui.sha256_json(harness.item)
            with self.assertRaisesRegex(
                approval_ui.ApprovalUIError,
                "旧式批量 Approval 已禁用",
            ):
                approval_ui.LocalApprovalSession(harness, ITEM_ID)

    def test_invalid_host_fetch_site_and_large_body_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers={
                        **self.approval_headers(session),
                        "Host": "attacker.invalid",
                    },
                )
                self.assertEqual(400, status)
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers={
                        **self.approval_headers(session),
                        "Sec-Fetch-Site": "cross-site",
                    },
                )
                self.assertEqual(403, status)
                status, _, _ = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body="x" * (approval_ui.MAX_REQUEST_BYTES + 1),
                    headers=self.approval_headers(session),
                )
                self.assertEqual(413, status)
                self.assertEqual(0, harness.close_calls)
            finally:
                session.server.server_close()

    def test_cancel_consumes_session_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                status, _, payload = self.request(
                    session,
                    "POST",
                    "/api/cancel",
                    body="{}",
                    headers=self.approval_headers(session),
                )
                self.assertEqual(200, status, payload)
                self.assertEqual("cancelled", session.outcome)
                self.assertTrue(session.consumed)
                self.assertEqual(0, harness.close_calls)
                self.assertFalse(
                    any(path.exists() for path in self.approval_paths(root, harness.gates))
                )
            finally:
                session.server.server_close()

    def test_expired_session_rejects_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(
                root,
                session_ttl_seconds=0,
            )
            try:
                status, _, payload = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=self.approval_headers(session),
                )
                self.assertEqual(409, status, payload)
                self.assertEqual(0, harness.close_calls)
            finally:
                session.server.server_close()

    def test_stale_subject_fails_closed_without_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                harness.subject = "d" * 64
                status, _, payload = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=self.approval_headers(session),
                )
                self.assertEqual(409, status, payload)
                self.assertEqual(0, harness.close_calls)
                self.assertFalse(
                    any(path.exists() for path in self.approval_paths(root, harness.gates))
                )
            finally:
                session.server.server_close()

    def test_unsafe_gate_cannot_escape_approval_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = FakeHarness(root, gates=["../escape"])
            with self.assertRaisesRegex(approval_ui.ApprovalUIError, "不安全"):
                self.make_session(root, harness=harness)
            self.assertFalse((root / "ios/project/escape.json").exists())

    def test_token_is_one_time_and_replay_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness, session = self.make_session(root)
            try:
                status, _, payload = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=self.approval_headers(session),
                )
                self.assertEqual(200, status, payload)
                status, _, payload = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=self.approval_headers(session),
                )
                self.assertEqual(409, status, payload)
                self.assertEqual(1, harness.close_calls)
            finally:
                session.server.server_close()

    def test_multi_file_replace_failure_rolls_back_approval_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            targets = [
                root / "approvals/first.json",
                root / "approvals/second.json",
            ]
            transaction = approval_ui.ApprovalFileTransaction(
                [
                    (targets[0], {"gate": "first"}),
                    (targets[1], {"gate": "second"}),
                ]
            )
            original_replace = approval_ui.os.replace
            pending_replaces = 0

            def flaky_replace(source, destination):
                nonlocal pending_replaces
                if ".pending." in Path(source).name:
                    pending_replaces += 1
                    if pending_replaces == 2:
                        raise OSError("simulated second replace failure")
                return original_replace(source, destination)

            with mock.patch.object(
                approval_ui.os,
                "replace",
                side_effect=flaky_replace,
            ):
                with self.assertRaisesRegex(OSError, "second replace"):
                    transaction.commit()
            self.assertFalse(any(path.exists() for path in targets))
            self.assertEqual([], list((root / "approvals").glob(".*.pending.*")))

    def test_close_failure_keeps_decision_for_direct_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = FakeHarness(root, gates=["architecture-review"])
            harness.fail_close = True
            _, session = self.make_session(root, harness=harness)
            try:
                status, _, payload = self.request(
                    session,
                    "POST",
                    "/api/decide",
                    body='{"selected_option":"recommended"}',
                    headers=self.approval_headers(session),
                )
                self.assertEqual(202, status, payload)
                self.assertEqual("recovery_required", session.outcome)
                self.assertTrue(
                    all(path.exists() for path in self.approval_paths(root, harness.gates))
                )
                harness.fail_close = False
                self.assertEqual("completed", harness.close(ITEM_ID))
            finally:
                session.server.server_close()

    def test_get_connection_cannot_starve_followup_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = FakeHarness(root, gates=["architecture-review"])
            _, session = self.make_session(root, harness=harness)
            opened = threading.Event()
            result = {}

            def serve():
                try:
                    result["outcome"] = session.serve(
                        browser_opener=lambda url: opened.set() or True
                    )
                except Exception as error:  # pragma: no cover - asserted below
                    result["error"] = error

            worker = threading.Thread(target=serve, daemon=True)
            worker.start()
            self.assertTrue(opened.wait(timeout=3))

            first_connection = http.client.HTTPConnection(
                approval_ui.LOOPBACK_HOST,
                session.port,
                timeout=3,
            )
            first_connection.request("GET", "/", headers={"Host": session.expected_host})
            first_response = first_connection.getresponse()
            self.assertEqual(200, first_response.status)
            first_response.read()
            self.assertEqual("close", first_response.getheader("Connection"))

            status, _, payload = self.request(
                session,
                "POST",
                "/api/decide",
                body='{"selected_option":"recommended"}',
                headers=self.approval_headers(session),
                start_handler=False,
            )
            self.assertEqual(200, status, payload)
            worker.join(timeout=3)
            first_connection.close()
            self.assertFalse(worker.is_alive())
            self.assertNotIn("error", result)
            self.assertEqual("completed", result["outcome"])
            self.assertEqual(1, harness.close_calls)

    def test_cli_has_review_but_no_noninteractive_approval_flags(self):
        parser = harness_module.build_parser()
        args = parser.parse_args(["review", ITEM_ID])
        self.assertEqual("review", args.command)
        self.assertEqual(ITEM_ID, args.item_id)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(["review", ITEM_ID, "--reviewer", "fake"])
            with self.assertRaises(SystemExit):
                parser.parse_args(["review", ITEM_ID, "--yes"])

    def test_session_has_no_public_token_or_approve_method(self):
        with tempfile.TemporaryDirectory() as directory:
            _, session = self.make_session(Path(directory))
            try:
                self.assertFalse(hasattr(session, "token"))
                self.assertFalse(hasattr(session, "approve"))
                self.assertFalse(hasattr(session, "_approve_from_http"))
                self.assertFalse(hasattr(session, "_cancel_from_http"))
            finally:
                session.server.server_close()

    def test_package_module_review_import_path_is_valid(self):
        packaged_harness = importlib.import_module("ios.harness.harness")
        packaged_ui = importlib.import_module("ios.harness.approval_ui")
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(
                packaged_harness,
                "Harness",
                return_value=object(),
            ), mock.patch.object(
                packaged_ui,
                "run_local_review",
                return_value="completed",
            ), contextlib.redirect_stdout(io.StringIO()):
                result = packaged_harness.main(
                    [
                        "--root",
                        directory,
                        "review",
                        ITEM_ID,
                    ]
                )
        self.assertEqual(0, result)

    def test_only_frozen_awaiting_human_item_can_open(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = FakeHarness(root)
            harness._state["work_items"][ITEM_ID]["status"] = "verified"
            with self.assertRaisesRegex(approval_ui.ApprovalUIError, "awaiting_human"):
                approval_ui.LocalApprovalSession(harness, ITEM_ID)


if __name__ == "__main__":
    unittest.main()
