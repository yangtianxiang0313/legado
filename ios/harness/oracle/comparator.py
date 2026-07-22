"""Exact shared-channel comparator with deterministic first divergence."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from enum import Enum
from typing import Optional

from oracle import SHARED_CHANNELS
from oracle.canonicalizer import canonicalize_node
from oracle.exact_json import JSONNode, NumberToken, digest, dumps, key_order, loads


class ComparisonError(ValueError):
    pass


@dataclass(frozen=True)
class Divergence:
    classification: str
    pointer: str
    expected: dict[str, JSONNode]
    actual: dict[str, JSONNode]


class _Missing(Enum):
    MISSING = "missing"


_MISSING = _Missing.MISSING


def compare(expected_payload: bytes, actual_artifact: bytes, config: dict[str, JSONNode]) -> dict[str, JSONNode]:
    expected_root = loads(expected_payload)
    actual_root = loads(actual_artifact)
    if (
        not isinstance(expected_root, dict)
        or expected_root.get("kind") != "android_oracle_payload"
        or not isinstance(expected_root.get("artifact"), dict)
    ):
        raise ComparisonError("expected input must be an android_oracle_payload")
    expected_artifact = expected_root["artifact"]
    if expected_root.get("fixture_id") != expected_artifact.get("fixture_id"):
        raise ComparisonError("expected payload/artifact fixture identity drift")
    expected_engine = expected_artifact.get("engine")
    actual_engine = actual_root.get("engine") if isinstance(actual_root, dict) else None
    if not isinstance(expected_engine, dict) or expected_engine.get("platform") != "android":
        raise ComparisonError("expected payload must contain an Android artifact")
    if not isinstance(actual_engine, dict) or actual_engine.get("platform") != "ios":
        raise ComparisonError("actual input must be an iOS artifact")
    expected_view = canonicalize_node(_comparison_view(expected_artifact), config)
    actual_view = canonicalize_node(_comparison_view(actual_root), config)
    difference = first_divergence(expected_view, actual_view)
    if difference is not None:
        base = {
            "classification": difference.classification,
            "pointer": difference.pointer,
            "stage": _stage(difference.pointer),
        }
        fingerprint = hashlib.sha256(
            dumps({**base, "fixture_id": expected_artifact["fixture_id"], "channels": list(SHARED_CHANNELS)})
        ).hexdigest()
        return {
            "equal": False,
            "channels": list(SHARED_CHANNELS),
            "first_divergence": {
                **base,
                "expected": difference.expected,
                "actual": difference.actual,
                "fingerprint": fingerprint,
            },
        }
    return {"equal": True, "channels": list(SHARED_CHANNELS), "first_divergence": None}


def first_divergence(expected, actual, pointer: str = "") -> Optional[Divergence]:
    if expected is _MISSING and actual is _MISSING:
        return None
    if expected is _MISSING or actual is _MISSING:
        return Divergence(
            "DIFF_PARSE",
            pointer,
            _describe(expected),
            _describe(actual),
        )
    if _node_type(expected) != _node_type(actual):
        return Divergence(
            "DIFF_TYPE_COERCION",
            pointer,
            _describe(expected),
            _describe(actual),
        )
    if isinstance(expected, dict):
        for key in sorted(set(expected) | set(actual), key=key_order):
            difference = first_divergence(
                expected.get(key, _MISSING),
                actual.get(key, _MISSING),
                f"{pointer}/{_escape(key)}",
            )
            if difference is not None:
                return difference
        return None
    if isinstance(expected, list):
        order_only = len(expected) == len(actual) and sorted(map(dumps, expected)) == sorted(map(dumps, actual))
        for index in range(max(len(expected), len(actual))):
            difference = first_divergence(
                expected[index] if index < len(expected) else _MISSING,
                actual[index] if index < len(actual) else _MISSING,
                f"{pointer}/{index}",
            )
            if difference is not None:
                if order_only:
                    return Divergence(
                        "DIFF_ORDER",
                        difference.pointer,
                        difference.expected,
                        difference.actual,
                    )
                return difference
        return None
    equal = expected.token == actual.token if isinstance(expected, NumberToken) else expected == actual
    if equal:
        return None
    return Divergence(
        "DIFF_PARSE",
        pointer,
        _describe(expected),
        _describe(actual),
    )


def _comparison_view(artifact: JSONNode) -> dict[str, JSONNode]:
    if not isinstance(artifact, dict):
        raise ComparisonError("artifact must be an object")
    engine = artifact.get("engine")
    result = artifact.get("result")
    if not isinstance(engine, dict) or not isinstance(result, dict) or not isinstance(result.get("value"), dict):
        raise ComparisonError("artifact engine/result.value must be objects")
    lanes = result["value"]
    platform = engine.get("platform")
    allowed_lanes = {
        "android": {"fixture_integrity", "portable_known_projection", "android_characterization"},
        "ios": {"fixture_integrity", "portable_known_projection", "ios_lossless_extension"},
    }
    if platform not in allowed_lanes or not set(lanes).issubset(allowed_lanes[platform]):
        raise ComparisonError("artifact contains an undeclared platform/result lane")
    return {
        "schema_version": artifact.get("schema_version", _MISSING),
        "fixture_id": artifact.get("fixture_id", _MISSING),
        "engine": {"compatibility_profile": engine.get("compatibility_profile", _MISSING)},
        "request_plan": artifact.get("request_plan", _MISSING),
        "decode": artifact.get("decode", _MISSING),
        "stages": artifact.get("stages", _MISSING),
        "result": {
            "type": result.get("type", _MISSING),
            "value": {channel: lanes.get(channel, _MISSING) for channel in SHARED_CHANNELS},
        },
        "issues": artifact.get("issues", _MISSING),
    }


def _describe(value) -> dict[str, JSONNode]:
    if value is _MISSING:
        return {"presence": "missing", "type": "missing", "sha256": None}
    return {"presence": "present", "type": _node_type(value), "sha256": digest(value)}


def _node_type(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, NumberToken):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    raise ComparisonError(f"unsupported node: {type(value).__name__}")


def _escape(component: str) -> str:
    return component.replace("~", "~0").replace("/", "~1")


def _stage(pointer: str) -> str:
    field = pointer.split("/", 2)[1] if pointer.startswith("/") else ""
    return {
        "request_plan": "request_planning",
        "decode": "decoding",
        "stages": "rule_evaluation",
        "result": "result_mapping",
        "issues": "issue_reporting",
    }.get(field, "envelope")
