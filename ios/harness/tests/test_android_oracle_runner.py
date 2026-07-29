import importlib.util
import base64
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[3]
RUNNER_PATH = (
    ROOT
    / "ios/harness/oracle/android-runner/orchestrator.py"
)
SPEC = importlib.util.spec_from_file_location(
    "android_oracle_orchestrator",
    RUNNER_PATH,
)
assert SPEC is not None and SPEC.loader is not None
runner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runner
SPEC.loader.exec_module(runner)


def bindings():
    return {
        "android_git_commit": "a" * 40,
        "android_git_tree": "b" * 40,
        "runner_id": runner.RUNNER_VERSION,
        "runner_digest": "c" * 64,
        "fixture_sha256": "d" * 64,
        "scenario_sha256": "e" * 64,
        "source_template_sha256": "f" * 64,
        "input_sha256": "1" * 64,
        "case_sha256": "2" * 64,
        "fixture_manifest_sha256": "3" * 64,
        "source_lab_manifest_sha256": "4" * 64,
        "canonicalizer_sha256": "5" * 64,
    }


def raw_artifact():
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(runner.EXPECTED_CASES):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/case-{index}",
            "headers": [],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {"value": index},
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": runner.SCENARIO_ID,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


def post_raw_artifact():
    requests = []
    cases = []
    values = (
        (
            "post-form-nominal",
            [
                {"key": "keyword", "value": "%E6%98%9F%E6%B2%B3"},
                {"key": "author", "value": "%E5%8C%97%E8%BE%B0"},
            ],
        ),
        (
            "post-form-boundary",
            [
                {"key": "empty", "value": ""},
                {"key": "dup", "value": "second"},
                {"key": "encoded", "value": "%E6%98%9F%E6%B2%B3"},
            ],
        ),
    )
    for case_id, fields in values:
        body = "&".join(
            f"{value['key']}={value['value']}"
            for value in fields
        )
        request = {
            "method": "POST",
            "url": f"{runner.LOGICAL_ORIGIN}/post/{case_id.split('-')[-1]}",
            "headers": [],
            "body": body,
            "body_base64": base64.b64encode(
                body.encode("utf-8")
            ).decode("ascii"),
            "form_fields": fields,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": "search",
                "request": request,
                "result": {"books": []},
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": "sl-post-form-001",
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


def xml_raw_artifact():
    scenario = "sl-source-response-xml-declaration-normalization-001"
    values = (
        (
            "xml-missing-declaration",
            "<?xml version=\"1.0\"?><feed><title>星河</title></feed>\n",
        ),
        (
            "xml-existing-declaration",
            "  <?XML version=\"1.0\"?><feed><title>既有声明</title></feed>\n",
        ),
        (
            "non-xml-content-type",
            "<feed><title>文本响应</title></feed>\n",
        ),
    )
    requests = []
    cases = []
    for case_id, body in values:
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/xml/{case_id}",
            "headers": [],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": "raw_response",
                "request": request,
                "result": {
                    "body": body,
                    "final_url": request["url"],
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


def request_option_raw_artifact():
    scenario = "sl-source-request-header-cookie-retry-layering-001"
    values = (
        ("retry-two-with-header-cookie", 7),
        ("retry-default", 5),
    )
    requests = []
    cases = []
    for case_id, retry in values:
        headers = [{"name": "X-Layer", "value": case_id}]
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/request-options/{case_id}",
            "headers": headers,
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": "request_options",
                "request": request,
                "result": {
                    "inherited_headers": headers,
                    "constructed_headers": headers,
                    "resolved_headers": headers,
                    "network_headers": headers,
                    "retry": retry,
                    "status_code": 503,
                    "body": "retryable\n",
                    "final_url": request["url"],
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": {
            "retry-two-with-header-cookie": 11,
            "retry-default": 13,
        },
    }


def rate_limit_raw_artifact():
    scenario = "sl-source-session-rate-limit-shared-state-001"
    values = (
        ("disabled-zero", {"active": False, "rate": "0"}),
        (
            "interval-shared-key",
            {
                "first_allowed": True,
                "second_same_key_denied": True,
                "after_end_still_denied": True,
                "record_mode": "minimum_interval",
                "frequency_on_denial": 1,
            },
        ),
        (
            "window-count-boundary",
            {
                "allowed_before_denial": 3,
                "denied_wait_positive": True,
                "record_mode": "count_per_window",
                "frequency_on_denial": 3,
            },
        ),
        (
            "distinct-source-keys",
            {"both_allowed": True, "records_are_distinct": True},
        ),
        (
            "invalid-interval",
            {
                "both_allowed": True,
                "same_record": True,
                "is_count_window": False,
                "frequency_after_second": 1,
            },
        ),
        (
            "invalid-window",
            {
                "both_allowed": True,
                "same_record": True,
                "is_count_window": True,
                "frequency_after_second": 1,
            },
        ),
    )
    requests = []
    cases = []
    for case_id, result in values:
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/rate-limit/{case_id}",
            "headers": [],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": "rate_limit_state",
                "request": request,
                "result": result,
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


def transport_dispatch_raw_artifact():
    scenario = "sl-source-transport-request-dispatch-contract-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    route_counts = {}
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        method = (
            "POST"
            if case_id in {
                "post-raw-content-type",
                "post-json-default",
            }
            else "GET"
        )
        url = (
            "data:application/octet-stream;base64,U291cmNlTGFi"
            if case_id == "data-uri-short-circuit"
            else f"{runner.LOGICAL_ORIGIN}/transport/{case_id}"
        )
        body = (
            "{\"keyword\":\"星河\"}"
            if case_id == "post-json-default"
            else "raw=星河"
            if case_id == "post-raw-content-type"
            else None
        )
        headers = (
            [{"name": "Content-Type", "value": "application/json"}]
            if case_id == "post-json-default"
            else [{"name": "Content-Type", "value": "text/plain"}]
            if case_id == "post-raw-content-type"
            else []
        )
        request = {
            "method": method,
            "url": url,
            "headers": headers,
            "body": body,
            "timeout_ms": 750
            if case_id == "proxy-timeout-policy"
            else None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {"observed_case": index},
                "issue": None,
            }
        )
        if case_id in runner.ROUTE_OBSERVATION_SCENARIOS[scenario]:
            route_counts[case_id] = index + 1
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": route_counts,
    }


def response_decoding_raw_artifact():
    scenario = "sl-source-transport-response-decoding-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for case_id, operation in contract["expected_cases"]:
        path = (
            "/decode/redirect-start"
            if case_id == "redirect-final-url"
            else f"/decode/{case_id}"
        )
        request = {
            "method": "GET",
            "url": runner.LOGICAL_ORIGIN + path,
            "headers": [
                {"name": "X-Source", "value": "response-decoding"}
            ],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        denied = case_id == "redirect-loop-denied"
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": None
                if denied
                else {
                    "body": f"body-{case_id}",
                    "final_url": (
                        runner.LOGICAL_ORIGIN + "/decode/redirect-final"
                        if case_id == "redirect-final-url"
                        else request["url"]
                    ),
                    "status_code": 200,
                    "is_successful": True,
                },
                "issue": {
                    "code": "android_exception",
                    "exception_type": "java.net.ProtocolException",
                }
                if denied
                else None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": {
            route_id: 1
            for route_id in runner.ROUTE_OBSERVATION_SCENARIOS[scenario]
        },
    }


def retry_redirect_raw_artifact():
    scenario = "sl-source-transport-retry-redirect-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/retry/{case_id}",
            "headers": [
                {"name": "x-source", "value": "retry-redirect"}
            ],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "configured_retry": index % 3,
                    "attempt_count": index + 1,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": {
            route_id: index + 1
            for index, route_id in enumerate(
                runner.ROUTE_OBSERVATION_SCENARIOS[scenario]
            )
        },
    }


def cookie_session_raw_artifact():
    scenario = "sl-source-cookie-persistent-session-merge-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/cookie/{case_id}",
            "headers": [
                {"name": "x-source", "value": "cookie-session"}
            ],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "domain": "sourcelab.test",
                    "combined_cookie": f"case={index}",
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": {
            route_id: index + 1
            for index, route_id in enumerate(
                runner.ROUTE_OBSERVATION_SCENARIOS[scenario]
            )
        },
    }


def dynamic_web_raw_artifact():
    scenario = "sl-source-transport-dynamic-web-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for case_id, operation in contract["expected_cases"]:
        method = "POST" if case_id == "post-http-then-webview" else "GET"
        request = {
            "method": method,
            "url": f"{runner.LOGICAL_ORIGIN}/dynamic/{case_id}",
            "headers": [
                {"name": "x-source", "value": "dynamic-web"}
            ],
            "body": (
                "{\"probe\":\"post-bootstrap\"}"
                if method == "POST"
                else None
            ),
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "body": f"result-{case_id}",
                    "final_url": request["url"],
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": {
            route_id: 1
            for route_id in runner.ROUTE_OBSERVATION_SCENARIOS[scenario]
        },
    }


def rule_variable_scope_raw_artifact():
    scenario = "sl-source-session-rule-variable-scope-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/variables/{case_id}",
            "headers": [],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "scope_value": case_id,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


def rule_backend_dispatch_raw_artifact():
    scenario = "sl-source-rule-backend-dispatch-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/rule-dispatch/{case_id}",
            "headers": [],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "dispatch_value": case_id,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


def content_cache_queue_completion_raw_artifact():
    scenario = "sl-content-cache-queue-completion-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/cache/{case_id}",
            "headers": [],
            "body": None,
            "timeout_ms": None,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "cache_value": case_id,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
    }


class AndroidOracleRunnerTests(unittest.TestCase):
    def test_doctor_binds_frozen_android_tree_and_exposes_no_authority(self):
        report = runner.doctor(ROOT)
        self.assertTrue(report["ok"])
        self.assertEqual(
            "30bfdf70224ed3006f2777777ff414ebdb3a9eb3",
            report["android_git_commit"],
        )
        self.assertEqual(
            "c81f5d383116e37c1eefee3eb86654514e82022b",
            report["android_git_tree"],
        )
        self.assertEqual(["doctor", "run"], report["commands"])
        for forbidden in (
            "accept",
            "publish",
            "promote",
            "record",
            "update-golden",
        ):
            self.assertNotIn(forbidden, report["commands"])
        post = runner.doctor(ROOT, "sl-post-form-001")
        self.assertEqual("sl-post-form-001", post["scenario_id"])
        xml = runner.doctor(
            ROOT,
            "sl-source-response-xml-declaration-normalization-001",
        )
        self.assertEqual(
            "sl-source-response-xml-declaration-normalization-001",
            xml["scenario_id"],
        )
        request_options = runner.doctor(
            ROOT,
            "sl-source-request-header-cookie-retry-layering-001",
        )
        self.assertEqual(
            "sl-source-request-header-cookie-retry-layering-001",
            request_options["scenario_id"],
        )
        url_template = runner.doctor(
            ROOT,
            "sl-source-request-url-template-compilation-001",
        )
        self.assertEqual(
            "sl-source-request-url-template-compilation-001",
            url_template["scenario_id"],
        )
        rate_limit = runner.doctor(
            ROOT,
            "sl-source-session-rate-limit-shared-state-001",
        )
        self.assertEqual(
            "sl-source-session-rate-limit-shared-state-001",
            rate_limit["scenario_id"],
        )
        transport_dispatch = runner.doctor(
            ROOT,
            "sl-source-transport-request-dispatch-contract-001",
        )
        self.assertEqual(
            "sl-source-transport-request-dispatch-contract-001",
            transport_dispatch["scenario_id"],
        )
        response_decoding = runner.doctor(
            ROOT,
            "sl-source-transport-response-decoding-runtime-001",
        )
        self.assertEqual(
            "sl-source-transport-response-decoding-runtime-001",
            response_decoding["scenario_id"],
        )
        retry_redirect = runner.doctor(
            ROOT,
            "sl-source-transport-retry-redirect-runtime-001",
        )
        self.assertEqual(
            "sl-source-transport-retry-redirect-runtime-001",
            retry_redirect["scenario_id"],
        )
        cookie_session = runner.doctor(
            ROOT,
            "sl-source-cookie-persistent-session-merge-runtime-001",
        )
        self.assertEqual(
            "sl-source-cookie-persistent-session-merge-runtime-001",
            cookie_session["scenario_id"],
        )
        dynamic_web = runner.doctor(
            ROOT,
            "sl-source-transport-dynamic-web-runtime-001",
        )
        self.assertEqual(
            "sl-source-transport-dynamic-web-runtime-001",
            dynamic_web["scenario_id"],
        )
        rule_variable_scope = runner.doctor(
            ROOT,
            "sl-source-session-rule-variable-scope-001",
        )
        self.assertEqual(
            "sl-source-session-rule-variable-scope-001",
            rule_variable_scope["scenario_id"],
        )
        rule_backend_dispatch = runner.doctor(
            ROOT,
            "sl-source-rule-backend-dispatch-runtime-001",
        )
        self.assertEqual(
            "sl-source-rule-backend-dispatch-runtime-001",
            rule_backend_dispatch["scenario_id"],
        )
        content_cache_queue_completion = runner.doctor(
            ROOT,
            "sl-content-cache-queue-completion-runtime-001",
        )
        self.assertEqual(
            "sl-content-cache-queue-completion-runtime-001",
            content_cache_queue_completion["scenario_id"],
        )
        with mock.patch.object(
            runner,
            "fixture_digest",
            return_value="0" * 64,
        ):
            with self.assertRaisesRegex(
                runner.AndroidOracleRunnerError,
                "FIXTURE_DIGEST_DRIFT",
            ):
                runner.repository_bindings(
                    ROOT,
                    "sl-source-session-rate-limit-shared-state-001",
                )

    def test_product_tree_drift_fails_before_runner_execution(self):
        baseline = {
            "android_oracle": {"git_commit": "a" * 40}
        }
        inventory = {
            "android_git_commit": "a" * 40,
            "android_tree": "b" * 40,
        }
        with (
            mock.patch.object(
                runner,
                "_read_json",
                side_effect=[baseline, inventory],
            ),
            mock.patch.object(
                runner,
                "_git",
                side_effect=[b"b" * 40 + b"\n", b"app/src/main/X.kt\n", b""],
            ),
        ):
            with self.assertRaisesRegex(
                runner.AndroidOracleRunnerError,
                "ANDROID_PRODUCT_TREE_DRIFT",
            ):
                runner.frozen_identity(ROOT)

    def test_raw_android_cases_become_structured_execution_envelope(self):
        artifact = runner.normalize_raw_artifact(
            raw_artifact(),
            bindings(),
        )
        self.assertEqual(1, artifact["schema_version"])
        self.assertEqual(runner.SCENARIO_ID, artifact["fixture_id"])
        self.assertEqual("android", artifact["engine"]["platform"])
        self.assertEqual("source_pipeline", artifact["result"]["type"])
        lanes = artifact["result"]["value"]
        self.assertEqual(
            {
                "fixture_integrity",
                "portable_known_projection",
                "android_characterization",
            },
            set(lanes),
        )
        self.assertEqual(
            len(runner.EXPECTED_CASES),
            len(lanes["portable_known_projection"]["cases"]),
        )
        self.assertEqual(
            len(runner.EXPECTED_CASES) * 8,
            len(artifact["stages"]),
        )
        self.assertNotIn(
            "127.0.0.1",
            json.dumps(artifact, ensure_ascii=False),
        )

    def test_post_form_android_request_plan_preserves_ordered_fields_and_bytes(self):
        artifact = runner.normalize_raw_artifact(
            post_raw_artifact(),
            {
                **bindings(),
                "scenario_id": "sl-post-form-001",
            },
            "sl-post-form-001",
        )
        self.assertEqual(
            "sl-post-form-001",
            artifact["fixture_id"],
        )
        nominal, boundary = artifact["request_plan"]
        self.assertEqual("POST", nominal["method"])
        self.assertEqual(
            nominal["body"].encode("utf-8"),
            base64.b64decode(nominal["body_base64"]),
        )
        self.assertEqual(
            ["empty", "dup", "encoded"],
            [
                value["key"]
                for value in boundary["form_fields"]
            ],
        )
        self.assertEqual(
            "second",
            boundary["form_fields"][1]["value"],
        )

        drift = post_raw_artifact()
        drift["request_plan"][0]["body_base64"] = base64.b64encode(
            b"wrong"
        ).decode("ascii")
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "RAW_POST_BODY_BINDING_DRIFT",
        ):
            runner.normalize_raw_artifact(
                drift,
                bindings(),
                "sl-post-form-001",
            )

    def test_xml_response_characterization_preserves_android_bodies(self):
        scenario = "sl-source-response-xml-declaration-normalization-001"
        artifact = runner.normalize_raw_artifact(
            xml_raw_artifact(),
            bindings(),
            scenario,
        )
        cases = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            "<?xml version=\"1.0\"?><feed><title>星河</title></feed>\n",
            cases[0]["result"]["body"],
        )
        self.assertTrue(
            cases[1]["result"]["body"].startswith("  <?XML")
        )
        self.assertTrue(
            cases[2]["result"]["body"].startswith("<feed>")
        )

    def test_request_option_characterization_binds_source_lab_route_counts(self):
        scenario = "sl-source-request-header-cookie-retry-layering-001"
        raw = request_option_raw_artifact()
        artifact = runner.normalize_raw_artifact(
            raw,
            bindings(),
            scenario,
        )
        observation = artifact["result"]["value"][
            "android_characterization"
        ]["source_lab_observation"]
        self.assertEqual(
            [
                {
                    "route_id": "retry-two-with-header-cookie",
                    "request_count": raw["source_lab_route_counts"][
                        "retry-two-with-header-cookie"
                    ],
                },
                {
                    "route_id": "retry-default",
                    "request_count": raw["source_lab_route_counts"][
                        "retry-default"
                    ],
                },
            ],
            observation["route_request_counts"],
        )

        invalid = request_option_raw_artifact()
        del invalid["source_lab_route_counts"]["retry-default"]
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "SOURCE_LAB_OBSERVATION_INVALID",
        ):
            runner.normalize_raw_artifact(
                invalid,
                bindings(),
                scenario,
            )

    def test_rate_limit_characterization_preserves_shared_state_boundary(self):
        scenario = "sl-source-session-rate-limit-shared-state-001"
        artifact = runner.normalize_raw_artifact(
            rate_limit_raw_artifact(),
            bindings(),
            scenario,
        )
        cases = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]

        self.assertEqual(3, cases[2]["result"]["allowed_before_denial"])
        self.assertTrue(cases[1]["result"]["second_same_key_denied"])
        self.assertTrue(cases[3]["result"]["records_are_distinct"])
        self.assertFalse(cases[4]["result"]["is_count_window"])
        self.assertTrue(cases[5]["result"]["is_count_window"])

    def test_transport_dispatch_accepts_mixed_requests_and_binds_network_routes(self):
        scenario = "sl-source-transport-request-dispatch-contract-001"
        raw = transport_dispatch_raw_artifact()
        artifact = runner.normalize_raw_artifact(
            raw,
            bindings(),
            scenario,
        )
        self.assertEqual(
            ["GET", "POST", "POST"],
            [
                request["method"]
                for request in artifact["request_plan"][:3]
            ],
        )
        self.assertTrue(
            artifact["request_plan"][6]["url"].startswith("data:")
        )
        self.assertEqual(750, artifact["request_plan"][8]["timeout_ms"])
        observation = artifact["result"]["value"][
            "android_characterization"
        ]["source_lab_observation"]
        self.assertEqual(
            list(runner.ROUTE_OBSERVATION_SCENARIOS[scenario]),
            [
                entry["route_id"]
                for entry in observation["route_request_counts"]
            ],
        )

        invalid = transport_dispatch_raw_artifact()
        invalid["request_plan"][0]["headers"] = [{"name": "broken"}]
        invalid["cases"][0]["request"] = invalid["request_plan"][0]
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "RAW_TRANSPORT_REQUEST_INVALID",
        ):
            runner.normalize_raw_artifact(
                invalid,
                bindings(),
                scenario,
            )

    def test_response_decoding_preserves_final_url_and_denied_redirect(self):
        scenario = "sl-source-transport-response-decoding-runtime-001"
        artifact = runner.normalize_raw_artifact(
            response_decoding_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        redirect = next(
            case for case in projected
            if case["id"] == "redirect-final-url"
        )
        self.assertEqual(
            runner.LOGICAL_ORIGIN + "/decode/redirect-final",
            redirect["result"]["final_url"],
        )
        denied = next(
            case for case in projected
            if case["id"] == "redirect-loop-denied"
        )
        self.assertEqual("rule_failed", denied["issue"]["code"])
        observation = artifact["result"]["value"][
            "android_characterization"
        ]["source_lab_observation"]
        self.assertEqual(
            list(runner.ROUTE_OBSERVATION_SCENARIOS[scenario]),
            [
                entry["route_id"]
                for entry in observation["route_request_counts"]
            ],
        )

    def test_retry_redirect_binds_all_cases_and_route_observations(self):
        scenario = "sl-source-transport-retry-redirect-runtime-001"
        artifact = runner.normalize_raw_artifact(
            retry_redirect_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [case["id"] for case in projected],
        )
        observation = artifact["result"]["value"][
            "android_characterization"
        ]["source_lab_observation"]
        self.assertEqual(
            list(runner.ROUTE_OBSERVATION_SCENARIOS[scenario]),
            [
                entry["route_id"]
                for entry in observation["route_request_counts"]
            ],
        )

    def test_cookie_session_binds_all_cases_and_route_observations(self):
        scenario = "sl-source-cookie-persistent-session-merge-runtime-001"
        artifact = runner.normalize_raw_artifact(
            cookie_session_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [case["id"] for case in projected],
        )
        observation = artifact["result"]["value"][
            "android_characterization"
        ]["source_lab_observation"]
        self.assertEqual(
            list(runner.ROUTE_OBSERVATION_SCENARIOS[scenario]),
            [
                entry["route_id"]
                for entry in observation["route_request_counts"]
            ],
        )

    def test_dynamic_web_accepts_post_and_binds_all_route_observations(self):
        scenario = "sl-source-transport-dynamic-web-runtime-001"
        artifact = runner.normalize_raw_artifact(
            dynamic_web_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [case["id"] for case in projected],
        )
        self.assertEqual("POST", artifact["request_plan"][4]["method"])
        observation = artifact["result"]["value"][
            "android_characterization"
        ]["source_lab_observation"]
        self.assertEqual(
            list(runner.ROUTE_OBSERVATION_SCENARIOS[scenario]),
            [
                entry["route_id"]
                for entry in observation["route_request_counts"]
            ],
        )

    def test_rule_variable_scope_binds_all_cases_without_network_observation(
        self,
    ):
        scenario = "sl-source-session-rule-variable-scope-001"
        artifact = runner.normalize_raw_artifact(
            rule_variable_scope_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [case["id"] for case in projected],
        )
        self.assertNotIn(
            "source_lab_observation",
            artifact["result"]["value"]["android_characterization"],
        )

    def test_rule_backend_dispatch_binds_all_cases_without_network_observation(
        self,
    ):
        scenario = "sl-source-rule-backend-dispatch-runtime-001"
        artifact = runner.normalize_raw_artifact(
            rule_backend_dispatch_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [case["id"] for case in projected],
        )
        self.assertNotIn(
            "source_lab_observation",
            artifact["result"]["value"]["android_characterization"],
        )

    def test_content_cache_queue_completion_binds_all_cases_without_network_observation(
        self,
    ):
        scenario = "sl-content-cache-queue-completion-runtime-001"
        artifact = runner.normalize_raw_artifact(
            content_cache_queue_completion_raw_artifact(),
            bindings(),
            scenario,
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [case["id"] for case in projected],
        )
        self.assertNotIn(
            "source_lab_observation",
            artifact["result"]["value"]["android_characterization"],
        )

    def test_nominal_issue_external_request_and_device_origin_leak_fail_closed(self):
        issue = raw_artifact()
        issue["cases"][0]["issue"] = {
            "code": "android_exception",
            "exception_type": "java.lang.IllegalStateException",
        }
        issue["cases"][0]["result"] = None
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "ANDROID_CHARACTERIZATION_FAILED",
        ):
            runner.normalize_raw_artifact(issue, bindings())

        external = raw_artifact()
        external["request_plan"][0]["url"] = "https://example.com/"
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "RAW_REQUEST_INVALID",
        ):
            runner.normalize_raw_artifact(external, bindings())

        leak = raw_artifact()
        leak["cases"][0]["result"] = {
            "url": "http://127.0.0.1:49152/private"
        }
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "DEVICE_ORIGIN_LEAK",
        ):
            runner.normalize_raw_artifact(leak, bindings())

    def test_boundary_exception_is_preserved_as_android_truth(self):
        raw = raw_artifact()
        boundary = next(
            entry
            for entry in raw["cases"]
            if entry["id"] == "toc-empty"
        )
        boundary["result"] = None
        boundary["issue"] = {
            "code": "android_exception",
            "exception_type": "io.legado.EmptyTocException",
        }
        artifact = runner.normalize_raw_artifact(raw, bindings())
        self.assertEqual(
            [
                {
                    "case_id": "toc-empty",
                    "code": "rule_failed",
                    "stage": "field_evaluation",
                }
            ],
            artifact["issues"],
        )
        projected = artifact["result"]["value"][
            "portable_known_projection"
        ]["cases"]
        toc_empty = next(
            entry for entry in projected if entry["id"] == "toc-empty"
        )
        self.assertIsNone(toc_empty["result"])
        self.assertEqual(
            "rule_failed",
            toc_empty["issue"]["code"],
        )
        self.assertNotIn(
            "exception_type",
            toc_empty["issue"],
        )
        self.assertEqual(
            [
                {
                    "case_id": "toc-empty",
                    "exception_type": "io.legado.EmptyTocException",
                }
            ],
            artifact["result"]["value"][
                "android_characterization"
            ]["exceptions"],
        )

    def test_local_document_is_candidate_only_and_private(self):
        artifact = runner.normalize_raw_artifact(
            raw_artifact(),
            bindings(),
        )
        document = runner.local_run_document(
            artifact,
            bindings(),
            emulator_serial="emulator-5554",
        )
        self.assertEqual("local_unverified", document["authority"])
        self.assertEqual("candidate_only", document["status"])
        self.assertNotIn(
            "emulator-5554",
            json.dumps(document, ensure_ascii=False),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime/result.json"
            runner._atomic_private_write(
                path,
                runner._canonical(document),
            )
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
            self.assertEqual(
                0o700,
                stat.S_IMODE(path.parent.stat().st_mode),
            )

    def test_output_must_stay_in_ignored_runtime(self):
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "OUTPUT_OUTSIDE_RUNTIME",
        ):
            runner._output_path(
                ROOT,
                ROOT / "ios/harness/goldens/forbidden.json",
            )
        output = runner._output_path(
            ROOT,
            Path(".harness-runtime/android-oracle/result.json"),
        )
        self.assertEqual(
            ROOT / ".harness-runtime/android-oracle/result.json",
            output,
        )


if __name__ == "__main__":
    unittest.main()
