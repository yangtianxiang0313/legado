#!/usr/bin/env python3
"""Protected contract probe for IOS-BOOT-001."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swiftpm_manifest import dump_package


REQUIRED_SOURCE_TARGETS = {
    "LegadoCore",
    "LibraryDomain",
    "SourceFormat",
    "RuleRuntime",
    "SourceRuntime",
    "HTMLSwiftSoup",
    "ScriptJavaScriptCore",
    "ReaderCore",
    "AppUseCases",
    "AppNavigation",
    "SourceRuntimeComposition",
    "SourceScriptComposition",
    "DatabaseGRDB",
    "TestSupport",
    "ConformanceCLI",
}
REQUIRED_TEST_TARGETS = {
    "LegadoCoreTests",
    "SourceRuntimeTests",
    "HTMLSwiftSoupTests",
    "ScriptJavaScriptCoreTests",
    "TestSupportTests",
    "ConformanceCLITests",
    "SourceFormatTests",
    "AppNavigationTests",
    "DatabaseGRDBTests",
}
REQUIRED_LIBRARY_PRODUCTS = {
    "LegadoCoreKit",
    "LegadoSourceRuntimeKit",
    "LegadoHTMLSwiftSoupKit",
    "LegadoScriptJavaScriptCoreKit",
    "LegadoSourceStoreSafeKit",
    "LegadoSourceFullCompatKit",
    "LegadoStoreSafeKit",
    "LegadoFullCompatKit",
}


def dependency_name(value):
    if not isinstance(value, dict):
        return None
    for key in ("byName", "target", "product"):
        candidate = value.get(key)
        if isinstance(candidate, list) and candidate:
            return candidate[0] if isinstance(candidate[0], str) else None
        if isinstance(candidate, str):
            return candidate
    return None


def swift_imports(text):
    return {
        match.group(1)
        for match in re.finditer(
            r"(?m)^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)\b",
            text,
        )
    }


def target_closure(root_targets, dependencies):
    result = set()
    pending = list(root_targets)
    while pending:
        name = pending.pop()
        if name in result:
            continue
        result.add(name)
        pending.extend(dependencies.get(name, set()) - result)
    return result


def architecture_issues(
    package_root,
    package,
    policy,
    target_roots=None,
    all_products=None,
):
    errors = []
    if not isinstance(policy, dict) or policy.get("schema_version") != 1:
        return ["architecture-rules.json schema_version 无效"]
    target_rules = policy.get("targets")
    test_rules = policy.get("test_targets")
    banned_patterns = policy.get("banned_patterns")
    profiles = policy.get("profiles")
    known_project = set(policy.get("known_project_modules", []))
    known_external = set(policy.get("known_external_modules", []))
    if not isinstance(target_rules, dict) or not isinstance(test_rules, dict):
        return ["architecture-rules.json targets/test_targets 无效"]
    if not isinstance(banned_patterns, list) or not isinstance(profiles, dict):
        return ["architecture-rules.json banned_patterns/profiles 无效"]

    package_targets = {
        target.get("name"): target
        for target in package.get("targets", [])
        if isinstance(target, dict) and isinstance(target.get("name"), str)
    }
    if target_roots is None:
        target_roots = {name: package_root for name in package_targets}
    products = all_products or {
        product.get("name"): product
        for product in package.get("products", [])
        if isinstance(product, dict) and isinstance(product.get("name"), str)
    }
    for name, target in package_targets.items():
        target_type = target.get("type")
        if target_type == "test" and name not in test_rules:
            errors.append(f"{name}: Test Target 缺少架构规则")
        elif target_type in {"regular", "executable"} and name not in target_rules:
            errors.append(f"{name}: Target 缺少架构规则")

    dependencies = {}
    for name, target in package_targets.items():
        dependencies[name] = set()
        for dependency in map(
            dependency_name,
            target.get("dependencies", []),
        ):
            if not isinstance(dependency, str):
                continue
            if dependency in known_project:
                dependencies[name].add(dependency)
            product = products.get(dependency)
            if isinstance(product, dict):
                dependencies[name].update(
                    target_name
                    for target_name in product.get("targets", [])
                    if target_name in known_project
                )

    for name, rules in {**target_rules, **test_rules}.items():
        target = package_targets.get(name)
        if target is None:
            continue
        allowed_dependencies = set(rules.get("dependencies", []))
        unexpected = dependencies.get(name, set()) - allowed_dependencies
        if unexpected:
            errors.append(
                f"{name}: Target 依赖越界 " + ", ".join(sorted(unexpected))
            )

        source_parent = "Tests" if name in test_rules else "Sources"
        owner_root = target_roots.get(name, package_root)
        directory = owner_root / source_parent / name
        for path in sorted(directory.rglob("*.swift")) if directory.exists() else []:
            relative = path.relative_to(owner_root).as_posix()
            text = path.read_text(encoding="utf-8")
            imports = swift_imports(text)
            forbidden = imports & set(rules.get("forbidden_imports", []))
            if forbidden:
                errors.append(
                    f"{relative}: 禁止 import " + ", ".join(sorted(forbidden))
                )
            project_imports = imports & known_project
            unexpected_imports = project_imports - allowed_dependencies - {name}
            if unexpected_imports:
                errors.append(
                    f"{relative}: 项目 import 越界 "
                    + ", ".join(sorted(unexpected_imports))
                )
            external_imports = imports & known_external
            unexpected_external = external_imports - set(
                rules.get("external_imports", [])
            )
            if unexpected_external:
                errors.append(
                    f"{relative}: 外部 import 未授权 "
                    + ", ".join(sorted(unexpected_external))
                )
            for entry in banned_patterns:
                if not isinstance(entry, dict):
                    errors.append("architecture-rules.json banned pattern 无效")
                    continue
                targets = entry.get("targets", [])
                pattern = entry.get("pattern")
                if (
                    isinstance(pattern, str)
                    and isinstance(targets, list)
                    and ("*" in targets or name in targets)
                    and re.search(pattern, text)
                ):
                    errors.append(
                        f"{relative}: 命中 {entry.get('id', 'banned-pattern')}"
                    )

    for profile_name, profile in profiles.items():
        if not isinstance(profile, dict):
            errors.append(f"profile {profile_name} 无效")
            continue
        product = products.get(profile.get("root_product"))
        if product is None:
            errors.append(f"profile {profile_name} 缺少 root product")
            continue
        closure = target_closure(product.get("targets", []), dependencies)
        missing = set(profile.get("required_targets", [])) - closure
        forbidden = set(profile.get("forbidden_targets", [])) & closure
        if missing:
            errors.append(
                f"profile {profile_name} 缺少 Target " + ", ".join(sorted(missing))
            )
        if forbidden:
            errors.append(
                f"profile {profile_name} 链接禁止 Target "
                + ", ".join(sorted(forbidden))
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    package_roots = [
        root / "ios/Packages/LegadoCoreKit",
        root / "ios/Packages/LegadoSourceKit",
        root / "ios/Packages/LegadoKit",
    ]
    errors = []
    packages = []
    target_roots = {}
    for package_root in package_roots:
        manifest_path = package_root / "Package.swift"
        if not manifest_path.exists():
            errors.append(
                f"{package_root.name}: 缺少 Package.swift"
            )
            continue
        text = manifest_path.read_text(encoding="utf-8")
        first_line = text.splitlines()[0] if text.splitlines() else ""
        if not re.fullmatch(
            r"//\s*swift-tools-version:\s*6\.2",
            first_line,
        ):
            errors.append(
                f"{package_root.name}: swift-tools-version 必须精确为 6.2"
            )
        if not re.search(r"\.iOS\s*\(\s*\.v17\s*\)", text):
            errors.append(
                f"{package_root.name}: 必须显式声明 iOS 17"
            )
        if not re.search(r"\.macOS\s*\(\s*\.v14\s*\)", text):
            errors.append(
                f"{package_root.name}: 必须显式声明 macOS 14"
            )
        if not re.search(
            r"swiftLanguageModes\s*:\s*\[\s*\.v6\s*\]",
            text,
        ):
            errors.append(
                f"{package_root.name}: 必须显式声明 Swift 6"
            )

        format_path = package_root / ".swift-format"
        if not format_path.exists():
            errors.append(
                f"{package_root.name}: 缺少受版本控制的 .swift-format"
            )
        else:
            try:
                json.loads(format_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as error:
                errors.append(
                    f"{package_root.name}: .swift-format 无效：{error}"
                )

        result = dump_package(package_root, cwd=root, timeout=60)
        if result.returncode != 0:
            errors.append(
                f"{package_root.name}: dump-package 失败："
                + (result.stderr or result.stdout)[-1000:]
            )
            continue
        try:
            package = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            errors.append(
                f"{package_root.name}: dump-package 输出无效：{error}"
            )
            continue
        packages.append(package)
        for target in package.get("targets", []):
            name = target.get("name")
            if isinstance(name, str):
                if name in target_roots:
                    errors.append(f"Target 重复声明：{name}")
                target_roots[name] = package_root

    if packages:
        merged = {
            "targets": [
                target
                for package in packages
                for target in package.get("targets", [])
            ],
            "products": [
                product
                for package in packages
                for product in package.get("products", [])
            ],
        }
        targets = {
            target.get("name"): target
            for target in merged["targets"]
        }
        missing_sources = sorted(REQUIRED_SOURCE_TARGETS - set(targets))
        missing_tests = sorted(REQUIRED_TEST_TARGETS - set(targets))
        if missing_sources:
            errors.append("缺少 source/executable targets：" + ", ".join(missing_sources))
        if missing_tests:
            errors.append("缺少 test targets：" + ", ".join(missing_tests))
        if targets.get("ConformanceCLI", {}).get("type") != "executable":
            errors.append("ConformanceCLI 必须是 executable target")
        for name in REQUIRED_TEST_TARGETS:
            if name in targets and targets[name].get("type") != "test":
                errors.append(f"{name} 必须是 test target")
        products = merged["products"]
        if not any(
            product.get("name") == "ConformanceCLI"
            and isinstance(product.get("type"), dict)
            and "executable" in product["type"]
            for product in products
            if isinstance(product, dict)
        ):
            errors.append("缺少 ConformanceCLI executable product")
        library_products = {
            product.get("name")
            for product in products
            if isinstance(product, dict)
            and isinstance(product.get("type"), dict)
            and "library" in product["type"]
        }
        missing_products = sorted(REQUIRED_LIBRARY_PRODUCTS - library_products)
        if missing_products:
            errors.append("缺少发行 library products：" + ", ".join(missing_products))
        architecture_path = root / "ios/harness/architecture-rules.json"
        try:
            architecture = json.loads(architecture_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            errors.append(f"architecture-rules.json 无效：{error}")
        else:
            all_products = {
                product.get("name"): product
                for product in products
                if isinstance(product, dict)
                and isinstance(product.get("name"), str)
            }
            errors.extend(
                architecture_issues(
                    root / "ios/Packages/LegadoKit",
                    merged,
                    architecture,
                    target_roots=target_roots,
                    all_products=all_products,
                )
            )

    for name in sorted(REQUIRED_SOURCE_TARGETS):
        package_root = target_roots.get(name)
        directory = (
            package_root / "Sources" / name
            if package_root is not None
            else None
        )
        if (
            directory is None
            or not directory.exists()
            or not any(directory.rglob("*.swift"))
        ):
            errors.append(f"{name} 缺少可编译 Swift 源码")
    for name in sorted(REQUIRED_TEST_TARGETS):
        package_root = target_roots.get(name)
        directory = (
            package_root / "Tests" / name
            if package_root is not None
            else None
        )
        if (
            directory is None
            or not directory.exists()
            or not any(directory.rglob("*.swift"))
        ):
            errors.append(f"{name} 缺少 Swift 测试源码")

    if errors:
        for error in errors:
            print(f"PACKAGE_CONTRACT: {error}", file=sys.stderr)
        return 1
    print("PACKAGE_CONTRACT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
