import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HARNESS = Path(__file__).resolve().parents[1]
if str(HARNESS) not in sys.path:
    sys.path.insert(0, str(HARNESS))

from github_oracle_receipt import (  # noqa: E402
    EXPECTED_FILES,
    GitHubOracleReceiptError,
    GitHubOracleReceiptSettler,
    receipt_path,
)


class ReceiptTests(unittest.TestCase):
    def test_receipt_path_is_deterministic(self):
        self.assertEqual(
            (
                "ios/project/external-execution-receipts/"
                "android-oracle-sl-post-form-001-"
                + "a" * 40
                + "-123-2.json"
            ),
            receipt_path("sl-post-form-001", "a" * 40, 123, 2),
        )

    def _settler(self, root, runner):
        gh = root / "fake-gh"
        gh.write_text("#!/bin/sh\nexit 1\n")
        os.chmod(gh, 0o700)
        return GitHubOracleReceiptSettler(
            root,
            repository="owner/legado",
            scenario="sl-post-form-001",
            source_digest="a" * 40,
            run_id=123,
            attempt=2,
            runner=runner,
            gh=gh,
        )

    def test_download_requires_exact_regular_digest_bound_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "artifact"
            destination.mkdir()

            def runner(argv, cwd):
                if "download" in argv:
                    payloads = {
                        name: (name + "\n").encode()
                        for name in EXPECTED_FILES
                        if name != "SHA256SUMS"
                    }
                    for name, payload in payloads.items():
                        (destination / name).write_bytes(payload)
                    sums = "".join(
                        f"{hashlib.sha256(payload).hexdigest()}  {name}\n"
                        for name, payload in sorted(payloads.items())
                    )
                    (destination / "SHA256SUMS").write_text(sums)
                return subprocess.CompletedProcess(argv, 0, b"", b"")

            settler = self._settler(root, runner)
            digests = settler._download(
                destination,
                {"name": "android-oracle-candidate-sl-post-form-001-123-2"},
            )
            self.assertEqual(EXPECTED_FILES, set(digests))

    def test_download_rejects_extra_file_and_symlink(self):
        for bad_kind in ("extra", "symlink"):
            with self.subTest(bad_kind=bad_kind):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    destination = root / "artifact"
                    destination.mkdir()

                    def runner(argv, cwd):
                        for name in EXPECTED_FILES:
                            (destination / name).write_bytes(b"x")
                        if bad_kind == "extra":
                            (destination / "extra").write_bytes(b"x")
                        else:
                            (destination / "link").symlink_to(
                                destination / "SHA256SUMS"
                            )
                        return subprocess.CompletedProcess(
                            argv, 0, b"", b""
                        )

                    settler = self._settler(root, runner)
                    with self.assertRaises(GitHubOracleReceiptError):
                        settler._download(destination, {"name": "candidate"})

    def test_gh_relative_symlink_resolves_once_and_calls_regular_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cellar = root / "Cellar/gh/2.89.0/bin"
            cellar.mkdir(parents=True)
            executable = cellar / "gh"
            executable.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(executable, 0o700)
            entry = root / "bin"
            entry.mkdir()
            link = entry / "gh"
            link.symlink_to("../Cellar/gh/2.89.0/bin/gh")
            commands = []

            def runner(argv, cwd):
                commands.append(argv)
                payload = [{
                    "databaseId": 123,
                    "attempt": 2,
                    "status": "completed",
                    "conclusion": "success",
                    "url": "https://example.invalid/run/123",
                    "headSha": "a" * 40,
                    "headBranch": (
                        "feature/oracle-sl-post-form-001-" + "a" * 40
                    ),
                    "event": "push",
                }]
                return subprocess.CompletedProcess(
                    argv, 0, json.dumps(payload).encode(), b""
                )

            settler = GitHubOracleReceiptSettler(
                root,
                repository="owner/legado",
                scenario="sl-post-form-001",
                source_digest="a" * 40,
                run_id=123,
                attempt=2,
                runner=runner,
                gh=link,
            )
            replacement = cellar.parent.parent / "2.90.0/bin"
            replacement.mkdir(parents=True)
            replacement_gh = replacement / "gh"
            replacement_gh.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(replacement_gh, 0o700)
            link.unlink()
            link.symlink_to("../Cellar/gh/2.90.0/bin/gh")

            settler._verify_run()

            self.assertEqual(executable.resolve(), settler.gh)
            self.assertEqual(str(executable.resolve()), commands[0][0])
            self.assertNotEqual(str(replacement_gh.resolve()), commands[0][0])

    def test_gh_rejects_broken_and_cyclic_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            broken = root / "broken-gh"
            broken.symlink_to("missing-gh")
            first = root / "first-gh"
            second = root / "second-gh"
            first.symlink_to(second.name)
            second.symlink_to(first.name)
            for candidate in (broken, first):
                with self.subTest(candidate=candidate.name):
                    with self.assertRaisesRegex(
                        GitHubOracleReceiptError, "^GH_EXECUTABLE_INVALID$"
                    ):
                        GitHubOracleReceiptSettler(
                            root,
                            repository="owner/legado",
                            scenario="sl-post-form-001",
                            source_digest="a" * 40,
                            run_id=123,
                            attempt=2,
                            gh=candidate,
                        )

    def test_gh_rejects_directory_fifo_and_non_executable_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            directory_target = root / "directory-gh"
            directory_target.mkdir()
            fifo_target = root / "fifo-gh"
            os.mkfifo(fifo_target)
            non_executable = root / "non-executable-gh"
            non_executable.write_text("#!/bin/sh\nexit 0\n")
            os.chmod(non_executable, 0o600)
            for candidate in (
                directory_target,
                fifo_target,
                non_executable,
            ):
                with self.subTest(candidate=candidate.name):
                    with self.assertRaisesRegex(
                        GitHubOracleReceiptError, "^GH_EXECUTABLE_INVALID$"
                    ):
                        GitHubOracleReceiptSettler(
                            root,
                            repository="owner/legado",
                            scenario="sl-post-form-001",
                            source_digest="a" * 40,
                            run_id=123,
                            attempt=2,
                            gh=candidate,
                        )

    def test_artifact_requires_workflow_run_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            expected_name = (
                "android-oracle-candidate-sl-post-form-001-123-2"
            )
            artifact = {
                "id": 9,
                "name": expected_name,
                "expired": False,
                "size_in_bytes": 100,
                "workflow_run": {
                    "id": 123,
                    "head_sha": "a" * 40,
                    "head_branch": (
                        "feature/oracle-sl-post-form-001-" + "a" * 40
                    ),
                },
            }

            def runner(argv, cwd):
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    json.dumps({"artifacts": [artifact]}).encode(),
                    b"secret must not escape",
                )

            settler = self._settler(root, runner)
            self.assertEqual(artifact, settler._verify_artifact())
            artifact["workflow_run"]["id"] = 122
            with self.assertRaisesRegex(
                GitHubOracleReceiptError, "GITHUB_ARTIFACT_INVALID"
            ):
                settler._verify_artifact()

    def test_authority_fixture_listing_is_bidirectional(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settler = self._settler(root, lambda argv, cwd: None)
            fixture = "ios/harness/fixtures/source-lab/sl-post-form-001/a"
            with (
                mock.patch.object(
                    settler,
                    "_fixture_path",
                    return_value=(
                        "ios/harness/fixtures/source-lab/sl-post-form-001"
                    ),
                ),
                mock.patch.object(
                    settler,
                    "_git",
                    side_effect=(fixture, fixture + "\nextra"),
                ),
            ):
                with self.assertRaisesRegex(
                    GitHubOracleReceiptError, "AUTHORITY_TREE_INVALID"
                ):
                    settler._authority_paths("a" * 40)

    def test_authority_fixture_path_accepts_runtime_manifest_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "fake-gh"
            gh.write_text("#!/bin/sh\nexit 1\n")
            os.chmod(gh, 0o700)
            settler = GitHubOracleReceiptSettler(
                root,
                repository="owner/repo",
                scenario="rl-reader-bookmark-search-runtime-risk-001",
                source_digest="a" * 40,
                run_id=123,
                attempt=2,
                runner=lambda argv, cwd: None,
                gh=gh,
            )
            fixture = (
                "ios/harness/fixtures/runtime-lab/"
                "rl-reader-bookmark-search-runtime-risk-001"
            )
            manifest = json.dumps(
                {
                    "fixtures": [
                        {
                            "id": (
                                "rl-reader-bookmark-search-runtime-risk-001"
                            ),
                            "path": fixture,
                            "sha256": "b" * 64,
                        }
                    ]
                }
            )
            with mock.patch.object(
                settler,
                "_git",
                return_value=manifest,
            ):
                self.assertEqual(fixture, settler._fixture_path("HEAD"))

    def test_receipt_parent_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside"
            outside.mkdir()
            ios = root / "ios"
            ios.mkdir()
            (ios / "project").symlink_to(outside)
            settler = self._settler(root, lambda argv, cwd: None)
            with self.assertRaisesRegex(
                GitHubOracleReceiptError, "RECEIPT_PATH_INVALID"
            ):
                settler._prepare_receipt_parent(
                    root
                    / "ios/project/external-execution-receipts"
                )

    def test_command_failure_does_not_disclose_stderr(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def runner(argv, cwd):
                return subprocess.CompletedProcess(
                    argv, 1, b"public", b"super-secret"
                )

            settler = self._settler(root, runner)
            with self.assertRaisesRegex(
                GitHubOracleReceiptError, "^STABLE_REASON$"
            ) as caught:
                settler._command(("false",), root, "STABLE_REASON")
            self.assertNotIn("secret", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
