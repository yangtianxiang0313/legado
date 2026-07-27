import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


HARNESS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HARNESS_DIR))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import codex_agent_adapter as adapter  # noqa: E402
from test_harness import HarnessFixture  # noqa: E402


class AdapterFixture:
    thread_id = "thread_12345678"

    def __init__(self, root):
        self.root = root
        self.fixture = HarnessFixture(root)
        self.harness = self.fixture.initialize()
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.name", "Adapter Test"], cwd=root, check=True
        )
        subprocess.run(
            ["git", "config", "user.email", "adapter@example.invalid"],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=root, check=True)
        self.codex_home = root / "codex-home"
        self.codex_home.mkdir()
        self.context_path = root / "context.json"
        context = self.harness.context_packet("IOS-BOOT-001")
        context["private_marker"] = "context-secret-marker"
        self.context_path.write_text(
            json.dumps(context, ensure_ascii=False), encoding="utf-8"
        )
        os.chmod(self.context_path, 0o600)
        self.environment = {
            "PATH": os.environ.get("PATH", ""),
            "LEGADO_WORK_ITEM_ID": "IOS-BOOT-001",
            "LEGADO_CONTEXT_PATH": str(self.context_path),
            "HOST_SECRET": "must-not-reach-child",
        }

    def fake(self, mode="success"):
        path = self.root / f"fake-codex-{mode}.py"
        source = f"""#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

if "--version" in sys.argv:
    print("codex-cli 0.130.0-test")
    raise SystemExit(0)

prompt = sys.stdin.read()
home = Path(os.environ["CODEX_HOME"])
with (home / "invocations.jsonl").open("a", encoding="utf-8") as handle:
    handle.write(json.dumps({{
        "argv": sys.argv[1:],
        "prompt": prompt,
        "host_secret": os.environ.get("HOST_SECRET"),
        "codex_home": os.environ.get("CODEX_HOME"),
    }}) + "\\n")
mode = {mode!r}
if mode == "malformed":
    print("not-json")
    raise SystemExit(0)
print(json.dumps({{"type": "thread.started", "thread_id": {self.thread_id!r}}}))
print(json.dumps({{"type": "turn.started"}}))
if mode == "failed":
    print(json.dumps({{"type": "turn.failed", "error": "private failure body"}}))
    raise SystemExit(1)
if mode == "leak":
    print(json.dumps({{"type": "item.completed", "item": {{
        "type": "agent_message", "text": "agent-private-message"
    }}}}))
print(json.dumps({{"type": "turn.completed", "usage": {{
    "input_tokens": 12, "output_tokens": 3
}}}}))
"""
        path.write_text(source, encoding="utf-8")
        os.chmod(path, 0o700)
        return path

    def run(self, executable, **overrides):
        arguments = {
            "executable": str(executable),
            "codex_home": self.codex_home,
            "repo": self.root,
            "context_path": self.context_path,
            "work_item_id": "IOS-BOOT-001",
            "environment": self.environment,
        }
        arguments.update(overrides)
        return adapter.run_adapter(**arguments)

    def invocations(self):
        path = self.codex_home / "invocations.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()]


class CodexAgentAdapterTests(unittest.TestCase):
    def test_doctor_reports_regular_symlink_nonzero_and_broken(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = AdapterFixture(Path(directory))
            good = fixture.fake()
            result = adapter.doctor(str(good), fixture.environment)
            self.assertEqual("available", result["status"])
            self.assertEqual("CODEX_EXECUTABLE_READY", result["reason_code"])

            link = fixture.root / "codex-link"
            link.symlink_to(good)
            self.assertEqual(
                "EXECUTABLE_SYMLINK_REJECTED",
                adapter.doctor(str(link), fixture.environment)["reason_code"],
            )

            nonexec = fixture.root / "codex-nonexec"
            nonexec.write_text("#!/bin/sh\n")
            self.assertEqual(
                "EXECUTABLE_NOT_EXECUTABLE",
                adapter.doctor(str(nonexec), fixture.environment)["reason_code"],
            )

            nonzero = fixture.root / "codex-nonzero"
            nonzero.write_text("#!/bin/sh\nexit 7\n")
            os.chmod(nonzero, 0o700)
            self.assertEqual(
                "VERSION_EXIT_NONZERO",
                adapter.doctor(str(nonzero), fixture.environment)["reason_code"],
            )

            broken = fixture.root / "codex-broken"
            broken.write_text("#!/missing/interpreter\n")
            os.chmod(broken, 0o700)
            self.assertEqual(
                "EXECUTABLE_BROKEN",
                adapter.doctor(str(broken), fixture.environment)["reason_code"],
            )

    def test_first_turn_resume_and_secret_minimization(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = AdapterFixture(Path(directory))
            executable = fixture.fake("leak")
            first = fixture.run(executable)
            self.assertEqual("completed_turn", first["outcome"])
            self.assertEqual("new", first["invocation"])
            self.assertEqual(fixture.thread_id, first["thread_id"])
            rendered = json.dumps(first)
            self.assertNotIn("agent-private-message", rendered)
            self.assertNotIn("context-secret-marker", rendered)
            self.assertNotIn("must-not-reach-child", rendered)

            second = fixture.run(executable)
            self.assertEqual("resume", second["invocation"])
            calls = fixture.invocations()
            self.assertEqual(2, len(calls))
            self.assertNotIn("resume", calls[0]["argv"])
            self.assertIn("resume", calls[1]["argv"])
            self.assertIn(fixture.thread_id, calls[1]["argv"])
            for call in calls:
                self.assertIsNone(call["host_secret"])
                self.assertEqual(str(fixture.codex_home), call["codex_home"])
                self.assertNotIn("context-secret-marker", call["prompt"])
                self.assertNotIn("context-secret-marker", json.dumps(call["argv"]))
                self.assertEqual("-", call["argv"][-1])
                self.assertIn("workspace-write", call["argv"])
                self.assertIn("never", call["argv"])
                for forbidden in (
                    "--yolo",
                    "--full-auto",
                    "danger-full-access",
                ):
                    self.assertNotIn(forbidden, call["argv"])

            session = (
                fixture.root
                / ".harness-runtime/codex-sessions/IOS-BOOT-001.json"
            )
            self.assertEqual(0o600, stat.S_IMODE(session.stat().st_mode))
            self.assertNotIn("context-secret-marker", session.read_text())
            self.assertNotIn("must-not-reach-child", session.read_text())

    def test_context_binding_fails_before_codex_start(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = AdapterFixture(Path(directory))
            executable = fixture.fake()
            os.chmod(fixture.context_path, 0o644)
            with self.assertRaisesRegex(
                adapter.AdapterError, "0o644"
            ) as caught:
                fixture.run(executable)
            self.assertEqual(
                "CONTEXT_PERMISSIONS_TOO_BROAD",
                caught.exception.reason_code,
            )
            self.assertFalse((fixture.codex_home / "invocations.jsonl").exists())

            os.chmod(fixture.context_path, 0o600)
            fixture.environment["LEGADO_WORK_ITEM_ID"] = "IOS-OTHER-001"
            with self.assertRaises(adapter.AdapterError) as caught:
                fixture.run(executable)
            self.assertEqual("WORK_ITEM_ENV_MISMATCH", caught.exception.reason_code)
            self.assertFalse((fixture.codex_home / "invocations.jsonl").exists())

    def test_failure_malformed_and_output_limit_do_not_advance_session(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = AdapterFixture(Path(directory))
            failed = fixture.fake("failed")
            with self.assertRaises(adapter.AdapterError) as caught:
                fixture.run(failed)
            self.assertEqual("TURN_FAILED", caught.exception.reason_code)
            session = (
                fixture.root
                / ".harness-runtime/codex-sessions/IOS-BOOT-001.json"
            )
            self.assertFalse(session.exists())

            malformed = fixture.fake("malformed")
            with self.assertRaises(adapter.AdapterError) as caught:
                fixture.run(malformed)
            self.assertEqual("JSONL_MALFORMED", caught.exception.reason_code)
            self.assertFalse(session.exists())

            success = fixture.fake("success")
            with self.assertRaises(adapter.AdapterError) as caught:
                fixture.run(success, max_jsonl_bytes=10)
            self.assertEqual(
                "JSONL_OUTPUT_LIMIT_EXCEEDED",
                caught.exception.reason_code,
            )
            self.assertFalse(session.exists())

    def test_session_binding_drift_and_symlink_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = AdapterFixture(Path(directory))
            executable = fixture.fake()
            fixture.run(executable)
            session = (
                fixture.root
                / ".harness-runtime/codex-sessions/IOS-BOOT-001.json"
            )
            value = json.loads(session.read_text())
            value["work_item_sha256"] = "f" * 64
            session.write_text(json.dumps(value))
            with self.assertRaises(adapter.AdapterError) as caught:
                fixture.run(executable)
            self.assertEqual("SESSION_BINDING_DRIFT", caught.exception.reason_code)

            session.unlink()
            target = fixture.root / "session-target"
            target.write_text("{}")
            session.symlink_to(target)
            with self.assertRaises(adapter.AdapterError) as caught:
                fixture.run(executable)
            self.assertEqual("SESSION_SYMLINK_REJECTED", caught.exception.reason_code)

    def test_parser_rejects_thread_drift_unknown_terminal_and_missing_events(self):
        valid_prefix = (
            b'{"type":"thread.started","thread_id":"thread_12345678"}\n'
            b'{"type":"turn.started"}\n'
        )
        with self.assertRaises(adapter.AdapterError) as caught:
            adapter._parse_jsonl(
                valid_prefix + b'{"type":"turn.cancelled"}\n',
                None,
                10000,
            )
        self.assertEqual("UNKNOWN_TERMINAL_EVENT", caught.exception.reason_code)
        with self.assertRaises(adapter.AdapterError) as caught:
            adapter._parse_jsonl(
                valid_prefix + b'{"type":"turn.completed"}\n',
                "thread_other_123",
                10000,
            )
        self.assertEqual("THREAD_ID_DRIFT", caught.exception.reason_code)
        with self.assertRaises(adapter.AdapterError) as caught:
            adapter._parse_jsonl(
                b'{"type":"thread.started","thread_id":"thread_12345678"}\n',
                None,
                10000,
            )
        self.assertEqual(
            "TURN_STARTED_COUNT_INVALID",
            caught.exception.reason_code,
        )

    def test_current_machine_doctor_is_truthful(self):
        path = Path("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js")
        if not path.exists():
            self.skipTest("global Codex launcher is not installed")
        result = adapter.doctor(str(path))
        self.assertIn(result["status"], {"available", "unavailable"})
        if result["status"] == "unavailable":
            self.assertIn(
                result["reason_code"],
                {
                    "EXECUTABLE_BROKEN",
                    "VERSION_EXIT_NONZERO",
                    "VERSION_TIMEOUT",
                    "VERSION_EMPTY",
                },
            )


if __name__ == "__main__":
    unittest.main()
