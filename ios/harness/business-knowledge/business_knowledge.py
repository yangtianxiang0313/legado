#!/usr/bin/env python3
"""Deterministic Business Knowledge control for the Legado iOS migration.

This tool is deliberately read-only. AI work items may create proposals, but
publishing a packet or architecture driver remains a trusted promotion action.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_ROOT = Path(__file__).resolve().parents[3]
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
PACKET_ID = re.compile(r"^BKP-[A-Z][A-Z0-9-]*-[0-9]{3}$")
CLAIM_ID = re.compile(r"^BKC-[A-Z][A-Z0-9-]*-[0-9]{3}$")
DRIVER_ID = re.compile(r"^DRV-[A-Z][A-Z0-9-]*-[0-9]{3}$")
LEDGER_ID = re.compile(r"^BKL-[A-Z][A-Z0-9-]*-[0-9]{3}$")
ENTRY_ID = re.compile(r"^BKE-[A-Z][A-Z0-9-]*-[0-9]{3}$")


class KnowledgeError(RuntimeError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_json(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value))


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise KnowledgeError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise KnowledgeError(
            f"JSON 无效：{path}:{error.lineno}:{error.colno}: {error.msg}"
        ) from error


def relative(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def _matches_type(value: Any, name: str) -> bool:
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    return True


def validate_schema(value: Any, schema: Dict[str, Any], location: str = "$") -> List[str]:
    errors: List[str] = []
    expected = schema.get("type")
    if expected is not None:
        names = expected if isinstance(expected, list) else [expected]
        if not any(_matches_type(value, name) for name in names):
            return [f"{location}: 类型应为 {names}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{location}: 必须等于 {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{location}: 值不在 enum {schema['enum']}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{location}: 字符串过短")
        pattern = schema.get("pattern")
        if isinstance(pattern, str) and re.fullmatch(pattern, value) is None:
            errors.append(f"{location}: 不匹配 pattern {pattern}")
    if isinstance(value, int) and not isinstance(value, bool):
        if value < schema.get("minimum", value):
            errors.append(f"{location}: 小于 minimum {schema['minimum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{location}: 数组项不足")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{location}: 数组项过多")
        if schema.get("uniqueItems"):
            encoded = [canonical_bytes(entry) for entry in value]
            if len(encoded) != len(set(encoded)):
                errors.append(f"{location}: 数组项必须唯一")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, entry in enumerate(value):
                errors.extend(validate_schema(entry, item_schema, f"{location}[{index}]"))
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{location}: 缺少必填字段 {key}")
        if schema.get("additionalProperties") is False:
            unknown = sorted(set(value) - set(properties))
            for key in unknown:
                errors.append(f"{location}: 未知字段 {key}")
        for key, child_schema in properties.items():
            if key in value and isinstance(child_schema, dict):
                errors.extend(validate_schema(value[key], child_schema, f"{location}.{key}"))
    return errors


def _control_dir(root: Path) -> Path:
    return root / "ios/harness/business-knowledge"


def _project_dir(root: Path) -> Path:
    return root / "ios/project/business-knowledge"


def _policy(root: Path) -> Dict[str, Any]:
    value = load_json(_control_dir(root) / "policy-v1.json")
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise KnowledgeError("Business Knowledge policy 无效")
    return value


def _schema(root: Path, name: str) -> Dict[str, Any]:
    value = load_json(_control_dir(root) / "schemas" / name)
    if not isinstance(value, dict):
        raise KnowledgeError(f"schema 必须是 object：{name}")
    return value


def _record(path: Path, root: Path) -> Dict[str, Any]:
    value = load_json(path)
    if not isinstance(value, dict):
        raise KnowledgeError(f"记录必须是 object：{relative(root, path)}")
    return {
        "path": relative(root, path),
        "sha256": sha256_bytes(path.read_bytes()),
        "record": value,
    }


def _records(root: Path, directory: str, pattern: str) -> List[Dict[str, Any]]:
    base = root / directory
    if not base.exists():
        return []
    return [_record(path, root) for path in sorted(base.rglob(pattern)) if path.is_file()]


def _accepted_adrs(root: Path) -> set[str]:
    result: set[str] = set()
    for path in sorted((root / "ios/docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
        text = path.read_text(encoding="utf-8")
        id_match = re.search(r"^id:\s*(ADR-[0-9]{4})\s*$", text, re.MULTILINE)
        status = re.search(r"^status:\s*([a-z_]+)\s*$", text, re.MULTILINE)
        if id_match and status and status.group(1) == "accepted":
            result.add(id_match.group(1))
    return result


def _current(records: Iterable[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    result: Dict[str, Dict[str, Any]] = {}
    for entry in records:
        record = entry["record"]
        identifier = record.get("id")
        revision = record.get("revision")
        if not isinstance(identifier, str) or not isinstance(revision, int):
            continue
        existing = result.get(identifier)
        if existing is None or revision > existing["record"].get("revision", 0):
            result[identifier] = entry
    return result


def _revision_issues(
    records: Sequence[Dict[str, Any]],
    identifier_pattern: re.Pattern[str],
    kind: str,
) -> List[str]:
    errors: List[str] = []
    grouped: Dict[str, Dict[int, Dict[str, Any]]] = {}
    for entry in records:
        record = entry["record"]
        identifier = record.get("id")
        revision = record.get("revision")
        if not isinstance(identifier, str) or identifier_pattern.fullmatch(identifier) is None:
            continue
        if not isinstance(revision, int):
            continue
        revisions = grouped.setdefault(identifier, {})
        if revision in revisions:
            errors.append(f"{kind} revision 重复：{identifier}@{revision}")
        revisions[revision] = entry
    for identifier, revisions in grouped.items():
        ordered = sorted(revisions)
        if ordered != list(range(1, max(ordered) + 1)):
            errors.append(f"{kind} revision 不连续：{identifier} -> {ordered}")
        for revision in ordered:
            supersedes = revisions[revision]["record"].get("supersedes")
            expected = None if revision == 1 else {"id": identifier, "revision": revision - 1}
            if supersedes != expected:
                errors.append(
                    f"{kind} supersedes 无效：{identifier}@{revision} expected={expected}"
                )
    return errors


def _claim_revision_issues(packet_entries: Sequence[Dict[str, Any]]) -> List[str]:
    errors: List[str] = []
    grouped: Dict[str, Dict[int, bytes]] = {}
    records: Dict[Tuple[str, int], Dict[str, Any]] = {}
    for packet in packet_entries:
        for claim in packet["record"].get("claims", []):
            identifier, revision = claim.get("id"), claim.get("revision")
            if not isinstance(identifier, str) or not isinstance(revision, int):
                continue
            encoded = canonical_bytes(claim)
            prior = grouped.setdefault(identifier, {}).get(revision)
            if prior is not None and prior != encoded:
                errors.append(f"Claim 同 ID/revision 内容不一致：{identifier}@{revision}")
            grouped[identifier][revision] = encoded
            records[(identifier, revision)] = claim
    for identifier, revisions in grouped.items():
        ordered = sorted(revisions)
        if ordered != list(range(1, max(ordered) + 1)):
            errors.append(f"Claim revision 不连续：{identifier} -> {ordered}")
        for revision in ordered:
            expected = None if revision == 1 else {"id": identifier, "revision": revision - 1}
            if records[(identifier, revision)].get("supersedes") != expected:
                errors.append(
                    f"Claim supersedes 无效：{identifier}@{revision} expected={expected}"
                )
    return errors


def _path_issues(entry: Dict[str, Any], authority: str, kind: str) -> List[str]:
    record = entry["record"]
    identifier = record.get("id")
    revision = record.get("revision")
    path = Path(entry["path"])
    errors: List[str] = []
    if kind in {"packet", "driver"}:
        expected_name = f"r{revision:04d}.json" if isinstance(revision, int) else None
        if path.parent.name != identifier or path.name != expected_name:
            errors.append(f"{entry['path']}: ID/revision 与路径不一致")
    elif kind == "ledger" and path.name != f"{identifier}.json":
        errors.append(f"{entry['path']}: Ledger ID 与文件名不一致")
    if authority == "proposal":
        expected_segment = "proposals"
    elif kind == "ledger":
        expected_segment = "coverage"
    else:
        expected_segment = "published"
    if expected_segment not in path.parts:
        errors.append(f"{entry['path']}: authority 目录不一致")
    return errors


def _graph(root: Path) -> Tuple[Dict[str, Any], List[str]]:
    policy = _policy(root)
    directories = policy["directories"]
    data = {
        "policy": policy,
        "packets_published": _records(root, directories["published_packets"], "r*.json"),
        "packets_proposals": _records(root, directories["packet_proposals"], "r*.json"),
        "drivers_published": _records(root, directories["published_drivers"], "r*.json"),
        "drivers_proposals": _records(root, directories["driver_proposals"], "r*.json"),
        "ledgers": _records(root, directories["coverage"], "BKL-*.json"),
    }
    errors: List[str] = []
    baseline = load_json(root / "ios/project/baseline.json")
    inventory = load_json(root / "ios/project/android-intake/inventory-manifest.json")
    requirement_catalog = load_json(root / "ios/project/requirements/catalog.json")
    if not all(isinstance(value, dict) for value in (baseline, inventory, requirement_catalog)):
        raise KnowledgeError("baseline/inventory/requirement catalog 必须是 object")
    android_commit = baseline.get("android_oracle", {}).get("git_commit")
    inventory_control = inventory.get("control_sha256")
    requirement_catalog_sha256 = sha256_json(requirement_catalog)
    architecture_digest = baseline.get("architecture", {}).get("digest")
    facts = {
        fact.get("id"): fact
        for fact in inventory.get("facts", [])
        if isinstance(fact, dict) and isinstance(fact.get("id"), str)
    }
    capabilities = {
        path.stem
        for path in (root / "ios/project/capabilities").glob("CAP-*.json")
    }

    packet_schema = _schema(root, "business-knowledge-packet.schema.json")
    driver_schema = _schema(root, "architecture-driver.schema.json")
    ledger_schema = _schema(root, "coverage-ledger.schema.json")
    all_packets = data["packets_published"] + data["packets_proposals"]
    all_drivers = data["drivers_published"] + data["drivers_proposals"]
    errors.extend(_revision_issues(all_packets, PACKET_ID, "Packet"))
    errors.extend(_revision_issues(all_drivers, DRIVER_ID, "Driver"))
    errors.extend(_claim_revision_issues(all_packets))

    for authority, entries in (
        ("published", data["packets_published"]),
        ("proposal", data["packets_proposals"]),
    ):
        for entry in entries:
            record = entry["record"]
            errors.extend(f"{entry['path']}: {error}" for error in validate_schema(record, packet_schema))
            errors.extend(_path_issues(entry, authority, "packet"))
            allowed_status = policy[
                "published_packet_statuses" if authority == "published" else "proposal_packet_statuses"
            ]
            if record.get("status") not in allowed_status:
                errors.append(f"{entry['path']}: Packet status 与 authority 不一致")
            packet_baseline = record.get("baseline", {})
            if packet_baseline.get("android_commit") != android_commit:
                errors.append(f"{entry['path']}: Android baseline 不一致")
            if packet_baseline.get("inventory_control_sha256") != inventory_control:
                errors.append(f"{entry['path']}: Fact Inventory control 不一致")
            for capability_id in record.get("scope", {}).get("capability_refs", []):
                if capability_id not in capabilities:
                    errors.append(f"{entry['path']}: 未登记 capability {capability_id}")
            claim_ids: set[str] = set()
            semantic_keys: set[str] = set()
            for claim in record.get("claims", []):
                claim_id = claim.get("id")
                semantic_key = claim.get("semantic_key")
                if claim_id in claim_ids:
                    errors.append(f"{entry['path']}: claim ID 重复 {claim_id}")
                if semantic_key in semantic_keys:
                    errors.append(f"{entry['path']}: claim semantic_key 重复 {semantic_key}")
                if isinstance(claim_id, str):
                    claim_ids.add(claim_id)
                if isinstance(semantic_key, str):
                    semantic_keys.add(semantic_key)
                support = claim.get("support", {})
                fact_refs = support.get("fact_refs", [])
                for fact_ref in fact_refs:
                    fact = facts.get(fact_ref.get("id")) if isinstance(fact_ref, dict) else None
                    if fact is None:
                        errors.append(f"{entry['path']}: claim 引用未知 Fact {fact_ref}")
                    elif fact_ref.get("revision_sha256") != fact.get("revision_sha256"):
                        errors.append(f"{entry['path']}: Fact revision 漂移 {fact_ref.get('id')}")
                for anchor in support.get("source_anchors", []):
                    if anchor.get("android_commit") != android_commit:
                        errors.append(f"{entry['path']}: source anchor baseline 不一致")
                for evidence in support.get("runtime_evidence", []):
                    if evidence.get("android_commit") != android_commit:
                        errors.append(f"{entry['path']}: runtime evidence baseline 不一致")
                if authority == "published" and claim.get("kind") == "composite_static_fact" and not fact_refs:
                    errors.append(f"{entry['path']}: published composite_static_fact 必须引用受控 Fact")
                if support.get("state") == "static_supported" and not fact_refs:
                    errors.append(f"{entry['path']}: static_supported 必须引用受控 Fact")
                if support.get("state") == "runtime_verified":
                    supporting = [
                        evidence
                        for evidence in support.get("runtime_evidence", [])
                        if evidence.get("relation") == "supports"
                        and evidence.get("kind") == "android_characterization"
                    ]
                    if not supporting:
                        errors.append(
                            f"{entry['path']}: runtime_verified 缺少 Android characterization Evidence；"
                            "real-source capture 只能提供真实输入，不能单独定义运行语义"
                        )

    current_packets = _current(data["packets_published"])
    current_claims: Dict[Tuple[str, int], Dict[str, Any]] = {}
    claim_semantic_keys: Dict[str, str] = {}
    claim_packet: Dict[Tuple[str, int], Dict[str, Any]] = {}
    for packet_entry in current_packets.values():
        for claim in packet_entry["record"].get("claims", []):
            key = (claim.get("id"), claim.get("revision"))
            if key in current_claims:
                errors.append(f"当前 published claim 重复：{key[0]}@{key[1]}")
            current_claims[key] = claim
            claim_packet[key] = packet_entry
            semantic_key = claim.get("semantic_key")
            if isinstance(semantic_key, str) and semantic_key in claim_semantic_keys:
                errors.append(
                    f"当前 claim semantic_key 冲突：{semantic_key} "
                    f"({claim_semantic_keys[semantic_key]}, {key[0]})"
                )
            elif isinstance(semantic_key, str):
                claim_semantic_keys[semantic_key] = str(key[0])
    for key, claim in current_claims.items():
        for dependency in claim.get("depends_on", []):
            dep_key = (dependency.get("id"), dependency.get("revision"))
            if dep_key not in current_claims:
                errors.append(f"claim 依赖不存在或非 current：{key[0]} -> {dep_key[0]}@{dep_key[1]}")
        for conflict in claim.get("conflicts_with", []):
            conflict_key = (conflict.get("id"), conflict.get("revision"))
            if conflict_key not in current_claims:
                errors.append(f"claim 冲突引用不存在：{key[0]} -> {conflict_key[0]}@{conflict_key[1]}")
        if claim.get("conflicts_with") and claim.get("support", {}).get("state") != "disputed":
            errors.append(f"存在 conflicts_with 的 claim 必须标记 disputed：{key[0]}@{key[1]}")

    accepted_adrs = _accepted_adrs(root)
    for authority, entries in (
        ("published", data["drivers_published"]),
        ("proposal", data["drivers_proposals"]),
    ):
        for entry in entries:
            record = entry["record"]
            errors.extend(f"{entry['path']}: {error}" for error in validate_schema(record, driver_schema))
            errors.extend(_path_issues(entry, authority, "driver"))
            allowed_status = policy[
                "published_driver_statuses" if authority == "published" else "proposal_driver_statuses"
            ]
            if record.get("status") not in allowed_status:
                errors.append(f"{entry['path']}: Driver status 与 authority 不一致")
            if authority == "published" and not isinstance(record.get("promotion"), dict):
                errors.append(f"{entry['path']}: published Driver 缺少 promotion")
            elif authority == "published" and any(
                not isinstance(record["promotion"].get(key), str)
                or not record["promotion"].get(key, "").strip()
                for key in ("approval_ref", "approved_by")
            ):
                errors.append(f"{entry['path']}: published Driver promotion 无效")
            if authority == "proposal" and record.get("promotion") is not None:
                errors.append(f"{entry['path']}: proposal Driver 不得伪造 promotion")
            for reference in record.get("claim_refs", []):
                key = (reference.get("id"), reference.get("revision"))
                if key not in current_claims:
                    errors.append(f"{entry['path']}: Driver 引用不存在或非 current claim {key}")
            resolution = record.get("resolution", {})
            if resolution.get("state") in {"resolved", "accepted_risk"}:
                adr_refs = resolution.get("adr_refs", [])
                if not adr_refs or any(adr not in accepted_adrs for adr in adr_refs):
                    errors.append(f"{entry['path']}: resolved Driver 必须引用 accepted ADR")

    current_drivers = _current(data["drivers_published"])
    driver_semantic_keys: Dict[str, str] = {}
    for identifier, entry in current_drivers.items():
        semantic_key = entry["record"].get("semantic_key")
        if isinstance(semantic_key, str) and semantic_key in driver_semantic_keys:
            errors.append(
                f"当前 Driver semantic_key 冲突：{semantic_key} "
                f"({driver_semantic_keys[semantic_key]}, {identifier})"
            )
        elif isinstance(semantic_key, str):
            driver_semantic_keys[semantic_key] = identifier

    authority_sha256 = _authority_digest(
        root,
        policy,
        android_commit,
        inventory_control,
        data["packets_published"],
        data["drivers_published"],
    )
    ledger_entries_by_claim: Dict[Tuple[str, int], List[Tuple[Dict[str, Any], Dict[str, Any]]]] = {}
    ledger_entry_ids: set[str] = set()
    ledger_ids: set[str] = set()
    for entry in data["ledgers"]:
        record = entry["record"]
        errors.extend(f"{entry['path']}: {error}" for error in validate_schema(record, ledger_schema))
        errors.extend(_path_issues(entry, "coverage", "ledger"))
        if record.get("generated_from", {}).get("knowledge_authority_sha256") != authority_sha256:
            errors.append(f"{entry['path']}: knowledge authority digest 已过期")
        if record.get("id") in ledger_ids:
            errors.append(f"Coverage Ledger ID 重复：{record.get('id')}")
        ledger_ids.add(record.get("id"))
        generated = record.get("generated_from", {})
        if generated.get("requirement_catalog_sha256") != requirement_catalog_sha256:
            errors.append(f"{entry['path']}: Requirement catalog digest 已过期")
        if generated.get("architecture_digest_sha256") != architecture_digest:
            errors.append(f"{entry['path']}: architecture digest 已过期")
        for packet_ref in record.get("packet_refs", []):
            current = current_packets.get(packet_ref.get("id"))
            if current is None or current["record"].get("revision") != packet_ref.get("revision"):
                errors.append(f"{entry['path']}: packet_ref 不存在或非 current {packet_ref}")
        for ledger_entry in record.get("entries", []):
            entry_id = ledger_entry.get("id")
            if entry_id in ledger_entry_ids:
                errors.append(f"Coverage entry ID 重复：{entry_id}")
            if isinstance(entry_id, str):
                ledger_entry_ids.add(entry_id)
            claim_ref = ledger_entry.get("claim_ref", {})
            key = (claim_ref.get("id"), claim_ref.get("revision"))
            if key not in current_claims:
                errors.append(f"{entry['path']}: Ledger 引用不存在或非 current claim {key}")
            ledger_entries_by_claim.setdefault(key, []).append((entry, ledger_entry))
            disposition = ledger_entry.get("product_disposition", {})
            if disposition.get("kind") in policy.get("terminal_dispositions", []):
                if not disposition.get("refs") or not disposition.get("reason"):
                    errors.append(f"{entry['path']}: terminal disposition 必须引用裁决并说明原因")
            validation = ledger_entry.get("validation", {})
            delivery = ledger_entry.get("delivery", {})
            computed = ledger_entry.get("computed", {})
            claim = current_claims.get(key, {})
            if claim.get("support", {}).get("state") == "disputed" or validation.get("state") == "disputed":
                expected_coverage = "conflicted"
            elif validation.get("blockers") or delivery.get("state") == "blocked":
                expected_coverage = "blocked"
            elif not computed.get("accounted") or (
                validation.get("required") != "none" and validation.get("state") == "missing"
            ):
                expected_coverage = "gap"
            else:
                expected_coverage = "covered"
            if computed.get("coverage_state") != expected_coverage:
                errors.append(
                    f"{entry['path']}#{entry_id}: coverage_state 应为 {expected_coverage}"
                )
    for key in sorted(current_claims):
        matches = ledger_entries_by_claim.get(key, [])
        if len(matches) != 1:
            errors.append(f"published claim 必须恰有一个 Coverage entry：{key[0]}@{key[1]}")

    data.update(
        {
            "baseline": baseline,
            "inventory": inventory,
            "android_commit": android_commit,
            "inventory_control": inventory_control,
            "requirement_catalog_sha256": requirement_catalog_sha256,
            "architecture_digest": architecture_digest,
            "current_packets": current_packets,
            "current_claims": current_claims,
            "claim_packet": claim_packet,
            "current_drivers": current_drivers,
            "ledger_entries_by_claim": ledger_entries_by_claim,
            "authority_sha256": authority_sha256,
        }
    )
    return data, errors


def _record_manifest(entries: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    return [
        {
            "id": entry["record"].get("id"),
            "revision": entry["record"].get("revision"),
            "path": entry["path"],
            "sha256": entry["sha256"],
        }
        for entry in sorted(
            entries,
            key=lambda value: (
                str(value["record"].get("id")),
                int(value["record"].get("revision", 0)),
                value["path"],
            ),
        )
    ]


def _authority_digest(
    root: Path,
    policy: Dict[str, Any],
    android_commit: Any,
    inventory_control: Any,
    packets: Sequence[Dict[str, Any]],
    drivers: Sequence[Dict[str, Any]],
) -> str:
    return sha256_json(
        {
            "schema_version": 1,
            "android_commit": android_commit,
            "inventory_control_sha256": inventory_control,
            "policy_sha256": sha256_json(policy),
            "packets": _record_manifest(packets),
            "drivers": _record_manifest(drivers),
        }
    )


def control_sha256(root: Path) -> str:
    control_dir = _control_dir(root)
    control_paths = list(
        path
        for path in control_dir.rglob("*")
        if path.is_file() and path.name != "__pycache__" and path.suffix != ".pyc"
    )
    harness_path = root / "ios/harness/harness.py"
    if harness_path.is_file():
        control_paths.append(harness_path)
    entries = []
    for path in sorted(control_paths):
        entries.append({"path": relative(root, path), "sha256": sha256_bytes(path.read_bytes())})
    return sha256_json(entries)


def catalog_value(root: Path) -> Dict[str, Any]:
    data, errors = _graph(root)
    if errors:
        raise KnowledgeError("Business Knowledge 图无效：\n- " + "\n- ".join(errors))
    packets = []
    for identifier, entry in sorted(data["current_packets"].items()):
        record = entry["record"]
        packets.append(
            {
                "id": identifier,
                "revision": record["revision"],
                "semantic_key": record["semantic_key"],
                "path": entry["path"],
                "record_sha256": entry["sha256"],
                "claim_refs": [
                    {"id": claim["id"], "revision": claim["revision"]}
                    for claim in sorted(record["claims"], key=lambda value: value["id"])
                ],
            }
        )
    drivers = []
    for identifier, entry in sorted(data["current_drivers"].items()):
        record = entry["record"]
        drivers.append(
            {
                "id": identifier,
                "revision": record["revision"],
                "semantic_key": record["semantic_key"],
                "path": entry["path"],
                "record_sha256": entry["sha256"],
                "resolution_state": record["resolution"]["state"],
            }
        )
    ledgers = [
        {
            "id": entry["record"]["id"],
            "revision": entry["record"]["revision"],
            "path": entry["path"],
            "record_sha256": entry["sha256"],
            "entry_ids": sorted(value["id"] for value in entry["record"]["entries"]),
        }
        for entry in sorted(data["ledgers"], key=lambda value: value["record"]["id"])
    ]
    proposal_records = data["packets_proposals"] + data["drivers_proposals"]
    return {
        "schema_version": 1,
        "contract_version": data["policy"]["contract_version"],
        "android_git_commit": data["android_commit"],
        "inventory_control_sha256": data["inventory_control"],
        "policy_sha256": sha256_json(data["policy"]),
        "control_sha256": control_sha256(root),
        "authority_sha256": data["authority_sha256"],
        "coverage_sha256": sha256_json(_record_manifest(data["ledgers"])),
        "proposal_sha256": sha256_json(_record_manifest(proposal_records)),
        "packets": packets,
        "architecture_drivers": drivers,
        "coverage_ledgers": ledgers,
        "proposals": _record_manifest(proposal_records),
    }


def doctor(root: Path, *, check_catalog: bool = True) -> List[str]:
    try:
        _, errors = _graph(root)
        expected = catalog_value(root) if not errors else None
    except KnowledgeError as error:
        return [str(error)]
    if check_catalog and expected is not None:
        catalog_path = _project_dir(root) / "catalog.json"
        try:
            actual = load_json(catalog_path)
        except KnowledgeError as error:
            errors.append(str(error))
        else:
            if actual != expected:
                errors.append("Business Knowledge catalog 已过期")
    return errors


def _ref_key(reference: Dict[str, Any]) -> Tuple[Any, Any]:
    return reference.get("id"), reference.get("revision")


def selection_value(root: Path, work_item: Dict[str, Any]) -> Dict[str, Any]:
    errors = doctor(root)
    if errors:
        raise KnowledgeError("Business Knowledge doctor 未通过：\n- " + "\n- ".join(errors))
    data, _ = _graph(root)
    knowledge = work_item.get("spec", {}).get("knowledge")
    if not isinstance(knowledge, dict):
        return {
            "contract_version": None,
            "mode": "legacy",
            "control_sha256": catalog_value(root)["control_sha256"],
            "authority_sha256": data["authority_sha256"],
            "knowledge_selection_sha256": None,
            "coverage_selection_sha256": None,
            "architecture_driver_selection_sha256": None,
            "claims": [],
            "coverage": [],
            "drivers": [],
            "blocking_reasons": [],
            "required_paths": [],
        }
    mode = knowledge.get("mode")
    catalog = catalog_value(root)
    if mode == "not_applicable":
        return {
            "contract_version": knowledge.get("contract_version"),
            "mode": mode,
            "control_sha256": catalog["control_sha256"],
            "authority_sha256": catalog["authority_sha256"],
            "knowledge_selection_sha256": None,
            "coverage_selection_sha256": None,
            "architecture_driver_selection_sha256": None,
            "claims": [],
            "coverage": [],
            "drivers": [],
            "blocking_reasons": [],
            "required_paths": ["ios/project/business-knowledge/catalog.json"],
        }

    selected: Dict[Tuple[str, int], Dict[str, Any]] = {}

    def include(reference: Dict[str, Any]) -> None:
        key = _ref_key(reference)
        claim = data["current_claims"].get(key)
        if claim is None:
            raise KnowledgeError(f"claim 不存在或不是 current published revision：{key[0]}@{key[1]}")
        if key in selected:
            return
        selected[key] = claim
        for dependency in claim.get("depends_on", []):
            include(dependency)

    for reference in knowledge.get("claim_refs", []):
        include(reference)

    drivers: List[Dict[str, Any]] = []
    for reference in knowledge.get("driver_refs", []):
        driver = data["current_drivers"].get(reference.get("id"))
        if driver is None or driver["record"].get("revision") != reference.get("revision"):
            raise KnowledgeError(
                f"Architecture Driver 不存在或 revision 不匹配："
                f"{reference.get('id')}@{reference.get('revision')}"
            )
        drivers.append(driver)
        for claim_ref in driver["record"].get("claim_refs", []):
            include(claim_ref)

    coverage: List[Dict[str, Any]] = []
    covered_claims: set[Tuple[str, int]] = set()
    ledger_by_id = {entry["record"]["id"]: entry for entry in data["ledgers"]}
    for reference in knowledge.get("coverage_refs", []):
        ledger = ledger_by_id.get(reference.get("id"))
        if ledger is None or ledger["record"].get("revision") != reference.get("revision"):
            raise KnowledgeError(
                f"Coverage Ledger 不存在或 revision 不匹配："
                f"{reference.get('id')}@{reference.get('revision')}"
            )
        entries = {entry["id"]: entry for entry in ledger["record"].get("entries", [])}
        for entry_id in reference.get("entries", []):
            selected_entry = entries.get(entry_id)
            if selected_entry is None:
                raise KnowledgeError(f"Coverage entry 不存在：{reference.get('id')}#{entry_id}")
            claim_key = _ref_key(selected_entry["claim_ref"])
            if claim_key not in selected:
                raise KnowledgeError(
                    f"Coverage selection 包含未选择的 claim："
                    f"{reference.get('id')}#{entry_id} -> {claim_key[0]}@{claim_key[1]}"
                )
            covered_claims.add(claim_key)
            coverage.append(
                {
                    "ledger": {
                        "id": ledger["record"]["id"],
                        "revision": ledger["record"]["revision"],
                        "path": ledger["path"],
                        "sha256": ledger["sha256"],
                    },
                    "entry": selected_entry,
                }
            )
    missing_coverage = sorted(set(selected) - covered_claims)
    if missing_coverage:
        rendered = ", ".join(f"{item[0]}@{item[1]}" for item in missing_coverage)
        raise KnowledgeError(f"选中的 claim 缺少显式 Coverage selection：{rendered}")

    claims = []
    blocking_reasons: List[str] = []
    coverage_by_claim = {
        _ref_key(value["entry"]["claim_ref"]): value["entry"] for value in coverage
    }
    ready_support = set(data["policy"].get("implementation_ready_support", []))
    for key, claim in sorted(selected.items()):
        packet = data["claim_packet"][key]
        ledger_entry = coverage_by_claim.get(key)
        support_state = claim.get("support", {}).get("state")
        claims.append(
            {
                "ref": {"id": key[0], "revision": key[1]},
                "packet": {
                    "id": packet["record"]["id"],
                    "revision": packet["record"]["revision"],
                    "path": packet["path"],
                    "sha256": packet["sha256"],
                },
                "kind": claim.get("kind"),
                "statement": claim.get("statement"),
                "support_state": support_state,
                "disposition": (
                    ledger_entry.get("product_disposition") if isinstance(ledger_entry, dict) else None
                ),
            }
        )
        if support_state not in ready_support:
            blocking_reasons.append(f"{key[0]}@{key[1]} support={support_state}")
        coverage_state = (
            ledger_entry.get("computed", {}).get("coverage_state")
            if isinstance(ledger_entry, dict)
            else None
        )
        if coverage_state in {"stale", "conflicted", "blocked", "gap"}:
            blocking_reasons.append(f"{key[0]}@{key[1]} coverage={coverage_state}")
        disposition_kind = (
            ledger_entry.get("product_disposition", {}).get("kind")
            if isinstance(ledger_entry, dict)
            else None
        )
        if disposition_kind in data["policy"].get("terminal_dispositions", []):
            blocking_reasons.append(f"{key[0]}@{key[1]} disposition={disposition_kind}")
    driver_context = []
    for entry in sorted(drivers, key=lambda value: value["record"]["id"]):
        record = entry["record"]
        driver_context.append(
            {
                "ref": {"id": record["id"], "revision": record["revision"]},
                "path": entry["path"],
                "sha256": entry["sha256"],
                "title": record["title"],
                "forces": record["forces"],
                "decision_questions": record["decision_questions"],
                "resolution": record["resolution"],
            }
        )
        if record.get("resolution", {}).get("state") not in {"resolved", "accepted_risk"}:
            blocking_reasons.append(
                f"{record['id']}@{record['revision']} unresolved="
                f"{record.get('resolution', {}).get('state')}"
            )
    context_payload = {
        "claims": claims,
        "coverage": coverage,
        "drivers": driver_context,
    }
    budget = knowledge.get("context_budget", data["policy"]["default_context_budget"])
    if len(claims) > budget.get("max_claims", 40):
        raise KnowledgeError(
            f"CONTEXT_OVERSIZED: claims {len(claims)} > {budget.get('max_claims')}"
        )
    context_bytes = len(canonical_bytes(context_payload))
    if context_bytes > budget.get("max_bytes", 65536):
        raise KnowledgeError(
            f"CONTEXT_OVERSIZED: bytes {context_bytes} > {budget.get('max_bytes')}"
        )
    required_paths = {"ios/project/business-knowledge/catalog.json"}
    required_paths.update(value["packet"]["path"] for value in claims)
    required_paths.update(value["ledger"]["path"] for value in coverage)
    required_paths.update(value["path"] for value in driver_context)
    return {
        "contract_version": knowledge.get("contract_version"),
        "mode": mode,
        "control_sha256": catalog["control_sha256"],
        "authority_sha256": catalog["authority_sha256"],
        "knowledge_selection_sha256": sha256_json(claims) if claims else None,
        "coverage_selection_sha256": sha256_json(coverage) if coverage else None,
        "architecture_driver_selection_sha256": (
            sha256_json(driver_context) if driver_context else None
        ),
        "claims": claims,
        "coverage": coverage,
        "drivers": driver_context,
        "blocking_reasons": sorted(set(blocking_reasons)),
        "required_paths": sorted(required_paths),
    }


def _load_work_item(root: Path, item_id: str) -> Dict[str, Any]:
    path = root / "ios/harness/work-items" / f"{item_id}.json"
    value = load_json(path)
    if not isinstance(value, dict):
        raise KnowledgeError(f"Work Item 必须是 object：{item_id}")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Legado Business Knowledge control")
    subparsers = parser.add_subparsers(dest="command", required=True)
    doctor_parser = subparsers.add_parser("doctor")
    doctor_parser.add_argument("--root", default=str(DEFAULT_ROOT))
    manifest_parser = subparsers.add_parser("manifest")
    manifest_parser.add_argument("--root", default=str(DEFAULT_ROOT))
    selection_parser = subparsers.add_parser("selection")
    selection_parser.add_argument("--root", default=str(DEFAULT_ROOT))
    selection_parser.add_argument("--work-item", required=True)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    root = Path(args.root).resolve()
    try:
        if args.command == "doctor":
            errors = doctor(root)
            if errors:
                for error in errors:
                    print(error, file=sys.stderr)
                return 1
            print("business-knowledge: OK")
            return 0
        if args.command == "manifest":
            print(json.dumps(catalog_value(root), ensure_ascii=False, indent=2))
            return 0
        if args.command == "selection":
            item = _load_work_item(root, args.work_item)
            print(json.dumps(selection_value(root, item), ensure_ascii=False, indent=2))
            return 0
    except KnowledgeError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
