import contextlib
import copy
import json
import os
import socket
import subprocess
import sys
import tempfile
import textwrap
import unittest
import urllib.request
from pathlib import Path
from unittest import mock


SOURCE_LAB_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SOURCE_LAB_ROOT.parents[2]
sys.path.insert(0, str(SOURCE_LAB_ROOT))

import source_lab  # noqa: E402


class SourceLabTests(unittest.TestCase):
    scenario = "sl-html-basic-001"

    def oracle_workflow(self):
        return (
            REPO_ROOT
            / ".github/workflows/android-oracle-attestation.yml"
        ).read_text()

    def oracle_selector_script(self):
        workflow = self.oracle_workflow()
        marker = "      - name: Resolve trusted Oracle scenario\n"
        block = workflow.split(marker, 1)[1].split(
            "\n      - name:", 1
        )[0]
        script = block.split("        run: |\n", 1)[1]
        return textwrap.dedent(script)

    def run_oracle_selector(
        self,
        *,
        event,
        ref,
        sha="0123456789abcdef0123456789abcdef01234567",
        scenario="",
    ):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / "env"
            output_file = Path(directory) / "output"
            environment = os.environ.copy()
            environment.update(
                {
                    "GITHUB_EVENT_NAME": event,
                    "GITHUB_REF": ref,
                    "GITHUB_SHA": sha,
                    "DISPATCH_SCENARIO": scenario,
                    "GITHUB_ENV": str(env_file),
                    "GITHUB_OUTPUT": str(output_file),
                }
            )
            result = subprocess.run(
                ["bash", "-c", self.oracle_selector_script()],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            return (
                result,
                env_file.read_text() if env_file.exists() else "",
                output_file.read_text() if output_file.exists() else "",
            )

    def test_oracle_workflow_selector_accepts_manual_and_exact_push(self):
        sha = "0123456789abcdef0123456789abcdef01234567"
        for scenario in ("sl-html-basic-001", "sl-post-form-001"):
            with self.subTest(event="workflow_dispatch", scenario=scenario):
                result, env_value, output_value = self.run_oracle_selector(
                    event="workflow_dispatch",
                    ref="refs/heads/main",
                    scenario=scenario,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(
                    f"ORACLE_SCENARIO={scenario}\n", env_value
                )
                self.assertEqual(f"scenario={scenario}\n", output_value)
            with self.subTest(event="push", scenario=scenario):
                result, env_value, output_value = self.run_oracle_selector(
                    event="push",
                    ref=f"refs/heads/feature/oracle-{scenario}-{sha}",
                    sha=sha,
                )
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(
                    f"ORACLE_SCENARIO={scenario}\n", env_value
                )
                self.assertEqual(f"scenario={scenario}\n", output_value)

    def test_oracle_workflow_selector_rejects_untrusted_sources(self):
        sha = "0123456789abcdef0123456789abcdef01234567"
        invalid = (
            ("workflow_dispatch", "refs/heads/main", "", ""),
            ("workflow_dispatch", "refs/heads/main", sha, "unknown"),
            ("push", f"refs/heads/oracle-sl-html-basic-001-{sha}", sha, ""),
            ("push", "refs/heads/feature/oracle-sl-html-basic-001", sha, ""),
            (
                "push",
                "refs/heads/feature/oracle-sl-html-basic-001-"
                + ("f" * 40),
                sha,
                "",
            ),
            (
                "push",
                f"refs/heads/feature/oracle-path/sl-html-basic-001-{sha}",
                sha,
                "",
            ),
            ("pull_request", "refs/pull/1/merge", sha, ""),
        )
        for event, ref, source_sha, scenario in invalid:
            with self.subTest(event=event, ref=ref, scenario=scenario):
                result, env_value, output_value = self.run_oracle_selector(
                    event=event,
                    ref=ref,
                    sha=source_sha,
                    scenario=scenario,
                )
                self.assertNotEqual(0, result.returncode)
                self.assertEqual("", env_value)
                self.assertEqual("", output_value)

    def test_oracle_workflow_keeps_candidate_only_authority(self):
        workflow = self.oracle_workflow()
        selector_output = "${{ steps.selector.outputs.scenario }}"
        after_selector = workflow.split(
            "      - name: Checkout exact source", 1
        )[1]
        self.assertNotIn("inputs.scenario", after_selector)
        self.assertEqual(5, workflow.count(selector_output))
        self.assertIn("run-name:", workflow)
        self.assertIn("${{ github.ref }}", workflow)
        self.assertIn("  push:\n    branches:\n      - feature/oracle-*\n", workflow)
        self.assertIn("  contents: read\n", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("pull-requests:", workflow)
        self.assertNotIn("secrets:", workflow)
        self.assertNotIn("self-hosted", workflow)
        self.assertNotIn("Publisher", workflow)
        self.assertNotIn("goldens", workflow.lower())
        for uses in (
            line.split("uses:", 1)[1].strip()
            for line in workflow.splitlines()
            if "uses:" in line
        ):
            self.assertRegex(uses, r"^[^@\s]+@[0-9a-f]{40}$")

    def test_builds_android_book_source_for_logical_origin(self):
        source = source_lab.build_source(REPO_ROOT, self.scenario, source_lab.LOGICAL_ORIGIN)
        self.assertEqual(source_lab.LOGICAL_ORIGIN, source["bookSourceUrl"])
        self.assertIn("{{key}}", source["searchUrl"])
        self.assertEqual("@CSS:.book-item", source["ruleSearch"]["bookList"])
        self.assertFalse(any(source_lab.SOURCE_PLACEHOLDER in value for value in source_lab.recursive_strings(source)))

    def test_rejects_non_loopback_origin(self):
        with self.assertRaises(source_lab.SourceLabError):
            source_lab.build_source(REPO_ROOT, self.scenario, "https://example.com")

    def test_binds_once_to_exact_ipv4_loopback_and_ephemeral_port(self):
        with source_lab.running_server(REPO_ROOT, self.scenario) as server:
            host, port = server.server_address[:2]
            self.assertEqual("127.0.0.1", host)
            self.assertGreater(port, 0)
            source = source_lab.build_source(REPO_ROOT, self.scenario, f"http://{server.authority}")
            self.assertEqual(f"http://{server.authority}", source["bookSourceUrl"])

    def test_parallel_instances_do_not_share_listener_or_counter(self):
        with contextlib.ExitStack() as stack:
            servers = [stack.enter_context(source_lab.running_server(REPO_ROOT, self.scenario)) for _ in range(4)]
            ports = {server.server_address[1] for server in servers}
            self.assertEqual(4, len(ports))
            route = servers[0].case["transport"]["responses"][0]
            source_lab.request_route(servers[0], route)
            self.assertEqual(1, servers[0].request_count)
            self.assertEqual([0, 0, 0], [server.request_count for server in servers[1:]])

    def test_repeated_outputs_are_byte_identical_and_headers_fixed(self):
        directory, case, _ = source_lab.load_scenario(REPO_ROOT, self.scenario)
        route = case["transport"]["responses"][0]
        with source_lab.running_server(REPO_ROOT, self.scenario) as server:
            target = f"http://{server.authority}/"
            with urllib.request.urlopen(target, timeout=1) as first:
                first_body = first.read()
                first_headers = {key.lower(): value for key, value in first.headers.items()}
            with urllib.request.urlopen(target, timeout=1) as second:
                second_body = second.read()
                second_headers = {key.lower(): value for key, value in second.headers.items()}
            self.assertEqual(first_body, second_body)
            self.assertEqual(first_headers, second_headers)
            self.assertEqual(source_lab.FIXED_DATE, first_headers["date"])
            self.assertEqual("LegadoSourceLab/1", first_headers["server"])
            expected = source_lab.safe_child(directory, route["respond"]["body_file"]).read_bytes()
            self.assertEqual(expected, first_body)

    def test_verify_site_has_port_free_canonical_transcript(self):
        first = source_lab.verify_site(REPO_ROOT, self.scenario)
        second = source_lab.verify_site(REPO_ROOT, self.scenario)
        self.assertEqual(first, second)
        self.assertNotIn("127.0.0.1", json.dumps(first))

    def test_case_roles_are_behavior_specific(self):
        _, case, _ = source_lab.load_scenario(REPO_ROOT, self.scenario)
        coverage = {entry["behavior"]: entry["cases"] for entry in case["coverage"]}
        transport_roles = {
            entry["id"]: entry["role"] for entry in coverage["transport.get-query"]
        }
        search_roles = {
            entry["id"]: entry["role"] for entry in coverage["pipeline.search-html"]
        }
        self.assertEqual("nominal", transport_roles["search-empty"])
        self.assertEqual("boundary", search_roles["search-empty"])

    def test_nested_business_answer_keys_are_rejected(self):
        value = {"arguments": {"nested_expected_result": {"name": "hard-coded"}}}
        self.assertIn("nested_expected_result", source_lab.forbidden_business_keys(value))

    def test_teardown_closes_listener(self):
        with source_lab.running_server(REPO_ROOT, self.scenario) as server:
            address = server.server_address[:2]
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.2)
            self.assertNotEqual(0, probe.connect_ex(address))
        finally:
            probe.close()

    def test_android_oracle_can_characterize_completed_candidate(self):
        manifest = source_lab.manifest_value(REPO_ROOT)
        self.assertEqual(
            [],
            source_lab.validate_work_item_contract(
                REPO_ROOT,
                "IOS-ANDROID-POST-FORM-ORACLE-001",
                manifest,
            ),
        )
        self.assertEqual(
            [],
            source_lab.validate_work_item_contract(
                REPO_ROOT,
                "IOS-ANDROID-ORACLE-RUNNER-001",
                manifest,
            ),
        )

    def test_candidate_characterization_fails_closed_on_authority_drift(self):
        item_id = "IOS-ANDROID-POST-FORM-ORACLE-001"
        item_path = (
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{item_id}.json"
        )
        state_path = REPO_ROOT / "ios/project/state.json"
        item = source_lab.load_json(item_path)
        state = source_lab.load_json(state_path)
        manifest = source_lab.manifest_value(REPO_ROOT)
        original_load_json = source_lab.load_json

        def validate(mutated_item, mutated_state):
            def controlled_load_json(path):
                if path == item_path:
                    return mutated_item
                if path == state_path:
                    return mutated_state
                return original_load_json(path)

            with mock.patch.object(
                source_lab,
                "load_json",
                side_effect=controlled_load_json,
            ):
                return source_lab.validate_work_item_contract(
                    REPO_ROOT,
                    item_id,
                    manifest,
                )

        missing_label = copy.deepcopy(item)
        missing_label["metadata"]["labels"].remove("candidate-only")
        self.assertTrue(
            any(
                "candidate reuse 仅限" in value
                for value in validate(missing_label, state)
            )
        )

        fixture_write = copy.deepcopy(item)
        fixture_write["spec"]["scope"]["allow_write"].append(
            "ios/harness/fixtures/source-lab/sl-post-form-001/case.json"
        )
        self.assertTrue(
            any(
                "candidate characterization 禁止写入" in value
                for value in validate(fixture_write, state)
            )
        )

        incomplete_introducer = copy.deepcopy(state)
        incomplete_introducer["work_items"][
            "IOS-SOURCELAB-POST-FORM-001"
        ]["status"] = "implementing"
        self.assertTrue(
            any(
                "introduced_by 尚未完成合法 extend" in value
                for value in validate(item, incomplete_introducer)
            )
        )

    def test_control_recovery_must_bind_terminal_characterization(self):
        predecessor_id = "IOS-ANDROID-POST-FORM-ORACLE-001"
        recovery_id = "IOS-ANDROID-POST-FORM-ORACLE-RECOVERY-TEST"
        predecessor_path = (
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{predecessor_id}.json"
        )
        recovery_path = (
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{recovery_id}.json"
        )
        predecessor = source_lab.load_json(predecessor_path)
        recovery = copy.deepcopy(predecessor)
        recovery["metadata"]["id"] = recovery_id
        recovery["metadata"]["labels"].extend(["corrective", "recovery"])
        recovery["spec"]["recovers"] = predecessor_id
        recovery["spec"]["requirements"] = {
            "mode": "control_plane",
            "refs": [],
            "none_reason": "test recovery",
        }
        state = source_lab.load_json(REPO_ROOT / "ios/project/state.json")
        manifest = source_lab.manifest_value(REPO_ROOT)
        original_load_json = source_lab.load_json

        def controlled_load_json(path):
            if path == recovery_path:
                return recovery
            return original_load_json(path)

        with mock.patch.object(
            source_lab,
            "load_json",
            side_effect=controlled_load_json,
        ):
            self.assertEqual(
                [],
                source_lab.validate_work_item_contract(
                    REPO_ROOT,
                    recovery_id,
                    manifest,
                ),
            )

        recovery["spec"]["recovers"] = "IOS-SOURCELAB-POST-FORM-001"
        with mock.patch.object(
            source_lab,
            "load_json",
            side_effect=controlled_load_json,
        ):
            self.assertTrue(
                any(
                    "control recovery 未精确承接" in value
                    for value in source_lab.validate_work_item_contract(
                        REPO_ROOT,
                        recovery_id,
                        manifest,
                    )
                )
            )

    def test_attestation_can_follow_completed_candidate_oracle(self):
        item_id = "IOS-TEST-POST-FORM-ATTESTATION-001"
        item_path = (
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{item_id}.json"
        )
        dependency_id = "IOS-ANDROID-POST-FORM-ORACLE-RECOVERY-002"
        dependency = source_lab.load_json(
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{dependency_id}.json"
        )
        item = copy.deepcopy(dependency)
        item["metadata"]["id"] = item_id
        item["metadata"]["labels"].extend(
            ["attestation", "github-actions"]
        )
        item["spec"]["depends_on"] = [dependency_id]
        item["spec"]["recovers"] = None
        item["spec"]["requirements"] = {
            "mode": "characterization",
            "refs": [
                {
                    "id": "REQ-ANDROID-SOURCE-PIPELINE-001",
                    "revision": 1,
                    "clauses": ["RC-01"],
                }
            ],
            "none_reason": None,
        }
        item["spec"]["scope"]["allow_write"] = [
            ".github/workflows/android-oracle-attestation.yml",
            "ios/harness/oracle/ci_proposal.py",
            "ios/harness/oracle/trusted_import.py",
        ]
        state_path = REPO_ROOT / "ios/project/state.json"
        state = source_lab.load_json(state_path)
        manifest = source_lab.manifest_value(REPO_ROOT)
        original_load_json = source_lab.load_json

        def validate(mutated_item, mutated_state):
            def controlled_load_json(path):
                if path == item_path:
                    return mutated_item
                if path == state_path:
                    return mutated_state
                return original_load_json(path)

            with mock.patch.object(
                source_lab,
                "load_json",
                side_effect=controlled_load_json,
            ):
                return source_lab.validate_work_item_contract(
                    REPO_ROOT,
                    item_id,
                    manifest,
                )

        self.assertEqual([], validate(item, state))

        incomplete = copy.deepcopy(state)
        incomplete["work_items"][dependency_id][
            "status"
        ] = "implementing"
        self.assertTrue(
            any(
                "已完成且证据通过" in value
                for value in validate(item, incomplete)
            )
        )

        wrong_dependency = copy.deepcopy(item)
        wrong_dependency["spec"]["depends_on"] = [
            "IOS-SOURCELAB-POST-FORM-001"
        ]
        self.assertTrue(
            any(
                "已完成且证据通过" in value
                for value in validate(wrong_dependency, state)
            )
        )

        unsafe_workflow = copy.deepcopy(item)
        unsafe_workflow["spec"]["scope"]["allow_write"].append(
            ".github/workflows/unrelated.yml"
        )
        self.assertTrue(
            any(
                "candidate characterization 禁止写入" in value
                for value in validate(unsafe_workflow, state)
            )
        )

    def test_attestation_control_recovery_chain_is_bounded(self):
        predecessor_id = (
            "IOS-ANDROID-POST-FORM-ATTESTATION-RECOVERY-002"
        )
        recovery_id = (
            "IOS-ANDROID-POST-FORM-ATTESTATION-RECOVERY-TEST"
        )
        recovery_path = (
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{recovery_id}.json"
        )
        predecessor = source_lab.load_json(
            REPO_ROOT
            / "ios/harness/work-items"
            / f"{predecessor_id}.json"
        )
        recovery = copy.deepcopy(predecessor)
        recovery["metadata"]["id"] = recovery_id
        recovery["spec"]["recovers"] = predecessor_id
        recovery["spec"]["scope"]["allow_write"] = [
            ".github/workflows/android-oracle-attestation.yml",
            "ios/harness/oracle/contract.py",
        ]
        state_path = REPO_ROOT / "ios/project/state.json"
        state = source_lab.load_json(state_path)
        manifest = source_lab.manifest_value(REPO_ROOT)
        original_load_json = source_lab.load_json

        def validate(mutated_item, mutated_state):
            def controlled_load_json(path):
                if path == recovery_path:
                    return mutated_item
                if path == state_path:
                    return mutated_state
                return original_load_json(path)

            with mock.patch.object(
                source_lab,
                "load_json",
                side_effect=controlled_load_json,
            ):
                return source_lab.validate_work_item_contract(
                    REPO_ROOT,
                    recovery_id,
                    manifest,
                )

        self.assertEqual([], validate(recovery, state))

        unsafe_workflow = copy.deepcopy(recovery)
        unsafe_workflow["spec"]["scope"]["allow_write"].append(
            ".github/workflows/unrelated.yml"
        )
        self.assertTrue(
            any(
                "candidate characterization 禁止写入" in value
                for value in validate(unsafe_workflow, state)
            )
        )

        active_predecessor = copy.deepcopy(state)
        active_predecessor["work_items"][predecessor_id][
            "status"
        ] = "implementing"
        self.assertTrue(
            any(
                "control recovery 未精确承接" in value
                for value in validate(recovery, active_predecessor)
            )
        )


if __name__ == "__main__":
    unittest.main()
