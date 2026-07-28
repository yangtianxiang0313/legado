#!/usr/bin/env python3
"""Deterministic compiler from proposal DAG recipes to reviewable candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

try:
    from .harness import Harness, HarnessError, WORK_ITEM_ID, sha256_json
except ImportError:
    from harness import Harness, HarnessError, WORK_ITEM_ID, sha256_json  # type: ignore


SCHEMA_VERSION = 1
COMPILER_VERSION = "proposal-compiler-v1"
DAG_PATH = "ios/project/work-item-proposals/initialization-dag.json"
RECIPE_ROOT = "ios/project/work-item-proposals/recipes"
CANDIDATE_ROOT = "ios/project/work-item-proposals/candidates"
MANIFEST_ROOT = "ios/project/work-item-proposals/candidate-manifests"
TERMINAL_STATUSES = {
    "blocked",
    "cancelled",
    "exhausted",
    "rejected",
    "superseded",
}


class ProposalCompilerError(RuntimeError):
    pass


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _json_bytes(value: Any) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n"
    ).encode("utf-8")


def _file_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise ProposalCompilerError(f"输入不是普通文件：{path}")
    return _sha256_bytes(path.read_bytes())


class ProposalCompiler:
    def __init__(self, harness: Harness, dag_path: Optional[Path] = None):
        self.harness = harness
        self.root = harness.root.resolve()
        self.dag_path = (
            dag_path.resolve()
            if dag_path is not None
            else harness.resolve(DAG_PATH).resolve()
        )

    def _load_json(self, path: Path, label: str) -> Mapping[str, Any]:
        if path.is_symlink() or not path.is_file():
            raise ProposalCompilerError(f"{label} 必须是普通 JSON 文件：{path}")
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProposalCompilerError(f"{label} JSON 无效：{error}") from error
        if not isinstance(value, dict):
            raise ProposalCompilerError(f"{label} 必须是 object")
        return value

    def _dag(self) -> Tuple[Mapping[str, Any], Dict[str, Mapping[str, Any]]]:
        dag = self._load_json(self.dag_path, "initialization DAG")
        if (
            dag.get("schema_version") != 1
            or dag.get("kind") != "InitializationWorkItemProposalDAG"
            or dag.get("authority") != "proposal_only"
            or dag.get("queue_effect", {}).get("materializes_work_items") is not False
        ):
            raise ProposalCompilerError("initialization DAG authority/queue contract 无效")
        nodes = dag.get("nodes")
        if not isinstance(nodes, list) or not nodes:
            raise ProposalCompilerError("initialization DAG nodes 不能为空")
        indexed: Dict[str, Mapping[str, Any]] = {}
        for node in nodes:
            if not isinstance(node, dict):
                raise ProposalCompilerError("DAG node 必须是 object")
            proposal_id = node.get("proposal_id")
            if not isinstance(proposal_id, str) or not proposal_id:
                raise ProposalCompilerError("DAG node 缺少 proposal_id")
            if proposal_id in indexed:
                raise ProposalCompilerError(f"DAG proposal_id 重复：{proposal_id}")
            depends_on = node.get("depends_on")
            if not isinstance(depends_on, list) or any(
                not isinstance(value, str) for value in depends_on
            ):
                raise ProposalCompilerError(f"{proposal_id}: depends_on 无效")
            recovers = node.get("recovers")
            if recovers is not None and (
                not isinstance(recovers, str)
                or WORK_ITEM_ID.fullmatch(recovers) is None
            ):
                raise ProposalCompilerError(f"{proposal_id}: recovers 无效")
            if recovers == proposal_id:
                raise ProposalCompilerError(f"{proposal_id}: recovers 不得自引用")
            if recovers is not None and recovers in depends_on:
                raise ProposalCompilerError(
                    f"{proposal_id}: recovers 不得同时出现在 depends_on"
                )
            indexed[proposal_id] = node
        return dag, indexed

    @staticmethod
    def _produces(item: Mapping[str, Any]) -> Dict[Tuple[str, str], int]:
        result: Dict[Tuple[str, str], int] = {}
        knowledge = item.get("spec", {}).get("knowledge", {})
        outputs = knowledge.get("produces", []) if isinstance(knowledge, dict) else []
        for output in outputs:
            if not isinstance(output, dict):
                continue
            kind = output.get("kind")
            identifier = output.get("id")
            revision = output.get("revision")
            if isinstance(kind, str) and isinstance(identifier, str) and isinstance(
                revision, int
            ):
                result[(kind, identifier)] = revision
        return result

    def _semantic_recoveries(
        self,
        item_id: str,
        items: Mapping[str, Mapping[str, Any]],
        state_items: Mapping[str, Mapping[str, Any]],
    ) -> List[str]:
        original = items.get(item_id)
        if original is None:
            return []
        expected = self._produces(original)
        if not expected:
            return []
        matches: List[str] = []
        for candidate_id, candidate in sorted(items.items()):
            if candidate_id == item_id:
                continue
            runtime = state_items.get(candidate_id, {})
            if runtime.get("status") != "completed":
                continue
            actual = self._produces(candidate)
            if all(
                actual.get(identity, 0) > revision
                for identity, revision in expected.items()
            ):
                matches.append(candidate_id)
        return matches

    def resolve_dependency(
        self,
        item_id: str,
        items: Mapping[str, Mapping[str, Any]],
        state_items: Mapping[str, Mapping[str, Any]],
    ) -> Mapping[str, Any]:
        chain: List[str] = []
        current = item_id
        while True:
            if current in chain:
                return {
                    "original": item_id,
                    "status": "unresolved",
                    "reason_code": "REPLACEMENT_CYCLE",
                    "chain": chain + [current],
                }
            chain.append(current)
            runtime = state_items.get(current)
            if not isinstance(runtime, dict):
                return {
                    "original": item_id,
                    "status": "unresolved",
                    "reason_code": "DEPENDENCY_MISSING",
                    "chain": chain,
                }
            status = runtime.get("status")
            if status == "completed":
                return {
                    "original": item_id,
                    "status": "resolved",
                    "reason_code": (
                        "DIRECT_COMPLETION"
                        if current == item_id
                        else "EXPLICIT_REPLACEMENT"
                    ),
                    "resolved": current,
                    "chain": chain,
                }
            replacement = runtime.get("replacement")
            if isinstance(replacement, str) and replacement:
                current = replacement
                continue
            if status in TERMINAL_STATUSES:
                matches = self._semantic_recoveries(current, items, state_items)
                if len(matches) == 1:
                    chain.append(matches[0])
                    return {
                        "original": item_id,
                        "status": "resolved",
                        "reason_code": "KNOWLEDGE_OUTPUT_RECOVERY",
                        "resolved": matches[0],
                        "chain": chain,
                    }
                return {
                    "original": item_id,
                    "status": "unresolved",
                    "reason_code": (
                        "RECOVERY_AMBIGUOUS"
                        if len(matches) > 1
                        else "TERMINAL_WITHOUT_RECOVERY"
                    ),
                    "candidates": matches,
                    "chain": chain,
                }
            return {
                "original": item_id,
                "status": "unresolved",
                "reason_code": "DEPENDENCY_NOT_COMPLETED",
                "dependency_status": status,
                "chain": chain,
            }

    def _recipe_path(self, proposal_id: str) -> Path:
        return self.harness.resolve(f"{RECIPE_ROOT}/{proposal_id}.json")

    def _candidate_path(self, proposal_id: str) -> Path:
        return self.harness.resolve(f"{CANDIDATE_ROOT}/{proposal_id}.json")

    def _manifest_path(self, proposal_id: str) -> Path:
        return self.harness.resolve(f"{MANIFEST_ROOT}/{proposal_id}.json")

    @staticmethod
    def _dag_outputs(node: Mapping[str, Any]) -> List[Mapping[str, Any]]:
        outputs = node.get("outputs", [])
        return [
            output
            for output in outputs
            if isinstance(output, dict)
            and set(output) == {"kind", "id", "revision"}
        ]

    def _load_recipe(
        self,
        node: Mapping[str, Any],
        resolved_dependencies: Sequence[str],
    ) -> Tuple[Mapping[str, Any], Mapping[str, Any], Path]:
        proposal_id = str(node["proposal_id"])
        path = self._recipe_path(proposal_id)
        recipe = self._load_json(path, f"{proposal_id} recipe")
        if set(recipe) != {
            "schema_version",
            "proposal_id",
            "proposal_constraint",
            "work_item",
        }:
            raise ProposalCompilerError(f"{proposal_id}: recipe 字段必须精确匹配 v1")
        if recipe.get("schema_version") != 1 or recipe.get("proposal_id") != proposal_id:
            raise ProposalCompilerError(f"{proposal_id}: recipe identity 不一致")
        if recipe.get("proposal_constraint") != node.get("constraint"):
            raise ProposalCompilerError(f"{proposal_id}: recipe constraint 与 DAG 不一致")
        item = recipe.get("work_item")
        if not isinstance(item, dict):
            raise ProposalCompilerError(f"{proposal_id}: recipe.work_item 必须是 object")
        errors = self.harness.validate_work_item(item, proposal_id)
        if errors:
            raise ProposalCompilerError(
                f"{proposal_id}: Work Item 无效：" + "；".join(errors)
            )
        if item.get("metadata", {}).get("title") != node.get("title"):
            raise ProposalCompilerError(f"{proposal_id}: title 与 DAG 不一致")
        if item.get("spec", {}).get("depends_on") != list(resolved_dependencies):
            raise ProposalCompilerError(f"{proposal_id}: resolved depends_on 与 DAG 不一致")
        if item.get("spec", {}).get("recovers") != node.get("recovers"):
            raise ProposalCompilerError(f"{proposal_id}: recovers 与 DAG 不一致")
        knowledge = item.get("spec", {}).get("knowledge", {})
        if knowledge.get("mode") != node.get("knowledge_mode"):
            raise ProposalCompilerError(f"{proposal_id}: knowledge_mode 与 DAG 不一致")
        if knowledge.get("produces") != self._dag_outputs(node):
            raise ProposalCompilerError(f"{proposal_id}: produces 与 DAG 不一致")
        if item.get("spec", {}).get("gates") != node.get("gates"):
            raise ProposalCompilerError(f"{proposal_id}: gates 与 DAG 不一致")
        return recipe, item, path

    def _dependency_binding(
        self,
        original: str,
        resolution: Mapping[str, Any],
        items: Mapping[str, Mapping[str, Any]],
        state_items: Mapping[str, Mapping[str, Any]],
    ) -> Mapping[str, Any]:
        resolved = resolution.get("resolved")
        if not isinstance(resolved, str):
            raise ProposalCompilerError(f"依赖未解析：{original}")
        runtime = state_items.get(resolved, {})
        evidence_relative = runtime.get("last_evidence")
        evidence_path = (
            self.harness.resolve(evidence_relative)
            if isinstance(evidence_relative, str)
            else None
        )
        checkpoint_path = self.harness.resolve(
            f"ios/project/checkpoints/{resolved}.json"
        )
        work_item_path = self.harness.resolve(
            f"ios/harness/work-items/{resolved}.json"
        )
        return {
            "original": original,
            "resolved": resolved,
            "reason_code": resolution.get("reason_code"),
            "chain": list(resolution.get("chain", [])),
            "work_item_sha256": _file_digest(work_item_path),
            "evidence": evidence_relative,
            "evidence_sha256": (
                _file_digest(evidence_path) if evidence_path is not None else None
            ),
            "checkpoint": self.harness.relative(checkpoint_path),
            "checkpoint_sha256": _file_digest(checkpoint_path),
        }

    def _recovery_binding(
        self,
        proposal_id: str,
        item: Mapping[str, Any],
        items: Mapping[str, Mapping[str, Any]],
        state_items: Mapping[str, Mapping[str, Any]],
    ) -> Optional[Mapping[str, Any]]:
        predecessor_id = item.get("spec", {}).get("recovers")
        if predecessor_id is None:
            return None
        prospective_items = {
            key: dict(value)
            for key, value in items.items()
            if isinstance(value, Mapping)
        }
        prospective_item = dict(item)
        issues = self.harness.recovery_candidate_issues(
            proposal_id,
            prospective_item,
            prospective_items,
            {"work_items": dict(state_items)},
        )
        if issues:
            raise ProposalCompilerError(
                f"{proposal_id}: recovery 无效：" + "；".join(issues)
            )
        if not isinstance(predecessor_id, str):
            raise ProposalCompilerError(f"{proposal_id}: recovers 无效")
        runtime = state_items.get(predecessor_id)
        if not isinstance(runtime, Mapping):
            raise ProposalCompilerError(
                f"{proposal_id}: predecessor runtime 不存在：{predecessor_id}"
            )
        work_item_relative = (
            f"ios/harness/work-items/{predecessor_id}.json"
        )
        work_item_path = self.harness.resolve(work_item_relative)
        evidence_relative = runtime.get("last_evidence")
        evidence_path = (
            self.harness.resolve(evidence_relative)
            if isinstance(evidence_relative, str)
            else None
        )
        if evidence_path is not None and not evidence_path.is_file():
            raise ProposalCompilerError(
                f"{proposal_id}: predecessor Evidence 不存在：{evidence_relative}"
            )
        checkpoint_relative = (
            f"ios/project/checkpoints/{predecessor_id}.json"
        )
        checkpoint_path = self.harness.resolve(checkpoint_relative)
        checkpoint_exists = checkpoint_path.is_file() and not checkpoint_path.is_symlink()
        return {
            "predecessor": predecessor_id,
            "capability": item.get("spec", {}).get("capability"),
            "work_item": work_item_relative,
            "work_item_sha256": _file_digest(work_item_path),
            "runtime_sha256": sha256_json(runtime),
            "status": runtime.get("status"),
            "replacement": runtime.get("replacement"),
            "evidence": evidence_relative,
            "evidence_sha256": (
                _file_digest(evidence_path)
                if evidence_path is not None
                else None
            ),
            "checkpoint": (
                checkpoint_relative if checkpoint_exists else None
            ),
            "checkpoint_sha256": (
                _file_digest(checkpoint_path)
                if checkpoint_exists
                else None
            ),
        }

    def _entry(
        self,
        node: Mapping[str, Any],
        items: Mapping[str, Mapping[str, Any]],
        state_items: Mapping[str, Mapping[str, Any]],
    ) -> Mapping[str, Any]:
        proposal_id = str(node["proposal_id"])
        runtime = state_items.get(proposal_id)
        if isinstance(runtime, dict):
            if runtime.get("status") == "completed":
                return {
                    "proposal_id": proposal_id,
                    "status": "completed",
                    "resolved_work_item_id": proposal_id,
                    "reason_code": "DIRECT_COMPLETION",
                    "dependencies": [],
                }
            if runtime.get("status") in TERMINAL_STATUSES:
                resolution = self.resolve_dependency(
                    proposal_id, items, state_items
                )
                if resolution.get("status") == "resolved":
                    return {
                        "proposal_id": proposal_id,
                        "status": "completed",
                        "resolved_work_item_id": resolution.get("resolved"),
                        "reason_code": resolution.get("reason_code"),
                        "dependencies": [],
                    }
                return {
                    "proposal_id": proposal_id,
                    "status": "terminal_unresolved",
                    "reason_code": resolution.get("reason_code"),
                    "dependencies": [],
                    "blockers": [resolution],
                }
            return {
                "proposal_id": proposal_id,
                "status": "materialized",
                "resolved_work_item_id": proposal_id,
                "reason_code": f"WORK_ITEM_{str(runtime.get('status')).upper()}",
                "dependencies": [],
            }

        resolutions = [
            self.resolve_dependency(dependency, items, state_items)
            for dependency in node.get("depends_on", [])
        ]
        unresolved = [
            resolution
            for resolution in resolutions
            if resolution.get("status") != "resolved"
        ]
        if unresolved:
            return {
                "proposal_id": proposal_id,
                "status": "dependency_blocked",
                "reason_code": "DEPENDENCY_UNRESOLVED",
                "dependencies": resolutions,
                "blockers": unresolved,
            }
        if node.get("gates"):
            return {
                "proposal_id": proposal_id,
                "status": "gate_blocked",
                "reason_code": "TRUSTED_GATE_REQUIRED",
                "dependencies": resolutions,
                "blockers": [{"gates": list(node.get("gates", []))}],
            }
        recipe_path = self._recipe_path(proposal_id)
        if not recipe_path.exists():
            return {
                "proposal_id": proposal_id,
                "status": "ready_for_recipe",
                "reason_code": "RECIPE_MISSING",
                "dependencies": resolutions,
            }
        resolved = [str(value["resolved"]) for value in resolutions]
        try:
            _, item, _ = self._load_recipe(node, resolved)
        except ProposalCompilerError as error:
            return {
                "proposal_id": proposal_id,
                "status": "ready_for_recipe",
                "reason_code": "RECIPE_INVALID",
                "dependencies": resolutions,
                "blockers": [{"message": str(error)}],
            }
        try:
            self._recovery_binding(
                proposal_id,
                item,
                items,
                state_items,
            )
        except ProposalCompilerError as error:
            return {
                "proposal_id": proposal_id,
                "status": "recovery_blocked",
                "reason_code": "RECOVERY_INVALID",
                "dependencies": resolutions,
                "blockers": [{"message": str(error)}],
            }
        return {
            "proposal_id": proposal_id,
            "status": "recipe_ready",
            "reason_code": "RECIPE_VALID",
            "dependencies": resolutions,
        }

    def plan(self) -> Mapping[str, Any]:
        dag, nodes = self._dag()
        items = self.harness.work_items()
        state_items = self.harness.state().get("work_items", {})
        entries = [
            self._entry(node, items, state_items) for node in nodes.values()
        ]
        return {
            "schema_version": SCHEMA_VERSION,
            "compiler_version": COMPILER_VERSION,
            "dag_id": dag.get("id"),
            "dag_revision": dag.get("revision"),
            "dag_sha256": _file_digest(self.dag_path),
            "nodes": entries,
        }

    def _expected(
        self, proposal_id: str
    ) -> Tuple[bytes, bytes, Mapping[str, Any]]:
        dag, nodes = self._dag()
        node = nodes.get(proposal_id)
        if node is None:
            raise ProposalCompilerError(f"DAG 中不存在 proposal：{proposal_id}")
        items = self.harness.work_items()
        state_items = self.harness.state().get("work_items", {})
        entry = self._entry(node, items, state_items)
        if entry.get("status") != "recipe_ready":
            raise ProposalCompilerError(
                f"{proposal_id} 不是 recipe_ready：{entry.get('status')} "
                f"{entry.get('reason_code')}"
            )
        resolutions = entry["dependencies"]
        resolved_ids = [str(value["resolved"]) for value in resolutions]
        recipe, item, recipe_path = self._load_recipe(node, resolved_ids)
        candidate_bytes = _json_bytes(item)
        recovery = self._recovery_binding(
            proposal_id,
            item,
            items,
            state_items,
        )
        manifest = {
            "schema_version": SCHEMA_VERSION,
            "compiler_version": COMPILER_VERSION,
            "proposal_id": proposal_id,
            "dag": {
                "id": dag.get("id"),
                "revision": dag.get("revision"),
                "sha256": _file_digest(self.dag_path),
            },
            "node_sha256": sha256_json(node),
            "recipe_sha256": _file_digest(recipe_path),
            "candidate_sha256": sha256_json(item),
            "dependencies": [
                self._dependency_binding(
                    original,
                    resolution,
                    items,
                    state_items,
                )
                for original, resolution in zip(
                    node.get("depends_on", []), resolutions
                )
            ],
            "authority": "proposal_only",
            "queue_effect": "none",
        }
        if recovery is not None:
            manifest["recovery"] = recovery
        return candidate_bytes, _json_bytes(manifest), manifest

    @staticmethod
    def _link_create(path: Path, payload: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, raw = tempfile.mkstemp(
            dir=str(path.parent), prefix=f".{path.name}.proposal-compiler."
        )
        temporary = Path(raw)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o644)
            os.link(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def compile(self, proposal_id: str) -> Mapping[str, Any]:
        candidate_bytes, manifest_bytes, manifest = self._expected(proposal_id)
        candidate_path = self._candidate_path(proposal_id)
        manifest_path = self._manifest_path(proposal_id)
        existing = [candidate_path.exists(), manifest_path.exists()]
        if any(existing):
            if (
                all(existing)
                and not candidate_path.is_symlink()
                and not manifest_path.is_symlink()
                and candidate_path.read_bytes() == candidate_bytes
                and manifest_path.read_bytes() == manifest_bytes
            ):
                return {
                    "schema_version": SCHEMA_VERSION,
                    "outcome": "unchanged",
                    "candidate": self.harness.relative(candidate_path),
                    "manifest": self.harness.relative(manifest_path),
                    "candidate_sha256": manifest["candidate_sha256"],
                }
            raise ProposalCompilerError(
                f"{proposal_id}: candidate/manifest 已存在且与当前输入不一致"
            )
        try:
            self._link_create(candidate_path, candidate_bytes)
        except FileExistsError as error:
            raise ProposalCompilerError(
                f"{proposal_id}: create-only 目标发生并发冲突"
            ) from error
        try:
            self._link_create(manifest_path, manifest_bytes)
        except Exception as error:
            candidate_path.unlink(missing_ok=True)
            if isinstance(error, FileExistsError):
                raise ProposalCompilerError(
                    f"{proposal_id}: create-only 目标发生并发冲突"
                ) from error
            raise
        return {
            "schema_version": SCHEMA_VERSION,
            "outcome": "created",
            "candidate": self.harness.relative(candidate_path),
            "manifest": self.harness.relative(manifest_path),
            "candidate_sha256": manifest["candidate_sha256"],
        }

    def check(self, proposal_id: str) -> Mapping[str, Any]:
        candidate_path = self._candidate_path(proposal_id)
        manifest_path = self._manifest_path(proposal_id)
        try:
            candidate_bytes, manifest_bytes, manifest = self._expected(proposal_id)
        except ProposalCompilerError as error:
            return {
                "schema_version": SCHEMA_VERSION,
                "status": "stale",
                "proposal_id": proposal_id,
                "reasons": [str(error)],
            }
        reasons: List[str] = []
        if (
            candidate_path.is_symlink()
            or not candidate_path.is_file()
            or candidate_path.read_bytes() != candidate_bytes
        ):
            reasons.append("candidate_mismatch")
        if (
            manifest_path.is_symlink()
            or not manifest_path.is_file()
            or manifest_path.read_bytes() != manifest_bytes
        ):
            reasons.append("manifest_mismatch")
        return {
            "schema_version": SCHEMA_VERSION,
            "status": "current" if not reasons else "stale",
            "proposal_id": proposal_id,
            "candidate_sha256": manifest["candidate_sha256"],
            "reasons": reasons,
        }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Compile reviewed DAG recipes into create-only candidate artifacts"
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("plan", help="Print deterministic DAG readiness")
    compile_parser = subparsers.add_parser(
        "compile", help="Create one candidate and provenance manifest"
    )
    compile_parser.add_argument("proposal_id")
    check_parser = subparsers.add_parser(
        "check", help="Recompute and compare one generated pair"
    )
    check_parser.add_argument("proposal_id")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        compiler = ProposalCompiler(Harness(args.root))
        if args.command == "plan":
            result = compiler.plan()
        elif args.command == "compile":
            result = compiler.compile(args.proposal_id)
        else:
            result = compiler.check(args.proposal_id)
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        if args.command == "check" and result.get("status") != "current":
            return 2
        return 0
    except (ProposalCompilerError, HarnessError) as error:
        print(f"proposal-compiler: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
