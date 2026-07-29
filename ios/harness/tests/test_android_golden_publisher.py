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


class AndroidGoldenPublisherTests(unittest.TestCase):
    repository = "yangtianxiang0313/legado"
    scenario = "sl-post-form-001"
    run_id = "30403665320/1"
    source_digest = "faa7252c34dac546b65c618a52826e6fd42258c5"
    android_commit = "30bfdf70224ed3006f2777777ff414ebdb3a9eb3"
    canonicalizer = (
        "c4d944b1b8a115421a95c42c8aab77e6aeee9f6dac0752abad1a5263d4d45d97"
    )

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.publisher_root = self.root / "repository"
        manifest = self.publisher_root / "ios/harness/goldens/manifest.json"
        manifest.parent.mkdir(parents=True)
        self.legacy_entry = {
            "path": (
                "ios/harness/goldens/android-legado-v1/"
                "sl-html-basic-001.json"
            ),
            "fixture_sha256": "1" * 64,
            "golden_sha256": "2" * 64,
            "operation": "source_lab_site",
            "proposal_sha256": "3" * 64,
            "proposal_archive_sha256": "4" * 64,
            "evidence_archive_sha256": "5" * 64,
            "proposal_attestation_sha256": "6" * 64,
            "evidence_attestation_sha256": "7" * 64,
            "source_digest": "d" * 40,
            "run_id": "30355913470/1",
            "runner_image_digest": "sha256:" + "8" * 64,
            "release_receipt": (
                "ios/harness/goldens/releases/"
                "sl-html-basic-001-30355913470-1.json"
            ),
        }
        manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "oracle": {
                        "android_git_commit": self.android_commit,
                        "profile": publisher.PROFILE,
                        "runner_digest": "9" * 64,
                        "runner_image_digest": "sha256:" + "8" * 64,
                    },
                    "canonicalizer_sha256": self.canonicalizer,
                    "fixtures": {
                        "sl-html-basic-001": self.legacy_entry,
                    },
                },
                ensure_ascii=False,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        self.payload = ci_proposal._dump(
            {
                "schema_version": 1,
                "fixture_id": self.scenario,
                "scenario_id": self.scenario,
                "result": {
                    "method": "POST",
                    "body": "keyword=%E6%98%9F%E6%B2%B3",
                },
            }
        )
        self.proposal = {
            "schema_version": 1,
            "authority": "candidate_only",
            "producer": {
                "run_id": self.run_id,
            },
            "bindings": {
                "compatibility_profile": publisher.PROFILE,
                "android_git_commit": self.android_commit,
                "runner_digest": "a" * 64,
                "runner_image_digest": "sha256:" + "b" * 64,
                "canonicalizer_config_sha256": self.canonicalizer,
            },
            "fixtures": [
                {
                    "id": self.scenario,
                    "fixture_path": (
                        "ios/harness/fixtures/source-lab/"
                        f"{self.scenario}"
                    ),
                    "fixture_sha256": "c" * 64,
                    "payload_path": f"payloads/{self.scenario}.json",
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
                f"proposal/payloads/{self.scenario}.json": self.payload,
                "proposal/proposal.json": self.proposal_bytes,
            },
        )
        self.evidence_archive = self.root / "evidence.tar"
        ci_proposal.deterministic_tar(
            self.evidence_archive,
            {
                f"evidence/payloads/{self.scenario}.json": self.payload,
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

    def test_prepare_is_deterministic_scenario_aware_and_migrates_v1(self):
        before = self._repository_status()
        first = self._prepare(self.root / "first")
        second = self._prepare(self.root / "second")
        self.assertEqual(before, self._repository_status())
        self.assertEqual(first, second)
        self.assertEqual(
            self._files(self.root / "first"),
            self._files(self.root / "second"),
        )

        files = self._files(self.root / "first")
        self.assertEqual(
            self.payload,
            files[f"{publisher.PROFILE}/{self.scenario}.json"],
        )
        manifest = exact_json.loads(files["manifest.json"])
        self.assertEqual("2", manifest["schema_version"].token)
        self.assertNotIn("runner_digest", manifest["oracle"])
        legacy = manifest["fixtures"]["sl-html-basic-001"]
        self.assertEqual("9" * 64, legacy["runner_digest"])
        self.assertEqual(
            "github_environment_review",
            legacy["authorization"],
        )
        entry = manifest["fixtures"][self.scenario]
        self.assertEqual("a" * 64, entry["runner_digest"])
        self.assertEqual(
            publisher.AUTHORIZATION,
            entry["authorization"],
        )
        self.assertEqual(
            self.canonicalizer,
            entry["canonicalizer_sha256"],
        )
        receipt = exact_json.loads(
            files[
                "releases/"
                f"{self.scenario}-30403665320-1.json"
            ]
        )
        self.assertEqual("2", receipt["schema_version"].token)
        self.assertEqual(
            "protected_android_golden",
            receipt["authority"],
        )
        self.assertEqual(
            publisher.AUTHORIZATION,
            receipt["authorization"],
        )
        self.assertEqual("a" * 64, receipt["controls"]["runner_digest"])

    def test_prepare_passes_scenario_to_trusted_import_and_members(self):
        fake_verify = mock.Mock(
            return_value=self._trusted_report()
        )
        fake_trusted_import = SimpleNamespace(verify=fake_verify)
        oracle_root = self.root / "historical-oracle-source"
        oracle_root.mkdir()
        with mock.patch.object(
            publisher,
            "_oracle_modules",
            return_value=(
                ci_proposal,
                fake_trusted_import,
                exact_json,
            ),
        ):
            publisher.prepare(
                self.publisher_root,
                oracle_root=oracle_root,
                scenario_id=self.scenario,
                proposal_archive=self.proposal_archive,
                proposal_attestation_bundle=self.proposal_bundle,
                evidence_archive=self.evidence_archive,
                evidence_attestation_bundle=self.evidence_bundle,
                repository=self.repository,
                gh=self.gh,
                authorized_run_id=self.run_id,
                authorized_source_digest=self.source_digest,
                authorized_proposal_sha256=self.proposal_sha256,
                output_dir=self.root / "scenario",
            )
        self.assertEqual(
            self.scenario,
            fake_verify.call_args.kwargs["scenario_id"],
        )
        self.assertEqual(
            oracle_root.resolve(),
            fake_verify.call_args.args[0],
        )

    def test_prepare_rejects_authorization_and_fixture_drift(self):
        cases = (
            {
                "authorized_run_id": "30403665321/1",
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
            {
                "scenario_id": "sl-other-001",
                "reason": "TRUSTED_IMPORT_BINDING_DRIFT",
            },
        )
        for index, case in enumerate(cases):
            values = dict(case)
            reason = values.pop("reason")
            with self.subTest(reason=reason), self.assertRaisesRegex(
                publisher.GoldenPublisherError,
                reason,
            ):
                self._prepare(
                    self.root / f"drift-{index}",
                    **values,
                )

    def test_prepare_rejects_repository_output_and_baseline_drift(self):
        forbidden = self.publisher_root / ".publisher-forbidden"
        with self.assertRaisesRegex(
            publisher.GoldenPublisherError,
            "OUTPUT_INSIDE_REPOSITORY",
        ):
            self._prepare(forbidden)
        self.assertFalse(forbidden.exists())

        self.proposal["bindings"][
            "canonicalizer_config_sha256"
        ] = "e" * 64
        self._refresh_proposal()
        with self.assertRaisesRegex(
            publisher.GoldenPublisherError,
            "EXISTING_GOLDEN_BASELINE_DRIFT",
        ):
            self._prepare(self.root / "baseline-drift")

    def test_prepare_is_idempotent_only_for_exact_published_bytes(self):
        output = self.root / "initial"
        first = self._prepare(output)
        self._install(output)
        replay_output = self.root / "replay"
        replay = self._prepare(replay_output)
        self.assertEqual("already_published", replay["status"])
        self.assertEqual([], replay["files"])
        self.assertFalse(replay_output.exists())
        self.assertEqual(
            first["manifest_sha256"],
            replay["manifest_sha256"],
        )

        golden = (
            self.publisher_root
            / "ios/harness/goldens"
            / publisher.PROFILE
            / f"{self.scenario}.json"
        )
        golden.write_bytes(b"conflict")
        with self.assertRaisesRegex(
            publisher.GoldenPublisherError,
            "GOLDEN_ALREADY_PUBLISHED_CONFLICT",
        ):
            self._prepare(self.root / "conflict")

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

    def test_workflow_is_push_only_scenario_bound_and_has_no_gate(self):
        workflow = (
            REPOSITORY_ROOT
            / ".github/workflows/android-golden-publisher.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("push:", workflow)
        self.assertIn("feature/golden-**", workflow)
        self.assertNotIn("workflow_dispatch:", workflow)
        self.assertNotIn("environment:", workflow)
        self.assertNotIn("pull-requests:", workflow)
        self.assertNotIn("gh pr create", workflow)
        self.assertIn("actions: read", workflow)
        self.assertIn("attestations: read", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("--scenario", workflow)
        self.assertIn("--root publisher", workflow)
        self.assertIn("--oracle-root source", workflow)
        self.assertIn("verified_candidate", workflow)
        self.assertIn("golden/result-", workflow)
        self.assertIn("publisher-result.json", workflow)
        self.assertIn(
            "android-golden-result-",
            workflow,
        )
        self.assertIn(
            "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            workflow,
        )
        self.assertIn(
            "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
            workflow,
        )

    def _trusted_report(self):
        return {
            "authority": "candidate_only",
            "status": "verified_for_human_review",
            "next_authority": "independent_golden_publisher",
            "source_digest": self.source_digest,
            "proposal_sha256": self.proposal_sha256,
            "scenario_id": self.scenario,
            "fixture_ids": [self.scenario],
        }

    def _prepare(self, output_dir, **overrides):
        fake_trusted_import = SimpleNamespace(
            verify=mock.Mock(return_value=self._trusted_report())
        )
        arguments = {
            "scenario_id": self.scenario,
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

    def _refresh_proposal(self):
        self.proposal_bytes = ci_proposal._dump(self.proposal)
        self.proposal_sha256 = self._sha256(self.proposal_bytes)
        self.proposal_archive.unlink()
        ci_proposal.deterministic_tar(
            self.proposal_archive,
            {
                f"proposal/payloads/{self.scenario}.json": self.payload,
                "proposal/proposal.json": self.proposal_bytes,
            },
        )

    def _install(self, output):
        golden_root = self.publisher_root / "ios/harness/goldens"
        for path in output.rglob("*"):
            if path.is_file():
                relative = path.relative_to(output)
                destination = (
                    golden_root / relative
                    if relative.as_posix() != "manifest.json"
                    else golden_root / "manifest.json"
                )
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)

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
