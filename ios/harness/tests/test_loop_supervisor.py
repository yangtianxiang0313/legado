import contextlib
import hashlib
import http.client
import inspect
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
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
        self.root = HARNESS_DIR.parents[1]
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

    def resolve(self, value):
        return self.root / value

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
        self.assertEqual(
            "HUMAN_DECISION_REQUIRED",
            supervisor.inspect().reason_code,
        )

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
        self.assertEqual("terminal_recovery", decision.state)

        harness.items["IOS-READY-001"]["spec"].update(
            {
                "capability": "CAP-TEST",
                "inputs": {"context_files": []},
            }
        )
        harness.items["IOS-FIX-001"] = {
            "metadata": {
                "priority": 1,
                "labels": ["recovery"],
            },
            "spec": {
                "capability": "CAP-TEST",
                "depends_on": [],
                "inputs": {
                    "context_files": [
                        "ios/harness/work-items/IOS-READY-001.json"
                    ]
                },
            },
        }
        harness.state_value["work_items"]["IOS-FIX-001"] = {
            "status": "completed"
        }
        decision = supervisor.inspect()
        self.assertEqual("terminal_recovery", decision.state)
        self.assertEqual(
            "TERMINAL_WITHOUT_RECOVERY",
            decision.blockers[0]["resolution"]["reason_code"],
        )

        harness.state_value["work_items"]["IOS-READY-001"]["replacement"] = (
            "IOS-FIX-001"
        )
        resolution = supervisor._terminal_resolution(
            "IOS-READY-001",
            harness.items,
            harness.state_value["work_items"],
        )
        self.assertEqual(
            "EXPLICIT_REPLACEMENT",
            resolution["reason_code"],
        )
        decision = supervisor.inspect()
        self.assertEqual("queue_empty", decision.state)
        self.assertEqual("NO_ELIGIBLE_COMPILED_CANDIDATE", decision.reason_code)

        harness.state_value["work_items"]["IOS-READY-001"]["replacement"] = (
            "IOS-MISSING-RECOVERY"
        )
        decision = supervisor.inspect()
        self.assertEqual("terminal_recovery", decision.state)
        self.assertEqual(
            "DEPENDENCY_MISSING",
            decision.blockers[0]["resolution"]["reason_code"],
        )

        harness.state_value["work_items"]["IOS-READY-001"] = {
            "status": "blocked",
            "blocker": "baseline_red",
        }
        decision = supervisor.inspect()
        self.assertEqual("terminal_recovery", decision.state)
        self.assertEqual("BLOCKED_WORK_ITEM_REQUIRES_RESOLUTION", decision.reason_code)

    def test_auto_materialization_priority_tie_is_not_guessed(self):
        first = loop_supervisor.AutoMaterializationCandidate(
            proposal_id="IOS-AUTO-A-001",
            priority=90,
            head_commit="a" * 40,
            candidate_relative="candidate-a",
            manifest_relative="manifest-a",
            candidate_sha256="b" * 64,
            manifest_sha256="c" * 64,
        )
        second = loop_supervisor.AutoMaterializationCandidate(
            proposal_id="IOS-AUTO-B-001",
            priority=90,
            head_commit="a" * 40,
            candidate_relative="candidate-b",
            manifest_relative="manifest-b",
            candidate_sha256="d" * 64,
            manifest_sha256="e" * 64,
        )
        selected, blocker = loop_supervisor.LoopSupervisor._select_auto_candidate(
            [first, second]
        )
        self.assertIsNone(selected)
        self.assertEqual(
            "AUTO_MATERIALIZATION_PRIORITY_AMBIGUOUS",
            blocker["reason_code"],
        )


class MaterializationFixture:
    def __init__(self, root: Path):
        self.root = root
        self.fixture = HarnessFixture(root)
        self.harness = self.fixture.initialize()
        self.fixture.write_text(".gitignore", ".harness-runtime/\n")
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
    def test_auto_scope_allows_only_registered_dispatcher_path(self):
        allowed = loop_supervisor.LoopSupervisor._auto_scope_allowed

        self.assertTrue(
            allowed("ios/harness/github_oracle_dispatcher.py")
        )
        self.assertFalse(allowed("ios/harness/unregistered.py"))
        self.assertFalse(allowed("ios/harness/**"))

        self.assertTrue(allowed("ios/harness/demand_compiler.py"))
        self.assertTrue(allowed("ios/harness/tests/test_example.py"))
        self.assertFalse(
            allowed(".github/workflows/android-oracle-attestation.yml")
        )
        self.assertFalse(allowed("ios/harness/goldens/example.json"))

    def test_inspect_surfaces_authority_demand_instead_of_queue_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            state = fixture.harness.state()
            for runtime in state["work_items"].values():
                runtime["status"] = "superseded"
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()
            plan = loop_supervisor.DemandPlan(
                intent_id="DINT-SOURCE-RUNTIME-HTML-CSS-001",
                priority=100,
                target_work_item_id="IOS-SOURCE-RUNTIME-HTML-CSS-001",
                state="knowledge_authority_required",
                reason_code="KNOWLEDGE_AUTHORITY_REQUIRED",
                authority_transition=True,
                artifacts=(),
                bindings={},
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                fixture.harness,
                "doctor",
                return_value=([], []),
            ):
                decision = loop_supervisor.LoopSupervisor(
                    fixture.harness
                ).inspect()
            self.assertEqual(
                "authority_transition_required",
                decision.state,
            )
            self.assertEqual(
                "KNOWLEDGE_AUTHORITY_REQUIRED",
                decision.reason_code,
            )
            self.assertFalse(decision.requires_human)
            self.assertTrue(decision.details["authority_transition"])
            self.assertEqual(
                "IOS-SOURCE-RUNTIME-HTML-CSS-001",
                decision.work_item_id,
            )

    def test_completed_demand_is_not_rescheduled(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            completed = loop_supervisor.DemandPlan(
                intent_id="DINT-COMPLETED-001",
                priority=100,
                target_work_item_id="IOS-COMPLETED-001",
                state="delivery_completed",
                reason_code="DELIVERY_EVIDENCE_SETTLED",
                authority_transition=False,
                artifacts=(),
                bindings={"settlement": {}},
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((completed,), ()),
            ):
                self.assertIsNone(
                    loop_supervisor.LoopSupervisor(
                        fixture.harness
                    )._demand_decision([])
                )

    def test_migration_demand_maps_to_automatic_materialization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-SOURCE-REQUEST-POST-FORM-001",
                priority=100,
                target_work_item_id=(
                    "IOS-ANDROID-REQUEST-OPTIONS-INTAKE-001"
                ),
                state="migration_intake_ready",
                reason_code="MIGRATION_INTAKE_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={"blueprint": {}, "requirement_proposal": {}},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_migration_plan_preview",
            ):
                decision = supervisor._demand_decision([])

            self.assertEqual(
                "migration_materialization_ready",
                decision.state,
            )
            self.assertEqual(
                "MINT-SOURCE-REQUEST-POST-FORM-001",
                decision.details["demand_plan"]["intent_id"],
            )
            self.assertFalse(decision.requires_human)

    def test_migration_materialization_recomputes_selected_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-TEST-MIGRATION-001",
                priority=100,
                target_work_item_id="IOS-TEST-MIGRATION-001",
                state="migration_intake_ready",
                reason_code="MIGRATION_INTAKE_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            preview = mock.Mock(
                spec=loop_supervisor.MaterializationPreview
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_migration_plan_preview",
                return_value=preview,
            ), mock.patch.object(
                supervisor,
                "materialize",
                return_value=plan.target_work_item_id,
            ) as materialize:
                result = supervisor.auto_materialize_migration(
                    plan.intent_id
                )

            self.assertEqual(plan.target_work_item_id, result)
            materialize.assert_called_once_with(
                preview,
                reason=(
                    "policy:"
                    + loop_supervisor.MIGRATION_MATERIALIZATION_POLICY
                ),
                provenance=plan.to_dict(),
            )

    def test_characterization_demand_maps_to_automatic_materialization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-SOURCE-REQUEST-POST-FORM-001",
                priority=100,
                target_work_item_id="IOS-SOURCELAB-POST-FORM-001",
                state="characterization_ready",
                reason_code="CHARACTERIZATION_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={"characterization_blueprint": {}},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_characterization_plan_preview",
            ):
                decision = supervisor._demand_decision([])

            self.assertEqual(
                "characterization_materialization_ready",
                decision.state,
            )
            self.assertEqual(
                "IOS-SOURCELAB-POST-FORM-001",
                decision.work_item_id,
            )
            self.assertFalse(decision.requires_human)

    def test_characterization_materialization_recomputes_selected_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-TEST-CHARACTERIZATION-001",
                priority=100,
                target_work_item_id="IOS-TEST-CHARACTERIZATION-001",
                state="characterization_ready",
                reason_code="CHARACTERIZATION_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            preview = mock.Mock(
                spec=loop_supervisor.MaterializationPreview
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_characterization_plan_preview",
                return_value=preview,
            ), mock.patch.object(
                supervisor,
                "materialize",
                return_value=plan.target_work_item_id,
            ) as materialize:
                result = (
                    supervisor.auto_materialize_characterization(
                        plan.intent_id
                    )
                )

            self.assertEqual(plan.target_work_item_id, result)
            materialize.assert_called_once_with(
                preview,
                reason=(
                    "policy:"
                    + loop_supervisor
                    .CHARACTERIZATION_MATERIALIZATION_POLICY
                ),
                provenance=plan.to_dict(),
            )

    def test_oracle_demand_maps_to_automatic_materialization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-SOURCE-REQUEST-POST-FORM-001",
                priority=100,
                target_work_item_id=(
                    "IOS-ANDROID-POST-FORM-ORACLE-001"
                ),
                state="oracle_ready",
                reason_code="ORACLE_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={"oracle_blueprint": {}},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_oracle_plan_preview",
            ):
                decision = supervisor._demand_decision([])
            self.assertEqual(
                "oracle_materialization_ready",
                decision.state,
            )
            self.assertEqual(
                plan.target_work_item_id,
                decision.work_item_id,
            )

    def test_oracle_materialization_recomputes_selected_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-TEST-ORACLE-001",
                priority=100,
                target_work_item_id="IOS-TEST-ORACLE-001",
                state="oracle_ready",
                reason_code="ORACLE_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            preview = mock.Mock(
                spec=loop_supervisor.MaterializationPreview
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_oracle_plan_preview",
                return_value=preview,
            ), mock.patch.object(
                supervisor,
                "materialize",
                return_value=plan.target_work_item_id,
            ) as materialize:
                result = supervisor.auto_materialize_oracle(
                    plan.intent_id
                )
            self.assertEqual(plan.target_work_item_id, result)
            materialize.assert_called_once_with(
                preview,
                reason=(
                    "policy:"
                    + loop_supervisor.ORACLE_MATERIALIZATION_POLICY
                ),
                provenance=plan.to_dict(),
            )

    def test_trusted_oracle_demand_maps_to_automatic_materialization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-SOURCE-REQUEST-POST-FORM-001",
                priority=100,
                target_work_item_id=(
                    "IOS-ANDROID-POST-FORM-ATTESTATION-001"
                ),
                state="trusted_oracle_ready",
                reason_code="TRUSTED_ORACLE_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={"trusted_oracle_blueprint": {}},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_trusted_oracle_plan_preview",
            ):
                decision = supervisor._demand_decision([])
            self.assertEqual(
                "trusted_oracle_materialization_ready",
                decision.state,
            )
            self.assertEqual(
                plan.target_work_item_id,
                decision.work_item_id,
            )

    def test_trusted_oracle_settlement_maps_to_external_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-SOURCE-REQUEST-POST-FORM-001",
                priority=100,
                target_work_item_id=(
                    "IOS-ANDROID-POST-FORM-ATTESTATION-RECOVERY-003"
                ),
                state="trusted_oracle_execution_required",
                reason_code=(
                    "TRUSTED_ORACLE_GITHUB_EXECUTION_REQUIRED"
                ),
                authority_transition=False,
                artifacts=(
                    {
                        "kind": "trusted_oracle_github_execution",
                        "status": "required",
                        "receipt": None,
                    },
                ),
                bindings={
                    "trusted_oracle_execution": {
                        "scenario_id": "sl-post-form-001",
                        "workflow_path": (
                            ".github/workflows/"
                            "android-oracle-attestation.yml"
                        ),
                        "source_digest": "a" * 40,
                        "receipt": None,
                    }
                },
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ):
                decision = supervisor._demand_decision([])
            self.assertEqual(
                "external_execution_required",
                decision.state,
            )
            self.assertFalse(decision.requires_human)
            self.assertEqual((), decision.commands)
            self.assertEqual(
                plan.bindings["trusted_oracle_execution"],
                decision.details["external_execution"],
            )

    def test_verified_oracle_receipt_maps_to_external_publisher(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            binding = {
                "scenario_id": "sl-post-form-001",
                "receipt": (
                    "ios/project/external-execution-receipts/receipt.json"
                ),
                "next_authority": "independent_golden_publisher",
            }
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-SOURCE-REQUEST-POST-FORM-001",
                priority=100,
                target_work_item_id="IOS-ANDROID-POST-FORM-ATTESTATION-001",
                state="trusted_oracle_golden_publisher_required",
                reason_code="TRUSTED_ORACLE_GOLDEN_PUBLISHER_REQUIRED",
                authority_transition=False,
                artifacts=(),
                bindings={"trusted_oracle_execution": binding},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ):
                decision = supervisor._demand_decision([])
            self.assertEqual("external_publisher_required", decision.state)
            self.assertFalse(decision.requires_human)
            self.assertEqual((), decision.commands)
            self.assertEqual(
                binding,
                decision.details["external_publisher"],
            )

    def test_drive_external_publisher_does_not_invoke_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            decision = loop_supervisor.LoopDecision(
                state="external_publisher_required",
                reason_code="TRUSTED_ORACLE_GOLDEN_PUBLISHER_REQUIRED",
                work_item_id="IOS-ANDROID-POST-FORM-ATTESTATION-001",
                requires_human=False,
            )
            config = Path(directory) / "supervisor.json"
            config.write_text(
                json.dumps(
                    {
                        "agent_invocation": {
                            "argv": ["must-not-run"],
                            "timeout_seconds": 1,
                        }
                    }
                )
            )
            with mock.patch.object(
                supervisor, "inspect", return_value=decision
            ), mock.patch.object(
                supervisor, "_invoke_agent_phase"
            ) as invoke:
                result = supervisor.drive(
                    config_path=config,
                    agent_id="test-agent",
                    max_transitions=1,
                )
            self.assertEqual(
                "trusted_oracle_golden_publisher_required",
                result["outcome"],
            )
            self.assertEqual([], result["transitions"])
            invoke.assert_not_called()

    def test_enabled_external_publisher_dispatches_and_never_invokes_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            config = Path(directory) / "supervisor.json"
            config.write_text(
                json.dumps(
                    {
                        "external_execution": {
                            "github_golden": {
                                "enabled": True,
                                "repository": "owner/legado",
                                "remote": "origin",
                            }
                        }
                    }
                )
            )
            binding = {
                "scenario_id": "sl-post-form-001",
                "receipt": (
                    "ios/project/external-execution-receipts/"
                    "android-oracle-sl-post-form-001-a.json"
                ),
                "receipt_sha256": "b" * 64,
            }
            decision = loop_supervisor.LoopDecision(
                state="external_publisher_required",
                reason_code=(
                    "TRUSTED_ORACLE_GOLDEN_PUBLISHER_REQUIRED"
                ),
                work_item_id="IOS-ANDROID-POST-FORM-ATTESTATION-001",
                requires_human=False,
                details={"external_publisher": binding},
            )
            dispatched = {
                "schema_version": 1,
                "outcome": "pending",
                "execution_id": "execution",
                "request_branch": "feature/golden-test",
                "result_branch": "golden/result-test",
                "journal": (
                    ".harness-runtime/github-golden/execution.json"
                ),
                "run": None,
                "result_commit": None,
            }
            with mock.patch.object(
                supervisor, "inspect", return_value=decision
            ), mock.patch.object(
                supervisor, "_invoke_agent_phase"
            ) as invoke, mock.patch.object(
                fixture.harness,
                "git_head",
                return_value="a" * 40,
            ), mock.patch.object(
                loop_supervisor.GitHubGoldenPublisherDispatcher,
                "dispatch",
                return_value=dispatched,
            ) as dispatch:
                result = supervisor.drive(
                    config_path=config,
                    agent_id="test-agent",
                    max_transitions=1,
                )
            self.assertEqual("pending", result["outcome"])
            self.assertEqual(
                dispatched, result["external_publisher"]
            )
            self.assertNotIn("continuation_decision", result)
            dispatch.assert_called_once_with()
            invoke.assert_not_called()

    def test_settled_external_publisher_reinspects_without_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            config = Path(directory) / "supervisor.json"
            config.write_text(
                json.dumps(
                    {
                        "external_execution": {
                            "github_golden": {
                                "enabled": True,
                                "repository": "owner/legado",
                                "remote": "origin",
                            }
                        }
                    }
                )
            )
            binding = {
                "scenario_id": "sl-post-form-001",
                "receipt": (
                    "ios/project/external-execution-receipts/"
                    "android-oracle-sl-post-form-001-a.json"
                ),
                "receipt_sha256": "b" * 64,
            }
            decision = loop_supervisor.LoopDecision(
                state="external_publisher_required",
                reason_code=(
                    "TRUSTED_ORACLE_GOLDEN_PUBLISHER_REQUIRED"
                ),
                work_item_id="IOS-ANDROID-POST-FORM-ATTESTATION-001",
                requires_human=False,
                details={"external_publisher": binding},
            )
            continuation = loop_supervisor.LoopDecision(
                state="migration_materialization_ready",
                reason_code="MIGRATION_INPUTS_READY",
                work_item_id="IOS-NEXT-001",
                requires_human=False,
            )
            dispatched = {
                "schema_version": 1,
                "outcome": "settled",
                "execution_id": "execution",
                "request_branch": "feature/golden-test",
                "result_branch": "golden/result-test",
                "journal": (
                    ".harness-runtime/github-golden/execution.json"
                ),
                "run": {
                    "id": 1,
                    "attempt": 1,
                    "status": "completed",
                    "conclusion": "success",
                    "url": "https://example.invalid/1",
                },
                "result_commit": "c" * 40,
            }
            with mock.patch.object(
                supervisor,
                "inspect",
                side_effect=(decision, continuation),
            ), mock.patch.object(
                supervisor, "_invoke_agent_phase"
            ) as invoke, mock.patch.object(
                fixture.harness,
                "git_head",
                return_value="a" * 40,
            ), mock.patch.object(
                loop_supervisor.GitHubGoldenPublisherDispatcher,
                "dispatch",
                return_value=dispatched,
            ):
                result = supervisor.drive(
                    config_path=config,
                    agent_id="test-agent",
                    max_transitions=1,
                )
            self.assertEqual("settled", result["outcome"])
            self.assertEqual(
                continuation.to_dict(),
                result["continuation_decision"],
            )
            invoke.assert_not_called()

    def test_trusted_oracle_materialization_recomputes_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            plan = loop_supervisor.DemandPlan(
                intent_id="MINT-TEST-TRUSTED-ORACLE-001",
                priority=100,
                target_work_item_id=(
                    "IOS-TEST-TRUSTED-ORACLE-001"
                ),
                state="trusted_oracle_ready",
                reason_code="TRUSTED_ORACLE_INPUTS_READY",
                authority_transition=False,
                artifacts=(),
                bindings={},
                policy=loop_supervisor.MIGRATION_MATERIALIZATION_POLICY,
                intent_kind="android_migration",
            )
            preview = mock.Mock(
                spec=loop_supervisor.MaterializationPreview
            )
            with mock.patch.object(
                loop_supervisor.DemandCompiler,
                "plans",
                return_value=((plan,), ()),
            ), mock.patch.object(
                supervisor,
                "_trusted_oracle_plan_preview",
                return_value=preview,
            ), mock.patch.object(
                supervisor,
                "materialize",
                return_value=plan.target_work_item_id,
            ) as materialize:
                result = (
                    supervisor.auto_materialize_trusted_oracle(
                        plan.intent_id
                    )
                )
            self.assertEqual(plan.target_work_item_id, result)
            materialize.assert_called_once_with(
                preview,
                reason=(
                    "policy:"
                    + loop_supervisor
                    .TRUSTED_ORACLE_MATERIALIZATION_POLICY
                ),
                provenance=plan.to_dict(),
            )

    def test_migration_scope_rejects_product_and_authority_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item = fixture.fixture.item(
                "IOS-TEST-MIGRATION-001",
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            item["spec"]["scope"]["allow_write"] = [
                "ios/Packages/LegadoKit/Sources/SourceRuntime/New.swift"
            ]
            issues = loop_supervisor.LoopSupervisor(
                fixture.harness
            )._migration_scope_issues(
                item,
                (
                    "ios/project/requirement-proposals/"
                    "ARQ-TEST-MIGRATION.json"
                ),
            )
            self.assertIn(
                "MIGRATION_SCOPE_FORBIDDEN:"
                "ios/Packages/LegadoKit/Sources/SourceRuntime/New.swift",
                issues,
            )
            self.assertTrue(
                any(
                    issue.startswith("MIGRATION_SCOPE_DENY_MISSING:")
                    for issue in issues
                )
            )

    def test_characterization_scope_is_exact_and_authority_denied(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item = fixture.fixture.item(
                "IOS-TEST-CHARACTERIZATION-001",
                "CAP-CONFORMANCE",
                100,
            )
            item["spec"]["source_lab"] = {
                "mode": "extend",
                "behaviors": ["transport.post-form"],
                "scenarios": ["sl-post-form-001"],
            }
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/fixtures/source-lab/sl-post-form-001/**",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                (
                    "ios/project/checkpoints/"
                    "IOS-TEST-CHARACTERIZATION-001.json"
                ),
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/harness/source-lab/**",
                "ios/harness/oracle/**",
                "ios/harness/goldens/**",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            self.assertEqual(
                [],
                supervisor._characterization_scope_issues(item),
            )
            item["spec"]["scope"]["allow_write"].append(
                "ios/Packages/LegadoKit/Sources/New.swift"
            )
            self.assertIn(
                "CHARACTERIZATION_SCOPE_ALLOW_INVALID",
                supervisor._characterization_scope_issues(item),
            )

    def test_oracle_scope_is_exact_and_golden_denied(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item = fixture.fixture.item(
                "IOS-TEST-ORACLE-001",
                "CAP-CONFORMANCE",
                100,
            )
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/oracle/android-runner/**",
                "ios/harness/oracle/README.md",
                "ios/harness/tests/test_android_oracle_runner.py",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                (
                    "ios/project/checkpoints/"
                    "IOS-TEST-ORACLE-001.json"
                ),
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/fixtures/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/ci_proposal.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            self.assertEqual([], supervisor._oracle_scope_issues(item))
            item["spec"]["scope"]["allow_write"].append(
                "ios/harness/goldens/new.json"
            )
            self.assertIn(
                "ORACLE_SCOPE_ALLOW_INVALID",
                supervisor._oracle_scope_issues(item),
            )

    def test_trusted_oracle_scope_is_exact_and_publisher_denied(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item = fixture.fixture.item(
                "IOS-TEST-TRUSTED-ORACLE-001",
                "CAP-CONFORMANCE",
                100,
            )
            item["spec"]["scope"]["allow_write"] = [
                (
                    ".github/workflows/"
                    "android-oracle-attestation.yml"
                ),
                "ios/harness/oracle/ci_proposal.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/harness/oracle/README.md",
                "ios/harness/tests/test_oracle_ci_proposal.py",
                "ios/harness/tests/test_oracle_trusted_import.py",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                (
                    "ios/project/checkpoints/"
                    "IOS-TEST-TRUSTED-ORACLE-001.json"
                ),
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/fixtures/**",
                "ios/harness/source-lab/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/android-runner/**",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            self.assertEqual(
                [],
                supervisor._trusted_oracle_scope_issues(item),
            )
            item["spec"]["scope"]["allow_write"].append(
                "ios/publisher/android_golden_publisher.py"
            )
            self.assertIn(
                "TRUSTED_ORACLE_SCOPE_ALLOW_INVALID",
                supervisor._trusted_oracle_scope_issues(item),
            )

    def test_trusted_oracle_recovery_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-TRUSTED-ORACLE-RECOVERY-002"
            item = fixture.fixture.item(
                item_id,
                "CAP-CONFORMANCE",
                100,
            )
            item["metadata"]["labels"] = [
                "control-plane",
                "android-oracle",
                "trusted-proposal",
                "candidate-only",
                "attestation",
                "github-actions",
                "corrective",
                "recovery",
            ]
            item["spec"]["recovers"] = (
                "IOS-TEST-TRUSTED-ORACLE-001"
            )
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                ".github/workflows/android-oracle-attestation.yml",
                "ios/harness/oracle/contract.py",
                "ios/harness/oracle/ci_proposal.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/harness/oracle/README.md",
                "ios/harness/tests/test_oracle_contract.py",
                "ios/harness/tests/test_oracle_ci_proposal.py",
                "ios/harness/tests/test_oracle_trusted_import.py",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/fixtures/**",
                "ios/harness/source-lab/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/android-runner/**",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )

            self.assertEqual(
                [],
                supervisor._trusted_oracle_recovery_scope_issues(
                    item
                ),
            )

            item["spec"]["scope"]["allow_write"].append(
                "ios/publisher/android_golden_publisher.py"
            )
            self.assertIn(
                "AUTO_TRUSTED_ORACLE_RECOVERY_SCOPE_ALLOW_INVALID",
                supervisor._trusted_oracle_recovery_scope_issues(
                    item
                ),
            )

    def test_android_oracle_workflow_hardening_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-WORKFLOW-HARDENING-001"
            item = fixture.fixture.item(
                item_id,
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            item["metadata"]["labels"] = [
                "external-execution",
                "workflow-hardening",
                "android-oracle",
                "corrective",
            ]
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                ".github/workflows/android-oracle-attestation.yml",
                "ios/harness/source-lab/tests/test_source_lab.py",
                "ios/harness/oracle/README.md",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/android-runner/**",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )

            self.assertEqual(
                [],
                supervisor
                ._android_oracle_workflow_hardening_scope_issues(
                    item
                ),
            )

            for drift in (
                ".github/workflows/change.yml",
                "ios/project/checkpoints/IOS-OTHER-001.json",
                "ios/publisher/android_golden_publisher.py",
                "ios/harness/goldens/manifest.json",
                "ios/Packages/LegadoKit/Package.swift",
                "ios/Packages/**",
            ):
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_WORKFLOW_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._android_oracle_workflow_hardening_scope_issues(
                            changed
                        ),
                    )

            for field, value in (
                ("gates", ["approval"]),
                (
                    "completion_effects",
                    {"health": {}, "publisher": {}},
                ),
            ):
                with self.subTest(field=field):
                    changed = json.loads(json.dumps(item))
                    changed["spec"][field] = value
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_WORKFLOW_AUTHORITY_INVALID",
                        supervisor
                        ._android_oracle_workflow_hardening_scope_issues(
                            changed
                        ),
                    )

    def test_workflow_hardening_requires_every_label_to_bypass_github(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item = fixture.fixture.item(
                "IOS-TEST-WORKFLOW-HARDENING-001",
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            required = {
                "external-execution",
                "workflow-hardening",
                "android-oracle",
                "corrective",
            }
            item["spec"]["requirements"]["mode"] = "control_plane"
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                ".github/workflows/android-oracle-attestation.yml",
                "ios/harness/source-lab/tests/test_source_lab.py",
                "ios/harness/oracle/README.md",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                (
                    "ios/project/checkpoints/"
                    "IOS-TEST-WORKFLOW-HARDENING-001.json"
                ),
                "ios/project/pitfalls/PIT-*.json",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            self.assertFalse(
                supervisor._auto_scope_allowed(
                    item["spec"]["scope"]["allow_write"][0]
                )
            )
            for missing in required:
                with self.subTest(missing=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required - {missing}
                    )
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_WORKFLOW_AUTHORITY_INVALID",
                        supervisor
                        ._android_oracle_workflow_hardening_scope_issues(
                            changed
                        ),
                    )

    def test_android_oracle_ci_packager_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-ORACLE-CI-PACKAGER-001"
            item = fixture.fixture.item(
                item_id,
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            required_labels = {
                "external-execution",
                "android-oracle",
                "ci-packager",
                "corrective",
            }
            item["metadata"]["labels"] = sorted(required_labels)
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/oracle/ci_proposal.py",
                "ios/harness/tests/test_oracle_ci_proposal.py",
                "ios/harness/oracle/README.md",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/fixtures/**",
                "ios/harness/source-lab/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/contract.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/harness/oracle/android-runner/**",
                "ios/project/baseline.json",
                "ios/project/requirements/**",
                "ios/project/business-knowledge/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )

            self.assertEqual(
                [],
                supervisor
                ._android_oracle_ci_packager_scope_issues(item),
            )

            for drift in (
                ".github/workflows/android-oracle-attestation.yml",
                "ios/harness/oracle/contract.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/harness/oracle/android-runner/orchestrator.py",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/goldens/manifest.json",
                "ios/publisher/android_golden_publisher.py",
                "ios/harness/source-lab/source_lab.py",
                "ios/harness/fixtures/source-lab/new.json",
                "ios/project/requirements/catalog.json",
                "ios/project/approvals/decision.json",
                "ios/project/business-knowledge/catalog.json",
                "ios/Packages/LegadoKit/Package.swift",
                "app/new.kt",
                "modules/new.kt",
                "ios/docs/architecture.md",
                "ios/project/checkpoints/IOS-OTHER-001.json",
                "ios/**",
            ):
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_CI_PACKAGER_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._android_oracle_ci_packager_scope_issues(
                            changed
                        ),
                    )

            for missing in required_labels:
                with self.subTest(missing=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required_labels - {missing}
                    )
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_CI_PACKAGER_AUTHORITY_INVALID",
                        supervisor
                        ._android_oracle_ci_packager_scope_issues(
                            changed
                        ),
                    )

    def test_github_golden_publisher_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-GOLDEN-PUBLISHER-001"
            item = fixture.fixture.item(
                item_id,
                "CAP-CONFORMANCE",
                100,
            )
            required_labels = {
                "external-execution",
                "android-oracle",
                "golden-publisher",
                "corrective",
            }
            item["metadata"]["labels"] = sorted(required_labels)
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                ".github/workflows/android-golden-publisher.yml",
                "ios/publisher/android_golden_publisher.py",
                "ios/publisher/README.md",
                "ios/harness/tests/test_android_golden_publisher.py",
                "ios/project/capabilities/CAP-CONFORMANCE.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/workflows/android-oracle-attestation.yml",
                ".github/workflows/change.yml",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/harness/harness.py",
                "ios/harness/demand_compiler.py",
                "ios/harness/loop_supervisor.py",
                "ios/harness/github_golden_publisher.py",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/github_oracle_receipt.py",
                "ios/harness/oracle/**",
                "ios/harness/fixtures/**",
                "ios/harness/source-lab/**",
                "ios/harness/goldens/**",
                "ios/project/external-execution-receipts/**",
                "ios/project/baseline.json",
                "ios/project/requirements/**",
                "ios/project/business-knowledge/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )

            self.assertEqual(
                [],
                supervisor._github_golden_publisher_scope_issues(item),
            )

            for drift in (
                ".github/workflows/change.yml",
                "ios/harness/goldens/manifest.json",
                "ios/harness/github_golden_publisher.py",
                "ios/harness/github_oracle_receipt.py",
                "ios/harness/oracle/contract.py",
                "ios/Packages/LegadoKit/Package.swift",
                "app/new.kt",
                "modules/new.kt",
                "ios/project/requirements/catalog.json",
                "ios/project/checkpoints/IOS-OTHER-001.json",
                "ios/**",
            ):
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_GITHUB_GOLDEN_PUBLISHER_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._github_golden_publisher_scope_issues(changed),
                    )

            for missing in required_labels:
                with self.subTest(missing=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required_labels - {missing}
                    )
                    self.assertIn(
                        "AUTO_GITHUB_GOLDEN_PUBLISHER_AUTHORITY_INVALID",
                        supervisor
                        ._github_golden_publisher_scope_issues(changed),
                    )

            changed = json.loads(json.dumps(item))
            changed["spec"]["scope"]["deny_write"] = []
            self.assertTrue(
                all(
                    issue.startswith(
                        "AUTO_GITHUB_GOLDEN_PUBLISHER_SCOPE_DENY_MISSING:"
                    )
                    for issue in supervisor
                    ._github_golden_publisher_scope_issues(changed)
                )
            )

    def test_github_golden_dispatcher_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-GOLDEN-DISPATCHER-001"
            item = fixture.fixture.item(
                item_id,
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            required_labels = {
                "external-execution",
                "android-oracle",
                "golden-dispatcher",
                "corrective",
            }
            item["metadata"]["labels"] = sorted(required_labels)
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/github_golden_publisher.py",
                "ios/harness/tests/test_github_golden_publisher.py",
                "ios/harness/loop_supervisor.py",
                "ios/harness/tests/test_loop_supervisor.py",
                "ios/harness/supervisor.example.json",
                "ios/harness/README.md",
                "ios/project/capabilities/CAP-KNOWLEDGE-CONTROL.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/harness.py",
                "ios/harness/demand_compiler.py",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/github_oracle_receipt.py",
                "ios/harness/oracle/**",
                "ios/harness/fixtures/**",
                "ios/harness/source-lab/**",
                "ios/harness/goldens/**",
                "ios/project/external-execution-receipts/**",
                "ios/project/baseline.json",
                "ios/project/requirements/**",
                "ios/project/business-knowledge/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            self.assertEqual(
                [],
                supervisor._github_golden_dispatcher_scope_issues(item),
            )
            for drift in (
                ".github/workflows/android-golden-publisher.yml",
                "ios/publisher/android_golden_publisher.py",
                "ios/harness/goldens/manifest.json",
                "ios/harness/github_oracle_receipt.py",
                "ios/Packages/LegadoKit/Package.swift",
                "app/new.kt",
                "ios/project/requirements/catalog.json",
                "ios/project/checkpoints/IOS-OTHER-001.json",
                "ios/**",
            ):
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_GITHUB_GOLDEN_DISPATCHER_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._github_golden_dispatcher_scope_issues(changed),
                    )
            for missing in required_labels:
                with self.subTest(missing=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required_labels - {missing}
                    )
                    self.assertIn(
                        "AUTO_GITHUB_GOLDEN_DISPATCHER_AUTHORITY_INVALID",
                        supervisor
                        ._github_golden_dispatcher_scope_issues(changed),
                    )

            for field, value in (
                ("gates", ["approval"]),
                (
                    "completion_effects",
                    {"health": {}, "publisher": {}},
                ),
            ):
                with self.subTest(field=field):
                    changed = json.loads(json.dumps(item))
                    changed["spec"][field] = value
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_CI_PACKAGER_AUTHORITY_INVALID",
                        supervisor
                        ._android_oracle_ci_packager_scope_issues(
                            changed
                        ),
                    )

            for missing in tuple(
                item["spec"]["scope"]["allow_write"]
            ):
                with self.subTest(missing_allow=missing):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].remove(
                        missing
                    )
                    self.assertIn(
                        "AUTO_ANDROID_ORACLE_CI_PACKAGER_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._android_oracle_ci_packager_scope_issues(
                            changed
                        ),
                    )

            duplicate = json.loads(json.dumps(item))
            duplicate["spec"]["scope"]["allow_write"].append(
                "ios/harness/oracle/ci_proposal.py"
            )
            self.assertIn(
                "AUTO_ANDROID_ORACLE_CI_PACKAGER_SCOPE_ALLOW_INVALID",
                supervisor
                ._android_oracle_ci_packager_scope_issues(duplicate),
            )

            denial_drift = json.loads(json.dumps(item))
            denial_drift["spec"]["scope"]["deny_write"].remove(
                "ios/harness/github_oracle_dispatcher.py"
            )
            self.assertIn(
                "AUTO_ANDROID_ORACLE_CI_PACKAGER_SCOPE_DENY_MISSING:"
                "ios/harness/github_oracle_dispatcher.py",
                supervisor
                ._android_oracle_ci_packager_scope_issues(
                    denial_drift
                ),
            )

    def test_harness_runtime_context_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-RUNTIME-CONTEXT-001"
            item = fixture.fixture.item(
                item_id,
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            required_labels = {
                "control-plane",
                "harness-runtime-context",
                "reproducibility",
                "corrective",
            }
            item["metadata"]["labels"] = sorted(required_labels)
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["source_lab"] = {
                "mode": "not_applicable",
                "behaviors": [],
                "scenarios": [],
                "none_reason": "test",
            }
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/harness.py",
                "ios/harness/tests/test_harness.py",
                "ios/harness/README.md",
                "ios/project/capabilities/CAP-KNOWLEDGE-CONTROL.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/loop_supervisor.py",
                "ios/harness/demand_compiler.py",
                "ios/harness/github_golden_publisher.py",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/github_oracle_receipt.py",
                "ios/harness/goldens/**",
                "ios/harness/oracle/**",
                "ios/harness/source-lab/**",
                "ios/harness/work-items/**",
                "ios/project/state.json",
                "ios/project/events.jsonl",
                "ios/project/status.md",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            self.assertEqual(
                [],
                supervisor._harness_runtime_context_scope_issues(item),
            )
            for drift in (
                ".github/workflows/android-golden-publisher.yml",
                "ios/harness/loop_supervisor.py",
                "ios/harness/github_golden_publisher.py",
                "ios/harness/goldens/manifest.json",
                "ios/harness/work-items/IOS-OLD-001.json",
                "ios/project/state.json",
                "ios/project/requirements/catalog.json",
                "ios/project/work-item-proposals/candidate.json",
                "ios/Packages/LegadoKit/Package.swift",
                "app/new.kt",
                "modules/new.kt",
                "ios/docs/architecture.md",
                "ios/**",
            ):
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_HARNESS_RUNTIME_CONTEXT_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._harness_runtime_context_scope_issues(changed),
                    )
            for missing in required_labels:
                with self.subTest(missing=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required_labels - {missing}
                    )
                    self.assertIn(
                        "AUTO_HARNESS_RUNTIME_CONTEXT_AUTHORITY_INVALID",
                        supervisor
                        ._harness_runtime_context_scope_issues(changed),
                    )
            denial_drift = json.loads(json.dumps(item))
            denial_drift["spec"]["scope"]["deny_write"] = []
            self.assertTrue(
                all(
                    issue.startswith(
                        "AUTO_HARNESS_RUNTIME_CONTEXT_SCOPE_DENY_MISSING:"
                    )
                    for issue in supervisor
                    ._harness_runtime_context_scope_issues(denial_drift)
                )
            )

    def test_golden_consumer_recovery_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-GOLDEN-CONSUMER-RECOVERY-002"
            item = fixture.fixture.item(
                item_id,
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            required_labels = {
                "control-plane",
                "demand-compiler",
                "golden-consumer-recovery",
                "publisher-compat",
                "corrective",
                "recovery",
            }
            item["metadata"]["labels"] = sorted(required_labels)
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["source_lab"] = {
                "mode": "not_applicable",
                "behaviors": [],
                "scenarios": [],
                "none_reason": "test",
            }
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/demand_compiler.py",
                "ios/harness/loop_supervisor.py",
                "ios/publisher/business_knowledge_publisher.py",
                "ios/harness/tests/test_business_knowledge_publisher.py",
                "ios/harness/tests/test_demand_compiler.py",
                "ios/harness/tests/test_loop_supervisor.py",
                "ios/harness/README.md",
                "ios/project/capabilities/CAP-KNOWLEDGE-CONTROL.json",
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/android_golden_publisher.py",
                "ios/harness/harness.py",
                "ios/harness/proposal_compiler.py",
                "ios/harness/github_golden_publisher.py",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/github_oracle_receipt.py",
                "ios/harness/config.json",
                "ios/harness/schemas/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/**",
                "ios/harness/source-lab/**",
                "ios/harness/work-items/**",
                "ios/project/state.json",
                "ios/project/events.jsonl",
                "ios/project/status.md",
                "ios/project/business-knowledge/**",
                "ios/project/delivery-intents/**",
                "ios/project/migration-intents/**",
                "ios/project/requirements/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            self.assertEqual(
                [],
                supervisor._golden_consumer_recovery_scope_issues(item),
            )
            for drift in (
                ".github/workflows/android-golden-publisher.yml",
                "ios/publisher/android_golden_publisher.py",
                "ios/harness/goldens/manifest.json",
                "ios/harness/github_golden_publisher.py",
                "ios/Packages/LegadoKit/Package.swift",
                "ios/project/business-knowledge/catalog.json",
                "ios/project/checkpoints/IOS-OTHER-001.json",
                "ios/**",
            ):
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_GOLDEN_CONSUMER_RECOVERY_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._golden_consumer_recovery_scope_issues(changed),
                    )
            for missing in required_labels:
                with self.subTest(missing=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required_labels - {missing}
                    )
                    self.assertIn(
                        "AUTO_GOLDEN_CONSUMER_RECOVERY_AUTHORITY_INVALID",
                        supervisor
                        ._golden_consumer_recovery_scope_issues(changed),
                    )
            denial_drift = json.loads(json.dumps(item))
            denial_drift["spec"]["scope"]["deny_write"].remove(
                "ios/harness/goldens/**"
            )
            self.assertIn(
                (
                    "AUTO_GOLDEN_CONSUMER_RECOVERY_SCOPE_DENY_MISSING:"
                    "ios/harness/goldens/manifest.json"
                ),
                supervisor._golden_consumer_recovery_scope_issues(
                    denial_drift
                ),
            )

    def test_github_oracle_receipt_settlement_auto_scope_is_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item_id = "IOS-TEST-GITHUB-ORACLE-RECEIPT-001"
            item = fixture.fixture.item(
                item_id,
                "CAP-KNOWLEDGE-CONTROL",
                100,
            )
            required_labels = {
                "external-execution",
                "android-oracle",
                "receipt-settlement",
                "corrective",
            }
            item["metadata"]["labels"] = sorted(required_labels)
            item["spec"]["requirements"] = {
                "mode": "control_plane",
                "refs": [],
                "none_reason": "test",
            }
            item["spec"]["knowledge"] = {
                "mode": "not_applicable",
            }
            item["spec"]["source_lab"] = {
                "mode": "not_applicable",
            }
            item["spec"]["scope"]["allow_write"] = [
                "ios/harness/github_oracle_receipt.py",
                "ios/harness/tests/test_github_oracle_receipt.py",
                "ios/harness/demand_compiler.py",
                "ios/harness/tests/test_demand_compiler.py",
                "ios/harness/loop_supervisor.py",
                "ios/harness/tests/test_loop_supervisor.py",
                "ios/harness/README.md",
                (
                    "ios/project/capabilities/"
                    "CAP-KNOWLEDGE-CONTROL.json"
                ),
                f"ios/project/checkpoints/{item_id}.json",
                "ios/project/pitfalls/PIT-*.json",
            ]
            item["spec"]["scope"]["deny_write"] = [
                ".github/**",
                "app/**",
                "modules/**",
                "ios/Packages/**",
                "ios/publisher/**",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/fixtures/**",
                "ios/harness/source-lab/**",
                "ios/harness/goldens/**",
                "ios/harness/oracle/**",
                "ios/project/baseline.json",
                "ios/project/requirements/**",
                "ios/project/business-knowledge/**",
                "ios/project/approvals/**",
                "ios/project/work-item-proposals/**",
                "ios/docs/**",
            ]
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )

            self.assertEqual(
                [],
                supervisor
                ._github_oracle_receipt_settlement_scope_issues(item),
            )

            forbidden = (
                ".github/workflows/android-oracle-attestation.yml",
                "ios/harness/oracle/contract.py",
                "ios/harness/oracle/ci_proposal.py",
                "ios/harness/oracle/trusted_import.py",
                "ios/harness/oracle/android-runner/orchestrator.py",
                "ios/harness/github_oracle_dispatcher.py",
                "ios/harness/goldens/manifest.json",
                "ios/publisher/android_golden_publisher.py",
                "ios/harness/source-lab/source_lab.py",
                "ios/harness/fixtures/source-lab/new.json",
                "ios/project/requirements/catalog.json",
                "ios/project/business-knowledge/catalog.json",
                "ios/project/approvals/decision.json",
                "ios/project/baseline.json",
                "ios/Packages/LegadoKit/Package.swift",
                "app/new.kt",
                "modules/new.kt",
                "ios/docs/architecture.md",
                "ios/project/checkpoints/IOS-OTHER-001.json",
                "ios/**",
            )
            for drift in forbidden:
                with self.subTest(drift=drift):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].append(
                        drift
                    )
                    self.assertIn(
                        "AUTO_GITHUB_ORACLE_RECEIPT_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._github_oracle_receipt_settlement_scope_issues(
                            changed
                        ),
                    )

            for missing in required_labels:
                with self.subTest(missing_label=missing):
                    changed = json.loads(json.dumps(item))
                    changed["metadata"]["labels"] = sorted(
                        required_labels - {missing}
                    )
                    self.assertIn(
                        "AUTO_GITHUB_ORACLE_RECEIPT_AUTHORITY_INVALID",
                        supervisor
                        ._github_oracle_receipt_settlement_scope_issues(
                            changed
                        ),
                    )

            for field, value in (
                ("gates", ["approval"]),
                ("requirements", {"mode": "implementation"}),
                ("knowledge", {"mode": "consume"}),
                ("source_lab", {"mode": "consume"}),
            ):
                with self.subTest(field=field):
                    changed = json.loads(json.dumps(item))
                    changed["spec"][field] = value
                    self.assertIn(
                        "AUTO_GITHUB_ORACLE_RECEIPT_AUTHORITY_INVALID",
                        supervisor
                        ._github_oracle_receipt_settlement_scope_issues(
                            changed
                        ),
                    )

            for missing in tuple(
                item["spec"]["scope"]["allow_write"]
            ):
                with self.subTest(missing_allow=missing):
                    changed = json.loads(json.dumps(item))
                    changed["spec"]["scope"]["allow_write"].remove(
                        missing
                    )
                    self.assertIn(
                        "AUTO_GITHUB_ORACLE_RECEIPT_SCOPE_ALLOW_INVALID",
                        supervisor
                        ._github_oracle_receipt_settlement_scope_issues(
                            changed
                        ),
                    )

            duplicate = json.loads(json.dumps(item))
            duplicate["spec"]["scope"]["allow_write"].append(
                "ios/harness/github_oracle_receipt.py"
            )
            self.assertIn(
                "AUTO_GITHUB_ORACLE_RECEIPT_SCOPE_ALLOW_INVALID",
                supervisor
                ._github_oracle_receipt_settlement_scope_issues(
                    duplicate
                ),
            )

            denial_drift = json.loads(json.dumps(item))
            denial_drift["spec"]["scope"]["deny_write"].remove(
                "ios/harness/oracle/**"
            )
            self.assertIn(
                "AUTO_GITHUB_ORACLE_RECEIPT_SCOPE_DENY_MISSING:"
                "ios/harness/oracle/contract.py",
                supervisor
                ._github_oracle_receipt_settlement_scope_issues(
                    denial_drift
                ),
            )

    def test_receipt_settlement_requires_every_label_for_special_scope(self):
        required = {
            "external-execution",
            "android-oracle",
            "receipt-settlement",
            "corrective",
        }
        source = inspect.getsource(
            loop_supervisor.LoopSupervisor._auto_candidate
        )
        for missing in required:
            with self.subTest(missing=missing):
                remaining = required - {missing}
                self.assertFalse(required.issubset(remaining))
        self.assertIn("receipt_settlement", source)
        self.assertIn(
            "_github_oracle_receipt_settlement_scope_issues",
            source,
        )
        self.assertFalse(
            loop_supervisor.LoopSupervisor._auto_scope_allowed(
                "ios/harness/github_oracle_receipt.py"
            )
        )

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

    def test_preflight_filename_binding_is_explicitly_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate(
                "IOS-TEST-CHARACTERIZATION-001"
            )
            intent_named = (
                fixture.candidate_root
                / "MINT-TEST-CHARACTERIZATION-001.json"
            )
            path.rename(intent_named)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)

            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "文件名必须与 metadata.id 一致",
            ):
                supervisor.preflight_candidate(intent_named)

            preview = supervisor.preflight_candidate(
                intent_named,
                require_filename_match=False,
            )
            self.assertEqual(
                item["metadata"]["id"],
                preview.item_id,
            )

    def test_preflight_policy_managed_gate_is_exactly_scoped(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate(
                "IOS-TEST-POLICY-GATE-001"
            )
            item["spec"]["gates"] = [
                "scenario-provenance-review"
            ]
            fixture.fixture.write_json(
                str(path.relative_to(fixture.root)),
                item,
            )
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)

            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "LEGACY_HUMAN_GATE_REJECTED",
            ):
                supervisor.preflight_candidate(path)

            preview = supervisor.preflight_candidate(
                path,
                policy_managed_gates=(
                    "scenario-provenance-review",
                ),
            )
            self.assertEqual(item["metadata"]["id"], preview.item_id)

            item["spec"]["gates"].append("architecture-review")
            fixture.fixture.write_json(
                str(path.relative_to(fixture.root)),
                item,
            )
            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "LEGACY_HUMAN_GATE_REJECTED",
            ):
                supervisor.preflight_candidate(
                    path,
                    policy_managed_gates=(
                        "scenario-provenance-review",
                    ),
                )

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

    def test_preflight_validates_typed_recovery_before_materialization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate()
            item["spec"]["recovers"] = "IOS-BOOT-001"
            fixture.fixture.write_json(str(path.relative_to(fixture.root)), item)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)

            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "可恢复终态",
            ):
                supervisor.preflight_candidate(path)

            state = fixture.harness.state()
            state["work_items"]["IOS-BOOT-001"]["status"] = "blocked"
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()
            preview = supervisor.preflight_candidate(path)
            self.assertEqual("IOS-BOOT-001", preview.recovers)
            self.assertEqual("IOS-BOOT-001", preview.to_dict()["recovers"])

            state["work_items"]["IOS-BOOT-001"]["replacement"] = (
                "IOS-OTHER-RECOVERY-001"
            )
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()
            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "已绑定 replacement",
            ):
                supervisor.preflight_candidate(path)

            state["work_items"]["IOS-BOOT-001"].pop("replacement")
            competing_id = "IOS-OTHER-RECOVERY-001"
            competing = fixture.fixture.item(
                competing_id,
                "CAP-BOOT",
                70,
            )
            competing["spec"]["recovers"] = "IOS-BOOT-001"
            fixture.fixture.write_json(
                f"ios/harness/work-items/{competing_id}.json",
                competing,
            )
            state["work_items"][competing_id] = {
                "status": "ready",
                "attempt": 0,
                "last_evidence": None,
            }
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()
            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "未终结 recovery",
            ):
                supervisor.preflight_candidate(path)

    def test_preflight_rejects_legacy_gate_and_accepts_structured_decision(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, item = fixture.candidate()
            item["spec"]["gates"] = ["architecture-choice"]
            fixture.fixture.write_json(str(path.relative_to(fixture.root)), item)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with self.assertRaisesRegex(
                loop_supervisor.MaterializationConflict,
                "LEGACY_HUMAN_GATE_REJECTED",
            ):
                supervisor.preflight_candidate(path)

            item["spec"]["gate_contract_version"] = 1
            item["spec"]["decision_gates"] = [
                {
                    "gate": "architecture-choice",
                    "trigger": "always",
                    "question": "采用哪个已验证的模块边界？",
                    "why_human": "两个方案都通过机器检查，但产品演进成本不同。",
                    "options": [
                        {
                            "id": "separate-package",
                            "label": "独立 Package",
                            "consequence": "获得更强替换边界，增加一个发布单元。",
                            "reversible": True,
                        },
                        {
                            "id": "existing-package",
                            "label": "留在现有 Package",
                            "consequence": "减少当前模块数，后续拆分成本更高。",
                            "reversible": True,
                        },
                    ],
                    "recommended_option": "separate-package",
                }
            ]
            fixture.fixture.write_json(str(path.relative_to(fixture.root)), item)
            preview = supervisor.preflight_candidate(path)
            self.assertEqual(("architecture-choice",), preview.gates)

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

    def test_materialize_accepts_intent_named_trusted_oracle_blueprint(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            item = fixture.fixture.item(
                "IOS-TEST-TRUSTED-ORACLE-001",
                "CAP-BOOT",
                80,
            )
            relative = (
                loop_supervisor.TRUSTED_ORACLE_BLUEPRINT_ROOT
                + "/MINT-TEST-TRUSTED-ORACLE-001.json"
            )
            fixture.fixture.write_json(relative, item)
            path = fixture.root / relative
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            preview = supervisor.preflight_candidate(
                path,
                allowed_root=(
                    loop_supervisor.TRUSTED_ORACLE_BLUEPRINT_ROOT
                ),
                require_filename_match=False,
            )

            item_id = supervisor.materialize(
                preview,
                reason="unit test",
            )

            self.assertEqual(
                "IOS-TEST-TRUSTED-ORACLE-001",
                item_id,
            )
            self.assertTrue(
                (
                    fixture.root
                    / "ios/harness/work-items"
                    / f"{item_id}.json"
                ).is_file()
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


class DeliveryBlueprintTests(unittest.TestCase):
    @staticmethod
    def initialize_git(root):
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Delivery Blueprint Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "delivery@example.invalid"],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "delivery baseline"], cwd=root, check=True)

    def prepare(self, root, *, readiness="implementation_ready", owner=True):
        fixture = MaterializationFixture(root)
        item_id = "IOS-DELIVERY-001"
        requirement_id = "REQ-DELIVERY-001"
        capability_id = "CAP-DELIVERY"
        record = {
            "schema_version": 1,
            "id": requirement_id,
            "revision": 1,
            "status": "accepted",
            "clauses": [{"id": "RC-01", "statement": "render html"}],
            "readiness": {"state": readiness, "blockers": []},
        }
        record_relative = (
            f"ios/project/requirements/accepted/{requirement_id}.json"
        )
        fixture.fixture.write_json(record_relative, record)
        record_sha = loop_supervisor.sha256_json(record)
        fixture.fixture.write_json(
            "ios/project/requirements/catalog.json",
            {
                "schema_version": 1,
                "requirements": [
                    {
                        "id": requirement_id,
                        "revision": 1,
                        "status": "accepted",
                        "readiness": readiness,
                        "path": record_relative,
                        "record_sha256": record_sha,
                        "clauses": ["RC-01"],
                    }
                ],
            },
        )
        fixture.fixture.write_json(
            f"ios/project/capabilities/{capability_id}.json",
            {
                "schema_version": 1,
                "id": capability_id,
                "revision": 3,
                "owners": {
                    "targets": ["SourceRuntime"],
                    "paths": (
                        ["ios/Packages/LegadoKit/Sources/SourceRuntime/**"]
                        if owner
                        else ["ios/Packages/LegadoKit/Sources/Other/**"]
                    ),
                },
                "active_decisions": ["ADR-0001"],
            },
        )
        golden_relative = (
            "ios/harness/goldens/android-legado-v1/fixture-001.json"
        )
        golden = b'{"result":"android"}'
        golden_path = root / golden_relative
        golden_path.parent.mkdir(parents=True, exist_ok=True)
        golden_path.write_bytes(golden)
        golden_sha = hashlib.sha256(golden).hexdigest()
        receipt_relative = (
            "ios/harness/goldens/releases/fixture-001-run.json"
        )
        fixture.fixture.write_json(
            receipt_relative,
            {
                "authority": "protected_android_golden",
                "authorization": "github_environment_review",
                "fixture_id": "fixture-001",
                "golden_path": golden_relative,
                "golden_sha256": golden_sha,
                "run_id": "42/1",
                "source_digest": "a" * 40,
                "proposal_sha256": "b" * 64,
            },
        )
        fixture.fixture.write_json(
            "ios/harness/goldens/manifest.json",
            {
                "schema_version": 1,
                "fixtures": {
                    "fixture-001": {
                        "path": golden_relative,
                        "golden_sha256": golden_sha,
                        "release_receipt": receipt_relative,
                        "run_id": "42/1",
                        "source_digest": "a" * 40,
                        "proposal_sha256": "b" * 64,
                    }
                },
            },
        )
        item = fixture.fixture.item(item_id, capability_id, 80)
        item["metadata"]["labels"] = ["product", "source-runtime"]
        item["spec"]["requirements"] = {
            "mode": "implementation",
            "refs": [
                {
                    "id": requirement_id,
                    "revision": 1,
                    "clauses": ["RC-01"],
                }
            ],
            "none_reason": None,
        }
        item["spec"]["acceptance"]["criteria"][0][
            "requirement_clauses"
        ] = [f"{requirement_id}#RC-01"]
        item["spec"]["architecture_refs"] = ["ADR-0001"]
        item["spec"]["completion_effects"] = {
            "health": {"delivery": "verified"}
        }
        item["spec"]["knowledge"] = {
            "contract_version": 1,
            "mode": "consume",
            "claim_refs": [{"id": "BKC-DELIVERY-001", "revision": 1}],
            "driver_refs": [],
            "coverage_refs": [
                {
                    "id": "BKL-DELIVERY-001",
                    "revision": 1,
                    "entries": ["BKE-DELIVERY-001"],
                }
            ],
            "produces": [],
            "expected_ledger_transitions": [],
            "context_budget": {"max_claims": 10, "max_bytes": 8192},
            "none_reason": None,
        }
        item["spec"]["acceptance"]["criteria"][0][
            "knowledge_claims"
        ] = [{"id": "BKC-DELIVERY-001", "revision": 1}]
        item["spec"]["delivery_blueprint"] = {
            "policy": loop_supervisor.DELIVERY_MATERIALIZATION_POLICY,
            "capability_revision": 3,
            "golden_fixtures": ["fixture-001"],
        }
        item["spec"]["scope"]["allow_write"] = [
            "ios/Packages/LegadoKit/Sources/SourceRuntime/**",
            "ios/Packages/LegadoKit/Tests/SourceRuntimeTests/**",
            f"ios/project/capabilities/{capability_id}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/pitfalls/PIT-*.json",
        ]
        item["spec"]["scope"]["deny_write"] = [
            ".github/**",
            "ios/Packages/LegadoKit/Package.swift",
            "ios/harness/goldens/**",
            "ios/harness/schemas/**",
            "ios/project/requirements/**",
            "ios/project/approvals/**",
            "ios/docs/**",
        ]
        blueprint_relative = (
            f"{loop_supervisor.DELIVERY_BLUEPRINT_ROOT}/{item_id}.json"
        )
        fixture.fixture.write_json(blueprint_relative, item)
        self.initialize_git(root)
        return fixture, root / blueprint_relative

    def test_bound_blueprint_materializes_with_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture, path = self.prepare(root)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                fixture.harness,
                "doctor",
                return_value=([], []),
            ):
                candidate = supervisor._delivery_candidate(path)
                self.assertEqual("IOS-DELIVERY-001", candidate.blueprint_id)
                self.assertEqual(
                    "protected_android_golden",
                    json.loads(
                        (
                            root
                            / "ios/harness/goldens/releases/fixture-001-run.json"
                        ).read_text()
                    )["authority"],
                )
                materialized = supervisor.auto_materialize_delivery(
                    candidate.blueprint_id
                )
            self.assertEqual("IOS-DELIVERY-001", materialized)
            event = fixture.harness.event_lines()[-1]
            provenance = event["payload"]["provenance"]
            self.assertEqual(
                loop_supervisor.DELIVERY_MATERIALIZATION_POLICY,
                provenance["policy"],
            )
            self.assertEqual(
                "fixture-001",
                provenance["goldens"][0]["fixture_id"],
            )

    def test_bound_blueprint_fails_closed_on_readiness_and_owner(self):
        for readiness, owner, reason in (
            (
                "characterization_required",
                True,
                "DELIVERY_REQUIREMENT_NOT_READY",
            ),
            (
                "implementation_ready",
                False,
                "DELIVERY_SCOPE_OUTSIDE_OWNER",
            ),
        ):
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture, path = self.prepare(
                    root,
                    readiness=readiness,
                    owner=owner,
                )
                supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
                with mock.patch.object(
                    fixture.harness,
                    "doctor",
                    return_value=([], []),
                ), self.assertRaisesRegex(
                    loop_supervisor.MaterializationConflict,
                    reason,
                ):
                    supervisor._delivery_candidate(path)
                self.assertFalse(
                    (
                        root
                        / "ios/harness/work-items/IOS-DELIVERY-001.json"
                    ).exists()
                )


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
        self.assertIn("preflight", help_text)
        self.assertIn("materialize-review", help_text)
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                parser.parse_args(["materialize", "candidate.json"])

    def test_preflight_cli_is_read_only(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            path, _ = fixture.candidate()
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                result = loop_supervisor.main(
                    ["--root", str(fixture.root), "preflight", str(path)]
                )
            self.assertEqual(0, result)
            payload = json.loads(stdout.getvalue())
            self.assertEqual("IOS-CANDIDATE-001", payload["work_item_id"])
            self.assertFalse(
                (fixture.root / "ios/harness/work-items/IOS-CANDIDATE-001.json").exists()
            )


class DriveTests(unittest.TestCase):
    @staticmethod
    def initialize_git(root):
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Loop Supervisor Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "loop@example.invalid"],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)

    @staticmethod
    def commit_all(root, message):
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)

    def test_drive_stops_before_agent_for_external_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(
                fixture.harness
            )
            config = fixture.root / "supervisor.json"
            config.write_text("{}\n")
            decision = loop_supervisor.LoopDecision(
                state="external_execution_required",
                reason_code=(
                    "TRUSTED_ORACLE_GITHUB_EXECUTION_REQUIRED"
                ),
                work_item_id=(
                    "IOS-ANDROID-POST-FORM-ATTESTATION-RECOVERY-003"
                ),
                requires_human=False,
                details={
                    "scenario_id": "sl-post-form-001",
                    "receipt": None,
                },
            )
            with mock.patch.object(
                supervisor,
                "inspect",
                return_value=decision,
            ), mock.patch.object(
                supervisor,
                "_invoke_agent_phase",
            ) as invoke:
                result = supervisor.drive(
                    config_path=config,
                    agent_id="test-agent",
                    max_transitions=1,
                )
            self.assertEqual(
                "trusted_oracle_github_execution_required",
                result["outcome"],
            )
            self.assertEqual([], result["transitions"])
            invoke.assert_not_called()

    def test_explicit_external_execution_uses_dispatcher_and_never_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            config = fixture.root / "supervisor.json"
            config.write_text(json.dumps({
                "external_execution": {
                    "github_oracle": {
                        "enabled": True,
                        "repository": "owner/legado",
                        "remote": "origin",
                    }
                }
            }))
            binding = {
                "workflow_path": (
                    ".github/workflows/android-oracle-attestation.yml"
                ),
                "scenario_id": "sl-post-form-001",
                "source_digest": "a" * 40,
            }
            decision = loop_supervisor.LoopDecision(
                state="external_execution_required",
                reason_code="TRUSTED_ORACLE_GITHUB_EXECUTION_REQUIRED",
                work_item_id="IOS-ANDROID-POST-FORM-ATTESTATION-RECOVERY-003",
                requires_human=False,
                details={"external_execution": binding},
            )
            dispatched = {
                "schema_version": 1, "outcome": "pending",
                "execution_id": "execution", "branch": "feature/oracle-test",
                "journal": ".harness-runtime/github-oracle/execution.json",
                "run": None,
            }
            with mock.patch.object(supervisor, "inspect",
                                   return_value=decision), \
                    mock.patch.object(supervisor, "_invoke_agent_phase") as invoke, \
                    mock.patch.object(
                        loop_supervisor.GitHubOracleDispatcher,
                        "dispatch", return_value=dispatched,
                    ) as dispatch:
                result = supervisor.drive(
                    config_path=config, agent_id="test-agent",
                    max_transitions=1,
                )
            self.assertEqual("pending", result["outcome"])
            self.assertEqual(dispatched, result["external_execution"])
            self.assertEqual([], result["transitions"])
            dispatch.assert_called_once_with()
            invoke.assert_not_called()

    @staticmethod
    def crash_drive(root, target, exit_code):
        source = textwrap.dedent(
            f"""
            import os
            import sys
            from pathlib import Path

            sys.path.insert(0, {str(HARNESS_DIR)!r})
            from harness import Harness
            from loop_supervisor import LoopSupervisor

            root = Path({str(root)!r})
            harness = Harness(root)
            supervisor = LoopSupervisor(harness)
            target = {target!r}
            if target == "verify":
                harness.verify = lambda item_id: os._exit({exit_code})
            elif target == "close":
                harness.close = lambda item_id: os._exit({exit_code})
            elif target == "journal_record":
                supervisor._journal_record_completion = (
                    lambda *args, **kwargs: os._exit({exit_code})
                )
            else:
                raise AssertionError(target)
            supervisor.drive(
                config_path=root / "supervisor.json",
                agent_id="crash-injection-agent",
                max_transitions=1,
            )
            """
        )
        return subprocess.run(
            [sys.executable, "-c", source],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )

    @staticmethod
    def process_exists(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

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
            self.initialize_git(root)
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

    def test_timeout_reclaims_child_and_grandchild_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            pid_file = root / "adapter-pids.txt"
            grandchild = (
                "import os,sys,time;"
                "open(sys.argv[1],'a').write(str(os.getpid())+'\\n');"
                "time.sleep(60)"
            )
            child = (
                "import os,subprocess,sys,time;"
                "open(sys.argv[1],'a').write(str(os.getpid())+'\\n');"
                f"subprocess.Popen([sys.executable,'-c',{grandchild!r},sys.argv[1]]);"
                "time.sleep(60)"
            )
            adapter = (
                "import os,subprocess,sys,time;"
                "open(sys.argv[1],'a').write(str(os.getpid())+'\\n');"
                f"subprocess.Popen([sys.executable,'-c',{child!r},sys.argv[1]]);"
                "time.sleep(60)"
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", adapter, str(pid_file)],
                        "timeout_seconds": 1,
                    }
                },
            )
            self.initialize_git(root)
            result = loop_supervisor.LoopSupervisor(fixture.harness).drive(
                config_path=root / "supervisor.json",
                agent_id="timeout-test",
                max_transitions=1,
            )
            self.assertEqual("agent_timeout", result["outcome"])
            transition = result["transitions"][0]
            self.assertTrue(transition["timed_out"])
            self.assertFalse(transition["process_leak"])
            self.assertIsNone(transition["cleanup_error"])
            pids = [int(value) for value in pid_file.read_text().splitlines()]
            self.assertEqual(3, len(pids))
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and any(
                self.process_exists(pid) for pid in pids
            ):
                time.sleep(0.02)
            self.assertEqual([], [pid for pid in pids if self.process_exists(pid)])

    def test_cleanup_permission_failure_is_structured(self):
        class TimeoutProcess:
            pid = 123
            returncode = -9

            def __init__(self):
                self.calls = 0

            def communicate(self, timeout=None):
                self.calls += 1
                if self.calls < 3:
                    raise subprocess.TimeoutExpired(
                        ["fake-agent"],
                        timeout,
                        output=b"partial",
                        stderr=b"",
                    )
                return b"", b""

        with tempfile.TemporaryDirectory() as directory:
            fixture = MaterializationFixture(Path(directory))
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with (
                mock.patch.object(
                    loop_supervisor.subprocess,
                    "Popen",
                    return_value=TimeoutProcess(),
                ),
                mock.patch.object(
                    supervisor,
                    "_signal_process_group",
                    side_effect=[
                        "sigterm_permission_denied",
                        "sigkill_permission_denied",
                    ],
                ),
                mock.patch.object(
                    supervisor,
                    "_process_group_exists",
                    return_value=False,
                ),
            ):
                transition = supervisor._run_agent_adapter(
                    item_id="IOS-BOOT-001",
                    argv=["fake-agent"],
                    environment={},
                    timeout_seconds=1,
                )
            self.assertTrue(transition["timed_out"])
            self.assertFalse(transition["process_leak"])
            self.assertEqual(
                "sigterm_permission_denied;sigkill_permission_denied",
                transition["cleanup_error"],
            )

    def test_process_crash_after_journal_replays_without_duplicate_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            count_path = root / ".harness-runtime/agent-count.txt"
            agent_source = textwrap.dedent(
                """
                from pathlib import Path

                path = Path(".harness-runtime/agent-count.txt")
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a", encoding="utf-8") as handle:
                    handle.write("implementation\\n")
                Path("ios/implementation.txt").write_text(
                    "implemented\\n",
                    encoding="utf-8",
                )
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", agent_source],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)

            crashed = self.crash_drive(root, "verify", 86)
            self.assertEqual(86, crashed.returncode, crashed.stderr)
            self.assertEqual(
                "implementing",
                fixture.harness.state()["work_items"]["IOS-BOOT-001"][
                    "status"
                ],
            )
            self.assertEqual(
                ["implementation"],
                count_path.read_text(encoding="utf-8").splitlines(),
            )

            resumed = loop_supervisor.LoopSupervisor(fixture.harness).drive(
                config_path=root / "supervisor.json",
                agent_id="fresh-supervisor",
                max_transitions=1,
            )
            self.assertEqual("transition_budget_reached", resumed["outcome"])
            self.assertEqual("verified", resumed["decision"]["state"], resumed)
            self.assertEqual(
                ["supervisor_replay", "supervisor_verification"],
                [transition["kind"] for transition in resumed["transitions"]],
            )
            self.assertEqual(
                ["implementation"],
                count_path.read_text(encoding="utf-8").splitlines(),
            )

    def test_process_crash_before_journal_reinvokes_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            count_path = root / ".harness-runtime/agent-count.txt"
            agent_source = textwrap.dedent(
                """
                from pathlib import Path

                path = Path(".harness-runtime/agent-count.txt")
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a", encoding="utf-8") as handle:
                    handle.write("implementation\\n")
                Path("ios/implementation.txt").write_text(
                    "implemented\\n",
                    encoding="utf-8",
                )
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", agent_source],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)

            crashed = self.crash_drive(root, "journal_record", 87)
            self.assertEqual(87, crashed.returncode, crashed.stderr)
            resumed = loop_supervisor.LoopSupervisor(fixture.harness).drive(
                config_path=root / "supervisor.json",
                agent_id="fresh-supervisor",
                max_transitions=1,
            )
            self.assertEqual("transition_budget_reached", resumed["outcome"])
            self.assertEqual("verified", resumed["decision"]["state"], resumed)
            self.assertEqual(
                ["agent", "supervisor_verification"],
                [transition["kind"] for transition in resumed["transitions"]],
            )
            self.assertEqual(
                ["implementation", "implementation"],
                count_path.read_text(encoding="utf-8").splitlines(),
            )

    def test_tampered_crash_journal_never_skips_agent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            count_path = root / ".harness-runtime/agent-count.txt"
            agent_source = textwrap.dedent(
                """
                from pathlib import Path

                path = Path(".harness-runtime/agent-count.txt")
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a", encoding="utf-8") as handle:
                    handle.write("implementation\\n")
                Path("ios/implementation.txt").write_text(
                    "implemented\\n",
                    encoding="utf-8",
                )
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", agent_source],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)
            crashed = self.crash_drive(root, "verify", 89)
            self.assertEqual(89, crashed.returncode, crashed.stderr)
            journal_path = (
                root
                / ".harness-runtime/loop-runs"
                / "ios-boot-001--attempt-1.json"
            )
            document = json.loads(journal_path.read_text(encoding="utf-8"))
            document["records"][0]["head_commit"] = "e" * 40
            journal_path.write_text(
                json.dumps(document) + "\n",
                encoding="utf-8",
            )

            resumed = loop_supervisor.LoopSupervisor(fixture.harness).drive(
                config_path=root / "supervisor.json",
                agent_id="fresh-supervisor",
                max_transitions=1,
            )
            self.assertEqual("agent", resumed["transitions"][0]["kind"])
            self.assertEqual(
                "invalid",
                resumed["transitions"][0]["journal_replay"]["status"],
            )
            self.assertEqual(
                ["implementation", "implementation"],
                count_path.read_text(encoding="utf-8").splitlines(),
            )

    def test_process_crash_after_memory_journal_resumes_directly_at_close(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            memory_count = root / ".harness-runtime/memory-count.txt"
            agent_source = textwrap.dedent(
                f"""
                import json
                import os
                from pathlib import Path

                root = Path({str(root)!r})
                context = json.loads(
                    Path(os.environ["LEGADO_CONTEXT_PATH"]).read_text(
                        encoding="utf-8"
                    )
                )
                control = context["supervisor_control"]
                item_id = context["work_item"]["metadata"]["id"]
                if control["phase"] == "implementation":
                    (root / "ios/implementation.txt").write_text(
                        "implemented\\n",
                        encoding="utf-8",
                    )
                elif control["phase"] == "memory_close":
                    count = root / ".harness-runtime/memory-count.txt"
                    count.parent.mkdir(parents=True, exist_ok=True)
                    with count.open("a", encoding="utf-8") as handle:
                        handle.write("memory\\n")
                    evidence_relative = control["latest_evidence"]
                    capability_path = (
                        root / "ios/project/capabilities/CAP-BOOT.json"
                    )
                    capability = json.loads(
                        capability_path.read_text(encoding="utf-8")
                    )
                    capability.update({{
                        "revision": 2,
                        "declared_status": "verified",
                        "latest_evidence": evidence_relative,
                        "updated_by": item_id,
                    }})
                    capability_path.write_text(
                        json.dumps(
                            capability,
                            ensure_ascii=False,
                            indent=2,
                        ) + "\\n",
                        encoding="utf-8",
                    )
                    checkpoint = {{
                        "schema_version": 1,
                        "work_item_id": item_id,
                        "summary": "memory crash replay",
                        "evidence": evidence_relative,
                        "capability_updates": [
                            {{
                                "id": "CAP-BOOT",
                                "from_revision": 1,
                                "to_revision": 2,
                            }}
                        ],
                        "architecture_impact": {{
                            "kind": "implements_existing",
                            "adr_refs": ["ADR-0001"],
                        }},
                        "requirements": {{
                            "mode": "control_plane",
                            "refs": [],
                            "selection_sha256": None,
                        }},
                        "source_lab": {{
                            "mode": "not_applicable",
                            "behaviors": [],
                            "scenarios": [],
                            "selection_sha256": None,
                        }},
                        "compatibility": {{
                            "records": [],
                            "none_reason": "unit test",
                        }},
                        "pitfalls": {{
                            "records": [],
                            "none_reason": "unit test",
                        }},
                        "remaining_risks": [],
                        "next_actions": [],
                        "created_at": "2026-01-01T00:00:00Z",
                    }}
                    checkpoint_path = (
                        root
                        / "ios/project/checkpoints"
                        / f"{{item_id}}.json"
                    )
                    checkpoint_path.parent.mkdir(
                        parents=True,
                        exist_ok=True,
                    )
                    checkpoint_path.write_text(
                        json.dumps(
                            checkpoint,
                            ensure_ascii=False,
                            indent=2,
                        ) + "\\n",
                        encoding="utf-8",
                    )
                else:
                    raise AssertionError(control)
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", agent_source],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            verified = supervisor.drive(
                config_path=root / "supervisor.json",
                agent_id="first-supervisor",
                max_transitions=1,
            )
            self.assertEqual("verified", verified["decision"]["state"])

            crashed = self.crash_drive(root, "close", 88)
            self.assertEqual(88, crashed.returncode, crashed.stderr)
            self.assertEqual(
                "verified",
                fixture.harness.state()["work_items"]["IOS-BOOT-001"][
                    "status"
                ],
            )
            self.assertEqual(
                ["memory"],
                memory_count.read_text(encoding="utf-8").splitlines(),
            )

            resumed = loop_supervisor.LoopSupervisor(fixture.harness).drive(
                config_path=root / "supervisor.json",
                agent_id="fresh-supervisor",
                max_transitions=1,
            )
            self.assertEqual(
                ["supervisor_replay", "supervisor_close"],
                [transition["kind"] for transition in resumed["transitions"]],
            )
            self.assertEqual(
                "completed",
                fixture.harness.state()["work_items"]["IOS-BOOT-001"][
                    "status"
                ],
            )
            self.assertEqual(
                ["memory"],
                memory_count.read_text(encoding="utf-8").splitlines(),
            )

    def test_supervisor_verification_retries_and_close_failure_is_structured(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            config_value = json.loads(
                (root / "ios/harness/config.json").read_text(encoding="utf-8")
            )
            config_value["checks"]["noop"]["argv"] = [
                sys.executable,
                "-c",
                "from pathlib import Path; assert Path('ios/fixed.txt').exists()",
            ]
            fixture.fixture.write_json("ios/harness/config.json", config_value)
            agent_source = textwrap.dedent(
                """
                import json
                import os
                from pathlib import Path

                context = json.loads(
                    Path(os.environ["LEGADO_CONTEXT_PATH"]).read_text(encoding="utf-8")
                )
                control = context["supervisor_control"]
                if (
                    control["phase"] == "implementation"
                    and control["verify_cycles"] >= 1
                ):
                    Path("ios/fixed.txt").write_text("fixed\\n", encoding="utf-8")
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", agent_source],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            result = supervisor.drive(
                config_path=root / "supervisor.json",
                agent_id="retry-agent",
                max_transitions=2,
            )
            self.assertEqual("transition_budget_reached", result["outcome"])
            self.assertEqual("verified", result["decision"]["state"])
            self.assertEqual(
                ["failed", "passed"],
                [
                    transition["result"]
                    for transition in result["transitions"]
                    if transition["kind"] == "supervisor_verification"
                ],
            )
            self.assertEqual(
                ["implementation", "implementation"],
                [
                    transition["phase"]
                    for transition in result["transitions"]
                    if transition["kind"] == "agent"
                ],
            )
            runtime = fixture.harness.state()["work_items"]["IOS-BOOT-001"]
            self.assertEqual(2, runtime["verify_cycles"])
            self.assertEqual("verified", runtime["status"])

            close_result = supervisor.drive(
                config_path=root / "supervisor.json",
                agent_id="retry-agent",
                max_transitions=1,
            )
            self.assertEqual("supervisor_close_failed", close_result["outcome"])
            self.assertEqual("verified", close_result["decision"]["state"])
            self.assertEqual("memory_close", close_result["transitions"][0]["phase"])
            self.assertEqual("failed", close_result["transitions"][1]["result"])
            self.assertIn(
                "close 前记忆事务无效",
                close_result["transitions"][1]["error"],
            )

    def test_supervisor_rejects_agent_control_plane_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            agent_source = textwrap.dedent(
                """
                import json
                from pathlib import Path

                path = Path("ios/project/state.json")
                state = json.loads(path.read_text(encoding="utf-8"))
                state["work_items"]["IOS-BOOT-001"]["verify_cycles"] = 99
                path.write_text(json.dumps(state, indent=2) + "\\n", encoding="utf-8")
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", agent_source],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)
            result = loop_supervisor.LoopSupervisor(fixture.harness).drive(
                config_path=root / "supervisor.json",
                agent_id="mutating-agent",
                max_transitions=1,
            )
            self.assertEqual("agent_control_plane_mutation", result["outcome"])
            self.assertEqual("agent", result["transitions"][0]["kind"])
            self.assertEqual(
                99,
                fixture.harness.state()["work_items"]["IOS-BOOT-001"][
                    "verify_cycles"
                ],
            )

    def test_scoped_knowledge_doctor_red_gets_repair_turn_before_verify(self):
        class RepairHarness:
            item_id = "IOS-REPAIR-001"

            def __init__(self, root):
                self.root = root
                self.marker = root / "candidate.valid"
                self.evidence = root / "evidence.json"
                self.item = {
                    "metadata": {"id": self.item_id, "priority": 100},
                    "spec": {
                        "capability": "CAP-REPAIR",
                        "depends_on": [],
                        "inputs": {
                            "context_files": ["contract.json"],
                            "android_source_anchors": [],
                        },
                        "knowledge": {
                            "produces": [
                                {
                                    "kind": "packet",
                                    "id": "BKP-REPAIR-001",
                                    "revision": 1,
                                }
                            ]
                        },
                    },
                }
                self.state_value = {
                    "event_head": "event-head",
                    "active_work_items": [self.item_id],
                    "work_items": {
                        self.item_id: {
                            "status": "implementing",
                            "attempt": 1,
                            "verify_cycles": 0,
                            "last_evidence": None,
                            "last_evidence_sha256": None,
                        }
                    },
                }

            def doctor(self):
                if self.marker.exists():
                    return [], []
                return ["Business Knowledge control 无效：bad proposal graph"], []

            def state(self):
                return self.state_value

            def work_items(self):
                return {self.item_id: self.item}

            def event_lines(self):
                return []

            def changed_since_claim(self, runtime):
                return ["candidate.invalid"]

            def scope_issues(self, item, runtime, changed):
                return [], [], 1

            def context_packet(self, item_id):
                raise harness_module.HarnessError("knowledge graph unavailable")

            def capability(self, capability_id):
                return {"id": capability_id, "revision": 1}

            def mutation_lock(self):
                return contextlib.nullcontext()

            def verify(self, item_id):
                self.evidence.write_text(
                    json.dumps(
                        {
                            "result": "passed",
                            "failure": None,
                        }
                    ),
                    encoding="utf-8",
                )
                runtime = self.state_value["work_items"][item_id]
                runtime["status"] = "verified"
                runtime["verify_cycles"] = 1
                runtime["last_evidence"] = "evidence.json"
                return self.evidence

            def relative(self, path):
                return path.relative_to(self.root).as_posix()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = RepairHarness(root)
            agent_source = textwrap.dedent(
                """
                import json
                import os
                from pathlib import Path

                context = json.loads(
                    Path(os.environ["LEGADO_CONTEXT_PATH"]).read_text(encoding="utf-8")
                )
                assert context["repair_context"]["reason_code"] == (
                    "ACTIVE_KNOWLEDGE_CANDIDATE_INVALID"
                )
                assert context["supervisor_control"]["repair"]["doctor_errors"]
                Path("candidate.valid").write_text("fixed\\n", encoding="utf-8")
                """
            )
            config = root / "supervisor.json"
            config.write_text(
                json.dumps(
                    {
                        "agent_invocation": {
                            "argv": [sys.executable, "-c", agent_source],
                            "timeout_seconds": 10,
                        },
                        "trusted_verification": {
                            "enabled": True,
                            "policy": (
                                loop_supervisor.SUPERVISOR_VERIFICATION_POLICY
                            ),
                        },
                    }
                ),
                encoding="utf-8",
            )
            result = loop_supervisor.LoopSupervisor(harness).drive(
                config_path=config,
                agent_id="repair-agent",
                max_transitions=2,
            )
            self.assertEqual("transition_budget_reached", result["outcome"])
            self.assertEqual("verified", result["decision"]["state"])
            self.assertTrue(result["transitions"][0]["repair"])
            self.assertEqual(
                ["agent", "supervisor_verification"],
                [transition["kind"] for transition in result["transitions"]],
            )
            self.assertTrue(harness.marker.exists())

    def test_active_control_catalog_stale_resumes_without_repeating_agent(self):
        class ControlCatalogHarness:
            item_id = "IOS-CONTROL-RESUME-001"

            def __init__(self, root):
                self.root = root
                self.root.mkdir(parents=True, exist_ok=True)
                self.catalog = root / "catalog.json"
                self.catalog.write_text('{"stale":true}\n', encoding="utf-8")
                self.business_knowledge_catalog_path = self.catalog
                self.refreshed = False
                self.verify_calls = 0
                self.item = {
                    "metadata": {
                        "id": self.item_id,
                        "priority": 100,
                        "labels": ["control-plane", "corrective"],
                    },
                    "spec": {
                        "capability": "CAP-CONTROL",
                        "depends_on": [],
                        "requirements": {"mode": "control_plane"},
                        "knowledge": {
                            "mode": "not_applicable",
                            "produces": [],
                        },
                    },
                }
                self.state_value = {
                    "event_head": "event-head",
                    "active_work_items": [self.item_id],
                    "work_items": {
                        self.item_id: {
                            "status": "implementing",
                            "attempt": 1,
                            "verify_cycles": 0,
                            "last_evidence": None,
                            "last_evidence_sha256": None,
                        }
                    },
                }
                self.evidence = root / "evidence.json"
                self.extra_error = None
                self.changed = ["ios/harness/harness.py"]
                self.policy_errors = []

            def business_knowledge_enabled(self):
                return True

            def doctor(self):
                if self.refreshed:
                    return [], []
                errors = [
                    "Business Knowledge control 无效："
                    + loop_supervisor.BUSINESS_KNOWLEDGE_CATALOG_STALE,
                    "IOS-CONTROL-RESUME-001: Business Knowledge selection 无效："
                    + loop_supervisor.BUSINESS_KNOWLEDGE_CATALOG_STALE,
                ]
                if self.extra_error is not None:
                    errors.append(self.extra_error)
                return errors, []

            def state(self):
                return self.state_value

            def work_items(self):
                return {self.item_id: self.item}

            def changed_since_claim(self, runtime):
                return list(self.changed)

            def scope_issues(self, item, runtime, changed):
                return list(self.policy_errors), [], len(changed)

            def mutation_lock(self):
                return contextlib.nullcontext()

            def refresh_business_knowledge_catalog(self):
                self.catalog.write_text(
                    '{"stale":false}\n',
                    encoding="utf-8",
                )
                self.refreshed = True

            def verify(self, item_id):
                self.verify_calls += 1
                self.evidence.write_text(
                    json.dumps({"result": "passed", "failure": None}),
                    encoding="utf-8",
                )
                runtime = self.state_value["work_items"][item_id]
                runtime["status"] = "verified"
                runtime["verify_cycles"] = 1
                runtime["last_evidence"] = "evidence.json"
                return self.evidence

            def relative(self, path):
                return path.relative_to(self.root).as_posix()

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = ControlCatalogHarness(root)
            config = root / "supervisor.json"
            config.write_text(
                json.dumps(
                    {
                        "agent_invocation": {
                            "argv": [
                                sys.executable,
                                "-c",
                                "raise SystemExit(99)",
                            ],
                            "timeout_seconds": 10,
                        },
                        "trusted_verification": {
                            "enabled": True,
                            "policy": (
                                loop_supervisor.SUPERVISOR_VERIFICATION_POLICY
                            ),
                        },
                    }
                ),
                encoding="utf-8",
            )
            supervisor = loop_supervisor.LoopSupervisor(harness)
            result = supervisor.drive(
                config_path=config,
                agent_id="must-not-run",
                max_transitions=1,
            )
            self.assertEqual("transition_budget_reached", result["outcome"])
            self.assertEqual("verified", result["decision"]["state"])
            self.assertEqual(1, harness.verify_calls)
            self.assertEqual(
                [
                    "supervisor_catalog_refresh",
                    "supervisor_verification",
                ],
                [transition["kind"] for transition in result["transitions"]],
            )
            refresh = result["transitions"][0]
            self.assertEqual("refreshed", refresh["result"])
            self.assertNotEqual(
                refresh["catalog_before_sha256"],
                refresh["catalog_after_sha256"],
            )

            blocked = ControlCatalogHarness(root / "blocked")
            blocked.extra_error = "Business Knowledge 图无效：claim cycle"
            self.assertIsNone(
                loop_supervisor.LoopSupervisor(
                    blocked
                )._refreshable_control_catalog(
                    loop_supervisor.LoopSupervisor(blocked).inspect()
                )
            )
            blocked.extra_error = None
            blocked.changed = ["ios/harness/loop_supervisor.py"]
            self.assertIsNone(
                loop_supervisor.LoopSupervisor(
                    blocked
                )._refreshable_control_catalog(
                    loop_supervisor.LoopSupervisor(blocked).inspect()
                )
            )
            blocked.changed = ["ios/harness/harness.py"]
            blocked.policy_errors = ["scope denied"]
            self.assertIsNone(
                loop_supervisor.LoopSupervisor(
                    blocked
                )._refreshable_control_catalog(
                    loop_supervisor.LoopSupervisor(blocked).inspect()
                )
            )

            failed = ControlCatalogHarness(root / "failed")

            def fail_refresh():
                raise harness_module.HarnessError("catalog refresh failed")

            failed.refresh_business_knowledge_catalog = fail_refresh
            failure = loop_supervisor.LoopSupervisor(failed).drive(
                config_path=config,
                agent_id="must-not-run",
                max_transitions=1,
            )
            self.assertEqual(
                "supervisor_catalog_refresh_failed",
                failure["outcome"],
            )

            mutated = ControlCatalogHarness(root / "mutated")

            def mutate_control():
                mutated.catalog.write_text(
                    '{"stale":false}\n',
                    encoding="utf-8",
                )
                mutated.refreshed = True
                mutated.state_value["event_head"] = "changed-event-head"

            mutated.refresh_business_knowledge_catalog = mutate_control
            mutation = loop_supervisor.LoopSupervisor(mutated).drive(
                config_path=config,
                agent_id="must-not-run",
                max_transitions=1,
            )
            self.assertEqual(
                "supervisor_catalog_control_mutation",
                mutation["outcome"],
            )

            unrecovered = ControlCatalogHarness(root / "unrecovered")

            def leave_doctor_red():
                unrecovered.catalog.write_text(
                    '{"stale":false}\n',
                    encoding="utf-8",
                )

            unrecovered.refresh_business_knowledge_catalog = leave_doctor_red
            not_recovered = loop_supervisor.LoopSupervisor(unrecovered).drive(
                config_path=config,
                agent_id="must-not-run",
                max_transitions=1,
            )
            self.assertEqual(
                "supervisor_catalog_refresh_not_recovered",
                not_recovered["outcome"],
            )

    def test_pre_evidence_verification_error_is_structured(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [sys.executable, "-c", "pass"],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)
            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            with mock.patch.object(
                fixture.harness,
                "verify",
                side_effect=harness_module.HarnessError(
                    "Business Knowledge graph unavailable"
                ),
            ):
                result = supervisor.drive(
                    config_path=root / "supervisor.json",
                    agent_id="verification-error-agent",
                    max_transitions=1,
                )
            self.assertEqual("supervisor_verification_error", result["outcome"])
            self.assertEqual(
                "error_before_evidence",
                result["transitions"][1]["result"],
            )
            self.assertIn(
                "Business Knowledge graph unavailable",
                result["transitions"][1]["error"],
            )

    def test_real_harness_e2e_materialize_drive_verify_close_and_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = MaterializationFixture(root)
            state = fixture.harness.state()
            for runtime in state["work_items"].values():
                runtime["status"] = "superseded"
            fixture.fixture.write_json("ios/project/state.json", state)
            fixture.refresh_status()

            item_id = "IOS-LOOP-E2E-001"
            candidate = fixture.fixture.item(item_id, "CAP-BOOT", 100)
            candidate["spec"]["scope"].update(
                {
                    "allow_write": [
                        "ios/implementation.txt",
                        "ios/project/capabilities/CAP-BOOT.json",
                        f"ios/project/checkpoints/{item_id}.json",
                    ],
                    "max_files_changed": 3,
                    "max_changed_lines": 100,
                }
            )
            candidate["spec"]["completion_effects"] = {
                "health": {"loop_engine": "local_mature"}
            }
            candidate_path = fixture.candidate_root / f"{item_id}.json"
            fixture.fixture.write_json(
                str(candidate_path.relative_to(root)),
                candidate,
            )
            agent_source = textwrap.dedent(
                f"""
                import json
                import os
                from pathlib import Path

                root = Path({str(root)!r})
                context_path = Path(os.environ["LEGADO_CONTEXT_PATH"])
                assert os.environ["LEGADO_CONTEXT_PATH"] == str(context_path)
                context = json.loads(context_path.read_text(encoding="utf-8"))
                item_id = os.environ["LEGADO_WORK_ITEM_ID"]
                assert context["work_item"]["metadata"]["id"] == item_id
                assert context["work_item_sha256"]
                control = context["supervisor_control"]
                assert control["policy"] == {loop_supervisor.SUPERVISOR_VERIFICATION_POLICY!r}
                assert os.environ["LEGADO_SUPERVISOR_PHASE"] == control["phase"]
                if control["phase"] == "implementation":
                    assert control["latest_evidence"] is None
                    (root / "ios/implementation.txt").write_text(
                        "implemented by argv adapter\\n",
                        encoding="utf-8",
                    )
                elif control["phase"] == "memory_close":
                    evidence_relative = control["latest_evidence"]
                    evidence = json.loads(
                        (root / evidence_relative).read_text(encoding="utf-8")
                    )
                    assert evidence["result"] == "passed"
                    capability_path = root / "ios/project/capabilities/CAP-BOOT.json"
                    capability = json.loads(
                        capability_path.read_text(encoding="utf-8")
                    )
                    capability.update({{
                        "revision": 2,
                        "declared_status": "verified",
                        "latest_evidence": evidence_relative,
                        "updated_by": item_id,
                    }})
                    capability_path.write_text(
                        json.dumps(capability, ensure_ascii=False, indent=2) + "\\n",
                        encoding="utf-8",
                    )
                    checkpoint = {{
                        "schema_version": 1,
                        "work_item_id": item_id,
                        "summary": "Supervisor-owned verify/close 完成 Harness 闭环",
                        "evidence": evidence_relative,
                        "capability_updates": [
                            {{"id": "CAP-BOOT", "from_revision": 1, "to_revision": 2}}
                        ],
                        "architecture_impact": {{
                            "kind": "implements_existing",
                            "adr_refs": ["ADR-0001"],
                        }},
                        "requirements": {{
                            "mode": "control_plane",
                            "refs": [],
                            "selection_sha256": None,
                        }},
                        "source_lab": {{
                            "mode": "not_applicable",
                            "behaviors": [],
                            "scenarios": [],
                            "selection_sha256": None,
                        }},
                        "compatibility": {{
                            "records": [],
                            "none_reason": "测试不涉及跨端差异",
                        }},
                        "pitfalls": {{
                            "records": [],
                            "none_reason": "测试未发现长期陷阱",
                        }},
                        "remaining_risks": [],
                        "next_actions": [],
                        "created_at": "2026-01-01T00:00:00Z",
                    }}
                    checkpoint_path = (
                        root / "ios/project/checkpoints" / f"{{item_id}}.json"
                    )
                    checkpoint_path.parent.mkdir(parents=True, exist_ok=True)
                    checkpoint_path.write_text(
                        json.dumps(checkpoint, ensure_ascii=False, indent=2) + "\\n",
                        encoding="utf-8",
                    )
                else:
                    raise AssertionError(control)
                """
            )
            fixture.fixture.write_json(
                "supervisor.json",
                {
                    "agent_invocation": {
                        "argv": [
                            sys.executable,
                            "-c",
                            agent_source,
                            "{repo_root}",
                            "{context_path}",
                        ],
                        "timeout_seconds": 10,
                    },
                    "trusted_verification": {
                        "enabled": True,
                        "policy": loop_supervisor.SUPERVISOR_VERIFICATION_POLICY,
                    },
                },
            )
            self.initialize_git(root)

            supervisor = loop_supervisor.LoopSupervisor(fixture.harness)
            preview = supervisor.preflight_candidate(candidate_path)
            self.assertEqual(item_id, supervisor.materialize(preview, reason="e2e"))
            self.assertEqual(
                "ready",
                fixture.harness.state()["work_items"][item_id]["status"],
            )
            self.commit_all(root, "materialized")

            result = supervisor.drive(
                config_path=root / "supervisor.json",
                agent_id="e2e-agent",
                max_transitions=3,
            )
            self.assertEqual(
                "no_eligible_compiled_candidate",
                result["outcome"],
            )
            self.assertEqual("queue_empty", result["decision"]["state"])
            transition = result["transitions"][0]
            self.assertEqual("agent", transition["kind"])
            self.assertEqual("implementation", transition["phase"])
            self.assertEqual(0, transition["exit_code"])
            self.assertFalse(transition["timed_out"])
            self.assertFalse(transition["process_leak"])
            self.assertIsNone(transition["cleanup_error"])
            self.assertEqual(
                [
                    "agent",
                    "supervisor_verification",
                    "agent",
                    "supervisor_close",
                ],
                [entry["kind"] for entry in result["transitions"]],
            )
            self.assertEqual(
                "memory_close",
                result["transitions"][2]["phase"],
            )
            self.assertEqual(
                "passed",
                result["transitions"][1]["result"],
            )
            self.assertEqual(
                "completed",
                result["transitions"][3]["result"],
            )

            final_state = fixture.harness.state()
            self.assertEqual(
                "completed",
                final_state["work_items"][item_id]["status"],
            )
            self.assertEqual("local_mature", final_state["health"]["loop_engine"])
            self.assertEqual([], final_state["active_work_items"])
            events = fixture.harness.event_lines()
            item_events = [
                event["event"]
                for event in events
                if event.get("work_item_id") == item_id
            ]
            self.assertEqual(
                [
                    "WorkItemMaterialized",
                    "WorkItemClaimed",
                    "VerificationPassed",
                    "WorkItemCompleted",
                ],
                item_events,
            )
            self.assertEqual(events[-1]["event_hash"], final_state["event_head"])
            evidence_path = root / final_state["work_items"][item_id]["last_evidence"]
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
            self.assertEqual("passed", evidence["result"])
            self.assertEqual(
                candidate["metadata"]["id"],
                evidence["work_item_id"],
            )
            checkpoint = json.loads(
                (
                    root
                    / "ios/project/checkpoints"
                    / f"{item_id}.json"
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(evidence_path.relative_to(root).as_posix(), checkpoint["evidence"])
            self.assertIn(
                f"| {item_id} | 100 | `completed` |",
                (root / "ios/project/status.md").read_text(encoding="utf-8"),
            )
            errors, _ = fixture.harness.doctor()
            self.assertEqual([], errors)


if __name__ == "__main__":
    unittest.main()
