#!/usr/bin/env python3
"""Legado iOS AI Harness v1.

The control plane intentionally uses only Python's standard library. Product and
conformance checks are configured as argv arrays; this module never executes a
shell command string.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import fnmatch
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
ACTIVE_STATUSES = {"implementing", "verified", "awaiting_human"}
TERMINAL_STATUSES = {"completed", "rejected", "exhausted", "cancelled", "superseded"}
ALL_STATUSES = ACTIVE_STATUSES | TERMINAL_STATUSES | {"ready", "blocked"}
WORK_ITEM_ID = re.compile(r"^IOS-[A-Z][A-Z0-9-]*-[0-9]{3}$")
CAPABILITY_ID = re.compile(r"^CAP-[A-Z0-9-]+$")
IMPORT_RE = re.compile(
    r"^\s*(?:(?:@_exported|@_implementationOnly|@preconcurrency|public|internal|package|private|fileprivate)\s+)*"
    r"import\s+(?:class\s+|struct\s+|enum\s+|protocol\s+|func\s+|var\s+|let\s+)?([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)


class HarnessError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_json(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value))


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as error:
        raise HarnessError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise HarnessError(f"JSON 无效：{path}:{error.lineno}:{error.colno}: {error.msg}") from error


def write_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=False)
        handle.write("\n")
    os.replace(str(temporary), str(path))


def write_text_atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        handle.write(value)
    os.replace(str(temporary), str(path))


def path_matches(path: str, patterns: Iterable[str]) -> bool:
    normalized = path.replace(os.sep, "/").lstrip("./")
    return any(fnmatch.fnmatchcase(normalized, pattern.lstrip("./")) for pattern in patterns)


def require_mapping(value: Any, label: str, errors: List[str]) -> Optional[Dict[str, Any]]:
    if not isinstance(value, dict):
        errors.append(f"{label} 必须是 object")
        return None
    return value


def validate_json_schema(value: Any, schema: Dict[str, Any], location: str = "$") -> List[str]:
    """Validate the JSON-Schema subset used by this repository without dependencies."""
    errors: List[str] = []
    expected_type = schema.get("type")
    if expected_type is not None:
        expected_types = expected_type if isinstance(expected_type, list) else [expected_type]

        def matches(type_name: str) -> bool:
            if type_name == "object":
                return isinstance(value, dict)
            if type_name == "array":
                return isinstance(value, list)
            if type_name == "string":
                return isinstance(value, str)
            if type_name == "integer":
                return isinstance(value, int) and not isinstance(value, bool)
            if type_name == "number":
                return isinstance(value, (int, float)) and not isinstance(value, bool)
            if type_name == "boolean":
                return isinstance(value, bool)
            if type_name == "null":
                return value is None
            return True

        if not any(matches(type_name) for type_name in expected_types):
            errors.append(f"{location}: 类型应为 {expected_types}")
            return errors
    if "const" in schema and value != schema["const"]:
        errors.append(f"{location}: 必须等于 {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{location}: 值不在 enum {schema['enum']}")
    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{location}: 字符串长度小于 {schema['minLength']}")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            errors.append(f"{location}: 不匹配 pattern {schema['pattern']}")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{location}: 小于 minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{location}: 大于 maximum {schema['maximum']}")
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{location}: 数组项少于 {schema['minItems']}")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{location}: 数组项多于 {schema['maxItems']}")
        if schema.get("uniqueItems"):
            encoded = [canonical_bytes(entry) for entry in value]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{location}: 数组项必须唯一")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, entry in enumerate(value):
                errors.extend(validate_json_schema(entry, item_schema, f"{location}[{index}]"))
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{location}: 缺少必填字段 {key}")
        properties = schema.get("properties", {})
        for key, child_schema in properties.items():
            if key in value and isinstance(child_schema, dict):
                errors.extend(validate_json_schema(value[key], child_schema, f"{location}.{key}"))
    return errors


class Harness:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.config_path = self.root / "ios/harness/config.json"
        self.config: Dict[str, Any] = load_json(self.config_path)

    def resolve(self, value: str) -> Path:
        candidate = (self.root / value).resolve()
        try:
            candidate.relative_to(self.root)
        except ValueError as error:
            raise HarnessError(f"路径越出仓库：{value}") from error
        return candidate

    def relative(self, path: Path) -> str:
        return path.resolve().relative_to(self.root).as_posix()

    def architecture_manifest(self) -> Dict[str, Any]:
        """Return the content-addressed architecture authority set.

        The digest deliberately excludes mutable project state. It covers the
        normative architecture documents, executable architecture rules, and
        every ADR whose front matter says it is accepted.
        """
        document_paths = self.config.get(
            "architecture_sources",
            ["ios/docs/architecture.md", "ios/docs/dependencies.md"],
        )
        documents: Dict[str, str] = {}
        for relative in document_paths:
            path = self.resolve(relative)
            if not path.is_file():
                raise HarnessError(f"架构权威文件不存在：{relative}")
            documents[relative] = sha256_bytes(path.read_bytes())

        rules_path = self.resolve(self.config["architecture_rules_path"])
        documents[self.relative(rules_path)] = sha256_bytes(rules_path.read_bytes())

        accepted_adrs: Dict[str, Dict[str, str]] = {}
        for path in sorted(self.resolve("ios/docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
            text = path.read_text(encoding="utf-8")
            id_match = re.search(r"^id:\s*(ADR-[0-9]{4})\s*$", text, re.MULTILINE)
            status_match = re.search(r"^status:\s*([a-z_]+)\s*$", text, re.MULTILINE)
            if not id_match or not status_match or status_match.group(1) != "accepted":
                continue
            adr_id = id_match.group(1)
            if adr_id in accepted_adrs:
                raise HarnessError(f"accepted ADR ID 重复：{adr_id}")
            accepted_adrs[adr_id] = {
                "path": self.relative(path),
                "sha256": sha256_bytes(path.read_bytes()),
            }
        return {
            "schema_version": 1,
            "documents": dict(sorted(documents.items())),
            "accepted_adrs": dict(sorted(accepted_adrs.items())),
        }

    def architecture_digest(self) -> str:
        return sha256_json(self.architecture_manifest())

    def verification_input_hashes(self) -> Dict[str, Any]:
        """Hashes which must still match for Evidence to remain fresh."""
        result = {
            "baseline_sha256": sha256_json(load_json(self.resolve(self.config["baseline_path"]))),
            "architecture_digest_sha256": self.architecture_digest(),
            "architecture_rules_sha256": sha256_json(
                load_json(self.resolve(self.config["architecture_rules_path"]))
            ),
            "harness_config_sha256": sha256_json(self.config),
            "golden_manifest_sha256": sha256_json(
                load_json(self.resolve(self.config["golden_manifest_path"]))
            ),
            "fixture_manifest_sha256": sha256_json(
                load_json(self.resolve(self.config["fixture_manifest_path"]))
            ),
            "dependency_lock_sha256": self.optional_file_hash(
                "ios/Packages/LegadoKit/Package.resolved"
            ),
        }
        source_lab_manifest_path = self.config.get("source_lab_manifest_path")
        if isinstance(source_lab_manifest_path, str):
            manifest = load_json(self.resolve(source_lab_manifest_path))
            result["source_lab_control_sha256"] = manifest.get("control_sha256")
        android_intake_manifest_path = self.config.get("android_intake_manifest_path")
        if isinstance(android_intake_manifest_path, str):
            manifest = load_json(self.resolve(android_intake_manifest_path))
            result["android_intake_control_sha256"] = manifest.get("control_sha256")
        return result

    @staticmethod
    def capability_assurance(capability: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "contract": capability.get("contract"),
            "requirement_refs": capability.get("requirement_refs"),
            "required_evidence": capability.get("required_evidence"),
            "freshness_inputs": capability.get("freshness_inputs"),
            "active_decisions": capability.get("active_decisions"),
        }

    def source_lab_manifest_value(self) -> Optional[Dict[str, Any]]:
        manifest_path = self.config.get("source_lab_manifest_path")
        if not isinstance(manifest_path, str):
            return None
        script = self.resolve("ios/harness/source-lab/source_lab.py")
        result = subprocess.run(
            [sys.executable, "-B", str(script), "manifest", "--root", str(self.root)],
            cwd=str(self.root),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        if result.returncode != 0:
            raise HarnessError("SourceLab manifest 生成失败：" + (result.stderr or result.stdout)[-2000:])
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise HarnessError(f"SourceLab manifest 输出无效：{error}") from error
        if not isinstance(value, dict):
            raise HarnessError("SourceLab manifest 必须是 object")
        return value

    def refresh_source_lab_manifest(self) -> None:
        manifest_path = self.config.get("source_lab_manifest_path")
        if not isinstance(manifest_path, str):
            return
        value = self.source_lab_manifest_value()
        assert value is not None
        write_json_atomic(self.resolve(manifest_path), value)

    def source_lab_selection_digest(self, item: Dict[str, Any]) -> Optional[str]:
        source_lab = item.get("spec", {}).get("source_lab", {})
        if not isinstance(source_lab, dict) or source_lab.get("mode") == "not_applicable":
            return None
        manifest_path = self.config.get("source_lab_manifest_path")
        if not isinstance(manifest_path, str):
            raise HarnessError("工作项使用 SourceLab，但 Harness 未配置 source_lab_manifest_path")
        manifest = load_json(self.resolve(manifest_path))
        selected_ids = set(source_lab.get("scenarios", []))
        selected_behaviors = set(source_lab.get("behaviors", []))
        payload = {
            "schema_version": 1,
            "mode": source_lab.get("mode"),
            "control_sha256": manifest.get("control_sha256"),
            "scenarios": [
                entry
                for entry in manifest.get("scenarios", [])
                if isinstance(entry, dict) and entry.get("id") in selected_ids
            ],
            "coverage": {
                behavior: manifest.get("coverage", {}).get(behavior)
                for behavior in sorted(selected_behaviors)
            },
        }
        return sha256_json(payload)

    def android_intake_bundle_value(self) -> Optional[Dict[str, Any]]:
        script_path = self.config.get("android_intake_script_path")
        if not isinstance(script_path, str):
            return None
        result = subprocess.run(
            [sys.executable, "-B", str(self.resolve(script_path)), "manifest", "--root", str(self.root)],
            cwd=str(self.root),
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if result.returncode != 0:
            raise HarnessError("Android intake manifest 生成失败：" + (result.stderr or result.stdout)[-3000:])
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise HarnessError(f"Android intake manifest 输出无效：{error}") from error
        if not isinstance(value, dict) or not isinstance(value.get("inventory"), dict) or not isinstance(value.get("catalog"), dict):
            raise HarnessError("Android intake manifest 必须包含 inventory/catalog")
        return value

    def refresh_android_intake_manifests(self) -> None:
        inventory_path = self.config.get("android_intake_manifest_path")
        catalog_path = self.config.get("requirement_catalog_path")
        if not isinstance(inventory_path, str) or not isinstance(catalog_path, str):
            return
        bundle = self.android_intake_bundle_value()
        assert bundle is not None
        write_json_atomic(self.resolve(inventory_path), bundle["inventory"])
        write_json_atomic(self.resolve(catalog_path), bundle["catalog"])

    def android_requirement_selection_digest(self, item: Dict[str, Any]) -> Optional[str]:
        script_path = self.config.get("android_intake_script_path")
        if not isinstance(script_path, str):
            return None
        metadata = item.get("metadata")
        item_id = metadata.get("id") if isinstance(metadata, dict) else None
        if not isinstance(item_id, str):
            raise HarnessError("工作项缺少 metadata.id，无法计算 Requirement selection")
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(self.resolve(script_path)),
                "selection",
                "--root",
                str(self.root),
                "--work-item",
                item_id,
            ],
            cwd=str(self.root),
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        if result.returncode != 0:
            raise HarnessError("Requirement selection 无效：" + (result.stderr or result.stdout)[-3000:])
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise HarnessError(f"Requirement selection 输出无效：{error}") from error
        digest = value.get("selection_sha256") if isinstance(value, dict) else None
        if digest is not None and (not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
            raise HarnessError("Requirement selection_sha256 无效")
        return digest

    @contextlib.contextmanager
    def mutation_lock(self):
        runtime = self.root / ".harness-runtime"
        runtime.mkdir(parents=True, exist_ok=True)
        lock_path = runtime / "control.lock"
        with lock_path.open("a+", encoding="utf-8") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise HarnessError("另一个 Harness mutation 正在运行") from error
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    @property
    def state_path(self) -> Path:
        return self.resolve(self.config["state_path"])

    @property
    def events_path(self) -> Path:
        return self.resolve(self.config["events_path"])

    @property
    def status_path(self) -> Path:
        return self.resolve(self.config["status_path"])

    def state(self) -> Dict[str, Any]:
        value = load_json(self.state_path)
        if not isinstance(value, dict):
            raise HarnessError("project/state.json 必须是 object")
        return value

    def work_items(self) -> Dict[str, Dict[str, Any]]:
        directory = self.resolve(self.config["work_items_dir"])
        result: Dict[str, Dict[str, Any]] = {}
        for path in sorted(directory.glob("*.json")):
            value = load_json(path)
            if not isinstance(value, dict):
                raise HarnessError(f"工作项必须是 object：{path}")
            metadata = value.get("metadata")
            if not isinstance(metadata, dict):
                raise HarnessError(f"工作项 metadata 必须是 object：{path}")
            item_id = metadata.get("id")
            if not isinstance(item_id, str):
                raise HarnessError(f"工作项缺少 metadata.id：{path}")
            if item_id in result:
                raise HarnessError(f"工作项 ID 重复：{item_id}")
            if path.stem != item_id:
                raise HarnessError(f"工作项文件名与 ID 不一致：{path.stem} != {item_id}")
            result[item_id] = value
        return result

    def capability(self, capability_id: str) -> Dict[str, Any]:
        path = self.resolve(self.config["capabilities_dir"]) / f"{capability_id}.json"
        value = load_json(path)
        if not isinstance(value, dict):
            raise HarnessError(f"能力状态必须是 object：{path}")
        return value

    def event_lines(self) -> List[Dict[str, Any]]:
        try:
            text = self.events_path.read_text(encoding="utf-8")
        except FileNotFoundError as error:
            raise HarnessError(f"缺少事件日志：{self.events_path}") from error
        result: List[Dict[str, Any]] = []
        for number, line in enumerate(text.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise HarnessError(f"事件日志第 {number} 行无效：{error.msg}") from error
            if not isinstance(value, dict):
                raise HarnessError(f"事件日志第 {number} 行必须是 object")
            result.append(value)
        return result

    @staticmethod
    def event_hash(event: Dict[str, Any]) -> str:
        unsigned = dict(event)
        unsigned.pop("event_hash", None)
        return sha256_json(unsigned)

    def append_event(self, name: str, work_item_id: Optional[str], payload: Dict[str, Any]) -> Dict[str, Any]:
        events = self.event_lines()
        previous_hash = events[-1]["event_hash"] if events else None
        event: Dict[str, Any] = {
            "sequence": len(events) + 1,
            "event": name,
            "work_item_id": work_item_id,
            "occurred_at": utc_now(),
            "previous_event_hash": previous_hash,
            "payload": payload,
        }
        event["event_hash"] = self.event_hash(event)
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
            handle.write("\n")
        return event

    def validate_events(self) -> List[str]:
        errors: List[str] = []
        try:
            events = self.event_lines()
        except HarnessError as error:
            return [str(error)]
        previous: Optional[str] = None
        for expected_sequence, event in enumerate(events, start=1):
            if event.get("sequence") != expected_sequence:
                errors.append(f"事件 sequence 不连续：期望 {expected_sequence}，实际 {event.get('sequence')}")
            if event.get("previous_event_hash") != previous:
                errors.append(f"事件 {expected_sequence} 的 previous_event_hash 不匹配")
            expected_hash = self.event_hash(event)
            if event.get("event_hash") != expected_hash:
                errors.append(f"事件 {expected_sequence} 的 event_hash 无效")
            previous = event.get("event_hash")
        if not events:
            errors.append("事件日志为空")
        return errors

    def validate_work_item(self, item: Dict[str, Any], item_id: str) -> List[str]:
        errors: List[str] = []
        schema = load_json(self.resolve("ios/harness/schemas/work-item.schema.json"))
        errors.extend(f"{item_id}: {error}" for error in validate_json_schema(item, schema))
        if item.get("api_version") != "legado.harness/v1" or item.get("kind") != "WorkItem":
            errors.append(f"{item_id}: api_version/kind 无效")
        metadata = require_mapping(item.get("metadata"), f"{item_id}.metadata", errors)
        spec = require_mapping(item.get("spec"), f"{item_id}.spec", errors)
        if metadata is None or spec is None:
            return errors
        if metadata.get("id") != item_id or not WORK_ITEM_ID.match(item_id):
            errors.append(f"{item_id}: ID 格式无效")
        if not isinstance(metadata.get("title"), str) or not metadata.get("title"):
            errors.append(f"{item_id}: title 不能为空")
        if not isinstance(metadata.get("priority"), int) or not 0 <= metadata.get("priority", -1) <= 100:
            errors.append(f"{item_id}: priority 必须为 0...100")
        if metadata.get("risk") not in {"low", "medium", "high", "critical"}:
            errors.append(f"{item_id}: risk 无效")
        capability = spec.get("capability")
        if not isinstance(capability, str) or not CAPABILITY_ID.match(capability):
            errors.append(f"{item_id}: capability ID 无效")
        depends = spec.get("depends_on")
        if not isinstance(depends, list) or any(not isinstance(entry, str) for entry in depends):
            errors.append(f"{item_id}: depends_on 必须是字符串数组")
        scope = require_mapping(spec.get("scope"), f"{item_id}.scope", errors)
        if scope is not None:
            for name in ("allow_write", "deny_write"):
                patterns = scope.get(name)
                if not isinstance(patterns, list) or any(not isinstance(entry, str) or not entry for entry in patterns):
                    errors.append(f"{item_id}: scope.{name} 必须是非空字符串数组")
            for name in ("max_files_changed", "max_changed_lines"):
                if not isinstance(scope.get(name), int) or scope.get(name, 0) < 1:
                    errors.append(f"{item_id}: scope.{name} 必须为正整数")
        acceptance = require_mapping(spec.get("acceptance"), f"{item_id}.acceptance", errors)
        if acceptance is not None:
            criteria = acceptance.get("criteria")
            if not isinstance(criteria, list) or not criteria:
                errors.append(f"{item_id}: acceptance.criteria 不能为空")
            checks = acceptance.get("required_checks")
            if not isinstance(checks, list) or not checks:
                errors.append(f"{item_id}: acceptance.required_checks 不能为空")
            else:
                configured = self.config.get("checks", {})
                for check_id in checks:
                    if not isinstance(check_id, str) or not check_id:
                        errors.append(f"{item_id}: required check ID 必须是非空字符串：{check_id!r}")
                    elif check_id not in configured:
                        errors.append(f"{item_id}: 未配置 required check：{check_id}")
                evidence_sources = {
                    check_id for check_id in checks if isinstance(check_id, str)
                } | {"architecture", "scope-policy", "memory-close"}
                for criterion in criteria or []:
                    verified_by = criterion.get("verified_by") if isinstance(criterion, dict) else None
                    if not isinstance(verified_by, list) or not verified_by:
                        errors.append(f"{item_id}: 每条 acceptance criterion 必须声明 verified_by")
                    elif any(not isinstance(source, str) or source not in evidence_sources for source in verified_by):
                        errors.append(f"{item_id}: criterion 引用了未执行的 evidence source：{verified_by}")
                    requirement_clauses = criterion.get("requirement_clauses") if isinstance(criterion, dict) else None
                    if not isinstance(requirement_clauses, list) or any(
                        not isinstance(reference, str)
                        or re.fullmatch(r"REQ-[A-Z0-9-]+#RC-[0-9]{2}", reference) is None
                        for reference in requirement_clauses
                    ):
                        errors.append(f"{item_id}: criterion.requirement_clauses 必须是合法引用数组")
        baseline_checks = spec.get("baseline_checks", [])
        if not isinstance(baseline_checks, list):
            errors.append(f"{item_id}: baseline_checks 必须是数组")
        else:
            for check_id in baseline_checks:
                if not isinstance(check_id, str) or not check_id:
                    errors.append(f"{item_id}: baseline check ID 必须是非空字符串：{check_id!r}")
                elif check_id not in self.config.get("checks", {}):
                    errors.append(f"{item_id}: 未配置 baseline check：{check_id}")
        for name in ("architecture_refs", "gates", "stop_on"):
            if not isinstance(spec.get(name), list):
                errors.append(f"{item_id}: {name} 必须是数组")
        for gate in spec.get("gates", []):
            if not isinstance(gate, str) or re.fullmatch(r"[a-z0-9][a-z0-9-]*", gate) is None:
                errors.append(f"{item_id}: gate ID 无效：{gate}")
        if not isinstance(spec.get("budget"), dict) or not isinstance(spec.get("memory"), dict):
            errors.append(f"{item_id}: budget/memory 必须是 object")
        if not isinstance(spec.get("completion_effects", {}), dict):
            errors.append(f"{item_id}: completion_effects 必须是 object")
        requirements = require_mapping(spec.get("requirements"), f"{item_id}.requirements", errors)
        if requirements is not None:
            mode = requirements.get("mode")
            refs = requirements.get("refs")
            none_reason = requirements.get("none_reason")
            if mode not in {"implementation", "enabler", "characterization", "verification", "control_plane"}:
                errors.append(f"{item_id}: requirements.mode 无效")
            if not isinstance(refs, list):
                errors.append(f"{item_id}: requirements.refs 必须是数组")
                refs = []
            if mode == "control_plane":
                if refs or not isinstance(none_reason, str) or not none_reason.strip():
                    errors.append(f"{item_id}: control_plane 必须清空 Requirement refs 并填写 none_reason")
            else:
                if not refs or none_reason is not None:
                    errors.append(f"{item_id}: 非 control_plane 必须引用 Requirement，none_reason 为 null")
                required_checks = spec.get("acceptance", {}).get("required_checks", [])
                if isinstance(self.config.get("android_intake_script_path"), str) and "android-intake-contract" not in required_checks:
                    errors.append(f"{item_id}: 引用 Requirement 必须执行 android-intake-contract")
            seen_requirement_refs: Set[Tuple[str, int]] = set()
            for reference in refs:
                if not isinstance(reference, dict) or set(reference) != {"id", "revision", "clauses"}:
                    errors.append(f"{item_id}: Requirement ref 必须精确包含 id/revision/clauses")
                    continue
                requirement_id = reference.get("id")
                revision = reference.get("revision")
                clauses = reference.get("clauses")
                if not isinstance(requirement_id, str) or re.fullmatch(r"REQ-[A-Z0-9-]+", requirement_id) is None:
                    errors.append(f"{item_id}: Requirement ID 无效：{requirement_id}")
                if not isinstance(revision, int) or revision < 1:
                    errors.append(f"{item_id}: Requirement revision 无效：{requirement_id}")
                if not isinstance(clauses, list) or not clauses or any(
                    not isinstance(clause, str) or re.fullmatch(r"RC-[0-9]{2}", clause) is None for clause in clauses
                ):
                    errors.append(f"{item_id}: Requirement clauses 无效：{requirement_id}")
                key = (str(requirement_id), revision if isinstance(revision, int) else -1)
                if key in seen_requirement_refs:
                    errors.append(f"{item_id}: Requirement ref 重复：{requirement_id}@{revision}")
                seen_requirement_refs.add(key)
        source_lab = require_mapping(spec.get("source_lab"), f"{item_id}.source_lab", errors)
        if source_lab is not None:
            mode = source_lab.get("mode")
            behaviors = source_lab.get("behaviors")
            scenarios = source_lab.get("scenarios")
            none_reason = source_lab.get("none_reason")
            if mode not in {"not_applicable", "reuse", "extend"}:
                errors.append(f"{item_id}: source_lab.mode 无效")
            if not isinstance(behaviors, list) or any(not isinstance(entry, str) for entry in behaviors):
                errors.append(f"{item_id}: source_lab.behaviors 必须是字符串数组")
                behaviors = []
            if not isinstance(scenarios, list) or any(not isinstance(entry, str) for entry in scenarios):
                errors.append(f"{item_id}: source_lab.scenarios 必须是字符串数组")
                scenarios = []
            if mode == "not_applicable":
                if behaviors or scenarios or not isinstance(none_reason, str) or not none_reason.strip():
                    errors.append(f"{item_id}: SourceLab 不适用时必须清空引用并填写 none_reason")
            elif mode in {"reuse", "extend"}:
                if not behaviors or not scenarios or none_reason is not None:
                    errors.append(f"{item_id}: SourceLab reuse/extend 必须声明 behavior/scenario，none_reason 为 null")
                required_checks = spec.get("acceptance", {}).get("required_checks", [])
                if "source-lab-contract" not in required_checks:
                    errors.append(f"{item_id}: 使用 SourceLab 必须执行 source-lab-contract")
                if mode == "extend" and "scenario-provenance-review" not in spec.get("gates", []):
                    errors.append(f"{item_id}: 扩展 SourceLab 必须声明 scenario-provenance-review gate")
        return errors

    def fixture_manifest_value(self) -> Tuple[Dict[str, Any], List[str]]:
        errors: List[str] = []
        fixture_root = self.resolve("ios/harness/fixtures")
        fixtures: List[Dict[str, Any]] = []
        seen: Set[str] = set()
        for case_path in sorted(fixture_root.rglob("case.json")):
            try:
                case = load_json(case_path)
            except HarnessError as error:
                errors.append(str(error))
                continue
            fixture_id = case.get("id") if isinstance(case, dict) else None
            if not isinstance(fixture_id, str) or not fixture_id:
                errors.append(f"fixture 缺少 id：{self.relative(case_path)}")
                continue
            if fixture_id in seen:
                errors.append(f"fixture ID 重复：{fixture_id}")
                continue
            seen.add(fixture_id)
            directory = case_path.parent
            file_entries = []
            for path in sorted(entry for entry in directory.rglob("*") if entry.is_file()):
                file_entries.append(
                    {
                        "path": path.relative_to(directory).as_posix(),
                        "sha256": sha256_bytes(path.read_bytes()),
                    }
                )
            fixtures.append(
                {
                    "id": fixture_id,
                    "path": self.relative(directory),
                    "sha256": sha256_json(file_entries),
                }
            )
        return {
            "schema_version": 1,
            "compatibility_profile": "android-legado-v1",
            "canonicalizer": "canonical-v1",
            "fixtures": fixtures,
        }, errors

    def refresh_fixture_manifest(self) -> None:
        manifest, errors = self.fixture_manifest_value()
        if errors:
            raise HarnessError("fixture manifest 无法生成：\n- " + "\n- ".join(errors))
        write_json_atomic(self.resolve(self.config["fixture_manifest_path"]), manifest)

    def architecture_issues(self) -> Tuple[List[str], List[str]]:
        errors: List[str] = []
        warnings: List[str] = []
        rules = load_json(self.resolve(self.config["architecture_rules_path"]))
        source_root = self.resolve(rules["source_root"])
        targets = rules.get("targets", {})
        test_targets = rules.get("test_targets", {})
        known_project = set(rules.get("known_project_modules", []))
        known_external = set(rules.get("known_external_modules", []))

        if not source_root.exists():
            warnings.append(f"Swift source root 尚未创建：{self.relative(source_root)}")
            return errors, warnings

        for target_dir in sorted(path for path in source_root.iterdir() if path.is_dir()):
            target = target_dir.name
            if target not in targets:
                errors.append(f"ARCH-001: 未登记 Target 目录：{self.relative(target_dir)}")
                continue
            rule = targets[target]
            allowed_project = set(rule.get("dependencies", []))
            allowed_external = set(rule.get("external_imports", []))
            forbidden = set(rule.get("forbidden_imports", []))
            for swift_file in sorted(target_dir.rglob("*.swift")):
                try:
                    text = swift_file.read_text(encoding="utf-8")
                except UnicodeDecodeError:
                    errors.append(f"Swift 文件不是 UTF-8：{self.relative(swift_file)}")
                    continue
                relative = self.relative(swift_file)
                for module in IMPORT_RE.findall(text):
                    if module in forbidden:
                        errors.append(f"ARCH import: {relative} 禁止 import {module}")
                    elif module in known_project and module not in allowed_project:
                        errors.append(f"ARCH-001: {target} 未获准依赖 {module}（{relative}）")
                    elif module in known_external and module not in allowed_external:
                        errors.append(f"外部模块 {module} 只能出现在批准 Adapter（{relative}）")
                code_without_line_comments = "\n".join(
                    line for line in text.splitlines() if not line.lstrip().startswith("//")
                )
                for banned in rules.get("banned_patterns", []):
                    selected_targets = banned.get("targets", [])
                    if "*" not in selected_targets and target not in selected_targets:
                        continue
                    if re.search(banned["pattern"], code_without_line_comments):
                        errors.append(f"{banned['id']}: {relative}")
                if target.startswith("Feature") and swift_file.name.endswith("Store.swift"):
                    if "@MainActor" not in code_without_line_comments:
                        errors.append(f"ARCH-007: Feature Store 缺少 @MainActor：{relative}")
                    if "private(set)" not in code_without_line_comments:
                        errors.append(f"ARCH-007: Feature Store 未只读暴露状态：{relative}")

        package_path = source_root.parent / "Package.swift"
        if package_path.exists():
            dump_errors, dump_warnings = self.validate_package_graph(
                package_path, targets, test_targets, rules.get("profiles", {})
            )
            errors.extend(dump_errors)
            warnings.extend(dump_warnings)
        else:
            warnings.append("Package.swift 尚未创建；IOS-BOOT-001 将建立依赖图")
        return errors, warnings

    def validate_package_graph(
        self,
        package_path: Path,
        target_rules: Dict[str, Any],
        test_target_rules: Dict[str, Any],
        profiles: Dict[str, Any],
    ) -> Tuple[List[str], List[str]]:
        errors: List[str] = []
        warnings: List[str] = []
        command = ["swift", "package", "--package-path", str(package_path.parent), "dump-package"]
        try:
            result = subprocess.run(command, cwd=str(self.root), capture_output=True, text=True, timeout=60, check=False)
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            return errors, [f"无法读取 Swift package graph：{error}"]
        if result.returncode != 0:
            errors.append(f"Package.swift 无法 dump：{result.stderr.strip()[-1000:]}")
            return errors, warnings
        try:
            package = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            errors.append(f"swift package dump-package 输出无效 JSON：{error}")
            return errors, warnings
        project_dependencies: Dict[str, Set[str]] = {}
        package_targets: Set[str] = set()
        for target in package.get("targets", []):
            name = target.get("name")
            if not isinstance(name, str):
                errors.append("Package.swift 中存在无名 Target")
                continue
            package_targets.add(name)
            target_type = target.get("type")
            rule_table = test_target_rules if target_type == "test" else target_rules
            if name not in rule_table:
                errors.append(f"ARCH-001: Package.swift 中 Target 未登记：{name}")
                continue
            allowed = set(rule_table[name].get("dependencies", []))
            allowed_external = set(rule_table[name].get("external_imports", []))
            actual: Set[str] = set()
            for dependency in target.get("dependencies", []):
                if not isinstance(dependency, dict):
                    continue
                for value in dependency.values():
                    if isinstance(value, list) and value and isinstance(value[0], str):
                        actual.add(value[0])
                    elif isinstance(value, str):
                        actual.add(value)
            forbidden = sorted(
                dep
                for dep in actual
                if (dep in target_rules or dep in test_target_rules) and dep not in allowed
            )
            if forbidden:
                errors.append(f"ARCH-001: {name} 的 Package 依赖越界：{', '.join(forbidden)}")
            unknown_external = sorted(
                dep for dep in actual if dep not in target_rules and dep not in test_target_rules and dep not in allowed_external
            )
            if unknown_external:
                errors.append(f"未批准的外部 package product：{name} -> {', '.join(unknown_external)}")
            project_dependencies[name] = {
                dep for dep in actual if dep in target_rules or dep in test_target_rules
            }

        products = {
            product.get("name"): product
            for product in package.get("products", [])
            if isinstance(product, dict) and isinstance(product.get("name"), str)
        }
        for profile_name, profile in profiles.items():
            if not isinstance(profile, dict):
                errors.append(f"发行 profile 配置无效：{profile_name}")
                continue
            root_product = profile.get("root_product")
            product = products.get(root_product)
            if product is None:
                errors.append(f"发行 profile {profile_name} 缺少根产品：{root_product}")
                continue
            roots = product.get("targets", [])
            if not isinstance(roots, list) or any(not isinstance(entry, str) for entry in roots):
                errors.append(f"发行 profile {profile_name} 的产品 targets 无效")
                continue
            closure: Set[str] = set()
            pending = list(roots)
            while pending:
                current = pending.pop()
                if current in closure:
                    continue
                closure.add(current)
                pending.extend(project_dependencies.get(current, set()) - closure)
            unknown_roots = sorted(closure - package_targets)
            if unknown_roots:
                errors.append(
                    f"发行 profile {profile_name} 引用了不存在 Target：{', '.join(unknown_roots)}"
                )
            forbidden_targets = sorted(closure & set(profile.get("forbidden_targets", [])))
            if forbidden_targets:
                errors.append(
                    f"发行 profile {profile_name} 闭包包含禁用 Target：{', '.join(forbidden_targets)}"
                )
            missing_required = sorted(set(profile.get("required_targets", [])) - closure)
            if missing_required:
                errors.append(
                    f"发行 profile {profile_name} 缺少必需 Target：{', '.join(missing_required)}"
                )
        return errors, warnings

    def validate_references(self, items: Dict[str, Dict[str, Any]]) -> List[str]:
        errors: List[str] = []
        architecture_text = self.resolve("ios/docs/architecture.md").read_text(encoding="utf-8")
        adr_dir = self.resolve("ios/docs/adr")
        adr_text = "\n".join(path.read_text(encoding="utf-8") for path in sorted(adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md")))
        for item_id, item in items.items():
            spec = item["spec"]
            for dependency in spec.get("depends_on", []):
                if dependency not in items:
                    errors.append(f"{item_id}: depends_on 不存在：{dependency}")
            for reference in spec.get("architecture_refs", []):
                if reference.startswith("ARCH-") and reference not in architecture_text:
                    errors.append(f"{item_id}: 架构引用不存在：{reference}")
                if reference.startswith("ADR-") and reference not in adr_text:
                    errors.append(f"{item_id}: ADR 引用不存在：{reference}")
            inputs = spec.get("inputs", {})
            for context in inputs.get("context_files", []):
                if not self.resolve(context).exists():
                    errors.append(f"{item_id}: context file 不存在：{context}")
            capability_id = spec.get("capability")
            try:
                capability = self.capability(capability_id)
            except HarnessError as error:
                errors.append(f"{item_id}: {error}")
                continue
            if capability.get("id") != capability_id:
                errors.append(f"{item_id}: capability 文件 ID 不一致")
            if not isinstance(capability.get("revision"), int) or capability.get("revision", 0) < 1:
                errors.append(f"{item_id}: capability revision 无效")
            contract = capability.get("contract")
            if not isinstance(contract, str) or not self.resolve(contract).exists():
                errors.append(f"{item_id}: capability contract 不存在：{contract}")
        errors.extend(self.detect_dependency_cycles(items))
        return errors

    def memory_issues(self, items: Dict[str, Dict[str, Any]], state: Dict[str, Any]) -> List[str]:
        errors: List[str] = []
        adr_statuses: Dict[str, str] = {}
        for path in sorted(self.resolve("ios/docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
            text = path.read_text(encoding="utf-8")
            id_match = re.search(r"^id:\s*(ADR-[0-9]{4})\s*$", text, re.MULTILINE)
            status_match = re.search(r"^status:\s*([a-z_]+)\s*$", text, re.MULTILINE)
            if id_match and status_match:
                adr_statuses[id_match.group(1)] = status_match.group(1)

        capability_required = {
            "schema_version",
            "id",
            "revision",
            "title",
            "area",
            "contract",
            "requirement_refs",
            "declared_status",
            "profiles",
            "owners",
            "depends_on",
            "active_decisions",
            "open_compatibility",
            "open_pitfalls",
            "blockers",
            "required_evidence",
            "freshness_inputs",
            "latest_evidence",
            "next_actions",
            "updated_at",
            "updated_by",
        }
        capabilities: Dict[str, Dict[str, Any]] = {}
        capability_schema = load_json(self.resolve("ios/harness/schemas/capability-state.schema.json"))
        for path in sorted(self.resolve(self.config["capabilities_dir"]).glob("CAP-*.json")):
            try:
                capability = load_json(path)
            except HarnessError as error:
                errors.append(str(error))
                continue
            if not isinstance(capability, dict):
                errors.append(f"能力状态必须是 object：{self.relative(path)}")
                continue
            errors.extend(
                f"{path.stem}: {error}" for error in validate_json_schema(capability, capability_schema)
            )
            missing = sorted(capability_required - set(capability))
            if missing:
                errors.append(f"{path.stem}: 缺少能力字段：{', '.join(missing)}")
                continue
            capability_id = capability["id"]
            if capability_id != path.stem or not CAPABILITY_ID.match(capability_id):
                errors.append(f"能力 ID/文件名不一致：{self.relative(path)}")
            if capability_id in capabilities:
                errors.append(f"能力 ID 重复：{capability_id}")
            capabilities[capability_id] = capability
            if not isinstance(capability.get("revision"), int) or capability["revision"] < 1:
                errors.append(f"{capability_id}: revision 无效")
            if capability.get("declared_status") not in {
                "proposed", "implementing", "partial", "verified", "blocked", "stale", "regressed", "deprecated", "unsupported"
            }:
                errors.append(f"{capability_id}: declared_status 无效")
            next_actions = capability.get("next_actions")
            if not isinstance(next_actions, list) or len(next_actions) > 5:
                errors.append(f"{capability_id}: next_actions 必须不超过 5 项")
            for decision in capability.get("active_decisions", []):
                if adr_statuses.get(decision) != "accepted":
                    errors.append(f"{capability_id}: active decision 不是 accepted ADR：{decision}")
            latest = capability.get("latest_evidence")
            if latest is not None and (not isinstance(latest, str) or not self.resolve(latest).exists()):
                errors.append(f"{capability_id}: latest_evidence 不存在：{latest}")
            if capability.get("declared_status") == "verified" and latest is None:
                errors.append(f"{capability_id}: verified 但没有 latest_evidence")
            freshness_inputs = capability.get("freshness_inputs")
            if not isinstance(freshness_inputs, list) or not freshness_inputs or any(
                not isinstance(entry, str) or not entry for entry in freshness_inputs
            ):
                errors.append(f"{capability_id}: freshness_inputs 必须是非空字符串数组")

        for item_id, item in items.items():
            if item["spec"].get("capability") not in capabilities:
                errors.append(f"{item_id}: 引用未登记能力 {item['spec'].get('capability')}")

        compatibility_ids: Set[str] = set()
        compatibility_records: Dict[str, Dict[str, Any]] = {}
        compatibility_schema = load_json(self.resolve("ios/harness/schemas/compatibility-record.schema.json"))
        for path in sorted(self.resolve("ios/project/compatibility").glob("COMP-*.json")):
            if ".template." in path.name:
                continue
            record = load_json(path)
            errors.extend(f"{path.stem}: {error}" for error in validate_json_schema(record, compatibility_schema))
            if not isinstance(record, dict):
                errors.append(f"兼容记录必须是 object：{self.relative(path)}")
                continue
            record_id = record.get("id") if isinstance(record, dict) else None
            if record_id != path.stem or record_id in compatibility_ids:
                errors.append(f"兼容记录 ID 重复或与文件名不一致：{self.relative(path)}")
            if isinstance(record_id, str):
                compatibility_ids.add(record_id)
                compatibility_records[record_id] = record
            if record.get("classification") == "intentional_difference":
                decision_adr = record.get("decision_adr")
                if adr_statuses.get(decision_adr) != "accepted":
                    errors.append(f"{record_id}: intentional_difference 必须引用 accepted ADR")

        pitfall_fingerprints: Set[str] = set()
        pitfall_records: Dict[str, Dict[str, Any]] = {}
        pitfall_schema = load_json(self.resolve("ios/harness/schemas/pitfall-record.schema.json"))
        for path in sorted(self.resolve("ios/project/pitfalls").glob("PIT-*.json")):
            if ".template." in path.name:
                continue
            record = load_json(path)
            errors.extend(f"{path.stem}: {error}" for error in validate_json_schema(record, pitfall_schema))
            if not isinstance(record, dict):
                errors.append(f"Pitfall 记录必须是 object：{self.relative(path)}")
                continue
            record_id = record.get("id") if isinstance(record, dict) else None
            if record_id != path.stem:
                errors.append(f"Pitfall ID 与文件名不一致：{self.relative(path)}")
            fingerprint = record.get("fingerprint") if isinstance(record, dict) else None
            if isinstance(record_id, str):
                pitfall_records[record_id] = record
            if not isinstance(fingerprint, str) or not fingerprint:
                errors.append(f"{record_id}: Pitfall fingerprint 为空")
            elif fingerprint in pitfall_fingerprints:
                errors.append(f"Pitfall fingerprint 重复：{fingerprint}")
            else:
                pitfall_fingerprints.add(fingerprint)

        for capability_id, capability in capabilities.items():
            for record_id in capability.get("open_compatibility", []):
                record = compatibility_records.get(record_id)
                if record is None or record.get("capability") != capability_id or record.get("status") != "open":
                    errors.append(f"{capability_id}: open_compatibility 引用无效：{record_id}")
            for record_id in capability.get("open_pitfalls", []):
                record = pitfall_records.get(record_id)
                if record is None or capability_id not in record.get("capabilities", []) or record.get("status") not in {"open", "mitigated"}:
                    errors.append(f"{capability_id}: open_pitfalls 引用无效：{record_id}")
        for record_id, record in compatibility_records.items():
            record_capability = record.get("capability")
            capability = capabilities.get(record_capability) if isinstance(record_capability, str) else None
            if record.get("status") == "open" and (capability is None or record_id not in capability.get("open_compatibility", [])):
                errors.append(f"{record_id}: open 兼容记录没有被 capability 反向引用")
            introduced_by = record.get("introduced_by")
            if not isinstance(introduced_by, str) or introduced_by not in items:
                errors.append(f"{record_id}: introduced_by 不是已登记工作项")
        for record_id, record in pitfall_records.items():
            record_capabilities = record.get("capabilities", [])
            if not isinstance(record_capabilities, list):
                continue
            for capability_id in record_capabilities:
                if not isinstance(capability_id, str):
                    continue
                capability = capabilities.get(capability_id)
                if record.get("status") in {"open", "mitigated"} and (
                    capability is None or record_id not in capability.get("open_pitfalls", [])
                ):
                    errors.append(f"{record_id}: 活跃 Pitfall 没有被 {capability_id} 反向引用")

        checkpoint_schema = load_json(self.resolve("ios/harness/schemas/checkpoint.schema.json"))
        for path in sorted(self.resolve(self.config["checkpoints_dir"]).glob("IOS-*.json")):
            checkpoint = load_json(path)
            errors.extend(f"{path.stem}: {error}" for error in validate_json_schema(checkpoint, checkpoint_schema))
        evidence_schema = load_json(self.resolve("ios/harness/schemas/evidence.schema.json"))
        evidence_records: Dict[str, Dict[str, Any]] = {}
        evidence_hashes: Dict[str, str] = {}
        for path in sorted(self.resolve(self.config["evidence_dir"]).glob("*.json")):
            evidence = load_json(path)
            errors.extend(f"{path.stem}: {error}" for error in validate_json_schema(evidence, evidence_schema))
            relative = self.relative(path)
            if isinstance(evidence, dict):
                evidence_records[relative] = evidence
                evidence_hashes[relative] = sha256_bytes(path.read_bytes())
                if evidence.get("run_id") != path.stem:
                    errors.append(f"{relative}: run_id 与文件名不一致")
        approval_schema = load_json(self.resolve("ios/harness/schemas/approval.schema.json"))
        for path in sorted(self.resolve(self.config["approvals_dir"]).glob("*.json")):
            approval = load_json(path)
            errors.extend(f"{path.stem}: {error}" for error in validate_json_schema(approval, approval_schema))
        fixture_schema = load_json(self.resolve("ios/harness/schemas/fixture.schema.json"))
        for path in sorted(self.resolve("ios/harness/fixtures").rglob("case.json")):
            fixture = load_json(path)
            errors.extend(f"{self.relative(path)}: {error}" for error in validate_json_schema(fixture, fixture_schema))
        dependency_policy_path = self.config.get("dependency_policy_path")
        if isinstance(dependency_policy_path, str):
            dependency_policy_schema = load_json(self.resolve("ios/harness/schemas/dependency-policy.schema.json"))
            dependency_policy = load_json(self.resolve(dependency_policy_path))
            errors.extend(
                f"dependency-policy: {error}"
                for error in validate_json_schema(dependency_policy, dependency_policy_schema)
            )
            dependency_proposal_schema = load_json(self.resolve("ios/harness/schemas/dependency-proposal.schema.json"))
            proposal_directory = self.resolve("ios/project/dependency-proposals")
            paths = sorted(proposal_directory.glob("DEP-*.json")) if proposal_directory.exists() else []
            for path in paths:
                if ".template." in path.name:
                    continue
                proposal = load_json(path)
                errors.extend(
                    f"{path.stem}: {error}"
                    for error in validate_json_schema(proposal, dependency_proposal_schema)
                )

        for item_id, runtime in state.get("work_items", {}).items():
            if not isinstance(runtime, dict):
                continue
            evidence = runtime.get("last_evidence")
            if evidence is not None and (not isinstance(evidence, str) or not self.resolve(evidence).exists()):
                errors.append(f"{item_id}: state.last_evidence 不存在：{evidence}")
            if runtime.get("status") == "completed":
                checkpoint = self.resolve(self.config["checkpoints_dir"]) / f"{item_id}.json"
                if not checkpoint.exists():
                    errors.append(f"{item_id}: completed 但缺少 checkpoint")

        try:
            current_inputs = self.verification_input_hashes()
        except HarnessError as error:
            errors.append(str(error))
            current_inputs = {}
        for capability_id, capability in capabilities.items():
            latest = capability.get("latest_evidence")
            if not isinstance(latest, str):
                continue
            evidence = evidence_records.get(latest)
            if evidence is None:
                errors.append(f"{capability_id}: latest_evidence 不在受管 Evidence 目录：{latest}")
                continue
            if evidence.get("result") != "passed":
                errors.append(f"{capability_id}: latest Evidence 不是 passed")
            updated_by = capability.get("updated_by")
            if evidence.get("work_item_id") != updated_by:
                errors.append(f"{capability_id}: latest Evidence 与 updated_by 不一致")
            item = items.get(updated_by)
            if item is None:
                errors.append(f"{capability_id}: updated_by 不是已登记工作项：{updated_by}")
            elif item.get("spec", {}).get("capability") != capability_id:
                errors.append(f"{capability_id}: updated_by 工作项属于其他 capability：{updated_by}")
            elif evidence.get("work_item_sha256") != sha256_json(item):
                errors.append(f"{capability_id}: latest Evidence 的工作项契约已过期")
            runtime = state.get("work_items", {}).get(updated_by, {})
            if not isinstance(runtime, dict) or runtime.get("last_evidence") != latest:
                errors.append(f"{capability_id}: state 未绑定 latest Evidence")
            elif runtime.get("last_evidence_sha256") != evidence_hashes.get(latest):
                errors.append(f"{capability_id}: latest Evidence 哈希与 state 不一致")

            if capability.get("declared_status") != "verified":
                continue
            evidence_checks = evidence.get("checks")
            if not isinstance(evidence_checks, list):
                errors.append(f"{capability_id}: Evidence checks 不是数组")
                evidence_checks = []
            passed_checks: Set[str] = set()
            for check in evidence_checks:
                if not isinstance(check, dict) or not isinstance(check.get("id"), str):
                    continue
                check_id = check["id"]
                definition = self.config.get("checks", {}).get(check_id)
                if (
                    isinstance(definition, dict)
                    and check.get("passed") is True
                    and check.get("exit_code") == 0
                    and check.get("timed_out") is False
                    and check.get("process_leak") is False
                    and check.get("definition_sha256") == sha256_json(definition)
                ):
                    passed_checks.add(check_id)
            if evidence.get("architecture_errors") == []:
                passed_checks.add("architecture")
            if evidence.get("policy_errors") == []:
                passed_checks.add("scope-policy")
            if isinstance(item, dict):
                required_by_item = set(item.get("spec", {}).get("acceptance", {}).get("required_checks", []))
                missing_item_checks = sorted(required_by_item - passed_checks)
                if missing_item_checks:
                    errors.append(
                        f"{capability_id}: Evidence 未覆盖工作项 required checks：{', '.join(missing_item_checks)}"
                    )
            missing_checks = sorted(set(capability.get("required_evidence", [])) - passed_checks)
            if missing_checks:
                errors.append(
                    f"{capability_id}: verified Evidence 缺少 required checks：{', '.join(missing_checks)}"
                )
            evidence_inputs = evidence.get("inputs")
            if not isinstance(evidence_inputs, dict):
                errors.append(f"{capability_id}: Evidence inputs 不是 object")
                evidence_inputs = {}
            for input_name in capability.get("freshness_inputs", []):
                if input_name == "android_requirement_selection_sha256":
                    if not isinstance(item, dict):
                        errors.append(f"{capability_id}: 无法计算 Requirement selection freshness")
                        continue
                    try:
                        expected_hash = self.android_requirement_selection_digest(item)
                    except HarnessError as error:
                        errors.append(f"{capability_id}: {error}")
                        continue
                    if evidence_inputs.get(input_name) != expected_hash:
                        errors.append(f"{capability_id}: verified Evidence 输入已过期：{input_name}")
                    continue
                if input_name == "source_lab_selection_sha256":
                    if not isinstance(item, dict):
                        errors.append(f"{capability_id}: 无法计算 SourceLab selection freshness")
                        continue
                    try:
                        expected_hash = self.source_lab_selection_digest(item)
                    except HarnessError as error:
                        errors.append(f"{capability_id}: {error}")
                        continue
                    if evidence_inputs.get(input_name) != expected_hash:
                        errors.append(f"{capability_id}: verified Evidence 输入已过期：{input_name}")
                    continue
                if input_name not in current_inputs:
                    errors.append(f"{capability_id}: 未知 freshness input：{input_name}")
                    continue
                expected_hash = current_inputs[input_name]
                if evidence_inputs.get(input_name) != expected_hash:
                    errors.append(f"{capability_id}: verified Evidence 输入已过期：{input_name}")
        return errors

    @staticmethod
    def detect_dependency_cycles(items: Dict[str, Dict[str, Any]]) -> List[str]:
        errors: List[str] = []
        visiting: Set[str] = set()
        visited: Set[str] = set()

        def visit(item_id: str, stack: List[str]) -> None:
            if item_id in visiting:
                errors.append(f"工作项依赖成环：{' -> '.join(stack + [item_id])}")
                return
            if item_id in visited or item_id not in items:
                return
            visiting.add(item_id)
            for dependency in items[item_id]["spec"].get("depends_on", []):
                visit(dependency, stack + [item_id])
            visiting.remove(item_id)
            visited.add(item_id)

        for item_id in items:
            visit(item_id, [])
        return errors

    def render_status(self, state: Dict[str, Any], items: Dict[str, Dict[str, Any]]) -> str:
        next_item = self.select_next(state, items)
        health = state.get("health", {})
        lines = [
            "# iOS 项目当前状态",
            "",
            "> 此文件由 `ios/harness/harness.py` 从 `state.json` 生成，请勿手工编辑。",
            "",
            f"- 更新时间：{state.get('updated_at')}",
            f"- 当前阶段：`{state.get('phase')}`",
            f"- 架构版本：`{state.get('architecture_version')}`",
            f"- 架构摘要：`{state.get('architecture_digest')}`",
            f"- 活跃工作项：{', '.join(state.get('active_work_items', [])) or '无'}",
            f"- 下一个可领取工作项：{next_item or '无'}",
            f"- 最近完成：{state.get('last_completed_work_item') or '无'}",
            "",
            "## 健康度",
            "",
            "| 维度 | 状态 |",
            "|---|---|",
        ]
        for key in sorted(health):
            lines.append(f"| {key} | `{health[key]}` |")
        lines.extend(["", "## 工作队列", "", "| ID | 优先级 | 状态 | 依赖 | 标题 |", "|---|---:|---|---|---|"])
        ordered = sorted(items.items(), key=lambda pair: (-pair[1]["metadata"]["priority"], pair[0]))
        for item_id, item in ordered:
            item_state = state.get("work_items", {}).get(item_id, {})
            dependencies = ", ".join(item["spec"].get("depends_on", [])) or "无"
            lines.append(
                f"| {item_id} | {item['metadata']['priority']} | `{item_state.get('status', 'missing')}` | {dependencies} | {item['metadata']['title']} |"
            )
        risks = state.get("risks", [])
        lines.extend(["", "## 风险", ""])
        if risks:
            for risk in risks:
                lines.append(f"- `{risk.get('id')}`：{risk.get('summary')}")
        else:
            lines.append("- 无已登记风险。")
        lines.extend(["", "## 常用命令", "", "```bash", "python3 ios/harness/harness.py doctor", "python3 ios/harness/harness.py next", "python3 ios/harness/harness.py context <WORK_ITEM_ID>", "```", ""])
        return "\n".join(lines)

    def doctor(self) -> Tuple[List[str], List[str]]:
        errors: List[str] = []
        warnings: List[str] = []
        try:
            items = self.work_items()
            state = self.state()
        except HarnessError as error:
            return [str(error)], warnings
        if not items:
            errors.append("没有工作项")
        for item_id, item in items.items():
            errors.extend(self.validate_work_item(item, item_id))
        errors.extend(self.validate_references(items))
        errors.extend(self.memory_issues(items, state))
        if state.get("schema_version") != 1:
            errors.append("state.schema_version 必须为 1")
        state_items = state.get("work_items")
        if not isinstance(state_items, dict):
            errors.append("state.work_items 必须是 object")
            state_items = {}
        missing_state = sorted(set(items) - set(state_items))
        extra_state = sorted(set(state_items) - set(items))
        if missing_state:
            errors.append(f"state 缺少工作项：{', '.join(missing_state)}")
        if extra_state:
            errors.append(f"state 存在未知工作项：{', '.join(extra_state)}")
        for item_id, item_state in state_items.items():
            status = item_state.get("status") if isinstance(item_state, dict) else None
            if status not in ALL_STATUSES:
                errors.append(f"{item_id}: 状态无效：{status}")
        active_expected = sorted(item_id for item_id, value in state_items.items() if isinstance(value, dict) and value.get("status") in ACTIVE_STATUSES)
        active_actual = sorted(state.get("active_work_items", []))
        if active_expected != active_actual:
            errors.append(f"active_work_items 与状态不一致：expected={active_expected}, actual={active_actual}")
        if len(active_actual) > self.config.get("max_parallel_work_items", 1):
            errors.append("活跃工作项超过 max_parallel_work_items")
        now = dt.datetime.now(dt.timezone.utc)
        for item_id in active_actual:
            expires_at = state_items.get(item_id, {}).get("lease_expires_at")
            if not isinstance(expires_at, str):
                errors.append(f"{item_id}: 活跃工作项缺少 lease_expires_at")
                continue
            try:
                expires = dt.datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
                if expires.tzinfo is None or expires <= now:
                    errors.append(f"{item_id}: lease 已过期；由 supervisor 运行 expire-leases")
            except ValueError:
                errors.append(f"{item_id}: lease_expires_at 无效")
        errors.extend(self.validate_events())
        try:
            events = self.event_lines()
            event_head = events[-1].get("event_hash") if events else None
            if state.get("event_head") != event_head:
                errors.append("state.event_head 与事件哈希链头不一致")
        except HarnessError:
            pass
        architecture_errors, architecture_warnings = self.architecture_issues()
        errors.extend(architecture_errors)
        warnings.extend(architecture_warnings)
        baseline = load_json(self.resolve(self.config["baseline_path"]))
        try:
            architecture_manifest = self.architecture_manifest()
            architecture_digest = sha256_json(architecture_manifest)
            accepted_ids = sorted(architecture_manifest["accepted_adrs"])
            if sorted(baseline.get("accepted_by", [])) != accepted_ids:
                errors.append(
                    "baseline.accepted_by 与当前 accepted ADR 集不一致："
                    f"expected={accepted_ids}, actual={sorted(baseline.get('accepted_by', []))}"
                )
            if baseline.get("architecture", {}).get("digest") != architecture_digest:
                errors.append("baseline 架构摘要已过期；架构变更必须更新 baseline/ADR")
            if state.get("architecture_digest") != architecture_digest:
                errors.append("state.architecture_digest 已过期")
        except HarnessError as error:
            errors.append(str(error))
        golden = load_json(self.resolve(self.config["golden_manifest_path"]))
        if golden.get("oracle", {}).get("android_git_commit") != baseline.get("android_oracle", {}).get("git_commit"):
            errors.append("golden manifest 的 Android commit 与 baseline 不一致")
        fixture_manifest, fixture_errors = self.fixture_manifest_value()
        errors.extend(fixture_errors)
        try:
            actual_fixture_manifest = load_json(self.resolve(self.config["fixture_manifest_path"]))
            if actual_fixture_manifest != fixture_manifest:
                errors.append("fixture manifest 不是当前 fixture 树的确定性生成结果")
        except HarnessError as error:
            errors.append(str(error))
        if isinstance(self.config.get("source_lab_manifest_path"), str):
            try:
                expected_source_lab = self.source_lab_manifest_value()
                actual_source_lab = load_json(self.resolve(self.config["source_lab_manifest_path"]))
                if actual_source_lab != expected_source_lab:
                    errors.append("SourceLab manifest 不是当前 contract/scenario 的确定性生成结果")
                result = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        str(self.resolve("ios/harness/source-lab/source_lab.py")),
                        "doctor",
                        "--root",
                        str(self.root),
                    ],
                    cwd=str(self.root),
                    capture_output=True,
                    text=True,
                    timeout=30,
                    check=False,
                )
                if result.returncode != 0:
                    errors.append("SourceLab contract 无效：" + (result.stderr or result.stdout)[-2000:].strip())
            except (HarnessError, subprocess.TimeoutExpired) as error:
                errors.append(f"SourceLab contract 无法验证：{error}")
        if isinstance(self.config.get("android_intake_script_path"), str):
            try:
                bundle = self.android_intake_bundle_value()
                assert bundle is not None
                inventory_path = self.config.get("android_intake_manifest_path")
                catalog_path = self.config.get("requirement_catalog_path")
                if not isinstance(inventory_path, str) or not isinstance(catalog_path, str):
                    errors.append("Android intake 缺少 inventory/catalog path 配置")
                else:
                    if load_json(self.resolve(inventory_path)) != bundle["inventory"]:
                        errors.append("Android fact inventory 不是固定 baseline 的确定性生成结果")
                    if load_json(self.resolve(catalog_path)) != bundle["catalog"]:
                        errors.append("Requirement catalog 不是 accepted Requirement 的确定性生成结果")
                requirement_schema = load_json(self.resolve("ios/harness/schemas/android-requirement.schema.json"))
                accepted_root = self.resolve("ios/project/requirements/accepted")
                for path in sorted(accepted_root.glob("REQ-*.json")):
                    requirement = load_json(path)
                    errors.extend(
                        f"{path.stem}: {issue}" for issue in validate_json_schema(requirement, requirement_schema)
                    )
                catalog_index = {
                    entry.get("id"): entry
                    for entry in bundle["catalog"].get("requirements", [])
                    if isinstance(entry, dict) and isinstance(entry.get("id"), str)
                }
                for path in sorted(self.resolve(self.config["capabilities_dir"]).glob("CAP-*.json")):
                    capability = load_json(path)
                    for reference in capability.get("requirement_refs", []):
                        if not isinstance(reference, dict):
                            continue
                        requirement_id = reference.get("id")
                        entry = catalog_index.get(requirement_id)
                        if entry is None:
                            errors.append(f"{path.stem}: 引用未发布 Requirement：{requirement_id}")
                            continue
                        if reference.get("revision") != entry.get("revision"):
                            errors.append(f"{path.stem}: Requirement revision 已过期：{requirement_id}")
                        unknown_clauses = sorted(set(reference.get("clauses", [])) - set(entry.get("clauses", [])))
                        if unknown_clauses:
                            errors.append(
                                f"{path.stem}: 引用未知 Requirement clause：{requirement_id}#{','.join(unknown_clauses)}"
                            )
                result = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        str(self.resolve(self.config["android_intake_script_path"])),
                        "doctor",
                        "--root",
                        str(self.root),
                    ],
                    cwd=str(self.root),
                    capture_output=True,
                    text=True,
                    timeout=60,
                    check=False,
                )
                if result.returncode != 0:
                    errors.append("Android Requirement Intake 无效：" + (result.stderr or result.stdout)[-3000:].strip())
            except (HarnessError, subprocess.TimeoutExpired) as error:
                errors.append(f"Android Requirement Intake 无法验证：{error}")
        expected_status = self.render_status(state, items)
        if not self.status_path.exists():
            errors.append("缺少由 Harness 生成的 project/status.md")
        elif self.status_path.read_text(encoding="utf-8") != expected_status:
            errors.append("project/status.md 已过期；运行 status --write")
        return errors, warnings

    @staticmethod
    def select_next(state: Dict[str, Any], items: Dict[str, Dict[str, Any]]) -> Optional[str]:
        if state.get("active_work_items"):
            return None
        state_items = state.get("work_items", {})
        eligible: List[Tuple[int, str]] = []
        for item_id, item in items.items():
            if state_items.get(item_id, {}).get("status") != "ready":
                continue
            dependencies = item["spec"].get("depends_on", [])
            if all(state_items.get(dependency, {}).get("status") == "completed" for dependency in dependencies):
                eligible.append((item["metadata"]["priority"], item_id))
        if not eligible:
            return None
        eligible.sort(key=lambda pair: (-pair[0], pair[1]))
        return eligible[0][1]

    def run_git(self, args: Sequence[str], *, check: bool = True, text: bool = False) -> subprocess.CompletedProcess:
        command = ["git"] + list(args)
        result = subprocess.run(command, cwd=str(self.root), capture_output=True, text=text, check=False)
        if check and result.returncode != 0:
            stderr = result.stderr if text else result.stderr.decode("utf-8", errors="replace")
            raise HarnessError(f"git 命令失败：{' '.join(command)}\n{stderr.strip()}")
        return result

    def git_head(self) -> str:
        return self.run_git(["rev-parse", "HEAD"], text=True).stdout.strip()

    def git_paths(self, args: Sequence[str]) -> Set[str]:
        output = self.run_git(args).stdout
        return {entry.decode("utf-8", errors="surrogateescape") for entry in output.split(b"\0") if entry}

    def dirty_paths(self) -> Set[str]:
        paths = set()
        paths.update(self.git_paths(["diff", "--no-renames", "--name-only", "-z"]))
        paths.update(self.git_paths(["diff", "--cached", "--no-renames", "--name-only", "-z"]))
        paths.update(self.git_paths(["ls-files", "--others", "--exclude-standard", "-z"]))
        return {path.replace(os.sep, "/") for path in paths}

    def index_is_clean(self) -> bool:
        return self.run_git(["diff", "--cached", "--quiet"], check=False).returncode == 0

    def file_fingerprint(self, relative: str) -> str:
        path = self.resolve(relative)
        if not path.exists() and not path.is_symlink():
            return "missing"
        if path.is_symlink():
            mode = oct(path.lstat().st_mode & 0o7777)
            return f"symlink:{mode}:" + sha256_bytes(os.readlink(str(path)).encode("utf-8"))
        if path.is_file():
            mode = oct(path.stat().st_mode & 0o7777)
            return f"file:{mode}:" + sha256_bytes(path.read_bytes())
        return "directory"

    def dirty_fingerprints(self) -> Dict[str, str]:
        return {path: self.file_fingerprint(path) for path in sorted(self.dirty_paths())}

    def changed_since_claim(self, runtime: Dict[str, Any]) -> List[str]:
        base_commit = runtime.get("base_commit")
        committed: Set[str] = set()
        if base_commit:
            committed = self.git_paths(["diff", "--no-renames", "--name-only", "-z", f"{base_commit}..HEAD"])
        before = runtime.get("base_dirty_fingerprints", {})
        current_paths = self.dirty_paths()
        working: Set[str] = set()
        for path in set(before) | current_paths:
            if self.file_fingerprint(path) != before.get(path, "clean"):
                working.add(path)
        return sorted({path.replace(os.sep, "/") for path in committed | working})

    def changed_line_count(self, base_commit: str, changed_paths: Sequence[str]) -> int:
        if not changed_paths:
            return 0
        result = self.run_git(["diff", "--numstat", base_commit, "--"] + list(changed_paths), check=False, text=True)
        total = 0
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                parts = line.split("\t", 2)
                if len(parts) >= 2:
                    for value in parts[:2]:
                        if value.isdigit():
                            total += int(value)
        tracked = self.git_paths(["ls-files", "-z"])
        for relative in changed_paths:
            if relative in tracked:
                continue
            path = self.resolve(relative)
            if path.is_file():
                try:
                    total += len(path.read_text(encoding="utf-8").splitlines())
                except UnicodeDecodeError:
                    total += 1
        return total

    def snapshot_hash(self) -> Tuple[str, Dict[str, str]]:
        dirty = self.dirty_fingerprints()
        payload = {"head": self.git_head(), "dirty": dirty}
        return sha256_json(payload), dirty

    def candidate_snapshot(self, runtime: Dict[str, Any], extra_excludes: Sequence[str] = ()) -> Tuple[str, Dict[str, str]]:
        excludes = list(self.config.get("harness_managed_paths", [])) + list(extra_excludes)
        paths = [path for path in self.changed_since_claim(runtime) if not path_matches(path, excludes)]
        fingerprints = {path: self.file_fingerprint(path) for path in paths}
        payload = {
            "base_commit": runtime.get("base_commit"),
            "head_commit": self.git_head(),
            "files": fingerprints,
        }
        return sha256_json(payload), fingerprints

    def write_state(self, state: Dict[str, Any], items: Dict[str, Dict[str, Any]]) -> None:
        state["revision"] = int(state.get("revision", 0)) + 1
        state["updated_at"] = utc_now()
        events = self.event_lines()
        state["event_head"] = events[-1]["event_hash"] if events else None
        write_json_atomic(self.state_path, state)
        write_text_atomic(self.status_path, self.render_status(state, items))

    def claim(self, item_id: str, agent: str) -> None:
        errors, _ = self.doctor()
        if errors:
            raise HarnessError("doctor 未通过，禁止 claim：\n- " + "\n- ".join(errors))
        items = self.work_items()
        state = self.state()
        selected = self.select_next(state, items)
        if selected is None:
            raise HarnessError("当前没有可领取工作项，或已有活跃工作项")
        if item_id != selected:
            raise HarnessError(f"只能领取 Harness 选择的下一个工作项：{selected}")
        if not agent.strip():
            raise HarnessError("agent 标识不能为空")
        if not self.index_is_clean():
            raise HarnessError("claim 要求 Git index 为空；请先提交或取消 staged 变更")
        item = items[item_id]
        capability = self.capability(item["spec"]["capability"])
        base_dirty = self.dirty_fingerprints()
        memory_paths = [
            f"ios/project/capabilities/{item['spec']['capability']}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/compatibility/COMP-*.json",
            "ios/project/pitfalls/PIT-*.json",
        ] + list(self.config.get("harness_managed_paths", []))
        overlapping_dirty = sorted(
            path
            for path in base_dirty
            if path_matches(path, item["spec"]["scope"]["allow_write"]) and not path_matches(path, memory_paths)
        )
        if overlapping_dirty:
            raise HarnessError(
                "工作项写范围包含 claim 前已有用户脏文件；请先提交、转移或使用独立 worktree：\n- "
                + "\n- ".join(overlapping_dirty)
            )
        baseline_before, _ = self.snapshot_hash()
        baseline_results: List[Dict[str, Any]] = []
        for check_id in item["spec"].get("baseline_checks", []):
            result = self.run_check(check_id, item_id)
            baseline_results.append(result)
            if not result["passed"]:
                entry = state["work_items"][item_id]
                entry["status"] = "blocked"
                entry["blocker"] = "baseline_red"
                entry["baseline_checks"] = baseline_results
                self.append_event("WorkItemBaselineRed", item_id, {"check_id": check_id})
                self.write_state(state, items)
                raise HarnessError(f"BASELINE_RED: {check_id} 在实现前已失败")
        baseline_after, _ = self.snapshot_hash()
        if baseline_before != baseline_after:
            raise HarnessError("BASELINE_RED: baseline check 修改了仓库候选内容")
        claimed_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        lease_expires_at = claimed_at + dt.timedelta(seconds=int(self.config.get("lease_seconds", 86400)))
        entry = state["work_items"][item_id]
        entry.update(
            {
                "status": "implementing",
                "attempt": int(entry.get("attempt", 0)) + 1,
                "claimed_by": agent,
                "claimed_at": claimed_at.isoformat().replace("+00:00", "Z"),
                "lease_expires_at": lease_expires_at.isoformat().replace("+00:00", "Z"),
                "work_item_sha256": sha256_json(item),
                "harness_config_sha256": sha256_json(self.config),
                "base_commit": self.git_head(),
                "base_dirty_fingerprints": base_dirty,
                "base_capability_revision": capability["revision"],
                "base_capability_assurance_sha256": sha256_json(self.capability_assurance(capability)),
                "android_requirement_selection_sha256": self.android_requirement_selection_digest(item),
                "verify_cycles": 0,
                "last_failure_fingerprint": None,
                "last_evidence": None,
                "baseline_checks": baseline_results,
            }
        )
        state["active_work_items"] = [item_id]
        self.append_event(
            "WorkItemClaimed",
            item_id,
            {"agent": agent, "attempt": entry["attempt"], "base_commit": entry["base_commit"], "work_item_sha256": entry["work_item_sha256"]},
        )
        self.write_state(state, items)

    def scope_issues(self, item: Dict[str, Any], runtime: Dict[str, Any], changed: Sequence[str]) -> Tuple[List[str], List[str], int]:
        errors: List[str] = []
        managed = self.config.get("harness_managed_paths", [])
        product_changes = [path for path in changed if not path_matches(path, managed)]
        scope = item["spec"]["scope"]
        allow = scope["allow_write"]
        deny = scope["deny_write"]
        protected = self.config.get("protected_paths", [])
        for path in product_changes:
            if path_matches(path, protected):
                errors.append(f"PROTECTED_PATH_MUTATION: {path}")
            elif path_matches(path, deny):
                errors.append(f"SCOPE_VIOLATION deny_write: {path}")
            elif not path_matches(path, allow):
                errors.append(f"SCOPE_VIOLATION allow_write: {path}")
        if len(product_changes) > scope["max_files_changed"]:
            errors.append(f"BUDGET_EXCEEDED files: {len(product_changes)} > {scope['max_files_changed']}")
        lines = self.changed_line_count(runtime["base_commit"], product_changes)
        if lines > scope["max_changed_lines"]:
            errors.append(f"BUDGET_EXCEEDED lines: {lines} > {scope['max_changed_lines']}")
        if not product_changes:
            errors.append("没有检测到工作项范围内的实现或记忆变化")
        return errors, product_changes, lines

    def command_environment(self, item_id: str) -> Dict[str, str]:
        allowed = ("PATH", "DEVELOPER_DIR", "SDKROOT", "TMPDIR", "HOME", "USER", "LOGNAME", "LANG")
        environment = {key: os.environ[key] for key in allowed if key in os.environ}
        environment.update(
            {
                "LEGADO_WORK_ITEM_ID": item_id,
                "PYTHONDONTWRITEBYTECODE": "1",
                "TZ": "UTC",
                "LC_ALL": "C",
            }
        )
        return environment

    @staticmethod
    def process_group_exists(process_group_id: int) -> bool:
        try:
            os.killpg(process_group_id, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    @classmethod
    def terminate_process_group(cls, process_group_id: int, grace_seconds: float = 0.75) -> None:
        try:
            os.killpg(process_group_id, signal.SIGTERM)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            if not cls.process_group_exists(process_group_id):
                return
            time.sleep(0.025)
        try:
            os.killpg(process_group_id, signal.SIGKILL)
        except ProcessLookupError:
            return

    def run_check(self, check_id: str, item_id: str) -> Dict[str, Any]:
        definition = self.config["checks"][check_id]
        argv = [str(part).replace("{work_item_id}", item_id) for part in definition["argv"]]
        if not argv or any(not part for part in argv):
            raise HarnessError(f"check {check_id} argv 无效")
        cwd = self.resolve(definition.get("cwd", "."))
        timeout = int(definition.get("timeout_seconds", 300))
        started = time.monotonic()
        started_at = utc_now()
        executable_path = shutil.which(argv[0], path=self.command_environment(item_id).get("PATH"))
        process_leak = False
        try:
            process = subprocess.Popen(
                argv,
                cwd=str(cwd),
                env=self.command_environment(item_id),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(timeout=timeout)
                exit_code: Optional[int] = process.returncode
                timed_out = False
            except subprocess.TimeoutExpired:
                self.terminate_process_group(process.pid, grace_seconds=0.1)
                stdout, stderr = process.communicate()
                exit_code = None
                timed_out = True
            if self.process_group_exists(process.pid):
                process_leak = not timed_out
                self.terminate_process_group(process.pid)
                if process_leak:
                    stderr += b"\nPROCESS_LEAK: check exited while child processes were still alive\n"
        except FileNotFoundError as error:
            exit_code = None
            stdout = b""
            stderr = str(error).encode("utf-8")
            timed_out = False
            process_leak = False
        duration_ms = int((time.monotonic() - started) * 1000)
        output_limit = int(self.config.get("evidence_output_tail_bytes", 6000))
        return {
            "id": check_id,
            "argv": argv,
            "executable_path": executable_path,
            "definition_sha256": sha256_json(definition),
            "cwd": self.relative(cwd),
            "started_at": started_at,
            "duration_ms": duration_ms,
            "timeout_seconds": timeout,
            "timed_out": timed_out,
            "process_leak": process_leak,
            "exit_code": exit_code,
            "passed": exit_code == 0 and not timed_out and not process_leak,
            "stdout_sha256": sha256_bytes(stdout),
            "stderr_sha256": sha256_bytes(stderr),
            "stdout_tail": self.redact_output(stdout[-output_limit:]),
            "stderr_tail": self.redact_output(stderr[-output_limit:]),
        }

    def redact_output(self, value: bytes) -> str:
        text = value.decode("utf-8", errors="replace")
        for rule in self.config.get("redaction_patterns", []):
            try:
                text = re.sub(rule["pattern"], rule.get("replacement", "<redacted>"), text)
            except (KeyError, re.error) as error:
                raise HarnessError(f"redaction pattern 无效：{error}") from error
        return text

    def environment_info(self) -> Dict[str, Any]:
        info: Dict[str, Any] = {
            "platform": platform.platform(),
            "python": platform.python_version(),
        }
        commands = {
            "xcode": ["xcodebuild", "-version"],
            "swift": ["swift", "--version"],
        }
        for key, argv in commands.items():
            try:
                result = subprocess.run(argv, cwd=str(self.root), capture_output=True, text=True, timeout=20, check=False)
                info[key] = (result.stdout or result.stderr).strip()
            except (FileNotFoundError, subprocess.TimeoutExpired) as error:
                info[key] = f"unavailable: {error}"
        return info

    @staticmethod
    def classify_failure(policy_errors: Sequence[str], architecture_errors: Sequence[str], checks: Sequence[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        if policy_errors:
            message = policy_errors[0]
            category = message.split(":", 1)[0] if ":" in message else "POLICY"
            fingerprint = sha256_json({"category": category, "message": message})
            return {"class": category, "message": message, "fingerprint": fingerprint}
        if architecture_errors:
            message = architecture_errors[0]
            return {"class": "ARCHITECTURE", "message": message, "fingerprint": sha256_json({"class": "ARCHITECTURE", "message": message})}
        for check in checks:
            if check["passed"]:
                continue
            if check.get("process_leak"):
                category = "PROCESS_LEAK"
            else:
                category = "INFRASTRUCTURE" if check["exit_code"] is None else "CHECK_FAILED"
            normalized = re.sub(r"\s+", " ", (check["stderr_tail"] or check["stdout_tail"])[-1000:]).strip()
            return {
                "class": category,
                "check_id": check["id"],
                "message": normalized,
                "fingerprint": sha256_json({"class": category, "check_id": check["id"], "message": normalized}),
            }
        return None

    def verify(self, item_id: str) -> Path:
        items = self.work_items()
        if item_id not in items:
            raise HarnessError(f"未知工作项：{item_id}")
        state = self.state()
        runtime = state.get("work_items", {}).get(item_id, {})
        if runtime.get("status") != "implementing":
            raise HarnessError(f"只能验证 implementing 工作项；当前为 {runtime.get('status')}")
        item = items[item_id]
        if runtime.get("work_item_sha256") != sha256_json(item):
            raise HarnessError("工作项在 claim 后被修改；停止并请求人工处理")
        if runtime.get("harness_config_sha256") != sha256_json(self.config):
            raise HarnessError("Harness config 在 claim 后被修改；停止并请求人工处理")
        current_requirement_selection = self.android_requirement_selection_digest(item)
        if runtime.get("android_requirement_selection_sha256") != current_requirement_selection:
            raise HarnessError("REQUIREMENT_DRIFT: Android fact 或 Requirement selection 在 claim 后变化")
        capability = self.capability(item["spec"]["capability"])
        if capability.get("revision") != runtime.get("base_capability_revision"):
            raise HarnessError("verify 前 capability revision 已变化；请先处理并发冲突")
        event_errors = self.validate_events()
        if event_errors:
            raise HarnessError("事件链无效：\n- " + "\n- ".join(event_errors))

        self.refresh_fixture_manifest()
        self.refresh_source_lab_manifest()
        self.refresh_android_intake_manifests()

        started_at = utc_now()
        changed = self.changed_since_claim(runtime)
        policy_errors, product_changes, changed_lines = self.scope_issues(item, runtime, changed)
        try:
            claimed_at = dt.datetime.fromisoformat(runtime["claimed_at"].replace("Z", "+00:00"))
            elapsed = (dt.datetime.now(dt.timezone.utc) - claimed_at).total_seconds()
            if elapsed > item["spec"]["budget"].get("wall_clock_seconds", 2400):
                policy_errors.append(
                    f"BUDGET_EXCEEDED wall_clock_seconds: {int(elapsed)} > {item['spec']['budget'].get('wall_clock_seconds', 2400)}"
                )
        except (KeyError, TypeError, ValueError):
            policy_errors.append("SPEC_INVALID: claimed_at 无效")
        if not self.index_is_clean():
            policy_errors.append("INDEX_DIRTY: verify 不接受 staged 候选；只验证唯一 worktree 内容")
        pre_check_fingerprints = {path: self.file_fingerprint(path) for path in product_changes}
        architecture_errors, architecture_warnings = self.architecture_issues()
        checks: List[Dict[str, Any]] = []
        if not policy_errors and not architecture_errors:
            for check_id in item["spec"]["acceptance"]["required_checks"]:
                check = self.run_check(check_id, item_id)
                checks.append(check)
                if not check["passed"]:
                    break
        post_changed = self.changed_since_claim(runtime)
        post_policy_errors, post_product_changes, post_changed_lines = self.scope_issues(item, runtime, post_changed)
        post_fingerprints = {path: self.file_fingerprint(path) for path in post_product_changes}
        for error in post_policy_errors:
            if error not in policy_errors:
                policy_errors.append(error)
        if product_changes != post_product_changes or pre_check_fingerprints != post_fingerprints:
            policy_errors.append("CHECK_MUTATED_CANDIDATE: 验收命令改变了候选代码或路径")
        if not self.index_is_clean() and not any(error.startswith("INDEX_DIRTY") for error in policy_errors):
            policy_errors.append("INDEX_DIRTY: 验收命令修改了 Git index")
        post_architecture_errors, post_architecture_warnings = self.architecture_issues()
        for error in post_architecture_errors:
            if error not in architecture_errors:
                architecture_errors.append(error)
        for warning in post_architecture_warnings:
            if warning not in architecture_warnings:
                architecture_warnings.append(warning)
        failure = self.classify_failure(policy_errors, architecture_errors, checks)
        passed = failure is None
        snapshot_sha256, dirty_snapshot = self.snapshot_hash()
        run_id = f"run-{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{item_id.lower()}-{uuid.uuid4().hex[:8]}"
        evidence_path = self.resolve(self.config["evidence_dir"]) / f"{run_id}.json"
        product_changes = post_product_changes
        changed_lines = post_changed_lines
        fingerprints = post_fingerprints
        evidence = {
            "schema_version": 1,
            "run_id": run_id,
            "work_item_id": item_id,
            "work_item_sha256": sha256_json(item),
            "result": "passed" if passed else "failed",
            "inputs": {
                "base_commit": runtime["base_commit"],
                "head_commit": self.git_head(),
                "snapshot_sha256": snapshot_sha256,
                **self.verification_input_hashes(),
                "android_requirement_selection_sha256": current_requirement_selection,
                "source_lab_selection_sha256": self.source_lab_selection_digest(item),
                "environment": self.environment_info(),
            },
            "changes": {
                "paths": product_changes,
                "changed_lines_approximate": changed_lines,
                "file_fingerprints": fingerprints,
                "dirty_snapshot": dirty_snapshot,
                "diff_sha256": sha256_json({"paths": product_changes, "fingerprints": fingerprints}),
            },
            "policy_errors": policy_errors,
            "architecture_errors": architecture_errors,
            "architecture_warnings": architecture_warnings,
            "checks": checks,
            "failure": failure,
            "started_at": started_at,
            "finished_at": utc_now(),
            "reproduction": f"python3 ios/harness/harness.py verify {item_id}",
        }
        write_json_atomic(evidence_path, evidence)
        evidence_sha256 = sha256_bytes(evidence_path.read_bytes())

        runtime["verify_cycles"] = int(runtime.get("verify_cycles", 0)) + 1
        runtime["last_evidence"] = self.relative(evidence_path)
        runtime["last_evidence_sha256"] = evidence_sha256
        runtime["verified_product_fingerprints"] = fingerprints if passed else None
        if passed:
            runtime["status"] = "verified"
            runtime["verified_at"] = utc_now()
            runtime["last_failure_fingerprint"] = None
            event_name = "VerificationPassed"
        else:
            fingerprint = failure["fingerprint"] if failure else None
            repeated = fingerprint is not None and fingerprint == runtime.get("last_failure_fingerprint")
            exhausted = runtime["verify_cycles"] >= item["spec"]["budget"].get("max_edit_verify_cycles", 3)
            runtime["last_failure_fingerprint"] = fingerprint
            hard_reject = any(
                error.startswith(("SCOPE_VIOLATION", "PROTECTED_PATH_MUTATION", "INDEX_DIRTY", "CHECK_MUTATED_CANDIDATE"))
                for error in policy_errors
            )
            hard_exhaust = any(error.startswith("BUDGET_EXCEEDED") for error in policy_errors)
            if hard_reject:
                runtime["status"] = "rejected"
                runtime["rejected_reason"] = failure
                state["active_work_items"] = []
                event_name = "WorkItemRejected"
            elif repeated or exhausted or hard_exhaust:
                runtime["status"] = "exhausted"
                runtime["exhausted_reason"] = "same_failure_twice" if repeated else "budget_exhausted"
                state["active_work_items"] = []
                event_name = "WorkItemExhausted"
            else:
                event_name = "VerificationFailed"
        self.append_event(event_name, item_id, {"run_id": run_id, "result": evidence["result"], "failure": failure})
        self.write_state(state, items)
        return evidence_path

    def expire_leases(self) -> List[str]:
        items = self.work_items()
        state = self.state()
        now = dt.datetime.now(dt.timezone.utc)
        expired: List[str] = []
        for item_id in list(state.get("active_work_items", [])):
            runtime = state["work_items"][item_id]
            try:
                expires = dt.datetime.fromisoformat(str(runtime.get("lease_expires_at")).replace("Z", "+00:00"))
            except ValueError:
                expires = now
            if expires.tzinfo is None or expires <= now:
                runtime["status"] = "blocked"
                runtime["blocker"] = "lease_expired"
                expired.append(item_id)
                self.append_event("WorkItemLeaseExpired", item_id, {"lease_expires_at": runtime.get("lease_expires_at")})
        if expired:
            state["active_work_items"] = [item for item in state.get("active_work_items", []) if item not in expired]
            self.write_state(state, items)
        return expired

    def optional_file_hash(self, relative: str) -> Optional[str]:
        path = self.resolve(relative)
        return sha256_bytes(path.read_bytes()) if path.exists() and path.is_file() else None

    def validate_checkpoint(self, item_id: str, item: Dict[str, Any], runtime: Dict[str, Any]) -> Tuple[Dict[str, Any], List[str]]:
        errors: List[str] = []
        checkpoint_path = self.resolve(self.config["checkpoints_dir"]) / f"{item_id}.json"
        try:
            checkpoint = load_json(checkpoint_path)
        except HarnessError as error:
            return {}, [str(error)]
        if not isinstance(checkpoint, dict):
            return {}, ["checkpoint 必须是 object"]
        required = [
            "schema_version",
            "work_item_id",
            "summary",
            "evidence",
            "capability_updates",
            "architecture_impact",
            "requirements",
            "source_lab",
            "compatibility",
            "pitfalls",
            "remaining_risks",
            "next_actions",
            "created_at",
        ]
        for key in required:
            if key not in checkpoint:
                errors.append(f"checkpoint 缺少字段：{key}")
        if checkpoint.get("schema_version") != 1 or checkpoint.get("work_item_id") != item_id:
            errors.append("checkpoint schema_version/work_item_id 无效")
        if checkpoint.get("evidence") != runtime.get("last_evidence"):
            errors.append("checkpoint 必须引用当前工作项最新 Evidence")
        if not isinstance(checkpoint.get("summary"), str) or not checkpoint.get("summary", "").strip():
            errors.append("checkpoint summary 不能为空")
        updates = checkpoint.get("capability_updates")
        if not isinstance(updates, list) or not updates:
            errors.append("checkpoint capability_updates 不能为空")
        architecture = checkpoint.get("architecture_impact")
        if not isinstance(architecture, dict) or architecture.get("kind") not in {"none", "implements_existing", "changes_architecture"}:
            errors.append("checkpoint architecture_impact 无效")
        elif architecture.get("kind") == "changes_architecture" and not architecture.get("adr_refs"):
            errors.append("架构变化必须引用 proposed ADR")
        requirements = checkpoint.get("requirements")
        expected_requirements = item.get("spec", {}).get("requirements", {})
        if not isinstance(requirements, dict):
            errors.append("checkpoint requirements 必须是 object")
        else:
            for key in ("mode", "refs"):
                if requirements.get(key) != expected_requirements.get(key):
                    errors.append(f"checkpoint requirements.{key} 与工作项契约不一致")
            try:
                requirement_evidence = load_json(self.resolve(runtime.get("last_evidence", "")))
                expected_requirement_selection = requirement_evidence.get("inputs", {}).get(
                    "android_requirement_selection_sha256"
                )
            except HarnessError as error:
                errors.append(str(error))
                expected_requirement_selection = None
            if requirements.get("selection_sha256") != expected_requirement_selection:
                errors.append("checkpoint requirements.selection_sha256 与 Evidence 不一致")
        source_lab = checkpoint.get("source_lab")
        expected_source_lab = item.get("spec", {}).get("source_lab", {})
        if not isinstance(source_lab, dict):
            errors.append("checkpoint source_lab 必须是 object")
        else:
            for key in ("mode", "behaviors", "scenarios"):
                if source_lab.get(key) != expected_source_lab.get(key):
                    errors.append(f"checkpoint source_lab.{key} 与工作项契约不一致")
            try:
                evidence = load_json(self.resolve(runtime.get("last_evidence", "")))
                expected_selection = evidence.get("inputs", {}).get("source_lab_selection_sha256")
            except HarnessError as error:
                errors.append(str(error))
                expected_selection = None
            if source_lab.get("selection_sha256") != expected_selection:
                errors.append("checkpoint source_lab.selection_sha256 与 Evidence 不一致")
        for name in ("compatibility", "pitfalls"):
            section = checkpoint.get(name)
            if not isinstance(section, dict):
                errors.append(f"checkpoint {name} 必须是 object")
                continue
            records = section.get("records")
            none_reason = section.get("none_reason")
            if not isinstance(records, list):
                errors.append(f"checkpoint {name}.records 必须是数组")
            elif not records and (not isinstance(none_reason, str) or not none_reason.strip()):
                errors.append(f"checkpoint {name} 无记录时必须填写 none_reason")
            elif records and none_reason is not None:
                errors.append(f"checkpoint {name} 有记录时 none_reason 必须为 null")
            for record in records or []:
                if not isinstance(record, str) or not self.resolve(record).exists():
                    errors.append(f"checkpoint {name} 引用不存在：{record}")
        next_actions = checkpoint.get("next_actions")
        if not isinstance(next_actions, list) or len(next_actions) > 5:
            errors.append("checkpoint next_actions 必须是最多 5 项的数组")
        return checkpoint, errors

    def required_close_gates(
        self,
        item_id: str,
        item: Dict[str, Any],
        changed_paths: Sequence[str],
    ) -> Tuple[List[str], List[str]]:
        gates = set(item.get("spec", {}).get("gates", []))
        errors: List[str] = []
        for relative in changed_paths:
            if not path_matches(relative, ["ios/project/compatibility/COMP-*.json"]):
                continue
            try:
                record = load_json(self.resolve(relative))
            except HarnessError as error:
                errors.append(str(error))
                continue
            if not isinstance(record, dict):
                continue
            if record.get("classification") != "intentional_difference" and record.get("decision") != "accept_difference":
                continue
            gates.add("oracle-adjudication")
            record_id = record.get("id")
            decision_adr = record.get("decision_adr")
            matching_adr: Optional[Path] = None
            for path in sorted(self.resolve("ios/docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
                text = path.read_text(encoding="utf-8")
                if re.search(rf"^id:\s*{re.escape(str(decision_adr))}\s*$", text, re.MULTILINE):
                    matching_adr = path
                    break
            if matching_adr is None:
                errors.append(f"{record_id}: accept_difference 缺少专用 decision ADR")
            else:
                text = matching_adr.read_text(encoding="utf-8")
                if not re.search(r"^status:\s*accepted\s*$", text, re.MULTILINE) or str(record_id) not in text:
                    errors.append(f"{record_id}: decision ADR 必须 accepted 且正文显式绑定该 COMP ID")
            if record.get("introduced_by") != item_id:
                errors.append(f"{record_id}: 本次 intentional difference 必须由当前工作项引入")
        return sorted(gates), errors

    def approval_issues(
        self,
        item_id: str,
        item: Dict[str, Any],
        tree_sha256: str,
        gates: Sequence[str],
    ) -> List[str]:
        errors: List[str] = []
        work_item_hash = sha256_json(item)
        for gate in gates:
            path = self.resolve(self.config["approvals_dir"]) / f"{item_id}--{gate}.json"
            try:
                approval = load_json(path)
            except HarnessError:
                errors.append(f"缺少人工批准：{gate}")
                continue
            if approval.get("work_item_id") != item_id or approval.get("gate") != gate:
                errors.append(f"approval 与工作项/gate 不匹配：{gate}")
            if approval.get("work_item_sha256") != work_item_hash or approval.get("tree_sha256") != tree_sha256:
                errors.append(f"approval 未绑定当前 spec/tree：{gate}")
            reviewer = approval.get("reviewer")
            if not isinstance(reviewer, str) or not reviewer.strip() or reviewer.lower().startswith("ai"):
                errors.append(f"approval reviewer 无效：{gate}")
            try:
                expires = dt.datetime.fromisoformat(str(approval.get("expires_at")).replace("Z", "+00:00"))
                if expires.tzinfo is None:
                    errors.append(f"approval expires_at 必须含时区：{gate}")
                elif expires <= dt.datetime.now(dt.timezone.utc):
                    errors.append(f"approval 已过期：{gate}")
            except (TypeError, ValueError):
                errors.append(f"approval expires_at 无效：{gate}")
        return errors

    def close(self, item_id: str) -> str:
        items = self.work_items()
        if item_id not in items:
            raise HarnessError(f"未知工作项：{item_id}")
        state = self.state()
        runtime = state["work_items"][item_id]
        if runtime.get("status") not in {"verified", "awaiting_human"}:
            raise HarnessError(f"只能关闭 verified/awaiting_human 工作项；当前为 {runtime.get('status')}")
        item = items[item_id]
        if runtime.get("work_item_sha256") != sha256_json(item):
            raise HarnessError("工作项 spec 在 claim 后变化")
        evidence = load_json(self.resolve(runtime["last_evidence"]))
        if evidence.get("result") != "passed":
            raise HarnessError("最新 Evidence 不是 passed")
        evidence_path = self.resolve(runtime["last_evidence"])
        if sha256_bytes(evidence_path.read_bytes()) != runtime.get("last_evidence_sha256"):
            raise HarnessError("最新 Evidence 在生成后被修改")
        checkpoint, checkpoint_errors = self.validate_checkpoint(item_id, item, runtime)

        capability = self.capability(item["spec"]["capability"])
        memory_errors: List[str] = []
        if sha256_json(self.capability_assurance(capability)) != runtime.get("base_capability_assurance_sha256"):
            memory_errors.append("能力 assurance contract 在 claim 后被削弱或改变；必须拆分架构门禁并重新验证")
        if capability.get("revision", 0) <= runtime.get("base_capability_revision", 0):
            memory_errors.append("能力 revision 未相对 claim 基线递增")
        if capability.get("updated_by") != item_id:
            memory_errors.append("能力 updated_by 必须是当前工作项")
        if capability.get("latest_evidence") != runtime.get("last_evidence"):
            memory_errors.append("能力 latest_evidence 必须引用最新 Evidence")
        if capability.get("declared_status") not in {"partial", "verified"}:
            memory_errors.append("完成工作项时能力 declared_status 必须为 partial 或 verified")
        updates = checkpoint.get("capability_updates") if isinstance(checkpoint, dict) else None
        matching_update = None
        if isinstance(updates, list):
            matching_update = next(
                (update for update in updates if isinstance(update, dict) and update.get("id") == item["spec"]["capability"]),
                None,
            )
        if matching_update is None:
            memory_errors.append("checkpoint 缺少当前 capability 的 revision 更新")
        else:
            if matching_update.get("from_revision") != runtime.get("base_capability_revision"):
                memory_errors.append("checkpoint capability from_revision 与 claim 基线不一致")
            if matching_update.get("to_revision") != capability.get("revision"):
                memory_errors.append("checkpoint capability to_revision 与当前能力不一致")

        current_changed = self.changed_since_claim(runtime)
        required_gates, dynamic_gate_errors = self.required_close_gates(item_id, item, current_changed)
        managed = self.config.get("harness_managed_paths", [])
        memory_patterns = [
            f"ios/project/capabilities/{item['spec']['capability']}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/compatibility/COMP-*.json",
            "ios/project/pitfalls/PIT-*.json",
        ]
        scope = item["spec"]["scope"]
        protected = self.config.get("protected_paths", [])
        approval_paths = [f"ios/project/approvals/{item_id}--{gate}.json" for gate in required_gates]
        verified_fingerprints = runtime.get("verified_product_fingerprints") or {}
        close_scope_errors: List[str] = []
        for path, fingerprint in verified_fingerprints.items():
            if self.file_fingerprint(path) != fingerprint and not path_matches(path, memory_patterns):
                close_scope_errors.append(f"验证后产品文件发生变化，必须重新 verify：{path}")
        for path in current_changed:
            if path_matches(path, managed) or path in verified_fingerprints or path in approval_paths:
                continue
            if not path_matches(path, memory_patterns):
                close_scope_errors.append(f"verify 后出现非记忆文件变化：{path}")
            elif path_matches(path, protected):
                close_scope_errors.append(f"verify 后修改了受保护记忆模板/策略：{path}")
            elif path_matches(path, scope.get("deny_write", [])):
                close_scope_errors.append(f"verify 后记忆文件命中 deny_write：{path}")
            elif not path_matches(path, scope.get("allow_write", [])):
                close_scope_errors.append(f"verify 后记忆文件不在 allow_write：{path}")

        all_errors = checkpoint_errors + memory_errors + close_scope_errors + dynamic_gate_errors
        all_errors.extend(self.memory_issues(items, state))
        if all_errors:
            raise HarnessError("close 前记忆事务无效：\n- " + "\n- ".join(all_errors))

        review_subject_sha256, review_subject_files = self.candidate_snapshot(runtime, approval_paths)
        frozen_subject = runtime.get("review_subject_sha256")
        if frozen_subject is not None and frozen_subject != review_subject_sha256:
            raise HarnessError("候选内容在请求人工批准后发生变化；旧批准主题已失效，必须重新 verify")
        approval_errors = self.approval_issues(item_id, item, review_subject_sha256, required_gates)
        architecture_kind = checkpoint.get("architecture_impact", {}).get("kind")
        if architecture_kind == "changes_architecture" and not item["spec"].get("gates"):
            approval_errors.append("架构变化工作项必须声明人工 gate")
        if approval_errors:
            runtime["status"] = "awaiting_human"
            runtime["awaiting_human_reasons"] = approval_errors
            runtime["review_subject_sha256"] = review_subject_sha256
            runtime["review_subject_files"] = review_subject_files
            self.append_event("HumanApprovalRequired", item_id, {"reasons": approval_errors, "review_subject_sha256": review_subject_sha256})
            self.write_state(state, items)
            return "awaiting_human"

        final_tree_sha256, _ = self.snapshot_hash()
        runtime["status"] = "completed"
        runtime["completed_at"] = utc_now()
        runtime["final_tree_sha256"] = final_tree_sha256
        runtime.pop("base_dirty_fingerprints", None)
        runtime.pop("verified_product_fingerprints", None)
        state["active_work_items"] = [entry for entry in state.get("active_work_items", []) if entry != item_id]
        state["last_completed_work_item"] = item_id
        completion_effects = item["spec"].get("completion_effects", {})
        if isinstance(completion_effects.get("health"), dict):
            state.setdefault("health", {}).update(completion_effects["health"])
        if isinstance(completion_effects.get("phase"), str):
            state["phase"] = completion_effects["phase"]
        self.append_event(
            "WorkItemCompleted",
            item_id,
            {"evidence": runtime["last_evidence"], "checkpoint": f"ios/project/checkpoints/{item_id}.json", "review_subject_sha256": review_subject_sha256, "final_tree_sha256": final_tree_sha256},
        )
        self.write_state(state, items)
        return "completed"

    def context_packet(self, item_id: str) -> Dict[str, Any]:
        items = self.work_items()
        if item_id not in items:
            raise HarnessError(f"未知工作项：{item_id}")
        item = items[item_id]
        state = self.state()
        capability = self.capability(item["spec"]["capability"])
        adr_paths: Dict[str, str] = {}
        for path in sorted(self.resolve("ios/docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
            match = re.search(r"^id:\s*(ADR-[0-9]{4})\s*$", path.read_text(encoding="utf-8"), re.MULTILINE)
            if match:
                adr_paths[match.group(1)] = self.relative(path)
        referenced_adrs = set(capability.get("active_decisions", []))
        referenced_adrs.update(ref for ref in item["spec"].get("architecture_refs", []) if ref.startswith("ADR-"))
        active_adrs = [
            {"id": adr_id, "path": adr_paths.get(adr_id)} for adr_id in sorted(referenced_adrs)
        ]

        compatibility = []
        for record_id in capability.get("open_compatibility", []):
            path = self.resolve(f"ios/project/compatibility/{record_id}.json")
            compatibility.append({"path": self.relative(path), "record": load_json(path) if path.exists() else None})
        pitfalls = []
        for record_id in capability.get("open_pitfalls", []):
            path = self.resolve(f"ios/project/pitfalls/{record_id}.json")
            pitfalls.append({"path": self.relative(path), "record": load_json(path) if path.exists() else None})

        latest_evidence = None
        latest_path = capability.get("latest_evidence")
        if isinstance(latest_path, str) and self.resolve(latest_path).exists():
            evidence = load_json(self.resolve(latest_path))
            latest_evidence = {
                "path": latest_path,
                "run_id": evidence.get("run_id"),
                "result": evidence.get("result"),
                "failure": evidence.get("failure"),
                "checks": [
                    {"id": check.get("id"), "passed": check.get("passed")} for check in evidence.get("checks", [])
                ],
            }

        dependency_checkpoints = []
        for dependency in item["spec"].get("depends_on", []):
            path = self.resolve(self.config["checkpoints_dir"]) / f"{dependency}.json"
            if path.exists():
                dependency_checkpoints.append({"path": self.relative(path), "checkpoint": load_json(path)})

        baseline = load_json(self.resolve(self.config["baseline_path"]))
        baseline_commit = baseline.get("android_oracle", {}).get("git_commit")
        android_anchors = [
            {
                "path": path,
                "baseline_commit": baseline_commit,
                "read_command": f"git show {baseline_commit}:{path}",
            }
            for path in item["spec"].get("inputs", {}).get("android_source_anchors", [])
        ]
        requirements_spec = item.get("spec", {}).get("requirements", {})
        requirements_context = None
        if isinstance(requirements_spec, dict) and requirements_spec.get("mode") != "control_plane":
            catalog_path = self.config.get("requirement_catalog_path")
            inventory_path = self.config.get("android_intake_manifest_path")
            if isinstance(catalog_path, str) and isinstance(inventory_path, str):
                catalog = load_json(self.resolve(catalog_path))
                inventory = load_json(self.resolve(inventory_path))
                catalog_entries = {
                    entry.get("id"): entry
                    for entry in catalog.get("requirements", [])
                    if isinstance(entry, dict) and isinstance(entry.get("id"), str)
                }
                fact_entries = {
                    entry.get("id"): entry
                    for entry in inventory.get("facts", [])
                    if isinstance(entry, dict) and isinstance(entry.get("id"), str)
                }
                selected_requirements = []
                selected_fact_ids: Set[str] = set()
                for reference in requirements_spec.get("refs", []):
                    requirement_id = reference.get("id") if isinstance(reference, dict) else None
                    entry = catalog_entries.get(requirement_id)
                    if not isinstance(entry, dict):
                        continue
                    record_path = entry.get("path")
                    record = load_json(self.resolve(record_path)) if isinstance(record_path, str) else None
                    if isinstance(record, dict):
                        selected_fact_ids.update(record.get("origin", {}).get("fact_refs", []))
                    selected_requirements.append(
                        {"ref": reference, "catalog_entry": entry, "record": record}
                    )
                requirements_context = {
                    "spec": requirements_spec,
                    "selection_sha256": self.android_requirement_selection_digest(item),
                    "inventory_sha256": catalog.get("inventory_sha256"),
                    "requirements": selected_requirements,
                    "facts": [fact_entries[fact_id] for fact_id in sorted(selected_fact_ids) if fact_id in fact_entries],
                }
        read_order = [
            "ios/project/baseline.json",
            "ios/docs/architecture.md",
            "ios/docs/android-requirement-intake.md",
            "ios/docs/trusted-supervisor.md",
            capability["contract"],
        ]
        if requirements_context:
            read_order.extend(
                entry["catalog_entry"]["path"]
                for entry in requirements_context["requirements"]
                if isinstance(entry.get("catalog_entry", {}).get("path"), str)
            )
        read_order.extend(entry["path"] for entry in active_adrs if entry.get("path"))
        read_order.extend(item["spec"].get("inputs", {}).get("context_files", []))
        read_order.extend(entry["path"] for entry in compatibility)
        read_order.extend(entry["path"] for entry in pitfalls)
        read_order.extend(entry["path"] for entry in dependency_checkpoints)
        source_lab_spec = item.get("spec", {}).get("source_lab", {})
        source_lab_context = None
        if isinstance(source_lab_spec, dict) and source_lab_spec.get("mode") != "not_applicable":
            source_lab_context = {
                "spec": source_lab_spec,
                "selection_sha256": self.source_lab_selection_digest(item),
                "manifest_path": self.config.get("source_lab_manifest_path"),
            }
            read_order.extend(["ios/docs/source-lab.md", str(self.config.get("source_lab_manifest_path"))])
            for scenario_id in source_lab_spec.get("scenarios", []):
                read_order.append(f"ios/harness/fixtures/source-lab/{scenario_id}/case.json")
        if latest_evidence:
            read_order.append(latest_evidence["path"])
        read_order = list(dict.fromkeys(read_order))
        return {
            "schema_version": 1,
            "work_item": item,
            "work_item_sha256": sha256_json(item),
            "runtime_state": state["work_items"][item_id],
            "capability_state": capability,
            "baseline": baseline,
            "active_adrs": active_adrs,
            "open_compatibility": compatibility,
            "open_pitfalls": pitfalls,
            "latest_evidence": latest_evidence,
            "dependency_checkpoints": dependency_checkpoints,
            "android_source_anchors": android_anchors,
            "requirements": requirements_context,
            "source_lab": source_lab_context,
            "required_read_order": read_order,
            "commands": {
                "claim": f"python3 ios/harness/harness.py claim {item_id} --agent <agent-id>",
                "verify": f"python3 ios/harness/harness.py verify {item_id}",
                "close": f"python3 ios/harness/harness.py close {item_id}",
            },
        }


def print_doctor(harness: Harness, as_json: bool) -> int:
    errors, warnings = harness.doctor()
    if as_json:
        print(json.dumps({"ok": not errors, "errors": errors, "warnings": warnings}, ensure_ascii=False, indent=2))
    else:
        if errors:
            print("doctor: FAILED")
            for error in errors:
                print(f"  ERROR {error}")
        else:
            print("doctor: OK")
        for warning in warnings:
            print(f"  WARN  {warning}")
    return 1 if errors else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Legado iOS AI Harness")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="仓库根目录（测试/调试用）")
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="验证控制面、状态、事件链与架构")
    doctor.add_argument("--json", action="store_true")

    next_parser = subparsers.add_parser("next", help="只读返回下一个可领取工作项")
    next_parser.add_argument("--json", action="store_true")

    context = subparsers.add_parser("context", help="生成当前工作项最小上下文包")
    context.add_argument("item_id")

    claim = subparsers.add_parser("claim", help="领取 Harness 选中的工作项")
    claim.add_argument("item_id")
    claim.add_argument("--agent", required=True)

    verify = subparsers.add_parser("verify", help="执行受保护验收并生成 Evidence")
    verify.add_argument("item_id")

    close = subparsers.add_parser("close", help="验证项目记忆事务并完成工作项")
    close.add_argument("item_id")

    architecture = subparsers.add_parser("architecture", help="只运行架构检查")
    architecture.add_argument("--json", action="store_true")

    status = subparsers.add_parser("status", help="显示或刷新人类可读状态")
    status.add_argument("--write", action="store_true")
    subparsers.add_parser("expire-leases", help="由 supervisor 回收已过期的活跃工作项")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        harness = Harness(args.root)
        if args.command == "doctor":
            return print_doctor(harness, args.json)
        if args.command == "next":
            items = harness.work_items()
            state = harness.state()
            item_id = harness.select_next(state, items)
            payload = {"work_item_id": item_id, "reason": None if item_id else "queue_empty_or_active_work_item"}
            print(json.dumps(payload, ensure_ascii=False, indent=2) if args.json else (item_id or "没有可领取工作项"))
            return 0 if item_id else 2
        if args.command == "context":
            print(json.dumps(harness.context_packet(args.item_id), ensure_ascii=False, indent=2))
            return 0
        if args.command == "claim":
            with harness.mutation_lock():
                harness.claim(args.item_id, args.agent)
            print(f"已领取 {args.item_id}")
            return 0
        if args.command == "verify":
            with harness.mutation_lock():
                evidence = harness.verify(args.item_id)
            result = load_json(evidence)
            print(f"{result['result']}: {harness.relative(evidence)}")
            if result.get("failure"):
                print(json.dumps(result["failure"], ensure_ascii=False, indent=2))
            return 0 if result["result"] == "passed" else 1
        if args.command == "close":
            with harness.mutation_lock():
                outcome = harness.close(args.item_id)
            print(f"{args.item_id}: {outcome}")
            return 0 if outcome == "completed" else 2
        if args.command == "architecture":
            errors, warnings = harness.architecture_issues()
            if args.json:
                print(json.dumps({"ok": not errors, "errors": errors, "warnings": warnings}, ensure_ascii=False, indent=2))
            else:
                print("architecture: OK" if not errors else "architecture: FAILED")
                for error in errors:
                    print(f"  ERROR {error}")
                for warning in warnings:
                    print(f"  WARN  {warning}")
            return 1 if errors else 0
        if args.command == "status":
            text = harness.render_status(harness.state(), harness.work_items())
            if args.write:
                with harness.mutation_lock():
                    write_text_atomic(harness.status_path, text)
                print(f"已刷新 {harness.relative(harness.status_path)}")
            else:
                print(text, end="")
            return 0
        if args.command == "expire-leases":
            with harness.mutation_lock():
                expired = harness.expire_leases()
            print(json.dumps({"expired": expired}, ensure_ascii=False, indent=2))
            return 0
        parser.error(f"未知命令：{args.command}")
        return 2
    except HarnessError as error:
        print(f"harness: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
