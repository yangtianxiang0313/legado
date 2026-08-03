#!/usr/bin/env python3
"""Deterministic source-site and Android runtime characterization fixtures."""

from __future__ import annotations

import argparse
import base64
import binascii
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
SOURCE_FIXTURE_ROOT = Path("ios/harness/fixtures/source-lab")
RUNTIME_FIXTURE_ROOT = Path("ios/harness/fixtures/runtime-lab")
INTEGRATION_FIXTURE_ROOT = Path("ios/harness/fixtures/integration-lab")
REAL_SOURCE_FIXTURE_ROOT = Path("ios/harness/fixtures/real-source")
FIXTURE_ROOTS = (
    SOURCE_FIXTURE_ROOT,
    RUNTIME_FIXTURE_ROOT,
    INTEGRATION_FIXTURE_ROOT,
    REAL_SOURCE_FIXTURE_ROOT,
)
CONTROL_ROOT = Path("ios/harness/source-lab")
SCENARIO_ID = re.compile(r"^(?:sl|rl|il|rs)-[a-z0-9-]+-[0-9]{3}$")
FIXED_DATE = "Thu, 01 Jan 1970 00:00:00 GMT"
ALLOWED_RESPONSE_HEADERS = {"content-type", "cache-control", "content-encoding", "location", "set-cookie"}
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


def fixture_body_bytes(path: Path) -> bytes:
    payload = path.read_bytes()
    if not path.name.endswith(".base64"):
        return payload
    try:
        return base64.b64decode(payload.strip(), validate=True)
    except (ValueError, binascii.Error) as error:
        raise SourceLabError(f"SourceLab base64 body 无效：{path}") from error


def scenario_directories(root: Path) -> List[Path]:
    directories = []
    for relative in FIXTURE_ROOTS:
        fixture_root = root / relative
        if fixture_root.exists():
            directories.extend(path.parent for path in fixture_root.glob("*/case.json"))
    return sorted(directories)


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
    if case.get("kind") != "source_lab_scenario":
        raise SourceLabError(f"{scenario_id}: Android runtime scenario 没有书源模板")
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


def validate_runtime_scenario(
    root: Path,
    directory: Path,
    case: Dict[str, Any],
) -> List[str]:
    errors: List[str] = []
    scenario_id = case.get("id")
    required_top = {
        "schema_version", "kind", "id", "revision", "status", "operation", "capabilities",
        "compatibility_profile", "source", "input", "transport", "coverage", "determinism", "limits", "provenance",
    }
    extras = sorted(set(case) - required_top)
    missing = sorted(required_top - set(case))
    if extras:
        errors.append(f"{scenario_id}: 不允许的 runtime case 字段：{', '.join(extras)}")
    if missing:
        errors.append(f"{scenario_id}: 缺少 runtime case 字段：{', '.join(missing)}")
    if (
        scenario_id != directory.name
        or not isinstance(scenario_id, str)
        or not scenario_id.startswith("rl-")
        or not SCENARIO_ID.fullmatch(scenario_id)
    ):
        errors.append(f"runtime scenario ID/目录无效：{directory}")
    if case.get("operation") != "android_runtime" or case.get("source") is not None:
        errors.append(f"{scenario_id}: runtime operation/source 无效")
    transport = case.get("transport")
    transport_disabled = transport == {
        "mode": "none",
        "external_network": "deny",
        "responses": [],
    }
    transport_loopback = (
        isinstance(transport, dict)
        and set(transport) == {"mode", "external_network", "responses"}
        and transport.get("mode") == "fixture_and_loopback"
        and transport.get("external_network") == "deny"
        and isinstance(transport.get("responses"), list)
        and bool(transport["responses"])
    )
    if not transport_disabled and not transport_loopback:
        errors.append(f"{scenario_id}: runtime transport 必须禁用或固定为本地 fixture")
    if transport_loopback:
        route_ids: Set[str] = set()
        for route in transport["responses"]:
            valid = (
                isinstance(route, dict)
                and set(route) == {"id", "match", "respond"}
                and isinstance(route.get("id"), str)
                and isinstance(route.get("match"), dict)
                and isinstance(route.get("respond"), dict)
                and route["match"].get("method") in {"GET", "POST"}
                and isinstance(route["match"].get("path"), str)
                and route["match"]["path"].startswith("/")
                and isinstance(route["respond"].get("status"), int)
                and isinstance(route["respond"].get("headers"), dict)
                and isinstance(route["respond"].get("body_file"), str)
            )
            if not valid or route.get("id") in route_ids:
                errors.append(f"{scenario_id}: runtime loopback route 无效或重复")
                continue
            route_ids.add(route["id"])
            try:
                body_path = safe_child(
                    directory,
                    route["respond"]["body_file"],
                )
                if not body_path.is_file():
                    errors.append(f"{scenario_id}: runtime loopback body 不存在")
            except SourceLabError as error:
                errors.append(str(error))
    determinism = case.get("determinism")
    expected_origin = (
        "http://sourcelab.test" if transport_loopback else None
    )
    if (
        not isinstance(determinism, dict)
        or determinism.get("network_allowed") is not False
        or determinism.get("logical_origin") != expected_origin
        or determinism.get("database_reset_per_case") is not True
        or determinism.get("timezone") != "UTC"
        or determinism.get("locale") != "en_US_POSIX"
    ):
        errors.append(f"{scenario_id}: runtime determinism 无效")
    limits = case.get("limits")
    if (
        not isinstance(limits, dict)
        or not isinstance(limits.get("timeout_ms"), int)
        or not 1 <= limits["timeout_ms"] <= 5_000
    ):
        errors.append(f"{scenario_id}: runtime limits.timeout_ms 无效")
    try:
        input_path = safe_child(directory, str(case.get("input", "")))
        inputs = load_json(input_path)
        input_cases: Dict[str, Dict[str, Any]] = {}
        if not isinstance(inputs, dict) or set(inputs) != {"schema_version", "cases"}:
            errors.append(f"{scenario_id}: runtime input 必须只含 schema_version/cases")
        elif inputs.get("schema_version") != 1 or not isinstance(inputs.get("cases"), list):
            errors.append(f"{scenario_id}: runtime input schema/cases 无效")
        else:
            for entry in inputs["cases"]:
                if (
                    not isinstance(entry, dict)
                    or set(entry) != {"id", "operation", "arguments"}
                    or not isinstance(entry.get("id"), str)
                    or not isinstance(entry.get("operation"), str)
                    or not isinstance(entry.get("arguments"), dict)
                ):
                    errors.append(f"{scenario_id}: runtime input case 无效")
                    continue
                if forbidden_business_keys(entry):
                    errors.append(f"{scenario_id}: runtime input 含业务答案字段：{entry['id']}")
                if entry["id"] in input_cases:
                    errors.append(f"{scenario_id}: runtime input case ID 重复：{entry['id']}")
                input_cases[entry["id"]] = entry
    except SourceLabError as error:
        errors.append(str(error))
        input_cases = {}
    errors.extend(validate_coverage(case, input_cases))
    return errors


def validate_coverage(
    case: Dict[str, Any],
    input_cases: Dict[str, Dict[str, Any]],
) -> List[str]:
    errors: List[str] = []
    scenario_id = case.get("id")
    coverage = case.get("coverage")
    if not isinstance(coverage, list):
        return [f"{scenario_id}: coverage 必须是数组"]
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


def validate_scenario(root: Path, directory: Path, case: Dict[str, Any]) -> List[str]:
    if case.get("kind") == "real_source_scenario":
        return validate_real_source_scenario(directory, case)
    if case.get("kind") == "android_runtime_scenario":
        return validate_runtime_scenario(root, directory, case)
    if case.get("kind") == "integration_lab_scenario":
        integration_directory = (
            root / "ios/harness/integration-lab"
        )
        if str(integration_directory) not in sys.path:
            sys.path.insert(0, str(integration_directory))
        import integration_lab  # type: ignore

        return integration_lab.validate_scenario(root, directory, case)
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
            if len(fixture_body_bytes(body_path)) > limits.get("max_response_bytes", 0):
                errors.append(f"{scenario_id}: route body 超限：{route_id}")
        except SourceLabError as error:
            errors.append(str(error))

    errors.extend(validate_coverage(case, input_cases))
    return errors


def validate_real_source_scenario(
    directory: Path,
    case: Dict[str, Any],
) -> List[str]:
    errors: List[str] = []
    scenario_id = case.get("id")
    required = {
        "schema_version", "kind", "id", "revision", "status",
        "operation", "compatibility_profile", "source", "input",
        "transport", "retention", "limits", "provenance",
    }
    if set(case) != required:
        errors.append(f"{scenario_id}: real-source case 字段无效")
    if (
        scenario_id != directory.name
        or not isinstance(scenario_id, str)
        or not scenario_id.startswith("rs-")
        or not SCENARIO_ID.fullmatch(scenario_id)
        or case.get("schema_version") != 1
        or case.get("kind") != "real_source_scenario"
        or case.get("operation") != "real_source_capture"
        or case.get("status") != "candidate"
        or case.get("compatibility_profile") != "android-legado-v1"
    ):
        errors.append(f"{scenario_id}: real-source identity 无效")
    try:
        source = load_json(safe_child(directory, str(case.get("source", ""))))
        inputs = load_json(safe_child(directory, str(case.get("input", ""))))
    except SourceLabError as error:
        errors.append(str(error))
        return errors
    if not isinstance(source, dict) or not isinstance(inputs, dict):
        errors.append(f"{scenario_id}: source/input 必须是 object")
        return errors
    origin = source.get("bookSourceUrl")
    transport = case.get("transport")
    allowed_hosts = (
        transport.get("allowed_hosts")
        if isinstance(transport, dict)
        else None
    )
    if (
        not isinstance(origin, str)
        or urllib.parse.urlsplit(origin).scheme != "https"
        or not isinstance(allowed_hosts, list)
        or allowed_hosts != [urllib.parse.urlsplit(origin).hostname]
        or transport.get("mode") != "external_capture_once"
        or transport.get("external_network") != "capture_only"
    ):
        errors.append(f"{scenario_id}: real-source transport/origin 无效")
    external_hosts = {
        urllib.parse.urlsplit(value).hostname
        for value in recursive_strings(source)
        if value.startswith(("http://", "https://"))
    }
    if external_hosts != set(allowed_hosts or []):
        errors.append(f"{scenario_id}: source URL 超出 allowlist")
    retention = case.get("retention")
    if (
        not isinstance(retention, dict)
        or retention.get("content_policy") != "public_domain"
        or retention.get("store_response_bodies") is not False
        or retention.get("store_credentials") is not False
        or not isinstance(
            retention.get("max_text_sample_characters"), int
        )
        or not 1 <= retention["max_text_sample_characters"] <= 512
    ):
        errors.append(f"{scenario_id}: real-source retention 无效")
    if any(
        key in source
        for key in ("loginUrl", "loginUi", "loginCheckJs", "jsLib")
    ):
        errors.append(f"{scenario_id}: 首个 real-source 禁止登录与远端脚本")
    provenance = case.get("provenance")
    if (
        not isinstance(provenance, dict)
        or provenance.get("kind") != "real_source_capture"
        or provenance.get("origin") != origin
        or provenance.get("rights") != "public_domain"
        or not isinstance(provenance.get("rights_evidence"), str)
    ):
        errors.append(f"{scenario_id}: real-source provenance 无效")
    if set(inputs) != {"keyword", "book_title", "chapter_title"} or any(
        not isinstance(value, str) or not value.strip()
        for value in inputs.values()
    ):
        errors.append(f"{scenario_id}: real-source input 无效")
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


def doctor(root: Path) -> List[str]:
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
            if case.get("kind") in {
                "android_runtime_scenario",
                "integration_lab_scenario",
                "real_source_scenario",
            }:
                continue
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
        self.route_request_counts = {
            route["id"]: 0 for route in case["transport"]["responses"]
        }
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

    def record_route_request(self, route_id: str) -> None:
        with self.counter_lock:
            self.route_request_counts[route_id] += 1


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
            server.record_route_request(route["id"])
            respond = route["respond"]
            body = fixture_body_bytes(
                safe_child(server.scenario_directory, respond["body_file"])
            )
            self.send_stable_response(respond["status"], respond["headers"], body)
        finally:
            server.semaphore.release()


@contextlib.contextmanager
def running_server(root: Path, scenario_id: str) -> Iterator[SourceLabHTTPServer]:
    directory, case, _ = load_scenario(root, scenario_id)
    if case.get("kind") != "source_lab_scenario":
        raise SourceLabError(f"{scenario_id}: Android runtime scenario 禁止启动网站")
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


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Any,
        new_url: str,
    ) -> None:
        return None


def request_route(server: SourceLabHTTPServer, route: Dict[str, Any]) -> Dict[str, Any]:
    method, path, query_items = route_signature(route)
    target = path
    if query_items:
        target += "?" + urllib.parse.urlencode(query_items)
    url = f"http://{server.authority}{target}"
    request = urllib.request.Request(url, method=method)
    try:
        opener = urllib.request.build_opener(_NoRedirect)
        with opener.open(request, timeout=server.limits["timeout_ms"] / 1000.0) as response:
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
            body = fixture_body_bytes(
                safe_child(directory, respond["body_file"])
            )
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
    manifest_parser = subparsers.add_parser("manifest")
    root_argument(manifest_parser)
    manifest_parser.add_argument(
        "--write",
        action="store_true",
        help="原子更新 SourceLab manifest，而不是只输出到 stdout",
    )
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
            errors = doctor(root)
            if errors:
                for error in errors:
                    print(f"SOURCE_LAB: {error}", file=sys.stderr)
                return 1
            print("SOURCE_LAB: OK")
            return 0
        if args.command == "manifest":
            value = (
                json.dumps(
                    manifest_value(root),
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n"
            )
            if args.write:
                path = root / CONTROL_ROOT / "manifest.json"
                temporary = path.with_suffix(".json.tmp")
                temporary.write_text(value, encoding="utf-8")
                os.replace(temporary, path)
            else:
                sys.stdout.write(value)
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
