"""Compact, immutable Android Oracle request registry."""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

from oracle.exact_json import JSONNode, integer, loads


REGISTRY_PATH = Path("ios/harness/oracle/request-registry.json")
REQUEST_ID = re.compile(r"IOS-[A-Z][A-Z0-9-]*-[0-9]{3}\Z")
SCENARIO_ID = re.compile(r"[a-z0-9][a-z0-9-]+\Z")


class RequestRegistryError(ValueError):
    pass


def load_registry(root: Path) -> dict[str, JSONNode]:
    path = root / REGISTRY_PATH
    try:
        value = loads(path.read_bytes())
    except (OSError, UnicodeError, ValueError) as error:
        raise RequestRegistryError("Oracle request registry is invalid") from error
    if not isinstance(value, dict) or set(value) != {"schema_version", "requests"}:
        raise RequestRegistryError("Oracle request registry fields mismatch")
    if integer(value["schema_version"], "registry.schema_version") != 1:
        raise RequestRegistryError("Oracle request registry schema is unsupported")
    requests = value["requests"]
    if not isinstance(requests, list) or not requests:
        raise RequestRegistryError("Oracle request registry must not be empty")
    by_id: dict[str, JSONNode] = {}
    by_scenario: dict[str, JSONNode] = {}
    for request in requests:
        if not isinstance(request, dict) or set(request) != {
            "id",
            "scenario_id",
            "fixture_ids",
            "authority",
            "status",
        }:
            raise RequestRegistryError("Oracle request entry fields mismatch")
        request_id = request["id"]
        scenario_id = request["scenario_id"]
        fixture_ids = request["fixture_ids"]
        if not isinstance(request_id, str) or REQUEST_ID.fullmatch(request_id) is None:
            raise RequestRegistryError("Oracle request id is invalid")
        if not isinstance(scenario_id, str) or SCENARIO_ID.fullmatch(scenario_id) is None:
            raise RequestRegistryError("Oracle scenario id is invalid")
        if fixture_ids != [scenario_id]:
            raise RequestRegistryError("Oracle request must bind exactly one matching fixture")
        if request["authority"] != "android_oracle_candidate_only":
            raise RequestRegistryError("Oracle request authority is invalid")
        if request["status"] not in {"candidate", "reference"}:
            raise RequestRegistryError("Oracle request status is invalid")
        if request_id in by_id or scenario_id in by_scenario:
            raise RequestRegistryError("Oracle request id/scenario must be unique")
        by_id[request_id] = request
        by_scenario[scenario_id] = request
    return {"by_id": by_id, "by_scenario": by_scenario}


def request_by_id(root: Path, request_id: str) -> dict[str, Any]:
    request = load_registry(root)["by_id"].get(request_id)
    if not isinstance(request, dict):
        raise RequestRegistryError("Oracle request is not registered")
    return request


def request_for_scenario(root: Path, scenario_id: str) -> dict[str, Any]:
    request = load_registry(root)["by_scenario"].get(scenario_id)
    if not isinstance(request, dict):
        raise RequestRegistryError("Oracle scenario is not registered")
    return request
