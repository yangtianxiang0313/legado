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
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Optional, Sequence, Tuple


CONTROL_ROOT = Path("ios/harness/android-intake")
POLICY_PATH = CONTROL_ROOT / "policy-v1.json"
INVENTORY_PATH = Path("ios/project/android-intake/inventory-manifest.json")
CATALOG_PATH = Path("ios/project/requirements/catalog.json")
REQUIREMENTS_ROOT = Path("ios/project/requirements/accepted")
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


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


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
    match = re.search(
        rf"\b(?:suspend\s+)?fun\s+(?:[A-Za-z_][A-Za-z0-9_.<>?]*\.)?"
        rf"{re.escape(symbol)}\s*\(",
        text,
    )
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


def extract_room_query(text: str, symbol: str) -> Tuple[Dict[str, Any], int, int]:
    function = re.search(rf"\bfun\s+{re.escape(symbol)}\s*\(", text)
    if function is None:
        raise IntakeError(f"找不到 Kotlin Room query function：{symbol}")
    query = None
    for candidate in re.finditer(r"@Query\s*\(", text[: function.start()]):
        query = candidate
    if query is None:
        raise IntakeError(f"找不到 Room @Query：{symbol}")
    opening = text.find("(", query.start())
    closing = matching_delimiter(text, opening, "(", ")")
    if closing > function.start():
        raise IntakeError(f"Room @Query 与 function 绑定无效：{symbol}")
    if re.search(r"@\w+", text[closing + 1 : function.start()]):
        raise IntakeError(f"Room @Query 与 function 之间存在其他 annotation：{symbol}")
    annotation = text[opening + 1 : closing].strip()
    triple = re.fullmatch(r'"""(.*)"""', annotation, flags=re.DOTALL)
    quoted = re.fullmatch(r'"((?:\\.|[^"\\])*)"', annotation, flags=re.DOTALL)
    if triple is not None:
        sql = triple.group(1)
    elif quoted is not None:
        sql = bytes(quoted.group(1), "utf-8").decode("unicode_escape")
    else:
        raise IntakeError(f"Room @Query 必须使用静态字符串：{symbol}")
    function_open = text.find("(", function.start())
    function_close = matching_delimiter(text, function_open, "(", ")")
    signature_end = text.find("\n", function_close)
    if signature_end < 0:
        signature_end = len(text)
    payload = {
        "kind": "kotlin_room_query",
        "symbol": symbol,
        "signature": normalize_space(text[function.start() : signature_end]),
        "sql": normalize_space(sql),
    }
    return (
        payload,
        line_number(text, query.start()),
        line_number(text, signature_end),
    )


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
    paths = [
        root / CONTROL_ROOT / "android_intake.py",
        root / POLICY_PATH,
        root / "ios/harness/schemas/android-requirement.schema.json",
    ]
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
        elif extractor == "kotlin_room_query":
            payload, start_line, end_line = extract_room_query(text, symbol)
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


def manifest_bundle(root: Path) -> Dict[str, Any]:
    inventory = inventory_value(root)
    catalog = catalog_value(root, inventory)
    return {"inventory": inventory, "catalog": catalog}


def doctor(root: Path) -> List[str]:
    errors: List[str] = []
    try:
        bundle = manifest_bundle(root)
        if load_json(root / INVENTORY_PATH) != bundle["inventory"]:
            errors.append("Android fact inventory 已过期")
        if load_json(root / CATALOG_PATH) != bundle["catalog"]:
            errors.append("Requirement catalog 已过期")
    except IntakeError as error:
        errors.append(str(error))
    return errors


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Android Requirement Intake")
    parser.add_argument("command", choices=["inventory", "catalog", "manifest", "doctor"])
    parser.add_argument("--root", default=".")
    parser.add_argument(
        "--write",
        action="store_true",
        help="原子更新命令对应的生成文件",
    )
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    try:
        if args.command == "inventory":
            value = inventory_value(root)
            if args.write:
                write_json(root / INVENTORY_PATH, value)
        elif args.command == "catalog":
            value = catalog_value(root)
            if args.write:
                write_json(root / CATALOG_PATH, value)
        elif args.command == "manifest":
            value = manifest_bundle(root)
            if args.write:
                write_json(root / INVENTORY_PATH, value["inventory"])
                write_json(root / CATALOG_PATH, value["catalog"])
        else:
            if args.write:
                raise IntakeError("doctor 不支持 --write")
            errors = doctor(root)
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
