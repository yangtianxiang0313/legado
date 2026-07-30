import contextlib
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
SOURCE_LAB_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = SOURCE_LAB_ROOT.parents[2]
sys.path.insert(0, str(SOURCE_LAB_ROOT))

import source_lab  # noqa: E402


class SourceLabTests(unittest.TestCase):
    scenario = "sl-html-basic-001"
    runtime_scenario = "rl-reader-bookmark-search-runtime-risk-001"
    integration_scenario = "il-integration-backup-webdav-001"

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
        registry = json.loads(
            (
                REPO_ROOT / "ios/harness/oracle/request-registry.json"
            ).read_text(encoding="utf-8")
        )
        scenarios = [
            request["scenario_id"] for request in registry["requests"]
        ]
        self.assertIn(
            "sl-source-response-xml-declaration-normalization-001",
            scenarios,
        )
        for scenario in scenarios:
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
            (
                "push",
                "refs/heads/feature/oracle-sl-html-basic-001-not-a-sha",
                "not-a-sha",
                "",
            ),
            (
                "push",
                "refs/heads/feature/oracle-sl-html-basic-001-"
                + ("A" * 40),
                "A" * 40,
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
            "      - name: Resolve trusted Oracle scenario", 1
        )[1].split("\n      - name:", 1)[1]
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
        self.assertIn(
            "python3 -B ios/harness/oracle/scenario_selector.py",
            workflow,
        )
        self.assertLess(
            workflow.index("      - name: Checkout exact source"),
            workflow.index(
                "      - name: Resolve trusted Oracle scenario"
            ),
        )
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

    def test_runtime_scenario_is_valid_without_source_or_network(self):
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            self.runtime_scenario,
        )
        self.assertEqual([], source_lab.validate_scenario(REPO_ROOT, directory, case))
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(7, len(inputs["cases"]))
        with self.assertRaisesRegex(
            source_lab.SourceLabError,
            "没有书源模板",
        ):
            source_lab.build_source(
                REPO_ROOT,
                self.runtime_scenario,
                source_lab.LOGICAL_ORIGIN,
            )
        with self.assertRaisesRegex(
            source_lab.SourceLabError,
            "禁止启动网站",
        ):
            with source_lab.running_server(REPO_ROOT, self.runtime_scenario):
                self.fail("runtime scenario started a SourceLab server")

    def test_library_group_boundary_runtime_scenario_is_source_anchored(self):
        scenario = "rl-library-shelf-group-bit-boundary-risk-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(REPO_ROOT, directory, case),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(3, len(inputs["cases"]))
        self.assertEqual(
            {"nominal", "boundary"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertTrue(
            all(
                value["android_fact_refs"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            )
        )

    def test_chapter_source_override_runtime_scenario_is_cache_scoped(self):
        scenario = "rl-reader-chapter-source-override-runtime-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(REPO_ROOT, directory, case),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(4, len(inputs["cases"]))
        self.assertEqual(
            {"nominal", "boundary"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertEqual("none", case["transport"]["mode"])
        self.assertFalse(case["determinism"]["network_allowed"])

    def test_reader_layout_incremental_stream_covers_terminal_failures(self):
        scenario = "rl-reader-layout-incremental-stream-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(REPO_ROOT, directory, case),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(7, len(inputs["cases"]))
        self.assertEqual(
            {"current_layout_stream", "adjacent_layout_stream"},
            {value["operation"] for value in inputs["cases"]},
        )
        self.assertEqual(
            {"nominal", "boundary", "denied"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertEqual("none", case["transport"]["mode"])
        self.assertFalse(case["determinism"]["network_allowed"])

    def test_reader_duration_session_covers_executor_and_config_boundaries(self):
        scenario = "rl-reader-progress-read-duration-session-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(REPO_ROOT, directory, case),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(7, len(inputs["cases"]))
        self.assertEqual(
            {
                "read_duration_single",
                "read_duration_repeated",
                "read_duration_disabled_gap",
                "read_duration_config_race",
                "read_duration_reset_race",
                "read_duration_durability_window",
            },
            {value["operation"] for value in inputs["cases"]},
        )
        self.assertEqual(
            {"nominal", "boundary", "denied"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertEqual("none", case["transport"]["mode"])
        self.assertFalse(case["determinism"]["network_allowed"])

    def test_reader_progress_save_runtime_covers_late_write_boundaries(self):
        scenario = "rl-reader-progress-save-runtime-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(REPO_ROOT, directory, case),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(6, len(inputs["cases"]))
        self.assertEqual(
            {
                "save_runtime_execution_state",
                "save_runtime_book_switch",
                "save_runtime_session_clear",
                "save_runtime_multi_queue",
                "save_runtime_missing_chapter",
                "save_runtime_durability_window",
            },
            {value["operation"] for value in inputs["cases"]},
        )
        self.assertEqual(
            {"nominal", "boundary", "denied"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertEqual("none", case["transport"]["mode"])
        self.assertFalse(case["determinism"]["network_allowed"])

    def test_book_detail_actions_cover_source_and_local_boundaries(self):
        scenario = "rl-ui-book-detail-conditional-actions-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(
                REPO_ROOT,
                directory,
                case,
            ),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(6, len(inputs["cases"]))
        self.assertEqual(
            {"book_detail_action_projection"},
            {value["operation"] for value in inputs["cases"]},
        )
        self.assertEqual(
            {"nominal", "boundary", "denied"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertEqual(
            {"remote", "local_txt", "local_epub"},
            {
                value["arguments"]["book_kind"]
                for value in inputs["cases"]
            },
        )
        self.assertEqual("none", case["transport"]["mode"])
        self.assertFalse(case["determinism"]["network_allowed"])

    def test_reader_layout_page_projection_covers_reflow_and_boundaries(self):
        scenario = "rl-reader-layout-page-projection-001"
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(REPO_ROOT, directory, case),
        )
        self.assertEqual("android_runtime_scenario", case["kind"])
        self.assertEqual(5, len(inputs["cases"]))
        self.assertEqual(
            {"layout_projection", "layout_reflow_projection"},
            {value["operation"] for value in inputs["cases"]},
        )
        self.assertEqual(
            {"nominal", "boundary"},
            {
                value["role"]
                for coverage in case["coverage"]
                for value in coverage["cases"]
            },
        )
        self.assertEqual("none", case["transport"]["mode"])
        self.assertFalse(case["determinism"]["network_allowed"])

    def test_global_scenario_manifest_includes_independent_integration_lab(self):
        directory, case, inputs = source_lab.load_scenario(
            REPO_ROOT,
            self.integration_scenario,
        )
        self.assertEqual(
            [],
            source_lab.validate_scenario(
                REPO_ROOT,
                directory,
                case,
            ),
        )
        self.assertEqual("integration_lab_scenario", case["kind"])
        self.assertEqual(12, len(inputs["cases"]))
        scenarios = {
            value["id"]: value
            for value in source_lab.manifest_value(REPO_ROOT)["scenarios"]
        }
        self.assertEqual(
            (
                "ios/harness/fixtures/integration-lab/"
                "il-integration-backup-webdav-001"
            ),
            scenarios[self.integration_scenario]["path"],
        )

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
            self.assertEqual(
                1,
                servers[0].route_request_counts[route["id"]],
            )
            self.assertTrue(
                all(
                    count == 0
                    for route_id, count
                    in servers[0].route_request_counts.items()
                    if route_id != route["id"]
                )
            )
            self.assertEqual([0, 0, 0], [server.request_count for server in servers[1:]])
            self.assertTrue(
                all(
                    all(count == 0 for count in server.route_request_counts.values())
                    for server in servers[1:]
                )
            )

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

    def test_binary_fixture_bodies_and_redirects_are_served_exactly(self):
        scenario = "sl-source-transport-response-decoding-runtime-001"
        directory, case, _ = source_lab.load_scenario(REPO_ROOT, scenario)
        routes = {
            route["id"]: route for route in case["transport"]["responses"]
        }
        gbk_path = source_lab.safe_child(
            directory,
            routes["header-gbk"]["respond"]["body_file"],
        )
        self.assertEqual(
            "声明编码：星河\n",
            source_lab.fixture_body_bytes(gbk_path).decode("gbk"),
        )
        with source_lab.running_server(REPO_ROOT, scenario) as server:
            redirect = source_lab.request_route(
                server,
                routes["redirect-final-url"],
            )
        self.assertEqual(302, redirect["status"])
        self.assertEqual(
            source_lab.LOGICAL_ORIGIN + "/decode/redirect-start",
            redirect["logical_target"],
        )

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


if __name__ == "__main__":
    unittest.main()
