#!/usr/bin/env python3
"""Deterministic local origin and contract checks for Legado book sources."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import http.client
import http.server
import json
import os
import re
import socket
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence, Set, Tuple


LOGICAL_ORIGIN = "http://sourcelab.test"
SOURCE_PLACEHOLDER = "${SOURCE_LAB_ORIGIN}"
FIXTURE_ROOT = Path("ios/harness/fixtures/source-lab")
CONTROL_ROOT = Path("ios/harness/source-lab")
SCENARIO_ID = re.compile(r"^sl-[a-z0-9-]+-[0-9]{3}$")
FIXED_DATE = "Thu, 01 Jan 1970 00:00:00 GMT"
ALLOWED_RESPONSE_HEADERS = {"content-type", "cache-control", "content-encoding", "location", "set-cookie"}
CANDIDATE_CHARACTERIZATION_LABELS = {"android-oracle", "candidate-only"}
CANDIDATE_ATTESTATION_LABELS = {"attestation", "github-actions"}
CANDIDATE_ATTESTATION_ALLOWED_WRITES = {
    ".github/workflows/android-oracle-attestation.yml",
}
CANDIDATE_CHARACTERIZATION_FORBIDDEN_WRITES = (
    ".github/",
    "app/",
    "modules/",
    "ios/Packages/",
    "ios/publisher/",
    "ios/harness/fixtures/",
    "ios/harness/goldens/",
    "ios/harness/source-lab/source_lab.py",
    "ios/harness/source-lab/coverage-policy-v1.json",
    "ios/harness/source-lab/manifest.json",
)


class SourceLabError(RuntimeError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise SourceLabError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise SourceLabError(f"JSON 无效：{path}:{error.lineno}:{error.colno}: {error.msg}") from error


def recursive_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for entry in value:
            yield from recursive_strings(entry)
    elif isinstance(value, dict):
        for entry in value.values():
            yield from recursive_strings(entry)


def forbidden_business_keys(value: Any) -> List[str]:
    forbidden = re.compile(r"(?i)(?:^|_)(expected|golden|canonical|result|output|issue)(?:$|_)")
    found: List[str] = []
    if isinstance(value, dict):
        for key, entry in value.items():
            if isinstance(key, str) and forbidden.search(key):
                found.append(key)
            found.extend(forbidden_business_keys(entry))
    elif isinstance(value, list):
        for entry in value:
            found.extend(forbidden_business_keys(entry))
    return found


def replace_strings(value: Any, old: str, new: str) -> Any:
    if isinstance(value, str):
        return value.replace(old, new)
    if isinstance(value, list):
        return [replace_strings(entry, old, new) for entry in value]
    if isinstance(value, dict):
        return {key: replace_strings(entry, old, new) for key, entry in value.items()}
    return value


def safe_child(directory: Path, relative: str) -> Path:
    candidate_relative = Path(relative)
    if candidate_relative.is_absolute() or ".." in candidate_relative.parts or not candidate_relative.parts:
        raise SourceLabError(f"场景路径越界：{relative}")
    candidate = directory / candidate_relative
    current = directory
    for part in candidate_relative.parts:
        current = current / part
        if current.is_symlink():
            raise SourceLabError(f"场景禁止 symlink：{current}")
    try:
        candidate.resolve().relative_to(directory.resolve())
    except ValueError as error:
        raise SourceLabError(f"场景路径越界：{relative}") from error
    if not candidate.is_file():
        raise SourceLabError(f"场景文件不存在：{candidate}")
    return candidate


def scenario_directories(root: Path) -> List[Path]:
    fixture_root = root / FIXTURE_ROOT
    if not fixture_root.exists():
        return []
    return sorted(path.parent for path in fixture_root.glob("*/case.json"))


def scenario_directory(root: Path, scenario_id: str) -> Path:
    matches = [path for path in scenario_directories(root) if path.name == scenario_id]
    if len(matches) != 1:
        raise SourceLabError(f"SourceLab scenario 不存在或不唯一：{scenario_id}")
    return matches[0]


def load_scenario(root: Path, scenario_id: str) -> Tuple[Path, Dict[str, Any], Dict[str, Any]]:
    directory = scenario_directory(root, scenario_id)
    case = load_json(directory / "case.json")
    if not isinstance(case, dict):
        raise SourceLabError(f"scenario case 必须是 object：{scenario_id}")
    input_path = safe_child(directory, str(case.get("input", "")))
    inputs = load_json(input_path)
    if not isinstance(inputs, dict):
        raise SourceLabError(f"scenario input 必须是 object：{scenario_id}")
    return directory, case, inputs


def validate_origin(origin: str) -> None:
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme != "http" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise SourceLabError(f"SourceLab origin 无效：{origin}")
    if parsed.path not in {"", "/"}:
        raise SourceLabError(f"SourceLab origin 不能包含 path：{origin}")
    if parsed.hostname == "sourcelab.test" and parsed.port is None:
        return
    if parsed.hostname != "127.0.0.1" or parsed.port is None or not 1 <= parsed.port <= 65535:
        raise SourceLabError("SourceLab 只允许逻辑 origin 或 127.0.0.1 的已绑定端口")


def build_source(root: Path, scenario_id: str, origin: str) -> Dict[str, Any]:
    validate_origin(origin)
    directory, case, _ = load_scenario(root, scenario_id)
    source_path = safe_child(directory, str(case.get("source", "")))
    source = load_json(source_path)
    if not isinstance(source, dict):
        raise SourceLabError("书源模板根必须是 object")
    rendered = replace_strings(source, SOURCE_PLACEHOLDER, origin.rstrip("/"))
    required = {"bookSourceUrl", "bookSourceName", "searchUrl", "ruleSearch", "ruleBookInfo", "ruleToc", "ruleContent"}
    missing = sorted(required - set(rendered))
    if missing:
        raise SourceLabError("书源模板缺少字段：" + ", ".join(missing))
    if any(SOURCE_PLACEHOLDER in value for value in recursive_strings(rendered)):
        raise SourceLabError("书源构建后仍含 origin placeholder")
    return rendered


def route_signature(route: Dict[str, Any]) -> Tuple[str, str, Tuple[Tuple[str, str], ...]]:
    match = route["match"]
    query = tuple(sorted((str(key), str(value)) for key, value in match.get("query", {}).items()))
    return str(match["method"]), str(match["path"]), query


def validate_scenario(root: Path, directory: Path, case: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    scenario_id = case.get("id")
    required_top = {
        "schema_version", "kind", "id", "revision", "status", "operation", "capabilities",
        "compatibility_profile", "source", "input", "transport", "coverage", "determinism", "limits", "provenance",
    }
    extras = sorted(set(case) - required_top)
    missing = sorted(required_top - set(case))
    if extras:
        errors.append(f"{scenario_id}: 不允许的 case 字段：{', '.join(extras)}")
    if missing:
        errors.append(f"{scenario_id}: 缺少 case 字段：{', '.join(missing)}")
    if scenario_id != directory.name or not isinstance(scenario_id, str) or not SCENARIO_ID.fullmatch(scenario_id):
        errors.append(f"scenario ID/目录无效：{directory}")
    if case.get("kind") != "source_lab_scenario" or case.get("operation") != "source_lab_site":
        errors.append(f"{scenario_id}: kind/operation 无效")
    if case.get("status") not in {"candidate", "reference", "retired"}:
        errors.append(f"{scenario_id}: status 无效")
    determinism = case.get("determinism")
    if not isinstance(determinism, dict):
        errors.append(f"{scenario_id}: determinism 必须是 object")
    elif (
        determinism.get("network_allowed") is not False
        or determinism.get("logical_origin") != LOGICAL_ORIGIN
        or determinism.get("timezone") != "UTC"
        or determinism.get("locale") != "en_US_POSIX"
    ):
        errors.append(f"{scenario_id}: determinism/network/logical origin 无效")
    limits = case.get("limits")
    if not isinstance(limits, dict):
        errors.append(f"{scenario_id}: limits 必须是 object")
        limits = {}
    for key, maximum in {
        "timeout_ms": 5000,
        "max_response_bytes": 10 * 1024 * 1024,
        "max_request_body_bytes": 1024 * 1024,
        "max_requests": 1000,
        "max_concurrency": 32,
    }.items():
        value = limits.get(key)
        if not isinstance(value, int) or value < (0 if key == "max_request_body_bytes" else 1) or value > maximum:
            errors.append(f"{scenario_id}: limits.{key} 无效")

    try:
        source_path = safe_child(directory, str(case.get("source", "")))
        input_path = safe_child(directory, str(case.get("input", "")))
        source = load_json(source_path)
        inputs = load_json(input_path)
        if not isinstance(source, dict):
            errors.append(f"{scenario_id}: source 必须是 object")
        else:
            if source.get("bookSourceUrl") != SOURCE_PLACEHOLDER:
                errors.append(f"{scenario_id}: bookSourceUrl 必须使用 run-scoped origin placeholder")
            for value in recursive_strings(source):
                if ("http://" in value or "https://" in value) and LOGICAL_ORIGIN not in value and SOURCE_PLACEHOLDER not in value:
                    errors.append(f"{scenario_id}: source 含外部 URL")
                    break
        if not isinstance(inputs, dict) or not isinstance(inputs.get("cases"), list):
            errors.append(f"{scenario_id}: input.cases 必须是数组")
            input_cases: Dict[str, Dict[str, Any]] = {}
        else:
            input_cases = {}
            for entry in inputs["cases"]:
                if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
                    errors.append(f"{scenario_id}: input case 无效")
                    continue
                allowed_input_fields = {"id", "operation", "arguments", "request"}
                if set(entry) != allowed_input_fields:
                    errors.append(f"{scenario_id}: input case 只能描述刺激，禁止业务 expected 字段：{entry['id']}")
                forbidden_keys = forbidden_business_keys(entry)
                if forbidden_keys:
                    errors.append(
                        f"{scenario_id}: input case 递归包含业务答案字段：{entry['id']}/{','.join(sorted(set(forbidden_keys)))}"
                    )
                if entry["id"] in input_cases:
                    errors.append(f"{scenario_id}: input case ID 重复：{entry['id']}")
                input_cases[entry["id"]] = entry
    except SourceLabError as error:
        errors.append(str(error))
        input_cases = {}

    transport = case.get("transport")
    if not isinstance(transport, dict) or transport.get("mode") != "fixture_and_loopback" or transport.get("external_network") != "deny":
        errors.append(f"{scenario_id}: transport 必须为 fixture_and_loopback 且禁止外网")
        routes: Sequence[Any] = []
    else:
        routes = transport.get("responses", [])
    signatures: Set[Tuple[str, str, Tuple[Tuple[str, str], ...]]] = set()
    route_ids: Set[str] = set()
    for route in routes if isinstance(routes, list) else []:
        if not isinstance(route, dict) or set(route) != {"id", "match", "respond"}:
            errors.append(f"{scenario_id}: route 结构无效")
            continue
        route_id = route.get("id")
        match = route.get("match")
        respond = route.get("respond")
        if not isinstance(route_id, str) or route_id in route_ids:
            errors.append(f"{scenario_id}: route ID 无效或重复：{route_id}")
            continue
        route_ids.add(route_id)
        if not isinstance(match, dict) or set(match) != {"method", "path", "query"}:
            errors.append(f"{scenario_id}: route match 无效：{route_id}")
            continue
        path = match.get("path")
        query = match.get("query")
        if match.get("method") not in {"GET", "POST"} or not isinstance(path, str) or not path.startswith("/") or path.startswith("//"):
            errors.append(f"{scenario_id}: route method/path 无效：{route_id}")
        if not isinstance(query, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in query.items()):
            errors.append(f"{scenario_id}: route query 只能是字符串 map：{route_id}")
        else:
            signature = route_signature(route)
            if signature in signatures:
                errors.append(f"{scenario_id}: route signature 重复：{route_id}")
            signatures.add(signature)
        if not isinstance(respond, dict) or set(respond) != {"status", "headers", "body_file"}:
            errors.append(f"{scenario_id}: route respond 无效：{route_id}")
            continue
        status = respond.get("status")
        headers = respond.get("headers")
        if not isinstance(status, int) or not 100 <= status <= 599:
            errors.append(f"{scenario_id}: route status 无效：{route_id}")
        if not isinstance(headers, dict):
            errors.append(f"{scenario_id}: route headers 无效：{route_id}")
        else:
            for key, value in headers.items():
                if key.lower() not in ALLOWED_RESPONSE_HEADERS or not isinstance(value, str) or "\r" in value or "\n" in value:
                    errors.append(f"{scenario_id}: route header 未批准：{route_id}/{key}")
        try:
            body_path = safe_child(directory, str(respond.get("body_file", "")))
            if body_path.stat().st_size > limits.get("max_response_bytes", 0):
                errors.append(f"{scenario_id}: route body 超限：{route_id}")
        except SourceLabError as error:
            errors.append(str(error))

    coverage = case.get("coverage")
    if not isinstance(coverage, list):
        errors.append(f"{scenario_id}: coverage 必须是数组")
    else:
        seen_behaviors: Set[str] = set()
        for entry in coverage:
            if not isinstance(entry, dict) or set(entry) != {"behavior", "cases"}:
                errors.append(f"{scenario_id}: coverage entry 无效")
                continue
            behavior = entry.get("behavior")
            if not isinstance(behavior, str) or behavior in seen_behaviors:
                errors.append(f"{scenario_id}: behavior 无效或重复：{behavior}")
                continue
            seen_behaviors.add(behavior)
            role_cases = entry.get("cases")
            if not isinstance(role_cases, list) or not role_cases:
                errors.append(f"{scenario_id}: {behavior}.cases 不能为空")
                continue
            seen_case_roles: Set[Tuple[str, str]] = set()
            for role_case in role_cases:
                if not isinstance(role_case, dict) or set(role_case) != {
                    "id", "role", "android_fact_refs", "branch_refs"
                }:
                    errors.append(f"{scenario_id}: {behavior} case-role 结构无效")
                    continue
                case_id = role_case.get("id")
                role = role_case.get("role")
                if case_id not in input_cases:
                    errors.append(f"{scenario_id}: {behavior} 引用未知 input case：{case_id}")
                if role not in {"nominal", "boundary", "malformed", "denied"}:
                    errors.append(f"{scenario_id}: {behavior} case role 无效：{role}")
                key = (str(case_id), str(role))
                if key in seen_case_roles:
                    errors.append(f"{scenario_id}: {behavior} case-role 重复：{case_id}/{role}")
                seen_case_roles.add(key)
                fact_refs = role_case.get("android_fact_refs")
                branch_refs = role_case.get("branch_refs")
                if not isinstance(fact_refs, list) or not fact_refs or any(
                    not isinstance(value, str) or re.fullmatch(r"AF-[A-Z0-9-]+", value) is None
                    for value in fact_refs
                ):
                    errors.append(f"{scenario_id}: {behavior}/{case_id} 缺少合法 android_fact_refs")
                if not isinstance(branch_refs, list) or not branch_refs or any(
                    not isinstance(value, str) or not value.strip() for value in branch_refs
                ):
                    errors.append(f"{scenario_id}: {behavior}/{case_id} 缺少 branch_refs")
    return errors


def coverage_policy(root: Path) -> Dict[str, Dict[str, Any]]:
    value = load_json(root / CONTROL_ROOT / "coverage-policy-v1.json")
    if not isinstance(value, dict) or not isinstance(value.get("behaviors"), list):
        raise SourceLabError("coverage policy 无效")
    roles = value.get("roles")
    if not isinstance(roles, list) or set(roles) != {"nominal", "boundary", "malformed", "denied"}:
        raise SourceLabError("coverage policy.roles 无效")
    result: Dict[str, Dict[str, Any]] = {}
    for entry in value["behaviors"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or entry["id"] in result:
            raise SourceLabError("coverage policy behavior 无效或重复")
        required_roles = entry.get("required_roles")
        if not isinstance(required_roles, list) or not required_roles or not set(required_roles) <= set(roles):
            raise SourceLabError(f"coverage policy.required_roles 无效：{entry.get('id')}")
        if not isinstance(entry.get("min_cases_per_role"), int) or entry["min_cases_per_role"] < 1:
            raise SourceLabError(f"coverage policy.min_cases_per_role 无效：{entry.get('id')}")
        result[entry["id"]] = entry
    return result


def manifest_value(root: Path) -> Dict[str, Any]:
    scenarios: List[Dict[str, Any]] = []
    coverage: Dict[str, Dict[str, List[str]]] = {}
    for directory in scenario_directories(root):
        case = load_json(directory / "case.json")
        file_entries = []
        for path in sorted(entry for entry in directory.rglob("*") if entry.is_file() and not entry.is_symlink()):
            file_entries.append({
                "path": path.relative_to(directory).as_posix(),
                "sha256": sha256_bytes(path.read_bytes()),
                "bytes": path.stat().st_size,
            })
        scenarios.append({
            "id": case.get("id"),
            "status": case.get("status"),
            "path": directory.relative_to(root).as_posix(),
            "sha256": sha256_bytes(canonical_bytes(file_entries)),
        })
        if case.get("status") == "reference":
            for entry in case.get("coverage", []):
                if not isinstance(entry, dict) or not isinstance(entry.get("behavior"), str):
                    continue
                bucket = coverage.setdefault(entry["behavior"], {})
                for role_case in entry.get("cases", []):
                    if not isinstance(role_case, dict):
                        continue
                    role = role_case.get("role")
                    case_id = role_case.get("id")
                    if isinstance(role, str) and isinstance(case_id, str):
                        bucket.setdefault(role, []).append(f"{case.get('id')}:{case_id}")

    control_files = []
    control_root = root / CONTROL_ROOT
    for path in sorted(entry for entry in control_root.rglob("*") if entry.is_file()):
        if path.name == "manifest.json" or "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        control_files.append({
            "path": path.relative_to(root).as_posix(),
            "sha256": sha256_bytes(path.read_bytes()),
            "bytes": path.stat().st_size,
        })
    schema_path = root / "ios/harness/schemas/source-lab-scenario.schema.json"
    control_files.append({
        "path": schema_path.relative_to(root).as_posix(),
        "sha256": sha256_bytes(schema_path.read_bytes()),
        "bytes": schema_path.stat().st_size,
    })
    return {
        "schema_version": 1,
        "logical_origin": LOGICAL_ORIGIN,
        "control_sha256": sha256_bytes(canonical_bytes(control_files)),
        "scenarios": sorted(scenarios, key=lambda entry: entry["id"]),
        "coverage": {
            behavior: {
                role: sorted(set(cases))
                for role, cases in sorted(values.items())
            }
            for behavior, values in sorted(coverage.items())
        },
    }


def validate_work_item_contract(root: Path, work_item_id: str, manifest: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    item_path = root / "ios/harness/work-items" / f"{work_item_id}.json"
    try:
        item = load_json(item_path)
    except SourceLabError as error:
        return [str(error)]
    source_lab = item.get("spec", {}).get("source_lab") if isinstance(item, dict) else None
    if not isinstance(source_lab, dict):
        return [f"{work_item_id}: 缺少 spec.source_lab"]
    mode = source_lab.get("mode")
    behaviors = source_lab.get("behaviors")
    scenarios = source_lab.get("scenarios")
    none_reason = source_lab.get("none_reason")
    if mode not in {"not_applicable", "reuse", "extend"}:
        errors.append(f"{work_item_id}: source_lab.mode 无效")
        return errors
    if not isinstance(behaviors, list) or any(not isinstance(entry, str) for entry in behaviors):
        errors.append(f"{work_item_id}: source_lab.behaviors 必须是字符串数组")
        behaviors = []
    if not isinstance(scenarios, list) or any(not isinstance(entry, str) for entry in scenarios):
        errors.append(f"{work_item_id}: source_lab.scenarios 必须是字符串数组")
        scenarios = []
    if mode == "not_applicable":
        if behaviors or scenarios or not isinstance(none_reason, str) or not none_reason.strip():
            errors.append(f"{work_item_id}: SourceLab 不适用时必须清空引用并填写 none_reason")
        return errors
    if not behaviors or not scenarios or none_reason is not None:
        errors.append(f"{work_item_id}: SourceLab reuse/extend 必须声明 behavior/scenario，none_reason 为 null")
    indexed_scenarios = {entry.get("id"): entry for entry in manifest.get("scenarios", [])}
    selected_statuses: Set[str] = set()
    for scenario_id in scenarios:
        entry = indexed_scenarios.get(scenario_id)
        if entry is None:
            errors.append(f"{work_item_id}: SourceLab scenario 未进入 manifest：{scenario_id}")
            continue
        status = entry.get("status")
        if isinstance(status, str):
            selected_statuses.add(status)
        if mode == "reuse" and status == "candidate":
            errors.extend(
                validate_candidate_characterization(
                    root,
                    work_item_id,
                    item,
                    scenario_id,
                    behaviors,
                )
            )
        elif mode == "reuse" and status != "reference":
            errors.append(
                f"{work_item_id}: reuse 只能使用 reference 或受限 "
                f"Android characterization candidate scenario：{scenario_id}"
            )
    coverage = manifest.get("coverage", {})
    if mode == "reuse":
        if len(selected_statuses) > 1:
            errors.append(
                f"{work_item_id}: reuse 不得混用 reference 与 candidate scenario"
            )
        if selected_statuses == {"reference"}:
            policy = coverage_policy(root)
            for behavior in behaviors:
                covered = coverage.get(behavior, {})
                rule = policy.get(behavior)
                if rule is None:
                    errors.append(f"{work_item_id}: behavior 未登记 policy：{behavior}")
                    continue
                minimum = rule.get("min_cases_per_role", 1)
                for role in rule.get("required_roles", []):
                    cases = covered.get(role, [])
                    selected = [value for value in cases if value.split(":", 1)[0] in scenarios]
                    if len(selected) < minimum:
                        errors.append(
                            f"{work_item_id}: 所选 reference scenario 缺少 {behavior}/{role} 覆盖"
                        )
    if mode == "extend":
        if "scenario-provenance-review" not in item.get("spec", {}).get("gates", []):
            errors.append(f"{work_item_id}: 扩展 SourceLab 必须声明 scenario-provenance-review gate")
        introduced = False
        candidate_coverage: Dict[str, Dict[str, int]] = {}
        for scenario_id in scenarios:
            try:
                _, case, _ = load_scenario(root, scenario_id)
            except SourceLabError:
                continue
            if case.get("status") == "candidate" and case.get("provenance", {}).get("introduced_by") == work_item_id:
                introduced = True
                for coverage_entry in case.get("coverage", []):
                    if not isinstance(coverage_entry, dict) or not isinstance(coverage_entry.get("behavior"), str):
                        continue
                    counts: Dict[str, int] = {}
                    for role_case in coverage_entry.get("cases", []):
                        if isinstance(role_case, dict) and isinstance(role_case.get("role"), str):
                            role = role_case["role"]
                            counts[role] = counts.get(role, 0) + 1
                    candidate_coverage[coverage_entry["behavior"]] = counts
        if not introduced:
            errors.append(f"{work_item_id}: extend 必须包含 introduced_by 当前工作项的 candidate scenario")
        policy = coverage_policy(root)
        for behavior in behaviors:
            counts = candidate_coverage.get(behavior, {})
            rule = policy.get(behavior, {})
            for role in rule.get("required_roles", []):
                if counts.get(role, 0) < rule.get("min_cases_per_role", 1):
                    errors.append(f"{work_item_id}: candidate 未提供 {behavior}/{role} 覆盖")
    return errors


def validate_candidate_characterization(
    root: Path,
    work_item_id: str,
    item: Dict[str, Any],
    scenario_id: str,
    behaviors: Sequence[str],
) -> List[str]:
    """Allow an Oracle to consume, but never promote, one candidate scenario."""

    errors: List[str] = []
    metadata = item.get("metadata", {})
    spec = item.get("spec", {})
    labels = set(metadata.get("labels", []))
    requirements = spec.get("requirements", {})
    allow_write = spec.get("scope", {}).get("allow_write", [])
    recovers = spec.get("recovers")
    is_direct_characterization = (
        requirements.get("mode") == "characterization"
    )
    is_control_recovery = (
        requirements.get("mode") == "control_plane"
        and isinstance(recovers, str)
        and bool(recovers)
    )
    is_attestation_followup = (
        is_direct_characterization
        and CANDIDATE_ATTESTATION_LABELS.issubset(labels)
    )
    is_attestation_recovery = (
        is_control_recovery
        and CANDIDATE_ATTESTATION_LABELS.issubset(labels)
    )
    if (
        not CANDIDATE_CHARACTERIZATION_LABELS.issubset(labels)
        or not (is_direct_characterization or is_control_recovery)
        or spec.get("gates") != []
    ):
        errors.append(
            f"{work_item_id}: candidate reuse 仅限无 Gate 的 "
            "android-oracle/candidate-only characterization 或其 control recovery"
        )

    if not isinstance(allow_write, list) or any(
        not isinstance(value, str) for value in allow_write
    ):
        errors.append(
            f"{work_item_id}: candidate characterization allow_write 无效"
        )
    else:
        forbidden = sorted(
            value
            for value in allow_write
            if any(
                value == prefix.rstrip("/") or value.startswith(prefix)
                for prefix in CANDIDATE_CHARACTERIZATION_FORBIDDEN_WRITES
            )
            and not (
                (is_attestation_followup or is_attestation_recovery)
                and value in CANDIDATE_ATTESTATION_ALLOWED_WRITES
            )
        )
        if forbidden:
            errors.append(
                f"{work_item_id}: candidate characterization 禁止写入："
                + ", ".join(forbidden)
            )

    try:
        _, case, _ = load_scenario(root, scenario_id)
    except SourceLabError as error:
        return [*errors, f"{work_item_id}: candidate scenario 无效：{error}"]
    provenance = case.get("provenance", {})
    introduced_by = provenance.get("introduced_by")
    if not isinstance(introduced_by, str) or not introduced_by:
        errors.append(
            f"{work_item_id}: candidate scenario 缺少 introduced_by"
        )
        return errors

    dependencies = spec.get("depends_on", [])
    if not is_attestation_followup and dependencies != [introduced_by]:
        errors.append(
            f"{work_item_id}: candidate characterization 必须唯一依赖 "
            f"introduced_by WorkItem：{introduced_by}"
        )

    try:
        introducer = load_json(
            root / "ios/harness/work-items" / f"{introduced_by}.json"
        )
        state = load_json(root / "ios/project/state.json")
    except SourceLabError as error:
        errors.append(
            f"{work_item_id}: candidate provenance binding 无效：{error}"
        )
        return errors
    introducer_source_lab = introducer.get("spec", {}).get("source_lab", {})
    introducer_runtime = state.get("work_items", {}).get(introduced_by, {})
    if (
        introducer_source_lab.get("mode") != "extend"
        or scenario_id not in introducer_source_lab.get("scenarios", [])
        or introducer_runtime.get("status") != "completed"
    ):
        errors.append(
            f"{work_item_id}: candidate introduced_by 尚未完成合法 extend："
            f"{introduced_by}"
        )

    if is_attestation_followup:
        if (
            not isinstance(dependencies, list)
            or len(dependencies) != 1
            or not isinstance(dependencies[0], str)
        ):
            errors.append(
                f"{work_item_id}: candidate attestation 必须唯一依赖"
                "已完成 Android Oracle"
            )
        else:
            dependency_id = dependencies[0]
            dependency_path = (
                root
                / "ios/harness/work-items"
                / f"{dependency_id}.json"
            )
            dependency_runtime = state.get("work_items", {}).get(
                dependency_id,
                {},
            )
            try:
                dependency = load_json(dependency_path)
            except SourceLabError as error:
                errors.append(
                    f"{work_item_id}: candidate attestation "
                    f"Oracle 依赖无效：{error}"
                )
            else:
                dependency_spec = dependency.get("spec", {})
                dependency_labels = set(
                    dependency.get("metadata", {}).get("labels", [])
                )
                dependency_requirements_mode = dependency_spec.get(
                    "requirements",
                    {},
                ).get("mode")
                dependency_source_lab = dependency_spec.get(
                    "source_lab",
                    {},
                )
                dependency_evidence_path = dependency_runtime.get(
                    "last_evidence"
                )
                dependency_evidence = None
                dependency_evidence_sha256 = None
                if isinstance(dependency_evidence_path, str):
                    evidence_path = root / dependency_evidence_path
                    try:
                        dependency_evidence = load_json(evidence_path)
                        dependency_evidence_sha256 = sha256_bytes(
                            evidence_path.read_bytes()
                        )
                    except (OSError, SourceLabError):
                        dependency_evidence = None
                if (
                    dependency_spec.get("capability")
                    != spec.get("capability")
                    or not CANDIDATE_CHARACTERIZATION_LABELS.issubset(
                        dependency_labels
                    )
                    or dependency_requirements_mode
                    not in {"characterization", "control_plane"}
                    or dependency_source_lab.get("mode") != "reuse"
                    or dependency_source_lab.get("scenarios")
                    != [scenario_id]
                    or dependency_source_lab.get("behaviors")
                    != list(behaviors)
                    or dependency_runtime.get("status") != "completed"
                    or dependency_runtime.get("work_item_sha256")
                    != sha256_bytes(canonical_bytes(dependency))
                    or not isinstance(dependency_evidence, dict)
                    or dependency_evidence.get("work_item_id")
                    != dependency_id
                    or dependency_evidence.get("result") != "passed"
                    or dependency_runtime.get("last_evidence_sha256")
                    != dependency_evidence_sha256
                ):
                    errors.append(
                        f"{work_item_id}: candidate attestation "
                        "必须沿已完成且证据通过的同 Capability "
                        "Android Oracle 谱系复用场景"
                    )

    if is_control_recovery:
        cursor = recovers
        seen: Set[str] = {work_item_id}
        terminal_statuses = {
            "blocked",
            "rejected",
            "exhausted",
            "cancelled",
        }
        chain_valid = False
        while isinstance(cursor, str) and cursor:
            if cursor in seen or len(seen) > 16:
                errors.append(
                    f"{work_item_id}: control recovery chain 成环或过深"
                )
                break
            seen.add(cursor)
            predecessor_path = (
                root / "ios/harness/work-items" / f"{cursor}.json"
            )
            try:
                predecessor = load_json(predecessor_path)
            except SourceLabError as error:
                errors.append(
                    f"{work_item_id}: candidate recovery predecessor "
                    f"无效：{error}"
                )
                break
            predecessor_spec = predecessor.get("spec", {})
            predecessor_labels = set(
                predecessor.get("metadata", {}).get("labels", [])
            )
            predecessor_runtime = state.get("work_items", {}).get(
                cursor,
                {},
            )
            if (
                predecessor_spec.get("capability") != spec.get("capability")
                or predecessor_spec.get("source_lab", {}).get("mode")
                != "reuse"
                or predecessor_spec.get("source_lab", {}).get("scenarios")
                != [scenario_id]
                or predecessor_spec.get("source_lab", {}).get("behaviors")
                != list(behaviors)
                or not CANDIDATE_CHARACTERIZATION_LABELS.issubset(
                    predecessor_labels
                )
                or predecessor_runtime.get("status")
                not in terminal_statuses
            ):
                errors.append(
                    f"{work_item_id}: control recovery 未精确承接 "
                    f"candidate characterization：{cursor}"
                )
                break
            predecessor_mode = predecessor_spec.get(
                "requirements",
                {},
            ).get("mode")
            if predecessor_mode == "characterization":
                chain_valid = True
                break
            next_predecessor = predecessor_spec.get("recovers")
            if (
                predecessor_mode != "control_plane"
                or not isinstance(next_predecessor, str)
                or not next_predecessor
            ):
                errors.append(
                    f"{work_item_id}: control recovery chain 未终止于 "
                    "candidate characterization"
                )
                break
            cursor = next_predecessor
        if not chain_valid and not any(
            "control recovery" in error for error in errors
        ):
            errors.append(
                f"{work_item_id}: control recovery chain 未解析"
            )

    policy = coverage_policy(root)
    candidate_coverage: Dict[str, Dict[str, int]] = {}
    for coverage_entry in case.get("coverage", []):
        if (
            not isinstance(coverage_entry, dict)
            or not isinstance(coverage_entry.get("behavior"), str)
        ):
            continue
        counts: Dict[str, int] = {}
        for role_case in coverage_entry.get("cases", []):
            if (
                isinstance(role_case, dict)
                and isinstance(role_case.get("role"), str)
            ):
                role = role_case["role"]
                counts[role] = counts.get(role, 0) + 1
        candidate_coverage[coverage_entry["behavior"]] = counts
    for behavior in behaviors:
        rule = policy.get(behavior)
        if rule is None:
            errors.append(f"{work_item_id}: behavior 未登记 policy：{behavior}")
            continue
        counts = candidate_coverage.get(behavior, {})
        for role in rule.get("required_roles", []):
            if counts.get(role, 0) < rule.get("min_cases_per_role", 1):
                errors.append(
                    f"{work_item_id}: candidate scenario 缺少 "
                    f"{behavior}/{role} 覆盖"
                )
    return errors


def doctor(root: Path, work_item_id: Optional[str] = None) -> List[str]:
    errors: List[str] = []
    try:
        policy = coverage_policy(root)
    except SourceLabError as error:
        return [str(error)]
    known_behaviors = set(policy)
    try:
        inventory = load_json(root / "ios/project/android-intake/inventory-manifest.json")
        known_facts = {
            entry.get("id")
            for entry in inventory.get("facts", [])
            if isinstance(entry, dict) and isinstance(entry.get("id"), str)
        }
    except SourceLabError as error:
        errors.append(str(error))
        known_facts = set()
    for directory in scenario_directories(root):
        try:
            case = load_json(directory / "case.json")
            if not isinstance(case, dict):
                errors.append(f"case 必须是 object：{directory}")
                continue
            errors.extend(validate_scenario(root, directory, case))
            for entry in case.get("coverage", []):
                behavior = entry.get("behavior") if isinstance(entry, dict) else None
                if behavior not in known_behaviors:
                    errors.append(f"{case.get('id')}: 未登记 behavior：{behavior}")
                for role_case in entry.get("cases", []) if isinstance(entry, dict) else []:
                    if not isinstance(role_case, dict):
                        continue
                    for fact_id in role_case.get("android_fact_refs", []):
                        if fact_id not in known_facts:
                            errors.append(f"{case.get('id')}: coverage 引用未知 Android fact：{fact_id}")
        except SourceLabError as error:
            errors.append(str(error))
    if not scenario_directories(root):
        errors.append("SourceLab 没有 scenario")
    try:
        expected_manifest = manifest_value(root)
        actual_manifest = load_json(root / CONTROL_ROOT / "manifest.json")
        if actual_manifest != expected_manifest:
            errors.append("SourceLab manifest 已过期")
        coverage = expected_manifest["coverage"]
        for behavior, rule in policy.items():
            if rule.get("status") != "active":
                continue
            actual = coverage.get(behavior, {})
            minimum = rule.get("min_cases_per_role", 1)
            for role in rule.get("required_roles", []):
                if len(actual.get(role, [])) < minimum:
                    errors.append(f"SourceLab behavior 缺少 reference case-role：{behavior}/{role}")
        if work_item_id:
            errors.extend(validate_work_item_contract(root, work_item_id, expected_manifest))
    except SourceLabError as error:
        errors.append(str(error))
    return errors


class SourceLabHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = False
    block_on_close = True
    request_queue_size = 16

    def __init__(self, address: Tuple[str, int], directory: Path, case: Dict[str, Any]):
        self.scenario_directory = directory
        self.case = case
        self.limits = case["limits"]
        self.route_table = {
            route_signature(route): route for route in case["transport"]["responses"]
        }
        self.counter_lock = threading.Lock()
        self.request_count = 0
        self.semaphore = threading.BoundedSemaphore(self.limits["max_concurrency"])
        super().__init__(address, SourceLabRequestHandler, bind_and_activate=True)

    @property
    def authority(self) -> str:
        host, port = self.server_address[:2]
        return f"{host}:{port}"

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(self.limits["timeout_ms"] / 1000.0)
        return connection, address

    def acquire_request_slot(self) -> bool:
        if not self.semaphore.acquire(blocking=False):
            return False
        with self.counter_lock:
            if self.request_count >= self.limits["max_requests"]:
                self.semaphore.release()
                return False
            self.request_count += 1
        return True


class SourceLabRequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LegadoSourceLab/1"
    sys_version = ""

    def log_message(self, format: str, *args: Any) -> None:
        return

    def date_time_string(self, timestamp: Optional[float] = None) -> str:
        return FIXED_DATE

    def do_GET(self) -> None:
        self.handle_source_lab_request()

    def do_POST(self) -> None:
        self.handle_source_lab_request()

    def do_CONNECT(self) -> None:
        self.send_stable_response(405, {"content-type": "application/json; charset=utf-8"}, b'{"error":"method_not_allowed"}\n')

    def send_stable_response(self, status: int, headers: Dict[str, str], body: bytes) -> None:
        try:
            self.send_response_only(status)
            self.send_header("Server", "LegadoSourceLab/1")
            self.send_header("Date", FIXED_DATE)
            for key, value in sorted(headers.items()):
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass
        self.close_connection = True

    def handle_source_lab_request(self) -> None:
        server = self.server
        assert isinstance(server, SourceLabHTTPServer)
        if self.headers.get("Host") != server.authority:
            self.send_stable_response(421, {"content-type": "application/json; charset=utf-8"}, b'{"error":"authority_mismatch"}\n')
            return
        if self.path.startswith(("http://", "https://", "//")):
            self.send_stable_response(400, {"content-type": "application/json; charset=utf-8"}, b'{"error":"absolute_target_denied"}\n')
            return
        if not server.acquire_request_slot():
            self.send_stable_response(503, {"content-type": "application/json; charset=utf-8"}, b'{"error":"request_budget_exceeded"}\n')
            return
        try:
            raw_length = self.headers.get("Content-Length", "0")
            try:
                length = int(raw_length)
            except ValueError:
                self.send_stable_response(400, {"content-type": "application/json; charset=utf-8"}, b'{"error":"invalid_content_length"}\n')
                return
            if length < 0 or length > server.limits["max_request_body_bytes"]:
                self.send_stable_response(413, {"content-type": "application/json; charset=utf-8"}, b'{"error":"request_body_too_large"}\n')
                return
            if length:
                self.rfile.read(length)
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.query:
                try:
                    pairs = urllib.parse.parse_qsl(
                        parsed.query,
                        keep_blank_values=True,
                        strict_parsing=True,
                        max_num_fields=32,
                    )
                except ValueError:
                    self.send_stable_response(400, {"content-type": "application/json; charset=utf-8"}, b'{"error":"invalid_query"}\n')
                    return
            else:
                pairs = []
            query: Dict[str, str] = {}
            for key, value in pairs:
                if key in query:
                    self.send_stable_response(400, {"content-type": "application/json; charset=utf-8"}, b'{"error":"duplicate_query"}\n')
                    return
                query[key] = value
            signature = (self.command, parsed.path, tuple(sorted(query.items())))
            route = server.route_table.get(signature)
            if route is None:
                self.send_stable_response(404, {"content-type": "application/json; charset=utf-8"}, b'{"error":"route_not_declared"}\n')
                return
            respond = route["respond"]
            body = safe_child(server.scenario_directory, respond["body_file"]).read_bytes()
            self.send_stable_response(respond["status"], respond["headers"], body)
        finally:
            server.semaphore.release()


@contextlib.contextmanager
def running_server(root: Path, scenario_id: str) -> Iterator[SourceLabHTTPServer]:
    directory, case, _ = load_scenario(root, scenario_id)
    server = SourceLabHTTPServer(("127.0.0.1", 0), directory, case)
    thread = threading.Thread(target=server.serve_forever, name=f"SourceLab-{scenario_id}")
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2.0)
        if thread.is_alive():
            raise SourceLabError("SourceLab server thread 未退出")
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.2)
            if probe.connect_ex(server.server_address[:2]) == 0:
                raise SourceLabError("SourceLab teardown 后端口仍在监听")
        finally:
            probe.close()


def request_route(server: SourceLabHTTPServer, route: Dict[str, Any]) -> Dict[str, Any]:
    method, path, query_items = route_signature(route)
    target = path
    if query_items:
        target += "?" + urllib.parse.urlencode(query_items)
    url = f"http://{server.authority}{target}"
    request = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(request, timeout=server.limits["timeout_ms"] / 1000.0) as response:
            status = response.status
            headers = {key.lower(): value for key, value in response.headers.items()}
            body = response.read(server.limits["max_response_bytes"] + 1)
    except urllib.error.HTTPError as error:
        status = error.code
        headers = {key.lower(): value for key, value in error.headers.items()}
        body = error.read(server.limits["max_response_bytes"] + 1)
    return {
        "route": route["id"],
        "method": method,
        "logical_target": LOGICAL_ORIGIN + target,
        "status": status,
        "content_type": headers.get("content-type"),
        "body_sha256": sha256_bytes(body),
        "body_bytes": len(body),
    }


def verify_site(root: Path, scenario_id: str) -> Dict[str, Any]:
    directory, case, _ = load_scenario(root, scenario_id)
    errors = validate_scenario(root, directory, case)
    if errors:
        raise SourceLabError("scenario 无效：\n- " + "\n- ".join(errors))
    with running_server(root, scenario_id) as server:
        origin = f"http://{server.authority}"
        source = build_source(root, scenario_id, origin)
        first = [request_route(server, route) for route in case["transport"]["responses"]]
        second = [request_route(server, route) for route in case["transport"]["responses"]]
        if first != second:
            raise SourceLabError("SourceLab 重复请求 transcript 不一致")
        for route, transcript in zip(case["transport"]["responses"], first):
            respond = route["respond"]
            body = safe_child(directory, respond["body_file"]).read_bytes()
            if transcript["status"] != respond["status"] or transcript["body_sha256"] != sha256_bytes(body):
                raise SourceLabError(f"SourceLab route 输出与 fixture 不一致：{route['id']}")
        connection = http.client.HTTPConnection(server.server_address[0], server.server_address[1], timeout=1)
        connection.request("GET", "/", headers={"Host": "localhost"})
        wrong_host = connection.getresponse()
        wrong_host.read()
        connection.close()
        if wrong_host.status != 421:
            raise SourceLabError("SourceLab 未拒绝错误 authority")
    return {
        "schema_version": 1,
        "scenario": scenario_id,
        "logical_origin": LOGICAL_ORIGIN,
        "source_sha256": sha256_bytes(canonical_bytes(build_source(root, scenario_id, LOGICAL_ORIGIN))),
        "transcript_sha256": sha256_bytes(canonical_bytes(first)),
        "route_count": len(first),
    }


def root_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=Path("."))


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    doctor_parser = subparsers.add_parser("doctor")
    root_argument(doctor_parser)
    doctor_parser.add_argument("--work-item")
    manifest_parser = subparsers.add_parser("manifest")
    root_argument(manifest_parser)
    build_parser = subparsers.add_parser("build-source")
    root_argument(build_parser)
    build_parser.add_argument("--scenario", required=True)
    build_parser.add_argument("--origin", default=LOGICAL_ORIGIN)
    build_parser.add_argument("--output", type=Path)
    verify_parser = subparsers.add_parser("verify-site")
    root_argument(verify_parser)
    verify_parser.add_argument("--scenario", required=True)
    serve_parser = subparsers.add_parser("serve")
    root_argument(serve_parser)
    serve_parser.add_argument("--scenario", required=True)

    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == "doctor":
            errors = doctor(root, args.work_item)
            if errors:
                for error in errors:
                    print(f"SOURCE_LAB: {error}", file=sys.stderr)
                return 1
            print("SOURCE_LAB: OK")
            return 0
        if args.command == "manifest":
            print(json.dumps(manifest_value(root), ensure_ascii=False, indent=2))
            return 0
        if args.command == "build-source":
            value = json.dumps(build_source(root, args.scenario, args.origin), ensure_ascii=False, indent=2) + "\n"
            if args.output:
                args.output.write_text(value, encoding="utf-8")
            else:
                sys.stdout.write(value)
            return 0
        if args.command == "verify-site":
            print(json.dumps(verify_site(root, args.scenario), ensure_ascii=False, sort_keys=True))
            return 0
        if args.command == "serve":
            directory, case, _ = load_scenario(root, args.scenario)
            errors = validate_scenario(root, directory, case)
            if errors:
                raise SourceLabError("scenario 无效：\n- " + "\n- ".join(errors))
            server = SourceLabHTTPServer(("127.0.0.1", 0), directory, case)
            print(json.dumps({"scenario": args.scenario, "origin": f"http://{server.authority}"}), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
            return 0
    except (SourceLabError, OSError) as error:
        print(f"SOURCE_LAB: {error}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
