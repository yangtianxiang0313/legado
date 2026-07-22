"""Executable implementation of the protected canonical-v1 contract."""

from __future__ import annotations

from copy import deepcopy
from pathlib import Path

from oracle.exact_json import JSONNode, NumberToken, dumps, loads


class CanonicalizationError(ValueError):
    pass


def load_config(path: Path) -> dict[str, JSONNode]:
    value = loads(path.read_bytes())
    if not isinstance(value, dict):
        raise CanonicalizationError("canonicalizer config must be an object")
    expected = {
        "schema_version",
        "id",
        "normalize",
        "ignore_json_pointers",
        "global_fuzzy_matching",
    }
    if set(value) != expected:
        raise CanonicalizationError("canonicalizer config fields changed")
    if not isinstance(value["schema_version"], NumberToken) or value["schema_version"].token != "1":
        raise CanonicalizationError("unsupported canonicalizer schema")
    if value["id"] != "canonical-v1" or value["global_fuzzy_matching"] is not False:
        raise CanonicalizationError("canonical-v1 identity/fuzzy policy mismatch")
    if value["normalize"] != [
        "http_header_names_ascii_lowercase",
        "json_object_keys_sorted",
        "line_endings_lf",
    ]:
        raise CanonicalizationError("canonical-v1 normalization policy mismatch")
    if value["ignore_json_pointers"] != [
        "/trace_id",
        "/timing",
        "/environment/run_started_at",
    ]:
        raise CanonicalizationError("canonical-v1 ignore policy mismatch")
    return value


def canonicalize_bytes(data: bytes, config: dict[str, JSONNode]) -> bytes:
    return dumps(canonicalize_node(loads(data), config))


def canonicalize_node(value: JSONNode, config: dict[str, JSONNode]) -> JSONNode:
    result = _normalize_lines(deepcopy(value))
    targets = [result]
    if isinstance(result, dict) and isinstance(result.get("artifact"), dict):
        targets.append(result["artifact"])
    for target in targets:
        _normalize_request_headers(target)
        for pointer in config["ignore_json_pointers"]:
            if not isinstance(pointer, str):
                raise CanonicalizationError("ignore pointer must be a string")
            _remove_pointer(target, pointer)
    return result


def _normalize_lines(value: JSONNode) -> JSONNode:
    if isinstance(value, str):
        return value.replace("\r\n", "\n").replace("\r", "\n")
    if isinstance(value, list):
        return [_normalize_lines(item) for item in value]
    if isinstance(value, dict):
        return {key: _normalize_lines(item) for key, item in value.items()}
    return value


def _normalize_request_headers(value: JSONNode) -> None:
    if not isinstance(value, dict) or not isinstance(value.get("request_plan"), list):
        return
    for request in value["request_plan"]:
        if not isinstance(request, dict) or not isinstance(request.get("headers"), list):
            continue
        for header in request["headers"]:
            if isinstance(header, dict) and isinstance(header.get("name"), str):
                header["name"] = _ascii_lower(header["name"])


def _ascii_lower(value: str) -> str:
    return "".join(chr(ord(char) + 32) if "A" <= char <= "Z" else char for char in value)


def _remove_pointer(value: JSONNode, pointer: str) -> None:
    if not pointer.startswith("/"):
        raise CanonicalizationError(f"invalid JSON pointer: {pointer}")
    parts = [part.replace("~1", "/").replace("~0", "~") for part in pointer[1:].split("/")]
    current = value
    for part in parts[:-1]:
        if not isinstance(current, dict) or part not in current:
            return
        current = current[part]
    if isinstance(current, dict):
        current.pop(parts[-1], None)
