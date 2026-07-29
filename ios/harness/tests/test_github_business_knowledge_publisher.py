import json
import sys
import tempfile
import unittest
import datetime as dt
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_ROOT))

import github_business_knowledge_publisher as publisher  # noqa: E402


class KnowledgePublicationIdentityTests(unittest.TestCase):
    def binding(self):
        return {
            "repository": "Owner/Legado",
            "workflow_path": publisher.WORKFLOW_PATH,
            "batch_id": "KPUB-SOURCE-RUNTIME-POST-FORM-001",
            "source_sha": "a" * 40,
            "remote": "origin",
            "publication": {
                "packet_proposal": (
                    "ios/project/business-knowledge/packets/proposals/"
                    "BKP-SOURCE-RUNTIME-POST-FORM-001/r0001.json"
                ),
                "packet_proposal_sha256": "1" * 64,
                "driver_proposal": (
                    "ios/project/business-knowledge/drivers/proposals/"
                    "DRV-SOURCE-RUNTIME-POST-FORM-001/r0001.json"
                ),
                "driver_proposal_sha256": "2" * 64,
                "golden_receipt": (
                    "ios/harness/goldens/releases/"
                    "sl-post-form-001-42-1.json"
                ),
                "golden_receipt_sha256": "3" * 64,
                "requirement_refs": [
                    "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-01"
                ],
                "target_work_item_id": (
                    "IOS-SOURCE-RUNTIME-POST-FORM-001"
                ),
            },
            "producer": {
                "work_item": (
                    "ios/harness/work-items/"
                    "IOS-KNOWLEDGE-SOURCE-RUNTIME-POST-FORM-001.json"
                ),
                "work_item_sha256": "4" * 64,
                "evidence": (
                    "ios/harness/evidence/runs/run-producer.json"
                ),
                "evidence_sha256": "5" * 64,
                "checkpoint": (
                    "ios/project/checkpoints/"
                    "IOS-KNOWLEDGE-SOURCE-RUNTIME-POST-FORM-001.json"
                ),
                "checkpoint_sha256": "6" * 64,
            },
            "next_delivery_intent_id": (
                "DINT-SOURCE-RUNTIME-POST-FORM-001"
            ),
        }

    def test_identity_is_content_addressed_and_scenario_agnostic(self):
        binding = self.binding()
        identity = publisher.knowledge_publication_identity(**binding)
        self.assertEqual("owner/legado", identity.repository)
        self.assertEqual(
            (
                "knowledge/request-source-runtime-post-form-001-"
                + "a" * 40
            ),
            identity.request_branch,
        )
        self.assertEqual(
            (
                "knowledge/result-source-runtime-post-form-001-"
                + "a" * 40
            ),
            identity.result_branch,
        )
        self.assertEqual(
            identity.execution_id,
            publisher._sha256(
                publisher._canonical(identity.request)
            ),
        )
        self.assertEqual(
            identity.request,
            json.loads(publisher._canonical(identity.request)),
        )

    def test_identity_rejects_path_and_requirement_drift(self):
        for mutate in (
            lambda value: value["publication"].update(
                {"packet_proposal": "../packet.json"}
            ),
            lambda value: value["publication"].update(
                {"requirement_refs": ["REQ-X@1#bad"]}
            ),
            lambda value: value["producer"].update(
                {"evidence_sha256": "not-a-digest"}
            ),
        ):
            with self.subTest(mutate=mutate):
                binding = self.binding()
                mutate(binding)
                with self.assertRaises(
                    publisher.GitHubBusinessKnowledgePublisherError
                ):
                    publisher.knowledge_publication_identity(**binding)

    def test_result_report_and_transaction_are_exact(self):
        binding = self.binding()
        with tempfile.TemporaryDirectory() as directory:
            dispatcher = (
                publisher.GitHubBusinessKnowledgePublisherDispatcher(
                    Path(directory),
                    **binding,
                )
            )
            run = {"databaseId": 42, "attempt": 3}
            request_commit = "b" * 40
            installs, deletes, release = (
                dispatcher._expected_transaction_paths(run)
            )
            transaction = {
                "schema_version": 1,
                "kind": (
                    "business_knowledge_publication_transaction"
                ),
                "authority": "protected_business_knowledge",
                "source_commit": request_commit,
                "publisher_run_id": "42/3",
                "install": [
                    {"path": path, "sha256": "7" * 64}
                    for path in sorted(installs)
                ],
                "delete": sorted(deletes),
                "receipt": release,
                "knowledge_authority_sha256": "8" * 64,
            }
            report = {
                "schema_version": 1,
                "status": "published",
                "batch_id": dispatcher.identity.batch_id,
                "source_sha": dispatcher.identity.source_sha,
                "request_branch": dispatcher.identity.request_branch,
                "request_commit": request_commit,
                "result_branch": dispatcher.identity.result_branch,
                "result_commit": "c" * 40,
                "publisher_run": {"id": 42, "attempt": 3},
                "transaction_sha256": publisher._sha256(
                    publisher._canonical(transaction)
                ),
                "execution_id": dispatcher.identity.execution_id,
            }
            self.assertEqual(
                "c" * 40,
                dispatcher._validate_result(
                    report,
                    transaction,
                    run,
                    request_commit,
                ),
            )
            transaction["delete"] = []
            with self.assertRaisesRegex(
                publisher.GitHubBusinessKnowledgePublisherError,
                "TRANSACTION_INVALID",
            ):
                dispatcher._validate_result(
                    report,
                    transaction,
                    run,
                    request_commit,
                )

    def test_journal_is_identity_bound_and_not_result_authority(self):
        binding = self.binding()
        with tempfile.TemporaryDirectory() as directory:
            dispatcher = (
                publisher.GitHubBusinessKnowledgePublisherDispatcher(
                    Path(directory),
                    **binding,
                    now=lambda: dt.datetime(
                        2026, 7, 29, tzinfo=dt.timezone.utc
                    ),
                )
            )
            dispatcher._write_journal(
                "verified",
                request_commit="b" * 40,
                result_commit="c" * 40,
                run={
                    "databaseId": 42,
                    "attempt": 1,
                    "status": "completed",
                    "conclusion": "success",
                    "url": "https://example.invalid/42",
                },
            )
            journal = dispatcher._read_journal()
            self.assertEqual("verified", journal["outcome"])
            self.assertEqual(
                dispatcher.identity.binding(),
                journal["identity"],
            )
            payload = json.loads(
                dispatcher.journal_path.read_text()
            )
            payload["identity"]["source_sha"] = "d" * 40
            dispatcher.journal_path.write_text(json.dumps(payload))
            with self.assertRaisesRegex(
                publisher.GitHubBusinessKnowledgePublisherError,
                "JOURNAL_INVALID",
            ):
                dispatcher._read_journal()


if __name__ == "__main__":
    unittest.main()
