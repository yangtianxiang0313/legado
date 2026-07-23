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


if __name__ == "__main__":
    unittest.main()
