import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parents[1]
sys.path.insert(0, str(HARNESS_ROOT))

from oracle import ci_proposal, trusted_import  # noqa: E402
from oracle.exact_json import loads  # noqa: E402


class OracleTrustedImportTests(unittest.TestCase):
    repository = "yangtianxiang0313/legado"
    workflow_ref = (
        "yangtianxiang0313/legado/"
        ".github/workflows/android-oracle-attestation.yml"
        "@refs/heads/feature/ios-ai-harness-bootstrap"
    )

    @classmethod
    def setUpClass(cls):
        cls.pipeline_temporary = tempfile.TemporaryDirectory()
        pipeline_root = Path(cls.pipeline_temporary.name)
        cls.source_digest = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        environment = pipeline_root / "runner-environment.json"
        environment.write_bytes(
            ci_proposal._dump(
                ci_proposal.runner_environment_document(
                    REPOSITORY_ROOT,
                    image_os="ubuntu24",
                    image_version="20260720.1",
                )
            )
        )
        local_run = pipeline_root / "local-run.json"
        local_run.write_bytes(
            ci_proposal._dump(cls._local_run()) + b"\n"
        )
        cls.evidence_bundle_bytes = b'{"bundle":"evidence"}'
        evidence_bundle = pipeline_root / "evidence-attestation.json"
        evidence_bundle.write_bytes(cls.evidence_bundle_bytes)
        prepared = ci_proposal.prepare(
            REPOSITORY_ROOT,
            local_run=local_run,
            runner_environment=environment,
            output_dir=pipeline_root / "evidence",
            repository=cls.repository,
            workflow_ref=cls.workflow_ref,
            run_id="123/1",
            source_digest=cls.source_digest,
        )
        cls.evidence_archive = Path(prepared["archive"])
        finalized = ci_proposal.finalize(
            REPOSITORY_ROOT,
            evidence_archive=cls.evidence_archive,
            evidence_attestation_bundle=evidence_bundle,
            attestation_url=(
                "https://github.com/"
                "yangtianxiang0313/legado/attestations/1"
            ),
            output_dir=pipeline_root / "proposal",
        )
        cls.proposal_archive = Path(finalized["archive"])

    @classmethod
    def tearDownClass(cls):
        cls.pipeline_temporary.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.evidence_bundle = self.root / "evidence-attestation.json"
        self.evidence_bundle.write_bytes(self.evidence_bundle_bytes)
        self.proposal_bundle = self.root / "proposal-attestation.json"
        self.proposal_bundle.write_bytes(b'{"bundle":"proposal"}')
        self.gh_log = self.root / "gh.log"
        self.gh = self.root / "fake-gh"
        self.attestation_report = [
            {
                "verificationResult": {
                    "statement": {
                        "predicate": {
                            "buildDefinition": {
                                "externalParameters": {
                                    "workflow": {
                                        "repository": (
                                            "https://github.com/"
                                            f"{self.repository}"
                                        ),
                                        "path": (
                                            ".github/workflows/"
                                            "android-oracle-attestation.yml"
                                        ),
                                        "ref": (
                                            "refs/heads/feature/"
                                            "ios-ai-harness-bootstrap"
                                        ),
                                    }
                                }
                            },
                            "runDetails": {
                                "builder": {
                                    "id": (
                                        "https://github.com/"
                                        f"{self.workflow_ref}"
                                    )
                                },
                                "metadata": {
                                    "invocationId": (
                                        "https://github.com/"
                                        f"{self.repository}/actions/"
                                        "runs/123/attempts/1"
                                    )
                                },
                            },
                        }
                    }
                }
            }
        ]
        encoded_report = json.dumps(
            self.attestation_report,
            separators=(",", ":"),
        )
        self.gh.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >>'{self.gh_log}'\n"
            f"printf '%s\\n' '{encoded_report}'\n",
            encoding="utf-8",
        )
        self.gh.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def test_import_verifies_both_attestations_and_only_reports_candidate(self):
        before = self._repository_status()
        report = self._verify()
        after = self._repository_status()
        self.assertEqual(before, after)
        self.assertEqual("candidate_only", report["authority"])
        self.assertEqual(
            "verified_for_human_review",
            report["status"],
        )
        self.assertEqual(
            "independent_golden_publisher",
            report["next_authority"],
        )
        self.assertEqual([ci_proposal.FIXTURE_ID], report["fixture_ids"])
        lines = self.gh_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(2, len(lines))
        for line in lines:
            self.assertIn(
                "--repo yangtianxiang0313/legado",
                line,
            )
            self.assertIn(
                "--signer-workflow "
                "yangtianxiang0313/legado/"
                ".github/workflows/android-oracle-attestation.yml",
                line,
            )
            self.assertIn(
                f"--source-digest {self.source_digest}",
                line,
            )
            self.assertIn("--deny-self-hosted-runners", line)
            self.assertIn(
                "--predicate-type https://slsa.dev/provenance/v1",
                line,
            )

    def test_import_rejects_evidence_bundle_replacement(self):
        self.evidence_bundle.write_bytes(b'{"bundle":"attacker"}')
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "EVIDENCE_ATTESTATION_BINDING_DRIFT",
        ):
            self._verify()

    def test_import_rejects_repository_policy_drift(self):
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "PRODUCER_BINDING_DRIFT",
        ):
            self._verify(repository="attacker/legado")

    def test_import_rejects_failed_gh_verification(self):
        self.gh.write_text(
            "#!/bin/sh\nexit 1\n",
            encoding="utf-8",
        )
        self.gh.chmod(0o700)
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "ATTESTATION_VERIFICATION_FAILED",
        ):
            self._verify()

    def test_import_rejects_provenance_run_identity_drift(self):
        report = copy.deepcopy(self.attestation_report)
        report[0]["verificationResult"]["statement"]["predicate"][
            "runDetails"
        ]["metadata"]["invocationId"] = (
            "https://github.com/"
            "yangtianxiang0313/legado/actions/runs/999/attempts/1"
        )
        encoded = json.dumps(report, separators=(",", ":"))
        self.gh.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' '{encoded}'\n",
            encoding="utf-8",
        )
        self.gh.chmod(0o700)
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "ATTESTATION_PROVENANCE_IDENTITY_DRIFT",
        ):
            self._verify()

    def test_import_rejects_provenance_workflow_path_drift(self):
        report = copy.deepcopy(self.attestation_report)
        report[0]["verificationResult"]["statement"]["predicate"][
            "buildDefinition"
        ]["externalParameters"]["workflow"]["path"] = (
            "/.github/workflows/android-oracle-attestation.yml"
        )
        self._replace_attestation_report(report)
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "ATTESTATION_PROVENANCE_IDENTITY_DRIFT",
        ):
            self._verify()

    def test_import_rejects_provenance_builder_identity_drift(self):
        report = copy.deepcopy(self.attestation_report)
        report[0]["verificationResult"]["statement"]["predicate"][
            "runDetails"
        ]["builder"]["id"] = (
            "https://github.com/actions/runner/github-hosted"
        )
        self._replace_attestation_report(report)
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "ATTESTATION_PROVENANCE_IDENTITY_DRIFT",
        ):
            self._verify()

    def test_import_rejects_symlink_bundle(self):
        linked = self.root / "linked-attestation.json"
        linked.symlink_to(self.proposal_bundle)
        with self.assertRaisesRegex(
            trusted_import.TrustedImportError,
            "REGULAR_FILE_REQUIRED",
        ):
            trusted_import.verify(
                REPOSITORY_ROOT,
                proposal_archive=self.proposal_archive,
                proposal_attestation_bundle=linked,
                evidence_archive=self.evidence_archive,
                evidence_attestation_bundle=self.evidence_bundle,
                repository=self.repository,
                gh=self.gh,
            )

    def test_command_surface_has_only_read_only_verify(self):
        self.assertEqual(("verify",), trusted_import.COMMANDS)
        for forbidden in (
            "accept",
            "publish",
            "promote",
            "record",
            "update-golden",
        ):
            self.assertNotIn(forbidden, trusted_import.COMMANDS)

    def _verify(self, repository=None):
        return trusted_import.verify(
            REPOSITORY_ROOT,
            proposal_archive=self.proposal_archive,
            proposal_attestation_bundle=self.proposal_bundle,
            evidence_archive=self.evidence_archive,
            evidence_attestation_bundle=self.evidence_bundle,
            repository=repository or self.repository,
            gh=self.gh,
        )

    def _replace_attestation_report(self, report):
        encoded = json.dumps(report, separators=(",", ":"))
        self.gh.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' '{encoded}'\n",
            encoding="utf-8",
        )
        self.gh.chmod(0o700)

    @classmethod
    def _local_run(cls):
        baseline = loads(
            (
                REPOSITORY_ROOT / "ios/project/baseline.json"
            ).read_bytes()
        )
        inventory = loads(
            (
                REPOSITORY_ROOT
                / "ios/project/android-intake/inventory-manifest.json"
            ).read_bytes()
        )
        commit = baseline["android_oracle"]["git_commit"]
        fixture, _, scenario = ci_proposal._fixture_entry(
            REPOSITORY_ROOT,
            ci_proposal.FIXTURE_ID,
        )
        controls = ci_proposal._control_bindings(
            REPOSITORY_ROOT,
            loads(
                (
                    REPOSITORY_ROOT
                    / f"ios/harness/work-items/{ci_proposal.WORK_ITEM_ID}.json"
                ).read_bytes()
            ),
        )
        artifact = {
            "schema_version": 1,
            "fixture_id": ci_proposal.FIXTURE_ID,
            "engine": {
                "platform": "android",
                "revision": commit,
                "compatibility_profile": "android-legado-v1",
            },
            "request_plan": [],
            "decode": None,
            "stages": [],
            "result": {
                "type": "source_pipeline",
                "value": {
                    "fixture_integrity": {},
                    "portable_known_projection": {"cases": []},
                    "android_characterization": {
                        "runner_id": "test",
                    },
                },
            },
            "issues": [],
        }
        return {
            "schema_version": 1,
            "kind": "android_oracle_local_run",
            "authority": "local_unverified",
            "status": "candidate_only",
            "scenario_id": ci_proposal.FIXTURE_ID,
            "emulator": {"serial_sha256": "e" * 64},
            "bindings": {
                "android_git_commit": commit,
                "android_git_tree": inventory["android_tree"],
                "runner_digest": ci_proposal._repository_runner_digest(
                    REPOSITORY_ROOT
                ),
                "fixture_sha256": fixture["sha256"],
                "scenario_sha256": scenario["sha256"],
                "source_lab_manifest_sha256": controls[
                    "source_lab_manifest_sha256"
                ],
                "input_sha256": ci_proposal.file_digest(
                    REPOSITORY_ROOT / fixture["path"] / "input.json"
                ),
            },
            "artifact_sha256": ci_proposal._sha256(
                ci_proposal._dump(artifact)
            ),
            "artifact": artifact,
        }

    @staticmethod
    def _repository_status():
        return subprocess.run(
            ["git", "status", "--porcelain=v1"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
        ).stdout


if __name__ == "__main__":
    unittest.main()
