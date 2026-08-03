#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


source_lab = load_module(
    "real_source_test_source_lab",
    ROOT / "ios/harness/source-lab/source_lab.py",
)
runner = load_module(
    "real_source_test_android_runner",
    ROOT / "ios/harness/oracle/android-runner/orchestrator.py",
)


class RealSourceCaptureContractTests(unittest.TestCase):
    scenario = "rs-wikisource-public-domain-001"

    def test_fixture_is_public_capture_only_and_allowlisted(self):
        directory, case, _ = source_lab.load_scenario(
            ROOT,
            self.scenario,
        )
        self.assertEqual(
            source_lab.validate_real_source_scenario(directory, case),
            [],
        )
        source = source_lab.load_json(directory / "source.json")
        self.assertEqual(
            source["bookSourceUrl"],
            "https://zh.wikisource.org",
        )
        self.assertNotIn("loginUrl", source)
        self.assertFalse(case["retention"]["store_response_bodies"])
        self.assertFalse(case["retention"]["store_credentials"])

    def test_android_runner_has_explicit_real_source_contract(self):
        contract = runner._scenario_contract(self.scenario)
        self.assertEqual(contract["fixture_kind"], "real_source_scenario")
        self.assertEqual(
            contract["device_origin"],
            "https://zh.wikisource.org",
        )
        self.assertEqual(
            list(contract["expected_cases"]),
            [
                ("real-search", "search"),
                ("real-book-info", "book_info"),
                ("real-toc", "chapters"),
                ("real-content", "content"),
            ],
        )
        _, directory = runner.fixture_root(
            ROOT,
            self.scenario,
            contract,
        )
        self.assertEqual(directory.name, self.scenario)

    def test_normalizer_accepts_structured_capture_without_body_archive(self):
        origin = "https://zh.wikisource.org"
        requests = [
            {
                "method": "GET",
                "url": f"{origin}/capture/{index}",
                "headers": [],
                "body": None,
                "timeout_ms": None,
            }
            for index in range(4)
        ]
        case_ids = [
            ("real-search", "search"),
            ("real-book-info", "book_info"),
            ("real-toc", "chapters"),
            ("real-content", "content"),
        ]
        raw = {
            "schema_version": 1,
            "scenario_id": self.scenario,
            "device_origin": origin,
            "logical_origin": origin,
            "request_plan": requests,
            "cases": [
                {
                    "id": case_id,
                    "operation": operation,
                    "request": requests[index],
                    "result": {"sample": "public-domain"},
                    "issue": None,
                }
                for index, (case_id, operation) in enumerate(case_ids)
            ],
        }
        bindings = {
            "fixture_kind": "real_source_scenario",
            "fixture_sha256": "f" * 64,
            "scenario_sha256": "e" * 64,
            "input_sha256": "d" * 64,
            "source_sha256": "c" * 64,
            "real_source_origin": origin,
            "android_git_commit": "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
            "runner_id": "android-characterization-instrumentation-v2",
            "runner_digest": "b" * 64,
        }
        artifact = runner.normalize_raw_artifact(
            raw,
            bindings,
            self.scenario,
        )
        value = artifact["result"]["value"]
        self.assertEqual(artifact["result"]["type"], "real_source_capture")
        self.assertEqual(
            value["fixture_integrity"]["source_sha256"],
            "c" * 64,
        )
        self.assertNotIn("response_bodies", value)


if __name__ == "__main__":
    unittest.main()
