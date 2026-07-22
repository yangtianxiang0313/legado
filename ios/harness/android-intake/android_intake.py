#!/usr/bin/env python3
"""Deterministic Android source fact inventory and requirement catalog validator.

The extractor intentionally supports a small allow-listed surface. It records
syntax facts and production entry-point anchors; it does not infer runtime
semantics or generate expected iOS results.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


CONTROL_ROOT = Path("ios/harness/android-intake")
POLICY_PATH = CONTROL_ROOT / "policy-v1.json"
INVENTORY_PATH = Path("ios/project/android-intake/inventory-manifest.json")
CATALOG_PATH = Path("ios/project/requirements/catalog.json")
REQUIREMENTS_ROOT = Path("ios/project/requirements/accepted")
WORK_ITEMS_ROOT = Path("ios/harness/work-items")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
FACT_ID_RE = re.compile(r"^AF-[A-Z0-9-]+$")
REQUIREMENT_ID_RE = re.compile(r"^REQ-[A-Z0-9-]+$")


class IntakeError(RuntimeError):
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
        raise IntakeError(f"缺少文件：{path}") from error
    except json.JSONDecodeError as error:
        raise IntakeError(f"JSON 无效：{path}: {error}") from error


def safe_repo_path(value: str) -> str:
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or ".." in path.parts or "." in path.parts:
        raise IntakeError(f"Android anchor 必须是仓库内相对路径：{value}")
    return path.as_posix()


def run_git(root: Path, argv: Sequence[str], binary: bool = False) -> Any:
    result = subprocess.run(
        ["git", *argv],
        cwd=str(root),
        capture_output=True,
        text=not binary,
        check=False,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace") if binary else result.stderr
        raise IntakeError(f"git {' '.join(argv)} 失败：{stderr.strip()}")
    return result.stdout


def git_blob(root: Path, commit: str, relative: str) -> Tuple[bytes, str]:
    if COMMIT_RE.fullmatch(commit) is None:
        raise IntakeError(f"Android baseline commit 无效：{commit}")
    path = safe_repo_path(relative)
    data = run_git(root, ["show", f"{commit}:{path}"], binary=True)
    blob = run_git(root, ["rev-parse", f"{commit}:{path}"]).strip()
    if re.fullmatch(r"[0-9a-f]{40,64}", blob) is None:
        raise IntakeError(f"Android blob ID 无效：{path}")
    return data, blob


def matching_delimiter(text: str, opening: int, open_char: str, close_char: str) -> int:
    if opening >= len(text) or text[opening] != open_char:
        raise IntakeError(f"无法定位平衡分隔符：{open_char}")
    depth = 0
    index = opening
    quote: Optional[str] = None
    triple = False
    escaped = False
    line_comment = False
    block_comment = False
    while index < len(text):
        char = text[index]
        next_two = text[index : index + 2]
        next_three = text[index : index + 3]
        if line_comment:
            if char == "\n":
                line_comment = False
            index += 1
            continue
        if block_comment:
            if next_two == "*/":
                block_comment = False
                index += 2
            else:
                index += 1
            continue
        if quote is not None:
            if triple and next_three == quote * 3:
                quote = None
                triple = False
                index += 3
                continue
            if not triple:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            index += 1
            continue
        if next_two == "//":
            line_comment = True
            index += 2
            continue
        if next_two == "/*":
            block_comment = True
            index += 2
            continue
        if char in {'"', "'"}:
            quote = char
            triple = char == '"' and next_three == '"""'
            index += 3 if triple else 1
            continue
        if char == open_char:
            depth += 1
        elif char == close_char:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    raise IntakeError(f"分隔符未闭合：{open_char}{close_char}")


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def normalize_space(value: str) -> str:
    return " ".join(value.strip().split())


def extract_constructor(text: str, symbol: str) -> Tuple[Dict[str, Any], int, int]:
    match = re.search(rf"\bdata\s+class\s+{re.escape(symbol)}\b", text)
    if match is None:
        raise IntakeError(f"找不到 Kotlin data class：{symbol}")
    opening = text.find("(", match.end())
    if opening < 0:
        raise IntakeError(f"找不到 data class 主构造器：{symbol}")
    closing = matching_delimiter(text, opening, "(", ")")
    constructor = text[opening + 1 : closing]
    property_pattern = re.compile(
        r"^\s*(?:override\s+)?(?:var|val)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^=,\n]+?)"
        r"(?:\s*=\s*([^,\n]+))?\s*,?\s*(?://.*)?$",
        re.MULTILINE,
    )
    properties = []
    for property_match in property_pattern.finditer(constructor):
        default = property_match.group(3)
        properties.append(
            {
                "name": property_match.group(1),
                "type": normalize_space(property_match.group(2)),
                "default": normalize_space(default) if default is not None else None,
            }
        )
    if not properties:
        raise IntakeError(f"data class 未提取到属性：{symbol}")
    payload = {"kind": "kotlin_primary_constructor", "symbol": symbol, "properties": properties}
    return payload, line_number(text, match.start()), line_number(text, closing)


def extract_function(text: str, symbol: str) -> Tuple[Dict[str, Any], int, int]:
    match = re.search(rf"\b(?:suspend\s+)?fun\s+{re.escape(symbol)}\s*\(", text)
    if match is None:
        raise IntakeError(f"找不到 Kotlin function：{symbol}")
    opening = text.find("(", match.start())
    closing = matching_delimiter(text, opening, "(", ")")
    body_open = text.find("{", closing)
    if body_open < 0:
        raise IntakeError(f"找不到 Kotlin function body：{symbol}")
    body_close = matching_delimiter(text, body_open, "{", "}")
    signature = normalize_space(text[match.start() : body_open])
    body = text[body_open + 1 : body_close]
    normalized_body = re.sub(r"/\*.*?\*/", " ", body, flags=re.DOTALL)
    normalized_body = re.sub(r"//[^\n]*", " ", normalized_body)
    normalized_body = normalize_space(normalized_body)
    payload = {
        "kind": "kotlin_function_entrypoint",
        "symbol": symbol,
        "signature": signature,
        "body_semantic_sha256": sha256_bytes(normalized_body.encode("utf-8")),
    }
    return payload, line_number(text, match.start()), line_number(text, body_close)


def policy_value(root: Path) -> Dict[str, Any]:
    value = load_json(root / POLICY_PATH)
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise IntakeError("Android intake policy 无效")
    sensors = value.get("sensors")
    if not isinstance(sensors, list) or not sensors:
        raise IntakeError("Android intake policy.sensors 必须是非空数组")
    return value


def baseline_commit(root: Path) -> str:
    baseline = load_json(root / "ios/project/baseline.json")
    commit = baseline.get("android_oracle", {}).get("git_commit") if isinstance(baseline, dict) else None
    if not isinstance(commit, str) or COMMIT_RE.fullmatch(commit) is None:
        raise IntakeError("baseline.android_oracle.git_commit 必须是 40 位 commit")
    return commit


def control_digest(root: Path) -> str:
    paths: List[Path] = []
    control = root / CONTROL_ROOT
    for path in control.rglob("*"):
        if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        paths.append(path)
    for name in ("android-requirement.schema.json", "work-item.schema.json"):
        paths.append(root / "ios/harness/schemas" / name)
    entries = []
    for path in sorted(set(paths)):
        entries.append(
            {
                "path": path.relative_to(root).as_posix(),
                "sha256": sha256_bytes(path.read_bytes()),
                "bytes": path.stat().st_size,
            }
        )
    return sha256_json(entries)


def inventory_value(root: Path) -> Dict[str, Any]:
    policy = policy_value(root)
    commit = baseline_commit(root)
    tree = run_git(root, ["rev-parse", f"{commit}^{{tree}}"]).strip()
    facts: List[Dict[str, Any]] = []
    seen: set[str] = set()
    for sensor in policy["sensors"]:
        if not isinstance(sensor, dict):
            raise IntakeError("Android intake sensor 必须是 object")
        fact_id = sensor.get("fact_id")
        if not isinstance(fact_id, str) or FACT_ID_RE.fullmatch(fact_id) is None or fact_id in seen:
            raise IntakeError(f"Android fact ID 无效或重复：{fact_id}")
        seen.add(fact_id)
        relative = safe_repo_path(str(sensor.get("path", "")))
        symbol = sensor.get("symbol")
        extractor = sensor.get("extractor")
        if not isinstance(symbol, str) or not symbol:
            raise IntakeError(f"{fact_id}: symbol 不能为空")
        data, blob_sha = git_blob(root, commit, relative)
        text = data.decode("utf-8")
        if extractor == "kotlin_primary_constructor":
            payload, start_line, end_line = extract_constructor(text, symbol)
        elif extractor == "kotlin_function_entrypoint":
            payload, start_line, end_line = extract_function(text, symbol)
        else:
            raise IntakeError(f"{fact_id}: 未知 extractor：{extractor}")
        maps_to = sensor.get("maps_to")
        if not isinstance(maps_to, list) or not maps_to or any(
            not isinstance(value, str) or REQUIREMENT_ID_RE.fullmatch(value) is None for value in maps_to
        ):
            raise IntakeError(f"{fact_id}: maps_to 必须引用至少一个 Requirement")
        facts.append(
            {
                "id": fact_id,
                "fact_key": sensor.get("fact_key"),
                "category": sensor.get("category"),
                "evidence_level": sensor.get("evidence_level"),
                "support_state": sensor.get("support_state"),
                "extractor": extractor,
                "symbol_id": sensor.get("symbol_id"),
                "path": relative,
                "git_blob": blob_sha,
                "source_sha256": sha256_bytes(data),
                "start_line": start_line,
                "end_line": end_line,
                "payload": payload,
                "revision_sha256": sha256_json(payload),
                "maps_to": sorted(set(maps_to)),
            }
        )
    return {
        "schema_version": 1,
        "android_git_commit": commit,
        "android_tree": tree,
        "control_sha256": control_digest(root),
        "policy_sha256": sha256_json(policy),
        "facts": sorted(facts, key=lambda value: value["id"]),
    }


def requirement_records(root: Path) -> List[Dict[str, Any]]:
    records = []
    for path in sorted((root / REQUIREMENTS_ROOT).glob("REQ-*.json")):
        value = load_json(path)
        if not isinstance(value, dict):
            raise IntakeError(f"Requirement 必须是 object：{path}")
        if value.get("id") != path.stem:
            raise IntakeError(f"Requirement 文件名与 ID 不一致：{path}")
        records.append(value)
    if not records:
        raise IntakeError("没有 accepted Requirement")
    return records


def validate_requirement(record: Dict[str, Any], facts: Dict[str, Dict[str, Any]]) -> List[str]:
    errors: List[str] = []
    requirement_id = record.get("id")
    if not isinstance(requirement_id, str) or REQUIREMENT_ID_RE.fullmatch(requirement_id) is None:
        return [f"Requirement ID 无效：{requirement_id}"]
    if record.get("schema_version") != 1 or record.get("status") != "accepted":
        errors.append(f"{requirement_id}: accepted Requirement schema/status 无效")
    if not isinstance(record.get("revision"), int) or record.get("revision", 0) < 1:
        errors.append(f"{requirement_id}: revision 无效")
    if not isinstance(record.get("semantic_key"), str) or not record.get("semantic_key"):
        errors.append(f"{requirement_id}: semantic_key 不能为空")
    origin = record.get("origin")
    if not isinstance(origin, dict):
        errors.append(f"{requirement_id}: origin 必须是 object")
        return errors
    kind = origin.get("kind")
    fact_refs = origin.get("fact_refs")
    decision_refs = origin.get("decision_refs")
    if kind not in {"android_observed", "ios_product_decision", "ios_enabler"}:
        errors.append(f"{requirement_id}: origin.kind 无效")
    if not isinstance(fact_refs, list) or any(not isinstance(value, str) for value in fact_refs):
        errors.append(f"{requirement_id}: origin.fact_refs 必须是字符串数组")
        fact_refs = []
    if not isinstance(decision_refs, list) or any(not isinstance(value, str) for value in decision_refs):
        errors.append(f"{requirement_id}: origin.decision_refs 必须是字符串数组")
        decision_refs = []
    if kind == "android_observed" and not fact_refs:
        errors.append(f"{requirement_id}: android_observed 必须引用 Android fact")
    if kind != "android_observed" and not decision_refs:
        errors.append(f"{requirement_id}: iOS 需求必须引用设计决策")
    for fact_id in fact_refs:
        fact = facts.get(fact_id)
        if fact is None:
            errors.append(f"{requirement_id}: 引用未知 fact：{fact_id}")
        elif requirement_id not in fact.get("maps_to", []):
            errors.append(f"{requirement_id}: policy 未将 fact 映射到本需求：{fact_id}")
    clauses = record.get("clauses")
    if not isinstance(clauses, list) or not clauses:
        errors.append(f"{requirement_id}: clauses 不能为空")
    else:
        clause_ids = []
        for clause in clauses:
            if not isinstance(clause, dict) or not isinstance(clause.get("id"), str):
                errors.append(f"{requirement_id}: clause 无效")
                continue
            clause_ids.append(clause["id"])
            if not isinstance(clause.get("statement"), str) or not clause.get("statement"):
                errors.append(f"{requirement_id}: clause statement 不能为空")
            if clause.get("proof_kind") not in {
                "static_source",
                "android_oracle",
                "architecture_decision",
                "human_adjudication",
            }:
                errors.append(f"{requirement_id}: clause proof_kind 无效")
        if len(clause_ids) != len(set(clause_ids)):
            errors.append(f"{requirement_id}: clause ID 重复")
    return errors


def catalog_value(root: Path, inventory: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    inventory = inventory or inventory_value(root)
    facts = {entry["id"]: entry for entry in inventory["facts"]}
    records = requirement_records(root)
    entries = []
    errors: List[str] = []
    semantic_keys: set[str] = set()
    ids: set[str] = set()
    for record in records:
        errors.extend(validate_requirement(record, facts))
        requirement_id = record.get("id")
        if requirement_id in ids:
            errors.append(f"Requirement ID 重复：{requirement_id}")
        ids.add(requirement_id)
        semantic_key = record.get("semantic_key")
        if semantic_key in semantic_keys:
            errors.append(f"Requirement semantic_key 重复：{semantic_key}")
        semantic_keys.add(semantic_key)
        fact_refs = record.get("origin", {}).get("fact_refs", [])
        fact_selection = [facts[fact_id] for fact_id in sorted(fact_refs) if fact_id in facts]
        entries.append(
            {
                "id": requirement_id,
                "revision": record.get("revision"),
                "status": record.get("status"),
                "semantic_key": semantic_key,
                "origin_kind": record.get("origin", {}).get("kind"),
                "readiness": record.get("readiness", {}).get("state"),
                "path": f"{REQUIREMENTS_ROOT.as_posix()}/{requirement_id}.json",
                "record_sha256": sha256_json(record),
                "fact_selection_sha256": sha256_json(fact_selection),
                "clauses": sorted(
                    clause.get("id") for clause in record.get("clauses", []) if isinstance(clause, dict)
                ),
            }
        )
    for fact in inventory["facts"]:
        for requirement_id in fact.get("maps_to", []):
            if requirement_id not in ids:
                errors.append(f"{fact['id']}: maps_to 未发布 Requirement：{requirement_id}")
    if errors:
        raise IntakeError("Requirement catalog 无效：\n- " + "\n- ".join(errors))
    return {
        "schema_version": 1,
        "android_git_commit": inventory["android_git_commit"],
        "inventory_sha256": sha256_json(inventory),
        "requirements": sorted(entries, key=lambda value: value["id"]),
    }


def requirement_selection(root: Path, item: Dict[str, Any], inventory: Dict[str, Any], catalog: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    requirement_spec = item.get("spec", {}).get("requirements", {}) if isinstance(item, dict) else {}
    if not isinstance(requirement_spec, dict):
        raise IntakeError("工作项 requirements 必须是 object")
    mode = requirement_spec.get("mode")
    refs = requirement_spec.get("refs")
    none_reason = requirement_spec.get("none_reason")
    if mode == "control_plane":
        if refs != [] or not isinstance(none_reason, str) or not none_reason.strip():
            raise IntakeError("control_plane 工作项必须清空 refs 并填写 none_reason")
        return None
    if mode not in {"implementation", "enabler", "characterization", "verification"}:
        raise IntakeError(f"工作项 requirements.mode 无效：{mode}")
    if not isinstance(refs, list) or not refs or none_reason is not None:
        raise IntakeError("非 control_plane 工作项必须引用 Requirement，none_reason 为 null")
    catalog_index = {entry["id"]: entry for entry in catalog["requirements"]}
    records = {record["id"]: record for record in requirement_records(root)}
    facts = {entry["id"]: entry for entry in inventory["facts"]}
    selected = []
    for ref in refs:
        if not isinstance(ref, dict) or set(ref) != {"id", "revision", "clauses"}:
            raise IntakeError("Requirement ref 必须精确包含 id/revision/clauses")
        requirement_id = ref.get("id")
        entry = catalog_index.get(requirement_id)
        record = records.get(requirement_id)
        if entry is None or record is None:
            raise IntakeError(f"工作项引用未发布 Requirement：{requirement_id}")
        if ref.get("revision") != entry.get("revision"):
            raise IntakeError(f"工作项 Requirement revision 已过期：{requirement_id}")
        clauses = ref.get("clauses")
        if not isinstance(clauses, list) or not clauses or any(not isinstance(value, str) for value in clauses):
            raise IntakeError(f"{requirement_id}: clauses 必须是非空字符串数组")
        known_clauses = {clause["id"]: clause for clause in record["clauses"]}
        unknown = sorted(set(clauses) - set(known_clauses))
        if unknown:
            raise IntakeError(f"{requirement_id}: 工作项引用未知 clause：{', '.join(unknown)}")
        if mode == "implementation" and record.get("readiness", {}).get("state") != "implementation_ready":
            raise IntakeError(f"{requirement_id}: 尚未达到 implementation_ready")
        fact_refs = record.get("origin", {}).get("fact_refs", [])
        selected.append(
            {
                "ref": ref,
                "catalog_entry": entry,
                "clauses": [known_clauses[clause_id] for clause_id in sorted(set(clauses))],
                "facts": [facts[fact_id] for fact_id in sorted(fact_refs)],
            }
        )
    return {
        "schema_version": 1,
        "mode": mode,
        "android_git_commit": inventory["android_git_commit"],
        "control_sha256": inventory["control_sha256"],
        "requirements": sorted(selected, key=lambda value: value["ref"]["id"]),
    }


def validate_work_item(root: Path, work_item_id: str, inventory: Dict[str, Any], catalog: Dict[str, Any]) -> List[str]:
    errors: List[str] = []
    try:
        item = load_json(root / WORK_ITEMS_ROOT / f"{work_item_id}.json")
        selection = requirement_selection(root, item, inventory, catalog)
        requirement_spec = item.get("spec", {}).get("requirements", {})
        if selection is not None:
            referenced_clauses = {
                f"{ref.get('id')}#{clause}"
                for ref in requirement_spec.get("refs", [])
                for clause in ref.get("clauses", [])
                if isinstance(clause, str)
            }
            criteria = item.get("spec", {}).get("acceptance", {}).get("criteria", [])
            covered: set[str] = set()
            for criterion in criteria:
                clauses = criterion.get("requirement_clauses") if isinstance(criterion, dict) else None
                if not isinstance(clauses, list):
                    errors.append(f"{work_item_id}: 每条 AC 必须声明 requirement_clauses")
                    continue
                covered.update(value for value in clauses if isinstance(value, str))
            missing = sorted(referenced_clauses - covered)
            extra = sorted(covered - referenced_clauses)
            if missing:
                errors.append(f"{work_item_id}: Requirement clause 未映射 AC：{', '.join(missing)}")
            if extra:
                errors.append(f"{work_item_id}: AC 引用未选择 Requirement clause：{', '.join(extra)}")
    except IntakeError as error:
        errors.append(f"{work_item_id}: {error}")
    return errors


def manifest_bundle(root: Path) -> Dict[str, Any]:
    inventory = inventory_value(root)
    catalog = catalog_value(root, inventory)
    return {"inventory": inventory, "catalog": catalog}


def doctor(root: Path, work_item_id: Optional[str]) -> List[str]:
    errors: List[str] = []
    try:
        bundle = manifest_bundle(root)
        if load_json(root / INVENTORY_PATH) != bundle["inventory"]:
            errors.append("Android fact inventory 已过期")
        if load_json(root / CATALOG_PATH) != bundle["catalog"]:
            errors.append("Requirement catalog 已过期")
        work_items: Iterable[Path]
        if work_item_id:
            work_items = [root / WORK_ITEMS_ROOT / f"{work_item_id}.json"]
        else:
            work_items = sorted((root / WORK_ITEMS_ROOT).glob("*.json"))
        for path in work_items:
            if not path.exists():
                errors.append(f"未知工作项：{path.stem}")
                continue
            errors.extend(validate_work_item(root, path.stem, bundle["inventory"], bundle["catalog"]))
    except IntakeError as error:
        errors.append(str(error))
    return errors


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Android Requirement Intake")
    parser.add_argument("command", choices=["inventory", "catalog", "manifest", "doctor", "selection"])
    parser.add_argument("--root", default=".")
    parser.add_argument("--work-item")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        if args.command == "inventory":
            value = inventory_value(root)
        elif args.command == "catalog":
            value = catalog_value(root)
        elif args.command == "manifest":
            value = manifest_bundle(root)
        elif args.command == "selection":
            if not args.work_item:
                raise IntakeError("selection 需要 --work-item")
            bundle = manifest_bundle(root)
            item = load_json(root / WORK_ITEMS_ROOT / f"{args.work_item}.json")
            selection = requirement_selection(root, item, bundle["inventory"], bundle["catalog"])
            value = {
                "selection": selection,
                "selection_sha256": sha256_json(selection) if selection is not None else None,
            }
        else:
            errors = doctor(root, args.work_item)
            if errors:
                for error in errors:
                    print(error, file=sys.stderr)
                return 1
            print("android-intake: OK")
            return 0
        print(json.dumps(value, ensure_ascii=False, indent=2))
        return 0
    except (IntakeError, UnicodeDecodeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
