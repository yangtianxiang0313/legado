#!/usr/bin/env python3
"""Local, human-click approval UI for the Legado iOS Harness.

This module is intentionally a cooperative local guardrail. It removes manual
Approval JSON authoring, but it is not a trust boundary against a process with
the same filesystem and desktop permissions. Production promotion must verify
a signed decision in a protected supervisor.
"""

from __future__ import annotations

import datetime as dt
import getpass
import hashlib
import html
import json
import os
import re
import secrets
import tempfile
import time
import webbrowser
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple


LOOPBACK_HOST = "127.0.0.1"
APPROVAL_TTL = dt.timedelta(hours=24)
SESSION_TTL_SECONDS = 600
MAX_REQUEST_BYTES = 4096
REQUEST_IO_TIMEOUT_SECONDS = 5
GATE_NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class ApprovalUIError(RuntimeError):
    pass


class ApprovalRequestError(ApprovalUIError):
    pass


class ApprovalConflict(ApprovalUIError):
    pass


class ApprovalRecoveryRequired(ApprovalUIError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def iso8601_utc(value: dt.datetime) -> str:
    if value.tzinfo is None:
        raise ApprovalUIError("审批时间必须包含时区")
    return value.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00",
        "Z",
    )


def local_reviewer() -> str:
    """Return a visible, explicitly untrusted local identity label."""

    try:
        account = getpass.getuser().strip()
    except (ImportError, KeyError, OSError):
        account = ""
    return f"local-user:{account or 'unknown'}"


def approval_relative_path(harness: Any, item_id: str, gate: str) -> str:
    if GATE_NAME.fullmatch(gate) is None:
        raise ApprovalUIError(f"Gate 名称不安全：{gate!r}")
    relative = f"{harness.config['approvals_dir']}/{item_id}--{gate}.json"
    approval_root = harness.resolve(harness.config["approvals_dir"])
    target = harness.resolve(relative)
    if target.parent != approval_root:
        raise ApprovalUIError(f"Approval 路径越界：{gate!r}")
    return relative


@dataclass(frozen=True)
class ReviewSnapshot:
    item_id: str
    title: str
    attempt: int
    gates: Tuple[str, ...]
    active_gate: str
    decision_contract: Dict[str, Any]
    decision_contract_sha256: str
    unresolved_count: int
    work_item_sha256: str
    review_subject_sha256: str
    review_subject_files: Tuple[Tuple[str, str], ...]
    evidence_path: str
    evidence_sha256: str

    def binding(self) -> Tuple[Any, ...]:
        return (
            self.item_id,
            self.attempt,
            self.gates,
            self.active_gate,
            self.decision_contract_sha256,
            self.unresolved_count,
            self.work_item_sha256,
            self.review_subject_sha256,
            self.review_subject_files,
            self.evidence_path,
            self.evidence_sha256,
        )


def collect_review_snapshot(harness: Any, item_id: str) -> ReviewSnapshot:
    items = harness.work_items()
    if item_id not in items:
        raise ApprovalUIError(f"未知工作项：{item_id}")
    state = harness.state()
    runtime = state.get("work_items", {}).get(item_id)
    if not isinstance(runtime, dict):
        raise ApprovalUIError(f"工作项尚未 materialize：{item_id}")
    if runtime.get("status") != "awaiting_human":
        raise ApprovalUIError(
            f"只能审批 awaiting_human 工作项；当前为 {runtime.get('status')}"
        )

    item = items[item_id]
    expected_item_hash = sha256_json(item)
    if runtime.get("work_item_sha256") != expected_item_hash:
        raise ApprovalConflict("Work Item 在 claim 后发生变化")

    changed = harness.changed_since_claim(runtime)
    gates, gate_errors = harness.required_close_gates(item_id, item, changed)
    if gate_errors:
        raise ApprovalUIError("Gate 计算失败：" + "；".join(gate_errors))
    gates = sorted(set(gates))
    if not gates:
        raise ApprovalUIError("当前工作项没有需要人工批准的 Gate")
    contracts, contract_errors = harness.decision_gate_contracts(item)
    if contract_errors:
        raise ApprovalUIError("Decision contract 无效：" + "；".join(contract_errors))
    if item.get("spec", {}).get("gate_contract_version") != 1:
        raise ApprovalUIError(
            "旧式批量 Approval 已禁用；请先迁移为 v1 decision contract"
        )
    if any(gate not in contracts for gate in gates):
        raise ApprovalUIError("存在没有结构化决策合同的 Gate")

    approval_paths = [
        approval_relative_path(harness, item_id, gate)
        for gate in gates
    ]
    subject_hash, subject_files = harness.candidate_snapshot(runtime, approval_paths)
    frozen_subject = runtime.get("review_subject_sha256")
    if not isinstance(frozen_subject, str) or not frozen_subject:
        raise ApprovalUIError("尚未冻结 review subject；请先运行 close")
    if subject_hash != frozen_subject:
        raise ApprovalConflict("候选已变化；旧 review subject 失效，必须重新 verify")

    evidence_relative = runtime.get("last_evidence")
    if not isinstance(evidence_relative, str) or not evidence_relative:
        raise ApprovalUIError("awaiting_human 工作项缺少 passing Evidence")
    evidence_path = harness.resolve(evidence_relative)
    evidence_hash = sha256_file(evidence_path)
    if evidence_hash != runtime.get("last_evidence_sha256"):
        raise ApprovalConflict("Evidence 在 verify 后发生变化")

    unresolved: List[str] = []
    for gate, relative in zip(gates, approval_paths):
        path = harness.resolve(relative)
        if not path.exists():
            unresolved.append(gate)
            continue
        issues = harness.approval_issues(
            item_id,
            item,
            subject_hash,
            [gate],
            requested_at=runtime.get("approval_requested_at"),
            preexisting_fingerprints=runtime.get(
                "approval_request_existing_fingerprints"
            ),
            evidence_sha256=evidence_hash,
        )
        if issues:
            raise ApprovalConflict(
                f"既有 decision record 无效，禁止覆盖：{gate}："
                + "；".join(issues)
            )
    if not unresolved:
        raise ApprovalRecoveryRequired(
            "所有 decision 已记录但工作项仍未完成；请运行 close 恢复事务"
        )
    active_gate = unresolved[0]
    contract = contracts[active_gate]

    return ReviewSnapshot(
        item_id=item_id,
        title=str(item.get("metadata", {}).get("title") or item_id),
        attempt=int(runtime.get("attempt", 0)),
        gates=tuple(gates),
        active_gate=active_gate,
        decision_contract=dict(contract),
        decision_contract_sha256=sha256_json(contract),
        unresolved_count=len(unresolved),
        work_item_sha256=expected_item_hash,
        review_subject_sha256=frozen_subject,
        review_subject_files=tuple(sorted(subject_files.items())),
        evidence_path=evidence_relative,
        evidence_sha256=evidence_hash,
    )


class ApprovalFileTransaction:
    """Best-effort all-files transaction with rollback for local approvals."""

    def __init__(self, records: Sequence[Tuple[Path, Dict[str, Any]]]):
        self.records = list(records)
        self.originals: Dict[Path, Optional[bytes]] = {}
        self.temporary: Dict[Path, Path] = {}
        self.replaced: List[Path] = []

    @staticmethod
    def _write_bytes_atomic(path: Path, payload: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, raw_temporary = tempfile.mkstemp(
            dir=str(path.parent),
            prefix=f".{path.name}.restore.",
        )
        temporary = Path(raw_temporary)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(str(temporary), str(path))
        finally:
            temporary.unlink(missing_ok=True)

    def commit(self) -> None:
        try:
            for path, value in self.records:
                path.parent.mkdir(parents=True, exist_ok=True)
                self.originals[path] = path.read_bytes() if path.exists() else None
                descriptor, raw_temporary = tempfile.mkstemp(
                    dir=str(path.parent),
                    prefix=f".{path.name}.pending.",
                )
                temporary = Path(raw_temporary)
                self.temporary[path] = temporary
                with os.fdopen(descriptor, "wb") as handle:
                    handle.write(
                        json.dumps(
                            value,
                            ensure_ascii=False,
                            indent=2,
                            sort_keys=False,
                        ).encode("utf-8")
                    )
                    handle.write(b"\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temporary, 0o600)
            for path, _ in self.records:
                os.replace(str(self.temporary[path]), str(path))
                self.replaced.append(path)
        except Exception:
            self.rollback()
            raise
        finally:
            for temporary in self.temporary.values():
                temporary.unlink(missing_ok=True)

    def rollback(self) -> None:
        for path in reversed(self.replaced):
            original = self.originals.get(path)
            if original is None:
                path.unlink(missing_ok=True)
            else:
                self._write_bytes_atomic(path, original)
        self.replaced.clear()


class LoopbackHTTPServer(HTTPServer):
    def get_request(self) -> Tuple[Any, Any]:
        request, client_address = super().get_request()
        request.settimeout(REQUEST_IO_TIMEOUT_SECONDS)
        return request, client_address

    def handle_error(self, request: Any, client_address: Any) -> None:
        # Browser disconnects and slow/partial local requests are fail-closed and
        # must not leak tracebacks or authorization material to the console.
        return


class LocalApprovalSession:
    def __init__(
        self,
        harness: Any,
        item_id: str,
        *,
        clock: Optional[Callable[[], dt.datetime]] = None,
        session_ttl_seconds: int = SESSION_TTL_SECONDS,
    ):
        self.harness = harness
        self.clock = clock or (lambda: dt.datetime.now(dt.timezone.utc))
        self.presented_at = iso8601_utc(self.clock())
        self.snapshot = collect_review_snapshot(harness, item_id)
        token = secrets.token_urlsafe(32)
        self.page_nonce = secrets.token_urlsafe(18)
        self.session_ttl_seconds = session_ttl_seconds
        self.created_monotonic = time.monotonic()
        self.deadline = self.created_monotonic + session_ttl_seconds
        self.consumed = False
        self.outcome: Optional[str] = None

        def validate_token(supplied_token: str) -> None:
            if self.consumed:
                raise ApprovalConflict("审批会话已使用，禁止重放")
            if self._expired():
                raise ApprovalConflict("审批会话已过期")
            if not secrets.compare_digest(supplied_token, token):
                raise ApprovalRequestError("approval token 无效")

        def cancel_from_http(supplied_token: str) -> str:
            validate_token(supplied_token)
            self.consumed = True
            self.outcome = "cancelled"
            return self.outcome

        def decide_from_http(
            supplied_token: str,
            selected_option: str,
        ) -> str:
            validate_token(supplied_token)
            with self.harness.mutation_lock():
                current = collect_review_snapshot(
                    self.harness,
                    self.snapshot.item_id,
                )
                if current.binding() != self.snapshot.binding():
                    raise ApprovalConflict("决策页打开后候选或 Evidence 已变化")

                option_ids = {
                    option.get("id")
                    for option in current.decision_contract.get("options", [])
                    if isinstance(option, dict)
                }
                if selected_option not in option_ids:
                    raise ApprovalRequestError("selected_option 不在当前决策选项中")

                now = self.clock()
                decided_at = iso8601_utc(now)
                expires_at = iso8601_utc(now + APPROVAL_TTL)
                reviewer = local_reviewer()
                path = self.harness.resolve(
                    approval_relative_path(
                        self.harness,
                        current.item_id,
                        current.active_gate,
                    )
                )
                record = {
                    "schema_version": 1,
                    "work_item_id": current.item_id,
                    "gate": current.active_gate,
                    "work_item_sha256": current.work_item_sha256,
                    "tree_sha256": current.review_subject_sha256,
                    "evidence_sha256": current.evidence_sha256,
                    "decision_contract_sha256": (
                        current.decision_contract_sha256
                    ),
                    "selected_option": selected_option,
                    "presented_at": self.presented_at,
                    "decided_at": decided_at,
                    "reviewer": reviewer,
                    "approved_at": decided_at,
                    "expires_at": expires_at,
                    "signature": None,
                }

                transaction = ApprovalFileTransaction([(path, record)])
                transaction.commit()
                try:
                    outcome = self.harness.close(current.item_id)
                    if outcome not in {
                        "completed",
                        "awaiting_human",
                    }:
                        raise ApprovalRecoveryRequired(
                            f"Decision 已记录，但 close 尚未完成：{outcome}"
                        )
                    if outcome == "awaiting_human":
                        outcome = "human_decision_pending"
                except ApprovalRecoveryRequired:
                    self.consumed = True
                    self.outcome = "recovery_required"
                    raise
                except Exception as error:
                    # Preserve the human decision. Harness.close persists
                    # event/state/status separately; deleting Approval after a
                    # partial write would make deterministic recovery harder.
                    runtime = (
                        self.harness.state()
                        .get("work_items", {})
                        .get(current.item_id, {})
                    )
                    self.consumed = True
                    self.outcome = "recovery_required"
                    raise ApprovalRecoveryRequired(
                        "人工选择已记录，但 Harness close 需要恢复；"
                        f"当前状态为 {runtime.get('status')}: {error}"
                    ) from error

            self.consumed = True
            self.outcome = outcome
            return outcome

        self.server = LoopbackHTTPServer(
            (LOOPBACK_HOST, 0),
            self._handler_type(
                decide_callback=decide_from_http,
                cancel_callback=cancel_from_http,
            ),
        )
        self.port = int(self.server.server_address[1])
        self.expected_host = f"{LOOPBACK_HOST}:{self.port}"
        self.expected_origin = f"http://{self.expected_host}"
        self.__open_page = lambda opener: opener(
            f"{self.expected_origin}/#{token}"
        )

    def _handler_type(
        self,
        *,
        decide_callback: Callable[[str, str], str],
        cancel_callback: Callable[[str], str],
    ) -> type[BaseHTTPRequestHandler]:
        session = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, format: str, *args: Any) -> None:
                return

            def _security_headers(self) -> None:
                self.send_header("Cache-Control", "no-store, max-age=0")
                self.send_header("Pragma", "no-cache")
                self.send_header("Referrer-Policy", "no-referrer")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("X-Frame-Options", "DENY")
                self.send_header(
                    "Content-Security-Policy",
                    "default-src 'none'; "
                    f"style-src 'nonce-{session.page_nonce}'; "
                    f"script-src 'nonce-{session.page_nonce}'; connect-src 'self'; "
                    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
                )

            def _send(self, status: int, payload: bytes, content_type: str) -> None:
                self.send_response(status)
                self._security_headers()
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True

            def _send_json(self, status: int, value: Dict[str, Any]) -> None:
                self._send(
                    status,
                    json.dumps(value, ensure_ascii=False).encode("utf-8"),
                    "application/json; charset=utf-8",
                )

            def _host_is_valid(self) -> bool:
                return self.headers.get("Host") == session.expected_host

            def do_GET(self) -> None:
                if not self._host_is_valid():
                    self._send_json(400, {"error": "invalid_host"})
                    return
                if self.path != "/":
                    self._send_json(404, {"error": "not_found"})
                    return
                self._send(
                    200,
                    session.render_page().encode("utf-8"),
                    "text/html; charset=utf-8",
                )

            def do_POST(self) -> None:
                if not self._host_is_valid():
                    self._send_json(400, {"error": "invalid_host"})
                    return
                if self.path not in {"/api/decide", "/api/cancel"}:
                    self._send_json(404, {"error": "not_found"})
                    return
                if self.headers.get("Origin") != session.expected_origin:
                    self._send_json(403, {"error": "invalid_origin"})
                    return
                fetch_site = self.headers.get("Sec-Fetch-Site")
                if fetch_site is not None and fetch_site != "same-origin":
                    self._send_json(403, {"error": "invalid_fetch_site"})
                    return
                if not self.headers.get("Content-Type", "").lower().startswith(
                    "application/json"
                ):
                    self._send_json(415, {"error": "json_required"})
                    return
                try:
                    content_length = int(self.headers.get("Content-Length", ""))
                except ValueError:
                    self._send_json(400, {"error": "invalid_content_length"})
                    return
                if content_length < 0 or content_length > MAX_REQUEST_BYTES:
                    self._send_json(413, {"error": "request_too_large"})
                    return
                body = self.rfile.read(content_length)
                try:
                    value = json.loads(body.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    self._send_json(400, {"error": "invalid_json"})
                    return
                supplied_token = self.headers.get("X-Approval-Token", "")
                try:
                    if self.path == "/api/cancel":
                        if value != {}:
                            self._send_json(400, {"error": "unexpected_fields"})
                            return
                        outcome = cancel_callback(supplied_token)
                    else:
                        if (
                            not isinstance(value, dict)
                            or set(value) != {"selected_option"}
                            or not isinstance(value.get("selected_option"), str)
                        ):
                            self._send_json(
                                400,
                                {"error": "selected_option_required"},
                            )
                            return
                        outcome = decide_callback(
                            supplied_token,
                            value["selected_option"],
                        )
                except ApprovalRequestError as error:
                    self._send_json(403, {"error": str(error)})
                    return
                except ApprovalConflict as error:
                    if session.outcome is None:
                        session.outcome = "stale"
                    self._send_json(409, {"error": str(error)})
                    return
                except ApprovalRecoveryRequired as error:
                    session.outcome = "recovery_required"
                    self._send_json(
                        202,
                        {
                            "outcome": "recovery_required",
                            "error": str(error),
                        },
                    )
                    return
                except ApprovalUIError as error:
                    session.outcome = "failed"
                    self._send_json(500, {"error": str(error)})
                    return
                except Exception:
                    session.outcome = "failed"
                    self._send_json(500, {"error": "决策处理失败，任务未完成"})
                    return
                self._send_json(200, {"outcome": outcome})

        return Handler

    def _expired(self) -> bool:
        return time.monotonic() >= self.deadline

    def render_page(self) -> str:
        snapshot = self.snapshot
        decision = snapshot.decision_contract
        recommended = str(decision["recommended_option"])
        option_rows = "".join(
            "<label class=\"option\">"
            f"<input type=\"radio\" name=\"decision-option\" value=\"{html.escape(str(option['id']))}\">"
            "<span>"
            f"<strong>{html.escape(str(option['label']))}</strong>"
            + (
                " <em>推荐</em>"
                if option["id"] == recommended
                else ""
            )
            + f"<small>{html.escape(str(option['consequence']))}</small>"
            + (
                "<small>可逆</small>"
                if option["reversible"]
                else "<small class=\"irreversible\">不可逆</small>"
            )
            + "</span></label>"
            for option in decision["options"]
        )
        file_rows = "".join(
            "<tr>"
            f"<td>{html.escape(path)}</td>"
            f"<td><code>{html.escape(digest)}</code></td>"
            "</tr>"
            for path, digest in snapshot.review_subject_files
        )
        return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Harness 人工决策</title>
  <style nonce="{html.escape(self.page_nonce)}">
    body {{ margin: 0; background: #f4f5f7; color: #17191d; font: 15px -apple-system, BlinkMacSystemFont, sans-serif; }}
    main {{ max-width: 980px; margin: 32px auto; padding: 0 20px 48px; }}
    section {{ background: white; border: 1px solid #dfe2e7; border-radius: 14px; padding: 22px; margin: 14px 0; }}
    h1 {{ margin: 0 0 8px; }} h2 {{ font-size: 17px; }}
    .warn {{ color: #7a3e00; background: #fff4dc; border-color: #f1cd85; }}
    .question {{ font-size: 20px; line-height: 1.45; }}
    .option {{ display: flex; gap: 12px; border: 1px solid #dfe2e7; border-radius: 12px; padding: 14px; margin: 10px 0; cursor: pointer; }}
    .option:has(input:checked) {{ border-color: #1677ff; background: #f1f7ff; }}
    .option input {{ margin-top: 4px; }}
    .option span {{ display: grid; gap: 5px; }}
    .option small {{ color: #5f6670; }}
    .option em {{ color: #0d6b34; font-style: normal; font-size: 12px; }}
    .irreversible {{ color: #a12622 !important; font-weight: 650; }}
    code {{ font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; overflow-wrap: anywhere; }}
    table {{ width: 100%; border-collapse: collapse; table-layout: fixed; }}
    td, th {{ padding: 8px; border-bottom: 1px solid #eceef1; text-align: left; overflow-wrap: anywhere; }}
    th:first-child, td:first-child {{ width: 48%; }}
    button {{ border: 0; border-radius: 10px; padding: 12px 18px; font-weight: 650; cursor: pointer; }}
    #decide {{ background: #1677ff; color: white; }}
    #cancel {{ background: #e8eaed; margin-left: 8px; }}
    button:disabled {{ opacity: .55; cursor: wait; }}
    #result {{ margin-top: 12px; font-weight: 600; }}
  </style>
</head>
<body>
<main>
  <h1>需要你的具体决策</h1>
  <p>{html.escape(snapshot.title)}</p>
  <p><code>{html.escape(snapshot.item_id)}</code> · attempt {snapshot.attempt}</p>
  <section class="warn">
    <strong>这是项目取舍，不是发布授权</strong>
    <p>本地选择只记录你在互斥方案中的决定。知识、Golden、Requirement、ADR 或 patch promotion 仍须由外部受信服务签名。</p>
  </section>
  <section>
    <p><code>{html.escape(snapshot.active_gate)}</code> · 尚有 {snapshot.unresolved_count} 项未决</p>
    <p class="question">{html.escape(str(decision["question"]))}</p>
    <p><strong>为什么机器不能决定：</strong>{html.escape(str(decision["why_human"]))}</p>
    <div>{option_rows}</div>
  </section>
  <section>
    <h2>冻结证据</h2>
    <p>Review subject：<code>{html.escape(snapshot.review_subject_sha256)}</code></p>
    <p>Work Item：<code>{html.escape(snapshot.work_item_sha256)}</code></p>
    <p>Evidence：<code>{html.escape(snapshot.evidence_path)}</code></p>
    <p>Evidence SHA-256：<code>{html.escape(snapshot.evidence_sha256)}</code></p>
    <details><summary>冻结文件（{len(snapshot.review_subject_files)}）</summary>
      <table><thead><tr><th>路径</th><th>内容摘要</th></tr></thead><tbody>{file_rows}</tbody></table>
    </details>
  </section>
  <section>
    <button id="decide" type="button">记录所选方案</button>
    <button id="cancel" type="button">暂不决定</button>
    <div id="result" role="status" aria-live="polite"></div>
  </section>
</main>
<script nonce="{html.escape(self.page_nonce)}">
(() => {{
  const decide = document.getElementById("decide");
  const cancel = document.getElementById("cancel");
  const result = document.getElementById("result");
  const token = location.hash.slice(1);
  history.replaceState(null, "", "/");
  if (!token) {{
    decide.disabled = true;
    result.textContent = "决策会话 token 缺失，请重新运行 Harness review。";
    return;
  }}
  cancel.addEventListener("click", async () => {{
    decide.disabled = true;
    cancel.disabled = true;
    result.textContent = "正在结束本次决策会话…";
    try {{
      const response = await fetch("/api/cancel", {{
        method: "POST",
        credentials: "omit",
        cache: "no-store",
        headers: {{
          "Content-Type": "application/json",
          "X-Approval-Token": token
        }},
        body: "{{}}"
      }});
      if (!response.ok) throw new Error(`HTTP ${{response.status}}`);
      result.textContent = "未作选择，会话已结束；未写入 Decision record。";
    }} catch (error) {{
      result.textContent = `结束会话失败：${{error.message}}`;
    }}
  }});
  decide.addEventListener("click", async () => {{
    const selected = document.querySelector('input[name="decision-option"]:checked');
    if (!selected) {{
      result.textContent = "请先选择一个具体方案。";
      return;
    }}
    decide.disabled = true;
    cancel.disabled = true;
    result.textContent = "正在重新校验冻结事实并记录选择…";
    try {{
      const response = await fetch("/api/decide", {{
        method: "POST",
        credentials: "omit",
        cache: "no-store",
        headers: {{
          "Content-Type": "application/json",
          "X-Approval-Token": token
        }},
        body: JSON.stringify({{ selected_option: selected.value }})
      }});
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || `HTTP ${{response.status}}`);
      if (payload.outcome === "completed") {{
        result.textContent = "选择已记录，工作项已完成。";
      }} else if (payload.outcome === "human_decision_pending") {{
        result.textContent = "选择已记录；下一项具体决策将自动打开。";
      }} else if (payload.outcome === "recovery_required") {{
        result.textContent = "选择已记录，但 Harness 关闭事务需要恢复；请保留页面并查看终端。";
      }} else {{
        throw new Error(`未知结果：${{payload.outcome}}`);
      }}
    }} catch (error) {{
      result.textContent = `未记录选择：${{error.message}}`;
    }}
  }});
}})();
</script>
</body>
</html>
"""

    def serve(
        self,
        *,
        browser_opener: Callable[[str], bool] = webbrowser.open,
    ) -> str:
        if not self.__open_page(browser_opener):
            self.server.server_close()
            raise ApprovalUIError("无法打开本地浏览器；未输出 token，也未写 Approval")
        try:
            while self.outcome is None and not self._expired():
                self.server.timeout = min(
                    0.25,
                    max(0.01, self.deadline - time.monotonic()),
                )
                self.server.handle_request()
            if self.outcome is None:
                raise ApprovalUIError("本地审批会话已超时；未写 Approval")
            if self.outcome == "recovery_required":
                raise ApprovalUIError(
                    "人工决定已记录，但 Harness close 需要恢复；请运行 doctor 并重试 close"
                )
            if self.outcome not in {
                "completed",
                "human_decision_pending",
            }:
                raise ApprovalUIError(f"本地决策未完成：{self.outcome}")
            return self.outcome
        finally:
            self.server.server_close()


def run_local_review(harness: Any, item_id: str) -> str:
    while True:
        session = LocalApprovalSession(harness, item_id)
        print(
            "本地决策页已在浏览器打开；"
            "一次只记录一个具体选择（授权 token 不会输出）…"
        )
        outcome = session.serve()
        if outcome == "completed":
            return outcome
