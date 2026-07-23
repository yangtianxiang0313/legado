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
BASE_ENTRY_ID = "BKE-TEST-BASE-001"
DEPENDENT_ENTRY_ID = "BKE-TEST-DEPENDENT-002"


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
        *,
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

    def packet(self, status: str = "published") -> dict[str, object]:
        return {
            "schema_version": 1,
            "kind": "BusinessKnowledgePacket",
            "id": PACKET_ID,
            "revision": 1,
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
                self.claim(BASE_CLAIM_ID, "test.base", depends_on=[]),
                self.claim(
                    DEPENDENT_CLAIM_ID,
                    "test.dependent",
                    depends_on=[{"id": BASE_CLAIM_ID, "revision": 1}],
                ),
            ],
            "supersedes": None,
            "created_by": CREATOR,
        }

    @staticmethod
    def driver() -> dict[str, object]:
        return {
            "schema_version": 1,
            "kind": "ArchitectureDriver",
            "id": DRIVER_ID,
            "revision": 1,
            "status": "resolved",
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
                "state": "resolved",
                "adr_refs": ["ADR-0001"],
                "work_item_refs": [CREATOR],
            },
            "promotion": {
                "approval_ref": "approval:test-architecture",
                "approved_by": "test-owner",
            },
            "supersedes": None,
            "created_by": CREATOR,
        }

    @staticmethod
    def proposal_driver(
        *,
        driver_id: str = DRIVER_ID,
        creator: str = CREATOR,
        claim_id: str = DEPENDENT_CLAIM_ID,
        claim_revision: int = 1,
    ) -> dict[str, object]:
        value = BusinessKnowledgeTests.driver()
        value.update(
            {
                "id": driver_id,
                "status": "proposed",
                "semantic_key": f"test.{driver_id.lower()}",
                "claim_refs": [{"id": claim_id, "revision": claim_revision}],
                "resolution": {
                    "state": "open",
                    "adr_refs": [],
                    "work_item_refs": [creator],
                },
                "promotion": None,
                "created_by": creator,
            }
        )
        return value

    @staticmethod
    def coverage_entry(
        entry_id: str,
        claim_id: str,
    ) -> dict[str, object]:
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
            "computed": {
                "accounted": True,
                "coverage_state": "covered",
            },
        }

    def work_item(
        self,
        *,
        max_claims: int = 40,
        claim_refs: list[dict[str, object]] | None = None,
        driver_refs: list[dict[str, object]] | None = None,
        coverage_refs: list[dict[str, object]] | None = None,
    ) -> dict[str, object]:
        return {
            "id": "IOS-TEST-CONSUMER-001",
            "spec": {
                "knowledge": {
                    "contract_version": 1,
                    "mode": "consume",
                    "claim_refs": claim_refs
                    if claim_refs is not None
                    else [{"id": DEPENDENT_CLAIM_ID, "revision": 1}],
                    "driver_refs": driver_refs
                    if driver_refs is not None
                    else [{"id": DRIVER_ID, "revision": 1}],
                    "coverage_refs": coverage_refs
                    if coverage_refs is not None
                    else [
                        {
                            "id": LEDGER_ID,
                            "revision": 1,
                            "entries": [BASE_ENTRY_ID, DEPENDENT_ENTRY_ID],
                        }
                    ],
                    "produces": [],
                    "expected_ledger_transitions": [],
                    "context_budget": {
                        "max_claims": max_claims,
                        "max_bytes": 65536,
                    },
                    "none_reason": None,
                }
            },
        }

    def write_producer(
        self,
        item_id: str,
        produces: list[dict[str, object]],
        *,
        mode: str = "produce",
    ) -> None:
        write_json(
            self.root / f"ios/harness/work-items/{item_id}.json",
            {
                "metadata": {"id": item_id},
                "spec": {
                    "knowledge": {
                        "mode": mode,
                        "produces": produces,
                    }
                },
            },
        )

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
        authority = knowledge._authority_digest(
            self.root,
            knowledge._policy(self.root),
            ANDROID_COMMIT,
            INVENTORY_CONTROL,
            [knowledge._record(packet_path, self.root)],
            [knowledge._record(driver_path, self.root)],
        )
        write_json(
            ledger_path,
            {
                "schema_version": 1,
                "kind": "BusinessKnowledgeCoverageLedger",
                "id": LEDGER_ID,
                "revision": 1,
                "status": "current",
                "packet_refs": [{"id": PACKET_ID, "revision": 1}],
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
                    self.coverage_entry(BASE_ENTRY_ID, BASE_CLAIM_ID),
                    self.coverage_entry(DEPENDENT_ENTRY_ID, DEPENDENT_CLAIM_ID),
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

    def test_empty_manifest_and_doctor_are_deterministic(self) -> None:
        expected = knowledge.catalog_value(self.root)
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            expected,
        )

        self.assertEqual(expected, knowledge.catalog_value(self.root))
        self.assertEqual([], knowledge.doctor(self.root))
        outputs = []
        for _ in range(2):
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                exit_code = knowledge.main(
                    ["manifest", "--root", str(self.root)]
                )
            self.assertEqual(0, exit_code)
            outputs.append(stdout.getvalue())
        self.assertEqual(outputs[0], outputs[1])
        self.assertEqual(expected, json.loads(outputs[0]))

    def test_selection_includes_claim_dependency_and_explicit_context(self) -> None:
        packet_path, driver_path, ledger_path = self.install_valid_graph()

        selected = knowledge.selection_value(self.root, self.work_item())

        self.assertEqual(
            [BASE_CLAIM_ID, DEPENDENT_CLAIM_ID],
            [entry["ref"]["id"] for entry in selected["claims"]],
        )
        self.assertEqual(
            [BASE_ENTRY_ID, DEPENDENT_ENTRY_ID],
            [entry["entry"]["id"] for entry in selected["coverage"]],
        )
        self.assertEqual([DRIVER_ID], [entry["ref"]["id"] for entry in selected["drivers"]])
        self.assertEqual([], selected["blocking_reasons"])
        self.assertTrue(selected["knowledge_selection_sha256"])
        self.assertTrue(selected["coverage_selection_sha256"])
        self.assertTrue(selected["architecture_driver_selection_sha256"])
        self.assertEqual(
            {
                "ios/project/business-knowledge/catalog.json",
                knowledge.relative(self.root, packet_path),
                knowledge.relative(self.root, driver_path),
                knowledge.relative(self.root, ledger_path),
            },
            set(selected["required_paths"]),
        )

    def test_related_driver_is_selected_even_when_work_item_omits_it(self) -> None:
        _, driver_path, ledger_path = self.install_valid_graph()
        selected = knowledge.selection_value(
            self.root,
            self.work_item(driver_refs=[]),
        )
        self.assertEqual([DRIVER_ID], [entry["ref"]["id"] for entry in selected["drivers"]])

        driver = knowledge.load_json(driver_path)
        driver["status"] = "active"
        driver["resolution"] = {
            "state": "requires_adr",
            "adr_refs": [],
            "work_item_refs": [CREATOR],
        }
        write_json(driver_path, driver)
        ledger = knowledge.load_json(ledger_path)
        ledger["generated_from"]["knowledge_authority_sha256"] = knowledge._authority_digest(
            self.root,
            knowledge._policy(self.root),
            ANDROID_COMMIT,
            INVENTORY_CONTROL,
            [knowledge._record(
                self.root
                / f"ios/project/business-knowledge/packets/published/{PACKET_ID}/r0001.json",
                self.root,
            )],
            [knowledge._record(driver_path, self.root)],
        )
        write_json(ledger_path, ledger)
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            knowledge.catalog_value(self.root),
        )
        selected = knowledge.selection_value(self.root, self.work_item(driver_refs=[]))
        self.assertTrue(any("unresolved" in reason for reason in selected["blocking_reasons"]))

    def test_coverage_change_does_not_change_authority(self) -> None:
        _, _, ledger_path = self.install_valid_graph()
        before = knowledge.catalog_value(self.root)
        ledger = knowledge.load_json(ledger_path)
        ledger["entries"][0]["delivery"]["state"] = "implementing"
        write_json(ledger_path, ledger)

        after = knowledge.catalog_value(self.root)

        self.assertEqual(before["authority_sha256"], after["authority_sha256"])
        self.assertNotEqual(before["coverage_sha256"], after["coverage_sha256"])

    def test_candidate_packet_cannot_be_consumed(self) -> None:
        proposal_path = (
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json"
        )
        self.write_producer(
            CREATOR,
            [{"kind": "packet", "id": PACKET_ID, "revision": 1}],
        )
        write_json(proposal_path, self.packet(status="candidate"))
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            knowledge.catalog_value(self.root),
        )
        item = self.work_item(
            claim_refs=[{"id": DEPENDENT_CLAIM_ID, "revision": 1}],
            driver_refs=[],
            coverage_refs=[],
        )

        with self.assertRaisesRegex(
            knowledge.KnowledgeError,
            "current published revision",
        ):
            knowledge.selection_value(self.root, item)

    def test_proposal_driver_can_reference_claim_from_same_producer_batch(self) -> None:
        self.write_producer(
            CREATOR,
            [
                {"kind": "packet", "id": PACKET_ID, "revision": 1},
                {"kind": "driver", "id": DRIVER_ID, "revision": 1},
            ],
        )
        before = knowledge.catalog_value(self.root)
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            self.packet(status="candidate"),
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json",
            self.proposal_driver(),
        )
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            knowledge.catalog_value(self.root),
        )
        after = knowledge.catalog_value(self.root)

        self.assertEqual([], knowledge.doctor(self.root))
        self.assertEqual(before["authority_sha256"], after["authority_sha256"])
        self.assertNotEqual(before["proposal_sha256"], after["proposal_sha256"])

    def test_proposal_driver_can_reference_current_published_claim(self) -> None:
        self.install_valid_graph()
        proposal_driver_id = "DRV-TEST-PROPOSAL-002"
        producer = "IOS-TEST-PROPOSAL-002"
        self.write_producer(
            producer,
            [{"kind": "driver", "id": proposal_driver_id, "revision": 1}],
        )
        write_json(
            self.root
            / (
                "ios/project/business-knowledge/drivers/proposals/"
                f"{proposal_driver_id}/r0001.json"
            ),
            self.proposal_driver(
                driver_id=proposal_driver_id,
                creator=producer,
            ),
        )
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            knowledge.catalog_value(self.root),
        )

        self.assertEqual([], knowledge.doctor(self.root))

    def test_proposal_driver_cannot_reference_packet_from_another_batch(self) -> None:
        packet_creator = "IOS-TEST-PACKET-002"
        driver_creator = "IOS-TEST-DRIVER-003"
        self.write_producer(
            packet_creator,
            [{"kind": "packet", "id": PACKET_ID, "revision": 1}],
        )
        self.write_producer(
            driver_creator,
            [{"kind": "driver", "id": DRIVER_ID, "revision": 1}],
        )
        packet = self.packet(status="candidate")
        packet["created_by"] = packet_creator
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            packet,
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json",
            self.proposal_driver(creator=driver_creator),
        )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("不属于 created_by 同批 Packet proposal" in error for error in errors),
            errors,
        )

    def test_proposal_created_by_must_match_exact_produces_declaration(self) -> None:
        other_creator = "IOS-TEST-PACKET-002"
        self.write_producer(
            other_creator,
            [{"kind": "packet", "id": PACKET_ID, "revision": 1}],
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            self.packet(status="candidate"),
        )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("与 knowledge.produces producer" in error for error in errors),
            errors,
        )

    def test_proposal_artifact_without_produces_declaration_is_rejected(self) -> None:
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            self.packet(status="candidate"),
        )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("未由 created_by Work Item 精确声明" in error for error in errors),
            errors,
        )

    def test_duplicate_proposal_producer_declaration_is_rejected(self) -> None:
        output = {"kind": "packet", "id": PACKET_ID, "revision": 1}
        self.write_producer(CREATOR, [output])
        self.write_producer("IOS-TEST-PACKET-002", [output])

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("proposal 生产声明不唯一" in error for error in errors),
            errors,
        )

    def test_duplicate_output_in_one_producer_is_rejected(self) -> None:
        output = {"kind": "packet", "id": PACKET_ID, "revision": 1}
        self.write_producer(CREATOR, [output, output])

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("proposal 生产声明不唯一" in error for error in errors),
            errors,
        )

    def test_same_claim_key_cannot_belong_to_different_proposal_batches(self) -> None:
        packet_a_id = "BKP-TEST-BATCH-A-002"
        packet_b_id = "BKP-TEST-BATCH-B-003"
        creator_a = "IOS-TEST-BATCH-A-002"
        creator_b = "IOS-TEST-BATCH-B-003"
        claim = self.claim(BASE_CLAIM_ID, "test.shared", depends_on=[])
        for packet_id, creator, semantic_key in (
            (packet_a_id, creator_a, "test.batch-a"),
            (packet_b_id, creator_b, "test.batch-b"),
        ):
            self.write_producer(
                creator,
                [{"kind": "packet", "id": packet_id, "revision": 1}],
            )
            packet = self.packet(status="candidate")
            packet.update(
                {
                    "id": packet_id,
                    "semantic_key": semantic_key,
                    "claims": [claim],
                    "created_by": creator,
                }
            )
            write_json(
                self.root
                / (
                    "ios/project/business-knowledge/packets/proposals/"
                    f"{packet_id}/r0001.json"
                ),
                packet,
            )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("proposal claim 归属批次不唯一" in error for error in errors),
            errors,
        )

    def test_proposal_claim_dependency_cannot_cross_producer_batch(self) -> None:
        packet_a_id = "BKP-TEST-BATCH-A-002"
        packet_b_id = "BKP-TEST-BATCH-B-003"
        claim_a_id = "BKC-TEST-BATCH-A-003"
        claim_b_id = "BKC-TEST-BATCH-B-004"
        creator_a = "IOS-TEST-BATCH-A-002"
        creator_b = "IOS-TEST-BATCH-B-003"
        self.write_producer(
            creator_a,
            [
                {"kind": "packet", "id": packet_a_id, "revision": 1},
                {"kind": "driver", "id": DRIVER_ID, "revision": 1},
            ],
        )
        self.write_producer(
            creator_b,
            [{"kind": "packet", "id": packet_b_id, "revision": 1}],
        )
        packet_a = self.packet(status="candidate")
        packet_a.update(
            {
                "id": packet_a_id,
                "semantic_key": "test.batch-a",
                "claims": [
                    self.claim(
                        claim_a_id,
                        "test.batch-a.claim",
                        depends_on=[{"id": claim_b_id, "revision": 1}],
                    )
                ],
                "created_by": creator_a,
            }
        )
        packet_b = self.packet(status="candidate")
        packet_b.update(
            {
                "id": packet_b_id,
                "semantic_key": "test.batch-b",
                "claims": [
                    self.claim(
                        claim_b_id,
                        "test.batch-b.claim",
                        depends_on=[],
                    )
                ],
                "created_by": creator_b,
            }
        )
        write_json(
            self.root
            / (
                "ios/project/business-knowledge/packets/proposals/"
                f"{packet_a_id}/r0001.json"
            ),
            packet_a,
        )
        write_json(
            self.root
            / (
                "ios/project/business-knowledge/packets/proposals/"
                f"{packet_b_id}/r0001.json"
            ),
            packet_b,
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json",
            self.proposal_driver(
                creator=creator_a,
                claim_id=claim_a_id,
            ),
        )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("proposal claim 依赖既非 current published claim" in error for error in errors),
            errors,
        )

    def test_proposal_claim_dependency_can_cross_packets_in_same_batch(self) -> None:
        packet_a_id = "BKP-TEST-BATCH-A-002"
        packet_b_id = "BKP-TEST-BATCH-B-003"
        claim_a_id = "BKC-TEST-BATCH-A-003"
        claim_b_id = "BKC-TEST-BATCH-B-004"
        creator = "IOS-TEST-BATCH-A-002"
        self.write_producer(
            creator,
            [
                {"kind": "packet", "id": packet_a_id, "revision": 1},
                {"kind": "packet", "id": packet_b_id, "revision": 1},
                {"kind": "driver", "id": DRIVER_ID, "revision": 1},
            ],
        )
        for packet_id, semantic_key, claim in (
            (
                packet_a_id,
                "test.batch-a",
                self.claim(
                    claim_a_id,
                    "test.batch-a.claim",
                    depends_on=[{"id": claim_b_id, "revision": 1}],
                ),
            ),
            (
                packet_b_id,
                "test.batch-b",
                self.claim(
                    claim_b_id,
                    "test.batch-b.claim",
                    depends_on=[],
                ),
            ),
        ):
            packet = self.packet(status="candidate")
            packet.update(
                {
                    "id": packet_id,
                    "semantic_key": semantic_key,
                    "claims": [claim],
                    "created_by": creator,
                }
            )
            write_json(
                self.root
                / (
                    "ios/project/business-knowledge/packets/proposals/"
                    f"{packet_id}/r0001.json"
                ),
                packet,
            )
        write_json(
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json",
            self.proposal_driver(
                creator=creator,
                claim_id=claim_a_id,
            ),
        )
        write_json(
            self.root / "ios/project/business-knowledge/catalog.json",
            knowledge.catalog_value(self.root),
        )

        self.assertEqual([], knowledge.doctor(self.root))

    def test_proposal_claim_conflict_cannot_cross_producer_batch(self) -> None:
        packet_a_id = "BKP-TEST-BATCH-A-002"
        packet_b_id = "BKP-TEST-BATCH-B-003"
        claim_a_id = "BKC-TEST-BATCH-A-003"
        claim_b_id = "BKC-TEST-BATCH-B-004"
        creator_a = "IOS-TEST-BATCH-A-002"
        creator_b = "IOS-TEST-BATCH-B-003"
        self.write_producer(
            creator_a,
            [{"kind": "packet", "id": packet_a_id, "revision": 1}],
        )
        self.write_producer(
            creator_b,
            [{"kind": "packet", "id": packet_b_id, "revision": 1}],
        )
        claim_a = self.claim(claim_a_id, "test.batch-a.claim", depends_on=[])
        claim_a["conflicts_with"] = [{"id": claim_b_id, "revision": 1}]
        claim_a["support"]["state"] = "disputed"
        for packet_id, semantic_key, claim, creator in (
            (packet_a_id, "test.batch-a", claim_a, creator_a),
            (
                packet_b_id,
                "test.batch-b",
                self.claim(claim_b_id, "test.batch-b.claim", depends_on=[]),
                creator_b,
            ),
        ):
            packet = self.packet(status="candidate")
            packet.update(
                {
                    "id": packet_id,
                    "semantic_key": semantic_key,
                    "claims": [claim],
                    "created_by": creator,
                }
            )
            write_json(
                self.root
                / (
                    "ios/project/business-knowledge/packets/proposals/"
                    f"{packet_id}/r0001.json"
                ),
                packet,
            )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("proposal claim 冲突既非 current published claim" in error for error in errors),
            errors,
        )

    def test_malformed_packet_proposals_return_errors_without_crashing(self) -> None:
        self.write_producer(
            CREATOR,
            [{"kind": "packet", "id": PACKET_ID, "revision": 1}],
        )
        path = (
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json"
        )
        variants = [
            ("id", []),
            ("revision", []),
            ("revision", True),
            ("claims", None),
            ("claims", [[]]),
            ("baseline", []),
            ("scope", []),
        ]
        for field, value in variants:
            with self.subTest(field=field, value=value):
                packet = self.packet(status="candidate")
                packet[field] = value
                write_json(path, packet)
                errors = knowledge.doctor(self.root, check_catalog=False)
                self.assertTrue(errors)
                self.assertTrue(any("$.%s" % field in error for error in errors), errors)
        packet = self.packet(status="candidate")
        packet["claims"][0]["support"] = []
        write_json(path, packet)
        errors = knowledge.doctor(self.root, check_catalog=False)
        self.assertTrue(any("$.claims[0].support" in error for error in errors), errors)

    def test_malformed_driver_proposals_return_errors_without_crashing(self) -> None:
        self.write_producer(
            CREATOR,
            [{"kind": "driver", "id": DRIVER_ID, "revision": 1}],
        )
        path = (
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json"
        )
        variants = [
            ("id", []),
            ("revision", []),
            ("revision", True),
            ("claim_refs", None),
            ("claim_refs", [[]]),
            ("claim_refs", [{"id": [], "revision": 1}]),
            ("resolution", []),
        ]
        for field, value in variants:
            with self.subTest(field=field, value=value):
                driver = self.proposal_driver()
                driver[field] = value
                write_json(path, driver)
                errors = knowledge.doctor(self.root, check_catalog=False)
                self.assertTrue(errors)
                self.assertTrue(any("$.%s" % field in error for error in errors), errors)

    def test_published_driver_cannot_reference_proposal_claim(self) -> None:
        self.write_producer(
            CREATOR,
            [{"kind": "packet", "id": PACKET_ID, "revision": 1}],
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            self.packet(status="candidate"),
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/drivers/published/{DRIVER_ID}/r0001.json",
            self.driver(),
        )
        adr_path = self.root / "ios/docs/adr/0001-test.md"
        adr_path.parent.mkdir(parents=True, exist_ok=True)
        adr_path.write_text("id: ADR-0001\nstatus: accepted\n", encoding="utf-8")

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("Driver 引用不存在或非 current claim" in error for error in errors),
            errors,
        )

    def test_proposal_driver_requires_exact_candidate_claim_revision(self) -> None:
        self.write_producer(
            CREATOR,
            [
                {"kind": "packet", "id": PACKET_ID, "revision": 1},
                {"kind": "driver", "id": DRIVER_ID, "revision": 1},
            ],
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/packets/proposals/{PACKET_ID}/r0001.json",
            self.packet(status="candidate"),
        )
        write_json(
            self.root
            / f"ios/project/business-knowledge/drivers/proposals/{DRIVER_ID}/r0001.json",
            self.proposal_driver(claim_revision=2),
        )

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("不属于 created_by 同批 Packet proposal" in error for error in errors),
            errors,
        )

    def test_context_budget_applies_after_dependency_closure(self) -> None:
        self.install_valid_graph()

        with self.assertRaisesRegex(
            knowledge.KnowledgeError,
            "CONTEXT_OVERSIZED: claims 2 > 1",
        ):
            knowledge.selection_value(self.root, self.work_item(max_claims=1))

    def test_resolved_driver_requires_accepted_adr(self) -> None:
        self.install_valid_graph(accepted_adr=False, write_catalog=False)

        errors = knowledge.doctor(self.root, check_catalog=False)

        self.assertTrue(
            any("resolved Driver 必须引用 accepted ADR" in error for error in errors),
            errors,
        )

    def test_cli_exposes_no_publish_or_accept_command(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CONTROL_SOURCE / "business_knowledge.py"), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("{doctor,manifest,selection}", result.stdout)
        self.assertNotIn("publish", result.stdout.lower())
        self.assertNotIn("accept", result.stdout.lower())

    def test_initialization_proposal_dag_contract(self) -> None:
        dag = knowledge.load_json(
            REPOSITORY_ROOT
            / "ios/project/work-item-proposals/initialization-dag.json"
        )
        self.assertEqual("proposal_only", dag["authority"])
        self.assertEqual(
            {
                "materializes_work_items": False,
                "changes_project_state": False,
                "changes_authority": False,
            },
            dag["queue_effect"],
        )
        self.assertFalse(dag["materialization_policy"]["auto_materialize"])
        self.assertEqual("IOS-KNOWLEDGE-DAG-REPAIR-001", dag["repaired_by"])
        nodes = {node["proposal_id"]: node for node in dag["nodes"]}
        self.assertEqual(13, len(nodes))
        for node in nodes.values():
            for dependency in node["depends_on"]:
                self.assertIn(dependency, nodes)
                self.assertLess(nodes[dependency]["phase"], node["phase"])
        state = knowledge.load_json(REPOSITORY_ROOT / "ios/project/state.json")
        self.assertTrue(
            all(
                state["work_items"][item_id]["status"] == "completed"
                for item_id in dag["external_prerequisites"]
            )
        )
        self.assertTrue(
            all(
                transition["executor"] == "external_trusted_publisher"
                for transition in dag["trusted_transitions"]
            )
        )


if __name__ == "__main__":
    unittest.main()
