import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HARNESS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_DIR))

import harness as harness_module  # noqa: E402


class HarnessFixture:
    def __init__(self, root: Path):
        self.root = root
        shutil.copytree(HARNESS_DIR / "schemas", self.root / "ios/harness/schemas")
        self.write_json(
            "ios/harness/config.json",
            {
                "schema_version": 1,
                "state_path": "ios/project/state.json",
                "events_path": "ios/project/events.jsonl",
                "baseline_path": "ios/project/baseline.json",
                "status_path": "ios/project/status.md",
                "capabilities_dir": "ios/project/capabilities",
                "checkpoints_dir": "ios/project/checkpoints",
                "approvals_dir": "ios/project/approvals",
                "work_items_dir": "ios/harness/work-items",
                "evidence_dir": "ios/harness/evidence/runs",
                "architecture_rules_path": "ios/harness/architecture-rules.json",
                "architecture_sources": [
                    "ios/docs/architecture.md",
                    "ios/docs/dependencies.md",
                ],
                "golden_manifest_path": "ios/harness/goldens/manifest.json",
                "fixture_manifest_path": "ios/harness/fixtures/manifest.json",
                "max_parallel_work_items": 1,
                "evidence_output_tail_bytes": 1000,
                "redaction_patterns": [
                    {
                        "pattern": "(?i)(authorization\\s*[:=]\\s*)([^\\r\\n]+)",
                        "replacement": "\\1<redacted>",
                    }
                ],
                "harness_managed_paths": [
                    "ios/project/state.json",
                    "ios/project/status.md",
                    "ios/project/events.jsonl",
                    "ios/harness/evidence/runs/**",
                    "ios/harness/fixtures/manifest.json",
                ],
                "protected_paths": ["ios/harness/goldens/**"],
                "checks": {
                    "noop": {
                        "argv": ["python3", "-c", "print('ok')"],
                        "cwd": ".",
                        "timeout_seconds": 10,
                    }
                },
            },
        )
        self.write_json(
            "ios/harness/architecture-rules.json",
            {
                "schema_version": 1,
                "source_root": "ios/Packages/LegadoKit/Sources",
                "known_project_modules": ["LegadoCore"],
                "known_external_modules": [],
                "targets": {
                    "LegadoCore": {
                        "dependencies": [],
                        "external_imports": [],
                        "forbidden_imports": ["SwiftUI"],
                    }
                },
                "test_targets": {},
                "banned_patterns": [],
                "profiles": {},
            },
        )
        self.write_json(
            "ios/project/baseline.json",
            {
                "schema_version": 1,
                "android_oracle": {"git_commit": "abc"},
                "accepted_by": ["ADR-0001"],
                "architecture": {"version": "1", "digest": None},
            },
        )
        self.write_json(
            "ios/harness/goldens/manifest.json",
            {"schema_version": 1, "oracle": {"android_git_commit": "abc"}},
        )
        self.write_json(
            "ios/harness/fixtures/manifest.json",
            {
                "schema_version": 1,
                "compatibility_profile": "android-legado-v1",
                "canonicalizer": "canonical-v1",
                "fixtures": [],
            },
        )
        self.write_text("ios/docs/architecture.md", "ARCH-001\n")
        self.write_text("ios/docs/dependencies.md", "# Dependencies\n")
        self.write_text("ios/docs/adr/0001-test.md", "id: ADR-0001\nstatus: accepted\n")

    def write_json(self, relative: str, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def write_text(self, relative: str, value: str):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="utf-8")

    @staticmethod
    def item(item_id: str, capability: str, priority: int, depends_on=None):
        return {
            "api_version": "legado.harness/v1",
            "kind": "WorkItem",
            "metadata": {
                "id": item_id,
                "title": item_id,
                "priority": priority,
                "risk": "low",
                "labels": ["test"],
            },
            "spec": {
                "capability": capability,
                "intent": "test",
                "depends_on": depends_on or [],
                "scope": {
                    "allow_write": ["ios/**"],
                    "deny_write": [],
                    "max_files_changed": 10,
                    "max_changed_lines": 100,
                },
                "inputs": {
                    "context_files": ["ios/docs/architecture.md"],
                    "android_source_anchors": [],
                    "fixtures": [],
                },
                "architecture_refs": ["ARCH-001", "ADR-0001"],
                "acceptance": {
                    "criteria": [{"id": "AC-1", "statement": "test", "verified_by": ["noop"], "requirement_clauses": []}],
                    "required_checks": ["noop"],
                },
                "baseline_checks": [],
                "budget": {"max_edit_verify_cycles": 3},
                "gates": [],
                "completion_effects": {},
                "memory": {"capability_state_required": True},
                "requirements": {
                    "mode": "control_plane",
                    "refs": [],
                    "none_reason": "isolated Harness unit test",
                },
                "source_lab": {
                    "mode": "not_applicable",
                    "behaviors": [],
                    "scenarios": [],
                    "none_reason": "unit test work item does not exercise source behavior",
                },
                "stop_on": ["failure"],
            },
        }

    def initialize(self):
        harness = harness_module.Harness(self.root)
        architecture_digest = harness.architecture_digest()
        baseline = harness_module.load_json(self.root / "ios/project/baseline.json")
        baseline["architecture"]["digest"] = architecture_digest
        self.write_json("ios/project/baseline.json", baseline)
        first = self.item("IOS-BOOT-001", "CAP-BOOT", 100)
        second = self.item("IOS-CORE-001", "CAP-CORE", 90, ["IOS-BOOT-001"])
        self.write_json("ios/harness/work-items/IOS-BOOT-001.json", first)
        self.write_json("ios/harness/work-items/IOS-CORE-001.json", second)
        for capability in ("CAP-BOOT", "CAP-CORE"):
            self.write_json(
                f"ios/project/capabilities/{capability}.json",
                {
                    "schema_version": 1,
                    "id": capability,
                    "revision": 1,
                    "title": capability,
                    "area": "test",
                    "contract": "ios/docs/architecture.md",
                    "requirement_refs": [
                        {"id": "REQ-TEST-001", "revision": 1, "clauses": ["RC-01"]}
                    ],
                    "declared_status": "proposed",
                    "profiles": {},
                    "owners": {"targets": [], "paths": []},
                    "depends_on": [],
                    "active_decisions": ["ADR-0001"],
                    "open_compatibility": [],
                    "open_pitfalls": [],
                    "blockers": [],
                    "required_evidence": ["noop"],
                    "freshness_inputs": [
                        "baseline_sha256",
                        "architecture_digest_sha256",
                        "architecture_rules_sha256",
                        "harness_config_sha256",
                        "dependency_lock_sha256",
                    ],
                    "latest_evidence": None,
                    "next_actions": [],
                    "updated_at": "2026-01-01T00:00:00Z",
                    "updated_by": "initialization",
                },
            )
        state = {
            "schema_version": 1,
            "revision": 1,
            "project": "test",
            "phase": "test",
            "architecture_version": "1",
            "architecture_digest": architecture_digest,
            "updated_at": "2026-01-01T00:00:00Z",
            "event_head": None,
            "active_work_items": [],
            "last_completed_work_item": None,
            "work_items": {
                "IOS-BOOT-001": {"status": "ready", "attempt": 0, "last_evidence": None},
                "IOS-CORE-001": {"status": "ready", "attempt": 0, "last_evidence": None},
            },
            "health": {},
            "risks": [],
        }
        self.write_json("ios/project/state.json", state)
        event = {
            "sequence": 1,
            "event": "ProjectInitialized",
            "work_item_id": None,
            "occurred_at": "2026-01-01T00:00:00Z",
            "previous_event_hash": None,
            "payload": {},
        }
        event["event_hash"] = harness_module.Harness.event_hash(event)
        self.write_text(
            "ios/project/events.jsonl",
            json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
        )
        state["event_head"] = event["event_hash"]
        self.write_json("ios/project/state.json", state)
        harness = harness_module.Harness(self.root)
        self.write_text("ios/project/status.md", harness.render_status(state, harness.work_items()))
        return harness


class HarnessTests(unittest.TestCase):
    @staticmethod
    def initialize_git(root: Path):
        subprocess.run(["git", "init", "-q"], cwd=str(root), check=True)
        subprocess.run(["git", "config", "user.name", "Harness Test"], cwd=str(root), check=True)
        subprocess.run(["git", "config", "user.email", "harness@example.invalid"], cwd=str(root), check=True)
        subprocess.run(["git", "add", "."], cwd=str(root), check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=str(root), check=True)

    @staticmethod
    def enable_business_knowledge(fixture: HarnessFixture):
        root = fixture.root
        shutil.copytree(
            HARNESS_DIR / "business-knowledge",
            root / "ios/harness/business-knowledge",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        baseline = harness_module.load_json(root / "ios/project/baseline.json")
        baseline["android_oracle"]["git_commit"] = "a" * 40
        fixture.write_json("ios/project/baseline.json", baseline)
        golden = harness_module.load_json(root / "ios/harness/goldens/manifest.json")
        golden["oracle"]["android_git_commit"] = "a" * 40
        fixture.write_json("ios/harness/goldens/manifest.json", golden)
        fixture.write_json(
            "ios/project/android-intake/inventory-manifest.json",
            {"control_sha256": "b" * 64, "facts": []},
        )
        fixture.write_json(
            "ios/project/requirements/catalog.json",
            {"schema_version": 1, "requirements": []},
        )
        for path in (root / "ios/harness/work-items").glob("*.json"):
            item = harness_module.load_json(path)
            item["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "not_applicable",
                "claim_refs": [],
                "driver_refs": [],
                "coverage_refs": [],
                "produces": [],
                "expected_ledger_transitions": [],
                "context_budget": {"max_claims": 40, "max_bytes": 65536},
                "none_reason": "isolated Harness unit test",
            }
            item["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = []
            fixture.write_json(f"ios/harness/work-items/{path.name}", item)
        harness = harness_module.Harness(root)
        harness.refresh_business_knowledge_catalog()
        return harness

    def test_doctor_and_dependency_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            errors, warnings = harness.doctor()
            self.assertEqual([], errors)
            self.assertTrue(any("source root" in warning for warning in warnings))
            self.assertEqual("IOS-BOOT-001", harness.select_next(harness.state(), harness.work_items()))

            state = harness.state()
            state["work_items"]["IOS-BOOT-001"]["status"] = "completed"
            self.assertEqual("IOS-CORE-001", harness.select_next(state, harness.work_items()))

    def test_recovers_contract_rejects_invalid_edges(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            item = fixture.item("IOS-RECOVERY-001", "CAP-BOOT", 100)

            item["spec"]["recovers"] = "not-a-work-item"
            errors = harness.validate_work_item(item, "IOS-RECOVERY-001")
            self.assertTrue(any("recovers 必须" in error for error in errors), errors)

            item["spec"]["recovers"] = "IOS-RECOVERY-001"
            errors = harness.validate_work_item(item, "IOS-RECOVERY-001")
            self.assertTrue(any("不得自引用" in error for error in errors), errors)

            item["spec"]["recovers"] = "IOS-BOOT-001"
            item["spec"]["depends_on"] = ["IOS-BOOT-001"]
            errors = harness.validate_work_item(item, "IOS-RECOVERY-001")
            self.assertTrue(
                any("不得同时出现在 depends_on" in error for error in errors),
                errors,
            )

            item["spec"]["depends_on"] = []
            items = harness.work_items()
            items["IOS-RECOVERY-001"] = item
            errors = harness.validate_references(items)
            self.assertEqual([], [
                error
                for error in errors
                if "recovers" in error or "恢复成环" in error
            ])

            item["spec"]["recovers"] = "IOS-CORE-001"
            errors = harness.validate_references(items)
            self.assertTrue(
                any("recovers capability 不一致" in error for error in errors),
                errors,
            )

            item["spec"]["recovers"] = "IOS-MISSING-001"
            errors = harness.validate_references(items)
            self.assertTrue(any("recovers 不存在" in error for error in errors), errors)

            item["spec"]["recovers"] = "IOS-BOOT-001"
            state = harness.state()
            state["work_items"]["IOS-RECOVERY-001"] = {
                "status": "verified",
            }
            issues = harness.recovery_binding_issues(
                "IOS-RECOVERY-001",
                item,
                items,
                state,
            )
            self.assertTrue(any("可恢复终态" in issue for issue in issues), issues)

            state["work_items"]["IOS-BOOT-001"] = {
                "status": "blocked",
                "replacement": "IOS-OTHER-001",
            }
            issues = harness.recovery_binding_issues(
                "IOS-RECOVERY-001",
                item,
                items,
                state,
            )
            self.assertTrue(any("不同 replacement" in issue for issue in issues), issues)

            state["work_items"]["IOS-BOOT-001"] = {"status": "blocked"}
            state["work_items"]["IOS-RECOVERY-001"]["replacement"] = "IOS-BOOT-001"
            issues = harness.recovery_binding_issues(
                "IOS-RECOVERY-001",
                item,
                items,
                state,
            )
            self.assertTrue(any("会成环" in issue for issue in issues), issues)

            items["IOS-BOOT-001"]["spec"]["recovers"] = "IOS-RECOVERY-001"
            errors = harness.validate_references(items)
            self.assertTrue(any("工作项恢复成环" in error for error in errors), errors)

    def test_promoted_knowledge_context_requires_exact_release_lineage(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            item_id = "IOS-KNOWLEDGE-TEST-001"
            packet_id = "BKP-TEST-DOMAIN-001"
            proposal = (
                "ios/project/business-knowledge/packets/proposals/"
                f"{packet_id}/r0001.json"
            )
            published = (
                "ios/project/business-knowledge/packets/published/"
                f"{packet_id}/r0001.json"
            )
            producer = fixture.item(item_id, "CAP-BOOT", 80)
            producer["spec"]["inputs"]["context_files"] = [proposal]
            producer["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "produce",
                "claim_refs": [],
                "driver_refs": [],
                "coverage_refs": [],
                "produces": [
                    {
                        "kind": "packet",
                        "id": packet_id,
                        "revision": 1,
                    }
                ],
                "expected_ledger_transitions": [],
                "context_budget": {
                    "max_claims": 10,
                    "max_bytes": 10000,
                },
                "none_reason": None,
            }
            fixture.write_json(
                f"ios/harness/work-items/{item_id}.json",
                producer,
            )
            items = harness.work_items()
            state = harness.state()

            proposal_sha = "a" * 64
            evidence_relative = (
                "ios/harness/evidence/runs/run-promoted-context.json"
            )
            evidence = {
                "schema_version": 1,
                "work_item_id": item_id,
                "result": "passed",
                "changes": {
                    "file_fingerprints": {
                        proposal: f"file:0o644:{proposal_sha}"
                    }
                },
            }
            fixture.write_json(evidence_relative, evidence)
            evidence_sha = harness_module.sha256_bytes(
                (fixture.root / evidence_relative).read_bytes()
            )
            state["work_items"][item_id] = {
                "status": "completed",
                "last_evidence": evidence_relative,
                "last_evidence_sha256": evidence_sha,
            }
            fixture.write_json(
                published,
                {
                    "schema_version": 1,
                    "id": packet_id,
                    "revision": 1,
                    "status": "published",
                    "created_by": item_id,
                },
            )
            published_sha = harness_module.sha256_bytes(
                (fixture.root / published).read_bytes()
            )
            receipt_relative = (
                "ios/project/business-knowledge/releases/"
                f"{packet_id}-r0001-123-1.json"
            )
            receipt = {
                "schema_version": 1,
                "kind": "business_knowledge_release",
                "authority": "protected_business_knowledge",
                "authorization": "github_environment_review",
                "source_commit": "b" * 40,
                "producer": {
                    "work_item": item_id,
                    "evidence": evidence_relative,
                    "evidence_sha256": evidence_sha,
                },
                "inputs": {
                    "packet_proposal": proposal,
                    "packet_proposal_sha256": proposal_sha,
                },
                "bindings": {
                    "packet": {
                        "id": packet_id,
                        "revision": 1,
                    }
                },
                "outputs": {
                    published: published_sha,
                },
                "deletions": [proposal],
            }
            fixture.write_json(receipt_relative, receipt)

            errors = harness.validate_references(items, state)
            self.assertFalse(
                any(proposal in error for error in errors),
                errors,
            )

            consumer_id = "IOS-KNOWLEDGE-CONSUMER-001"
            consumer = fixture.item(consumer_id, "CAP-BOOT", 70)
            consumer["spec"]["inputs"]["context_files"] = [proposal]
            items[consumer_id] = consumer
            consumer_evidence_relative = (
                "ios/harness/evidence/runs/"
                "run-promoted-context-consumer.json"
            )
            fixture.write_json(
                consumer_evidence_relative,
                {
                    "schema_version": 1,
                    "work_item_id": consumer_id,
                    "result": "passed",
                    "changes": {
                        "file_fingerprints": {},
                        "dirty_snapshot": {
                            proposal: f"file:0o644:{proposal_sha}"
                        },
                    },
                },
            )
            consumer_evidence_sha = harness_module.sha256_bytes(
                (
                    fixture.root / consumer_evidence_relative
                ).read_bytes()
            )
            state["work_items"][consumer_id] = {
                "status": "completed",
                "last_evidence": consumer_evidence_relative,
                "last_evidence_sha256": consumer_evidence_sha,
            }
            errors = harness.validate_references(items, state)
            self.assertFalse(
                any(proposal in error for error in errors),
                errors,
            )

            published_path = fixture.root / published
            original_published = published_path.read_bytes()
            published_path.write_bytes(original_published + b" ")
            errors = harness.validate_references(items, state)
            self.assertTrue(
                any("PROMOTED_CONTEXT_INVALID" in error for error in errors),
                errors,
            )
            published_path.write_bytes(original_published)

            duplicate = receipt.copy()
            fixture.write_json(
                "ios/project/business-knowledge/releases/duplicate.json",
                duplicate,
            )
            errors = harness.validate_references(items, state)
            self.assertTrue(
                any(
                    "PROMOTED_CONTEXT_INVALID receipt count=2" in error
                    for error in errors
                ),
                errors,
            )

            (fixture.root / receipt_relative).unlink()
            (
                fixture.root
                / "ios/project/business-knowledge/releases/duplicate.json"
            ).unlink()
            state["work_items"][item_id]["status"] = "ready"
            errors = harness.validate_references(items, state)
            self.assertTrue(
                any("context file 不存在" in error for error in errors),
                errors,
            )

    def test_business_knowledge_is_frozen_and_written_to_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            fixture.initialize()
            harness = self.enable_business_knowledge(fixture)
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            runtime = harness.state()["work_items"]["IOS-BOOT-001"]
            self.assertTrue(runtime["business_knowledge_control_sha256"])
            fixture.write_text("ios/implementation.txt", "implemented\n")
            evidence = harness_module.load_json(harness.verify("IOS-BOOT-001"))
            self.assertEqual(
                runtime["business_knowledge_control_sha256"],
                evidence["inputs"]["business_knowledge_control_sha256"],
            )
            self.assertNotIn(
                "ios/project/business-knowledge/catalog.json",
                evidence["changes"]["paths"],
            )

    def test_business_knowledge_control_drift_stops_verify(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            fixture.initialize()
            harness = self.enable_business_knowledge(fixture)
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            policy_path = root / "ios/harness/business-knowledge/policy-v1.json"
            policy = harness_module.load_json(policy_path)
            policy["default_context_budget"]["max_bytes"] += 1
            fixture.write_json("ios/harness/business-knowledge/policy-v1.json", policy)
            with self.assertRaisesRegex(harness_module.HarnessError, "KNOWLEDGE_DRIFT"):
                harness.verify("IOS-BOOT-001")

    def test_knowledge_tombstone_scope_requires_corrective_control_plane(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            item = fixture.item("IOS-TOMBSTONE-001", "CAP-BOOT", 100)
            item["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "not_applicable",
                "claim_refs": [],
                "driver_refs": [],
                "coverage_refs": [],
                "produces": [],
                "expected_ledger_transitions": [],
                "context_budget": {"max_claims": 20, "max_bytes": 32768},
                "none_reason": "control-plane tombstone protocol",
            }
            item["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = []
            path = (
                "ios/project/business-knowledge/tombstones/packets/"
                "BKP-TEST-DOMAIN-001/r0001.json"
            )
            item["metadata"]["labels"] = ["control-plane", "corrective"]
            self.assertEqual(
                [],
                harness.knowledge_scope_issues(item, [path]),
            )

            item["metadata"]["labels"] = ["knowledge"]
            errors = harness.knowledge_scope_issues(item, [path])
            self.assertTrue(
                any("AUTHORITY_ESCALATION" in error for error in errors)
            )

    def test_doctor_does_not_reselect_terminal_knowledge_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            fixture.initialize()
            harness = self.enable_business_knowledge(fixture)
            state = harness.state()
            for runtime in state["work_items"].values():
                runtime["status"] = "superseded"
            fixture.write_json("ios/project/state.json", state)
            fixture.write_text(
                "ios/project/status.md",
                harness.render_status(state, harness.work_items()),
            )
            with mock.patch.object(
                harness,
                "business_knowledge_selection",
                side_effect=AssertionError("terminal selection must not be recomputed"),
            ):
                errors, _ = harness.doctor()
            self.assertEqual([], errors)

    def test_ledger_close_matches_declared_sections_and_transaction_refs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            fixture.write_json(
                "ios/project/android-intake/inventory-manifest.json",
                {"facts": []},
            )
            fixture.write_json(
                "ios/project/requirements/catalog.json",
                {"requirements": []},
            )
            ledger_id = "BKL-TEST-CLOSE-001"
            entry_id = "BKE-TEST-CLOSE-001"
            path = f"ios/project/business-knowledge/coverage/{ledger_id}.json"
            old_delivery = {
                "state": "planned",
                "requirement_refs": [],
                "work_item_refs": [],
                "capability_refs": [],
                "evidence_refs": [],
            }
            ledger = {
                "schema_version": 1,
                "kind": "BusinessKnowledgeCoverageLedger",
                "id": ledger_id,
                "revision": 1,
                "status": "current",
                "packet_refs": [],
                "generated_from": {},
                "entries": [{
                    "id": entry_id,
                    "claim_ref": {"id": "BKC-TEST-CLOSE-001", "revision": 1},
                    "validation": {
                        "required": "none",
                        "state": "not_applicable",
                        "evidence_refs": [],
                        "blockers": [],
                    },
                    "product_disposition": {
                        "kind": "knowledge_only",
                        "refs": [],
                        "reason": None,
                        "review_after": None,
                    },
                    "delivery": old_delivery,
                    "computed": {"accounted": True, "coverage_state": "covered"},
                }],
                "updated_by": "IOS-BOOT-001",
                "updated_at": "2026-01-01T00:00:00Z",
            }
            fixture.write_json(path, ledger)
            new_delivery = {**old_delivery, "state": "implemented"}
            item = fixture.item("IOS-BOOT-001", "CAP-BOOT", 100)
            item["spec"]["knowledge"] = {
                "coverage_refs": [{
                    "id": ledger_id,
                    "revision": 1,
                    "entries": [entry_id],
                }],
                "expected_ledger_transitions": [{
                    "id": ledger_id,
                    "from_revision": 1,
                    "to_revision": 2,
                    "entry_updates": [{"id": entry_id, "set": {"delivery": new_delivery}}],
                }]
            }
            selection = {
                "coverage": [{
                    "ledger": {"id": ledger_id, "revision": 1, "path": path},
                }]
            }
            runtime = {
                "knowledge_ledger_revisions": {ledger_id: 1},
                "knowledge_ledger_snapshots": harness.business_knowledge_ledger_snapshots(
                    item, selection
                ),
                "last_evidence": "ios/harness/evidence/runs/current.json",
            }
            ledger["revision"] = 2
            ledger["entries"][0]["delivery"] = new_delivery
            fixture.write_json(path, ledger)
            self.assertEqual(
                [],
                harness.knowledge_close_issues("IOS-BOOT-001", item, runtime),
            )

            item["spec"]["knowledge"]["coverage_refs"] = [
                {
                    "id": ledger_id,
                    "revision": 1,
                    "entries": [entry_id],
                },
                {
                    "id": ledger_id,
                    "revision": 1,
                    "entries": ["BKE-TEST-CLOSE-999"],
                },
            ]
            self.assertFalse(any(
                "越出显式 Coverage selection" in error
                for error in harness.validate_business_knowledge_spec(
                    item, "IOS-BOOT-001"
                )
            ))
            self.assertFalse(any(
                "越出显式 Coverage selection" in error
                for error in harness.knowledge_close_issues(
                    "IOS-BOOT-001", item, runtime
                )
            ))
            item["spec"]["knowledge"]["coverage_refs"][1]["revision"] = 2
            self.assertTrue(any(
                "必须使用相同 revision" in error
                for error in harness.validate_business_knowledge_spec(
                    item, "IOS-BOOT-001"
                )
            ))

            item["spec"]["knowledge"]["coverage_refs"] = [{
                "id": ledger_id,
                "revision": 1,
                "entries": [entry_id],
            }]
            item["spec"]["knowledge"]["coverage_refs"][0]["entries"] = [
                "BKE-TEST-CLOSE-999"
            ]
            self.assertTrue(any(
                "越出显式 Coverage selection" in error
                for error in harness.validate_business_knowledge_spec(
                    item, "IOS-BOOT-001"
                )
            ))
            self.assertTrue(any(
                "越出显式 Coverage selection" in error
                for error in harness.knowledge_close_issues(
                    "IOS-BOOT-001", item, runtime
                )
            ))
            item["spec"]["knowledge"]["coverage_refs"][0]["entries"] = [entry_id]

            ledger["entries"][0]["claim_ref"]["revision"] = 2
            fixture.write_json(path, ledger)
            self.assertTrue(any(
                "claim_ref 不可变" in error
                for error in harness.knowledge_close_issues(
                    "IOS-BOOT-001", item, runtime
                )
            ))
            ledger["entries"][0]["claim_ref"]["revision"] = 1

            ledger["entries"][0]["product_disposition"]["reason"] = "undeclared"
            fixture.write_json(path, ledger)
            self.assertTrue(any(
                "实际变化 section" in error
                for error in harness.knowledge_close_issues("IOS-BOOT-001", item, runtime)
            ))

            ledger["entries"][0]["product_disposition"]["reason"] = None
            verified_delivery = {**old_delivery, "state": "verified"}
            ledger["entries"][0]["delivery"] = verified_delivery
            item["spec"]["knowledge"]["expected_ledger_transitions"][0]["entry_updates"][0][
                "set"
            ]["delivery"] = verified_delivery
            fixture.write_json(path, ledger)
            self.assertTrue(any(
                "verified delivery 缺少当前事务" in error
                for error in harness.knowledge_close_issues("IOS-BOOT-001", item, runtime)
            ))

    def test_doctor_reports_malformed_ledger_updates_without_crashing(self):
        variants = (
            "null-updates",
            "object-updates",
            "nested-entry-selection",
            "array-ledger-ref-id",
            "array-transition-id",
            "array-update-id",
        )
        for variant in variants:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fixture = HarnessFixture(root)
                harness = fixture.initialize()
                item_path = root / "ios/harness/work-items/IOS-BOOT-001.json"
                item = harness_module.load_json(item_path)
                claim_ref = {"id": "BKC-TEST-MALFORMED-001", "revision": 1}
                item["spec"]["knowledge"] = {
                    "contract_version": 1,
                    "mode": "consume",
                    "claim_refs": [claim_ref],
                    "driver_refs": [],
                    "coverage_refs": [{
                        "id": "BKL-TEST-MALFORMED-001",
                        "revision": 1,
                        "entries": ["BKE-TEST-MALFORMED-001"],
                    }],
                    "produces": [],
                    "expected_ledger_transitions": [{
                        "id": "BKL-TEST-MALFORMED-001",
                        "from_revision": 1,
                        "to_revision": 2,
                        "entry_updates": [{
                            "id": "BKE-TEST-MALFORMED-001",
                            "set": {"computed": {"accounted": True}},
                        }],
                    }],
                    "context_budget": {"max_claims": 40, "max_bytes": 65536},
                    "none_reason": None,
                }
                knowledge = item["spec"]["knowledge"]
                transition = knowledge["expected_ledger_transitions"][0]
                if variant == "null-updates":
                    transition["entry_updates"] = None
                elif variant == "object-updates":
                    transition["entry_updates"] = {}
                elif variant == "nested-entry-selection":
                    knowledge["coverage_refs"][0]["entries"] = [[]]
                elif variant == "array-ledger-ref-id":
                    knowledge["coverage_refs"][0]["id"] = []
                elif variant == "array-transition-id":
                    transition["id"] = []
                elif variant == "array-update-id":
                    transition["entry_updates"][0]["id"] = []
                item["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = [
                    claim_ref
                ]
                fixture.write_json(
                    "ios/harness/work-items/IOS-BOOT-001.json",
                    item,
                )
                harness = harness_module.Harness(root)
                errors, _ = harness.doctor()
                self.assertTrue(errors, variant)

    def test_verified_capability_becomes_stale_when_architecture_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "implemented\n")
            evidence_path = harness.verify("IOS-BOOT-001")
            evidence_relative = harness.relative(evidence_path)
            capability = harness.capability("CAP-BOOT")
            capability.update(
                {
                    "revision": 2,
                    "declared_status": "verified",
                    "latest_evidence": evidence_relative,
                    "updated_by": "IOS-BOOT-001",
                }
            )
            fixture.write_json("ios/project/capabilities/CAP-BOOT.json", capability)
            errors = harness.memory_issues(harness.work_items(), harness.state())
            self.assertEqual([], errors)

            fixture.write_text("ios/docs/architecture.md", "ARCH-001\nchanged architecture\n")
            errors = harness.memory_issues(harness.work_items(), harness.state())
            self.assertTrue(
                any("architecture_digest_sha256" in error for error in errors),
                errors,
            )

    def test_event_hash_chain_detects_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            self.assertEqual([], harness.validate_events())
            events = harness.event_lines()
            events[0]["payload"] = {"tampered": True}
            fixture.write_text("ios/project/events.jsonl", json.dumps(events[0]) + "\n")
            self.assertTrue(any("event_hash" in error for error in harness.validate_events()))

    def test_architecture_forbidden_import(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            fixture.write_text(
                "ios/Packages/LegadoKit/Sources/LegadoCore/Bad.swift",
                "import SwiftUI\npublic struct Bad {}\n",
            )
            errors, _ = harness.architecture_issues()
            self.assertTrue(any("禁止 import SwiftUI" in error for error in errors))

    def test_architecture_detects_implementation_only_import(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            rules_path = Path(directory) / "ios/harness/architecture-rules.json"
            rules = json.loads(rules_path.read_text(encoding="utf-8"))
            rules["known_external_modules"] = ["GRDB"]
            fixture.write_json("ios/harness/architecture-rules.json", rules)
            fixture.write_text(
                "ios/Packages/LegadoKit/Sources/LegadoCore/Bad.swift",
                "@_implementationOnly import GRDB\npublic struct Bad {}\n",
            )
            harness = harness_module.Harness(Path(directory))
            errors, _ = harness.architecture_issues()
            self.assertTrue(any("外部模块 GRDB" in error for error in errors), errors)

    def test_path_globs_are_repo_relative(self):
        self.assertTrue(harness_module.path_matches("ios/project/pitfalls/PIT-0001.json", ["ios/project/pitfalls/PIT-*.json"]))
        self.assertTrue(harness_module.path_matches("ios/Packages/LegadoKit/Package.swift", ["**/Package.swift"]))
        self.assertFalse(harness_module.path_matches("app/build.gradle", ["ios/**"]))

    def test_output_redaction(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            self.assertEqual("Authorization: <redacted>", harness.redact_output(b"Authorization: bearer-secret"))

    def test_terminate_process_group_returns_stable_permission_diagnostics(self):
        with mock.patch.object(
            harness_module.os, "killpg", side_effect=PermissionError
        ):
            diagnostic = harness_module.Harness.terminate_process_group(123)
        self.assertEqual("sigterm_permission_denied", diagnostic)

        with mock.patch.object(
            harness_module.os,
            "killpg",
            side_effect=[None, PermissionError],
        ):
            diagnostic = harness_module.Harness.terminate_process_group(
                123, grace_seconds=0
            )
        self.assertEqual("sigkill_permission_denied", diagnostic)

    def test_terminate_process_group_tolerates_process_exit_race(self):
        with mock.patch.object(
            harness_module.os,
            "killpg",
            side_effect=[None, ProcessLookupError],
        ):
            diagnostic = harness_module.Harness.terminate_process_group(123)
        self.assertIsNone(diagnostic)

    def test_run_check_timeout_cleanup_is_bounded_and_structured(self):
        class TimeoutProcess:
            pid = 123
            returncode = None

            def __init__(self):
                self.communicate_timeouts = []

            def communicate(self, timeout=None):
                self.communicate_timeouts.append(timeout)
                raise subprocess.TimeoutExpired(
                    ["fake-check"],
                    timeout,
                    output=b"partial stdout",
                    stderr=b"partial stderr",
                )

            def kill(self):
                raise PermissionError

        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            process = TimeoutProcess()
            with (
                mock.patch.object(
                    harness_module.subprocess, "Popen", return_value=process
                ),
                mock.patch.object(
                    harness,
                    "terminate_process_group",
                    return_value="sigterm_permission_denied",
                ),
                mock.patch.object(harness, "process_group_exists", return_value=True),
            ):
                result = harness.run_check("noop", "IOS-BOOT-001")

        self.assertFalse(result["passed"])
        self.assertTrue(result["timed_out"])
        self.assertTrue(result["process_leak"])
        self.assertEqual(
            "sigterm_permission_denied;process_kill_permission_denied;"
            "communicate_timeout_after_cleanup",
            result["cleanup_error"],
        )
        self.assertEqual([10, 1.0], process.communicate_timeouts)
        self.assertIn("CLEANUP_ERROR:", result["stderr_tail"])

    def test_harness_tests_use_bounded_effective_timeout_definition(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            configured = {
                "argv": ["python3", "-c", "print('full-suite')"],
                "cwd": ".",
                "timeout_seconds": 60,
            }
            harness.config["checks"]["harness-tests"] = configured

            effective = harness.effective_check_definition("harness-tests")
            self.assertEqual(180, effective["timeout_seconds"])
            self.assertEqual(configured["argv"], effective["argv"])
            self.assertEqual(configured["cwd"], effective["cwd"])
            result = harness.run_check("harness-tests", "IOS-BOOT-001")
            self.assertTrue(result["passed"], result)
            self.assertEqual(180, result["timeout_seconds"])
            self.assertEqual(
                harness_module.sha256_json(effective),
                result["definition_sha256"],
            )

            harness.config["checks"]["harness-tests"]["timeout_seconds"] = 240
            self.assertEqual(
                240,
                harness.effective_check_definition("harness-tests")[
                    "timeout_seconds"
                ],
            )
            self.assertEqual(
                10,
                harness.effective_check_definition("noop")["timeout_seconds"],
            )

    def test_run_check_normal_completion_has_no_cleanup_error(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = HarnessFixture(Path(directory))
            harness = fixture.initialize()
            result = harness.run_check("noop", "IOS-BOOT-001")
        self.assertTrue(result["passed"])
        self.assertFalse(result["timed_out"])
        self.assertFalse(result["process_leak"])
        self.assertIsNone(result["cleanup_error"])

    def test_verify_persists_cleanup_failure_evidence_and_event(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "candidate\n")
            failed_check = {
                "id": "noop",
                "argv": ["fake-check"],
                "executable_path": "/fake-check",
                "definition_sha256": "definition",
                "cwd": ".",
                "started_at": "2026-01-01T00:00:00Z",
                "duration_ms": 1000,
                "timeout_seconds": 10,
                "timed_out": True,
                "process_leak": True,
                "cleanup_error": "sigterm_permission_denied",
                "exit_code": None,
                "passed": False,
                "stdout_sha256": "stdout",
                "stderr_sha256": "stderr",
                "stdout_tail": "",
                "stderr_tail": "CLEANUP_ERROR: sigterm_permission_denied",
            }
            with mock.patch.object(harness, "run_check", return_value=failed_check):
                evidence = harness_module.load_json(harness.verify("IOS-BOOT-001"))

            self.assertEqual("failed", evidence["result"])
            self.assertEqual(
                "sigterm_permission_denied",
                evidence["checks"][0]["cleanup_error"],
            )
            self.assertEqual("PROCESS_LEAK", evidence["failure"]["class"])
            self.assertEqual("VerificationFailed", harness.event_lines()[-1]["event"])
            self.assertEqual(
                1,
                harness.state()["work_items"]["IOS-BOOT-001"]["verify_cycles"],
            )

    def test_intentional_difference_requires_dedicated_adjudication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            fixture.write_json(
                "ios/project/compatibility/COMP-0001.json",
                {
                    "schema_version": 1,
                    "id": "COMP-0001",
                    "revision": 1,
                    "capability": "CAP-BOOT",
                    "title": "test difference",
                    "android": {},
                    "ios": {},
                    "classification": "intentional_difference",
                    "decision": "accept_difference",
                    "decision_adr": "ADR-0001",
                    "affected_profiles": ["test"],
                    "severity": "low",
                    "tests": [],
                    "status": "open",
                    "introduced_by": "IOS-BOOT-001",
                },
            )
            item = harness.work_items()["IOS-BOOT-001"]
            gates, errors = harness.required_close_gates(
                "IOS-BOOT-001",
                item,
                ["ios/project/compatibility/COMP-0001.json"],
            )
            self.assertIn("oracle-adjudication", gates)
            self.assertTrue(any("COMP-0001" in error for error in errors), errors)

    def test_decision_contract_validation_and_dynamic_gate_are_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            item = fixture.item("IOS-DECISION-001", "CAP-BOOT", 100)
            item["spec"]["gates"] = ["oracle-adjudication"]
            item["spec"]["gate_contract_version"] = 1
            item["spec"]["decision_gates"] = [
                {
                    "gate": "oracle-adjudication",
                    "trigger": "oracle-difference",
                    "question": "是否接受这个有证据支持的平台差异？",
                    "why_human": "两个平台行为都可实现，需要项目所有者决定兼容目标。",
                    "options": [
                        {
                            "id": "accept-difference",
                            "label": "接受差异",
                            "consequence": "iOS 保持平台化行为并记录兼容差异。",
                            "reversible": True,
                        },
                        {
                            "id": "match-android",
                            "label": "继续对齐 Android",
                            "consequence": "增加实现成本以保持跨端一致。",
                            "reversible": True,
                        },
                    ],
                    "recommended_option": "accept-difference",
                }
            ]
            contracts, errors = harness.decision_gate_contracts(item)
            self.assertEqual([], errors)
            self.assertEqual(
                {"oracle-adjudication"},
                set(contracts),
            )

            malformed = json.loads(json.dumps(item))
            malformed["spec"]["decision_gates"][0]["recommended_option"] = "missing"
            _, errors = harness.decision_gate_contracts(malformed)
            self.assertTrue(
                any("recommended_option" in error for error in errors),
                errors,
            )

            item_without_decision = fixture.item(
                "IOS-DECISION-002",
                "CAP-BOOT",
                100,
            )
            item_without_decision["spec"]["gate_contract_version"] = 1
            item_without_decision["spec"]["decision_gates"] = []
            fixture.write_json(
                "ios/project/compatibility/COMP-0001.json",
                {
                    "classification": "intentional_difference",
                    "decision": "accept_difference",
                    "decision_adr": "ADR-0001",
                    "id": "COMP-0001",
                    "introduced_by": "IOS-DECISION-002",
                },
            )
            gates, errors = harness.required_close_gates(
                "IOS-DECISION-002",
                item_without_decision,
                ["ios/project/compatibility/COMP-0001.json"],
            )
            self.assertNotIn("oracle-adjudication", gates)
            self.assertTrue(
                any("UNSTRUCTURED_DECISION_REQUIRED" in error for error in errors),
                errors,
            )

    def test_proposal_changes_only_gate_when_structured_review_is_declared(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            item = fixture.item("IOS-PROPOSAL-001", "CAP-BOOT", 100)
            item["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "supersede",
                "claim_refs": [],
                "driver_refs": [],
                "coverage_refs": [],
                "produces": [
                    {"kind": "packet", "id": "BKP-PROPOSAL-001", "revision": 1},
                    {"kind": "driver", "id": "DRV-PROPOSAL-001", "revision": 1},
                ],
                "expected_ledger_transitions": [],
                "context_budget": {"max_claims": 10, "max_bytes": 4096},
                "none_reason": None,
            }
            proposal_paths = harness.knowledge_proposal_paths(item)
            gates, errors = harness.required_close_gates(
                "IOS-PROPOSAL-001",
                item,
                proposal_paths,
            )
            self.assertEqual([], gates)
            self.assertEqual([], errors)

            item["spec"]["gates"] = [
                "knowledge-review",
                "architecture-review",
            ]
            item["spec"]["gate_contract_version"] = 1
            item["spec"]["decision_gates"] = [
                {
                    "gate": gate,
                    "trigger": trigger,
                    "question": f"是否审查 {gate}？",
                    "why_human": "项目所有者显式要求在候选阶段做方向判断。",
                    "options": [
                        {
                            "id": "accept",
                            "label": "接受候选",
                            "consequence": "允许候选继续停留在 proposal。",
                            "reversible": True,
                        },
                        {
                            "id": "revise",
                            "label": "继续修改",
                            "consequence": "保持工作项未完成并继续修订。",
                            "reversible": True,
                        },
                    ],
                    "recommended_option": "accept",
                }
                for gate, trigger in (
                    ("knowledge-review", "knowledge-proposal-change"),
                    ("architecture-review", "architecture-proposal-change"),
                )
            ]
            gates, errors = harness.required_close_gates(
                "IOS-PROPOSAL-001",
                item,
                proposal_paths,
            )
            self.assertEqual(
                ["architecture-review", "knowledge-review"],
                gates,
            )
            self.assertEqual([], errors)

    def test_structured_decision_record_binds_contract_option_and_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            item = harness.work_items()["IOS-BOOT-001"]
            contract = {
                "gate": "architecture-choice",
                "trigger": "always",
                "question": "采用哪个模块边界？",
                "why_human": "两个方案都通过机器约束，需要项目方向取舍。",
                "options": [
                    {
                        "id": "separate",
                        "label": "独立模块",
                        "consequence": "提高替换性并增加模块数。",
                        "reversible": True,
                    },
                    {
                        "id": "combined",
                        "label": "合并模块",
                        "consequence": "减少模块数并提高后续拆分成本。",
                        "reversible": True,
                    },
                ],
                "recommended_option": "separate",
            }
            item["spec"]["gates"] = ["architecture-choice"]
            item["spec"]["gate_contract_version"] = 1
            item["spec"]["decision_gates"] = [contract]
            gate = "architecture-choice"
            tree = "a" * 64
            evidence = "b" * 64
            fixture.write_json(
                f"ios/project/approvals/IOS-BOOT-001--{gate}.json",
                {
                    "schema_version": 1,
                    "work_item_id": "IOS-BOOT-001",
                    "gate": gate,
                    "work_item_sha256": harness_module.sha256_json(item),
                    "tree_sha256": tree,
                    "evidence_sha256": evidence,
                    "decision_contract_sha256": harness_module.sha256_json(
                        contract
                    ),
                    "selected_option": "separate",
                    "presented_at": "2026-07-28T00:00:00Z",
                    "decided_at": "2026-07-28T00:01:00Z",
                    "reviewer": "local-user:test",
                    "approved_at": "2026-07-28T00:01:00Z",
                    "expires_at": "2099-07-29T00:01:00Z",
                    "signature": None,
                },
            )
            self.assertEqual(
                [],
                harness.approval_issues(
                    "IOS-BOOT-001",
                    item,
                    tree,
                    [gate],
                    requested_at="2026-07-28T00:00:00Z",
                    evidence_sha256=evidence,
                ),
            )
            approval_path = (
                root
                / f"ios/project/approvals/IOS-BOOT-001--{gate}.json"
            )
            approval = json.loads(approval_path.read_text())
            approval["selected_option"] = "not-an-option"
            fixture.write_json(
                f"ios/project/approvals/IOS-BOOT-001--{gate}.json",
                approval,
            )
            errors = harness.approval_issues(
                "IOS-BOOT-001",
                item,
                tree,
                [gate],
                requested_at="2026-07-28T00:00:00Z",
                evidence_sha256=evidence,
            )
            self.assertTrue(
                any("selected_option 无效" in error for error in errors),
                errors,
            )

    def test_claim_verify_and_close_memory_transaction(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            predecessor_id = "IOS-FAILED-001"
            predecessor = fixture.item(
                predecessor_id,
                "CAP-BOOT",
                80,
            )
            fixture.write_json(
                f"ios/harness/work-items/{predecessor_id}.json",
                predecessor,
            )
            item_path = root / "ios/harness/work-items/IOS-BOOT-001.json"
            item = harness_module.load_json(item_path)
            item["spec"]["recovers"] = predecessor_id
            fixture.write_json(
                "ios/harness/work-items/IOS-BOOT-001.json",
                item,
            )
            state = harness.state()
            state["work_items"][predecessor_id] = {
                "status": "blocked",
                "attempt": 1,
                "last_evidence": None,
                "blocker": "baseline_red",
            }
            fixture.write_json("ios/project/state.json", state)
            harness = harness_module.Harness(root)
            fixture.write_text(
                "ios/project/status.md",
                harness.render_status(harness.state(), harness.work_items()),
            )
            self.initialize_git(root)

            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "implemented\n")
            evidence_path = harness.verify("IOS-BOOT-001")
            evidence_relative = harness.relative(evidence_path)
            self.assertEqual("passed", harness_module.load_json(evidence_path)["result"])

            capability = harness.capability("CAP-BOOT")
            capability.update(
                {
                    "revision": 2,
                    "declared_status": "verified",
                    "latest_evidence": evidence_relative,
                    "updated_by": "IOS-BOOT-001",
                }
            )
            fixture.write_json("ios/project/capabilities/CAP-BOOT.json", capability)
            fixture.write_json(
                "ios/project/checkpoints/IOS-BOOT-001.json",
                {
                    "schema_version": 1,
                    "work_item_id": "IOS-BOOT-001",
                    "summary": "完成测试实现",
                    "evidence": evidence_relative,
                    "capability_updates": [
                        {"id": "CAP-BOOT", "from_revision": 1, "to_revision": 2}
                    ],
                    "architecture_impact": {
                        "kind": "implements_existing",
                        "adr_refs": ["ADR-0001"],
                    },
                    "requirements": {"mode": "control_plane", "refs": [], "selection_sha256": None},
                    "source_lab": {"mode": "not_applicable", "behaviors": [], "scenarios": [], "selection_sha256": None},
                    "compatibility": {"records": [], "none_reason": "没有跨端行为"},
                    "pitfalls": {"records": [], "none_reason": "没有长期踩坑"},
                    "remaining_risks": [],
                    "next_actions": [],
                    "created_at": "2026-01-01T00:00:00Z",
                },
            )
            self.assertEqual("completed", harness.close("IOS-BOOT-001"))
            predecessor_runtime = harness.state()["work_items"][predecessor_id]
            self.assertEqual(
                "IOS-BOOT-001",
                predecessor_runtime["replacement"],
            )
            self.assertTrue(predecessor_runtime["replacement_bound_at"])
            recovery_events = [
                event
                for event in harness.event_lines()
                if event.get("event") == "WorkItemRecoveryBound"
            ]
            self.assertEqual(1, len(recovery_events))
            self.assertEqual(predecessor_id, recovery_events[0]["work_item_id"])
            self.assertEqual(
                "IOS-BOOT-001",
                recovery_events[0]["payload"]["replacement"],
            )
            errors, _ = harness.doctor()
            self.assertEqual([], errors)

    def test_verify_rejects_staged_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "candidate\n")
            subprocess.run(["git", "add", "ios/implementation.txt"], cwd=str(root), check=True)
            evidence = harness_module.load_json(harness.verify("IOS-BOOT-001"))
            self.assertEqual("failed", evidence["result"])
            self.assertTrue(any("INDEX_DIRTY" in error for error in evidence["policy_errors"]))

    def test_verify_sees_both_sides_of_protected_rename(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            fixture.write_json("ios/harness/goldens/protected-extra.json", {"protected": True})
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            source = root / "ios/harness/goldens/protected-extra.json"
            destination = root / "ios/moved-from-protected.json"
            source.rename(destination)
            evidence = harness_module.load_json(harness.verify("IOS-BOOT-001"))
            self.assertEqual("failed", evidence["result"])
            self.assertTrue(
                any("protected-extra.json" in error for error in evidence["policy_errors"]),
                evidence["policy_errors"],
            )

    def test_verify_rejects_check_that_mutates_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            config = json.loads((root / "ios/harness/config.json").read_text(encoding="utf-8"))
            config["checks"]["mutating-check"] = {
                "argv": [
                    "python3",
                    "-c",
                    "from pathlib import Path; Path('ios/implementation.txt').write_text('mutated-after-check\\n')",
                ],
                "cwd": ".",
                "timeout_seconds": 10,
            }
            fixture.write_json("ios/harness/config.json", config)
            item_path = root / "ios/harness/work-items/IOS-BOOT-001.json"
            item = json.loads(item_path.read_text(encoding="utf-8"))
            item["spec"]["acceptance"]["required_checks"] = ["mutating-check"]
            item["spec"]["acceptance"]["criteria"][0]["verified_by"] = ["mutating-check"]
            fixture.write_json("ios/harness/work-items/IOS-BOOT-001.json", item)
            harness = harness_module.Harness(root)
            fixture.write_text("ios/project/status.md", harness.render_status(harness.state(), harness.work_items()))
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "candidate-that-was-not-tested\n")
            evidence = harness_module.load_json(harness.verify("IOS-BOOT-001"))
            self.assertEqual("failed", evidence["result"])
            self.assertTrue(any("CHECK_MUTATED_CANDIDATE" in error for error in evidence["policy_errors"]))

    def test_verify_fails_and_cleans_up_orphan_check_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            config = json.loads((root / "ios/harness/config.json").read_text(encoding="utf-8"))
            config["checks"]["leaky-check"] = {
                "argv": [
                    "python3",
                    "-c",
                    "import subprocess; subprocess.Popen(['sleep', '60'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)",
                ],
                "cwd": ".",
                "timeout_seconds": 10,
            }
            fixture.write_json("ios/harness/config.json", config)
            item_path = root / "ios/harness/work-items/IOS-BOOT-001.json"
            item = json.loads(item_path.read_text(encoding="utf-8"))
            item["spec"]["acceptance"]["required_checks"] = ["leaky-check"]
            item["spec"]["acceptance"]["criteria"][0]["verified_by"] = ["leaky-check"]
            fixture.write_json("ios/harness/work-items/IOS-BOOT-001.json", item)
            harness = harness_module.Harness(root)
            fixture.write_text("ios/project/status.md", harness.render_status(harness.state(), harness.work_items()))
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "candidate\n")
            evidence = harness_module.load_json(harness.verify("IOS-BOOT-001"))
            self.assertEqual("failed", evidence["result"])
            self.assertTrue(evidence["checks"][0]["process_leak"])
            self.assertEqual("PROCESS_LEAK", evidence["failure"]["class"])

    def test_close_rejects_invalid_pitfall_before_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "implemented\n")
            evidence_path = harness.verify("IOS-BOOT-001")
            evidence_relative = harness.relative(evidence_path)
            capability = harness.capability("CAP-BOOT")
            capability.update(
                {"revision": 2, "declared_status": "verified", "latest_evidence": evidence_relative, "updated_by": "IOS-BOOT-001"}
            )
            fixture.write_json("ios/project/capabilities/CAP-BOOT.json", capability)
            fixture.write_json("ios/project/pitfalls/PIT-0001.json", {})
            fixture.write_json(
                "ios/project/checkpoints/IOS-BOOT-001.json",
                {
                    "schema_version": 1,
                    "work_item_id": "IOS-BOOT-001",
                    "summary": "完成测试实现",
                    "evidence": evidence_relative,
                    "capability_updates": [{"id": "CAP-BOOT", "from_revision": 1, "to_revision": 2}],
                    "architecture_impact": {"kind": "implements_existing", "adr_refs": ["ADR-0001"]},
                    "requirements": {"mode": "control_plane", "refs": [], "selection_sha256": None},
                    "source_lab": {"mode": "not_applicable", "behaviors": [], "scenarios": [], "selection_sha256": None},
                    "compatibility": {"records": [], "none_reason": "没有跨端行为"},
                    "pitfalls": {"records": ["ios/project/pitfalls/PIT-0001.json"], "none_reason": None},
                    "remaining_risks": [],
                    "next_actions": [],
                    "created_at": "2026-01-01T00:00:00Z",
                },
            )
            with self.assertRaisesRegex(harness_module.HarnessError, "Pitfall"):
                harness.close("IOS-BOOT-001")
            self.assertEqual("verified", harness.state()["work_items"]["IOS-BOOT-001"]["status"])

    def test_human_gate_binds_stable_review_subject(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            item_path = root / "ios/harness/work-items/IOS-BOOT-001.json"
            item = json.loads(item_path.read_text(encoding="utf-8"))
            item["spec"]["gates"] = ["security-review"]
            fixture.write_json("ios/harness/work-items/IOS-BOOT-001.json", item)
            harness = harness_module.Harness(root)
            fixture.write_text("ios/project/status.md", harness.render_status(harness.state(), harness.work_items()))
            self.initialize_git(root)
            harness.claim("IOS-BOOT-001", "unit-test")
            fixture.write_text("ios/implementation.txt", "implemented\n")
            evidence_path = harness.verify("IOS-BOOT-001")
            evidence_relative = harness.relative(evidence_path)
            capability = harness.capability("CAP-BOOT")
            capability.update(
                {"revision": 2, "declared_status": "verified", "latest_evidence": evidence_relative, "updated_by": "IOS-BOOT-001"}
            )
            fixture.write_json("ios/project/capabilities/CAP-BOOT.json", capability)
            fixture.write_json(
                "ios/project/checkpoints/IOS-BOOT-001.json",
                {
                    "schema_version": 1,
                    "work_item_id": "IOS-BOOT-001",
                    "summary": "完成测试实现",
                    "evidence": evidence_relative,
                    "capability_updates": [{"id": "CAP-BOOT", "from_revision": 1, "to_revision": 2}],
                    "architecture_impact": {"kind": "implements_existing", "adr_refs": ["ADR-0001"]},
                    "requirements": {"mode": "control_plane", "refs": [], "selection_sha256": None},
                    "source_lab": {"mode": "not_applicable", "behaviors": [], "scenarios": [], "selection_sha256": None},
                    "compatibility": {"records": [], "none_reason": "没有跨端行为"},
                    "pitfalls": {"records": [], "none_reason": "没有长期踩坑"},
                    "remaining_risks": [],
                    "next_actions": [],
                    "created_at": "2026-01-01T00:00:00Z",
                },
            )
            approval_ref = (
                "ios/project/approvals/"
                "IOS-BOOT-001--security-review.json"
            )
            verified_runtime = harness.state()["work_items"]["IOS-BOOT-001"]
            preexisting_subject, _ = harness.candidate_snapshot(
                verified_runtime,
                [approval_ref],
            )
            fixture.write_json(
                approval_ref,
                {
                    "schema_version": 1,
                    "work_item_id": "IOS-BOOT-001",
                    "gate": "security-review",
                    "work_item_sha256": harness_module.sha256_json(item),
                    "tree_sha256": preexisting_subject,
                    "reviewer": "preexisting-human@example.invalid",
                    "approved_at": harness_module.utc_now(),
                    "expires_at": "2099-01-01T00:00:00Z",
                    "signature": None,
                },
            )
            self.assertEqual("awaiting_human", harness.close("IOS-BOOT-001"))
            runtime = harness.state()["work_items"]["IOS-BOOT-001"]
            self.assertEqual(
                harness.file_fingerprint(approval_ref),
                runtime["approval_request_existing_fingerprints"][approval_ref],
            )
            self.assertTrue(
                any(
                    "未在本次人工请求后更新" in reason
                    for reason in runtime["awaiting_human_reasons"]
                )
            )
            fixture.write_json(
                approval_ref,
                {
                    "schema_version": 1,
                    "work_item_id": "IOS-BOOT-001",
                    "gate": "security-review",
                    "work_item_sha256": harness_module.sha256_json(item),
                    "tree_sha256": runtime["review_subject_sha256"],
                    "reviewer": "human-reviewer@example.invalid",
                    "approved_at": harness_module.utc_now(),
                    "expires_at": "2099-01-01T00:00:00Z",
                    "signature": None,
                },
            )
            self.assertEqual("completed", harness.close("IOS-BOOT-001"))

    def test_product_scope_review_uses_two_stage_close(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = HarnessFixture(root)
            harness = fixture.initialize()
            item_id = "IOS-BOOT-001"
            ledger_id = "BKL-TEST-SCOPE-001"
            entry_id = "BKE-TEST-SCOPE-001"
            claim_ref = {"id": "BKC-TEST-SCOPE-001", "revision": 1}
            ledger_path = (
                f"ios/project/business-knowledge/coverage/{ledger_id}.json"
            )
            fixture.write_json(
                "ios/project/requirements/catalog.json",
                {"schema_version": 1, "requirements": []},
            )
            fixture.write_json(
                "ios/project/android-intake/inventory-manifest.json",
                {"facts": []},
            )
            approval_ref = (
                "ios/project/approvals/"
                f"{item_id}--product-scope-review.json"
            )
            old_disposition = {
                "kind": "knowledge_only",
                "refs": [],
                "reason": None,
                "review_after": None,
            }
            terminal_disposition = {
                "kind": "deferred",
                "refs": [approval_ref],
                "reason": "等待产品范围裁决",
                "review_after": "2026-12-01",
            }
            ledger = {
                "schema_version": 1,
                "kind": "BusinessKnowledgeCoverageLedger",
                "id": ledger_id,
                "revision": 1,
                "status": "current",
                "packet_refs": [],
                "generated_from": {},
                "entries": [{
                    "id": entry_id,
                    "claim_ref": claim_ref,
                    "validation": {
                        "required": "none",
                        "state": "not_applicable",
                        "evidence_refs": [],
                        "blockers": [],
                    },
                    "product_disposition": old_disposition,
                    "delivery": {
                        "state": "planned",
                        "requirement_refs": [],
                        "work_item_refs": [],
                        "capability_refs": [],
                        "evidence_refs": [],
                    },
                    "computed": {
                        "accounted": True,
                        "coverage_state": "covered",
                    },
                }],
                "updated_by": "IOS-BOOT-001",
                "updated_at": "2026-01-01T00:00:00Z",
            }
            fixture.write_json(ledger_path, ledger)

            item_path = root / f"ios/harness/work-items/{item_id}.json"
            item = harness_module.load_json(item_path)
            coverage_refs = [{
                "id": ledger_id,
                "revision": 1,
                "entries": [entry_id],
            }]
            transitions = [{
                "id": ledger_id,
                "from_revision": 1,
                "to_revision": 2,
                "entry_updates": [{
                    "id": entry_id,
                    "set": {"product_disposition": terminal_disposition},
                }],
            }]
            item["spec"]["knowledge"] = {
                "contract_version": 1,
                "mode": "consume",
                "claim_refs": [claim_ref],
                "driver_refs": [],
                "coverage_refs": coverage_refs,
                "produces": [],
                "expected_ledger_transitions": transitions,
                "context_budget": {"max_claims": 40, "max_bytes": 65536},
                "none_reason": None,
            }
            item["spec"]["acceptance"]["criteria"][0]["knowledge_claims"] = [
                claim_ref
            ]
            fixture.write_json(
                f"ios/harness/work-items/{item_id}.json",
                item,
            )
            harness = harness_module.Harness(root)
            fixture.write_text(
                "ios/project/status.md",
                harness.render_status(harness.state(), harness.work_items()),
            )
            selection = {
                "control_sha256": "1" * 64,
                "authority_sha256": "2" * 64,
                "knowledge_selection_sha256": "3" * 64,
                "coverage_selection_sha256": "4" * 64,
                "architecture_driver_selection_sha256": "5" * 64,
                "coverage": [{
                    "ledger": {
                        "id": ledger_id,
                        "revision": 1,
                        "path": ledger_path,
                    },
                }],
            }

            self.initialize_git(root)
            with mock.patch.object(
                harness,
                "business_knowledge_selection",
                return_value=selection,
            ):
                harness.claim(item_id, "unit-test")
                fixture.write_text("ios/implementation.txt", "implemented\n")
                evidence_path = harness.verify(item_id)
            evidence_relative = harness.relative(evidence_path)
            evidence = harness_module.load_json(evidence_path)
            self.assertEqual("passed", evidence["result"])

            capability = harness.capability("CAP-BOOT")
            capability.update({
                "revision": 2,
                "declared_status": "verified",
                "latest_evidence": evidence_relative,
                "updated_by": item_id,
            })
            fixture.write_json(
                "ios/project/capabilities/CAP-BOOT.json",
                capability,
            )
            ledger["revision"] = 2
            ledger["updated_by"] = item_id
            ledger["updated_at"] = "2026-07-23T00:00:00Z"
            ledger["entries"][0]["product_disposition"] = terminal_disposition
            fixture.write_json(ledger_path, ledger)
            fixture.write_json(
                f"ios/project/checkpoints/{item_id}.json",
                {
                    "schema_version": 1,
                    "work_item_id": item_id,
                    "summary": "验证产品范围审批两阶段关闭",
                    "evidence": evidence_relative,
                    "capability_updates": [{
                        "id": "CAP-BOOT",
                        "from_revision": 1,
                        "to_revision": 2,
                    }],
                    "architecture_impact": {
                        "kind": "implements_existing",
                        "adr_refs": ["ADR-0001"],
                    },
                    "requirements": {
                        "mode": "control_plane",
                        "refs": [],
                        "selection_sha256": evidence["inputs"][
                            "android_requirement_selection_sha256"
                        ],
                    },
                    "business_knowledge": {
                        "mode": "consume",
                        "claim_refs": [claim_ref],
                        "driver_refs": [],
                        "coverage_refs": coverage_refs,
                        "selection_sha256": evidence["inputs"][
                            "knowledge_selection_sha256"
                        ],
                        "coverage_selection_sha256": evidence["inputs"][
                            "coverage_selection_sha256"
                        ],
                        "architecture_driver_selection_sha256": evidence[
                            "inputs"
                        ]["architecture_driver_selection_sha256"],
                        "produced_refs": [],
                        "ledger_updates": transitions,
                        "none_reason": None,
                    },
                    "source_lab": {
                        "mode": "not_applicable",
                        "behaviors": [],
                        "scenarios": [],
                        "selection_sha256": evidence["inputs"][
                            "source_lab_selection_sha256"
                        ],
                    },
                    "compatibility": {
                        "records": [],
                        "none_reason": "没有跨端行为",
                    },
                    "pitfalls": {
                        "records": [],
                        "none_reason": "没有长期踩坑",
                    },
                    "remaining_risks": [],
                    "next_actions": [],
                    "created_at": "2026-07-23T00:00:00Z",
                },
            )

            self.assertFalse((root / approval_ref).exists())
            self.assertEqual("awaiting_human", harness.close(item_id))
            runtime = harness.state()["work_items"][item_id]
            self.assertTrue(runtime["review_subject_sha256"])
            self.assertTrue(any(
                "product-scope-review" in reason
                for reason in runtime["awaiting_human_reasons"]
            ))
            fixture.write_json(
                approval_ref,
                {
                    "schema_version": 1,
                    "work_item_id": item_id,
                    "gate": "product-scope-review",
                    "work_item_sha256": harness_module.sha256_json(item),
                    "tree_sha256": runtime["review_subject_sha256"],
                    "reviewer": "human-reviewer@example.invalid",
                    "approved_at": harness_module.utc_now(),
                    "expires_at": "2099-01-01T00:00:00Z",
                    "signature": None,
                },
            )
            self.assertEqual("completed", harness.close(item_id))


if __name__ == "__main__":
    unittest.main()
