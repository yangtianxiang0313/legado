"""Strict JSON AST that preserves the spelling of every number token."""

from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from dataclasses import dataclass
from typing import Dict, List, Union


NUMBER = re.compile(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\Z")
MAX_JSON_BYTES = 16 * 1024 * 1024


class ExactJSONError(ValueError):
    pass


@dataclass(frozen=True)
class NumberToken:
    token: str

    def __post_init__(self) -> None:
        if NUMBER.fullmatch(self.token) is None:
            raise ExactJSONError(f"invalid JSON number: {self.token}")


JSONNode = Union[None, bool, str, NumberToken, List["JSONNode"], Dict[str, "JSONNode"]]


def loads(data: bytes) -> JSONNode:
    if len(data) > MAX_JSON_BYTES:
        raise ExactJSONError("JSON input exceeds 16 MiB")
    try:
        text = data.decode("utf-8", errors="strict")
        value = json.loads(
            text,
            parse_int=NumberToken,
            parse_float=NumberToken,
            parse_constant=_reject_constant,
            object_pairs_hook=_object,
        )
        _validate(value)
        return value
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ExactJSONError(str(error)) from error


def dumps(value: JSONNode) -> bytes:
    output: list[str] = []
    _append(value, output)
    try:
        return "".join(output).encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise ExactJSONError("JSON contains an unpaired Unicode surrogate") from error


def digest(value: JSONNode) -> str:
    return hashlib.sha256(dumps(value)).hexdigest()


def file_digest(path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def integer(value: JSONNode, field: str) -> int:
    if not isinstance(value, NumberToken) or re.fullmatch(r"0|[1-9][0-9]*", value.token) is None:
        raise ExactJSONError(f"{field} must be a non-negative integer")
    return int(value.token)


def _reject_constant(value: str) -> None:
    raise ExactJSONError(f"non-finite number is forbidden: {value}")


def _object(pairs: list[tuple[str, JSONNode]]) -> dict[str, JSONNode]:
    result: dict[str, JSONNode] = {}
    identities: set[str] = set()
    for key, value in pairs:
        identity = unicodedata.normalize("NFC", key)
        if identity in identities:
            raise ExactJSONError(f"duplicate object key: {key}")
        identities.add(identity)
        result[key] = value
    return result


def _validate(value: JSONNode, depth: int = 0) -> None:
    if depth > 128:
        raise ExactJSONError("JSON nesting exceeds 128")
    if isinstance(value, NumberToken):
        if len(value.token) > 4096:
            raise ExactJSONError("JSON number token exceeds 4096 characters")
    elif isinstance(value, str):
        try:
            value.encode("utf-8", errors="strict")
        except UnicodeEncodeError as error:
            raise ExactJSONError("JSON contains an unpaired Unicode surrogate") from error
    elif isinstance(value, list):
        for item in value:
            _validate(item, depth + 1)
    elif isinstance(value, dict):
        for key, item in value.items():
            _validate(key, depth + 1)
            _validate(item, depth + 1)


def key_order(value: str):
    return (unicodedata.normalize("NFC", value).encode("utf-8"), value.encode("utf-8"))


def _append(value: JSONNode, output: list[str]) -> None:
    if value is None:
        output.append("null")
    elif value is True:
        output.append("true")
    elif value is False:
        output.append("false")
    elif isinstance(value, NumberToken):
        output.append(value.token)
    elif isinstance(value, str):
        output.append(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    elif isinstance(value, list):
        output.append("[")
        for index, item in enumerate(value):
            if index:
                output.append(",")
            _append(item, output)
        output.append("]")
    elif isinstance(value, dict):
        output.append("{")
        for index, key in enumerate(sorted(value, key=key_order)):
            if index:
                output.append(",")
            _append(key, output)
            output.append(":")
            _append(value[key], output)
        output.append("}")
    else:
        raise ExactJSONError(f"unsupported JSON node: {type(value).__name__}")
