import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE_PATH = ROOT / "ios/harness/probes/package_contract.py"
SPEC = importlib.util.spec_from_file_location("package_contract", MODULE_PATH)
assert SPEC and SPEC.loader
package_contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_contract)


class PackageArchitectureContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package_root = self.root / "LegadoKit"
        (self.package_root / "Sources/SourceRuntime").mkdir(parents=True)
        (self.package_root / "Sources/AppUseCases").mkdir(parents=True)
        self.package = {
            "targets": [
                {
                    "name": "SourceRuntime",
                    "type": "regular",
                    "dependencies": [],
                },
                {
                    "name": "AppUseCases",
                    "type": "regular",
                    "dependencies": [{"byName": ["SourceRuntime", None]}],
                },
            ],
            "products": [
                {"name": "Product", "targets": ["AppUseCases"]},
            ],
        }
        self.policy = {
            "schema_version": 1,
            "known_project_modules": ["SourceRuntime", "AppUseCases"],
            "known_external_modules": ["GRDB"],
            "targets": {
                "SourceRuntime": {
                    "dependencies": [],
                    "external_imports": [],
                    "forbidden_imports": ["SwiftUI"],
                },
                "AppUseCases": {
                    "dependencies": ["SourceRuntime"],
                    "external_imports": [],
                    "forbidden_imports": [],
                },
            },
            "test_targets": {},
            "banned_patterns": [
                {
                    "id": "ARCH-006-global-shared",
                    "pattern": r"\bstatic\s+(?:let|var)\s+shared\b",
                    "targets": ["SourceRuntime"],
                }
            ],
            "profiles": {
                "test": {
                    "root_product": "Product",
                    "required_targets": ["SourceRuntime", "AppUseCases"],
                    "forbidden_targets": [],
                }
            },
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_rejects_business_shared_singleton(self):
        (
            self.package_root / "Sources/SourceRuntime/Limiter.swift"
        ).write_text(
            "public actor Limiter { static let shared = Limiter() }\n",
            encoding="utf-8",
        )

        errors = package_contract.architecture_issues(
            self.package_root,
            self.package,
            self.policy,
        )

        self.assertTrue(
            any("ARCH-006-global-shared" in error for error in errors)
        )

    def test_accepts_constructor_scoped_actor_and_valid_profile(self):
        (
            self.package_root / "Sources/SourceRuntime/Limiter.swift"
        ).write_text(
            "public actor Limiter { public init() {} }\n",
            encoding="utf-8",
        )
        (
            self.package_root / "Sources/AppUseCases/UseCase.swift"
        ).write_text(
            "import SourceRuntime\npublic struct UseCase {}\n",
            encoding="utf-8",
        )

        self.assertEqual(
            [],
            package_contract.architecture_issues(
                self.package_root,
                self.package,
                self.policy,
            ),
        )

    def test_rejects_dependency_import_and_profile_drift(self):
        self.package["targets"][0]["dependencies"] = [
            {"byName": ["AppUseCases", None]}
        ]
        (
            self.package_root / "Sources/SourceRuntime/Limiter.swift"
        ).write_text(
            "import SwiftUI\nimport AppUseCases\npublic actor Limiter {}\n",
            encoding="utf-8",
        )
        self.policy["profiles"]["test"]["forbidden_targets"] = [
            "SourceRuntime"
        ]

        errors = package_contract.architecture_issues(
            self.package_root,
            self.package,
            self.policy,
        )

        self.assertTrue(any("Target 依赖越界" in error for error in errors))
        self.assertTrue(any("禁止 import SwiftUI" in error for error in errors))
        self.assertTrue(any("项目 import 越界" in error for error in errors))
        self.assertTrue(any("链接禁止 Target" in error for error in errors))

    def test_rejects_package_target_without_architecture_rule(self):
        self.package["targets"].append(
            {
                "name": "UnruledTests",
                "type": "test",
                "dependencies": [],
            }
        )

        errors = package_contract.architecture_issues(
            self.package_root,
            self.package,
            self.policy,
        )

        self.assertIn(
            "UnruledTests: Test Target 缺少架构规则",
            errors,
        )


if __name__ == "__main__":
    unittest.main()
