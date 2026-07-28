import hashlib
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parents[1]
PUBLISHER_PATH = (
    REPOSITORY_ROOT
    / "ios/publisher/business_knowledge_publisher.py"
)
SPEC = importlib.util.spec_from_file_location(
    "business_knowledge_publisher",
    PUBLISHER_PATH,
)
assert SPEC is not None and SPEC.loader is not None
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class BusinessKnowledgePublisherTests(unittest.TestCase):
    packet_relative = (
        "ios/project/business-knowledge/packets/proposals/"
        "BKP-SOURCE-RUNTIME-HTML-CSS-001/r0001.json"
    )
    driver_relative = (
        "ios/project/business-knowledge/drivers/proposals/"
        "DRV-SOURCE-RUNTIME-HTML-CSS-001/r0001.json"
    )
    golden_receipt_relative = (
        "ios/harness/goldens/releases/"
        "sl-html-basic-001-30355913470-1.json"
    )
    requirement_refs = (
        "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-01",
        "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-02",
        "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-03",
        "REQ-ANDROID-SOURCE-PIPELINE-001@1#RC-04",
    )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.root = self.base / "repository"
        self._copy_fixture()
        self._git("init", "-q")
        self._git("config", "user.email", "publisher-tests@example.invalid")
        self._git("config", "user.name", "Publisher Tests")
        self._git("add", ".")
        self._git("commit", "-qm", "publisher fixture")
        self.source_commit = self._git("rev-parse", "HEAD")

    def tearDown(self):
        self.temporary.cleanup()

    def _copy_fixture(self):
        paths = (
            "ios/harness/business-knowledge",
            "ios/harness/evidence",
            "ios/harness/goldens",
            "ios/harness/harness.py",
            "ios/harness/work-items",
            "ios/docs/adr",
            "ios/project/android-intake/inventory-manifest.json",
            "ios/project/baseline.json",
            "ios/project/business-knowledge",
            "ios/project/capabilities",
            "ios/project/checkpoints",
            "ios/project/events.jsonl",
            "ios/project/requirements/catalog.json",
            "ios/project/state.json",
        )
        for relative in paths:
            source = REPOSITORY_ROOT / relative
            destination = self.root / relative
            if source.is_dir():
                shutil.copytree(source, destination)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)

    def _git(self, *arguments):
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            self.fail(result.stderr or result.stdout)
        return result.stdout.strip()

    @staticmethod
    def _sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _prepare(self, output, **overrides):
        values = {
            "source_commit": self.source_commit,
            "authorized_run_id": "424242/1",
            "packet_proposal": self.packet_relative,
            "packet_proposal_sha256": self._sha(
                self.root / self.packet_relative
            ),
            "driver_proposal": self.driver_relative,
            "driver_proposal_sha256": self._sha(
                self.root / self.driver_relative
            ),
            "golden_receipt": self.golden_receipt_relative,
            "golden_receipt_sha256": self._sha(
                self.root / self.golden_receipt_relative
            ),
            "requirement_refs": self.requirement_refs,
            "target_work_item": "IOS-SOURCE-RUNTIME-HTML-CSS-001",
            "approved_by": "github-actions[bot]:35530717",
            "published_at": "2026-07-28T00:00:00Z",
            "output_dir": output,
        }
        values.update(overrides)
        return publisher.prepare(self.root, **values)

    @staticmethod
    def _files(root):
        return {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file()
        }

    def _commit_mutation(self, path):
        self._git("add", path)
        self._git("commit", "-qm", f"mutate {path}")
        self.source_commit = self._git("rev-parse", "HEAD")

    def test_prepare_is_deterministic_staging_only_and_complete(self):
        before = self._git(
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        )
        first = self._prepare(self.base / "first")
        second = self._prepare(self.base / "second")
        after = self._git(
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        )
        self.assertEqual("", before)
        self.assertEqual(before, after)
        self.assertEqual(first, second)
        self.assertEqual(
            self._files(self.base / "first"),
            self._files(self.base / "second"),
        )
        transaction = json.loads(
            (
                self.base / "first/transaction.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(
            "protected_business_knowledge",
            transaction["authority"],
        )
        self.assertEqual(5, len(transaction["install"]))
        self.assertEqual(
            sorted(
                [
                    self.driver_relative,
                    self.packet_relative,
                ]
            ),
            transaction["delete"],
        )
        installed = {
            item["path"]: item["sha256"]
            for item in transaction["install"]
        }
        self.assertIn(
            "ios/project/business-knowledge/coverage/"
            "BKL-SOURCE-RUNTIME-HTML-CSS-001.json",
            installed,
        )
        packet_path = (
            self.base
            / "first/ios/project/business-knowledge/packets/published/"
            "BKP-SOURCE-RUNTIME-HTML-CSS-001/r0001.json"
        )
        driver_path = (
            self.base
            / "first/ios/project/business-knowledge/drivers/published/"
            "DRV-SOURCE-RUNTIME-HTML-CSS-001/r0001.json"
        )
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        driver = json.loads(driver_path.read_text(encoding="utf-8"))
        self.assertEqual("published", packet["status"])
        self.assertEqual("resolved", driver["status"])
        self.assertEqual(
            (
                "github-actions-environment:"
                "business-knowledge-publisher:424242/1"
            ),
            driver["promotion"]["approval_ref"],
        )

    def test_prepare_recomputes_every_runtime_projection(self):
        packet_path = self.root / self.packet_relative
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        packet["claims"][0]["support"]["runtime_evidence"][0][
            "observed_sha256"
        ] = "0" * 64
        packet_path.write_text(
            json.dumps(packet, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        self._commit_mutation(self.packet_relative)
        with self.assertRaisesRegex(
            publisher.KnowledgePublisherError,
            "OBSERVED_PROJECTION_SHA256_DRIFT",
        ):
            self._prepare(self.base / "projection-drift")

    def test_prepare_rejects_golden_payload_drift(self):
        receipt = json.loads(
            (
                self.root / self.golden_receipt_relative
            ).read_text(encoding="utf-8")
        )
        golden_path = self.root / receipt["golden_path"]
        golden_path.write_bytes(golden_path.read_bytes() + b" ")
        self._commit_mutation(receipt["golden_path"])
        with self.assertRaisesRegex(
            publisher.KnowledgePublisherError,
            "GOLDEN_PAYLOAD_SHA256_DRIFT",
        ):
            self._prepare(self.base / "golden-drift")

    def test_prepare_rejects_driver_claim_outside_packet(self):
        driver_path = self.root / self.driver_relative
        driver = json.loads(driver_path.read_text(encoding="utf-8"))
        driver["claim_refs"].append(
            {
                "id": "BKC-SR-NOT-IN-PACKET-001",
                "revision": 1,
            }
        )
        driver_path.write_text(
            json.dumps(driver, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        self._commit_mutation(self.driver_relative)
        with self.assertRaisesRegex(
            publisher.KnowledgePublisherError,
            "DRIVER_CLAIM_SELECTION_DRIFT",
        ):
            self._prepare(self.base / "driver-drift")

    def test_prepare_rejects_dirty_source_and_repository_output(self):
        forbidden = self.root / "publisher-output"
        with self.assertRaisesRegex(
            publisher.KnowledgePublisherError,
            "OUTPUT_INSIDE_REPOSITORY",
        ):
            self._prepare(forbidden)
        self.assertFalse(forbidden.exists())

        (self.root / "untracked").write_text("dirty", encoding="utf-8")
        with self.assertRaisesRegex(
            publisher.KnowledgePublisherError,
            "SOURCE_TREE_DIRTY",
        ):
            self._prepare(self.base / "dirty")

    def test_prepare_rejects_authorized_input_digest_drift(self):
        cases = (
            ("packet_proposal_sha256", "0" * 64, "PACKET_PROPOSAL"),
            ("driver_proposal_sha256", "0" * 64, "DRIVER_PROPOSAL"),
            ("golden_receipt_sha256", "0" * 64, "GOLDEN_RECEIPT"),
        )
        for index, (key, value, reason) in enumerate(cases):
            with self.subTest(key=key), self.assertRaisesRegex(
                publisher.KnowledgePublisherError,
                reason,
            ):
                self._prepare(
                    self.base / f"digest-{index}",
                    **{key: value},
                )

    def test_prepare_rejects_existing_publication_target(self):
        target = (
            self.root
            / "ios/project/business-knowledge/coverage/"
            "BKL-SOURCE-RUNTIME-HTML-CSS-001.json"
        )
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("{}\n", encoding="utf-8")
        self._commit_mutation(
            "ios/project/business-knowledge/coverage/"
            "BKL-SOURCE-RUNTIME-HTML-CSS-001.json"
        )
        with self.assertRaisesRegex(
            publisher.KnowledgePublisherError,
            "PUBLICATION_TARGET_ALREADY_EXISTS",
        ):
            self._prepare(self.base / "existing")

    def test_workflow_is_environment_protected_pinned_and_pr_only(self):
        workflow = (
            REPOSITORY_ROOT
            / ".github/workflows/business-knowledge-publisher.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn(
            "environment: business-knowledge-publisher",
            workflow,
        )
        self.assertIn("contents: write", workflow)
        self.assertIn("pull-requests: write", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("permissions: write-all", workflow)
        self.assertIn(
            "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            workflow,
        )
        self.assertIn(
            "TARGET_BRANCH: feature/ios-ai-harness-bootstrap",
            workflow,
        )
        self.assertIn('AUTHORIZED_ACTOR_ID: "35530717"', workflow)
        self.assertIn(
            "business_knowledge_publisher.py",
            workflow,
        )
        self.assertIn(
            "business_knowledge.py \\\n            doctor",
            workflow,
        )
        self.assertIn(
            '.state == "requirement_readiness_required"',
            workflow,
        )
        self.assertIn("gh pr create", workflow)
        self.assertNotIn(
            'HEAD:refs/heads/${TARGET_BRANCH}',
            workflow,
        )


if __name__ == "__main__":
    unittest.main()
