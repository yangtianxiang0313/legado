import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


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


if __name__ == "__main__":
    unittest.main()
