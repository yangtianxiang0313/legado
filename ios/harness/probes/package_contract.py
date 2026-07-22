#!/usr/bin/env python3
"""Protected contract probe for IOS-BOOT-001."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


REQUIRED_SOURCE_TARGETS = {
    "LegadoCore",
    "LibraryDomain",
    "SourceFormat",
    "RuleRuntime",
    "SourceRuntime",
    "ReaderCore",
    "AppUseCases",
    "TestSupport",
    "ConformanceCLI",
}
REQUIRED_TEST_TARGETS = {
    "LegadoCoreTests",
    "SourceRuntimeTests",
    "TestSupportTests",
    "ConformanceCLITests",
    "SourceFormatTests",
}
REQUIRED_LIBRARY_PRODUCTS = {
    "LegadoStoreSafeKit",
    "LegadoFullCompatKit",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    package_root = root / "ios/Packages/LegadoKit"
    manifest_path = package_root / "Package.swift"
    errors = []
    if not manifest_path.exists():
        print("PACKAGE_CONTRACT: 缺少 Package.swift", file=sys.stderr)
        return 1
    text = manifest_path.read_text(encoding="utf-8")
    first_line = text.splitlines()[0] if text.splitlines() else ""
    if not re.fullmatch(r"//\s*swift-tools-version:\s*6\.2", first_line):
        errors.append("swift-tools-version 必须精确为 6.2")
    if not re.search(r"\.iOS\s*\(\s*\.v17\s*\)", text):
        errors.append("Package 必须显式声明 iOS 17")
    if not re.search(r"\.macOS\s*\(\s*\.v14\s*\)", text):
        errors.append("Package 必须显式声明 macOS 14")
    if not re.search(r"swiftLanguageModes\s*:\s*\[\s*\.v6\s*\]", text):
        errors.append("Package 必须显式声明 swiftLanguageModes: [.v6]")

    format_path = package_root / ".swift-format"
    if not format_path.exists():
        errors.append("缺少受版本控制的 .swift-format")
    else:
        try:
            json.loads(format_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            errors.append(f".swift-format 不是有效 JSON：{error}")

    command = ["swift", "package", "--package-path", str(package_root), "dump-package"]
    result = subprocess.run(command, cwd=str(root), capture_output=True, text=True, check=False)
    if result.returncode != 0:
        errors.append("swift package dump-package 失败：" + (result.stderr or result.stdout)[-1000:])
    else:
        try:
            package = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            errors.append(f"dump-package 输出不是 JSON：{error}")
            package = {}
        if package.get("dependencies"):
            errors.append("Bootstrap Package 不得包含外部依赖")
        targets = {target.get("name"): target for target in package.get("targets", [])}
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
        products = package.get("products", [])
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

    for name in sorted(REQUIRED_SOURCE_TARGETS):
        directory = package_root / "Sources" / name
        if not directory.exists() or not any(directory.rglob("*.swift")):
            errors.append(f"{name} 缺少可编译 Swift 源码")
    for name in sorted(REQUIRED_TEST_TARGETS):
        directory = package_root / "Tests" / name
        if not directory.exists() or not any(directory.rglob("*.swift")):
            errors.append(f"{name} 缺少 Swift 测试源码")

    if errors:
        for error in errors:
            print(f"PACKAGE_CONTRACT: {error}", file=sys.stderr)
        return 1
    print("PACKAGE_CONTRACT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
