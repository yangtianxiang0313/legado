import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_ROOT))

import demand_compiler  # noqa: E402


class OracleReceiptDigestRegressionTests(unittest.TestCase):
    def test_real_trusted_report_uses_canonical_manifest_digest(self):
        root = HARNESS_ROOT.parents[1]
        manifest = json.loads(
            (root / "ios/harness/source-lab/manifest.json").read_text()
        )
        report = json.loads(
            (
                root
                / ".harness-runtime/github-oracle/review-30403665320/"
                "trusted-import-report.json"
            ).read_text()
        )
        self.assertEqual(
            "00740e8da677684213116bce8b62efd15"
            "a5d3dabbccd9b51b51e210ee52c03f6",
            demand_compiler._sha256_json(manifest),
        )
        self.assertEqual(
            demand_compiler._sha256_json(manifest),
            report["source_lab_manifest_sha256"],
        )
        self.assertNotEqual(
            hashlib.sha256(
                (
                    root / "ios/harness/source-lab/manifest.json"
                ).read_bytes()
            ).hexdigest(),
            report["source_lab_manifest_sha256"],
        )


class DemandFixture:
    intent_id = "DINT-TEST-DELIVERY-001"
    target_id = "IOS-TEST-DELIVERY-001"
    requirement_id = "REQ-TEST-DELIVERY-001"
    capability_id = "CAP-TEST-DELIVERY"
    fixture_id = "fixture-001"
    packet_id = "BKP-TEST-DELIVERY-001"
    driver_id = "DRV-TEST-DELIVERY-001"

    def __init__(self, root: Path):
        self.root = root
        self.write_json(
            f"ios/project/capabilities/{self.capability_id}.json",
            {
                "id": self.capability_id,
                "revision": 2,
            },
        )
        self.requirement_record = {
            "id": self.requirement_id,
            "revision": 1,
            "status": "accepted",
            "clauses": [{"id": "RC-01"}],
            "readiness": {
                "state": "characterization_required",
                "blockers": ["missing protected golden"],
            },
        }
        self.write_requirement()
        self.write_json(
            demand_compiler.KNOWLEDGE_CATALOG,
            {
                "packets": [],
                "architecture_drivers": [],
                "proposals": [
                    {
                        "id": self.packet_id,
                        "revision": 1,
                        "path": "packet-proposal.json",
                        "sha256": "a" * 64,
                    },
                    {
                        "id": self.driver_id,
                        "revision": 1,
                        "path": "driver-proposal.json",
                        "sha256": "b" * 64,
                    },
                ],
            },
        )
        golden_relative = (
            "ios/harness/goldens/android-legado-v1/fixture-001.json"
        )
        golden_payload = b'{"result":"android"}'
        golden_path = root / golden_relative
        golden_path.parent.mkdir(parents=True, exist_ok=True)
        golden_path.write_bytes(golden_payload)
        golden_sha = hashlib.sha256(golden_payload).hexdigest()
        self.receipt_relative = (
            "ios/harness/goldens/releases/fixture-001-run.json"
        )
        self.write_json(
            self.receipt_relative,
            {
                "authority": "protected_android_golden",
                "authorization": "github_environment_review",
                "fixture_id": self.fixture_id,
                "golden_path": golden_relative,
                "golden_sha256": golden_sha,
                "run_id": "42/1",
                "source_digest": "c" * 40,
                "proposal_sha256": "d" * 64,
            },
        )
        self.write_json(
            demand_compiler.GOLDEN_MANIFEST,
            {
                "fixtures": {
                    self.fixture_id: {
                        "path": golden_relative,
                        "golden_sha256": golden_sha,
                        "release_receipt": self.receipt_relative,
                        "run_id": "42/1",
                        "source_digest": "c" * 40,
                        "proposal_sha256": "d" * 64,
                    }
                }
            },
        )
        self.intent_relative = (
            f"{demand_compiler.INTENT_ROOT}/{self.intent_id}.json"
        )
        self.write_json(
            self.intent_relative,
            {
                "schema_version": 1,
                "kind": "DeliveryIntent",
                "id": self.intent_id,
                "priority": 90,
                "target_work_item_id": self.target_id,
                "capability": {
                    "id": self.capability_id,
                    "revision": 2,
                },
                "requirements": [
                    {
                        "id": self.requirement_id,
                        "revision": 1,
                        "clauses": ["RC-01"],
                    }
                ],
                "knowledge": {
                    "packets": [
                        {"id": self.packet_id, "revision": 1}
                    ],
                    "drivers": [
                        {"id": self.driver_id, "revision": 1}
                    ],
                },
                "golden_fixtures": [self.fixture_id],
                "blueprint": (
                    f"{demand_compiler.DELIVERY_BLUEPRINT_ROOT}/"
                    f"{self.target_id}.json"
                ),
            },
        )
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Demand Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "demand@example.invalid"],
            cwd=root,
            check=True,
        )
        self.commit("initial")

    def write_json(self, relative: str, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def write_requirement(self):
        relative = (
            "ios/project/requirements/accepted/"
            f"{self.requirement_id}.json"
        )
        self.write_json(relative, self.requirement_record)
        digest = demand_compiler._sha256_json(self.requirement_record)
        self.write_json(
            demand_compiler.REQUIREMENT_CATALOG,
            {
                "requirements": [
                    {
                        "id": self.requirement_id,
                        "revision": 1,
                        "status": "accepted",
                        "readiness": self.requirement_record[
                            "readiness"
                        ]["state"],
                        "path": relative,
                        "record_sha256": digest,
                        "clauses": ["RC-01"],
                    }
                ]
            },
        )

    def commit(self, message: str):
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", message],
            cwd=self.root,
            check=True,
        )

    def compiler(self):
        return demand_compiler.DemandCompiler(self.root)

    def intent_path(self):
        return self.root / self.intent_relative

    def publish_knowledge(self):
        self.write_json(
            demand_compiler.KNOWLEDGE_CATALOG,
            {
                "packets": [
                    {
                        "id": self.packet_id,
                        "revision": 1,
                        "path": "packet.json",
                        "sha256": "a" * 64,
                    }
                ],
                "architecture_drivers": [
                    {
                        "id": self.driver_id,
                        "revision": 1,
                        "path": "driver.json",
                        "sha256": "b" * 64,
                    }
                ],
                "proposals": [],
            },
        )
        self.commit("publish knowledge")

    def make_requirement_ready(self):
        self.requirement_record["readiness"] = {
            "state": "implementation_ready",
            "blockers": [],
        }
        self.write_requirement()
        self.commit("requirement ready")

    def add_blueprint(self):
        self.write_json(
            (
                f"{demand_compiler.DELIVERY_BLUEPRINT_ROOT}/"
                f"{self.target_id}.json"
            ),
            {
                "kind": "WorkItem",
                "metadata": {"id": self.target_id},
            },
        )
        self.commit("add blueprint")

    def settle_delivery(self):
        self.publish_knowledge()
        self.make_requirement_ready()
        self.add_blueprint()
        capability = {
            "id": self.capability_id,
            "revision": 3,
        }
        self.write_json(
            f"ios/project/capabilities/{self.capability_id}.json",
            capability,
        )
        work_item = {
            "metadata": {"id": self.target_id},
            "spec": {
                "delivery_blueprint": {
                    "capability_revision": 2,
                    "golden_fixtures": [self.fixture_id],
                },
                "requirements": {
                    "mode": "implementation",
                    "refs": [
                        {
                            "id": self.requirement_id,
                            "revision": 1,
                            "clauses": ["RC-01"],
                        }
                    ],
                },
                "source_lab": {
                    "scenarios": [self.fixture_id],
                },
            },
        }
        work_item_relative = (
            f"{demand_compiler.WORK_ITEM_ROOT}/{self.target_id}.json"
        )
        self.write_json(work_item_relative, work_item)
        work_item_sha = demand_compiler._sha256_json(work_item)
        evidence_relative = (
            f"{demand_compiler.EVIDENCE_ROOT}/run-settled.json"
        )
        self.write_json(
            evidence_relative,
            {
                "work_item_id": self.target_id,
                "work_item_sha256": work_item_sha,
                "result": "passed",
            },
        )
        evidence_sha = hashlib.sha256(
            (self.root / evidence_relative).read_bytes()
        ).hexdigest()
        self.write_json(
            f"{demand_compiler.CHECKPOINT_ROOT}/{self.target_id}.json",
            {
                "work_item_id": self.target_id,
                "evidence": evidence_relative,
                "capability_updates": [
                    {
                        "id": self.capability_id,
                        "from_revision": 2,
                        "to_revision": 3,
                    }
                ],
                "requirements": {
                    "mode": "implementation",
                    "refs": work_item["spec"]["requirements"]["refs"],
                },
                "source_lab": {
                    "scenarios": [self.fixture_id],
                },
            },
        )
        self.write_json(
            demand_compiler.STATE_PATH,
            {
                "work_items": {
                    self.target_id: {
                        "status": "completed",
                        "work_item_sha256": work_item_sha,
                        "last_evidence": evidence_relative,
                        "last_evidence_sha256": evidence_sha,
                    }
                }
            },
        )
        self.commit("settle delivery")


class MigrationFixture:
    intent_id = "MINT-TEST-MIGRATION-001"
    target_id = "IOS-TEST-MIGRATION-001"
    characterization_id = "IOS-TEST-CHARACTERIZATION-001"
    oracle_id = "IOS-TEST-ORACLE-001"
    oracle_recovery_id = "IOS-TEST-ORACLE-RECOVERY-002"
    trusted_oracle_id = "IOS-TEST-TRUSTED-ORACLE-001"
    trusted_oracle_recovery_2_id = (
        "IOS-TEST-TRUSTED-ORACLE-RECOVERY-002"
    )
    trusted_oracle_recovery_3_id = (
        "IOS-TEST-TRUSTED-ORACLE-RECOVERY-003"
    )
    scenario_id = "sl-test-post-form-001"
    target_requirement_id = "REQ-TEST-MIGRATION-001"
    proposal_id = "ARQ-TEST-MIGRATION"
    capability_id = "CAP-TEST-MIGRATION"
    control_capability_id = "CAP-KNOWLEDGE-CONTROL"
    source_relative = "app/src/main/java/example/AnalyzeUrl.kt"

    def __init__(self, root: Path):
        self.root = root
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Migration Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "migration@example.invalid"],
            cwd=root,
            check=True,
        )
        source = root / self.source_relative
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("class AnalyzeUrl { fun post() = Unit }\n")
        self.write_json(
            demand_compiler.SOURCE_LAB_COVERAGE_POLICY,
            {
                "behaviors": [
                    {
                        "id": "transport.post-form",
                        "status": "planned",
                        "phase": 1,
                    }
                ]
            },
        )
        self.write_json(
            f"ios/project/capabilities/{self.capability_id}.json",
            {"id": self.capability_id, "revision": 3},
        )
        self.write_json(
            demand_compiler.REQUIREMENT_CATALOG,
            {"requirements": []},
        )
        self.write_json(
            (
                f"{demand_compiler.MIGRATION_BLUEPRINT_ROOT}/"
                f"{self.target_id}.json"
            ),
            {
                "api_version": "legado.harness/v1",
                "kind": "WorkItem",
                "metadata": {"id": self.target_id},
                "spec": {
                    "requirements": {"mode": "control_plane"},
                    "gates": [],
                },
            },
        )
        self.commit("android baseline")
        self.baseline_commit = self.git("rev-parse", "HEAD")
        self.source_blob = self.git(
            "rev-parse",
            f"HEAD:{self.source_relative}",
        )
        self.write_json(
            demand_compiler.BASELINE_PATH,
            {
                "android_oracle": {
                    "git_commit": self.baseline_commit,
                }
            },
        )
        self.intent_relative = (
            f"{demand_compiler.MIGRATION_INTENT_ROOT}/"
            f"{self.intent_id}.json"
        )
        self.write_json(self.intent_relative, self.intent())
        self.commit("migration control")

    def write_json(self, relative: str, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip()

    def commit(self, message: str):
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(
            ["git", "commit", "-qm", message],
            cwd=self.root,
            check=True,
        )

    def intent(self):
        return {
            "schema_version": 1,
            "kind": "AndroidMigrationIntent",
            "id": self.intent_id,
            "priority": 100,
            "phase": 1,
            "target_work_item_id": self.target_id,
            "capability": {
                "id": self.capability_id,
                "revision": 3,
            },
            "android_baseline": {"commit": self.baseline_commit},
            "source_anchors": [
                {
                    "path": self.source_relative,
                    "git_blob": self.source_blob,
                    "symbols": [
                        "kotlin://example/AnalyzeUrl/post",
                    ],
                }
            ],
            "source_lab": {
                "behavior": "transport.post-form",
                "expected_status": "planned",
            },
            "requirement_proposal": {
                "id": self.proposal_id,
                "target_requirement_id": self.target_requirement_id,
                "dedupe_key": (
                    f"{self.capability_id}/transport.post-form/test"
                ),
                "path": (
                    "ios/project/requirement-proposals/"
                    f"{self.proposal_id}.json"
                ),
            },
            "requirement_binding": {
                "id": self.target_requirement_id,
                "revision": 1,
                "clauses": ["RC-01"],
            },
            "intake_blueprint": (
                f"{demand_compiler.MIGRATION_BLUEPRINT_ROOT}/"
                f"{self.target_id}.json"
            ),
            "characterization_blueprint": (
                f"{demand_compiler.CHARACTERIZATION_BLUEPRINT_ROOT}/"
                f"{self.intent_id}.json"
            ),
            "oracle_blueprint": (
                f"{demand_compiler.ORACLE_BLUEPRINT_ROOT}/"
                f"{self.intent_id}.json"
            ),
        }

    def compiler(self):
        return demand_compiler.DemandCompiler(self.root)

    def intent_path(self):
        return self.root / self.intent_relative

    def settle(self):
        work_item = {
            "metadata": {"id": self.target_id},
            "spec": {
                "capability": self.control_capability_id,
                "requirements": {"mode": "control_plane"},
                "gates": [],
            },
        }
        work_item_relative = (
            f"{demand_compiler.WORK_ITEM_ROOT}/{self.target_id}.json"
        )
        self.write_json(work_item_relative, work_item)
        work_item_sha = demand_compiler._sha256_json(work_item)
        evidence_relative = (
            f"{demand_compiler.EVIDENCE_ROOT}/migration-settled.json"
        )
        self.write_json(
            evidence_relative,
            {
                "work_item_id": self.target_id,
                "work_item_sha256": work_item_sha,
                "result": "passed",
            },
        )
        evidence_sha = hashlib.sha256(
            (self.root / evidence_relative).read_bytes()
        ).hexdigest()
        self.write_json(
            f"{demand_compiler.CHECKPOINT_ROOT}/{self.target_id}.json",
            {
                "work_item_id": self.target_id,
                "evidence": evidence_relative,
                "capability_updates": [
                    {
                        "id": self.control_capability_id,
                        "from_revision": 10,
                        "to_revision": 11,
                    }
                ],
            },
        )
        self.write_json(
            (
                "ios/project/capabilities/"
                f"{self.control_capability_id}.json"
            ),
            {"id": self.control_capability_id, "revision": 11},
        )
        proposal = self.intent()["requirement_proposal"]
        self.write_json(
            proposal["path"],
            {
                "schema_version": 1,
                "id": self.proposal_id,
                "target_requirement_id": self.target_requirement_id,
                "status": "proposed",
                "dedupe_key": proposal["dedupe_key"],
                "source_facts": ["AF-TEST"],
                "unknowns": ["runner output"],
                "source_lab_gap": ["transport.post-form"],
                "auto_action": "create_characterization_dag",
            },
        )
        self.write_json(
            demand_compiler.STATE_PATH,
            {
                "work_items": {
                    self.target_id: {
                        "status": "completed",
                        "work_item_sha256": work_item_sha,
                        "last_evidence": evidence_relative,
                        "last_evidence_sha256": evidence_sha,
                    }
                }
            },
        )
        self.commit("settle migration")

    def accept_requirement(self, *, with_blueprint: bool):
        record_relative = (
            "ios/project/requirements/accepted/"
            f"{self.target_requirement_id}.json"
        )
        record = {
            "id": self.target_requirement_id,
            "revision": 1,
            "status": "accepted",
            "clauses": [{"id": "RC-01"}],
            "readiness": {"state": "implementation_ready"},
        }
        self.write_json(record_relative, record)
        self.write_json(
            demand_compiler.REQUIREMENT_CATALOG,
            {
                "requirements": [
                    {
                        "id": self.target_requirement_id,
                        "revision": 1,
                        "status": "accepted",
                        "clauses": ["RC-01"],
                        "path": record_relative,
                        "record_sha256": (
                            demand_compiler._sha256_json(record)
                        ),
                    }
                ]
            },
        )
        if with_blueprint:
            self.write_json(
                self.intent()["characterization_blueprint"],
                {
                    "api_version": "legado.harness/v1",
                    "kind": "WorkItem",
                    "metadata": {"id": self.characterization_id},
                    "spec": {
                        "requirements": {
                            "mode": "characterization",
                            "refs": [
                                self.intent()["requirement_binding"]
                            ],
                        },
                        "source_lab": {"mode": "extend"},
                    },
                },
            )
        self.commit("accept migration requirement")

    def settle_characterization(self):
        work_item = {
            "api_version": "legado.harness/v1",
            "kind": "WorkItem",
            "metadata": {"id": self.characterization_id},
            "spec": {
                "capability": "CAP-CONFORMANCE",
                "requirements": {
                    "mode": "characterization",
                    "refs": [self.intent()["requirement_binding"]],
                },
                "source_lab": {
                    "mode": "extend",
                    "behaviors": ["transport.post-form"],
                    "scenarios": [self.scenario_id],
                },
                "gates": ["scenario-provenance-review"],
            },
        }
        self.write_json(
            self.intent()["characterization_blueprint"],
            work_item,
        )
        work_item_relative = (
            f"{demand_compiler.WORK_ITEM_ROOT}/"
            f"{self.characterization_id}.json"
        )
        self.write_json(work_item_relative, work_item)
        work_item_sha = demand_compiler._sha256_json(work_item)
        evidence_relative = (
            f"{demand_compiler.EVIDENCE_ROOT}/"
            "characterization-settled.json"
        )
        evidence = {
            "work_item_id": self.characterization_id,
            "work_item_sha256": work_item_sha,
            "result": "passed",
            "inputs": {
                "android_requirement_selection_sha256": "r" * 64,
                "source_lab_selection_sha256": "s" * 64,
            },
        }
        self.write_json(evidence_relative, evidence)
        evidence_sha = hashlib.sha256(
            (self.root / evidence_relative).read_bytes()
        ).hexdigest()
        checkpoint_relative = (
            f"{demand_compiler.CHECKPOINT_ROOT}/"
            f"{self.characterization_id}.json"
        )
        self.write_json(
            checkpoint_relative,
            {
                "work_item_id": self.characterization_id,
                "evidence": evidence_relative,
                "capability_updates": [
                    {
                        "id": "CAP-CONFORMANCE",
                        "from_revision": 4,
                        "to_revision": 5,
                    }
                ],
                "requirements": {
                    **work_item["spec"]["requirements"],
                    "selection_sha256": "r" * 64,
                },
                "source_lab": {
                    **work_item["spec"]["source_lab"],
                    "selection_sha256": "s" * 64,
                },
            },
        )
        self.write_json(
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            {"id": "CAP-CONFORMANCE", "revision": 5},
        )
        self.write_json(
            demand_compiler.SOURCE_LAB_MANIFEST,
            {
                "scenarios": [
                    {
                        "id": self.scenario_id,
                        "status": "candidate",
                        "path": (
                            "ios/harness/fixtures/source-lab/"
                            f"{self.scenario_id}"
                        ),
                        "sha256": "f" * 64,
                    }
                ]
            },
        )
        state = json.loads(
            (self.root / demand_compiler.STATE_PATH).read_text()
        )
        state["work_items"][self.characterization_id] = {
            "status": "completed",
            "work_item_sha256": work_item_sha,
            "last_evidence": evidence_relative,
            "last_evidence_sha256": evidence_sha,
        }
        self.write_json(demand_compiler.STATE_PATH, state)
        self.commit("settle characterization")

    def write_oracle_blueprint(self):
        self.write_json(
            self.intent()["oracle_blueprint"],
            {
                "api_version": "legado.harness/v1",
                "kind": "WorkItem",
                "metadata": {"id": self.oracle_id},
                "spec": {
                    "capability": "CAP-CONFORMANCE",
                    "depends_on": [self.characterization_id],
                    "requirements": {
                        "mode": "characterization",
                        "refs": [
                            self.intent()["requirement_binding"]
                        ],
                    },
                    "source_lab": {
                        "mode": "reuse",
                        "behaviors": ["transport.post-form"],
                        "scenarios": [self.scenario_id],
                    },
                    "gates": [],
                },
            },
        )
        self.commit("add oracle blueprint")

    def settle_oracle(self, *, recovery: bool):
        oracle_relative = self.intent()["oracle_blueprint"]
        oracle = json.loads(
            (self.root / oracle_relative).read_text()
        )
        original_relative = (
            f"{demand_compiler.WORK_ITEM_ROOT}/{self.oracle_id}.json"
        )
        self.write_json(original_relative, oracle)
        original_sha = demand_compiler._sha256_json(oracle)
        state = json.loads(
            (self.root / demand_compiler.STATE_PATH).read_text()
        )

        if recovery:
            resolved_id = self.oracle_recovery_id
            resolved = {
                "api_version": "legado.harness/v1",
                "kind": "WorkItem",
                "metadata": {"id": resolved_id},
                "spec": {
                    "capability": "CAP-CONFORMANCE",
                    "recovers": self.oracle_id,
                    "depends_on": [self.characterization_id],
                    "requirements": {
                        "mode": "control_plane",
                        "refs": [],
                        "none_reason": "test recovery",
                    },
                    "source_lab": oracle["spec"]["source_lab"],
                    "gates": [],
                },
            }
            self.write_json(
                (
                    f"{demand_compiler.WORK_ITEM_ROOT}/"
                    f"{resolved_id}.json"
                ),
                resolved,
            )
            state["work_items"][self.oracle_id] = {
                "status": "exhausted",
                "work_item_sha256": original_sha,
                "android_requirement_selection_sha256": "r" * 64,
                "replacement": resolved_id,
            }
            checkpoint_requirements = {
                "mode": "control_plane",
                "refs": [],
                "selection_sha256": None,
            }
            evidence_requirement_selection = None
        else:
            resolved_id = self.oracle_id
            resolved = oracle
            checkpoint_requirements = {
                **oracle["spec"]["requirements"],
                "selection_sha256": "r" * 64,
            }
            evidence_requirement_selection = "r" * 64

        resolved_sha = demand_compiler._sha256_json(resolved)
        evidence_relative = (
            f"{demand_compiler.EVIDENCE_ROOT}/"
            f"oracle-{resolved_id.lower()}-settled.json"
        )
        evidence = {
            "work_item_id": resolved_id,
            "work_item_sha256": resolved_sha,
            "result": "passed",
            "inputs": {
                "android_requirement_selection_sha256": (
                    evidence_requirement_selection
                ),
                "source_lab_selection_sha256": "t" * 64,
            },
        }
        self.write_json(evidence_relative, evidence)
        evidence_sha = hashlib.sha256(
            (self.root / evidence_relative).read_bytes()
        ).hexdigest()
        checkpoint = {
            "work_item_id": resolved_id,
            "evidence": evidence_relative,
            "capability_updates": [
                {
                    "id": "CAP-CONFORMANCE",
                    "from_revision": 5,
                    "to_revision": 6,
                }
            ],
            "requirements": checkpoint_requirements,
            "source_lab": {
                **oracle["spec"]["source_lab"],
                "selection_sha256": "t" * 64,
            },
        }
        if recovery:
            checkpoint["recovery"] = {
                "predecessor": self.oracle_id,
            }
        self.write_json(
            (
                f"{demand_compiler.CHECKPOINT_ROOT}/"
                f"{resolved_id}.json"
            ),
            checkpoint,
        )
        self.write_json(
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            {"id": "CAP-CONFORMANCE", "revision": 6},
        )
        state["work_items"][resolved_id] = {
            "status": "completed",
            "work_item_sha256": resolved_sha,
            "last_evidence": evidence_relative,
            "last_evidence_sha256": evidence_sha,
            "android_requirement_selection_sha256": (
                "r" * 64 if not recovery else None
            ),
        }
        if not recovery:
            state["work_items"][self.oracle_id][
                "android_requirement_selection_sha256"
            ] = "r" * 64
        self.write_json(demand_compiler.STATE_PATH, state)
        self.commit("settle oracle")

    def write_trusted_oracle_blueprint(self, *, depends_on: str):
        relative = (
            f"{demand_compiler.TRUSTED_ORACLE_BLUEPRINT_ROOT}/"
            f"{self.intent_id}.json"
        )
        self.write_json(
            relative,
            {
                "api_version": "legado.harness/v1",
                "kind": "WorkItem",
                "metadata": {"id": self.trusted_oracle_id},
                "spec": {
                    "capability": "CAP-CONFORMANCE",
                    "depends_on": [depends_on],
                    "requirements": {
                        "mode": "characterization",
                        "refs": [
                            self.intent()["requirement_binding"]
                        ],
                    },
                    "source_lab": {
                        "mode": "reuse",
                        "behaviors": ["transport.post-form"],
                        "scenarios": [self.scenario_id],
                    },
                    "gates": [],
                },
            },
        )
        self.commit("add trusted oracle blueprint")

    def settle_trusted_oracle(self, *, recovery: bool):
        blueprint_relative = (
            f"{demand_compiler.TRUSTED_ORACLE_BLUEPRINT_ROOT}/"
            f"{self.intent_id}.json"
        )
        original = json.loads(
            (self.root / blueprint_relative).read_text()
        )
        original_relative = (
            f"{demand_compiler.WORK_ITEM_ROOT}/"
            f"{self.trusted_oracle_id}.json"
        )
        self.write_json(original_relative, original)
        state = json.loads(
            (self.root / demand_compiler.STATE_PATH).read_text()
        )
        chain = [self.trusted_oracle_id]
        resolved = original
        if recovery:
            prior = self.trusted_oracle_id
            for item_id in (
                self.trusted_oracle_recovery_2_id,
                self.trusted_oracle_recovery_3_id,
            ):
                resolved = {
                    "api_version": "legado.harness/v1",
                    "kind": "WorkItem",
                    "metadata": {"id": item_id},
                    "spec": {
                        "capability": "CAP-CONFORMANCE",
                        "recovers": prior,
                        "depends_on": original["spec"]["depends_on"],
                        "requirements": {
                            "mode": "control_plane",
                            "refs": [],
                            "none_reason": "test recovery",
                        },
                        "source_lab": original["spec"]["source_lab"],
                        "gates": [],
                    },
                }
                self.write_json(
                    f"{demand_compiler.WORK_ITEM_ROOT}/{item_id}.json",
                    resolved,
                )
                state["work_items"][prior] = {
                    "status": "rejected",
                    "work_item_sha256": demand_compiler._sha256_json(
                        (
                            original
                            if prior == self.trusted_oracle_id
                            else json.loads(
                                (
                                    self.root
                                    / demand_compiler.WORK_ITEM_ROOT
                                    / f"{prior}.json"
                                ).read_text()
                            )
                        )
                    ),
                }
                if prior == self.trusted_oracle_id:
                    state["work_items"][prior][
                        "android_requirement_selection_sha256"
                    ] = "r" * 64
                if prior == self.trusted_oracle_recovery_2_id:
                    state["work_items"][prior][
                        "replacement"
                    ] = item_id
                chain.append(item_id)
                prior = item_id
        resolved_id = chain[-1]
        resolved_sha = demand_compiler._sha256_json(resolved)
        evidence_relative = (
            f"{demand_compiler.EVIDENCE_ROOT}/trusted-settled.json"
        )
        evidence = {
            "work_item_id": resolved_id,
            "work_item_sha256": resolved_sha,
            "result": "passed",
            "inputs": {
                "android_requirement_selection_sha256": (
                    None if recovery else "r" * 64
                ),
                "source_lab_selection_sha256": "u" * 64,
                "business_knowledge_control_sha256": "c" * 64,
                "business_knowledge_authority_sha256": "a" * 64,
            },
        }
        self.write_json(evidence_relative, evidence)
        evidence_sha = hashlib.sha256(
            (self.root / evidence_relative).read_bytes()
        ).hexdigest()
        requirements = (
            resolved["spec"]["requirements"]
        )
        checkpoint = {
            "work_item_id": resolved_id,
            "evidence": evidence_relative,
            "capability_updates": [
                {
                    "id": "CAP-CONFORMANCE",
                    "from_revision": 18,
                    "to_revision": 19,
                }
            ],
            "requirements": {
                **requirements,
                "selection_sha256": (
                    None if recovery else "r" * 64
                ),
            },
            "source_lab": {
                **original["spec"]["source_lab"],
                "selection_sha256": "u" * 64,
            },
        }
        if recovery:
            checkpoint["recovery"] = {
                "predecessor": chain[-2],
            }
        self.write_json(
            f"{demand_compiler.CHECKPOINT_ROOT}/{resolved_id}.json",
            checkpoint,
        )
        self.write_json(
            "ios/project/capabilities/CAP-CONFORMANCE.json",
            {"id": "CAP-CONFORMANCE", "revision": 19},
        )
        state["work_items"][resolved_id] = {
            "status": "completed",
            "work_item_sha256": resolved_sha,
            "last_evidence": evidence_relative,
            "last_evidence_sha256": evidence_sha,
        }
        state["work_items"][self.trusted_oracle_id][
            "android_requirement_selection_sha256"
        ] = "r" * 64
        self.write_json(demand_compiler.STATE_PATH, state)
        contract = self.root / demand_compiler.ORACLE_CONTRACT_PATH
        contract.parent.mkdir(parents=True, exist_ok=True)
        contract.write_text(
            "def verify_proposal(*args, **kwargs):\n    return {}\n"
        )
        for relative, function in (
            (demand_compiler.ORACLE_CI_PROPOSAL_PATH, "finalize"),
            (demand_compiler.ORACLE_TRUSTED_IMPORT_PATH, "verify"),
        ):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "from oracle.contract import verify_proposal\n\n"
                f"def {function}(*args, **kwargs):\n"
                "    return verify_proposal(*args, **kwargs)\n"
            )
        workflow = self.root / demand_compiler.TRUSTED_ORACLE_WORKFLOW
        workflow.parent.mkdir(parents=True, exist_ok=True)
        workflow.write_text(
            "run: python3 ios/harness/oracle/ci_proposal.py finalize\n"
        )
        self.commit("settle trusted oracle")
        return chain


class DemandCompilerTests(unittest.TestCase):
    def test_compiles_shortest_authority_and_delivery_chain(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            compiler = fixture.compiler()

            plan = compiler.compile(fixture.intent_path())
            self.assertEqual("knowledge_authority_required", plan.state)
            self.assertEqual("KNOWLEDGE_AUTHORITY_REQUIRED", plan.reason_code)
            self.assertTrue(plan.authority_transition)
            self.assertEqual(
                ["proposal_only", "proposal_only"],
                [
                    artifact["status"]
                    for artifact in plan.artifacts
                    if artifact["kind"] == "business_knowledge"
                ],
            )

            fixture.publish_knowledge()
            plan = compiler.compile(fixture.intent_path())
            self.assertEqual("requirement_readiness_required", plan.state)
            self.assertTrue(plan.authority_transition)

            fixture.make_requirement_ready()
            plan = compiler.compile(fixture.intent_path())
            self.assertEqual("blueprint_required", plan.state)
            self.assertFalse(plan.authority_transition)

            fixture.add_blueprint()
            plan = compiler.compile(fixture.intent_path())
            self.assertEqual("delivery_ready", plan.state)
            self.assertEqual("DELIVERY_INPUTS_READY", plan.reason_code)

    def test_receipt_tamper_and_uncommitted_intent_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            receipt = json.loads(
                (fixture.root / fixture.receipt_relative).read_text()
            )
            receipt["authority"] = "candidate_only"
            fixture.write_json(fixture.receipt_relative, receipt)
            fixture.commit("tamper receipt")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "GOLDEN_RECEIPT_DRIFT",
            ):
                fixture.compiler().compile(fixture.intent_path())

        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            fixture.requirement_record["status"] = "superseded"
            relative = (
                "ios/project/requirements/accepted/"
                f"{fixture.requirement_id}.json"
            )
            fixture.write_json(relative, fixture.requirement_record)
            fixture.commit("semantic requirement drift")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "REQUIREMENT_RECORD_DRIFT",
            ):
                fixture.compiler().compile(fixture.intent_path())

        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            intent = json.loads(fixture.intent_path().read_text())
            intent["priority"] = 91
            fixture.write_json(fixture.intent_relative, intent)
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "DEMAND_INPUT_HEAD_DRIFT",
            ):
                fixture.compiler().compile(fixture.intent_path())

    def test_rejects_duplicate_selectors_and_blueprint_identity_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            intent = json.loads(fixture.intent_path().read_text())
            intent["golden_fixtures"].append(fixture.fixture_id)
            fixture.write_json(fixture.intent_relative, intent)
            fixture.commit("duplicate fixture")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "INTENT_GOLDEN_SELECTOR_INVALID",
            ):
                fixture.compiler().compile(fixture.intent_path())

        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            fixture.publish_knowledge()
            fixture.make_requirement_ready()
            fixture.write_json(
                (
                    f"{demand_compiler.DELIVERY_BLUEPRINT_ROOT}/"
                    f"{fixture.target_id}.json"
                ),
                {
                    "kind": "WorkItem",
                    "metadata": {"id": "IOS-WRONG-001"},
                },
            )
            fixture.commit("wrong blueprint")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "DELIVERY_BLUEPRINT_IDENTITY_INVALID",
            ):
                fixture.compiler().compile(fixture.intent_path())

    def test_completed_delivery_is_evidence_settled_after_capability_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            fixture.settle_delivery()

            plan = fixture.compiler().compile(fixture.intent_path())

            self.assertEqual("delivery_completed", plan.state)
            self.assertEqual("DELIVERY_EVIDENCE_SETTLED", plan.reason_code)
            self.assertEqual(
                3,
                plan.bindings["settlement"]["to_revision"],
            )

    def test_completed_delivery_with_tampered_checkpoint_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = DemandFixture(Path(directory))
            fixture.settle_delivery()
            checkpoint = (
                fixture.root
                / demand_compiler.CHECKPOINT_ROOT
                / f"{fixture.target_id}.json"
            )
            value = json.loads(checkpoint.read_text())
            value["capability_updates"][0]["to_revision"] = 2
            fixture.write_json(
                str(checkpoint.relative_to(fixture.root)),
                value,
            )
            fixture.commit("tamper settlement")

            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "DELIVERY_SETTLEMENT_INVALID",
            ):
                fixture.compiler().compile(fixture.intent_path())

    def test_compiles_source_anchored_migration_intake(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))

            plan = fixture.compiler().compile_migration(
                fixture.intent_path()
            )

            self.assertEqual("migration_intake_ready", plan.state)
            self.assertEqual(
                demand_compiler.MIGRATION_POLICY,
                plan.policy,
            )
            self.assertEqual("android_migration", plan.intent_kind)
            self.assertEqual(
                fixture.source_blob,
                plan.bindings["sources"][0]["git_blob"],
            )
            self.assertEqual(
                "transport.post-form",
                plan.artifacts[0]["id"],
            )

    def test_migration_source_and_coverage_drift_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            intent = fixture.intent()
            intent["source_anchors"][0]["git_blob"] = "f" * 40
            fixture.write_json(fixture.intent_relative, intent)
            fixture.commit("wrong source blob")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "MIGRATION_SOURCE_BLOB_DRIFT",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.write_json(
                demand_compiler.SOURCE_LAB_COVERAGE_POLICY,
                {
                    "behaviors": [
                        {
                            "id": "transport.post-form",
                            "status": "active",
                            "phase": 1,
                        }
                    ]
                },
            )
            fixture.commit("coverage drift")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "MIGRATION_BEHAVIOR_BINDING_DRIFT",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

    def test_migration_settlement_requires_exact_evidence_and_proposal(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()

            plan = fixture.compiler().compile_migration(
                fixture.intent_path()
            )

            self.assertEqual("requirement_authority_required", plan.state)
            self.assertTrue(plan.authority_transition)

            proposal_path = (
                fixture.root
                / fixture.intent()["requirement_proposal"]["path"]
            )
            proposal = json.loads(proposal_path.read_text())
            proposal["dedupe_key"] = "tampered"
            fixture.write_json(
                str(proposal_path.relative_to(fixture.root)),
                proposal,
            )
            fixture.commit("tamper proposal")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "MIGRATION_SETTLEMENT_INVALID",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

    def test_migration_reuses_accepted_requirement_for_characterization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()
            fixture.accept_requirement(with_blueprint=False)

            missing = fixture.compiler().compile_migration(
                fixture.intent_path()
            )
            self.assertEqual(
                "characterization_blueprint_required",
                missing.state,
            )
            self.assertEqual(fixture.target_id, missing.target_work_item_id)

            fixture.accept_requirement(with_blueprint=True)
            ready = fixture.compiler().compile_migration(
                fixture.intent_path()
            )
            self.assertEqual("characterization_ready", ready.state)
            self.assertEqual(
                fixture.characterization_id,
                ready.target_work_item_id,
            )
            self.assertEqual(
                "REQ-TEST-MIGRATION-001",
                next(
                    artifact
                    for artifact in ready.artifacts
                    if artifact["kind"] == "requirement"
                )["id"],
            )

    def test_completed_characterization_compiles_oracle_dag(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()
            fixture.accept_requirement(with_blueprint=True)
            fixture.settle_characterization()

            missing = fixture.compiler().compile_migration(
                fixture.intent_path()
            )
            self.assertEqual(
                "oracle_blueprint_required",
                missing.state,
            )
            self.assertEqual(
                fixture.characterization_id,
                missing.target_work_item_id,
            )

            fixture.write_oracle_blueprint()
            ready = fixture.compiler().compile_migration(
                fixture.intent_path()
            )
            self.assertEqual("oracle_ready", ready.state)
            self.assertEqual(
                fixture.oracle_id,
                ready.target_work_item_id,
            )
            self.assertEqual(
                fixture.scenario_id,
                next(
                    artifact
                    for artifact in ready.artifacts
                    if artifact["kind"] == "source_lab_scenario"
                )["id"],
            )

    def test_completed_oracle_compiles_trusted_proposal_dag(self):
        for recovery in (False, True):
            with self.subTest(recovery=recovery):
                with tempfile.TemporaryDirectory() as directory:
                    fixture = MigrationFixture(Path(directory))
                    fixture.settle()
                    fixture.accept_requirement(with_blueprint=True)
                    fixture.settle_characterization()
                    fixture.write_oracle_blueprint()
                    fixture.settle_oracle(recovery=recovery)

                    missing = fixture.compiler().compile_migration(
                        fixture.intent_path()
                    )
                    self.assertEqual(
                        "trusted_oracle_blueprint_required",
                        missing.state,
                    )
                    expected_dependency = (
                        fixture.oracle_recovery_id
                        if recovery
                        else fixture.oracle_id
                    )
                    self.assertEqual(
                        expected_dependency,
                        missing.target_work_item_id,
                    )
                    settlement = missing.bindings[
                        "oracle_settlement"
                    ]
                    self.assertEqual(
                        expected_dependency,
                        settlement["resolved_work_item_id"],
                    )
                    self.assertEqual(
                        (
                            [
                                fixture.oracle_id,
                                fixture.oracle_recovery_id,
                            ]
                            if recovery
                            else [fixture.oracle_id]
                        ),
                        settlement["recovery_chain"],
                    )

                    fixture.write_trusted_oracle_blueprint(
                        depends_on=expected_dependency
                    )
                    ready = fixture.compiler().compile_migration(
                        fixture.intent_path()
                    )
                    self.assertEqual(
                        "trusted_oracle_ready",
                        ready.state,
                    )
                    self.assertEqual(
                        fixture.trusted_oracle_id,
                        ready.target_work_item_id,
                    )

                    chain = fixture.settle_trusted_oracle(
                        recovery=recovery
                    )
                    execution = (
                        fixture.compiler().compile_migration(
                            fixture.intent_path()
                        )
                    )
                    self.assertEqual(
                        "trusted_oracle_execution_required",
                        execution.state,
                    )
                    self.assertEqual(
                        "TRUSTED_ORACLE_GITHUB_EXECUTION_REQUIRED",
                        execution.reason_code,
                    )
                    self.assertEqual(
                        chain[-1],
                        execution.target_work_item_id,
                    )
                    settlement = execution.bindings[
                        "trusted_oracle_settlement"
                    ]
                    self.assertEqual(
                        chain,
                        settlement["recovery_chain"],
                    )
                    self.assertEqual(
                        {
                            "from_revision": 18,
                            "to_revision": 19,
                            "current_capability_revision": 19,
                        },
                        {
                            key: settlement[key]
                            for key in (
                                "from_revision",
                                "to_revision",
                                "current_capability_revision",
                            )
                        },
                    )
                    self.assertEqual(
                        None,
                        execution.bindings[
                            "trusted_oracle_execution"
                        ]["receipt"],
                    )

    def test_trusted_oracle_live_capability_revision_is_monotonic(self):
        for revision in (19, 20, 21, 42):
            with self.subTest(revision=revision):
                with tempfile.TemporaryDirectory() as directory:
                    fixture = MigrationFixture(Path(directory))
                    fixture.settle()
                    fixture.accept_requirement(with_blueprint=True)
                    fixture.settle_characterization()
                    fixture.write_oracle_blueprint()
                    fixture.settle_oracle(recovery=False)
                    fixture.write_trusted_oracle_blueprint(
                        depends_on=fixture.oracle_id
                    )
                    fixture.settle_trusted_oracle(recovery=False)
                    fixture.write_json(
                        "ios/project/capabilities/"
                        "CAP-CONFORMANCE.json",
                        {
                            "id": "CAP-CONFORMANCE",
                            "revision": revision,
                        },
                    )
                    if revision != 19:
                        fixture.commit("advance live capability")

                    plan = fixture.compiler().compile_migration(
                        fixture.intent_path()
                    )
                    settlement = plan.bindings[
                        "trusted_oracle_settlement"
                    ]
                    self.assertEqual(
                        "trusted_oracle_execution_required",
                        plan.state,
                    )
                    self.assertEqual(18, settlement["from_revision"])
                    self.assertEqual(19, settlement["to_revision"])
                    self.assertEqual(
                        revision,
                        settlement["current_capability_revision"],
                    )

    def test_trusted_oracle_invalid_live_capability_fails_closed(self):
        invalid_capabilities = (
            {"id": "CAP-CONFORMANCE", "revision": 18},
            {"id": "CAP-CONFORMANCE"},
            {"id": "CAP-CONFORMANCE", "revision": True},
            {"id": "CAP-CONFORMANCE", "revision": "21"},
            {"id": "CAP-OTHER", "revision": 21},
        )
        for capability in invalid_capabilities:
            with self.subTest(capability=capability):
                with tempfile.TemporaryDirectory() as directory:
                    fixture = MigrationFixture(Path(directory))
                    fixture.settle()
                    fixture.accept_requirement(with_blueprint=True)
                    fixture.settle_characterization()
                    fixture.write_oracle_blueprint()
                    fixture.settle_oracle(recovery=False)
                    fixture.write_trusted_oracle_blueprint(
                        depends_on=fixture.oracle_id
                    )
                    fixture.settle_trusted_oracle(recovery=False)
                    fixture.write_json(
                        "ios/project/capabilities/"
                        "CAP-CONFORMANCE.json",
                        capability,
                    )
                    fixture.commit("invalidate live capability")

                    with self.assertRaisesRegex(
                        demand_compiler.DemandCompilerError,
                        (
                            "(TRUSTED_ORACLE|CHARACTERIZATION)_"
                            "SETTLEMENT_INVALID"
                        ),
                    ):
                        fixture.compiler().compile_migration(
                            fixture.intent_path()
                        )

    def test_oracle_recovery_chain_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()
            fixture.accept_requirement(with_blueprint=True)
            fixture.settle_characterization()
            fixture.write_oracle_blueprint()
            fixture.settle_oracle(recovery=True)
            state_path = fixture.root / demand_compiler.STATE_PATH
            state = json.loads(state_path.read_text())
            state["work_items"][fixture.oracle_id][
                "replacement"
            ] = fixture.oracle_id
            fixture.write_json(demand_compiler.STATE_PATH, state)
            fixture.commit("cycle oracle recovery")

            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "ORACLE_SETTLEMENT_RECOVERY_CYCLE",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

    def test_trusted_oracle_ambiguous_recovery_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()
            fixture.accept_requirement(with_blueprint=True)
            fixture.settle_characterization()
            fixture.write_oracle_blueprint()
            fixture.settle_oracle(recovery=True)
            fixture.write_trusted_oracle_blueprint(
                depends_on=fixture.oracle_recovery_id
            )
            fixture.settle_trusted_oracle(recovery=True)
            competing_id = (
                "IOS-TEST-TRUSTED-ORACLE-RECOVERY-ALT-002"
            )
            original = json.loads(
                (
                    fixture.root
                    / demand_compiler.WORK_ITEM_ROOT
                    / f"{fixture.trusted_oracle_recovery_2_id}.json"
                ).read_text()
            )
            original["metadata"]["id"] = competing_id
            original["spec"]["recovers"] = fixture.trusted_oracle_id
            fixture.write_json(
                f"{demand_compiler.WORK_ITEM_ROOT}/{competing_id}.json",
                original,
            )
            state_path = fixture.root / demand_compiler.STATE_PATH
            state = json.loads(state_path.read_text())
            state["work_items"][competing_id] = {
                "status": "rejected",
                "work_item_sha256": (
                    demand_compiler._sha256_json(original)
                ),
            }
            fixture.write_json(demand_compiler.STATE_PATH, state)
            fixture.commit("add ambiguous recovery")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "TRUSTED_ORACLE_SETTLEMENT_INVALID",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

    def test_trusted_oracle_contract_authority_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()
            fixture.accept_requirement(with_blueprint=True)
            fixture.settle_characterization()
            fixture.write_oracle_blueprint()
            fixture.settle_oracle(recovery=False)
            fixture.write_trusted_oracle_blueprint(
                depends_on=fixture.oracle_id
            )
            fixture.settle_trusted_oracle(recovery=False)
            path = fixture.root / demand_compiler.ORACLE_CI_PROPOSAL_PATH
            path.write_text(
                "def finalize(*args, **kwargs):\n    return {}\n"
            )
            fixture.commit("bypass shared contract")
            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "TRUSTED_ORACLE_SETTLEMENT_INVALID",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

    def test_migration_requirement_clause_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            fixture.settle()
            fixture.accept_requirement(with_blueprint=True)
            intent = fixture.intent()
            intent["requirement_binding"]["clauses"] = ["RC-02"]
            fixture.write_json(fixture.intent_relative, intent)
            fixture.commit("drift requirement clause")

            with self.assertRaisesRegex(
                demand_compiler.DemandCompilerError,
                "MIGRATION_REQUIREMENT_AUTHORITY_INVALID",
            ):
                fixture.compiler().compile_migration(
                    fixture.intent_path()
                )

    def test_plans_include_migration_and_invalid_items_block(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MigrationFixture(Path(directory))
            plans, blockers = fixture.compiler().plans()
            self.assertEqual([], list(blockers))
            self.assertEqual([fixture.intent_id], [
                plan.intent_id for plan in plans
            ])

            intent = fixture.intent()
            intent["source_anchors"][0]["git_blob"] = "e" * 40
            fixture.write_json(fixture.intent_relative, intent)
            fixture.commit("invalidate migration")
            plans, blockers = fixture.compiler().plans()
            self.assertEqual([], list(plans))
            self.assertEqual("android_migration", blockers[0]["intent_kind"])
            self.assertIn(
                "MIGRATION_SOURCE_BLOB_DRIFT",
                blockers[0]["reason_code"],
            )


if __name__ == "__main__":
    unittest.main()
