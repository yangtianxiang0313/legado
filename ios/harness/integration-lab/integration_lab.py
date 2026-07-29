#!/usr/bin/env python3
"""Deterministic loopback protocol simulator for integration characterization."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import http.client
import http.server
import json
import re
import socket
import sys
import threading
import urllib.parse
from pathlib import Path
from typing import Any, Dict, Iterable, Iterator, List, Mapping, Optional, Sequence, Set, Tuple


LOGICAL_ORIGIN = "http://integrationlab.test"
FIXTURE_ROOT = Path("ios/harness/fixtures/integration-lab")
CONTROL_ROOT = Path("ios/harness/integration-lab")
SCHEMA_PATH = Path("ios/harness/schemas/integration-lab-scenario.schema.json")
SCENARIO_ID = re.compile(r"^il-[a-z0-9-]+-[0-9]{3}$")
FACT_ID = re.compile(r"^AF-[A-Z0-9-]+$")
FIXED_DATE = "Thu, 01 Jan 1970 00:00:00 GMT"
METHODS = {"GET", "PUT", "DELETE", "PROPFIND", "MKCOL"}
SCENARIO_OPERATIONS = {
    "webdav_protocol": {
        "webdav_check",
        "webdav_exists",
        "webdav_make_directory",
        "webdav_list",
        "webdav_get_file",
        "webdav_download",
        "webdav_upload",
        "webdav_delete",
    },
    "remote_management_protocol": {
        "remote_listener_contract",
        "remote_http_request",
        "remote_websocket_handshake",
    },
    "system_text_to_speech": {
        "tts_helper_queue",
        "tts_helper_initialization",
        "tts_helper_lifecycle",
        "tts_service_speech_rate",
        "tts_service_progress",
        "tts_platform_engine_probe",
    },
}
TRANSPORT_FIXTURE_SERVER = "fixture_and_loopback"
TRANSPORT_ANDROID_LISTENER = "android_loopback_listener"
TRANSPORT_ANDROID_PLATFORM = "android_platform_service"
ALLOWED_RESPONSE_HEADERS = {
    "content-type",
    "etag",
    "last-modified",
    "www-authenticate",
}
SENSITIVE_KEYS = re.compile(
    r"(?i)(?:password|passwd|credential|authorization|cookie|secret|token|key)"
)


class IntegrationLabError(RuntimeError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        + b"\n"
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise IntegrationLabError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise IntegrationLabError(
            f"JSON 无效：{path}:{error.lineno}:{error.colno}: {error.msg}"
        ) from error


def recursive_items(value: Any) -> Iterable[Tuple[str, Any]]:
    if isinstance(value, dict):
        for key, entry in value.items():
            yield str(key), entry
            yield from recursive_items(entry)
    elif isinstance(value, list):
        for entry in value:
            yield from recursive_items(entry)


def safe_child(directory: Path, relative: str) -> Path:
    candidate_relative = Path(relative)
    if (
        candidate_relative.is_absolute()
        or ".." in candidate_relative.parts
        or not candidate_relative.parts
    ):
        raise IntegrationLabError(f"场景路径越界：{relative}")
    candidate = directory / candidate_relative
    current = directory
    for part in candidate_relative.parts:
        current = current / part
        if current.is_symlink():
            raise IntegrationLabError(f"场景禁止 symlink：{current}")
    try:
        candidate.resolve().relative_to(directory.resolve())
    except ValueError as error:
        raise IntegrationLabError(f"场景路径越界：{relative}") from error
    if not candidate.is_file():
        raise IntegrationLabError(f"场景文件不存在：{candidate}")
    return candidate


def scenario_directories(root: Path) -> List[Path]:
    directory = root / FIXTURE_ROOT
    if not directory.exists():
        return []
    return sorted(path.parent for path in directory.glob("*/case.json"))


def scenario_directory(root: Path, scenario_id: str) -> Path:
    matches = [
        directory
        for directory in scenario_directories(root)
        if directory.name == scenario_id
    ]
    if len(matches) != 1:
        raise IntegrationLabError(
            f"IntegrationLab scenario 不存在或不唯一：{scenario_id}"
        )
    return matches[0]


def load_scenario(
    root: Path,
    scenario_id: str,
) -> Tuple[Path, Dict[str, Any], Dict[str, Any]]:
    directory = scenario_directory(root, scenario_id)
    case = load_json(directory / "case.json")
    if not isinstance(case, dict):
        raise IntegrationLabError(f"scenario case 必须是 object：{scenario_id}")
    input_path = safe_child(directory, str(case.get("input", "")))
    inputs = load_json(input_path)
    if not isinstance(inputs, dict):
        raise IntegrationLabError(f"scenario input 必须是 object：{scenario_id}")
    return directory, case, inputs


def route_signature(
    route: Mapping[str, Any],
) -> Tuple[str, str]:
    match = route["match"]
    return str(match["method"]), str(match["path"])


def validate_coverage(
    case: Mapping[str, Any],
    input_cases: Mapping[str, Mapping[str, Any]],
    known_facts: Set[str],
    policy: Mapping[str, Mapping[str, Any]],
) -> List[str]:
    errors: List[str] = []
    scenario_id = case.get("id")
    coverage = case.get("coverage")
    if not isinstance(coverage, list) or not coverage:
        return [f"{scenario_id}: coverage 必须是非空数组"]
    seen_behaviors: Set[str] = set()
    observed: Dict[str, Dict[str, int]] = {}
    for entry in coverage:
        if not isinstance(entry, dict) or set(entry) != {"behavior", "cases"}:
            errors.append(f"{scenario_id}: coverage entry 无效")
            continue
        behavior = entry.get("behavior")
        if (
            not isinstance(behavior, str)
            or behavior in seen_behaviors
            or behavior not in policy
        ):
            errors.append(f"{scenario_id}: behavior 未登记或重复：{behavior}")
            continue
        seen_behaviors.add(behavior)
        role_cases = entry.get("cases")
        if not isinstance(role_cases, list) or not role_cases:
            errors.append(f"{scenario_id}: {behavior}.cases 不能为空")
            continue
        seen_case_roles: Set[Tuple[str, str]] = set()
        for role_case in role_cases:
            if not isinstance(role_case, dict) or set(role_case) != {
                "id",
                "role",
                "android_fact_refs",
                "branch_refs",
            }:
                errors.append(f"{scenario_id}: {behavior} case-role 结构无效")
                continue
            case_id = role_case.get("id")
            role = role_case.get("role")
            if case_id not in input_cases:
                errors.append(
                    f"{scenario_id}: {behavior} 引用未知 input case：{case_id}"
                )
            if role not in {"nominal", "boundary", "malformed", "denied"}:
                errors.append(
                    f"{scenario_id}: {behavior}/{case_id} role 无效：{role}"
                )
            key = (str(case_id), str(role))
            if key in seen_case_roles:
                errors.append(
                    f"{scenario_id}: {behavior} case-role 重复：{case_id}/{role}"
                )
            seen_case_roles.add(key)
            observed.setdefault(str(behavior), {}).setdefault(str(role), 0)
            observed[str(behavior)][str(role)] += 1
            facts = role_case.get("android_fact_refs")
            if (
                not isinstance(facts, list)
                or not facts
                or any(
                    not isinstance(value, str)
                    or FACT_ID.fullmatch(value) is None
                    or value not in known_facts
                    for value in facts
                )
            ):
                errors.append(
                    f"{scenario_id}: {behavior}/{case_id} Android fact 无效"
                )
            branches = role_case.get("branch_refs")
            if (
                not isinstance(branches, list)
                or not branches
                or any(
                    not isinstance(value, str) or not value.strip()
                    for value in branches
                )
            ):
                errors.append(
                    f"{scenario_id}: {behavior}/{case_id} branch_refs 无效"
                )
    for behavior, rule in policy.items():
        if rule.get("status") != "active":
            continue
        actual = observed.get(behavior, {})
        minimum = int(rule.get("min_cases_per_role", 1))
        for role in rule.get("required_roles", []):
            if actual.get(role, 0) < minimum:
                errors.append(
                    f"IntegrationLab behavior 缺少 case-role：{behavior}/{role}"
                )
    return errors


def validate_scenario(
    root: Path,
    directory: Path,
    case: Mapping[str, Any],
) -> List[str]:
    errors: List[str] = []
    scenario_id = case.get("id")
    required_top = {
        "schema_version",
        "kind",
        "id",
        "revision",
        "status",
        "operation",
        "capabilities",
        "compatibility_profile",
        "input",
        "transport",
        "coverage",
        "determinism",
        "limits",
        "provenance",
    }
    if set(case) != required_top:
        errors.append(
            f"{scenario_id}: case 字段无效，missing="
            f"{sorted(required_top - set(case))}, extra="
            f"{sorted(set(case) - required_top)}"
        )
    if (
        case.get("schema_version") != 1
        or case.get("kind") != "integration_lab_scenario"
        or case.get("operation") not in SCENARIO_OPERATIONS
        or case.get("status") not in {"candidate", "reference", "retired"}
        or scenario_id != directory.name
        or not isinstance(scenario_id, str)
        or SCENARIO_ID.fullmatch(scenario_id) is None
    ):
        errors.append(f"{scenario_id}: identity/kind/operation 无效")
    for key, _ in recursive_items(case):
        if SENSITIVE_KEYS.search(key):
            errors.append(f"{scenario_id}: fixture 禁止敏感字段：{key}")

    try:
        inputs = load_json(safe_child(directory, str(case.get("input", ""))))
    except IntegrationLabError as error:
        errors.append(str(error))
        inputs = {}
    input_cases: Dict[str, Mapping[str, Any]] = {}
    if (
        not isinstance(inputs, dict)
        or set(inputs) != {"schema_version", "cases"}
        or inputs.get("schema_version") != 1
        or not isinstance(inputs.get("cases"), list)
    ):
        errors.append(f"{scenario_id}: input 必须只含 schema_version/cases")
    else:
        allowed_operations = SCENARIO_OPERATIONS.get(
            str(case.get("operation")),
            set(),
        )
        for value in inputs["cases"]:
            if (
                not isinstance(value, dict)
                or set(value) != {"id", "operation", "arguments"}
                or not isinstance(value.get("id"), str)
                or value.get("operation") not in allowed_operations
                or not isinstance(value.get("arguments"), dict)
            ):
                errors.append(f"{scenario_id}: input case 无效")
                continue
            if value["id"] in input_cases:
                errors.append(f"{scenario_id}: input case ID 重复：{value['id']}")
            for key, _ in recursive_items(value):
                if SENSITIVE_KEYS.search(key):
                    errors.append(
                        f"{scenario_id}: input 禁止敏感字段：{value['id']}/{key}"
                    )
            input_cases[value["id"]] = value

    transport = case.get("transport")
    routes: Sequence[Any] = []
    if not isinstance(transport, dict):
        errors.append(f"{scenario_id}: transport 必须是 object")
    elif transport.get("mode") == TRANSPORT_FIXTURE_SERVER:
        if (
            set(transport) != {"mode", "external_network", "responses"}
            or transport.get("external_network") != "deny"
            or not isinstance(transport.get("responses"), list)
            or not transport["responses"]
        ):
            errors.append(
                f"{scenario_id}: fixture transport 必须是非空 loopback fixture"
            )
        else:
            routes = transport["responses"]
    elif transport.get("mode") == TRANSPORT_ANDROID_LISTENER:
        if (
            set(transport) != {"mode", "external_network", "client"}
            or transport.get("external_network") != "deny"
            or transport.get("client")
            != "android_instrumentation_loopback"
        ):
            errors.append(
                f"{scenario_id}: Android listener transport 无效"
            )
    elif transport.get("mode") == TRANSPORT_ANDROID_PLATFORM:
        if (
            set(transport)
            != {"mode", "external_network", "client", "service"}
            or transport.get("external_network") != "deny"
            or transport.get("client") != "android_instrumentation"
            or transport.get("service") != "text_to_speech"
        ):
            errors.append(
                f"{scenario_id}: Android platform transport 无效"
            )
    else:
        errors.append(f"{scenario_id}: transport mode 无效")
    signatures: Set[Tuple[str, str]] = set()
    route_ids: Set[str] = set()
    limits = case.get("limits")
    if not isinstance(limits, dict):
        limits = {}
        errors.append(f"{scenario_id}: limits 必须是 object")
    maximum_response = limits.get("max_response_bytes")
    for route in routes:
        if not isinstance(route, dict) or set(route) != {
            "id",
            "match",
            "respond",
        }:
            errors.append(f"{scenario_id}: route 结构无效")
            continue
        route_id = route.get("id")
        match = route.get("match")
        respond = route.get("respond")
        if not isinstance(route_id, str) or route_id in route_ids:
            errors.append(f"{scenario_id}: route ID 无效或重复：{route_id}")
            continue
        route_ids.add(route_id)
        if (
            not isinstance(match, dict)
            or set(match) != {"method", "path"}
            or match.get("method") not in METHODS
            or not isinstance(match.get("path"), str)
            or not match["path"].startswith("/")
            or match["path"].startswith("//")
        ):
            errors.append(f"{scenario_id}: route match 无效：{route_id}")
            continue
        signature = route_signature(route)
        if signature in signatures:
            errors.append(f"{scenario_id}: route signature 重复：{route_id}")
        signatures.add(signature)
        if (
            not isinstance(respond, dict)
            or set(respond) != {"status", "headers", "body_file"}
            or not isinstance(respond.get("status"), int)
            or not 100 <= respond["status"] <= 599
            or not isinstance(respond.get("headers"), dict)
        ):
            errors.append(f"{scenario_id}: route respond 无效：{route_id}")
            continue
        for key, value in respond["headers"].items():
            if (
                str(key).lower() not in ALLOWED_RESPONSE_HEADERS
                or not isinstance(value, str)
                or "\r" in value
                or "\n" in value
            ):
                errors.append(
                    f"{scenario_id}: route header 未批准：{route_id}/{key}"
                )
        try:
            body = safe_child(directory, str(respond.get("body_file", "")))
            if (
                not isinstance(maximum_response, int)
                or body.stat().st_size > maximum_response
            ):
                errors.append(f"{scenario_id}: route body 超限：{route_id}")
        except IntegrationLabError as error:
            errors.append(str(error))

    determinism = case.get("determinism")
    if (
        not isinstance(determinism, dict)
        or determinism.get("network_allowed") is not False
        or determinism.get("logical_origin") != LOGICAL_ORIGIN
        or determinism.get("timezone") != "UTC"
        or determinism.get("locale") != "en_US_POSIX"
    ):
        errors.append(f"{scenario_id}: determinism 无效")
    for key, maximum in {
        "timeout_ms": 5_000,
        "max_response_bytes": 10 * 1024 * 1024,
        "max_request_body_bytes": 1024 * 1024,
        "max_requests": 1_000,
        "max_concurrency": 32,
    }.items():
        value = limits.get(key)
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or value < (0 if key == "max_request_body_bytes" else 1)
            or value > maximum
        ):
            errors.append(f"{scenario_id}: limits.{key} 无效")

    try:
        inventory = load_json(
            root / "ios/project/android-intake/inventory-manifest.json"
        )
        known_facts = {
            value.get("id")
            for value in inventory.get("facts", [])
            if isinstance(value, dict) and isinstance(value.get("id"), str)
        }
        policy = {
            behavior: rule
            for behavior, rule in coverage_policy(root).items()
            if case.get("operation") in rule["operations"]
        }
        errors.extend(
            validate_coverage(
                case,
                input_cases,
                known_facts,
                policy,
            )
        )
    except IntegrationLabError as error:
        errors.append(str(error))
    return errors


def coverage_policy(root: Path) -> Dict[str, Dict[str, Any]]:
    value = load_json(root / CONTROL_ROOT / "coverage-policy-v1.json")
    if not isinstance(value, dict) or not isinstance(value.get("behaviors"), list):
        raise IntegrationLabError("IntegrationLab coverage policy 无效")
    result: Dict[str, Dict[str, Any]] = {}
    for entry in value["behaviors"]:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("id"), str)
            or entry["id"] in result
            or not isinstance(entry.get("operations"), list)
            or not entry["operations"]
            or any(
                operation not in SCENARIO_OPERATIONS
                for operation in entry["operations"]
            )
            or not isinstance(entry.get("required_roles"), list)
            or not isinstance(entry.get("min_cases_per_role"), int)
        ):
            raise IntegrationLabError("IntegrationLab coverage behavior 无效")
        result[entry["id"]] = entry
    return result


def fixture_digest(directory: Path) -> str:
    entries = [
        {
            "path": path.relative_to(directory).as_posix(),
            "sha256": sha256_bytes(path.read_bytes()),
            "bytes": path.stat().st_size,
        }
        for path in sorted(
            value
            for value in directory.rglob("*")
            if value.is_file() and not value.is_symlink()
        )
    ]
    return sha256_bytes(canonical_bytes(entries))


def manifest_value(root: Path) -> Dict[str, Any]:
    scenarios = []
    for directory in scenario_directories(root):
        case = load_json(directory / "case.json")
        scenarios.append(
            {
                "id": case.get("id"),
                "status": case.get("status"),
                "path": directory.relative_to(root).as_posix(),
                "sha256": fixture_digest(directory),
            }
        )
    control_paths = [
        root / CONTROL_ROOT / "integration_lab.py",
        root / CONTROL_ROOT / "coverage-policy-v1.json",
        root / SCHEMA_PATH,
    ]
    controls = [
        {
            "path": path.relative_to(root).as_posix(),
            "sha256": sha256_bytes(path.read_bytes()),
            "bytes": path.stat().st_size,
        }
        for path in sorted(control_paths)
    ]
    return {
        "schema_version": 1,
        "logical_origin": LOGICAL_ORIGIN,
        "control_sha256": sha256_bytes(canonical_bytes(controls)),
        "scenarios": sorted(scenarios, key=lambda value: value["id"]),
    }


def doctor(root: Path) -> List[str]:
    errors: List[str] = []
    for directory in scenario_directories(root):
        try:
            case = load_json(directory / "case.json")
            if not isinstance(case, dict):
                errors.append(f"case 必须是 object：{directory}")
                continue
            errors.extend(validate_scenario(root, directory, case))
        except IntegrationLabError as error:
            errors.append(str(error))
    if not scenario_directories(root):
        errors.append("IntegrationLab 没有 scenario")
    try:
        expected = manifest_value(root)
        actual = load_json(root / CONTROL_ROOT / "manifest.json")
        if actual != expected:
            errors.append("IntegrationLab manifest 已过期")
    except IntegrationLabError as error:
        errors.append(str(error))
    return errors


class IntegrationLabHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = False
    daemon_threads = False
    block_on_close = True
    request_queue_size = 16

    def __init__(
        self,
        address: Tuple[str, int],
        directory: Path,
        case: Dict[str, Any],
    ):
        self.scenario_directory = directory
        self.case = case
        self.limits = case["limits"]
        self.route_table = {
            route_signature(route): route
            for route in case["transport"]["responses"]
        }
        self.counter_lock = threading.Lock()
        self.request_count = 0
        self.route_request_counts = {
            route["id"]: 0 for route in case["transport"]["responses"]
        }
        self.request_observations: List[Dict[str, Any]] = []
        self.semaphore = threading.BoundedSemaphore(
            self.limits["max_concurrency"]
        )
        super().__init__(
            address,
            IntegrationLabRequestHandler,
            bind_and_activate=True,
        )

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

    def record_request(
        self,
        route_id: str,
        *,
        method: str,
        path: str,
        headers: http.client.HTTPMessage,
        body: bytes,
    ) -> None:
        authorization = headers.get("Authorization", "")
        authorization_scheme = (
            authorization.split(" ", 1)[0]
            if " " in authorization
            else None
        )
        observation = {
            "route_id": route_id,
            "method": method,
            "logical_target": LOGICAL_ORIGIN + path,
            "depth": headers.get("Depth"),
            "authorization_scheme": authorization_scheme,
            "content_type": headers.get("Content-Type"),
            "body_sha256": sha256_bytes(body),
            "body_bytes": len(body),
        }
        with self.counter_lock:
            self.route_request_counts[route_id] += 1
            self.request_observations.append(observation)


class IntegrationLabRequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LegadoIntegrationLab/1"
    sys_version = ""

    def log_message(self, format: str, *args: Any) -> None:
        return

    def date_time_string(self, timestamp: Optional[float] = None) -> str:
        return FIXED_DATE

    def do_GET(self) -> None:
        self.handle_integration_request()

    def do_PUT(self) -> None:
        self.handle_integration_request()

    def do_DELETE(self) -> None:
        self.handle_integration_request()

    def do_PROPFIND(self) -> None:
        self.handle_integration_request()

    def do_MKCOL(self) -> None:
        self.handle_integration_request()

    def do_CONNECT(self) -> None:
        self.send_stable_response(
            405,
            {"content-type": "application/json; charset=utf-8"},
            b'{"error":"method_not_allowed"}\n',
        )

    def send_stable_response(
        self,
        status: int,
        headers: Mapping[str, str],
        body: bytes,
    ) -> None:
        try:
            self.send_response_only(status)
            self.send_header("Server", "LegadoIntegrationLab/1")
            self.send_header("Date", FIXED_DATE)
            for key, value in sorted(headers.items()):
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass
        self.close_connection = True

    def handle_integration_request(self) -> None:
        server = self.server
        assert isinstance(server, IntegrationLabHTTPServer)
        if self.headers.get("Host") != server.authority:
            self.send_stable_response(
                421,
                {"content-type": "application/json; charset=utf-8"},
                b'{"error":"authority_mismatch"}\n',
            )
            return
        if self.path.startswith(("http://", "https://", "//")):
            self.send_stable_response(
                400,
                {"content-type": "application/json; charset=utf-8"},
                b'{"error":"absolute_target_denied"}\n',
            )
            return
        if not server.acquire_request_slot():
            self.send_stable_response(
                503,
                {"content-type": "application/json; charset=utf-8"},
                b'{"error":"request_budget_exceeded"}\n',
            )
            return
        try:
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                self.send_stable_response(
                    400,
                    {"content-type": "application/json; charset=utf-8"},
                    b'{"error":"invalid_content_length"}\n',
                )
                return
            if (
                length < 0
                or length > server.limits["max_request_body_bytes"]
            ):
                self.send_stable_response(
                    413,
                    {"content-type": "application/json; charset=utf-8"},
                    b'{"error":"request_body_too_large"}\n',
                )
                return
            body = self.rfile.read(length) if length else b""
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.query or parsed.fragment:
                self.send_stable_response(
                    400,
                    {"content-type": "application/json; charset=utf-8"},
                    b'{"error":"query_or_fragment_denied"}\n',
                )
                return
            signature = (self.command, parsed.path)
            route = server.route_table.get(signature)
            if route is None:
                self.send_stable_response(
                    404,
                    {"content-type": "application/json; charset=utf-8"},
                    b'{"error":"route_not_declared"}\n',
                )
                return
            server.record_request(
                route["id"],
                method=self.command,
                path=parsed.path,
                headers=self.headers,
                body=body,
            )
            response = route["respond"]
            response_body = safe_child(
                server.scenario_directory,
                response["body_file"],
            ).read_bytes()
            self.send_stable_response(
                response["status"],
                response["headers"],
                response_body,
            )
        finally:
            server.semaphore.release()


@contextlib.contextmanager
def running_server(
    root: Path,
    scenario_id: str,
) -> Iterator[IntegrationLabHTTPServer]:
    directory, case, _ = load_scenario(root, scenario_id)
    errors = validate_scenario(root, directory, case)
    if errors:
        raise IntegrationLabError(
            "scenario 无效：\n- " + "\n- ".join(errors)
        )
    if case["transport"]["mode"] != TRANSPORT_FIXTURE_SERVER:
        raise IntegrationLabError(
            "Android listener scenario 不启动 host fixture server"
        )
    server = IntegrationLabHTTPServer(("127.0.0.1", 0), directory, case)
    thread = threading.Thread(
        target=server.serve_forever,
        name=f"IntegrationLab-{scenario_id}",
    )
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join(2.0)
        if thread.is_alive():
            raise IntegrationLabError("IntegrationLab server thread 未退出")
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.settimeout(0.2)
            if probe.connect_ex(server.server_address[:2]) == 0:
                raise IntegrationLabError(
                    "IntegrationLab teardown 后端口仍在监听"
                )
        finally:
            probe.close()


def request_route(
    server: IntegrationLabHTTPServer,
    route: Mapping[str, Any],
) -> Dict[str, Any]:
    method, path = route_signature(route)
    connection = http.client.HTTPConnection(
        server.server_address[0],
        server.server_address[1],
        timeout=server.limits["timeout_ms"] / 1000.0,
    )
    connection.request(method, path, headers={"Host": server.authority})
    response = connection.getresponse()
    body = response.read(server.limits["max_response_bytes"] + 1)
    connection.close()
    return {
        "route_id": route["id"],
        "method": method,
        "logical_target": LOGICAL_ORIGIN + path,
        "status": response.status,
        "body_sha256": sha256_bytes(body),
        "body_bytes": len(body),
    }


def verify_protocol(root: Path, scenario_id: str) -> Dict[str, Any]:
    directory, case, inputs = load_scenario(root, scenario_id)
    errors = validate_scenario(root, directory, case)
    if errors:
        raise IntegrationLabError(
            "scenario 无效：\n- " + "\n- ".join(errors)
        )
    if case["transport"]["mode"] in {
        TRANSPORT_ANDROID_LISTENER,
        TRANSPORT_ANDROID_PLATFORM,
    }:
        first = inputs["cases"]
        second = load_scenario(root, scenario_id)[2]["cases"]
        route_count = 0
    else:
        with running_server(root, scenario_id) as first_server:
            first = [
                request_route(first_server, route)
                for route in case["transport"]["responses"]
            ]
        with running_server(root, scenario_id) as second_server:
            second = [
                request_route(second_server, route)
                for route in case["transport"]["responses"]
            ]
        route_count = len(first)
    if first != second:
        raise IntegrationLabError("IntegrationLab 重复运行 transcript 不一致")
    return {
        "schema_version": 1,
        "scenario": scenario_id,
        "logical_origin": LOGICAL_ORIGIN,
        "transcript_sha256": sha256_bytes(canonical_bytes(first)),
        "route_count": route_count,
        "case_count": len(inputs["cases"]),
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
    verify_parser = subparsers.add_parser("verify-protocol")
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
                    print(f"INTEGRATION_LAB: {error}", file=sys.stderr)
                return 1
            print("INTEGRATION_LAB: OK")
            return 0
        if args.command == "manifest":
            print(
                json.dumps(
                    manifest_value(root),
                    ensure_ascii=False,
                    indent=2,
                )
            )
            return 0
        if args.command == "verify-protocol":
            print(
                json.dumps(
                    verify_protocol(root, args.scenario),
                    ensure_ascii=False,
                    sort_keys=True,
                )
            )
            return 0
        if args.command == "serve":
            with running_server(root, args.scenario) as server:
                print(
                    json.dumps(
                        {
                            "scenario": args.scenario,
                            "origin": f"http://{server.authority}",
                        }
                    ),
                    flush=True,
                )
                try:
                    while True:
                        threading.Event().wait(60)
                except KeyboardInterrupt:
                    pass
            return 0
    except (IntegrationLabError, OSError, UnicodeError) as error:
        print(f"INTEGRATION_LAB: {error}", file=sys.stderr)
        return 2
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
