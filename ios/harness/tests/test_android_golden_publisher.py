import hashlib
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parents[1]
PUBLISHER_PATH = (
    REPOSITORY_ROOT
    / "ios/publisher/android_golden_publisher.py"
)
SPEC = importlib.util.spec_from_file_location(
    "android_golden_publisher",
    PUBLISHER_PATH,
)
assert SPEC is not None and SPEC.loader is not None
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)

import sys

sys.path.insert(0, str(HARNESS_ROOT))
from oracle import ci_proposal, exact_json  # noqa: E402
from oracle.contract import fixture_digest  # noqa: E402


class AndroidGoldenPublisherTests(unittest.TestCase):
    repository = "yangtianxiang0313/legado"
    run_id = "30355913470/1"
    source_digest = "d94cdbaafc8f825790d0d8a8011f842aebbafa8b"

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.publisher_root = self.root / "repository"
        manifest = self.publisher_root / "ios/harness/goldens/manifest.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "oracle": {
                        "android_git_commit": (
                            "30bfdf70224ed3006f2777777ff414ebdb3a9eb3"
                        ),
                        "profile": publisher.PROFILE,
                        "runner_digest": None,
                    },
                    "canonicalizer_sha256": None,
                    "fixtures": {},
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        self.payload = ci_proposal._dump(
            {
                "schema_version": 1,
                "fixture_id": publisher.FIXTURE_ID,
                "result": {"title": "本地书源样例"},
            }
        )
        fixture_path = (
            REPOSITORY_ROOT
            / "ios/harness/fixtures/source-lab"
            / publisher.FIXTURE_ID
        )
        self.proposal = {
            "schema_version": 1,
            "authority": "candidate_only",
            "producer": {
                "run_id": self.run_id,
            },
            "bindings": {
                "compatibility_profile": publisher.PROFILE,
                "android_git_commit": "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
                "runner_digest": "8" * 64,
                "runner_image_digest": "sha256:" + "9" * 64,
                "canonicalizer_config_sha256": "a" * 64,
            },
            "fixtures": [
                {
                    "id": publisher.FIXTURE_ID,
                    "fixture_path": (
                        "ios/harness/fixtures/source-lab/"
                        f"{publisher.FIXTURE_ID}"
                    ),
                    "fixture_sha256": fixture_digest(fixture_path),
                    "payload_path": (
                        f"payloads/{publisher.FIXTURE_ID}.json"
                    ),
                    "payload_sha256": self._sha256(self.payload),
                    "operation": "source_lab_site",
                }
            ],
        }
        self.proposal_bytes = ci_proposal._dump(self.proposal)
        self.proposal_sha256 = self._sha256(self.proposal_bytes)
        self.proposal_archive = self.root / "proposal.tar"
        ci_proposal.deterministic_tar(
            self.proposal_archive,
            {
                (
                    "proposal/payloads/"
                    f"{publisher.FIXTURE_ID}.json"
                ): self.payload,
                "proposal/proposal.json": self.proposal_bytes,
            },
        )
        self.evidence_archive = self.root / "evidence.tar"
        ci_proposal.deterministic_tar(
            self.evidence_archive,
            {
                (
                    "evidence/payloads/"
                    f"{publisher.FIXTURE_ID}.json"
                ): self.payload,
                "evidence/run.json": b"{}",
                "evidence/runner-environment.json": b"{}",
            },
        )
        self.proposal_bundle = self.root / "proposal-attestation.json"
        self.proposal_bundle.write_bytes(b'{"kind":"proposal"}')
        self.evidence_bundle = self.root / "evidence-attestation.json"
        self.evidence_bundle.write_bytes(b'{"kind":"evidence"}')
        self.gh = self.root / "gh"
        self.gh.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.gh.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def test_prepare_is_deterministic_staging_only_and_fully_bound(self):
        before = self._repository_status()
        first = self._prepare(self.root / "first")
        second = self._prepare(self.root / "second")
        after = self._repository_status()
        self.assertEqual(before, after)
        self.assertEqual(first, second)

        first_files = self._files(self.root / "first")
        second_files = self._files(self.root / "second")
        self.assertEqual(first_files, second_files)
        self.assertEqual(
            self.payload,
            first_files[
                f"android-legado-v1/{publisher.FIXTURE_ID}.json"
            ],
        )
        manifest = exact_json.loads(first_files["manifest.json"])
        entry = manifest["fixtures"][publisher.FIXTURE_ID]
        self.assertEqual(self.run_id, entry["run_id"])
        self.assertEqual(
            self.source_digest,
            entry["source_digest"],
        )
        self.assertEqual(
            self.proposal_sha256,
            entry["proposal_sha256"],
        )
        self.assertEqual(
            "sha256:" + "9" * 64,
            entry["runner_image_digest"],
        )
        receipt = exact_json.loads(
            first_files[
                "releases/"
                f"{publisher.FIXTURE_ID}-30355913470-1.json"
            ]
        )
        self.assertEqual(
            "protected_android_golden",
            receipt["authority"],
        )
        self.assertEqual(
            "github_environment_review",
            receipt["authorization"],
        )
        self.assertEqual(
            "candidate_only",
            receipt["previous_authority"],
        )

    def test_prepare_rejects_authorization_binding_drift(self):
        cases = (
            {
                "authorized_run_id": "30355913471/1",
                "reason": "PROPOSAL_AUTHORIZATION_DRIFT",
            },
            {
                "authorized_source_digest": "e" * 40,
                "reason": "TRUSTED_IMPORT_BINDING_DRIFT",
            },
            {
                "authorized_proposal_sha256": "f" * 64,
                "reason": "TRUSTED_IMPORT_BINDING_DRIFT",
            },
        )
        for index, case in enumerate(cases):
            reason = case.pop("reason")
            with self.subTest(reason=reason), self.assertRaisesRegex(
                publisher.GoldenPublisherError,
                reason,
            ):
                self._prepare(
                    self.root / f"drift-{index}",
                    **case,
                )

    def test_prepare_rejects_every_repository_output_path(self):
        forbidden = (
            self.publisher_root
            / ".publisher-forbidden"
        )
        self.assertFalse(forbidden.exists())
        with self.assertRaisesRegex(
            publisher.GoldenPublisherError,
            "OUTPUT_INSIDE_REPOSITORY",
        ):
            self._prepare(forbidden)
        self.assertFalse(forbidden.exists())

    def test_prepare_rejects_already_published_fixture(self):
        live_manifest = (
            REPOSITORY_ROOT / "ios/harness/goldens/manifest.json"
        )
        shutil.copyfile(
            live_manifest,
            self.publisher_root / "ios/harness/goldens/manifest.json",
        )

        with self.assertRaisesRegex(
            publisher.GoldenPublisherError,
            "GOLDEN_ALREADY_PUBLISHED",
        ):
            self._prepare(self.root / "published")

    def test_prepare_accepts_a_symlinked_gh_executable(self):
        linked = self.root / "linked-gh"
        linked.symlink_to(self.gh)
        report = self._prepare(
            self.root / "symlink-gh",
            gh=linked,
        )
        self.assertEqual(
            "staged_for_external_publisher",
            report["status"],
        )

    def test_workflow_is_manual_protected_pinned_and_pr_only(self):
        workflow = (
            REPOSITORY_ROOT
            / ".github/workflows/android-golden-publisher.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn(
            "environment: android-golden-publisher",
            workflow,
        )
        self.assertIn("actions: read", workflow)
        self.assertIn("attestations: read", workflow)
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
        self.assertIn(
            'AUTHORIZED_ACTOR_ID: "35530717"',
            workflow,
        )
        self.assertIn(
            "android_golden_publisher.py",
            workflow,
        )
        self.assertIn(
            'gh run download "${ORACLE_RUN_ID}"',
            workflow,
        )
        self.assertIn(
            "shasum -a 256 -c SHA256SUMS",
            workflow,
        )
        self.assertIn(
            'gh pr create \\\n',
            workflow,
        )
        self.assertNotIn(
            'git -C publisher push origin "${TARGET_BRANCH}"',
            workflow,
        )

    def _prepare(self, output_dir, **overrides):
        trusted_report = {
            "authority": "candidate_only",
            "status": "verified_for_human_review",
            "next_authority": "independent_golden_publisher",
            "source_digest": self.source_digest,
            "proposal_sha256": self.proposal_sha256,
        }
        fake_trusted_import = SimpleNamespace(
            verify=mock.Mock(return_value=trusted_report)
        )
        arguments = {
            "proposal_archive": self.proposal_archive,
            "proposal_attestation_bundle": self.proposal_bundle,
            "evidence_archive": self.evidence_archive,
            "evidence_attestation_bundle": self.evidence_bundle,
            "repository": self.repository,
            "gh": self.gh,
            "authorized_run_id": self.run_id,
            "authorized_source_digest": self.source_digest,
            "authorized_proposal_sha256": self.proposal_sha256,
            "output_dir": output_dir,
        }
        arguments.update(overrides)
        with mock.patch.object(
            publisher,
            "_oracle_modules",
            return_value=(
                ci_proposal,
                fake_trusted_import,
                exact_json,
            ),
        ):
            return publisher.prepare(
                self.publisher_root,
                **arguments,
            )

    @staticmethod
    def _sha256(payload):
        return hashlib.sha256(payload).hexdigest()

    @staticmethod
    def _files(root):
        return {
            path.relative_to(root).as_posix(): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file()
        }

    @staticmethod
    def _repository_status():
        import subprocess

        return subprocess.run(
            [
                "git",
                "status",
                "--short",
                "--untracked-files=all",
            ],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout


if __name__ == "__main__":
    unittest.main()
