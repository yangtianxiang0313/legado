import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HARNESS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = HARNESS_DIR.parents[1]
sys.path.insert(0, str(HARNESS_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import harness as harness_module  # noqa: E402
import loop_supervisor  # noqa: E402
import proposal_compiler  # noqa: E402
from test_harness import HarnessFixture  # noqa: E402


class CompilerFixture:
    def __init__(self, root):
        self.root = root
        self.fixture = HarnessFixture(root)
        self.harness = self.fixture.initialize()
        self.dag_path = root / proposal_compiler.DAG_PATH

    def item(self, item_id="IOS-COMPILE-TARGET-001"):
        item = self.fixture.item(item_id, "CAP-BOOT", 80)
        item["metadata"]["title"] = "Compiled target"
        item["spec"]["knowledge"] = {
            "contract_version": 1,
            "mode": "not_applicable",
            "claim_refs": [],
            "driver_refs": [],
            "coverage_refs": [],
            "produces": [],
            "expected_ledger_transitions": [],
            "context_budget": {"max_claims": 10, "max_bytes": 4096},
            "none_reason": "compiler unit test",
        }
        item["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = []
        return item

    def dag(self, item_id="IOS-COMPILE-TARGET-001"):
        value = {
            "schema_version": 1,
            "kind": "InitializationWorkItemProposalDAG",
            "id": "WIPD-TEST-001",
            "revision": 1,
            "authority": "proposal_only",
            "queue_effect": {"materializes_work_items": False},
            "nodes": [
                {
                    "proposal_id": item_id,
                    "phase": 1,
                    "class": "control_plane",
                    "depends_on": [],
                    "knowledge_mode": "not_applicable",
                    "title": "Compiled target",
                    "outputs": [],
                    "gates": [],
                    "constraint": "test constraint",
                }
            ],
        }
        self.fixture.write_json(proposal_compiler.DAG_PATH, value)
        return value

    def recipe(self, item_id="IOS-COMPILE-TARGET-001"):
        value = {
            "schema_version": 1,
            "proposal_id": item_id,
            "proposal_constraint": "test constraint",
            "work_item": self.item(item_id),
        }
        self.fixture.write_json(
            f"{proposal_compiler.RECIPE_ROOT}/{item_id}.json",
            value,
        )
        return value

    def compiler(self):
        return proposal_compiler.ProposalCompiler(
            self.harness,
            self.dag_path,
        )


class ProposalCompilerTests(unittest.TestCase):
    def test_plan_is_read_only_deterministic_and_compile_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            fixture.dag()
            fixture.recipe()
            compiler = fixture.compiler()
            controlled = [
                fixture.root / "ios/project/state.json",
                fixture.root / "ios/project/events.jsonl",
                fixture.root / "ios/project/status.md",
            ]
            before = {path: path.read_bytes() for path in controlled}
            first = compiler.plan()
            second = compiler.plan()
            self.assertEqual(
                proposal_compiler._json_bytes(first),
                proposal_compiler._json_bytes(second),
            )
            self.assertEqual("recipe_ready", first["nodes"][0]["status"])
            self.assertEqual(before, {path: path.read_bytes() for path in controlled})

            result = compiler.compile("IOS-COMPILE-TARGET-001")
            self.assertEqual("created", result["outcome"])
            self.assertEqual(
                "unchanged",
                compiler.compile("IOS-COMPILE-TARGET-001")["outcome"],
            )
            self.assertEqual(
                "current",
                compiler.check("IOS-COMPILE-TARGET-001")["status"],
            )
            self.assertFalse(
                (
                    fixture.root
                    / "ios/harness/work-items/IOS-COMPILE-TARGET-001.json"
                ).exists()
            )
            self.assertEqual(before, {path: path.read_bytes() for path in controlled})

    def test_recipe_mismatch_fails_closed_without_inventing_fields(self):
        variants = (
            ("proposal_constraint", "wrong"),
            ("work_item.metadata.title", "wrong"),
            ("work_item.spec.depends_on", ["IOS-OTHER-001"]),
            ("work_item.spec.gates", ["architecture-review"]),
        )
        for path, value in variants:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as directory:
                fixture = CompilerFixture(Path(directory))
                fixture.dag()
                recipe = fixture.recipe()
                cursor = recipe
                parts = path.split(".")
                for part in parts[:-1]:
                    cursor = cursor[part]
                cursor[parts[-1]] = value
                fixture.fixture.write_json(
                    f"{proposal_compiler.RECIPE_ROOT}/IOS-COMPILE-TARGET-001.json",
                    recipe,
                )
                entry = fixture.compiler().plan()["nodes"][0]
                self.assertEqual("ready_for_recipe", entry["status"])
                self.assertEqual("RECIPE_INVALID", entry["reason_code"])
                with self.assertRaises(proposal_compiler.ProposalCompilerError):
                    fixture.compiler().compile("IOS-COMPILE-TARGET-001")

    def test_terminal_dependency_resolves_unique_output_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            original = fixture.item("IOS-ORIGINAL-001")
            original["spec"]["knowledge"].update(
                {
                    "mode": "produce",
                    "produces": [
                        {"kind": "packet", "id": "BKP-RECOVERY-001", "revision": 1}
                    ],
                    "none_reason": None,
                }
            )
            recovery = fixture.item("IOS-RECOVERY-002")
            recovery["spec"]["knowledge"].update(
                {
                    "mode": "supersede",
                    "produces": [
                        {"kind": "packet", "id": "BKP-RECOVERY-001", "revision": 2}
                    ],
                    "none_reason": None,
                }
            )
            fixture.fixture.write_json(
                "ios/harness/work-items/IOS-ORIGINAL-001.json", original
            )
            fixture.fixture.write_json(
                "ios/harness/work-items/IOS-RECOVERY-002.json", recovery
            )
            state = fixture.harness.state()
            state["work_items"].update(
                {
                    "IOS-ORIGINAL-001": {"status": "exhausted"},
                    "IOS-RECOVERY-002": {"status": "completed"},
                }
            )
            fixture.fixture.write_json("ios/project/state.json", state)
            compiler = fixture.compiler()
            result = compiler.resolve_dependency(
                "IOS-ORIGINAL-001",
                compiler.harness.work_items(),
                compiler.harness.state()["work_items"],
            )
            self.assertEqual("resolved", result["status"])
            self.assertEqual("KNOWLEDGE_OUTPUT_RECOVERY", result["reason_code"])
            self.assertEqual("IOS-RECOVERY-002", result["resolved"])

            second = fixture.item("IOS-RECOVERY-003")
            second["spec"]["knowledge"].update(
                {
                    "mode": "supersede",
                    "produces": [
                        {"kind": "packet", "id": "BKP-RECOVERY-001", "revision": 3}
                    ],
                    "none_reason": None,
                }
            )
            fixture.fixture.write_json(
                "ios/harness/work-items/IOS-RECOVERY-003.json", second
            )
            state["work_items"]["IOS-RECOVERY-003"] = {"status": "completed"}
            fixture.fixture.write_json("ios/project/state.json", state)
            result = compiler.resolve_dependency(
                "IOS-ORIGINAL-001",
                compiler.harness.work_items(),
                compiler.harness.state()["work_items"],
            )
            self.assertEqual("unresolved", result["status"])
            self.assertEqual("RECOVERY_AMBIGUOUS", result["reason_code"])

    def test_replacement_cycle_and_atomic_pair_rollback_are_structured(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            fixture.dag()
            fixture.recipe()
            state = fixture.harness.state()
            state["work_items"].update(
                {
                    "IOS-CYCLE-A-001": {
                        "status": "cancelled",
                        "replacement": "IOS-CYCLE-B-001",
                    },
                    "IOS-CYCLE-B-001": {
                        "status": "cancelled",
                        "replacement": "IOS-CYCLE-A-001",
                    },
                }
            )
            fixture.fixture.write_json("ios/project/state.json", state)
            compiler = fixture.compiler()
            resolution = compiler.resolve_dependency(
                "IOS-CYCLE-A-001",
                compiler.harness.work_items(),
                compiler.harness.state()["work_items"],
            )
            self.assertEqual("REPLACEMENT_CYCLE", resolution["reason_code"])

            original_create = compiler._link_create
            calls = []

            def fail_second(path, payload):
                calls.append(path)
                if len(calls) == 2:
                    raise OSError("simulated manifest failure")
                original_create(path, payload)

            with mock.patch.object(compiler, "_link_create", side_effect=fail_second):
                with self.assertRaisesRegex(OSError, "simulated"):
                    compiler.compile("IOS-COMPILE-TARGET-001")
            self.assertFalse(
                (
                    fixture.root
                    / f"{proposal_compiler.CANDIDATE_ROOT}/IOS-COMPILE-TARGET-001.json"
                ).exists()
            )
            self.assertFalse(
                (
                    fixture.root
                    / f"{proposal_compiler.MANIFEST_ROOT}/IOS-COMPILE-TARGET-001.json"
                ).exists()
            )

    def test_current_integrations_candidate_is_bound_and_preflightable(self):
        compiler = proposal_compiler.ProposalCompiler(
            harness_module.Harness(REPO_ROOT)
        )
        plan = compiler.plan()
        entries = {entry["proposal_id"]: entry for entry in plan["nodes"]}
        self.assertEqual(
            "IOS-KNOWLEDGE-UI-TOPOLOGY-RECOVERY-002",
            entries["IOS-KNOWLEDGE-UI-TOPOLOGY-001"]["resolved_work_item_id"],
        )
        self.assertEqual(
            "recipe_ready",
            entries["IOS-KNOWLEDGE-INTEGRATIONS-001"]["status"],
        )
        self.assertEqual(
            "current",
            compiler.check("IOS-KNOWLEDGE-INTEGRATIONS-001")["status"],
        )
        preview = loop_supervisor.LoopSupervisor(
            compiler.harness
        ).preflight_candidate(
            REPO_ROOT
            / f"{proposal_compiler.CANDIDATE_ROOT}/IOS-KNOWLEDGE-INTEGRATIONS-001.json"
        )
        self.assertEqual("IOS-KNOWLEDGE-INTEGRATIONS-001", preview.item_id)
        self.assertEqual(
            (("packet", "BKP-INTEGRATIONS-001", 1), ("driver", "DRV-INTEGRATION-PROFILES-001", 1)),
            preview.produces,
        )

    def test_cli_exposes_no_authority_escalation_commands(self):
        help_text = proposal_compiler.build_parser().format_help().lower()
        for forbidden in ("materialize", "approve", "publish", "accept"):
            self.assertNotIn(forbidden, help_text)


if __name__ == "__main__":
    unittest.main()
