#!/usr/bin/env python3
"""Validate SwiftPM dependencies against the protected supply-chain policy."""

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from swiftpm_manifest import dump_package


def strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for entry in value:
            yield from strings(entry)
    elif isinstance(value, dict):
        for entry in value.values():
            yield from strings(entry)


def keyed_values(value: Any, key: str) -> Iterable[Any]:
    if isinstance(value, list):
        for entry in value:
            yield from keyed_values(entry, key)
    elif isinstance(value, dict):
        for child_key, child in value.items():
            if child_key == key:
                yield child
            yield from keyed_values(child, key)


def first_string(value: Any) -> Optional[str]:
    return next(strings(value), None)


def normalized_url(value: str) -> str:
    return value.lower().rstrip("/").removesuffix(".git")


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def dependency_policy_match(dependency: Any, packages: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    dependency_strings = list(strings(dependency))
    normalized_strings = {normalized_url(value) for value in dependency_strings}
    lowered_strings = {value.lower() for value in dependency_strings}
    for package in packages:
        if package["identity"].lower() in lowered_strings:
            return package
        if normalized_url(package["url"]) in normalized_strings:
            return package
    return None


def package_product_dependencies(target: Dict[str, Any]) -> Set[str]:
    result: Set[str] = set()
    for dependency in target.get("dependencies", []):
        if not isinstance(dependency, dict):
            continue
        product = dependency.get("product")
        if product is not None:
            name = first_string(product)
            if name:
                result.add(name)
    return result


def resolved_pins(value: Any) -> List[Dict[str, Any]]:
    if isinstance(value, dict) and isinstance(value.get("pins"), list):
        return [pin for pin in value["pins"] if isinstance(pin, dict)]
    if isinstance(value, dict) and isinstance(value.get("object"), dict):
        pins = value["object"].get("pins", [])
        return [pin for pin in pins if isinstance(pin, dict)]
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    policy_path = root / "ios/harness/dependency-policy.json"
    package_roots = [
        root / "ios/Packages/LegadoSourceKit",
        root / "ios/Packages/LegadoKit",
    ]
    baseline_path = root / "ios/project/baseline.json"
    errors: List[str] = []

    try:
        policy = load_json(policy_path)
    except (OSError, json.JSONDecodeError) as error:
        print(f"DEPENDENCY_CONTRACT: policy 无效：{error}", file=sys.stderr)
        return 1
    packages = policy.get("packages") if isinstance(policy, dict) else None
    if not isinstance(packages, list):
        print("DEPENDENCY_CONTRACT: policy.packages 必须是数组", file=sys.stderr)
        return 1
    identities: Set[str] = set()
    products: Dict[str, Dict[str, Any]] = {}
    for entry in packages:
        if not isinstance(entry, dict):
            errors.append("policy package 必须是 object")
            continue
        identity = entry.get("identity")
        if not isinstance(identity, str) or identity in identities:
            errors.append(f"package identity 无效或重复：{identity}")
            continue
        identities.add(identity)
        for product in entry.get("products", []):
            if product in products:
                errors.append(f"外部 product 被多个 package 声明：{product}")
            products[product] = entry
        if any(entry.get(flag) is not False for flag in ("allow_binary_targets", "allow_plugins", "allow_macros")):
            errors.append(f"{identity}: binary/plugin/macro 必须禁止")
        if entry.get("traits") != []:
            errors.append(f"{identity}: traits 必须为空")

    if not all(
        (package_root / "Package.swift").exists()
        for package_root in package_roots
    ):
        if any(entry.get("status") == "enabled" for entry in packages if isinstance(entry, dict)):
            errors.append("存在 enabled dependency，但 Package.swift 尚未创建")
    else:
        manifests = []
        for package_root in package_roots:
            result = dump_package(package_root, cwd=root, timeout=60)
            if result.returncode != 0:
                errors.append(
                    f"{package_root.name}: swift package dump-package 失败："
                    + (result.stderr or result.stdout)[-1000:]
                )
                continue
            try:
                manifests.append(json.loads(result.stdout))
            except json.JSONDecodeError as error:
                errors.append(
                    f"{package_root.name}: dump-package 输出不是 JSON：{error}"
                )

        found: Set[str] = set()
        for package in manifests:
            for dependency in package.get("dependencies", []):
                if (
                    isinstance(dependency, dict)
                    and "fileSystem" in dependency
                ):
                    continue
                entry = dependency_policy_match(dependency, packages)
                if entry is None:
                    errors.append(
                        "Package.swift 包含未登记 dependency："
                        + json.dumps(dependency, sort_keys=True)
                    )
                    continue
                identity = entry["identity"]
                found.add(identity)
                if entry.get("status") != "enabled":
                    errors.append(
                        f"{identity}: policy 状态不是 enabled，禁止出现在 Package.swift"
                    )
                exact_nodes = list(keyed_values(dependency, "exact"))
                if (
                    not exact_nodes
                    or entry.get("exact_version")
                    not in set(strings(exact_nodes))
                ):
                    errors.append(
                        f"{identity}: 必须使用 exact {entry.get('exact_version')}"
                    )
        for entry in packages:
            if isinstance(entry, dict) and entry.get("status") == "enabled" and entry.get("identity") not in found:
                errors.append(f"{entry.get('identity')}: policy enabled 但 Package.swift 未引用")

        for package in manifests:
            for target in package.get("targets", []):
                if not isinstance(target, dict):
                    continue
                target_name = target.get("name")
                target_type = target.get("type")
                if target_type in {"binary", "plugin", "macro"}:
                    errors.append(
                        f"禁止 {target_type} target：{target_name}"
                    )
                for product in package_product_dependencies(target):
                    entry = products.get(product)
                    if (
                        entry is not None
                        and target_name not in entry.get(
                            "allowed_targets",
                            [],
                        )
                    ):
                        errors.append(
                            f"外部 product {product} 未获准用于 Target {target_name}"
                        )

        enabled = [entry for entry in packages if isinstance(entry, dict) and entry.get("status") == "enabled"]
        lock_path = (
            root / "ios/Packages/LegadoKit/Package.resolved"
        )
        if enabled and not lock_path.exists():
            errors.append("存在 enabled dependency，但缺少 Package.resolved")
        elif enabled:
            try:
                pins = resolved_pins(load_json(lock_path))
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"Package.resolved 无效：{error}")
                pins = []
            for entry in enabled:
                matching = next(
                    (
                        pin
                        for pin in pins
                        if str(pin.get("identity") or pin.get("package") or "").lower()
                        == entry["identity"].lower()
                    ),
                    None,
                )
                if matching is None:
                    errors.append(f"Package.resolved 缺少 pin：{entry['identity']}")
                    continue
                state = matching.get("state", {})
                if state.get("version") != entry.get("exact_version"):
                    errors.append(f"{entry['identity']}: resolved version 与 policy 不一致")
                expected_revision = entry.get("expected_revision")
                if not isinstance(expected_revision, str) or not expected_revision:
                    errors.append(f"{entry['identity']}: enabled 时必须冻结 expected_revision")
                elif state.get("revision") != expected_revision:
                    errors.append(f"{entry['identity']}: resolved revision 与 policy 不一致")
            try:
                baseline = load_json(baseline_path)
                expected_digest = baseline.get("dependency_lock", {}).get("digest")
                actual_digest = hashlib.sha256(lock_path.read_bytes()).hexdigest()
                if expected_digest != actual_digest:
                    errors.append("Package.resolved hash 与受批准 baseline 不一致")
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"无法校验 dependency baseline：{error}")

    if errors:
        for error in errors:
            print(f"DEPENDENCY_CONTRACT: {error}", file=sys.stderr)
        return 1
    print("DEPENDENCY_CONTRACT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
