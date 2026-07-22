import copy
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parents[1]
sys.path.insert(0, str(HARNESS_ROOT))

from oracle.canonicalizer import canonicalize_bytes, load_config  # noqa: E402
from oracle.cli import build_parser  # noqa: E402
from oracle.comparator import compare  # noqa: E402
from oracle.contract import (  # noqa: E402
    ProposalError,
    canonical_file_digest,
    fixture_digest,
    implementation_digest,
    verify_proposal,
)
from oracle.exact_json import ExactJSONError, loads  # noqa: E402


class OracleControlTests(unittest.TestCase):
    commit = "1" * 40
    tree = "2" * 40
    fixture_id = "source-format-test-001"
    request_id = "IOS-ORACLE-TEST-001"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self._copy("ios/harness/normalization/canonical-v1.json")
        self._copy("ios/harness/schemas/execution-envelope.schema.json")
        self._write("ios/project/baseline.json", {"android_oracle": {"git_commit": self.commit}})
        self._write(
            "ios/project/android-intake/inventory-manifest.json",
            {"android_git_commit": self.commit, "android_tree": self.tree},
        )
        self._write("ios/project/requirements/catalog.json", {"schema_version": 1, "requirements": []})
        self._write(
            f"ios/harness/work-items/{self.request_id}.json",
            {
                "kind": "WorkItem",
                "metadata": {
                    "id": self.request_id,
                    "labels": ["oracle-golden-request"],
                },
                "spec": {"inputs": {"fixtures": [self.fixture_id]}},
            },
        )
        fixture = self.root / f"ios/harness/fixtures/source-format/{self.fixture_id}"
        fixture.mkdir(parents=True)
        self._write(
            f"ios/harness/fixtures/source-format/{self.fixture_id}/case.json",
            {"id": self.fixture_id, "operation": "source_round_trip"},
        )
        self._write(
            f"ios/harness/fixtures/source-format/{self.fixture_id}/source.json",
            {"bookSourceUrl": "https://fixture.invalid", "bookSourceName": "fixture"},
        )
        self.fixture_sha = fixture_digest(fixture)
        self._write(
            "ios/harness/fixtures/manifest.json",
            {
                "schema_version": 1,
                "compatibility_profile": "android-legado-v1",
                "canonicalizer": "canonical-v1",
                "fixtures": [
                    {
                        "id": self.fixture_id,
                        "path": f"ios/harness/fixtures/source-format/{self.fixture_id}",
                        "sha256": self.fixture_sha,
                    }
                ],
            },
        )
        self._write("ios/harness/goldens/manifest.json", {"schema_version": 1, "fixtures": {}})
        self.proposal_root = self.root / "oracle-proposals/proposal-001"
        (self.proposal_root / "payloads").mkdir(parents=True)
        self.payload_value = self._payload()
        self.payload = self.proposal_root / f"payloads/{self.fixture_id}.json"
        self.payload.write_bytes(self._canonical(self.payload_value))
        self.proposal_value = self._proposal()
        self.proposal = self.proposal_root / "proposal.json"
        self._write_path(self.proposal, self.proposal_value)

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_json_and_canonicalizer_preserve_tokens_and_only_allowed_normalizations(self):
        config = load_config(self.root / "ios/harness/normalization/canonical-v1.json")
        raw = (
            b'{"z":1e500,"integer":123456789012345678901234567890,"decimal":0.1000,'
            b'"negative":-0,"line":"a\\r\\nb\\rc","name":"Keep",'
            b'"trace_id":"drop","request_plan":[{"headers":[{"name":"X-API","value":"v"}]}]}'
        )
        canonical = canonicalize_bytes(raw, config)

        self.assertIn(b'"z":1e500', canonical)
        self.assertIn(b'"decimal":0.1000', canonical)
        self.assertIn(b'"negative":-0', canonical)
        self.assertIn(b'"line":"a\\nb\\nc"', canonical)
        self.assertIn(b'"name":"Keep"', canonical)
        self.assertIn(b'"name":"x-api"', canonical)
        self.assertNotIn(b"trace_id", canonical)
        self.assertEqual(canonicalize_bytes(canonical, config), canonical)
        self.assertEqual(loads('{"e\u0301":1}'.encode()), {"e\u0301": loads(b"1")})

        invalid = [
            b'{"a":1,"a":2}',
            b'{"a":1,"\\u0061":2}',
            '{"é":1,"e\u0301":2}'.encode(),
            b'{"n":NaN}',
            b'{"n":Infinity}',
            b'{"n":-Infinity}',
            b'{"s":"\\ud800"}',
        ]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ExactJSONError):
                loads(value)

    def test_comparator_uses_full_shared_view_but_ignores_platform_extensions(self):
        config = load_config(self.root / "ios/harness/normalization/canonical-v1.json")
        actual = copy.deepcopy(self.payload_value["artifact"])
        actual["engine"]["platform"] = "ios"
        actual["engine"]["revision"] = "ios-build"
        actual["result"]["value"].pop("android_characterization")
        actual["result"]["value"]["ios_lossless_extension"] = {"raw": True}
        expected = self.payload.read_bytes()
        self.assertTrue(compare(expected, self._canonical(actual), config)["equal"])

        actual["result"]["value"]["portable_known_projection"] = {
            "a/b": {"~key": 1.0}
        }
        report = compare(expected, self._canonical(actual), config)
        self.assertFalse(report["equal"])
        self.assertEqual(
            report["first_divergence"]["pointer"],
            "/result/value/portable_known_projection/a~1b/~0key",
        )
        self.assertEqual(report["first_divergence"]["stage"], "result_mapping")
        self.assertEqual(report, compare(expected, self._canonical(actual), config))

        actual = copy.deepcopy(self.payload_value["artifact"])
        actual["engine"].update(platform="ios", revision="ios-build")
        actual["result"]["value"].pop("android_characterization")
        actual["result"]["value"].pop("portable_known_projection")
        actual["result"]["value"]["ios_lossless_extension"] = {}
        report = compare(expected, self._canonical(actual), config)
        self.assertEqual(
            report["first_divergence"]["pointer"],
            "/result/value/portable_known_projection",
        )

        actual = copy.deepcopy(self.payload_value["artifact"])
        actual["engine"]["platform"] = "ios"
        actual["fixture_id"] = "source-format-other-001"
        actual["result"]["value"].pop("android_characterization")
        actual["result"]["value"]["ios_lossless_extension"] = {}
        report = compare(expected, self._canonical(actual), config)
        self.assertEqual(report["first_divergence"]["pointer"], "/fixture_id")

    def test_valid_proposal_binds_every_protected_input_and_rejects_drift(self):
        summary = verify_proposal(self.root, self.proposal, self.request_id)
        self.assertEqual(summary["authority"], "candidate_only")
        self.assertEqual(summary["fixture_ids"], [self.fixture_id])

        original = copy.deepcopy(self.proposal_value)
        mutations = {
            "commit": lambda value: value["bindings"].update(android_git_commit="3" * 40),
            "runner": lambda value: value["bindings"].update(runner_digest="4" * 64),
            "manifest": lambda value: value["bindings"].update(fixture_manifest_sha256="5" * 64),
            "canonicalizer": lambda value: value["bindings"].update(canonicalizer_config_sha256="6" * 64),
            "payload": lambda value: value["fixtures"][0].update(payload_sha256="7" * 64),
            "extra-field": lambda value: value.update(untrusted=True),
            "path-traversal": lambda value: value["fixtures"][0].update(payload_path="../payload.json"),
            "selection-shrink": lambda value: value["request"].update(fixture_ids=[]),
        }
        for name, mutate in mutations.items():
            value = copy.deepcopy(original)
            mutate(value)
            self._write_path(self.proposal, value)
            with self.subTest(name=name), self.assertRaises(ProposalError):
                verify_proposal(self.root, self.proposal, self.request_id)
        self._write_path(self.proposal, original)

        payload_bytes = self.payload.read_bytes()
        self.payload.write_bytes(payload_bytes + b" ")
        with self.assertRaises(ProposalError):
            verify_proposal(self.root, self.proposal, self.request_id)
        self.payload.write_bytes(payload_bytes)

        real_payload = self.payload.with_suffix(".real")
        self.payload.rename(real_payload)
        self.payload.symlink_to(real_payload)
        with self.assertRaises(ProposalError):
            verify_proposal(self.root, self.proposal, self.request_id)
        self.payload.unlink()
        os.link(real_payload, self.payload)
        with self.assertRaises(ProposalError):
            verify_proposal(self.root, self.proposal, self.request_id)

    def test_cli_surface_is_read_only_and_all_commands_preserve_goldens(self):
        parser = build_parser()
        subcommands = next(action.choices for action in parser._actions if isinstance(action.choices, dict))
        self.assertEqual(
            set(subcommands),
            {"doctor", "canonicalize", "compare", "verify-proposal"},
        )
        before = self._tree_digest(self.root / "ios/harness/goldens")
        actual = self.proposal_root / "actual.json"
        ios_artifact = copy.deepcopy(self.payload_value["artifact"])
        ios_artifact["engine"].update(platform="ios", revision="ios-build")
        ios_artifact["result"]["value"].pop("android_characterization")
        ios_artifact["result"]["value"]["ios_lossless_extension"] = {}
        actual.write_bytes(self._canonical(ios_artifact))
        commands = [
            ["doctor", "--root", str(self.root)],
            [
                "canonicalize",
                "--root",
                str(self.root),
                "--input",
                str(self.payload),
            ],
            [
                "compare",
                "--root",
                str(self.root),
                "--expected-payload",
                str(self.payload),
                "--actual-artifact",
                str(actual),
            ],
            [
                "verify-proposal",
                "--root",
                str(self.root),
                "--proposal",
                str(self.proposal),
                "--request-work-item",
                self.request_id,
            ],
        ]
        environment = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        for arguments in commands:
            result = subprocess.run(
                [sys.executable, "-B", str(HARNESS_ROOT / "oracle/cli.py"), *arguments],
                capture_output=True,
                env=environment,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(before, self._tree_digest(self.root / "ios/harness/goldens"))

        for forbidden in ("publish", "accept", "record", "promote", "update-golden"):
            result = subprocess.run(
                [sys.executable, "-B", str(HARNESS_ROOT / "oracle/cli.py"), forbidden],
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)

    def _payload(self):
        artifact = {
            "schema_version": 1,
            "fixture_id": self.fixture_id,
            "engine": {
                "platform": "android",
                "revision": self.commit,
                "compatibility_profile": "android-legado-v1",
            },
            "request_plan": [],
            "decode": None,
            "stages": [],
            "result": {
                "type": "book_source_round_trip",
                "value": {
                    "portable_known_projection": {"a/b": {"~key": 1}},
                    "android_characterization": {"gson": "observed"},
                },
            },
            "issues": [],
        }
        return {
            "schema_version": 1,
            "kind": "android_oracle_payload",
            "fixture_id": self.fixture_id,
            "fixture_sha256": self.fixture_sha,
            "operation": "source_round_trip",
            "compatibility_profile": "android-legado-v1",
            "oracle": {
                "android_git_commit": self.commit,
                "runner_digest": "8" * 64,
                "runner_image_digest": "sha256:" + "9" * 64,
            },
            "artifact": artifact,
        }

    def _proposal(self):
        bindings = {
            "compatibility_profile": "android-legado-v1",
            "android_git_commit": self.commit,
            "android_git_tree": self.tree,
            "checkout_clean": True,
            "runner_digest": "8" * 64,
            "runner_image_digest": "sha256:" + "9" * 64,
            "request_work_item_sha256": canonical_file_digest(
                self.root / f"ios/harness/work-items/{self.request_id}.json"
            ),
            "android_baseline_sha256": canonical_file_digest(self.root / "ios/project/baseline.json"),
            "fixture_manifest_sha256": canonical_file_digest(
                self.root / "ios/harness/fixtures/manifest.json"
            ),
            "android_fact_inventory_sha256": canonical_file_digest(
                self.root / "ios/project/android-intake/inventory-manifest.json"
            ),
            "requirement_catalog_sha256": canonical_file_digest(
                self.root / "ios/project/requirements/catalog.json"
            ),
            "execution_envelope_schema_sha256": canonical_file_digest(
                self.root / "ios/harness/schemas/execution-envelope.schema.json"
            ),
            "canonicalizer_id": "canonical-v1",
            "canonicalizer_config_sha256": canonical_file_digest(
                self.root / "ios/harness/normalization/canonical-v1.json"
            ),
            "canonicalizer_implementation_sha256": implementation_digest(
                "canonicalizer.py", "exact_json.py"
            ),
            "comparator_id": "shared-exact-v1",
            "comparator_implementation_sha256": implementation_digest(
                "__init__.py", "canonicalizer.py", "comparator.py", "exact_json.py"
            ),
        }
        payload = self.payload.read_bytes()
        return {
            "schema_version": 1,
            "kind": "android_oracle_proposal",
            "authority": "candidate_only",
            "status": "proposed",
            "proposal_id": "oracle-proposal-001",
            "request": {"work_item_id": self.request_id, "fixture_ids": [self.fixture_id]},
            "producer": {
                "system": "test-ci",
                "workflow_ref": "workflow@sha256",
                "run_id": "run-1",
                "attestation_uri": "https://ci.invalid/attestation/1",
                "attestation_sha256": "a" * 64,
            },
            "bindings": bindings,
            "fixtures": [
                {
                    "id": self.fixture_id,
                    "operation": "source_round_trip",
                    "fixture_path": f"ios/harness/fixtures/source-format/{self.fixture_id}",
                    "fixture_sha256": self.fixture_sha,
                    "payload_path": f"payloads/{self.fixture_id}.json",
                    "payload_sha256": hashlib.sha256(payload).hexdigest(),
                    "payload_bytes": len(payload),
                }
            ],
        }

    def _canonical(self, value):
        raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        config = load_config(self.root / "ios/harness/normalization/canonical-v1.json")
        return canonicalize_bytes(raw, config)

    def _copy(self, relative):
        destination = self.root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPOSITORY_ROOT / relative, destination)

    def _write(self, relative, value):
        self._write_path(self.root / relative, value)

    @staticmethod
    def _write_path(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    @staticmethod
    def _tree_digest(root):
        entries = []
        for path in sorted(root.rglob("*")):
            if path.is_file():
                entries.append((path.relative_to(root).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest()))
        return entries


if __name__ == "__main__":
    unittest.main()
