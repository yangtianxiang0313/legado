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

from swiftpm_manifest import dump_package


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
ACTIVE_STATUSES = {"implementing", "verified", "awaiting_human"}
TERMINAL_STATUSES = {"completed", "rejected", "exhausted", "cancelled", "superseded"}
RECOVERABLE_STATUSES = {"blocked", "rejected", "exhausted", "cancelled"}
ALL_STATUSES = ACTIVE_STATUSES | TERMINAL_STATUSES | {"ready", "blocked"}
HISTORICAL_CONTEXT_STATUSES = TERMINAL_STATUSES | {"blocked"}
WORK_ITEM_ID = re.compile(r"^IOS-[A-Z][A-Z0-9-]*-[0-9]{3}$")
CAPABILITY_ID = re.compile(r"^CAP-[A-Z0-9-]+$")
DECISION_ID = re.compile(r"^[a-z0-9][a-z0-9-]*$")
DECISION_TRIGGER_GATES = {
    "product-scope-change": "product-scope-review",
    "knowledge-proposal-change": "knowledge-review",
    "architecture-proposal-change": "architecture-review",
    "oracle-difference": "oracle-adjudication",
}
CHECK_TIMEOUT_FLOORS = {
    "harness-tests": 180,
}
KNOWLEDGE_CLAIM_ID = re.compile(r"^BKC-[A-Z][A-Z0-9-]*-[0-9]{3}$")
KNOWLEDGE_DRIVER_ID = re.compile(r"^DRV-[A-Z][A-Z0-9-]*-[0-9]{3}$")
KNOWLEDGE_LEDGER_ID = re.compile(r"^BKL-[A-Z][A-Z0-9-]*-[0-9]{3}$")
KNOWLEDGE_ENTRY_ID = re.compile(r"^BKE-[A-Z][A-Z0-9-]*-[0-9]{3}$")
KNOWLEDGE_PACKET_ID = re.compile(r"^BKP-[A-Z][A-Z0-9-]*-[0-9]{3}$")
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

    def decision_gate_contracts(
        self,
        item: Dict[str, Any],
    ) -> Tuple[Dict[str, Dict[str, Any]], List[str]]:
        """Validate and index the opt-in v1 human-decision contract."""

        errors: List[str] = []
        metadata = item.get("metadata", {})
        item_id = (
            str(metadata.get("id"))
            if isinstance(metadata, dict)
            else "<unknown-work-item>"
        )
        spec = item.get("spec", {})
        if not isinstance(spec, dict):
            return {}, [f"{item_id}: spec 必须是 object"]
        gates = spec.get("gates", [])
        if not isinstance(gates, list):
            return {}, [f"{item_id}: gates 必须是数组"]
        version = spec.get("gate_contract_version")
        raw_contracts = spec.get("decision_gates")
        if version is None and raw_contracts is None:
            return {}, []
        if version != 1:
            errors.append(f"{item_id}: gate_contract_version 必须为 1")
        if not isinstance(raw_contracts, list):
            errors.append(f"{item_id}: decision_gates 必须是数组")
            return {}, errors

        contracts: Dict[str, Dict[str, Any]] = {}
        required_contract_keys = {
            "gate",
            "trigger",
            "question",
            "why_human",
            "options",
            "recommended_option",
        }
        required_option_keys = {
            "id",
            "label",
            "consequence",
            "reversible",
        }
        for index, raw in enumerate(raw_contracts):
            label = f"{item_id}: decision_gates[{index}]"
            if not isinstance(raw, dict):
                errors.append(f"{label} 必须是 object")
                continue
            if set(raw) != required_contract_keys:
                errors.append(
                    f"{label} 字段必须精确为 {sorted(required_contract_keys)}"
                )
                continue
            gate = raw.get("gate")
            if not isinstance(gate, str) or DECISION_ID.fullmatch(gate) is None:
                errors.append(f"{label}.gate 无效")
                continue
            if gate in contracts:
                errors.append(f"{item_id}: decision gate 重复：{gate}")
                continue
            trigger = raw.get("trigger")
            allowed_triggers = {"always", *DECISION_TRIGGER_GATES}
            if trigger not in allowed_triggers:
                errors.append(f"{label}.trigger 无效：{trigger}")
            expected_gate = DECISION_TRIGGER_GATES.get(str(trigger))
            if expected_gate is not None and gate != expected_gate:
                errors.append(
                    f"{label}: trigger {trigger} 必须使用 gate {expected_gate}"
                )
            for field in ("question", "why_human"):
                value = raw.get(field)
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{label}.{field} 不能为空")
            options = raw.get("options")
            option_ids: Set[str] = set()
            if not isinstance(options, list) or not 2 <= len(options) <= 4:
                errors.append(f"{label}.options 必须包含 2～4 个选项")
                options = []
            for option_index, option in enumerate(options):
                option_label = f"{label}.options[{option_index}]"
                if not isinstance(option, dict) or set(option) != required_option_keys:
                    errors.append(
                        f"{option_label} 字段必须精确为 {sorted(required_option_keys)}"
                    )
                    continue
                option_id = option.get("id")
                if (
                    not isinstance(option_id, str)
                    or DECISION_ID.fullmatch(option_id) is None
                ):
                    errors.append(f"{option_label}.id 无效")
                elif option_id in option_ids:
                    errors.append(f"{label} option id 重复：{option_id}")
                else:
                    option_ids.add(option_id)
                for field in ("label", "consequence"):
                    value = option.get(field)
                    if not isinstance(value, str) or not value.strip():
                        errors.append(f"{option_label}.{field} 不能为空")
                if not isinstance(option.get("reversible"), bool):
                    errors.append(f"{option_label}.reversible 必须是 boolean")
            recommended = raw.get("recommended_option")
            if not isinstance(recommended, str) or recommended not in option_ids:
                errors.append(f"{label}.recommended_option 必须引用现有 option")
            contracts[gate] = dict(raw)

        if set(gates) != set(contracts):
            errors.append(
                f"{item_id}: gates 与 decision_gates 必须一一对应 "
                f"gates={sorted(str(gate) for gate in gates)}, "
                f"decisions={sorted(contracts)}"
            )
        return contracts, errors

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
        if self.business_knowledge_enabled() and self.business_knowledge_catalog_path.is_file():
            catalog = load_json(self.business_knowledge_catalog_path)
            result.update(
                {
                    "business_knowledge_control_sha256": catalog.get("control_sha256"),
                    "business_knowledge_authority_sha256": catalog.get("authority_sha256"),
                    "business_knowledge_coverage_sha256": catalog.get("coverage_sha256"),
                    "business_knowledge_proposal_sha256": catalog.get("proposal_sha256"),
                }
            )
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

    def readiness_transition_defers_enabler_freshness(
        self,
        item: Dict[str, Any],
        state: Dict[str, Any],
    ) -> bool:
        requirements = item.get("spec", {}).get("requirements", {})
        if requirements.get("mode") != "enabler":
            return False
        selected = {
            f"{reference['id']}@{reference['revision']}#{clause}"
            for reference in requirements.get("refs", [])
            if isinstance(reference, dict)
            for clause in reference.get("clauses", [])
            if isinstance(clause, str)
        }
        releases = self.resolve("ios/project/requirements/releases")
        matches = []
        if releases.is_dir() and not releases.is_symlink():
            for path in sorted(releases.glob("*.json")):
                try:
                    receipt = load_json(path)
                except HarnessError:
                    continue
                binding = receipt.get("binding", {})
                clauses = set(binding.get("clauses", []))
                target = binding.get("target_work_item")
                outputs = receipt.get("outputs", {})
                target_status = (
                    state.get("work_items", {}).get(target, {}).get("status")
                    if isinstance(target, str)
                    else None
                )
                target_accepts_transition = target_status != "completed" or (
                    self.completed_readiness_target_proves_handoff(
                        target,
                        clauses,
                        state,
                    )
                )
                if (
                    receipt.get("kind") == "requirement_readiness_release"
                    and receipt.get("authority")
                    == "protected_requirement_readiness"
                    and receipt.get("authorization")
                    == "github_environment_review"
                    and binding.get("from") == "characterization_required"
                    and binding.get("to") == "implementation_ready"
                    and clauses
                    and clauses.issubset(selected)
                    and isinstance(target, str)
                    and target_accepts_transition
                    and isinstance(outputs, dict)
                    and outputs
                    and all(
                        isinstance(relative, str)
                        and isinstance(digest, str)
                        and (
                            relative in {
                                "ios/project/business-knowledge/catalog.json",
                                "ios/project/requirements/catalog.json",
                            }
                            or (
                                self.resolve(relative).is_file()
                                and not self.resolve(relative).is_symlink()
                                and sha256_bytes(
                                    self.resolve(relative).read_bytes()
                                )
                                == digest
                            )
                        )
                        for relative, digest in outputs.items()
                    )
                ):
                    matches.append(path)
        return len(matches) == 1

    def completed_readiness_target_proves_handoff(
        self,
        target: str,
        release_clauses: Set[str],
        state: Dict[str, Any],
    ) -> bool:
        runtime = state.get("work_items", {}).get(target)
        item = self.work_items().get(target)
        if (
            not isinstance(runtime, dict)
            or runtime.get("status") != "completed"
            or not isinstance(item, dict)
            or runtime.get("work_item_sha256") != sha256_json(item)
        ):
            return False
        requirements = item.get("spec", {}).get("requirements", {})
        selected = {
            f"{reference['id']}@{reference['revision']}#{clause}"
            for reference in requirements.get("refs", [])
            if isinstance(reference, dict)
            and isinstance(reference.get("id"), str)
            and isinstance(reference.get("revision"), int)
            for clause in reference.get("clauses", [])
            if isinstance(clause, str)
        }
        if requirements.get("mode") != "implementation" or selected != release_clauses:
            return False

        evidence_relative = runtime.get("last_evidence")
        evidence_sha256 = runtime.get("last_evidence_sha256")
        evidence_root = self.config.get("evidence_dir")
        if (
            not isinstance(evidence_relative, str)
            or not isinstance(evidence_root, str)
            or not evidence_relative.startswith(evidence_root.rstrip("/") + "/")
            or not isinstance(evidence_sha256, str)
        ):
            return False
        evidence_path = self.resolve(evidence_relative)
        if (
            not evidence_path.is_file()
            or evidence_path.is_symlink()
            or sha256_bytes(evidence_path.read_bytes()) != evidence_sha256
        ):
            return False
        try:
            evidence = load_json(evidence_path)
        except HarnessError:
            return False
        selection = runtime.get("android_requirement_selection_sha256")
        if (
            evidence.get("work_item_id") != target
            or evidence.get("result") != "passed"
            or evidence.get("inputs", {}).get(
                "android_requirement_selection_sha256"
            )
            != selection
        ):
            return False

        checkpoint_path = (
            self.resolve(self.config["checkpoints_dir"]) / f"{target}.json"
        )
        try:
            checkpoint = load_json(checkpoint_path)
        except HarnessError:
            return False
        checkpoint_requirements = checkpoint.get("requirements", {})
        return (
            checkpoint.get("work_item_id") == target
            and checkpoint.get("evidence") == evidence_relative
            and checkpoint_requirements.get("mode") == "implementation"
            and checkpoint_requirements.get("refs") == requirements.get("refs")
            and checkpoint_requirements.get("selection_sha256") == selection
        )

    @property
    def business_knowledge_script_path(self) -> Path:
        return self.resolve("ios/harness/business-knowledge/business_knowledge.py")

    @property
    def business_knowledge_catalog_path(self) -> Path:
        return self.resolve("ios/project/business-knowledge/catalog.json")

    def business_knowledge_enabled(self) -> bool:
        return self.business_knowledge_script_path.is_file()

    def business_knowledge_command(self, command: Sequence[str]) -> Dict[str, Any]:
        if not self.business_knowledge_enabled():
            raise HarnessError("Business Knowledge control 尚未安装")
        try:
            result = subprocess.run(
                [sys.executable, "-B", str(self.business_knowledge_script_path), *command, "--root", str(self.root)],
                cwd=str(self.root),
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise HarnessError(f"Business Knowledge control 超时：{error}") from error
        if result.returncode != 0:
            raise HarnessError(
                "Business Knowledge control 失败：" + (result.stderr or result.stdout)[-4000:].strip()
            )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise HarnessError(f"Business Knowledge control 输出无效：{error}") from error
        if not isinstance(value, dict):
            raise HarnessError("Business Knowledge control 输出必须是 object")
        return value

    def business_knowledge_catalog_value(self) -> Optional[Dict[str, Any]]:
        if not self.business_knowledge_enabled():
            return None
        return self.business_knowledge_command(["manifest"])

    def refresh_business_knowledge_catalog(self) -> None:
        value = self.business_knowledge_catalog_value()
        if value is not None:
            write_json_atomic(self.business_knowledge_catalog_path, value)

    def business_knowledge_selection(self, item: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        knowledge = item.get("spec", {}).get("knowledge")
        if not self.business_knowledge_enabled():
            if knowledge is not None:
                raise HarnessError("工作项声明 Business Knowledge，但控制组件尚未安装")
            return None
        item_id = item.get("metadata", {}).get("id")
        if not isinstance(item_id, str):
            raise HarnessError("工作项缺少 metadata.id，无法计算 Business Knowledge selection")
        return self.business_knowledge_command(["selection", "--work-item", item_id])

    @staticmethod
    def business_knowledge_ledger_revisions(
        selection: Optional[Dict[str, Any]],
    ) -> Dict[str, int]:
        revisions: Dict[str, int] = {}
        if not isinstance(selection, dict):
            return revisions
        for selected in selection.get("coverage", []):
            ledger = selected.get("ledger") if isinstance(selected, dict) else None
            ledger_id = ledger.get("id") if isinstance(ledger, dict) else None
            revision = ledger.get("revision") if isinstance(ledger, dict) else None
            if isinstance(ledger_id, str) and isinstance(revision, int):
                revisions[ledger_id] = revision
        return dict(sorted(revisions.items()))

    def business_knowledge_ledger_snapshots(
        self,
        item: Dict[str, Any],
        selection: Optional[Dict[str, Any]],
    ) -> Dict[str, Dict[str, Any]]:
        transition_ids = {
            transition.get("id")
            for transition in item.get("spec", {})
            .get("knowledge", {})
            .get("expected_ledger_transitions", [])
            if isinstance(transition, dict)
        }
        selected_ledgers: Dict[str, Dict[str, Any]] = {}
        for selected in selection.get("coverage", []) if isinstance(selection, dict) else []:
            ledger = selected.get("ledger") if isinstance(selected, dict) else None
            if isinstance(ledger, dict) and ledger.get("id") in transition_ids:
                selected_ledgers[ledger["id"]] = ledger
        snapshots: Dict[str, Dict[str, Any]] = {}
        for identifier in sorted(transition_ids):
            ledger = selected_ledgers.get(identifier)
            path = ledger.get("path") if isinstance(ledger, dict) else None
            if not isinstance(path, str):
                raise HarnessError(f"{identifier}: Ledger transition 未进入 Coverage selection")
            record = load_json(self.resolve(path))
            if not isinstance(record, dict):
                raise HarnessError(f"{identifier}: Ledger 必须是 object")
            static = {
                key: value
                for key, value in record.items()
                if key not in {"revision", "entries", "updated_by", "updated_at"}
            }
            snapshots[identifier] = {
                "path": path,
                "revision": record.get("revision"),
                "record_sha256": sha256_json(record),
                "static_sha256": sha256_json(static),
                "entry_sha256": {
                    entry["id"]: sha256_json(entry)
                    for entry in record.get("entries", [])
                    if isinstance(entry, dict) and isinstance(entry.get("id"), str)
                },
                "entry_section_sha256": {
                    entry["id"]: {
                        key: sha256_json(entry.get(key))
                        for key in (
                            "claim_ref",
                            "validation",
                            "product_disposition",
                            "delivery",
                            "computed",
                        )
                    }
                    for entry in record.get("entries", [])
                    if isinstance(entry, dict) and isinstance(entry.get("id"), str)
                },
            }
        return snapshots

    @staticmethod
    def business_knowledge_hashes(selection: Optional[Dict[str, Any]]) -> Dict[str, Optional[str]]:
        if selection is None:
            return {
                "business_knowledge_control_sha256": None,
                "business_knowledge_authority_sha256": None,
                "knowledge_selection_sha256": None,
                "coverage_selection_sha256": None,
                "architecture_driver_selection_sha256": None,
            }
        return {
            "business_knowledge_control_sha256": selection.get("control_sha256"),
            "business_knowledge_authority_sha256": selection.get("authority_sha256"),
            "knowledge_selection_sha256": selection.get("knowledge_selection_sha256"),
            "coverage_selection_sha256": selection.get("coverage_selection_sha256"),
            "architecture_driver_selection_sha256": selection.get(
                "architecture_driver_selection_sha256"
            ),
        }

    def managed_paths(self) -> List[str]:
        paths = list(self.config.get("harness_managed_paths", []))
        if self.business_knowledge_enabled():
            paths.append("ios/project/business-knowledge/catalog.json")
        return list(dict.fromkeys(paths))

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

    def validate_business_knowledge_spec(
        self,
        item: Dict[str, Any],
        item_id: str,
    ) -> List[str]:
        errors: List[str] = []
        spec = item.get("spec", {})
        if not isinstance(spec, dict) or "knowledge" not in spec:
            return errors
        knowledge = require_mapping(spec.get("knowledge"), f"{item_id}.knowledge", errors)
        if knowledge is None:
            return errors
        required = {
            "contract_version",
            "mode",
            "claim_refs",
            "driver_refs",
            "coverage_refs",
            "produces",
            "expected_ledger_transitions",
            "context_budget",
            "none_reason",
        }
        if set(knowledge) != required:
            missing = sorted(required - set(knowledge))
            unknown = sorted(set(knowledge) - required)
            if missing:
                errors.append(f"{item_id}: knowledge 缺少字段：{', '.join(missing)}")
            if unknown:
                errors.append(f"{item_id}: knowledge 包含未知字段：{', '.join(unknown)}")
        if knowledge.get("contract_version") != 1:
            errors.append(f"{item_id}: knowledge.contract_version 必须为 1")
        mode = knowledge.get("mode")
        if mode not in {"not_applicable", "consume", "produce", "supersede"}:
            errors.append(f"{item_id}: knowledge.mode 无效")

        list_names = (
            "claim_refs",
            "driver_refs",
            "coverage_refs",
            "produces",
            "expected_ledger_transitions",
        )
        values: Dict[str, List[Any]] = {}
        for name in list_names:
            entries = knowledge.get(name)
            if not isinstance(entries, list):
                errors.append(f"{item_id}: knowledge.{name} 必须是数组")
                values[name] = []
                continue
            values[name] = entries
            encoded = [canonical_bytes(entry) for entry in entries]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{item_id}: knowledge.{name} 不得包含重复项")

        def validate_ref(
            reference: Any,
            label: str,
            pattern: re.Pattern[str],
            keys: Set[str] = {"id", "revision"},
        ) -> None:
            if not isinstance(reference, dict) or set(reference) != keys:
                errors.append(f"{item_id}: {label} 必须精确包含 {sorted(keys)}")
                return
            identifier = reference.get("id")
            revision = reference.get("revision")
            if not isinstance(identifier, str) or pattern.fullmatch(identifier) is None:
                errors.append(f"{item_id}: {label}.id 无效：{identifier}")
            if not isinstance(revision, int) or revision < 1:
                errors.append(f"{item_id}: {label}.revision 必须为正整数")

        for reference in values["claim_refs"]:
            validate_ref(reference, "knowledge.claim_refs[]", KNOWLEDGE_CLAIM_ID)
        for reference in values["driver_refs"]:
            validate_ref(reference, "knowledge.driver_refs[]", KNOWLEDGE_DRIVER_ID)
        for reference in values["coverage_refs"]:
            validate_ref(
                reference,
                "knowledge.coverage_refs[]",
                KNOWLEDGE_LEDGER_ID,
                {"id", "revision", "entries"},
            )
            if isinstance(reference, dict):
                entries = reference.get("entries")
                if (
                    not isinstance(entries, list)
                    or not entries
                    or any(
                        not isinstance(entry, str)
                        or KNOWLEDGE_ENTRY_ID.fullmatch(entry) is None
                        for entry in entries
                    )
                    or len(entries) != len(set(entries))
                ):
                    errors.append(f"{item_id}: knowledge.coverage_refs[].entries 无效")
        for produced in values["produces"]:
            if not isinstance(produced, dict) or set(produced) != {"kind", "id", "revision"}:
                errors.append(
                    f"{item_id}: knowledge.produces[] 必须精确包含 kind/id/revision"
                )
                continue
            kind = produced.get("kind")
            pattern = {"packet": KNOWLEDGE_PACKET_ID, "driver": KNOWLEDGE_DRIVER_ID}.get(kind)
            if pattern is None:
                errors.append(f"{item_id}: knowledge.produces[].kind 无效：{kind}")
            elif not isinstance(produced.get("id"), str) or pattern.fullmatch(produced["id"]) is None:
                errors.append(f"{item_id}: knowledge.produces[].id 无效：{produced.get('id')}")
            if not isinstance(produced.get("revision"), int) or produced.get("revision", 0) < 1:
                errors.append(f"{item_id}: knowledge.produces[].revision 必须为正整数")
        for transition in values["expected_ledger_transitions"]:
            if not isinstance(transition, dict) or set(transition) != {
                "id",
                "from_revision",
                "to_revision",
                "entry_updates",
            }:
                errors.append(
                    f"{item_id}: knowledge.expected_ledger_transitions[] "
                    "必须精确包含 id/from_revision/to_revision/entry_updates"
                )
                continue
            if (
                not isinstance(transition.get("id"), str)
                or KNOWLEDGE_LEDGER_ID.fullmatch(transition["id"]) is None
            ):
                errors.append(f"{item_id}: Ledger transition id 无效")
            before = transition.get("from_revision")
            after = transition.get("to_revision")
            if not isinstance(before, int) or before < 1 or after != before + 1:
                errors.append(f"{item_id}: Ledger transition revision 必须严格 +1")
            entry_updates = transition.get("entry_updates")
            if (
                not isinstance(entry_updates, list)
                or not entry_updates
                or any(not isinstance(entry, dict) for entry in entry_updates)
            ):
                errors.append(f"{item_id}: Ledger transition entry_updates 无效")
                continue
            seen_entry_ids: Set[str] = set()
            for update in entry_updates:
                if set(update) != {"id", "set"}:
                    errors.append(f"{item_id}: Ledger entry update 必须精确包含 id/set")
                    continue
                entry_id, changes = update.get("id"), update.get("set")
                if (
                    not isinstance(entry_id, str)
                    or KNOWLEDGE_ENTRY_ID.fullmatch(entry_id) is None
                    or entry_id in seen_entry_ids
                ):
                    errors.append(f"{item_id}: Ledger entry update id 无效或重复")
                else:
                    seen_entry_ids.add(entry_id)
                allowed = {"validation", "product_disposition", "delivery", "computed"}
                if (
                    not isinstance(changes, dict)
                    or not changes
                    or not set(changes) <= allowed
                    or any(not isinstance(value, dict) for value in changes.values())
                ):
                    errors.append(
                        f"{item_id}: Ledger entry update set 只能声明非空受控 section"
                    )
        coverage_revisions: Dict[Any, Any] = {}
        coverage_entries: Dict[Any, Set[Any]] = {}
        for reference in values["coverage_refs"]:
            if not isinstance(reference, dict):
                continue
            identifier = reference.get("id")
            if not isinstance(identifier, str):
                continue
            revision = reference.get("revision")
            if identifier in coverage_revisions and coverage_revisions[identifier] != revision:
                errors.append(
                    f"{item_id}: 同一 Ledger 的 coverage_refs 必须使用相同 revision"
                )
            else:
                coverage_revisions[identifier] = revision
            entries = reference.get("entries")
            if isinstance(entries, list):
                coverage_entries.setdefault(identifier, set()).update(
                    entry for entry in entries if isinstance(entry, str)
                )
        for transition in values["expected_ledger_transitions"]:
            if not isinstance(transition, dict):
                continue
            identifier = transition.get("id")
            if not isinstance(identifier, str):
                continue
            if coverage_revisions.get(identifier) != transition.get("from_revision"):
                errors.append(
                    f"{item_id}: Ledger transition 必须以 coverage_refs 中的精确 revision 为起点"
                )
            entry_updates = transition.get("entry_updates")
            update_ids = {
                update.get("id")
                for update in entry_updates
                if isinstance(update, dict) and isinstance(update.get("id"), str)
            } if isinstance(entry_updates, list) else set()
            if not update_ids <= coverage_entries.get(identifier, set()):
                errors.append(
                    f"{item_id}: Ledger entry update 越出显式 Coverage selection"
                )

        budget = knowledge.get("context_budget")
        if not isinstance(budget, dict) or set(budget) != {"max_claims", "max_bytes"}:
            errors.append(f"{item_id}: knowledge.context_budget 必须精确包含 max_claims/max_bytes")
        elif (
            not isinstance(budget.get("max_claims"), int)
            or budget["max_claims"] < 1
            or not isinstance(budget.get("max_bytes"), int)
            or budget["max_bytes"] < 1024
        ):
            errors.append(f"{item_id}: knowledge.context_budget 数值无效")

        none_reason = knowledge.get("none_reason")
        referenced = (
            values["claim_refs"]
            + values["driver_refs"]
            + values["coverage_refs"]
            + values["produces"]
            + values["expected_ledger_transitions"]
        )
        if mode == "not_applicable":
            if referenced or not isinstance(none_reason, str) or not none_reason.strip():
                errors.append(f"{item_id}: knowledge 不适用时必须清空引用并填写 none_reason")
        elif mode == "consume":
            if (
                not values["claim_refs"]
                or not values["coverage_refs"]
                or values["produces"]
                or none_reason is not None
            ):
                errors.append(
                    f"{item_id}: knowledge.consume 必须选择 claim/coverage、不得产生 proposal，"
                    "none_reason 为 null"
                )
        elif mode in {"produce", "supersede"}:
            if not values["produces"] or none_reason is not None:
                errors.append(
                    f"{item_id}: knowledge.{mode} 必须声明 proposal outputs，none_reason 为 null"
                )

        criteria = spec.get("acceptance", {}).get("criteria", [])
        selected_claims = {
            (reference.get("id"), reference.get("revision"))
            for reference in values["claim_refs"]
            if isinstance(reference, dict)
        }
        for criterion in criteria if isinstance(criteria, list) else []:
            if not isinstance(criterion, dict):
                continue
            claim_refs = criterion.get("knowledge_claims")
            if not isinstance(claim_refs, list):
                errors.append(f"{item_id}: criterion 必须声明 knowledge_claims 数组")
                continue
            for reference in claim_refs:
                if (
                    not isinstance(reference, dict)
                    or set(reference) != {"id", "revision"}
                    or (reference.get("id"), reference.get("revision")) not in selected_claims
                ):
                    errors.append(
                        f"{item_id}: criterion.knowledge_claims 必须引用工作项选择的精确 claim"
                    )
        if spec.get("requirements", {}).get("mode") == "implementation":
            if mode != "consume":
                errors.append(f"{item_id}: implementation 工作项必须 knowledge.consume")
            for criterion in criteria if isinstance(criteria, list) else []:
                if isinstance(criterion, dict) and not criterion.get("knowledge_claims"):
                    errors.append(f"{item_id}: implementation 每条 AC 必须绑定 knowledge claim")
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
        recovers = spec.get("recovers")
        if recovers is not None:
            if not isinstance(recovers, str) or WORK_ITEM_ID.fullmatch(recovers) is None:
                errors.append(f"{item_id}: recovers 必须是单个 Work Item ID")
            elif recovers == item_id:
                errors.append(f"{item_id}: recovers 不得自引用")
            elif isinstance(depends, list) and recovers in depends:
                errors.append(f"{item_id}: recovers 不得同时出现在 depends_on")
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
        if (
            "gate_contract_version" in spec
            or "decision_gates" in spec
        ):
            _, decision_errors = self.decision_gate_contracts(item)
            errors.extend(decision_errors)
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
        errors.extend(self.validate_business_knowledge_spec(item, item_id))
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
        try:
            result = dump_package(package_path.parent, cwd=self.root, timeout=60)
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

    def promoted_knowledge_context(
        self,
        item_id: str,
        item: Dict[str, Any],
        context: str,
        state: Dict[str, Any],
    ) -> Tuple[bool, Optional[str]]:
        """Validate an immutable proposal context replaced by trusted promotion."""

        proposal_match = re.fullmatch(
            (
                r"ios/project/business-knowledge/"
                r"(packets|drivers)/proposals/"
                r"((?:BKP|DRV)-[A-Z][A-Z0-9-]*-[0-9]{3})/"
                r"r([0-9]{4})\.json"
            ),
            context,
        )
        if proposal_match is None:
            return False, None
        category, identifier, raw_revision = proposal_match.groups()
        kind = "packet" if category == "packets" else "driver"
        expected_prefix = "BKP-" if kind == "packet" else "DRV-"
        if not identifier.startswith(expected_prefix):
            return False, None
        revision = int(raw_revision)

        runtime = state.get("work_items", {}).get(item_id)
        if (
            not isinstance(runtime, dict)
            or runtime.get("status") != "completed"
        ):
            return False, None
        evidence_relative = runtime.get("last_evidence")
        evidence_sha256 = runtime.get("last_evidence_sha256")
        if (
            not isinstance(evidence_relative, str)
            or not isinstance(evidence_sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", evidence_sha256) is None
        ):
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID evidence binding：{context}",
            )
        evidence_path = self.resolve(evidence_relative)
        if (
            evidence_path.is_symlink()
            or not evidence_path.is_file()
            or sha256_bytes(evidence_path.read_bytes()) != evidence_sha256
        ):
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID evidence artifact：{context}",
            )
        try:
            evidence = load_json(evidence_path)
        except HarnessError:
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID evidence JSON：{context}",
            )
        if not isinstance(evidence, dict):
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID evidence object：{context}",
            )
        changes = evidence.get("changes")
        fingerprint = None
        if isinstance(changes, dict):
            for section in ("file_fingerprints", "dirty_snapshot"):
                fingerprints = changes.get(section)
                if (
                    isinstance(fingerprints, dict)
                    and isinstance(fingerprints.get(context), str)
                ):
                    fingerprint = fingerprints[context]
                    break
        fingerprint_match = re.fullmatch(
            r"file:0o[0-7]+:([0-9a-f]{64})",
            fingerprint if isinstance(fingerprint, str) else "",
        )
        if (
            evidence.get("work_item_id") != item_id
            or evidence.get("result") != "passed"
        ):
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID consumer evidence：{context}",
            )
        if fingerprint_match is not None:
            proposal_sha256 = fingerprint_match.group(1)
        else:
            base_commit = runtime.get("base_commit")
            if (
                not isinstance(base_commit, str)
                or re.fullmatch(r"[0-9a-f]{40}", base_commit) is None
            ):
                return (
                    False,
                    f"PROMOTED_CONTEXT_INVALID frozen proposal：{context}",
                )
            historical = self.run_git(
                ["show", f"{base_commit}:{context}"],
                check=False,
            )
            if historical.returncode != 0:
                return (
                    False,
                    f"PROMOTED_CONTEXT_INVALID frozen proposal：{context}",
                )
            proposal_sha256 = sha256_bytes(historical.stdout)

        published_root = (
            "ios/project/business-knowledge/packets/published"
            if kind == "packet"
            else "ios/project/business-knowledge/drivers/published"
        )
        published_relative = (
            f"{published_root}/{identifier}/r{revision:04d}.json"
        )
        published_path = self.resolve(published_relative)
        if published_path.is_symlink() or not published_path.is_file():
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID published artifact：{context}",
            )
        published_sha256 = sha256_bytes(published_path.read_bytes())
        try:
            published = load_json(published_path)
        except HarnessError:
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID published JSON：{context}",
            )
        expected_status = "published" if kind == "packet" else {
            "active",
            "resolved",
        }
        status = published.get("status")
        if (
            published.get("id") != identifier
            or published.get("revision") != revision
            or (
                status != expected_status
                if isinstance(expected_status, str)
                else status not in expected_status
            )
        ):
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID published identity：{context}",
            )

        proposal_key = (
            "packet_proposal" if kind == "packet" else "driver_proposal"
        )
        proposal_sha_key = f"{proposal_key}_sha256"
        releases = self.resolve(
            "ios/project/business-knowledge/releases"
        )
        candidates: List[Tuple[Path, Dict[str, Any]]] = []
        if releases.is_dir() and not releases.is_symlink():
            for receipt_path in sorted(releases.glob("*.json")):
                if receipt_path.is_symlink() or not receipt_path.is_file():
                    continue
                try:
                    receipt = load_json(receipt_path)
                except HarnessError:
                    continue
                inputs = receipt.get("inputs")
                if (
                    isinstance(inputs, dict)
                    and inputs.get(proposal_key) == context
                ):
                    candidates.append((receipt_path, receipt))
        if len(candidates) != 1:
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID receipt count={len(candidates)}：{context}",
            )
        _, receipt = candidates[0]
        receipt_producer = receipt.get("producer")
        receipt_inputs = receipt.get("inputs")
        receipt_outputs = receipt.get("outputs")
        receipt_binding = receipt.get("bindings", {}).get(kind)
        producer_id = (
            receipt_producer.get("work_item")
            if isinstance(receipt_producer, dict)
            else None
        )
        producer_runtime = (
            state.get("work_items", {}).get(producer_id)
            if isinstance(producer_id, str)
            else None
        )
        producer_item_path = (
            self.resolve(f"ios/harness/work-items/{producer_id}.json")
            if isinstance(producer_id, str)
            else None
        )
        producer_item: Any = None
        if (
            isinstance(producer_runtime, dict)
            and producer_runtime.get("status") == "completed"
            and isinstance(producer_item_path, Path)
            and producer_item_path.is_file()
            and not producer_item_path.is_symlink()
        ):
            try:
                producer_item = load_json(producer_item_path)
            except HarnessError:
                producer_item = None
        producer_outputs = (
            producer_item.get("spec", {})
            .get("knowledge", {})
            .get("produces", [])
            if isinstance(producer_item, dict)
            else []
        )
        producer_declared = any(
            isinstance(output, dict)
            and output.get("kind") == kind
            and output.get("id") == identifier
            and output.get("revision") == revision
            for output in producer_outputs
        )
        producer_evidence_relative = (
            producer_runtime.get("last_evidence")
            if isinstance(producer_runtime, dict)
            else None
        )
        producer_evidence_sha256 = (
            producer_runtime.get("last_evidence_sha256")
            if isinstance(producer_runtime, dict)
            else None
        )
        producer_evidence_path = (
            self.resolve(producer_evidence_relative)
            if isinstance(producer_evidence_relative, str)
            else None
        )
        producer_evidence_valid = (
            isinstance(producer_evidence_path, Path)
            and producer_evidence_path.is_file()
            and not producer_evidence_path.is_symlink()
            and isinstance(producer_evidence_sha256, str)
            and sha256_bytes(producer_evidence_path.read_bytes())
            == producer_evidence_sha256
        )
        if (
            receipt.get("kind") != "business_knowledge_release"
            or receipt.get("authority") != "protected_business_knowledge"
            or receipt.get("authorization")
            != "github_environment_review"
            or re.fullmatch(
                r"[0-9a-f]{40}",
                str(receipt.get("source_commit", "")),
            )
            is None
            or not isinstance(receipt_producer, dict)
            or not producer_declared
            or not producer_evidence_valid
            or published.get("created_by") != producer_id
            or receipt_producer.get("evidence")
            != producer_evidence_relative
            or receipt_producer.get("evidence_sha256")
            != producer_evidence_sha256
            or not isinstance(receipt_inputs, dict)
            or receipt_inputs.get(proposal_sha_key)
            != proposal_sha256
            or not isinstance(receipt_outputs, dict)
            or receipt_outputs.get(published_relative)
            != published_sha256
            or context not in receipt.get("deletions", [])
            or not isinstance(receipt_binding, dict)
            or receipt_binding.get("id") != identifier
            or receipt_binding.get("revision") != revision
        ):
            return (
                False,
                f"PROMOTED_CONTEXT_INVALID receipt binding：{context}",
            )
        return True, None

    def validate_references(
        self,
        items: Dict[str, Dict[str, Any]],
        state: Optional[Dict[str, Any]] = None,
    ) -> List[str]:
        errors: List[str] = []
        state = state if isinstance(state, dict) else self.state()
        architecture_text = self.resolve("ios/docs/architecture.md").read_text(encoding="utf-8")
        adr_dir = self.resolve("ios/docs/adr")
        adr_text = "\n".join(path.read_text(encoding="utf-8") for path in sorted(adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md")))
        for item_id, item in items.items():
            spec = item["spec"]
            for dependency in spec.get("depends_on", []):
                if dependency not in items:
                    errors.append(f"{item_id}: depends_on 不存在：{dependency}")
            recovers = spec.get("recovers")
            if isinstance(recovers, str):
                predecessor = items.get(recovers)
                if predecessor is None:
                    errors.append(f"{item_id}: recovers 不存在：{recovers}")
                elif (
                    predecessor.get("spec", {}).get("capability")
                    != spec.get("capability")
                ):
                    errors.append(
                        f"{item_id}: recovers capability 不一致：{recovers}"
                    )
            for reference in spec.get("architecture_refs", []):
                if reference.startswith("ARCH-") and reference not in architecture_text:
                    errors.append(f"{item_id}: 架构引用不存在：{reference}")
                if reference.startswith("ADR-") and reference not in adr_text:
                    errors.append(f"{item_id}: ADR 引用不存在：{reference}")
            inputs = spec.get("inputs", {})
            for context in inputs.get("context_files", []):
                if not self.resolve(context).exists():
                    promoted, issue = self.promoted_knowledge_context(
                        item_id,
                        item,
                        context,
                        state,
                    )
                    runtime = state.get("work_items", {}).get(
                        item_id, {}
                    )
                    status = (
                        runtime.get("status")
                        if isinstance(runtime, dict)
                        else None
                    )
                    context_path = Path(context)
                    ignored_runtime_context = (
                        isinstance(context, str)
                        and context.startswith(".harness-runtime/")
                        and context_path.as_posix() == context
                        and context_path.parts
                        and context_path.parts[0] == ".harness-runtime"
                        and "." not in context_path.parts
                        and ".." not in context_path.parts
                    )
                    if (
                        not promoted
                        and ignored_runtime_context
                        and status in HISTORICAL_CONTEXT_STATUSES
                    ):
                        continue
                    if not promoted:
                        errors.append(
                            f"{item_id}: "
                            + (
                                issue
                                if issue is not None
                                else f"context file 不存在：{context}"
                            )
                        )
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
        errors.extend(self.detect_recovery_cycles(items))
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
                elif isinstance(
                    items.get(item_id, {}).get("spec", {}).get("knowledge"),
                    dict,
                ):
                    _, checkpoint_errors = self.validate_checkpoint(
                        item_id, items[item_id], runtime
                    )
                    errors.extend(
                        f"{item_id}: terminal checkpoint: {error}"
                        for error in checkpoint_errors
                    )

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
                        if not self.readiness_transition_defers_enabler_freshness(
                            item,
                            state,
                        ):
                            errors.append(
                                f"{capability_id}: verified Evidence 输入已过期：{input_name}"
                            )
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

    @staticmethod
    def detect_recovery_cycles(items: Dict[str, Dict[str, Any]]) -> List[str]:
        errors: List[str] = []
        for item_id in sorted(items):
            chain: List[str] = []
            current = item_id
            while current in items:
                if current in chain:
                    errors.append(
                        "工作项恢复成环：" + " -> ".join(chain + [current])
                    )
                    break
                chain.append(current)
                predecessor = items[current].get("spec", {}).get("recovers")
                if not isinstance(predecessor, str):
                    break
                current = predecessor
        return sorted(set(errors))

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
        errors.extend(self.validate_references(items, state))
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
        if self.business_knowledge_enabled():
            try:
                result = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        str(self.business_knowledge_script_path),
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
                    errors.append(
                        "Business Knowledge control 无效："
                        + (result.stderr or result.stdout)[-4000:].strip()
                    )
            except subprocess.TimeoutExpired as error:
                errors.append(f"Business Knowledge control 验证超时：{error}")
            for item_id, item in items.items():
                runtime = state_items.get(item_id, {})
                status = runtime.get("status") if isinstance(runtime, dict) else None
                knowledge = item.get("spec", {}).get("knowledge")
                if status not in TERMINAL_STATUSES and not isinstance(knowledge, dict):
                    errors.append(f"{item_id}: 非终态工作项必须声明 Business Knowledge contract")
                    continue
                if status in TERMINAL_STATUSES or not isinstance(knowledge, dict):
                    continue
                try:
                    selection = self.business_knowledge_selection(item)
                except HarnessError as error:
                    errors.append(f"{item_id}: Business Knowledge selection 无效：{error}")
                    continue
                if (
                    item.get("spec", {}).get("requirements", {}).get("mode") == "implementation"
                    and selection
                    and selection.get("blocking_reasons")
                ):
                    errors.append(
                        f"{item_id}: implementation 的 Business Knowledge 尚未就绪："
                        + ", ".join(selection["blocking_reasons"])
                    )
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
        excludes = self.managed_paths() + list(extra_excludes)
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
        ] + self.managed_paths()
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
        knowledge_selection = self.business_knowledge_selection(item)
        if (
            item.get("spec", {}).get("requirements", {}).get("mode") == "implementation"
            and knowledge_selection
            and knowledge_selection.get("blocking_reasons")
        ):
            raise HarnessError(
                "KNOWLEDGE_NOT_READY: " + ", ".join(knowledge_selection["blocking_reasons"])
            )
        knowledge_hashes = self.business_knowledge_hashes(knowledge_selection)
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
                **knowledge_hashes,
                "knowledge_ledger_revisions": self.business_knowledge_ledger_revisions(
                    knowledge_selection
                ),
                "knowledge_ledger_snapshots": self.business_knowledge_ledger_snapshots(
                    item, knowledge_selection
                ),
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

    @staticmethod
    def knowledge_proposal_paths(item: Dict[str, Any]) -> List[str]:
        knowledge = item.get("spec", {}).get("knowledge", {})
        paths: List[str] = []
        for produced in knowledge.get("produces", []) if isinstance(knowledge, dict) else []:
            if not isinstance(produced, dict):
                continue
            identifier = produced.get("id")
            revision = produced.get("revision")
            kind = produced.get("kind")
            if not isinstance(identifier, str) or not isinstance(revision, int):
                continue
            if kind == "packet":
                root = "ios/project/business-knowledge/packets/proposals"
            elif kind == "driver":
                root = "ios/project/business-knowledge/drivers/proposals"
            else:
                continue
            paths.append(f"{root}/{identifier}/r{revision:04d}.json")
        return sorted(paths)

    @staticmethod
    def business_knowledge_control_upgrade(item: Dict[str, Any]) -> bool:
        labels = item.get("metadata", {}).get("labels", [])
        return (
            item.get("spec", {}).get("requirements", {}).get("mode") == "control_plane"
            and item.get("spec", {}).get("knowledge", {}).get("mode") == "not_applicable"
            and isinstance(labels, list)
            and any(label in {"control-plane", "governance", "corrective"} for label in labels)
        )

    @staticmethod
    def knowledge_ledger_paths(item: Dict[str, Any]) -> List[str]:
        knowledge = item.get("spec", {}).get("knowledge", {})
        paths: List[str] = []
        transitions = (
            knowledge.get("expected_ledger_transitions", [])
            if isinstance(knowledge, dict)
            else []
        )
        for transition in transitions:
            identifier = transition.get("id") if isinstance(transition, dict) else None
            if isinstance(identifier, str):
                paths.append(f"ios/project/business-knowledge/coverage/{identifier}.json")
        return sorted(paths)

    def knowledge_scope_issues(
        self,
        item: Dict[str, Any],
        product_changes: Sequence[str],
    ) -> List[str]:
        knowledge = item.get("spec", {}).get("knowledge")
        if not isinstance(knowledge, dict):
            return []
        errors: List[str] = []
        mode = knowledge.get("mode")
        proposal_roots = [
            "ios/project/business-knowledge/packets/proposals/**",
            "ios/project/business-knowledge/drivers/proposals/**",
        ]
        published_roots = [
            "ios/project/business-knowledge/packets/published/**",
            "ios/project/business-knowledge/drivers/published/**",
        ]
        coverage_root = ["ios/project/business-knowledge/coverage/**"]
        tombstone_root = ["ios/project/business-knowledge/tombstones/**"]
        expected_proposals = set(self.knowledge_proposal_paths(item))
        control_upgrade = self.business_knowledge_control_upgrade(item)
        for path in product_changes:
            if path_matches(path, ["ios/harness/business-knowledge/**"]):
                if not control_upgrade:
                    errors.append(f"KNOWLEDGE_CONTROL_MUTATION: {path}")
            elif path_matches(path, tombstone_root):
                if not control_upgrade:
                    errors.append(
                        f"AUTHORITY_ESCALATION: 普通工作项不得创建 knowledge tombstone：{path}"
                    )
            elif path_matches(path, published_roots):
                errors.append(f"AUTHORITY_ESCALATION: 普通工作项不得修改 published 知识：{path}")
            elif path_matches(path, coverage_root):
                errors.append(f"COVERAGE_TRANSACTION_EARLY: Coverage 只能在 verify 后按声明更新：{path}")
            elif path_matches(path, proposal_roots) and (
                mode not in {"produce", "supersede"} or path not in expected_proposals
            ):
                errors.append(f"AUTHORITY_ESCALATION: 未声明的知识 proposal：{path}")
            elif path_matches(path, ["ios/project/business-knowledge/**"]) and path not in expected_proposals:
                errors.append(f"KNOWLEDGE_PATH_UNDECLARED: {path}")
        if mode in {"produce", "supersede"}:
            for path in sorted(expected_proposals):
                if path not in product_changes or not self.resolve(path).is_file():
                    errors.append(f"KNOWLEDGE_OUTPUT_MISSING: {path}")
            product_code = [
                path
                for path in product_changes
                if path_matches(path, ["app/**", "modules/**", "ios/Packages/**"])
            ]
            if product_code:
                errors.append(
                    "KNOWLEDGE_PRODUCT_MIXED: 知识生产与产品实现必须拆分："
                    + ", ".join(sorted(product_code))
                )
        return errors

    def scope_issues(self, item: Dict[str, Any], runtime: Dict[str, Any], changed: Sequence[str]) -> Tuple[List[str], List[str], int]:
        errors: List[str] = []
        managed = self.managed_paths()
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
        errors.extend(self.knowledge_scope_issues(item, product_changes))
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
    def terminate_process_group(
        cls, process_group_id: int, grace_seconds: float = 0.75
    ) -> Optional[str]:
        try:
            os.killpg(process_group_id, signal.SIGTERM)
        except ProcessLookupError:
            return None
        except PermissionError:
            return "sigterm_permission_denied"
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            if not cls.process_group_exists(process_group_id):
                return None
            time.sleep(0.025)
        try:
            os.killpg(process_group_id, signal.SIGKILL)
        except ProcessLookupError:
            return None
        except PermissionError:
            return "sigkill_permission_denied"
        return None

    @staticmethod
    def timeout_output(value: Any) -> bytes:
        if value is None:
            return b""
        if isinstance(value, bytes):
            return value
        if isinstance(value, str):
            return value.encode("utf-8")
        return bytes(value)

    def run_check(self, check_id: str, item_id: str) -> Dict[str, Any]:
        definition = self.effective_check_definition(check_id)
        argv = [str(part).replace("{work_item_id}", item_id) for part in definition["argv"]]
        if not argv or any(not part for part in argv):
            raise HarnessError(f"check {check_id} argv 无效")
        cwd = self.resolve(definition.get("cwd", "."))
        timeout = int(definition.get("timeout_seconds", 300))
        started = time.monotonic()
        started_at = utc_now()
        executable_path = shutil.which(argv[0], path=self.command_environment(item_id).get("PATH"))
        process_leak = False
        cleanup_errors: List[str] = []

        def record_cleanup_error(value: Optional[str]) -> None:
            if value and value not in cleanup_errors:
                cleanup_errors.append(value)

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
            except subprocess.TimeoutExpired as error:
                stdout = self.timeout_output(error.output)
                stderr = self.timeout_output(error.stderr)
                cleanup_diagnostic = self.terminate_process_group(
                    process.pid, grace_seconds=0.1
                )
                record_cleanup_error(cleanup_diagnostic)
                if cleanup_diagnostic:
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    except PermissionError:
                        record_cleanup_error("process_kill_permission_denied")
                try:
                    final_stdout, final_stderr = process.communicate(timeout=1.0)
                    stdout = self.timeout_output(final_stdout) or stdout
                    stderr = self.timeout_output(final_stderr) or stderr
                except subprocess.TimeoutExpired as cleanup_timeout:
                    stdout = self.timeout_output(cleanup_timeout.output) or stdout
                    stderr = self.timeout_output(cleanup_timeout.stderr) or stderr
                    record_cleanup_error("communicate_timeout_after_cleanup")
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    except PermissionError:
                        record_cleanup_error("process_kill_permission_denied")
                exit_code = None
                timed_out = True
            if self.process_group_exists(process.pid):
                process_leak = not timed_out
                record_cleanup_error(self.terminate_process_group(process.pid))
                if timed_out:
                    process_leak = self.process_group_exists(process.pid)
            if process_leak:
                stderr += b"\nPROCESS_LEAK: check exited while child processes were still alive\n"
        except FileNotFoundError as error:
            exit_code = None
            stdout = b""
            stderr = str(error).encode("utf-8")
            timed_out = False
            process_leak = False
        cleanup_error = ";".join(cleanup_errors) or None
        if cleanup_error:
            stderr += f"\nCLEANUP_ERROR: {cleanup_error}\n".encode("utf-8")
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
            "cleanup_error": cleanup_error,
            "exit_code": exit_code,
            "passed": (
                exit_code == 0
                and not timed_out
                and not process_leak
                and cleanup_error is None
            ),
            "stdout_sha256": sha256_bytes(stdout),
            "stderr_sha256": sha256_bytes(stderr),
            "stdout_tail": self.redact_output(stdout[-output_limit:]),
            "stderr_tail": self.redact_output(stderr[-output_limit:]),
        }

    def effective_check_definition(self, check_id: str) -> Dict[str, Any]:
        definition = dict(self.config["checks"][check_id])
        floor = CHECK_TIMEOUT_FLOORS.get(check_id)
        if floor is not None:
            configured = int(definition.get("timeout_seconds", 300))
            definition["timeout_seconds"] = max(configured, floor)
        return definition

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
        self.refresh_business_knowledge_catalog()
        current_knowledge_selection = self.business_knowledge_selection(item)
        current_knowledge_hashes = self.business_knowledge_hashes(current_knowledge_selection)
        missing_knowledge_freeze = [
            key for key in current_knowledge_hashes if key not in runtime
        ]
        if missing_knowledge_freeze:
            bootstrap_claim = (
                item_id == "IOS-KNOWLEDGE-CONTROL-PLANE-001"
                and len(missing_knowledge_freeze) == len(current_knowledge_hashes)
                and runtime.get("attempt") == 1
                and runtime.get("base_commit")
                == "cf7f095de3af737966dbf3d4c1e846719b68f169"
            )
            if not bootstrap_claim:
                raise HarnessError(
                    "KNOWLEDGE_DRIFT: claim 未冻结 Business Knowledge："
                    + ", ".join(missing_knowledge_freeze)
                )
        else:
            drifted = [
                key
                for key, value in current_knowledge_hashes.items()
                if runtime.get(key) != value
            ]
            if self.business_knowledge_control_upgrade(item):
                drifted = [
                    key
                    for key in drifted
                    if key != "business_knowledge_control_sha256"
                ]
            if drifted:
                raise HarnessError(
                    "KNOWLEDGE_DRIFT: Business Knowledge 在 claim 后变化："
                    + ", ".join(drifted)
                )

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
        if self.business_knowledge_enabled():
            try:
                expected_catalog = self.business_knowledge_catalog_value()
                actual_catalog = load_json(self.business_knowledge_catalog_path)
                if actual_catalog != expected_catalog:
                    policy_errors.append(
                        "CHECK_MUTATED_KNOWLEDGE_CATALOG: 验收命令使知识目录失去确定性"
                    )
                else:
                    post_knowledge_selection = self.business_knowledge_selection(item)
                    post_knowledge_hashes = self.business_knowledge_hashes(
                        post_knowledge_selection
                    )
                    if post_knowledge_hashes != current_knowledge_hashes:
                        policy_errors.append(
                            "CHECK_MUTATED_KNOWLEDGE: 验收命令改变了知识选择或控制摘要"
                        )
            except HarnessError as error:
                policy_errors.append(f"CHECK_MUTATED_KNOWLEDGE: {error}")
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
                **current_knowledge_hashes,
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
                error.startswith(
                    (
                        "SCOPE_VIOLATION",
                        "PROTECTED_PATH_MUTATION",
                        "INDEX_DIRTY",
                        "CHECK_MUTATED_CANDIDATE",
                        "CHECK_MUTATED_KNOWLEDGE",
                        "AUTHORITY_ESCALATION",
                        "COVERAGE_TRANSACTION_EARLY",
                        "KNOWLEDGE_PRODUCT_MIXED",
                        "KNOWLEDGE_CONTROL_MUTATION",
                        "KNOWLEDGE_PATH_UNDECLARED",
                    )
                )
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
        expected_knowledge = item.get("spec", {}).get("knowledge")
        if isinstance(expected_knowledge, dict):
            required.append("business_knowledge")
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
        if isinstance(expected_knowledge, dict):
            knowledge = checkpoint.get("business_knowledge")
            knowledge_keys = {
                "mode",
                "claim_refs",
                "driver_refs",
                "coverage_refs",
                "selection_sha256",
                "coverage_selection_sha256",
                "architecture_driver_selection_sha256",
                "produced_refs",
                "ledger_updates",
                "none_reason",
            }
            if not isinstance(knowledge, dict):
                errors.append("checkpoint business_knowledge 必须是 object")
            else:
                if set(knowledge) != knowledge_keys:
                    errors.append(
                        "checkpoint business_knowledge 必须精确包含消费、选择摘要、产出和 Ledger 更新字段"
                    )
                for key in ("mode", "claim_refs", "driver_refs", "coverage_refs", "none_reason"):
                    if knowledge.get(key) != expected_knowledge.get(key):
                        errors.append(
                            f"checkpoint business_knowledge.{key} 与工作项契约不一致"
                        )
                if knowledge.get("produced_refs") != expected_knowledge.get("produces"):
                    errors.append("checkpoint business_knowledge.produced_refs 与工作项契约不一致")
                if knowledge.get("ledger_updates") != expected_knowledge.get(
                    "expected_ledger_transitions"
                ):
                    errors.append("checkpoint business_knowledge.ledger_updates 与工作项契约不一致")
                try:
                    knowledge_evidence = load_json(
                        self.resolve(runtime.get("last_evidence", ""))
                    )
                    evidence_inputs = knowledge_evidence.get("inputs", {})
                except HarnessError as error:
                    errors.append(str(error))
                    evidence_inputs = {}
                for checkpoint_key, evidence_key in (
                    ("selection_sha256", "knowledge_selection_sha256"),
                    ("coverage_selection_sha256", "coverage_selection_sha256"),
                    (
                        "architecture_driver_selection_sha256",
                        "architecture_driver_selection_sha256",
                    ),
                ):
                    if knowledge.get(checkpoint_key) != evidence_inputs.get(evidence_key):
                        errors.append(
                            f"checkpoint business_knowledge.{checkpoint_key} 与 Evidence 不一致"
                        )
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

    def knowledge_entry_reference_issues(
        self,
        item_id: str,
        item: Dict[str, Any],
        runtime: Dict[str, Any],
        ledger_id: str,
        entry_id: str,
        entry: Dict[str, Any],
    ) -> List[str]:
        errors: List[str] = []
        label = f"{ledger_id}#{entry_id}"
        catalog = load_json(self.resolve("ios/project/requirements/catalog.json"))
        requirements = {
            (value.get("id"), value.get("revision")): value
            for value in catalog.get("requirements", [])
            if isinstance(value, dict)
        }

        def requirement_reference_valid(reference: Any) -> bool:
            match = (
                re.fullmatch(
                    r"(REQ-[A-Z0-9-]+)@([0-9]+)(?:#(RC-[0-9]{2}))?",
                    reference,
                )
                if isinstance(reference, str)
                else None
            )
            if match is None:
                return False
            record = requirements.get((match.group(1), int(match.group(2))))
            return isinstance(record, dict) and (
                match.group(3) is None or match.group(3) in record.get("clauses", [])
            )

        inventory = load_json(self.resolve("ios/project/android-intake/inventory-manifest.json"))
        fact_ids = {
            value.get("id")
            for value in inventory.get("facts", [])
            if isinstance(value, dict)
        }

        def evidence_reference_valid(reference: Any) -> bool:
            return isinstance(reference, str) and (
                reference in fact_ids
                or (
                    reference.startswith("ios/")
                    and self.resolve(reference).is_file()
                )
            )

        validation = entry.get("validation", {})
        validation_evidence = validation.get("evidence_refs", [])
        if validation.get("state") in {"supported", "verified"} and (
            not validation_evidence
            or any(not evidence_reference_valid(ref) for ref in validation_evidence)
        ):
            errors.append(f"{label}: validation Evidence 引用不可解析")

        delivery = entry.get("delivery", {})
        work_items = self.work_items()
        if any(ref not in work_items for ref in delivery.get("work_item_refs", [])):
            errors.append(f"{label}: delivery Work Item 引用不可解析")
        if any(
            not isinstance(ref, str)
            or not (self.resolve(self.config["capabilities_dir"]) / f"{ref}.json").is_file()
            for ref in delivery.get("capability_refs", [])
        ):
            errors.append(f"{label}: delivery Capability 引用不可解析")
        if any(
            not evidence_reference_valid(ref)
            for ref in delivery.get("evidence_refs", [])
        ):
            errors.append(f"{label}: delivery Evidence 引用不可解析")
        if any(
            not requirement_reference_valid(ref)
            for ref in delivery.get("requirement_refs", [])
        ):
            errors.append(f"{label}: delivery Requirement 引用不可解析")
        if delivery.get("state") == "verified":
            required = {
                "work_item_refs": item_id,
                "capability_refs": item.get("spec", {}).get("capability"),
                "evidence_refs": runtime.get("last_evidence"),
            }
            for field, reference in required.items():
                if reference not in delivery.get(field, []):
                    errors.append(f"{label}: verified delivery 缺少当前事务 {field}")

        disposition = entry.get("product_disposition", {})
        kind, refs = disposition.get("kind"), disposition.get("refs", [])
        if kind == "covered_by_requirement" and (
            not refs or any(not requirement_reference_valid(ref) for ref in refs)
        ):
            errors.append(f"{label}: covered_by_requirement 引用不可解析")
        if kind == "architecture_driver":
            drivers = {
                (value.get("id"), value.get("revision"))
                for value in load_json(self.business_knowledge_catalog_path).get(
                    "architecture_drivers", []
                )
                if isinstance(value, dict)
            }
            if not refs or any(
                not isinstance(ref, str)
                or (
                    (match := re.fullmatch(r"(DRV-[A-Z][A-Z0-9-]*-[0-9]{3})@([0-9]+)", ref))
                    is None
                )
                or (match.group(1), int(match.group(2))) not in drivers
                for ref in refs
            ):
                errors.append(f"{label}: architecture_driver 引用不可解析")
        if kind in {"intentional_omission", "unsupported", "deferred", "rejected"} and (
            not refs
            or f"ios/project/approvals/{item_id}--product-scope-review.json" not in refs
            or any(
                not isinstance(ref, str)
                or not ref.startswith("ios/project/approvals/")
                for ref in refs
            )
        ):
            errors.append(f"{label}: terminal disposition 必须引用当前工作项的人工批准")
        return errors

    def knowledge_close_issues(
        self,
        item_id: str,
        item: Dict[str, Any],
        runtime: Dict[str, Any],
    ) -> List[str]:
        knowledge = item.get("spec", {}).get("knowledge")
        if not isinstance(knowledge, dict):
            return []
        transitions = knowledge.get("expected_ledger_transitions", [])
        if not transitions:
            return []
        errors: List[str] = []
        baselines = runtime.get("knowledge_ledger_revisions")
        snapshots = runtime.get("knowledge_ledger_snapshots")
        if not isinstance(baselines, dict) or not isinstance(snapshots, dict):
            return ["claim 未冻结 Knowledge Ledger revision/snapshot"]
        selected_entries: Dict[Any, Set[Any]] = {}
        for reference in knowledge.get("coverage_refs", []):
            if not isinstance(reference, dict):
                continue
            identifier = reference.get("id")
            if not isinstance(identifier, str):
                continue
            entries = reference.get("entries")
            if isinstance(entries, list):
                selected_entries.setdefault(identifier, set()).update(
                    entry for entry in entries if isinstance(entry, str)
                )
        for transition in transitions:
            if not isinstance(transition, dict):
                continue
            identifier = transition.get("id")
            before = transition.get("from_revision")
            after = transition.get("to_revision")
            entry_updates = transition.get("entry_updates")
            if not isinstance(entry_updates, list):
                errors.append(f"{identifier}: Ledger transition entry_updates 无效")
                continue
            update_ids = {
                update.get("id")
                for update in entry_updates
                if isinstance(update, dict) and isinstance(update.get("id"), str)
            }
            if not update_ids <= selected_entries.get(identifier, set()):
                errors.append(
                    f"{identifier}: Ledger entry update 越出显式 Coverage selection"
                )
            if baselines.get(identifier) != before:
                errors.append(
                    f"{identifier}: Ledger from_revision 与 claim 基线不一致"
                )
                continue
            snapshot = snapshots.get(identifier)
            if not isinstance(snapshot, dict):
                errors.append(f"{identifier}: claim 缺少 Ledger snapshot")
                continue
            path = self.resolve(
                f"ios/project/business-knowledge/coverage/{identifier}.json"
            )
            try:
                ledger = load_json(path)
            except HarnessError as error:
                errors.append(str(error))
                continue
            if not isinstance(ledger, dict):
                errors.append(f"{identifier}: Ledger 必须是 object")
                continue
            if ledger.get("id") != identifier or ledger.get("revision") != after:
                errors.append(f"{identifier}: Ledger 未更新到声明的 revision {after}")
            if ledger.get("updated_by") != item_id:
                errors.append(f"{identifier}: Ledger updated_by 必须是当前工作项")
            static = {
                key: value
                for key, value in ledger.items()
                if key not in {"revision", "entries", "updated_by", "updated_at"}
            }
            if sha256_json(static) != snapshot.get("static_sha256"):
                errors.append(f"{identifier}: Ledger 非进度元数据在 close 事务中被修改")
            entries = {
                entry.get("id"): entry
                for entry in ledger.get("entries", [])
                if isinstance(entry, dict) and isinstance(entry.get("id"), str)
            }
            previous = snapshot.get("entry_sha256", {})
            if set(entries) != set(previous):
                errors.append(f"{identifier}: Ledger close 不得增删 Coverage entry")
                continue
            updates = {
                update.get("id"): update.get("set", {})
                for update in entry_updates
                if isinstance(update, dict)
            }
            declared = set(updates)
            missing_entries = sorted(declared - set(entries))
            changed_entries = {
                entry_id
                for entry_id, entry in entries.items()
                if sha256_json(entry) != previous.get(entry_id)
            }
            if missing_entries:
                errors.append(
                    f"{identifier}: Ledger 缺少声明更新项：{', '.join(missing_entries)}"
                )
            if not declared <= changed_entries:
                errors.append(f"{identifier}: 声明的 Coverage entry 必须实际发生变化")
            undeclared = sorted(changed_entries - declared)
            if undeclared:
                errors.append(
                    f"{identifier}: 修改了未声明的 Coverage entry：{', '.join(undeclared)}"
                )
            section_baselines = snapshot.get("entry_section_sha256", {})
            for entry_id, expected_sections in updates.items():
                entry = entries.get(entry_id)
                before_sections = section_baselines.get(entry_id, {})
                if not isinstance(entry, dict) or not isinstance(before_sections, dict):
                    continue
                if sha256_json(entry.get("claim_ref")) != before_sections.get("claim_ref"):
                    errors.append(f"{identifier}#{entry_id}: claim_ref 不可变")
                actual_changed: Set[str] = set()
                for section in (
                    "validation",
                    "product_disposition",
                    "delivery",
                    "computed",
                ):
                    if sha256_json(entry.get(section)) != before_sections.get(section):
                        actual_changed.add(section)
                    if section in expected_sections and entry.get(section) != expected_sections[section]:
                        errors.append(
                            f"{identifier}#{entry_id}: {section} 未达到 Work Item 声明值"
                        )
                if actual_changed != set(expected_sections):
                    errors.append(
                        f"{identifier}#{entry_id}: 实际变化 section 与声明不一致 "
                        f"expected={sorted(expected_sections)}, actual={sorted(actual_changed)}"
                    )
                errors.extend(
                    self.knowledge_entry_reference_issues(
                        item_id, item, runtime, identifier, entry_id, entry
                    )
                )
        return errors

    def required_close_gates(
        self,
        item_id: str,
        item: Dict[str, Any],
        changed_paths: Sequence[str],
    ) -> Tuple[List[str], List[str]]:
        spec = item.get("spec", {})
        contracts, contract_errors = self.decision_gate_contracts(item)
        structured = spec.get("gate_contract_version") == 1
        gates = {
            gate
            for gate, contract in contracts.items()
            if contract.get("trigger") == "always"
        } if structured else set(spec.get("gates", []))
        errors: List[str] = []
        errors.extend(contract_errors)

        def require_decision(gate: str, trigger: str) -> None:
            if not structured:
                gates.add(gate)
                return
            contract = contracts.get(gate)
            if contract is None or contract.get("trigger") not in {
                trigger,
                "always",
            }:
                errors.append(
                    "UNSTRUCTURED_DECISION_REQUIRED: "
                    f"{gate} 需要 trigger={trigger} 的 v1 decision contract"
                )
                return
            gates.add(gate)

        def trigger_declared_decision(gate: str, trigger: str) -> None:
            """Proposal-only changes are reviewable, but not authority gates by default."""
            if not structured:
                return
            contract = contracts.get(gate)
            if contract is not None and contract.get("trigger") in {
                trigger,
                "always",
            }:
                gates.add(gate)

        expected_proposals = set(self.knowledge_proposal_paths(item))
        transitions = (
            spec
            .get("knowledge", {})
            .get("expected_ledger_transitions", [])
        )
        if any(
            "product_disposition" in update.get("set", {})
            for transition in transitions
            if isinstance(transition, dict)
            for update in transition.get("entry_updates", [])
            if isinstance(update, dict)
        ):
            require_decision("product-scope-review", "product-scope-change")
        for relative in changed_paths:
            if relative in expected_proposals:
                trigger_declared_decision(
                    "knowledge-review",
                    "knowledge-proposal-change",
                )
                if path_matches(
                    relative,
                    ["ios/project/business-knowledge/drivers/proposals/**"],
                ):
                    trigger_declared_decision(
                        "architecture-review",
                        "architecture-proposal-change",
                    )
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
            require_decision("oracle-adjudication", "oracle-difference")
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
        *,
        requested_at: Optional[str] = None,
        preexisting_fingerprints: Optional[Dict[str, str]] = None,
        evidence_sha256: Optional[str] = None,
    ) -> List[str]:
        errors: List[str] = []
        work_item_hash = sha256_json(item)
        contracts, contract_errors = self.decision_gate_contracts(item)
        structured = item.get("spec", {}).get("gate_contract_version") == 1
        errors.extend(contract_errors)
        request_time: Optional[dt.datetime] = None
        if requested_at is not None:
            try:
                request_time = dt.datetime.fromisoformat(
                    requested_at.replace("Z", "+00:00")
                )
                if request_time.tzinfo is None:
                    errors.append("approval_requested_at 必须含时区")
                    request_time = None
            except (TypeError, ValueError):
                errors.append("approval_requested_at 无效")
        for gate in gates:
            path = self.resolve(self.config["approvals_dir"]) / f"{item_id}--{gate}.json"
            try:
                approval = load_json(path)
            except HarnessError:
                errors.append(f"缺少人工批准：{gate}")
                continue
            relative = self.relative(path)
            if (
                preexisting_fingerprints is not None
                and preexisting_fingerprints.get(relative)
                == self.file_fingerprint(relative)
            ):
                errors.append(f"approval 未在本次人工请求后更新：{gate}")
            if approval.get("work_item_id") != item_id or approval.get("gate") != gate:
                errors.append(f"approval 与工作项/gate 不匹配：{gate}")
            if approval.get("work_item_sha256") != work_item_hash or approval.get("tree_sha256") != tree_sha256:
                errors.append(f"approval 未绑定当前 spec/tree：{gate}")
            if structured:
                contract = contracts.get(gate)
                if contract is None:
                    errors.append(f"decision contract 缺失：{gate}")
                else:
                    expected_contract_hash = sha256_json(contract)
                    if (
                        approval.get("decision_contract_sha256")
                        != expected_contract_hash
                    ):
                        errors.append(f"decision contract 摘要漂移：{gate}")
                    options = {
                        option.get("id")
                        for option in contract.get("options", [])
                        if isinstance(option, dict)
                    }
                    if approval.get("selected_option") not in options:
                        errors.append(f"decision selected_option 无效：{gate}")
                if (
                    not isinstance(evidence_sha256, str)
                    or approval.get("evidence_sha256") != evidence_sha256
                ):
                    errors.append(f"decision 未绑定当前 Evidence：{gate}")
            reviewer = approval.get("reviewer")
            if not isinstance(reviewer, str) or not reviewer.strip() or reviewer.lower().startswith("ai"):
                errors.append(f"approval reviewer 无效：{gate}")
            approved: Optional[dt.datetime] = None
            try:
                approved = dt.datetime.fromisoformat(
                    str(approval.get("approved_at")).replace("Z", "+00:00")
                )
                if approved.tzinfo is None:
                    errors.append(f"approval approved_at 必须含时区：{gate}")
                elif request_time is not None and approved < request_time:
                    errors.append(f"approval 早于本次人工请求：{gate}")
            except (TypeError, ValueError):
                errors.append(f"approval approved_at 无效：{gate}")
            if structured:
                presented: Optional[dt.datetime] = None
                decided: Optional[dt.datetime] = None
                try:
                    presented = dt.datetime.fromisoformat(
                        str(approval.get("presented_at")).replace("Z", "+00:00")
                    )
                    if presented.tzinfo is None:
                        errors.append(f"decision presented_at 必须含时区：{gate}")
                except (TypeError, ValueError):
                    errors.append(f"decision presented_at 无效：{gate}")
                try:
                    decided = dt.datetime.fromisoformat(
                        str(approval.get("decided_at")).replace("Z", "+00:00")
                    )
                    if decided.tzinfo is None:
                        errors.append(f"decision decided_at 必须含时区：{gate}")
                except (TypeError, ValueError):
                    errors.append(f"decision decided_at 无效：{gate}")
                if (
                    presented is not None
                    and decided is not None
                    and decided < presented
                ):
                    errors.append(f"decision decided_at 早于 presented_at：{gate}")
                if (
                    approved is not None
                    and decided is not None
                    and approved != decided
                ):
                    errors.append(f"decision decided_at 与 approved_at 不一致：{gate}")
                if (
                    request_time is not None
                    and presented is not None
                    and presented < request_time
                ):
                    errors.append(f"decision presented_at 早于请求：{gate}")
            try:
                expires = dt.datetime.fromisoformat(str(approval.get("expires_at")).replace("Z", "+00:00"))
                if expires.tzinfo is None:
                    errors.append(f"approval expires_at 必须含时区：{gate}")
                elif expires <= dt.datetime.now(dt.timezone.utc):
                    errors.append(f"approval 已过期：{gate}")
            except (TypeError, ValueError):
                errors.append(f"approval expires_at 无效：{gate}")
        return errors

    def recovery_binding_issues(
        self,
        item_id: str,
        item: Dict[str, Any],
        items: Dict[str, Dict[str, Any]],
        state: Dict[str, Any],
    ) -> List[str]:
        predecessor_id = item.get("spec", {}).get("recovers")
        if predecessor_id is None:
            return []
        errors: List[str] = []
        if not isinstance(predecessor_id, str):
            return [f"{item_id}: recovers 必须是单个 Work Item ID"]
        predecessor = items.get(predecessor_id)
        predecessor_runtime = state.get("work_items", {}).get(predecessor_id)
        if not isinstance(predecessor, dict) or not isinstance(
            predecessor_runtime,
            dict,
        ):
            return [f"{item_id}: recovers predecessor 不存在：{predecessor_id}"]
        if (
            predecessor.get("spec", {}).get("capability")
            != item.get("spec", {}).get("capability")
        ):
            errors.append(f"{item_id}: recovers capability 不一致：{predecessor_id}")
        if predecessor_runtime.get("status") not in RECOVERABLE_STATUSES:
            errors.append(
                f"{item_id}: recovers predecessor 必须处于可恢复终态，"
                f"当前 {predecessor_id}={predecessor_runtime.get('status')}"
            )
        existing = predecessor_runtime.get("replacement")
        if existing not in {None, item_id}:
            errors.append(
                f"{item_id}: predecessor 已绑定不同 replacement："
                f"{predecessor_id}->{existing}"
            )

        chain: List[str] = []
        current = item_id
        while current not in chain:
            chain.append(current)
            runtime = state.get("work_items", {}).get(current)
            replacement = (
                runtime.get("replacement")
                if isinstance(runtime, dict)
                else None
            )
            if not isinstance(replacement, str) or not replacement:
                break
            if replacement == predecessor_id:
                errors.append(
                    f"{item_id}: recovery replacement 会成环："
                    + " -> ".join([predecessor_id, *chain, predecessor_id])
                )
                break
            current = replacement
        return errors

    def recovery_candidate_issues(
        self,
        item_id: str,
        item: Dict[str, Any],
        items: Dict[str, Dict[str, Any]],
        state: Dict[str, Any],
    ) -> List[str]:
        predecessor_id = item.get("spec", {}).get("recovers")
        if predecessor_id is None:
            return []
        if not isinstance(predecessor_id, str):
            return [f"{item_id}: recovers 必须是单个 Work Item ID"]
        errors: List[str] = []
        predecessor = items.get(predecessor_id)
        state_items = state.get("work_items", {})
        predecessor_runtime = state_items.get(predecessor_id)
        if not isinstance(predecessor, dict) or not isinstance(
            predecessor_runtime,
            dict,
        ):
            return [f"{item_id}: recovers predecessor 不存在：{predecessor_id}"]
        if (
            predecessor.get("spec", {}).get("capability")
            != item.get("spec", {}).get("capability")
        ):
            errors.append(f"{item_id}: recovers capability 不一致：{predecessor_id}")
        if predecessor_runtime.get("status") not in RECOVERABLE_STATUSES:
            errors.append(
                f"{item_id}: recovers predecessor 必须处于可恢复终态，"
                f"当前 {predecessor_id}={predecessor_runtime.get('status')}"
            )
        existing = predecessor_runtime.get("replacement")
        if existing is not None:
            errors.append(
                f"{item_id}: predecessor 已绑定 replacement："
                f"{predecessor_id}->{existing}"
            )

        prospective = dict(items)
        prospective[item_id] = item
        errors.extend(self.detect_recovery_cycles(prospective))
        competing = sorted(
            candidate_id
            for candidate_id, candidate in items.items()
            if candidate_id != item_id
            and candidate.get("spec", {}).get("recovers") == predecessor_id
            and state_items.get(candidate_id, {}).get("status")
            not in {
                "blocked",
                "rejected",
                "exhausted",
                "cancelled",
                "superseded",
            }
        )
        if competing:
            errors.append(
                f"{item_id}: predecessor 已有未终结 recovery："
                + ", ".join(competing)
            )
        return errors

    def bind_recovery(
        self,
        item_id: str,
        item: Dict[str, Any],
        state: Dict[str, Any],
        runtime: Dict[str, Any],
    ) -> None:
        predecessor_id = item.get("spec", {}).get("recovers")
        if not isinstance(predecessor_id, str):
            return
        items = self.work_items()
        bindings: List[Tuple[str, str]] = []
        replacement_id = item_id
        seen: Set[str] = {item_id}
        while isinstance(predecessor_id, str) and predecessor_id:
            if predecessor_id in seen:
                raise HarnessError(
                    "recovery lineage 在完成绑定时成环："
                    + " -> ".join([*seen, predecessor_id])
                )
            seen.add(predecessor_id)
            predecessor_runtime = state["work_items"].get(
                predecessor_id
            )
            if not isinstance(predecessor_runtime, dict):
                raise HarnessError(
                    f"recovery lineage predecessor 不存在：{predecessor_id}"
                )
            existing = predecessor_runtime.get("replacement")
            if existing not in {None, replacement_id}:
                raise HarnessError(
                    "recovery lineage predecessor 已绑定不同 replacement："
                    f"{predecessor_id}->{existing}"
                )
            bindings.append((predecessor_id, replacement_id))
            predecessor_item = items.get(predecessor_id, {})
            ancestor = predecessor_item.get("spec", {}).get("recovers")
            if (
                predecessor_runtime.get("status")
                not in RECOVERABLE_STATUSES
                or not isinstance(ancestor, str)
                or not ancestor
            ):
                break
            replacement_id = predecessor_id
            predecessor_id = ancestor

        bound_at = utc_now()
        for predecessor_id, replacement_id in bindings:
            predecessor_runtime = state["work_items"][predecessor_id]
            predecessor_runtime["replacement"] = replacement_id
            predecessor_runtime["replacement_bound_at"] = bound_at
            replacement_item = items.get(replacement_id, item)
            self.append_event(
                "WorkItemRecoveryBound",
                predecessor_id,
                {
                    "replacement": replacement_id,
                    "resolution": item_id,
                    "recovery_work_item_sha256": sha256_json(
                        replacement_item
                    ),
                    "evidence": runtime["last_evidence"],
                    "evidence_sha256": runtime.get(
                        "last_evidence_sha256"
                    ),
                },
            )

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
        memory_errors.extend(self.knowledge_close_issues(item_id, item, runtime))

        current_changed = self.changed_since_claim(runtime)
        required_gates, dynamic_gate_errors = self.required_close_gates(item_id, item, current_changed)
        architecture_kind = checkpoint.get("architecture_impact", {}).get("kind")
        if architecture_kind == "changes_architecture":
            contracts, _ = self.decision_gate_contracts(item)
            architecture_decision = contracts.get("architecture-review")
            if item["spec"].get("gate_contract_version") == 1:
                if architecture_decision is None:
                    dynamic_gate_errors.append(
                        "UNSTRUCTURED_DECISION_REQUIRED: "
                        "架构变化必须声明 architecture-review decision contract"
                    )
                elif "architecture-review" not in required_gates:
                    required_gates.append("architecture-review")
                    required_gates.sort()
            elif "architecture-review" not in required_gates:
                dynamic_gate_errors.append("架构变化工作项必须声明人工 gate")
        managed = self.managed_paths()
        memory_patterns = [
            f"ios/project/capabilities/{item['spec']['capability']}.json",
            f"ios/project/checkpoints/{item_id}.json",
            "ios/project/compatibility/COMP-*.json",
            "ios/project/pitfalls/PIT-*.json",
        ] + self.knowledge_ledger_paths(item)
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

        try:
            self.refresh_business_knowledge_catalog()
        except HarnessError as error:
            memory_errors.append(f"Business Knowledge memory 无效：{error}")
        recovery_errors = self.recovery_binding_issues(
            item_id,
            item,
            items,
            state,
        )
        all_errors = (
            checkpoint_errors
            + memory_errors
            + close_scope_errors
            + dynamic_gate_errors
            + recovery_errors
        )
        all_errors.extend(self.memory_issues(items, state))
        if all_errors:
            raise HarnessError("close 前记忆事务无效：\n- " + "\n- ".join(all_errors))

        review_subject_sha256, review_subject_files = self.candidate_snapshot(runtime, approval_paths)
        frozen_subject = runtime.get("review_subject_sha256")
        if frozen_subject is not None and frozen_subject != review_subject_sha256:
            raise HarnessError("候选内容在请求人工批准后发生变化；旧批准主题已失效，必须重新 verify")
        if required_gates and not isinstance(
            runtime.get("approval_requested_at"),
            str,
        ):
            runtime["approval_requested_at"] = utc_now()
            runtime["approval_request_existing_fingerprints"] = {
                path: self.file_fingerprint(path)
                for path in approval_paths
            }
        approval_errors = self.approval_issues(
            item_id,
            item,
            review_subject_sha256,
            required_gates,
            requested_at=runtime.get("approval_requested_at"),
            preexisting_fingerprints=runtime.get(
                "approval_request_existing_fingerprints"
            ),
            evidence_sha256=runtime.get("last_evidence_sha256"),
        )
        if approval_errors:
            runtime["status"] = "awaiting_human"
            runtime["awaiting_human_reasons"] = approval_errors
            runtime["review_subject_sha256"] = review_subject_sha256
            runtime["review_subject_files"] = review_subject_files
            self.append_event("HumanApprovalRequired", item_id, {"reasons": approval_errors, "review_subject_sha256": review_subject_sha256})
            self.write_state(state, items)
            return "awaiting_human"

        final_tree_sha256, _ = self.snapshot_hash()
        commit_subject_sha256, _ = self.candidate_snapshot(
            runtime,
            approval_paths,
        )
        if commit_subject_sha256 != review_subject_sha256:
            raise HarnessError(
                "候选在批准校验与完成提交之间发生变化；停止完成并重新 verify"
            )
        self.bind_recovery(item_id, item, state, runtime)
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
        business_knowledge_context = self.business_knowledge_selection(item)
        adr_paths: Dict[str, str] = {}
        for path in sorted(self.resolve("ios/docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
            match = re.search(r"^id:\s*(ADR-[0-9]{4})\s*$", path.read_text(encoding="utf-8"), re.MULTILINE)
            if match:
                adr_paths[match.group(1)] = self.relative(path)
        referenced_adrs = set(capability.get("active_decisions", []))
        referenced_adrs.update(ref for ref in item["spec"].get("architecture_refs", []) if ref.startswith("ADR-"))
        if isinstance(business_knowledge_context, dict):
            for driver in business_knowledge_context.get("drivers", []):
                resolution = driver.get("resolution") if isinstance(driver, dict) else None
                if isinstance(resolution, dict):
                    referenced_adrs.update(resolution.get("adr_refs", []))
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
        if business_knowledge_context is not None:
            read_order.append("ios/docs/business-knowledge-control-plane.md")
            read_order.extend(business_knowledge_context.get("required_paths", []))
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
            "business_knowledge": business_knowledge_context,
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

    review = subparsers.add_parser(
        "review",
        help="打开本地人工审批页（仅 awaiting_human；无非交互 approve 入口）",
    )
    review.add_argument("item_id")

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
        if args.command == "review":
            try:
                if __package__:
                    from .approval_ui import ApprovalUIError as LocalApprovalUIError
                    from .approval_ui import run_local_review
                else:
                    from approval_ui import ApprovalUIError as LocalApprovalUIError
                    from approval_ui import run_local_review
            except ImportError as error:
                raise HarnessError(f"无法加载本地审批 UI：{error}") from error
            try:
                outcome = run_local_review(harness, args.item_id)
            except LocalApprovalUIError as error:
                raise HarnessError(str(error)) from error
            print(f"{args.item_id}: {outcome}")
            return 0
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
