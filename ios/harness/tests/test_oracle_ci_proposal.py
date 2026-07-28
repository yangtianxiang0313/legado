import copy
import io
import os
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parents[1]
sys.path.insert(0, str(HARNESS_ROOT))

from oracle import ci_proposal  # noqa: E402
from oracle.exact_json import dumps, loads  # noqa: E402


class OracleCIProposalTests(unittest.TestCase):
    repository = "yangtianxiang0313/legado"
    workflow_ref = (
        "yangtianxiang0313/legado/"
        ".github/workflows/android-oracle-attestation.yml"
        "@refs/heads/feature/ios-ai-harness-bootstrap"
    )
    source_digest = "b" * 40

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.environment = self.root / "runner-environment.json"
        environment = ci_proposal.runner_environment_document(
            REPOSITORY_ROOT,
            image_os="ubuntu24",
            image_version="20260720.1",
        )
        self.environment.write_bytes(ci_proposal._dump(environment))
        self.local_run = self.root / "local-run.json"
        self.local_run.write_bytes(
            ci_proposal._dump(self._local_run()) + b"\n"
        )
        self.bundle = self.root / "evidence-attestation.json"
        self.bundle.write_bytes(b'{"test":"evidence-attestation"}')

    def tearDown(self):
        self.temporary.cleanup()

    def test_prepare_and_finalize_are_deterministic_and_contract_valid(self):
        first = self._prepare_finalize("first")
        second = self._prepare_finalize("second")
        self.assertEqual(
            first["prepare"]["archive_sha256"],
            second["prepare"]["archive_sha256"],
        )
        self.assertEqual(
            first["finalize"]["archive_sha256"],
            second["finalize"]["archive_sha256"],
        )
        self.assertEqual(
            first["finalize"]["proposal_sha256"],
            second["finalize"]["proposal_sha256"],
        )
        proposal_members = ci_proposal.read_deterministic_tar(
            Path(first["finalize"]["archive"]),
            ci_proposal.EXPECTED_PROPOSAL_MEMBERS,
        )
        proposal = loads(
            proposal_members["proposal/proposal.json"]
        )
        self.assertEqual("candidate_only", proposal["authority"])
        self.assertEqual(
            ci_proposal._sha256(self.bundle.read_bytes()),
            proposal["producer"]["attestation_sha256"],
        )
        self.assertEqual(
            "https://github.com/yangtianxiang0313/legado/attestations/1",
            proposal["producer"]["attestation_uri"],
        )

    def test_prepare_rejects_artifact_digest_tampering(self):
        value = loads(self.local_run.read_bytes())
        value["artifact"]["issues"] = [{"code": "tampered"}]
        self.local_run.write_bytes(dumps(value) + b"\n")
        with self.assertRaisesRegex(
            ci_proposal.CIProposalError,
            "LOCAL_RUN_ARTIFACT_DIGEST_DRIFT",
        ):
            self._prepare("tampered")

    def test_prepare_rejects_untrusted_runner_environment(self):
        value = loads(self.environment.read_bytes())
        value["github_hosted"] = False
        self.environment.write_bytes(dumps(value))
        with self.assertRaisesRegex(
            ci_proposal.CIProposalError,
            "RUNNER_ENVIRONMENT_INVALID",
        ):
            self._prepare("self-hosted")

    def test_finalize_rejects_non_github_attestation_url(self):
        prepared = self._prepare("bad-url")
        with self.assertRaisesRegex(
            ci_proposal.CIProposalError,
            "ATTESTATION_URL_INVALID",
        ):
            ci_proposal.finalize(
                REPOSITORY_ROOT,
                evidence_archive=Path(prepared["archive"]),
                evidence_attestation_bundle=self.bundle,
                attestation_url="https://attacker.invalid/1",
                output_dir=self.root / "bad-url-proposal",
            )

    def test_packager_refuses_every_repository_output_path(self):
        forbidden = (
            REPOSITORY_ROOT
            / ".harness-runtime/oracle-ci-forbidden"
        )
        self.assertFalse(forbidden.exists())
        with self.assertRaisesRegex(
            ci_proposal.CIProposalError,
            "OUTPUT_INSIDE_REPOSITORY",
        ):
            ci_proposal.prepare(
                REPOSITORY_ROOT,
                local_run=self.local_run,
                runner_environment=self.environment,
                output_dir=forbidden,
                repository=self.repository,
                workflow_ref=self.workflow_ref,
                run_id="123/1",
                source_digest=self.source_digest,
            )
        self.assertFalse(forbidden.exists())

    def test_archive_reader_rejects_traversal_symlink_and_duplicate(self):
        for label, members in (
            (
                "traversal",
                [
                    self._tar_info("../escape", b"x"),
                ],
            ),
            (
                "symlink",
                [
                    self._tar_info(
                        "proposal/proposal.json",
                        b"",
                        kind=tarfile.SYMTYPE,
                        linkname="../../escape",
                    ),
                    self._tar_info(
                        "proposal/payloads/sl-html-basic-001.json",
                        b"{}",
                    ),
                ],
            ),
            (
                "duplicate",
                [
                    self._tar_info("proposal/proposal.json", b"{}"),
                    self._tar_info("proposal/proposal.json", b"{}"),
                ],
            ),
        ):
            path = self.root / f"{label}.tar"
            with tarfile.open(path, "w") as archive:
                for info, payload in members:
                    archive.addfile(info, io.BytesIO(payload))
            with self.subTest(label=label), self.assertRaises(
                ci_proposal.CIProposalError
            ):
                ci_proposal.read_deterministic_tar(
                    path,
                    ci_proposal.EXPECTED_PROPOSAL_MEMBERS,
                )
        valid = self._prepare_finalize("non-deterministic")
        archive = Path(valid["finalize"]["archive"])
        archive.write_bytes(archive.read_bytes() + b"trailing-data")
        with self.assertRaisesRegex(
            ci_proposal.CIProposalError,
            "ARCHIVE_NOT_DETERMINISTIC",
        ):
            ci_proposal.read_deterministic_tar(
                archive,
                ci_proposal.EXPECTED_PROPOSAL_MEMBERS,
            )

    def test_workflow_is_manual_minimal_pinned_and_candidate_only(self):
        workflow = (
            REPOSITORY_ROOT
            / ".github/workflows/android-oracle-attestation.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("permissions: write-all", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn("attestations: write", workflow)
        self.assertIn("contents: read", workflow)
        self.assertIn(
            "actions/attest@f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6",
            workflow,
        )
        self.assertIn(
            "actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
            workflow,
        )
        job_environment = workflow.split(
            "    env:\n", 1
        )[1].split("    steps:\n", 1)[0]
        self.assertNotIn("${{ runner.", job_environment)
        workspace_initialization = (
            "          printf 'ORACLE_TEMP=%s\\n' \\\n"
            '            "${RUNNER_TEMP}/legado-android-oracle" \\\n'
            '            >>"${GITHUB_ENV}"'
        )
        self.assertIn(workspace_initialization, workflow)
        self.assertLess(
            workflow.index(workspace_initialization),
            workflow.index("${ORACLE_TEMP}"),
        )
        sdk_tools_initialization = (
            '          sdkmanager="${ANDROID_HOME}/'
            'cmdline-tools/latest/bin/sdkmanager"\n'
            '          avdmanager="${ANDROID_HOME}/'
            'cmdline-tools/latest/bin/avdmanager"\n'
            '          adb="${ANDROID_HOME}/platform-tools/adb"\n'
            '          test -x "${sdkmanager}"\n'
            '          test -x "${avdmanager}"'
        )
        self.assertIn(sdk_tools_initialization, workflow)
        self.assertIn(
            'printf \'SDKMANAGER=%s\\n\' "${sdkmanager}" '
            '>>"${GITHUB_ENV}"',
            workflow,
        )
        self.assertIn(
            'printf \'AVDMANAGER=%s\\n\' "${avdmanager}" '
            '>>"${GITHUB_ENV}"',
            workflow,
        )
        self.assertIn(
            'adb="${ANDROID_HOME}/platform-tools/adb"',
            workflow,
        )
        self.assertIn('test -x "${adb}"', workflow)
        self.assertIn(
            'printf \'ADB=%s\\n\' "${adb}" >>"${GITHUB_ENV}"',
            workflow,
        )
        self.assertLess(
            workflow.index(sdk_tools_initialization),
            workflow.index('"${SDKMANAGER}" --licenses'),
        )
        self.assertLess(
            workflow.index(sdk_tools_initialization),
            workflow.index('"${AVDMANAGER}" create avd'),
        )
        self.assertNotIn("yes | sdkmanager --licenses", workflow)
        self.assertNotIn("echo no | avdmanager create avd", workflow)
        self.assertNotIn("\n          adb -s", workflow)
        self.assertNotIn("$(adb -s", workflow)
        self.assertIn(
            '"${SDKMANAGER}" \\\n'
            '            "platform-tools"',
            workflow,
        )
        self.assertIn(
            '"${ANDROID_HOME}/emulator/emulator"',
            workflow,
        )
        self.assertIn(
            '--adb "${ADB}"',
            workflow,
        )
        self.assertEqual(4, workflow.count('"${ADB}" -s "${AVD_SERIAL}"'))
        self.assertIn("set +o pipefail", workflow)
        attest_action = (
            "actions/attest@"
            "f7c74d28b9d84cb8768d0b8ca14a4bac6ef463e6"
        )
        self.assertEqual(2, workflow.count(attest_action))
        self.assertEqual(
            2,
            workflow.count(
                "subject-path: ${{ runner.temp }}/"
                "legado-android-oracle/"
            ),
        )
        for forbidden in (
            "publish",
            "promote",
            "update-golden",
            "ios/harness/goldens",
        ):
            self.assertNotIn(forbidden, workflow)

    def test_command_surface_has_no_authority_transition(self):
        self.assertEqual(
            ("environment", "prepare", "finalize"),
            ci_proposal.COMMANDS,
        )
        for forbidden in (
            "accept",
            "publish",
            "promote",
            "record",
            "update-golden",
        ):
            self.assertNotIn(forbidden, ci_proposal.COMMANDS)

    def _prepare(self, label):
        return ci_proposal.prepare(
            REPOSITORY_ROOT,
            local_run=self.local_run,
            runner_environment=self.environment,
            output_dir=self.root / f"{label}-evidence",
            repository=self.repository,
            workflow_ref=self.workflow_ref,
            run_id="123/1",
            source_digest=self.source_digest,
        )

    def _prepare_finalize(self, label):
        prepared = self._prepare(label)
        finalized = ci_proposal.finalize(
            REPOSITORY_ROOT,
            evidence_archive=Path(prepared["archive"]),
            evidence_attestation_bundle=self.bundle,
            attestation_url=(
                "https://github.com/"
                "yangtianxiang0313/legado/attestations/1"
            ),
            output_dir=self.root / f"{label}-proposal",
        )
        return {"prepare": prepared, "finalize": finalized}

    def _local_run(self):
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
        artifact_sha256 = ci_proposal._sha256(
            ci_proposal._dump(artifact)
        )
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
                "runner_digest": "8" * 64,
            },
            "artifact_sha256": artifact_sha256,
            "artifact": artifact,
        }

    @staticmethod
    def _tar_info(name, payload, *, kind=tarfile.REGTYPE, linkname=""):
        info = tarfile.TarInfo(name)
        info.size = len(payload)
        info.mode = 0o644
        info.uid = 0
        info.gid = 0
        info.mtime = 0
        info.type = kind
        info.linkname = linkname
        return info, payload


if __name__ == "__main__":
    unittest.main()
