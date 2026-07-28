import hashlib
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "ios/publisher/requirement_readiness_publisher.py"
SPEC = importlib.util.spec_from_file_location("requirement_publisher", SCRIPT)
assert SPEC and SPEC.loader
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


class RequirementReadinessPublisherTests(unittest.TestCase):
    record = (
        "ios/project/requirements/accepted/"
        "REQ-ANDROID-SOURCE-PIPELINE-001.json"
    )
    catalog = "ios/project/requirements/catalog.json"
    golden = (
        "ios/harness/goldens/releases/"
        "sl-html-basic-001-30355913470-1.json"
    )
    release = (
        "ios/project/business-knowledge/releases/"
        "BKP-SOURCE-RUNTIME-HTML-CSS-001-r0001-30371606142-1.json"
    )
    coverage = (
        "ios/project/business-knowledge/coverage/"
        "BKL-SOURCE-RUNTIME-HTML-CSS-001.json"
    )

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.root = self.base / "repo"
        for relative in (
            self.record,
            self.catalog,
            self.golden,
            self.release,
            self.coverage,
        ):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        self._git("init", "-q")
        self._git("config", "user.name", "Requirement Publisher Tests")
        self._git("config", "user.email", "requirement@example.invalid")
        self._git("add", ".")
        self._git("commit", "-qm", "fixture")
        self.source_commit = self._git("rev-parse", "HEAD")

    def tearDown(self):
        self.temp.cleanup()

    def _git(self, *args):
        result = subprocess.run(
            ["git", *args],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return result.stdout.strip()

    @staticmethod
    def _sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _prepare(self, name="output", **overrides):
        values = {
            "source_commit": self.source_commit,
            "authorized_run_id": "99/1",
            "requirement_record": self.record,
            "requirement_record_sha256": self._sha(self.root / self.record),
            "requirement_catalog": self.catalog,
            "requirement_catalog_sha256": self._sha(self.root / self.catalog),
            "golden_receipt": self.golden,
            "golden_receipt_sha256": self._sha(self.root / self.golden),
            "knowledge_release": self.release,
            "knowledge_release_sha256": self._sha(self.root / self.release),
            "coverage_ledger": self.coverage,
            "coverage_ledger_sha256": self._sha(self.root / self.coverage),
            "approved_by": "github-actions[bot]:35530717",
            "published_at": "2026-07-28T00:00:00Z",
            "output_dir": self.base / name,
        }
        values.update(overrides)
        return publisher.prepare(self.root, **values)

    def test_prepare_is_staging_only_complete_and_deterministic(self):
        before = self._git("status", "--porcelain=v1", "--untracked-files=all")
        first = self._prepare("first")
        second = self._prepare("second")
        self.assertEqual(before, self._git(
            "status", "--porcelain=v1", "--untracked-files=all"
        ))
        self.assertEqual(first, second)
        transaction = json.loads(
            (self.base / "first/transaction.json").read_text()
        )
        self.assertEqual(3, len(transaction["install"]))
        record = json.loads((self.base / "first" / self.record).read_text())
        self.assertEqual(
            "implementation_ready", record["readiness"]["state"]
        )
        self.assertEqual([], record["readiness"]["blockers"])

    def test_rejects_digest_and_coverage_drift(self):
        with self.assertRaisesRegex(
            publisher.RequirementPublisherError,
            "GOLDEN_RECEIPT_SHA256_DRIFT",
        ):
            self._prepare("digest", golden_receipt_sha256="0" * 64)
        coverage = json.loads((self.root / self.coverage).read_text())
        coverage["entries"][0]["validation"]["state"] = "pending"
        (self.root / self.coverage).write_text(json.dumps(coverage) + "\n")
        self._git("add", ".")
        self._git("commit", "-qm", "bad coverage")
        self.source_commit = self._git("rev-parse", "HEAD")
        with self.assertRaisesRegex(
            publisher.RequirementPublisherError,
            "COVERAGE_LEDGER_BINDING_INVALID",
        ):
            self._prepare("coverage")

    def test_rejects_dirty_source_and_repository_output(self):
        with self.assertRaisesRegex(
            publisher.RequirementPublisherError,
            "OUTPUT_MUST_BE_OUTSIDE_REPOSITORY",
        ):
            self._prepare(output_dir=self.root / "output")
        (self.root / self.record).write_text("{}\n")
        with self.assertRaisesRegex(
            publisher.RequirementPublisherError, "SOURCE_WORKTREE_DIRTY"
        ):
            self._prepare("dirty")

    def test_workflow_is_environment_protected_and_verify_before_push(self):
        workflow = (
            ROOT / ".github/workflows/requirement-readiness-publisher.yml"
        ).read_text()
        self.assertIn("environment: requirement-readiness-publisher", workflow)
        self.assertIn(
            "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            workflow,
        )
        self.assertNotIn("pull_request_target", workflow)
        freeze = workflow.index(
            "- name: Install and freeze local release commit"
        )
        verify = workflow.index("- name: Verify immutable next Loop state")
        push = workflow.index("- name: Push verified commit and create PR")
        self.assertLess(freeze, verify)
        self.assertLess(verify, push)
        self.assertIn('.plans[0].state == "blueprint_required"', workflow)
        self.assertNotIn("git -C publisher push", workflow[freeze:verify])
        self.assertNotIn("git -C publisher push", workflow[verify:push])


if __name__ == "__main__":
    unittest.main()
