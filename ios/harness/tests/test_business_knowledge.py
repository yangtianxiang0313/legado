from __future__ import annotations

import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CONTROL_SOURCE = Path(__file__).resolve().parents[1] / "business-knowledge"
REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(CONTROL_SOURCE))

import business_knowledge as knowledge  # noqa: E402


ANDROID_COMMIT = "a" * 40
INVENTORY_CONTROL = "b" * 64
FACT_REVISION = "c" * 64
CREATOR = "IOS-TEST-KNOWLEDGE-001"
PACKET_ID = "BKP-TEST-DOMAIN-001"
BASE_CLAIM_ID = "BKC-TEST-BASE-001"
DEPENDENT_CLAIM_ID = "BKC-TEST-DEPENDENT-002"
DRIVER_ID = "DRV-TEST-ARCH-001"
LEDGER_ID = "BKL-TEST-DOMAIN-001"


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


class BusinessKnowledgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        shutil.copytree(
            CONTROL_SOURCE,
            self.root / "ios/harness/business-knowledge",
            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
        )
        write_json(
            self.root / "ios/project/baseline.json",
            {
                "android_oracle": {"git_commit": ANDROID_COMMIT},
                "architecture": {"digest": "e" * 64},
            },
        )
        write_json(
            self.root / "ios/project/requirements/catalog.json",
            {"schema_version": 1, "requirements": []},
        )
        write_json(
            self.root / "ios/project/android-intake/inventory-manifest.json",
            {
                "control_sha256": INVENTORY_CONTROL,
                "facts": [
                    {
                        "id": "AF-TEST-FACT",
                        "revision_sha256": FACT_REVISION,
                    }
                ],
            },
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def claim(
        claim_id: str,
        semantic_key: str,
        depends_on: list[dict[str, object]],
    ) -> dict[str, object]:
        return {
            "id": claim_id,
            "revision": 1,
            "semantic_key": semantic_key,
            "kind": "business_inference",
            "topic": "测试领域",
            "statement": f"{claim_id} 的稳定业务陈述",
            "subject_keys": ["test.subject"],
            "depends_on": depends_on,
            "support": {
                "state": "static_supported",
                "fact_refs": [
                    {
                        "id": "AF-TEST-FACT",
                        "revision_sha256": FACT_REVISION,
                    }
                ],
                "source_anchors": [],
                "runtime_evidence": [],
                "runtime_requirement": "none",
            },
            "conflicts_with": [],
            "supersedes": None,
        }

    def packet(
        self,
        *,
        status: str = "published",
        creator: str = CREATOR,
        revision: int = 1,
    ) -> dict[str, object]:
        return {
            "schema_version": 1,
            "kind": "BusinessKnowledgePacket",
            "id": PACKET_ID,
            "revision": revision,
            "status": status,
            "semantic_key": "test.domain",
            "title": "测试领域知识",
            "baseline": {
                "android_commit": ANDROID_COMMIT,
                "inventory_control_sha256": INVENTORY_CONTROL,
            },
            "scope": {
                "bounded_contexts": ["test.domain"],
                "capability_refs": [],
                "subject_keys": ["test.subject"],
            },
            "claims": [
                self.claim(BASE_CLAIM_ID, "test.base", []),
                self.claim(
                    DEPENDENT_CLAIM_ID,
                    "test.dependent",
                    [{"id": BASE_CLAIM_ID, "revision": 1}],
                ),
            ],
            "supersedes": (
                None
                if revision == 1
                else {"id": PACKET_ID, "revision": revision - 1}
            ),
            "created_by": creator,
        }

    @staticmethod
    def driver(
        *,
        status: str = "resolved",
        creator: str = CREATOR,
    ) -> dict[str, object]:
        published = status != "proposed"
        return {
            "schema_version": 1,
            "kind": "ArchitectureDriver",
            "id": DRIVER_ID,
            "revision": 1,
            "status": status,
            "semantic_key": "test.architecture",
            "title": "测试架构驱动力",
            "claim_refs": [{"id": DEPENDENT_CLAIM_ID, "revision": 1}],
            "forces": [
                {
                    "quality_attribute": "可替换性",
                    "scenario": "领域实现不依赖 UI",
                    "criticality": "high",
                }
            ],
            "decision_questions": ["领域边界如何保持稳定？"],
            "resolution": {
                "state": "resolved" if published else "open",
                "adr_refs": ["ADR-0001"] if published else [],
                "work_item_refs": [creator],
            },
            "promotion": (
                {
                    "approval_ref": "approval:test-architecture",
                    "approved_by": "test-owner",
                }
                if published
                else None
            ),
            "supersedes": None,
            "created_by": creator,
        }

    @staticmethod
    def coverage_entry(entry_id: str, claim_id: str) -> dict[str, object]:
        return {
            "id": entry_id,
            "claim_ref": {"id": claim_id, "revision": 1},
            "validation": {
                "required": "static_source",
                "state": "supported",
                "evidence_refs": ["AF-TEST-FACT"],
                "blockers": [],
            },
            "product_disposition": {
                "kind": "covered_by_requirement",
                "refs": ["REQ-TEST@1"],
                "reason": None,
                "review_after": None,
            },
            "delivery": {
                "state": "planned",
                "requirement_refs": ["REQ-TEST@1"],
                "work_item_refs": [],
                "capability_refs": [],
                "evidence_refs": [],
            },
            "computed": {"accounted": True, "coverage_state": "covered"},
        }

    def install_valid_graph(
        self,
        *,
        accepted_adr: bool = True,
        write_catalog: bool = True,
    ) -> tuple[Path, Path, Path]:
        packet_path = (
            self.root
            / f"ios/project/business-knowledge/packets/published/{PACKET_ID}/r0001.json"
        )
        driver_path = (
            self.root
            / f"ios/project/business-knowledge/drivers/published/{DRIVER_ID}/r0001.json"
        )
        ledger_path = (
            self.root / f"ios/project/business-knowledge/coverage/{LEDGER_ID}.json"
        )
        write_json(packet_path, self.packet())
        write_json(driver_path, self.driver())
        if accepted_adr:
            adr_path = self.root / "ios/docs/adr/0001-test.md"
            adr_path.parent.mkdir(parents=True, exist_ok=True)
            adr_path.write_text(
                "id: ADR-0001\nstatus: accepted\n",
                encoding="utf-8",
            )
        packet_entry = knowledge._record(packet_path, self.root)
        driver_entry = knowledge._record(driver_path, self.root)
        authority = knowledge._authority_digest(
            self.root,
            knowledge._policy(self.root),
            ANDROID_COMMIT,
            INVENTORY_CONTROL,
            [packet_entry],
            [driver_entry],
        )
        write_json(
            ledger_path,
            {
                "schema_version": 1,
                "kind": "BusinessKnowledgeCoverageLedger",
                "id": LEDGER_ID,
                "revision": 1,
                "status": "current",
                "packet_refs": [
                    {
                        "id": PACKET_ID,
                        "revision": 1,
                        "sha256": packet_entry["sha256"],
                    }
                ],
                "generated_from": {
                    "knowledge_authority_sha256": authority,
                    "requirement_catalog_sha256": knowledge.sha256_json(
                        knowledge.load_json(
                            self.root / "ios/project/requirements/catalog.json"
                        )
                    ),
                    "architecture_digest_sha256": "e" * 64,
                },
                "entries": [
                    self.coverage_entry("BKE-TEST-BASE-001", BASE_CLAIM_ID),
                    self.coverage_entry(
                        "BKE-TEST-DEPENDENT-002",
                        DEPENDENT_CLAIM_ID,
                    ),
                ],
                "updated_by": CREATOR,
                "updated_at": "2026-07-23T00:00:00Z",
            },
        )
        if write_catalog:
            write_json(
                self.root / "ios/project/business-knowledge/catalog.json",
                knowledge.catalog_value(self.root),
            )
        return packet_path, driver_path, ledger_path

    def test_manifest_and_doctor_are_deterministic(self) -> None:
        expected = knowledge.catalog_value(self.root)
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            expected,
        )
        self.assertEqual([], knowledge.doctor(self.root))
        outputs = []
        for _ in range(2):
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(
                    0,
                    knowledge.main(["manifest", "--root", str(self.root)]),
                )
            outputs.append(stdout.getvalue())
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(expected, json.loads(outputs[0]))

    def test_published_graph_validates_without_runtime_control_plane(self) -> None:
        self.install_valid_graph()
        self.assertFalse(
            (self.root / "ios/harness/work-items").exists()
        )
        self.assertFalse((self.root / "ios/project/state.json").exists())
        self.assertFalse((self.root / "ios/project/events.jsonl").exists())
        self.assertEqual([], knowledge.doctor(self.root))

    def test_fact_revision_and_packet_digest_drift_are_detected(self) -> None:
        packet_path, _, _ = self.install_valid_graph()
        packet = knowledge.load_json(packet_path)
        packet["claims"][0]["support"]["fact_refs"][0][
            "revision_sha256"
        ] = "d" * 64
        write_json(packet_path, packet)
        errors = knowledge.doctor(self.root, check_catalog=False)
        self.assertTrue(any("Fact revision 漂移" in error for error in errors))
        self.assertTrue(
            any("packet_ref 内容摘要不匹配" in error for error in errors)
        )

    def test_proposal_batch_is_defined_by_created_by(self) -> None:
        packet_path = (
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json"
        )
        driver_path = (
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json"
        )
        write_json(packet_path, self.packet(status="candidate"))
        write_json(driver_path, self.driver(status="proposed"))
        self.assertEqual([], knowledge.doctor(self.root, check_catalog=False))

        driver = knowledge.load_json(driver_path)
        driver["created_by"] = "IOS-OTHER-KNOWLEDGE-002"
        driver["resolution"]["work_item_refs"] = ["IOS-OTHER-KNOWLEDGE-002"]
        write_json(driver_path, driver)
        errors = knowledge.doctor(self.root, check_catalog=False)
        self.assertTrue(
            any("不属于 created_by 同批 Packet proposal" in error for error in errors)
        )

    def test_tombstones_reserve_revisions_without_state_or_events(self) -> None:
        for revision, status in ((1, "blocked"), (2, "exhausted")):
            write_json(
                self.root
                / (
                    "ios/project/business-knowledge/tombstones/packets/"
                    f"{PACKET_ID}/r{revision:04d}.json"
                ),
                {
                    "schema_version": 1,
                    "kind": "KnowledgeRevisionTombstone",
                    "knowledge_kind": "packet",
                    "id": PACKET_ID,
                    "revision": revision,
                    "status": "abandoned",
                    "producer_work_item": f"IOS-OLD-PRODUCER-00{revision}",
                    "producer_terminal_status": status,
                    "reason_code": "historical_failure",
                    "evidence": None,
                    "created_by": "IOS-OLD-CLEANUP-001",
                    "created_at": "2026-07-28T00:00:00Z",
                },
            )
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0003.json",
            self.packet(status="candidate", revision=3),
        )
        self.assertEqual([], knowledge.doctor(self.root, check_catalog=False))

    def test_tombstone_cannot_overlap_a_physical_revision(self) -> None:
        tombstone = {
            "schema_version": 1,
            "kind": "KnowledgeRevisionTombstone",
            "knowledge_kind": "packet",
            "id": PACKET_ID,
            "revision": 1,
            "status": "abandoned",
            "producer_work_item": "IOS-OLD-PRODUCER-001",
            "producer_terminal_status": "blocked",
            "reason_code": "historical_failure",
            "evidence": None,
            "created_by": "IOS-OLD-CLEANUP-001",
            "created_at": "2026-07-28T00:00:00Z",
        }
        write_json(
            self.root
            / f"ios/project/business-knowledge/tombstones/packets/{PACKET_ID}/r0001.json",
            tombstone,
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            self.packet(status="candidate"),
        )
        errors = knowledge.doctor(self.root, check_catalog=False)
        self.assertTrue(
            any("物理 knowledge artifact 已存在" in error for error in errors)
        )

    def test_resolved_driver_requires_accepted_adr(self) -> None:
        self.install_valid_graph(accepted_adr=False, write_catalog=False)
        errors = knowledge.doctor(self.root, check_catalog=False)
        self.assertTrue(
            any("resolved Driver 必须引用 accepted ADR" in error for error in errors)
        )

    def test_cli_only_exposes_read_only_graph_commands(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(CONTROL_SOURCE / "business_knowledge.py"),
                "--help",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("{doctor,manifest}", result.stdout)
        self.assertNotIn("selection", result.stdout)
        self.assertNotIn("publish", result.stdout.lower())
        self.assertNotIn("accept", result.stdout.lower())

    def test_repository_business_knowledge_is_valid(self) -> None:
        self.assertEqual([], knowledge.doctor(REPOSITORY_ROOT))


if __name__ == "__main__":
    unittest.main()
