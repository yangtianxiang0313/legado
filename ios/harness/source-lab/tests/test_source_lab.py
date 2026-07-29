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


if __name__ == "__main__":
    unittest.main()
