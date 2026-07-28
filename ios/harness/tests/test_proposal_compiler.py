import json
import subprocess
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

    def complete_base_queue(self):
        state = self.harness.state()
        for runtime in state["work_items"].values():
            runtime["status"] = "superseded"
        self.fixture.write_json("ios/project/state.json", state)
        self.fixture.write_text(
            "ios/project/status.md",
            self.harness.render_status(state, self.harness.work_items()),
        )

    def initialize_git(self):
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Auto Materialization Test"],
            cwd=self.root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "auto@example.invalid"],
            cwd=self.root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", "compiled candidate"],
            cwd=self.root,
            check=True,
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

    def test_recovery_recipe_manifest_binds_predecessor_and_detects_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            predecessor_id = "IOS-FAILED-001"
            dag = fixture.dag()
            dag["nodes"][0]["recovers"] = predecessor_id
            fixture.fixture.write_json(proposal_compiler.DAG_PATH, dag)
            recipe = fixture.recipe()
            recipe["work_item"]["spec"]["recovers"] = predecessor_id
            recipe["work_item"]["spec"]["scope"]["allow_write"] = [
                "ios/project/checkpoints/IOS-COMPILE-TARGET-001.json",
                "ios/project/capabilities/CAP-BOOT.json",
            ]
            fixture.fixture.write_json(
                f"{proposal_compiler.RECIPE_ROOT}/IOS-COMPILE-TARGET-001.json",
                recipe,
            )
            fixture.fixture.write_json(
                f"ios/harness/work-items/{predecessor_id}.json",
                fixture.item(predecessor_id),
            )
            state = fixture.harness.state()
            state["work_items"][predecessor_id] = {
                "status": "blocked",
                "attempt": 1,
                "last_evidence": None,
                "blocker": "baseline_red",
            }
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.fixture.write_text(
                "ios/project/status.md",
                fixture.harness.render_status(
                    state,
                    fixture.harness.work_items(),
                ),
            )

            compiler = fixture.compiler()
            self.assertEqual("recipe_ready", compiler.plan()["nodes"][0]["status"])
            compiler.compile("IOS-COMPILE-TARGET-001")
            manifest = harness_module.load_json(
                fixture.root
                / proposal_compiler.MANIFEST_ROOT
                / "IOS-COMPILE-TARGET-001.json"
            )
            recovery = manifest["recovery"]
            self.assertEqual(predecessor_id, recovery["predecessor"])
            self.assertEqual("blocked", recovery["status"])
            self.assertIsNone(recovery["replacement"])
            self.assertTrue(recovery["work_item_sha256"])
            self.assertTrue(recovery["runtime_sha256"])
            self.assertIsNone(recovery["checkpoint"])
            self.assertIsNone(recovery["evidence"])

            fixture.initialize_git()
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                supervisor,
                "_require_head_regular",
                wraps=supervisor._require_head_regular,
            ) as require_head:
                auto_candidate = supervisor._auto_candidate(
                    "IOS-COMPILE-TARGET-001"
                )
            self.assertEqual(
                "IOS-COMPILE-TARGET-001",
                auto_candidate.proposal_id,
            )
            provenance_paths = set(require_head.call_args.args[0])
            self.assertIn(recovery["work_item"], provenance_paths)

            state["work_items"][predecessor_id]["blocker"] = "changed"
            fixture.fixture.write_json("ios/project/state.json", state)
            result = compiler.check("IOS-COMPILE-TARGET-001")
            self.assertEqual("stale", result["status"])

    def test_recovery_recipe_fails_closed_for_mismatch_status_and_replacement(self):
        variants = (
            ("recipe-mismatch", "blocked", None),
            ("non-terminal", "ready", None),
            ("already-bound", "blocked", "IOS-OTHER-RECOVERY-001"),
        )
        for variant, status, replacement in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                fixture = CompilerFixture(Path(directory))
                predecessor_id = "IOS-FAILED-001"
                dag = fixture.dag()
                dag["nodes"][0]["recovers"] = predecessor_id
                fixture.fixture.write_json(proposal_compiler.DAG_PATH, dag)
                recipe = fixture.recipe()
                if variant != "recipe-mismatch":
                    recipe["work_item"]["spec"]["recovers"] = predecessor_id
                fixture.fixture.write_json(
                    f"{proposal_compiler.RECIPE_ROOT}/IOS-COMPILE-TARGET-001.json",
                    recipe,
                )
                fixture.fixture.write_json(
                    f"ios/harness/work-items/{predecessor_id}.json",
                    fixture.item(predecessor_id),
                )
                state = fixture.harness.state()
                runtime = {
                    "status": status,
                    "attempt": 1,
                    "last_evidence": None,
                }
                if replacement is not None:
                    runtime["replacement"] = replacement
                state["work_items"][predecessor_id] = runtime
                fixture.fixture.write_json("ios/project/state.json", state)

                entry = fixture.compiler().plan()["nodes"][0]
                if variant == "recipe-mismatch":
                    self.assertEqual("ready_for_recipe", entry["status"])
                    self.assertEqual("RECIPE_INVALID", entry["reason_code"])
                else:
                    self.assertEqual("recovery_blocked", entry["status"])
                    self.assertEqual("RECOVERY_INVALID", entry["reason_code"])

    def test_recipe_mismatch_fails_closed_without_inventing_fields(self):
        variants = (
            ("proposal_constraint", "wrong"),
            ("work_item.metadata.title", "wrong"),
            ("work_item.spec.depends_on", ["IOS-OTHER-001"]),
            ("work_item.spec.recovers", "IOS-BOOT-001"),
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
        proposal_id = "IOS-KNOWLEDGE-INTEGRATIONS-001"
        plan = compiler.plan()
        entries = {entry["proposal_id"]: entry for entry in plan["nodes"]}
        self.assertEqual(
            "IOS-KNOWLEDGE-UI-TOPOLOGY-RECOVERY-002",
            entries["IOS-KNOWLEDGE-UI-TOPOLOGY-001"]["resolved_work_item_id"],
        )
        candidate_path = (
            REPO_ROOT
            / proposal_compiler.CANDIDATE_ROOT
            / f"{proposal_id}.json"
        )
        manifest_path = (
            REPO_ROOT
            / proposal_compiler.MANIFEST_ROOT
            / f"{proposal_id}.json"
        )
        candidate = json.loads(candidate_path.read_text(encoding="utf-8"))
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(
            harness_module.sha256_json(candidate),
            manifest["candidate_sha256"],
        )
        self.assertEqual("proposal_only", manifest["authority"])

        runtime = compiler.harness.state()["work_items"].get(proposal_id)
        entry = entries[proposal_id]
        if runtime is None:
            self.assertEqual("recipe_ready", entry["status"])
            self.assertEqual("current", compiler.check(proposal_id)["status"])
            preview = loop_supervisor.LoopSupervisor(
                compiler.harness
            ).preflight_candidate(candidate_path)
            self.assertEqual(proposal_id, preview.item_id)
            self.assertEqual(
                (
                    ("packet", "BKP-INTEGRATIONS-001", 1),
                    ("driver", "DRV-INTEGRATION-PROFILES-001", 1),
                ),
                preview.produces,
            )
        else:
            materialized = json.loads(
                (
                    REPO_ROOT
                    / "ios/harness/work-items"
                    / f"{proposal_id}.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(candidate, materialized)
            status = runtime["status"]
            if status == "completed":
                self.assertEqual("completed", entry["status"])
            elif status in proposal_compiler.TERMINAL_STATUSES:
                resolution = compiler.resolve_dependency(
                    proposal_id,
                    compiler.harness.work_items(),
                    compiler.harness.state()["work_items"],
                )
                self.assertEqual(
                    (
                        "completed"
                        if resolution["status"] == "resolved"
                        else "terminal_unresolved"
                    ),
                    entry["status"],
                )
            else:
                self.assertEqual("materialized", entry["status"])

    def test_cli_exposes_no_authority_escalation_commands(self):
        help_text = proposal_compiler.build_parser().format_help().lower()
        for forbidden in ("materialize", "approve", "publish", "accept"):
            self.assertNotIn(forbidden, help_text)

    def test_compiled_control_plane_candidate_auto_materializes_and_drives(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            fixture.complete_base_queue()
            fixture.dag()
            recipe = fixture.recipe()
            item = recipe["work_item"]
            item["spec"]["scope"]["allow_write"] = [
                "ios/project/checkpoints/IOS-COMPILE-TARGET-001.json",
                "ios/project/capabilities/CAP-BOOT.json",
            ]
            fixture.fixture.write_json(
                f"{proposal_compiler.RECIPE_ROOT}/IOS-COMPILE-TARGET-001.json",
                recipe,
            )
            fixture.compiler().compile("IOS-COMPILE-TARGET-001")
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "auto_materialization": {
                        "enabled": True,
                        "policy": loop_supervisor.AUTO_MATERIALIZATION_POLICY,
                    },
                    "agent_invocation": {
                        "argv": [
                            sys.executable,
                            "-c",
                            "import os; assert os.environ['LEGADO_WORK_ITEM_ID']",
                        ],
                        "timeout_seconds": 10,
                    },
                },
            )
            fixture.fixture.write_json(
                "disabled-supervisor.json",
                {
                    "auto_materialization": {
                        "enabled": False,
                        "policy": loop_supervisor.AUTO_MATERIALIZATION_POLICY,
                    },
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", "raise SystemExit(99)"],
                        "timeout_seconds": 10,
                    },
                },
            )
            fixture.initialize_git()

            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            decision = supervisor.inspect()
            self.assertEqual("auto_materialization_ready", decision.state)
            self.assertEqual("AUTO_MATERIALIZATION_READY", decision.reason_code)
            self.assertFalse(decision.requires_human)
            self.assertEqual("IOS-COMPILE-TARGET-001", decision.work_item_id)
            disabled = supervisor.drive(
                config_path=fixture.root / "disabled-supervisor.json",
                agent_id="auto-agent",
                max_transitions=1,
            )
            self.assertEqual("auto_materialization_disabled", disabled["outcome"])
            self.assertNotIn(
                "IOS-COMPILE-TARGET-001",
                fixture.harness.state()["work_items"],
            )

            with mock.patch.object(
                fixture.harness,
                "business_knowledge_selection",
                return_value=None,
            ):
                result = supervisor.drive(
                    config_path=fixture.root / "supervisor.json",
                    agent_id="auto-agent",
                    max_transitions=1,
                )
            self.assertEqual("transition_budget_reached", result["outcome"])
            self.assertEqual(
                "auto_materialization",
                result["transitions"][0]["kind"],
            )
            self.assertEqual(0, result["transitions"][1]["exit_code"])
            runtime = fixture.harness.state()["work_items"][
                "IOS-COMPILE-TARGET-001"
            ]
            self.assertEqual("implementing", runtime["status"])
            events = [
                event
                for event in fixture.harness.event_lines()
                if event.get("work_item_id") == "IOS-COMPILE-TARGET-001"
            ]
            self.assertEqual(
                ["WorkItemMaterialized", "WorkItemClaimed"],
                [event["event"] for event in events],
            )
            provenance = events[0]["payload"]["provenance"]
            self.assertEqual(
                loop_supervisor.AUTO_MATERIALIZATION_POLICY,
                provenance["policy"],
            )
            self.assertEqual(
                subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    cwd=fixture.root,
                    check=True,
                    stdout=subprocess.PIPE,
                    text=True,
                ).stdout.strip(),
                provenance["head_commit"],
            )

    def test_auto_materialization_fails_closed_for_dirty_or_authority_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            fixture.complete_base_queue()
            fixture.dag()
            fixture.recipe()
            fixture.compiler().compile("IOS-COMPILE-TARGET-001")
            fixture.initialize_git()
            (fixture.root / "untracked.txt").write_text("dirty\n", encoding="utf-8")
            decision = loop_supervisor.LoopSupervisor(fixture.harness).inspect()
            self.assertEqual("auto_materialization_blocked", decision.state)
            self.assertEqual(
                "GIT_WORKTREE_DIRTY",
                decision.blockers[0]["reason_code"],
            )

        with tempfile.TemporaryDirectory() as directory:
            fixture = CompilerFixture(Path(directory))
            fixture.complete_base_queue()
            fixture.dag()
            recipe = fixture.recipe()
            recipe["work_item"]["spec"]["scope"]["allow_write"] = [
                "ios/Packages/LegadoKit/Sources/LegadoCore/Product.swift"
            ]
            fixture.fixture.write_json(
                f"{proposal_compiler.RECIPE_ROOT}/IOS-COMPILE-TARGET-001.json",
                recipe,
            )
            fixture.compiler().compile("IOS-COMPILE-TARGET-001")
            fixture.initialize_git()
            decision = loop_supervisor.LoopSupervisor(fixture.harness).inspect()
            self.assertEqual("auto_materialization_blocked", decision.state)
            self.assertIn(
                "AUTO_POLICY_SCOPE_DENIED",
                decision.blockers[0]["reason_code"],
            )


if __name__ == "__main__":
    unittest.main()
