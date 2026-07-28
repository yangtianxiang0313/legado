#!/usr/bin/env python3

import importlib.util
import subprocess
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "swiftpm_manifest.py"
SPEC = importlib.util.spec_from_file_location("swiftpm_manifest_under_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
swiftpm_manifest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(swiftpm_manifest)


class SwiftPMManifestTests(unittest.TestCase):
    def test_dump_package_isolates_argv_environment_and_lifetime(self):
        package_root = Path("/repo/ios/Packages/LegadoKit")
        cwd = Path("/repo")
        source_environment = {
            "PATH": "/usr/bin",
            "HOME": "/host/home",
            "CODEX_HOME": "/host/codex",
            "CUSTOM": "retained",
            "CLANG_MODULE_CACHE_PATH": "/host/clang-cache",
            "SWIFTPM_MODULECACHE_OVERRIDE": "/host/swiftpm-cache",
        }
        observed = {}

        def fake_run(argv, **kwargs):
            observed["argv"] = list(argv)
            observed["kwargs"] = kwargs
            isolated_paths = {
                argv[argv.index(option) + 1]
                for option in (
                    "--cache-path",
                    "--config-path",
                    "--security-path",
                    "--scratch-path",
                )
            }
            environment = kwargs["env"]
            isolated_paths.add(environment["CLANG_MODULE_CACHE_PATH"])
            self.assertEqual(
                environment["CLANG_MODULE_CACHE_PATH"],
                environment["SWIFTPM_MODULECACHE_OVERRIDE"],
            )
            self.assertTrue(all(Path(path).is_dir() for path in isolated_paths))
            observed["isolated_paths"] = isolated_paths
            return subprocess.CompletedProcess(argv, 0, stdout="{}", stderr="")

        with mock.patch.object(swiftpm_manifest.subprocess, "run", side_effect=fake_run):
            result = swiftpm_manifest.dump_package(
                package_root,
                cwd=cwd,
                timeout=37,
                environment=source_environment,
            )

        self.assertEqual(result.returncode, 0)
        argv = observed["argv"]
        self.assertEqual(argv[:6], [
            "swift",
            "package",
            "--package-path",
            str(package_root),
            "--disable-sandbox",
            "--cache-path",
        ])
        self.assertEqual(argv[-1], "dump-package")
        self.assertEqual(
            [argv[index] for index in (5, 7, 9, 11)],
            ["--cache-path", "--config-path", "--security-path", "--scratch-path"],
        )
        kwargs = observed["kwargs"]
        self.assertEqual(kwargs["cwd"], str(cwd))
        self.assertEqual(kwargs["timeout"], 37)
        self.assertTrue(kwargs["capture_output"])
        self.assertTrue(kwargs["text"])
        self.assertFalse(kwargs["check"])
        self.assertEqual(kwargs["env"]["HOME"], "/host/home")
        self.assertEqual(kwargs["env"]["CODEX_HOME"], "/host/codex")
        self.assertEqual(kwargs["env"]["CUSTOM"], "retained")
        self.assertEqual(source_environment["CLANG_MODULE_CACHE_PATH"], "/host/clang-cache")
        self.assertEqual(
            source_environment["SWIFTPM_MODULECACHE_OVERRIDE"],
            "/host/swiftpm-cache",
        )
        self.assertTrue(
            all(not Path(path).exists() for path in observed["isolated_paths"])
        )

    def test_each_invocation_uses_a_distinct_isolation_root(self):
        roots = []

        def fake_run(argv, **kwargs):
            roots.append(Path(argv[6]).parent)
            return subprocess.CompletedProcess(argv, 1, stdout="", stderr="failure")

        with mock.patch.object(swiftpm_manifest.subprocess, "run", side_effect=fake_run):
            first = swiftpm_manifest.dump_package(Path("/package"), cwd=Path("/repo"))
            second = swiftpm_manifest.dump_package(Path("/package"), cwd=Path("/repo"))

        self.assertEqual(first.returncode, 1)
        self.assertEqual(second.stderr, "failure")
        self.assertEqual(len(set(roots)), 2)
        self.assertTrue(all(not root.exists() for root in roots))


if __name__ == "__main__":
    unittest.main()
