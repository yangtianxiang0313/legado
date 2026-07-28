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
        digest = hashlib.sha256((self.root / relative).read_bytes()).hexdigest()
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


if __name__ == "__main__":
    unittest.main()
