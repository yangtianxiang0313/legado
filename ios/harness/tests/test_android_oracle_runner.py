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


def bookmark_runtime_raw_artifact():
    scenario = "rl-reader-bookmark-search-runtime-risk-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "row_count": 1,
                    "rows": [{"time": index + 1}],
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def book_group_runtime_raw_artifact():
    scenario = "rl-library-shelf-group-bit-boundary-risk-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "stored_group_count": 63 + index,
                    "boundary_observed": index > 0,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def chapter_source_override_raw_artifact():
    scenario = "rl-reader-chapter-source-override-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "cache_identity": "current-book/current-chapter",
                    "alternative_source_persisted": False,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def reader_layout_incremental_stream_raw_artifact():
    scenario = "rl-reader-layout-incremental-stream-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "event_order_projected": True,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def reader_layout_page_projection_raw_artifact():
    scenario = "rl-reader-layout-page-projection-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "character_anchor_preserved": True,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def read_record_runtime_raw_artifact():
    scenario = "rl-reader-history-read-record-runtime-risk-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "relationship_verified": True,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def read_duration_session_raw_artifact():
    scenario = "rl-reader-progress-read-duration-session-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "session_relationships_projected": True,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def progress_save_runtime_raw_artifact():
    scenario = "rl-reader-progress-save-runtime-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "late_write_relationships_projected": True,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def reader_prefetch_runtime_raw_artifact():
    scenario = "rl-reader-cache-prefetch-policy-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "case_index": index,
                    "policy_observed": True,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def reader_toc_remap_runtime_raw_artifact():
    scenario = "rl-reader-progress-toc-remap-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "selected_index": index,
                    "selected_index_in_bounds": True,
                    "selected_title": f"chapter-{index}",
                    "new_chapter_count": 11,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
        "request_plan": requests,
        "cases": cases,
    }


def app_startup_runtime_raw_artifact():
    scenario = "rl-app-startup-first-use-and-restore-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for case_id, operation in contract["expected_cases"]:
        request = {
            "operation": operation,
            "arguments": {"fixture_case": case_id},
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": {
                    "build_debug": True,
                    "dialog_sequence": [],
                    "activity_finishing": False,
                },
                "issue": None,
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-runtime://local",
        "logical_origin": "android-runtime://local",
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


def jsonpath_regex_raw_artifact():
    scenario = "sl-source-rule-jsonpath-regex-backends-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        request = {
            "method": "GET",
            "url": f"{runner.LOGICAL_ORIGIN}/jsonpath-regex/{case_id}",
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
                    "backend_value": case_id,
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


def webdav_integration_raw_artifact():
    scenario = "il-integration-backup-webdav-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    requests = []
    cases = []
    for index, (case_id, operation) in enumerate(
        contract["expected_cases"]
    ):
        arguments = {"target": f"/dav/test-{index}"}
        if operation == "webdav_upload":
            arguments.update(
                {
                    "media_type": "application/octet-stream",
                    "payload_utf8": "payload",
                }
            )
        request = {
            "operation": operation,
            "arguments": arguments,
        }
        requests.append(request)
        cases.append(
            {
                "id": case_id,
                "operation": operation,
                "request": request,
                "result": (
                    None
                    if case_id == "object-not-found-exception"
                    else {"case_index": index}
                ),
                "issue": (
                    {
                        "code": "android_exception",
                        "exception_type": (
                            "io.legado.app.lib.webdav."
                            "ObjectNotFoundException"
                        ),
                    }
                    if case_id == "object-not-found-exception"
                    else None
                ),
            }
        )
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:49152",
        "logical_origin": runner.INTEGRATION_LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "source_lab_route_counts": {
            route_id: index + 1
            for index, route_id in enumerate(
                runner.ROUTE_OBSERVATION_SCENARIOS[scenario]
            )
        },
        "integration_lab_observations": [
            {
                "route_id": route_id,
                "method": "PROPFIND",
                "logical_target": (
                    f"{runner.INTEGRATION_LOGICAL_ORIGIN}/observed/{index}"
                ),
                "depth": "0",
                "authorization_scheme": "Basic",
                "content_type": "application/xml",
                "body_sha256": f"{index:064x}",
                "body_bytes": index,
            }
            for index, route_id in enumerate(
                runner.ROUTE_OBSERVATION_SCENARIOS[scenario]
            )
        ],
    }


def remote_management_integration_raw_artifact():
    scenario = (
        "il-integration-remote-http-websocket-management-001"
    )
    contract = runner.SCENARIO_CONTRACTS[scenario]
    fixture = json.loads(
        (
            ROOT
            / "ios/harness/fixtures/integration-lab"
            / scenario
            / "input.json"
        ).read_text(encoding="utf-8")
    )
    requests = [
        {
            "operation": value["operation"],
            "arguments": value["arguments"],
        }
        for value in fixture["cases"]
    ]
    cases = [
        {
            "id": case_id,
            "operation": operation,
            "request": requests[index],
            "result": {"case_index": index},
            "issue": None,
        }
        for index, (case_id, operation) in enumerate(
            contract["expected_cases"]
        )
    ]
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "http://127.0.0.1:0",
        "logical_origin": runner.INTEGRATION_LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "integration_lab_observations": [],
    }


def system_tts_integration_raw_artifact():
    scenario = "il-integration-system-text-to-speech-001"
    contract = runner.SCENARIO_CONTRACTS[scenario]
    fixture = json.loads(
        (
            ROOT
            / "ios/harness/fixtures/integration-lab"
            / scenario
            / "input.json"
        ).read_text(encoding="utf-8")
    )
    requests = [
        {
            "operation": value["operation"],
            "arguments": value["arguments"],
        }
        for value in fixture["cases"]
    ]
    cases = [
        {
            "id": case_id,
            "operation": operation,
            "request": requests[index],
            "result": {"case_index": index},
            "issue": None,
        }
        for index, (case_id, operation) in enumerate(
            contract["expected_cases"]
        )
    ]
    return {
        "schema_version": 1,
        "scenario_id": scenario,
        "device_origin": "android-platform://text-to-speech",
        "logical_origin": runner.INTEGRATION_LOGICAL_ORIGIN,
        "request_plan": requests,
        "cases": cases,
        "integration_lab_observations": [],
    }


class AndroidOracleRunnerTests(unittest.TestCase):
    def test_git_helper_accepts_longer_cleanup_timeout(self):
        with mock.patch.object(
            runner,
            "_run",
            return_value=mock.Mock(stdout=b""),
        ) as run:
            runner._git(
                ROOT,
                "worktree",
                "remove",
                "--force",
                "/tmp/example",
                check=False,
                timeout=300,
            )

        run.assert_called_once_with(
            [
                "git",
                "worktree",
                "remove",
                "--force",
                "/tmp/example",
            ],
            cwd=ROOT,
            timeout=300,
            check=False,
        )

    def test_android_listener_instrumentation_receives_device_origin_without_source(
        self,
    ):
        arguments = runner._instrumentation_arguments(
            adb=Path("/sdk/adb"),
            serial="emulator-5554",
            source_base64=None,
            integration_scenario=True,
            device_origin="http://127.0.0.1:0",
            logical_origin=runner.INTEGRATION_LOGICAL_ORIGIN,
            scenario_id=(
                "il-integration-remote-http-websocket-management-001"
            ),
            input_base64="e30=",
        )
        self.assertNotIn("sourceBase64", arguments)
        origin_index = arguments.index("deviceOrigin")
        self.assertEqual(
            "http://127.0.0.1:0",
            arguments[origin_index + 1],
        )

    def test_android_platform_instrumentation_receives_service_origin_without_source(
        self,
    ):
        arguments = runner._instrumentation_arguments(
            adb=Path("/sdk/adb"),
            serial="emulator-5554",
            source_base64=None,
            integration_scenario=True,
            device_origin="android-platform://text-to-speech",
            logical_origin=runner.INTEGRATION_LOGICAL_ORIGIN,
            scenario_id="il-integration-system-text-to-speech-001",
            input_base64="e30=",
        )
        self.assertNotIn("sourceBase64", arguments)
        origin_index = arguments.index("deviceOrigin")
        self.assertEqual(
            "android-platform://text-to-speech",
            arguments[origin_index + 1],
        )

    def test_ci_emulator_boot_probes_have_wall_clock_and_command_timeouts(self) -> None:
        workflow = (
            ROOT / ".github/workflows/android-oracle-attestation.yml"
        ).read_text(encoding="utf-8")

        self.assertIn("wait_for_emulator()", workflow)
        self.assertIn("while (( SECONDS - started_at < deadline_seconds ))", workflow)
        self.assertIn('timeout 5s "${ADB}" -s "${AVD_SERIAL}" get-state', workflow)
        self.assertIn("if wait_for_emulator 360; then", workflow)
        self.assertNotIn('printf \'EMULATOR_ACCEL=off', workflow)

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
        rule_combination = runner.doctor(
            ROOT,
            "sl-source-rule-combination-and-coercion-runtime-001",
        )
        self.assertEqual(
            "sl-source-rule-combination-and-coercion-runtime-001",
            rule_combination["scenario_id"],
        )
        dom_selector_backends = runner.doctor(
            ROOT,
            "sl-source-rule-dom-selector-backends-001",
        )
        self.assertEqual(
            "sl-source-rule-dom-selector-backends-001",
            dom_selector_backends["scenario_id"],
        )
        jsonpath_regex_backends = runner.doctor(
            ROOT,
            "sl-source-rule-jsonpath-regex-backends-001",
        )
        self.assertEqual(
            "sl-source-rule-jsonpath-regex-backends-001",
            jsonpath_regex_backends["scenario_id"],
        )
        content_cache_queue_completion = runner.doctor(
            ROOT,
            "sl-content-cache-queue-completion-runtime-001",
        )
        self.assertEqual(
            "sl-content-cache-queue-completion-runtime-001",
            content_cache_queue_completion["scenario_id"],
        )
        bookmark_runtime = runner.doctor(
            ROOT,
            "rl-reader-bookmark-search-runtime-risk-001",
        )
        self.assertEqual(
            "rl-reader-bookmark-search-runtime-risk-001",
            bookmark_runtime["scenario_id"],
        )
        book_group_runtime = runner.doctor(
            ROOT,
            "rl-library-shelf-group-bit-boundary-risk-001",
        )
        self.assertEqual(
            "rl-library-shelf-group-bit-boundary-risk-001",
            book_group_runtime["scenario_id"],
        )
        local_book_relocation = runner.doctor(
            ROOT,
            "rl-library-local-book-relocation-runtime-001",
        )
        self.assertEqual(
            "rl-library-local-book-relocation-runtime-001",
            local_book_relocation["scenario_id"],
        )
        book_import_channel = runner.doctor(
            ROOT,
            "rl-library-book-import-channel-runtime-001",
        )
        self.assertEqual(
            "rl-library-book-import-channel-runtime-001",
            book_import_channel["scenario_id"],
        )
        chapter_source_override = runner.doctor(
            ROOT,
            "rl-reader-chapter-source-override-runtime-001",
        )
        self.assertEqual(
            "rl-reader-chapter-source-override-runtime-001",
            chapter_source_override["scenario_id"],
        )
        read_duration_session = runner.doctor(
            ROOT,
            "rl-reader-progress-read-duration-session-001",
        )
        self.assertEqual(
            "rl-reader-progress-read-duration-session-001",
            read_duration_session["scenario_id"],
        )
        progress_save_runtime = runner.doctor(
            ROOT,
            "rl-reader-progress-save-runtime-001",
        )
        self.assertEqual(
            "rl-reader-progress-save-runtime-001",
            progress_save_runtime["scenario_id"],
        )
        book_detail_actions = runner.doctor(
            ROOT,
            "rl-ui-book-detail-conditional-actions-001",
        )
        self.assertEqual(
            "rl-ui-book-detail-conditional-actions-001",
            book_detail_actions["scenario_id"],
        )
        reader_layout_stream = runner.doctor(
            ROOT,
            "rl-reader-layout-incremental-stream-001",
        )
        self.assertEqual(
            "rl-reader-layout-incremental-stream-001",
            reader_layout_stream["scenario_id"],
        )
        reader_layout_projection = runner.doctor(
            ROOT,
            "rl-reader-layout-page-projection-001",
        )
        self.assertEqual(
            "rl-reader-layout-page-projection-001",
            reader_layout_projection["scenario_id"],
        )
        reader_prefetch_runtime = runner.doctor(
            ROOT,
            "rl-reader-cache-prefetch-policy-001",
        )
        self.assertEqual(
            "rl-reader-cache-prefetch-policy-001",
            reader_prefetch_runtime["scenario_id"],
        )
        reader_toc_remap_runtime = runner.doctor(
            ROOT,
            "rl-reader-progress-toc-remap-001",
        )
        self.assertEqual(
            "rl-reader-progress-toc-remap-001",
            reader_toc_remap_runtime["scenario_id"],
        )
        webdav = runner.doctor(
            ROOT,
            "il-integration-backup-webdav-001",
        )
        self.assertEqual(
            "il-integration-backup-webdav-001",
            webdav["scenario_id"],
        )
        remote_management = runner.doctor(
            ROOT,
            "il-integration-remote-http-websocket-management-001",
        )
        self.assertEqual(
            "il-integration-remote-http-websocket-management-001",
            remote_management["scenario_id"],
        )
        with mock.patch.object(
            runner,
            "fixture_digest",
            return_value="0" * 64,
        ):
            observed = runner.repository_bindings(
                ROOT,
                "sl-source-session-rate-limit-shared-state-001",
            )
        self.assertEqual("0" * 64, observed["fixture_sha256"])

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

    def test_runtime_fixture_uses_non_network_stimuli_and_reader_stages(self):
        scenario = "rl-reader-bookmark-search-runtime-risk-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            bookmark_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(7 * 4, len(artifact["stages"]))
        self.assertEqual(
            "android_runtime_scenario",
            artifact["result"]["value"]["fixture_integrity"][
                "fixture_kind"
            ],
        )
        self.assertNotIn(
            "source_template_sha256",
            artifact["result"]["value"]["fixture_integrity"],
        )
        self.assertTrue(
            all(
                set(value) == {"operation", "arguments"}
                for value in artifact["request_plan"]
            )
        )

    def test_library_group_boundary_fixture_uses_room_runtime_projection(self):
        scenario = "rl-library-shelf-group-bit-boundary-risk-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            book_group_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("library_runtime", artifact["result"]["type"])
        self.assertEqual(3 * 6, len(artifact["stages"]))
        self.assertEqual(
            3,
            artifact["result"]["value"]["android_characterization"][
                "case_count"
            ],
        )
        self.assertTrue(
            all(
                value["issue"] is None
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            )
        )

    def test_chapter_source_override_fixture_tracks_cache_identity(self):
        scenario = "rl-reader-chapter-source-override-runtime-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            chapter_source_override_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(4 * 6, len(artifact["stages"]))
        self.assertEqual(
            4,
            artifact["result"]["value"]["android_characterization"][
                "case_count"
            ],
        )
        self.assertTrue(
            all(
                value["result"]["alternative_source_persisted"] is False
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            )
        )

    def test_reader_layout_incremental_stream_binds_terminal_failures(self):
        scenario = "rl-reader-layout-incremental-stream-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            reader_layout_incremental_stream_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(7 * 6, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertEqual(
            {
                "current_layout_stream",
                "adjacent_layout_stream",
            },
            {
                value["operation"]
                for value in artifact["request_plan"]
            },
        )

    def test_reader_layout_page_projection_binds_all_layout_boundaries(self):
        scenario = "rl-reader-layout-page-projection-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            reader_layout_page_projection_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(5 * 5, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertEqual(
            {
                "layout_projection",
                "layout_reflow_projection",
            },
            {
                value["operation"]
                for value in artifact["request_plan"]
            },
        )

    def test_integration_fixture_uses_protocol_stimuli_and_redacted_observation(
        self,
    ):
        scenario = "il-integration-backup-webdav-001"
        integration_bindings = {
            **bindings(),
            "fixture_kind": "integration_lab_scenario",
            "fixture_path": (
                "ios/harness/fixtures/integration-lab/"
                f"{scenario}"
            ),
        }
        integration_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            webdav_integration_raw_artifact(),
            integration_bindings,
            scenario,
        )
        self.assertEqual("integration_runtime", artifact["result"]["type"])
        self.assertEqual(11 * 5 + 4, len(artifact["stages"]))
        fixture = artifact["result"]["value"]["fixture_integrity"]
        self.assertEqual("integration_lab_scenario", fixture["fixture_kind"])
        self.assertNotIn("source_template_sha256", fixture)
        characterization = artifact["result"]["value"][
            "android_characterization"
        ]
        self.assertIn("integration_lab_observation", characterization)
        self.assertNotIn("source_lab_observation", characterization)
        self.assertEqual(
            13,
            len(
                characterization["integration_lab_observation"][
                    "requests"
                ]
            ),
        )
        self.assertEqual(
            "response_parse",
            next(
                stage["stage"]
                for stage in artifact["stages"]
                if stage["outcome"] == "failed"
            ),
        )
        rendered = json.dumps(artifact, ensure_ascii=False)
        self.assertNotIn("127.0.0.1", rendered)
        self.assertNotIn("oracle-password", rendered)

    def test_android_listener_integration_uses_structured_stimuli_without_host_routes(
        self,
    ):
        scenario = (
            "il-integration-remote-http-websocket-management-001"
        )
        integration_bindings = {
            **bindings(),
            "fixture_kind": "integration_lab_scenario",
            "fixture_path": (
                "ios/harness/fixtures/integration-lab/"
                f"{scenario}"
            ),
        }
        integration_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            remote_management_integration_raw_artifact(),
            integration_bindings,
            scenario,
        )
        self.assertEqual("integration_runtime", artifact["result"]["type"])
        self.assertEqual(50, len(artifact["stages"]))
        characterization = artifact["result"]["value"][
            "android_characterization"
        ]
        self.assertNotIn("integration_lab_observation", characterization)
        self.assertEqual(10, characterization["case_count"])
        self.assertTrue(
            all(
                set(value) == {"operation", "arguments"}
                for value in artifact["request_plan"]
            )
        )
        rendered = json.dumps(artifact, ensure_ascii=False)
        self.assertNotIn("127.0.0.1", rendered)

    def test_android_platform_integration_uses_bound_service_origin(
        self,
    ):
        scenario = "il-integration-system-text-to-speech-001"
        integration_bindings = {
            **bindings(),
            "fixture_kind": "integration_lab_scenario",
            "fixture_path": (
                "ios/harness/fixtures/integration-lab/"
                f"{scenario}"
            ),
        }
        integration_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            system_tts_integration_raw_artifact(),
            integration_bindings,
            scenario,
        )
        self.assertEqual("integration_runtime", artifact["result"]["type"])
        self.assertEqual(48, len(artifact["stages"]))
        characterization = artifact["result"]["value"][
            "android_characterization"
        ]
        self.assertNotIn("integration_lab_observation", characterization)
        self.assertEqual(8, characterization["case_count"])
        self.assertTrue(
            all(
                set(value) == {"operation", "arguments"}
                for value in artifact["request_plan"]
            )
        )
        rendered = json.dumps(artifact, ensure_ascii=False)
        self.assertNotIn("127.0.0.1", rendered)
        invalid = system_tts_integration_raw_artifact()
        invalid["device_origin"] = "http://127.0.0.1:0"
        with self.assertRaisesRegex(
            runner.AndroidOracleRunnerError,
            "RAW_DEVICE_ORIGIN_INVALID",
        ):
            runner.normalize_raw_artifact(
                invalid,
                integration_bindings,
                scenario,
            )

    def test_read_record_runtime_fixture_uses_relational_reader_projection(self):
        scenario = "rl-reader-history-read-record-runtime-risk-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            read_record_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(6 * 5, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertTrue(
            all(
                set(value) == {"operation", "arguments"}
                for value in artifact["request_plan"]
            )
        )

    def test_read_duration_session_binds_executor_and_config_boundaries(self):
        scenario = "rl-reader-progress-read-duration-session-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            read_duration_session_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(7 * 5, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertEqual(
            {
                "read_duration_single",
                "read_duration_repeated",
                "read_duration_disabled_gap",
                "read_duration_config_race",
                "read_duration_reset_race",
                "read_duration_durability_window",
            },
            {
                value["operation"]
                for value in artifact["request_plan"]
            },
        )

    def test_progress_save_runtime_binds_late_write_boundaries(self):
        scenario = "rl-reader-progress-save-runtime-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            progress_save_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(6 * 5, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertEqual(
            {
                "save_runtime_execution_state",
                "save_runtime_book_switch",
                "save_runtime_session_clear",
                "save_runtime_multi_queue",
                "save_runtime_missing_chapter",
                "save_runtime_durability_window",
            },
            {
                value["operation"]
                for value in artifact["request_plan"]
            },
        )

    def test_reader_prefetch_runtime_binds_policy_and_cancellation_cases(self):
        scenario = "rl-reader-cache-prefetch-policy-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            reader_prefetch_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(8 * 5, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertTrue(
            all(
                value["operation"] == "reader_prefetch_policy"
                for value in artifact["request_plan"]
            )
        )

    def test_reader_toc_remap_runtime_binds_all_search_boundaries(self):
        scenario = "rl-reader-progress-toc-remap-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            reader_toc_remap_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("reader_runtime", artifact["result"]["type"])
        self.assertEqual(11 * 5, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
        )
        self.assertTrue(
            all(
                value["operation"] == "reader_progress_toc_remap"
                for value in artifact["request_plan"]
            )
        )

    def test_app_startup_runtime_binds_activity_and_onboarding_boundaries(self):
        scenario = "rl-app-startup-first-use-and-restore-001"
        runtime_bindings = {
            **bindings(),
            "fixture_kind": "android_runtime_scenario",
            "fixture_path": (
                "ios/harness/fixtures/runtime-lab/"
                f"{scenario}"
            ),
        }
        runtime_bindings.pop("source_template_sha256")
        artifact = runner.normalize_raw_artifact(
            app_startup_runtime_raw_artifact(),
            runtime_bindings,
            scenario,
        )
        self.assertEqual("app_runtime", artifact["result"]["type"])
        self.assertEqual(6 * 6, len(artifact["stages"]))
        self.assertEqual(
            [
                case_id
                for case_id, _ in
                runner.SCENARIO_CONTRACTS[scenario]["expected_cases"]
            ],
            [
                value["id"]
                for value in artifact["result"]["value"][
                    "portable_known_projection"
                ]["cases"]
            ],
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

    def test_jsonpath_regex_binds_all_cases_without_network_observation(
        self,
    ):
        scenario = "sl-source-rule-jsonpath-regex-backends-001"
        artifact = runner.normalize_raw_artifact(
            jsonpath_regex_raw_artifact(),
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

    def test_characterization_document_is_direct_and_runtime_can_be_private(self):
        artifact = runner.normalize_raw_artifact(
            raw_artifact(),
            bindings(),
        )
        document = runner.characterization_document(
            artifact,
            bindings(),
            emulator_serial="emulator-5554",
        )
        self.assertEqual(
            "android_runtime_characterization",
            document["kind"],
        )
        self.assertEqual(runner.SCENARIO_ID, document["fixture_id"])
        self.assertEqual(
            bindings()["android_git_commit"],
            document["oracle"]["android_git_commit"],
        )
        self.assertNotIn(
            "emulator-5554",
            json.dumps(document, ensure_ascii=False),
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime/result.json"
            runner._atomic_write(
                path,
                runner._canonical(document),
                private=True,
            )
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
            self.assertEqual(
                0o700,
                stat.S_IMODE(path.parent.stat().st_mode),
            )

    def test_output_allows_only_runtime_or_exact_scenario_golden(self):
        scenario_golden = (
            ROOT
            / "ios/harness/goldens/android-legado-v1"
            / f"{runner.SCENARIO_ID}.json"
        )
        self.assertEqual(
            scenario_golden,
            runner._output_path(
                ROOT,
                scenario_golden,
            ),
        )
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
