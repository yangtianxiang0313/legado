#!/usr/bin/env python3
"""Candidate-only Android characterization runner over deterministic fixtures."""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, Mapping, Optional, Sequence


RUNNER_VERSION = "android-characterization-instrumentation-v2"
COMMANDS = ("doctor", "run")
DEFAULT_SCENARIO_ID = "sl-html-basic-001"
SCENARIO_ID = DEFAULT_SCENARIO_ID
LOGICAL_ORIGIN = "http://sourcelab.test"
INTEGRATION_LOGICAL_ORIGIN = "http://integrationlab.test"
BASELINE_PATH = "ios/project/baseline.json"
INVENTORY_PATH = "ios/project/android-intake/inventory-manifest.json"
FIXTURE_MANIFEST_PATH = "ios/harness/fixtures/manifest.json"
SOURCE_LAB_MANIFEST_PATH = "ios/harness/source-lab/manifest.json"
CANONICALIZER_PATH = "ios/harness/normalization/canonical-v1.json"
KOTLIN_RUNNER = "LegadoOracleInstrumentedTest.kt"
OVERLAY_RELATIVE = (
    "app/src/androidTest/java/io/legado/app/oracle/"
    "LegadoOracleInstrumentedTest.kt"
)
RAW_DEVICE_PATH = "files/legado-oracle-raw.json"
TARGET_PACKAGE = "io.legado.app.debug"
TEST_PACKAGE = "io.legado.app.debug.test"
INSTRUMENTATION = (
    "io.legado.app.debug.test/androidx.test.runner.AndroidJUnitRunner"
)
TEST_CLASS = (
    "io.legado.app.oracle.LegadoOracleInstrumentedTest"
    "#runCharacterization"
)
EXPECTED_CASES = (
    ("search-hit", "search"),
    ("search-empty", "search"),
    ("book-detail", "book_info"),
    ("book-detail-missing-cover", "book_info"),
    ("toc", "chapters"),
    ("toc-empty", "chapters"),
    ("chapter", "content"),
    ("chapter-second", "content"),
)
NOMINAL_CASES = {
    "search-hit",
    "book-detail",
    "toc",
    "chapter",
    "chapter-second",
}
SCENARIO_CONTRACTS = {
    "sl-html-basic-001": {
        "status": "reference",
        "expected_cases": EXPECTED_CASES,
        "nominal_cases": frozenset(NOMINAL_CASES),
    },
    "sl-post-form-001": {
        "status": "candidate",
        "expected_cases": (
            ("post-form-nominal", "search"),
            ("post-form-boundary", "search"),
        ),
        "nominal_cases": frozenset({"post-form-nominal"}),
    },
    "sl-source-response-xml-declaration-normalization-001": {
        "status": "candidate",
        "expected_cases": (
            ("xml-missing-declaration", "raw_response"),
            ("xml-existing-declaration", "raw_response"),
            ("non-xml-content-type", "raw_response"),
        ),
        "nominal_cases": frozenset({"xml-missing-declaration"}),
    },
    "sl-source-request-header-cookie-retry-layering-001": {
        "status": "candidate",
        "expected_cases": (
            ("retry-two-with-header-cookie", "request_options"),
            ("retry-default", "request_options"),
        ),
        "nominal_cases": frozenset({"retry-two-with-header-cookie"}),
    },
    "sl-source-request-field-encoding-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("utf8-preserved-and-duplicate", "field_encoding"),
            ("declared-gbk", "field_encoding"),
            ("escape-mode", "field_encoding"),
            ("invalid-charset", "field_encoding"),
        ),
        "nominal_cases": frozenset({
            "utf8-preserved-and-duplicate",
            "declared-gbk",
        }),
    },
    "sl-source-request-url-template-compilation-001": {
        "status": "candidate",
        "expected_cases": (
            ("inline-js-key-page-option", "url_template_compilation"),
            ("script-block-order", "url_template_compilation"),
            ("relative-empty-last-page", "url_template_compilation"),
            ("nested-inline-js", "url_template_compilation"),
        ),
        "nominal_cases": frozenset({
            "inline-js-key-page-option",
            "script-block-order",
        }),
    },
    "sl-source-session-rate-limit-shared-state-001": {
        "status": "candidate",
        "expected_cases": (
            ("disabled-zero", "rate_limit_state"),
            ("interval-shared-key", "rate_limit_state"),
            ("window-count-boundary", "rate_limit_state"),
            ("distinct-source-keys", "rate_limit_state"),
            ("invalid-interval", "rate_limit_state"),
            ("invalid-window", "rate_limit_state"),
        ),
        "nominal_cases": frozenset({
            "disabled-zero",
            "interval-shared-key",
            "window-count-boundary",
            "distinct-source-keys",
            "invalid-interval",
            "invalid-window",
        }),
    },
    "sl-source-transport-request-dispatch-contract-001": {
        "status": "candidate",
        "expected_cases": (
            ("get-response-metadata", "transport_dispatch"),
            ("post-raw-content-type", "transport_dispatch"),
            ("post-json-default", "transport_dispatch"),
            ("typed-string-hex", "transport_dispatch"),
            ("byte-array-network", "transport_dispatch"),
            ("input-stream-network", "transport_dispatch"),
            ("data-uri-short-circuit", "transport_dispatch"),
            ("media-models", "transport_dispatch"),
            ("proxy-timeout-policy", "transport_dispatch"),
        ),
        "nominal_cases": frozenset({
            "get-response-metadata",
            "post-raw-content-type",
            "post-json-default",
            "typed-string-hex",
            "byte-array-network",
            "input-stream-network",
            "data-uri-short-circuit",
            "media-models",
            "proxy-timeout-policy",
        }),
    },
    "sl-source-transport-response-decoding-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("header-utf8", "response_decoding"),
            ("header-gbk", "response_decoding"),
            ("detected-gbk", "response_decoding"),
            ("utf8-bom", "response_decoding"),
            ("wrong-declared-charset", "response_decoding"),
            ("gzip-transparent", "response_decoding"),
            ("zip-first-entry", "response_decoding"),
            ("malformed-zip", "response_decoding"),
            ("redirect-final-url", "response_decoding"),
            ("redirect-loop-denied", "response_decoding"),
        ),
        "nominal_cases": frozenset({
            "header-utf8",
            "header-gbk",
            "detected-gbk",
            "utf8-bom",
            "gzip-transparent",
            "zip-first-entry",
            "redirect-final-url",
        }),
    },
    "sl-source-transport-retry-redirect-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("retry-default-single-failure", "retry_redirect"),
            ("retry-two-repeated-failure", "retry_redirect"),
            ("redirect-success-observation", "retry_redirect"),
            ("redirect-failure-chain-retried", "retry_redirect"),
            ("helper-eventual-success", "retry_redirect"),
            ("helper-network-exception-no-retry", "retry_redirect"),
            ("helper-cancellation-propagates", "retry_redirect"),
            ("negative-retry-empty-range", "retry_redirect"),
        ),
        "nominal_cases": frozenset({
            "retry-default-single-failure",
            "retry-two-repeated-failure",
            "redirect-success-observation",
            "redirect-failure-chain-retried",
            "helper-eventual-success",
            "helper-network-exception-no-retry",
            "helper-cancellation-propagates",
            "negative-retry-empty-range",
        }),
    },
    "sl-source-cookie-persistent-session-merge-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("cookie-parser-boundaries", "cookie_session"),
            ("persistent-session-merge-order", "cookie_session"),
            ("enabled-jar-network-reloads-store", "cookie_session"),
            (
                "disabled-jar-keeps-explicit-and-ignores-response",
                "cookie_session",
            ),
            (
                "response-classifies-persistent-and-session",
                "cookie_session",
            ),
            ("path-and-expiry-metadata-flattened", "cookie_session"),
            ("redirect-cookie-chain", "cookie_session"),
            ("remove-key-and-domain", "cookie_session"),
            ("registrable-domain-normalization", "cookie_session"),
        ),
        "nominal_cases": frozenset({
            "cookie-parser-boundaries",
            "persistent-session-merge-order",
            "enabled-jar-network-reloads-store",
            "disabled-jar-keeps-explicit-and-ignores-response",
            "response-classifies-persistent-and-session",
            "path-and-expiry-metadata-flattened",
            "redirect-cookie-chain",
            "remove-key-and-domain",
            "registrable-domain-normalization",
        }),
    },
    "sl-source-transport-dynamic-web-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("get-default-dom", "dynamic_web"),
            ("get-custom-js-value", "dynamic_web"),
            ("invocation-disables-webview", "dynamic_web"),
            ("option-disables-webview", "dynamic_web"),
            ("post-http-then-webview", "dynamic_web"),
            ("resource-regex-sniff", "dynamic_web"),
            ("webview-cookie-bridge", "dynamic_web"),
            ("configured-user-agent", "dynamic_web"),
        ),
        "nominal_cases": frozenset({
            "get-default-dom",
            "get-custom-js-value",
            "invocation-disables-webview",
            "option-disables-webview",
            "post-http-then-webview",
            "resource-regex-sniff",
            "webview-cookie-bridge",
            "configured-user-agent",
        }),
    },
    "sl-source-session-rule-variable-scope-001": {
        "status": "candidate",
        "expected_cases": (
            ("rule-data-storage-boundary", "rule_variable_scope"),
            (
                "analyze-rule-priority-and-specials",
                "rule_variable_scope",
            ),
            (
                "analyze-url-priority-and-specials",
                "rule_variable_scope",
            ),
            ("rule-script-shared-propagation", "rule_variable_scope"),
            ("url-script-shared-propagation", "rule_variable_scope"),
            ("failure-keeps-prior-write", "rule_variable_scope"),
            ("independent-context-isolation", "rule_variable_scope"),
        ),
        "nominal_cases": frozenset({
            "rule-data-storage-boundary",
            "analyze-rule-priority-and-specials",
            "analyze-url-priority-and-specials",
            "rule-script-shared-propagation",
            "url-script-shared-propagation",
            "failure-keeps-prior-write",
            "independent-context-isolation",
        }),
    },
    "sl-source-rule-backend-dispatch-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            ("html-prefix-dispatch", "rule_backend_dispatch"),
            ("json-content-dispatch", "rule_backend_dispatch"),
            ("javascript-dispatch", "rule_backend_dispatch"),
            ("regex-all-in-one-stickiness", "rule_backend_dispatch"),
            (
                "parser-cache-content-invalidation",
                "rule_backend_dispatch",
            ),
            ("native-object-direct-access", "rule_backend_dispatch"),
            ("null-content-rejected", "rule_backend_dispatch"),
            ("foreign-content-cache-isolation", "rule_backend_dispatch"),
        ),
        "nominal_cases": frozenset({
            "html-prefix-dispatch",
            "json-content-dispatch",
            "javascript-dispatch",
            "regex-all-in-one-stickiness",
            "parser-cache-content-invalidation",
            "native-object-direct-access",
            "null-content-rejected",
            "foreign-content-cache-isolation",
        }),
    },
    "sl-source-rule-combination-and-coercion-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            (
                "json-list-and-concatenation",
                "rule_combination_coercion",
            ),
            ("json-list-or-fallback", "rule_combination_coercion"),
            (
                "json-list-percent-interleave",
                "rule_combination_coercion",
            ),
            (
                "json-scalar-coercion-matrix",
                "rule_combination_coercion",
            ),
            (
                "json-element-consumer-shapes",
                "rule_combination_coercion",
            ),
            (
                "sequential-html-javascript-chain",
                "rule_combination_coercion",
            ),
            (
                "newline-url-resolution-deduplication",
                "rule_combination_coercion",
            ),
            (
                "empty-and-missing-propagation",
                "rule_combination_coercion",
            ),
            (
                "javascript-exception-interruption",
                "rule_combination_coercion",
            ),
        ),
        "nominal_cases": frozenset({
            "json-list-and-concatenation",
            "json-list-or-fallback",
            "json-list-percent-interleave",
            "json-scalar-coercion-matrix",
            "json-element-consumer-shapes",
            "sequential-html-javascript-chain",
            "newline-url-resolution-deduplication",
            "empty-and-missing-propagation",
            "javascript-exception-interruption",
        }),
    },
    "sl-source-rule-dom-selector-backends-001": {
        "status": "candidate",
        "expected_cases": (
            ("css-string-derivations", "dom_selector_backends"),
            ("css-index-children-filtering", "dom_selector_backends"),
            ("css-combination-operators", "dom_selector_backends"),
            (
                "css-url-resolution-deduplication",
                "dom_selector_backends",
            ),
            (
                "css-empty-and-malformed-selector",
                "dom_selector_backends",
            ),
            ("xpath-string-node-forms", "dom_selector_backends"),
            (
                "xpath-element-node-projections",
                "dom_selector_backends",
            ),
            (
                "xpath-tolerant-html-fragments",
                "dom_selector_backends",
            ),
            (
                "xpath-namespace-and-functions",
                "dom_selector_backends",
            ),
            (
                "xpath-empty-and-malformed-expression",
                "dom_selector_backends",
            ),
        ),
        "nominal_cases": frozenset({
            "css-string-derivations",
            "css-index-children-filtering",
            "css-combination-operators",
            "css-url-resolution-deduplication",
            "css-empty-and-malformed-selector",
            "xpath-string-node-forms",
            "xpath-element-node-projections",
            "xpath-tolerant-html-fragments",
            "xpath-namespace-and-functions",
            "xpath-empty-and-malformed-expression",
        }),
    },
    "sl-source-rule-jsonpath-regex-backends-001": {
        "status": "candidate",
        "expected_cases": (
            (
                "jsonpath-scalars-and-null",
                "jsonpath_regex_backends",
            ),
            (
                "jsonpath-filter-recursive-slice",
                "jsonpath_regex_backends",
            ),
            (
                "jsonpath-combination-and-interpolation",
                "jsonpath_regex_backends",
            ),
            (
                "jsonpath-object-input",
                "jsonpath_regex_backends",
            ),
            (
                "jsonpath-missing-null-malformed",
                "jsonpath_regex_backends",
            ),
            (
                "regex-single-capture-and-chain",
                "jsonpath_regex_backends",
            ),
            (
                "regex-list-optional-unicode-zero-width",
                "jsonpath_regex_backends",
            ),
            (
                "regex-replacement-all-first-groups",
                "jsonpath_regex_backends",
            ),
            (
                "regex-replacement-after-json-list",
                "jsonpath_regex_backends",
            ),
            (
                "regex-malformed-boundaries",
                "jsonpath_regex_backends",
            ),
        ),
        "nominal_cases": frozenset({
            "jsonpath-scalars-and-null",
            "jsonpath-filter-recursive-slice",
            "jsonpath-combination-and-interpolation",
            "jsonpath-object-input",
            "jsonpath-missing-null-malformed",
            "regex-single-capture-and-chain",
            "regex-list-optional-unicode-zero-width",
            "regex-replacement-all-first-groups",
            "regex-replacement-after-json-list",
            "regex-malformed-boundaries",
        }),
    },
    "sl-content-cache-queue-completion-runtime-001": {
        "status": "candidate",
        "expected_cases": (
            (
                "content-presence-short-circuits",
                "content_cache_queue_completion",
            ),
            (
                "text-cache-file-lifecycle",
                "content_cache_queue_completion",
            ),
            (
                "image-completion-boundary",
                "content_cache_queue_completion",
            ),
            (
                "queue-range-stop-resume",
                "content_cache_queue_completion",
            ),
            (
                "retry-budget-concurrent-stop",
                "content_cache_queue_completion",
            ),
            (
                "success-cancel-memory-state",
                "content_cache_queue_completion",
            ),
            (
                "registry-finally-cleanup",
                "content_cache_queue_completion",
            ),
        ),
        "nominal_cases": frozenset({
            "content-presence-short-circuits",
            "text-cache-file-lifecycle",
            "image-completion-boundary",
            "queue-range-stop-resume",
            "retry-budget-concurrent-stop",
            "success-cancel-memory-state",
            "registry-finally-cleanup",
        }),
    },
    "rl-reader-bookmark-search-runtime-risk-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "database_write",
            "room_query",
            "result_mapping",
        ),
        "expected_cases": (
            ("same-book-chapter-name", "bookmark_search"),
            ("content-branch-cross-book", "bookmark_search"),
            ("empty-key-cross-book", "bookmark_search"),
            ("percent-wildcard", "bookmark_search"),
            ("underscore-wildcard", "bookmark_search"),
            ("global-chapter-order", "bookmark_search"),
            ("time-primary-key-replace", "bookmark_insert_conflict"),
        ),
        "nominal_cases": frozenset({
            "same-book-chapter-name",
            "content-branch-cross-book",
            "empty-key-cross-book",
            "percent-wildcard",
            "underscore-wildcard",
            "global-chapter-order",
            "time-primary-key-replace",
        }),
    },
    "rl-library-shelf-group-bit-boundary-risk-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "library_runtime",
        "stage_names": (
            "fixture_setup",
            "database_write",
            "bit_allocation",
            "room_query",
            "membership_projection",
            "result_mapping",
        ),
        "expected_cases": (
            ("last-positive-bit-control", "book_group_allocation"),
            (
                "min-value-allocation-and-capacity",
                "book_group_allocation",
            ),
            (
                "min-value-selection-and-membership",
                "book_group_selection",
            ),
        ),
        "nominal_cases": frozenset({
            "last-positive-bit-control",
            "min-value-allocation-and-capacity",
            "min-value-selection-and-membership",
        }),
    },
    "rl-reader-chapter-source-override-runtime-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "alternative_source_fetch",
            "cache_write",
            "cache_read",
            "source_recovery",
            "result_mapping",
        ),
        "expected_cases": (
            ("alternative-fetch-is-cacheless", "chapter_source_fetch"),
            (
                "replacement-uses-current-cache-identity",
                "chapter_source_replace",
            ),
            (
                "replacement-overwrites-existing-current-cache",
                "chapter_source_overwrite",
            ),
            (
                "invalidation-recovers-current-source",
                "chapter_source_invalidate_recover",
            ),
        ),
        "nominal_cases": frozenset({
            "alternative-fetch-is-cacheless",
            "replacement-uses-current-cache-identity",
            "replacement-overwrites-existing-current-cache",
            "invalidation-recovers-current-source",
        }),
    },
    "rl-reader-history-read-record-runtime-risk-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "database_write",
            "read_session_action",
            "room_query",
            "result_mapping",
        ),
        "expected_cases": (
            ("all-device-aggregate-query", "read_record_query"),
            ("reset-loads-all-device-total", "read_record_reset"),
            (
                "empty-device-write-recounts-foreign",
                "read_record_session_write",
            ),
            (
                "pause-save-leaves-tail-unsettled",
                "read_record_pause_boundary",
            ),
            (
                "disabled-recording-preserves-session-start",
                "read_record_disabled",
            ),
            (
                "composite-key-replace-isolated-by-device",
                "read_record_insert_conflict",
            ),
        ),
        "nominal_cases": frozenset({
            "all-device-aggregate-query",
            "reset-loads-all-device-total",
            "empty-device-write-recounts-foreign",
            "pause-save-leaves-tail-unsettled",
            "disabled-recording-preserves-session-start",
            "composite-key-replace-isolated-by-device",
        }),
    },
    "rl-reader-progress-read-duration-session-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "session_configuration",
            "executor_queue",
            "database_observation",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "enabled-settlement-advances-session-clock",
                "read_duration_single",
            ),
            (
                "consecutive-settlements-accumulate-monotonically",
                "read_duration_repeated",
            ),
            (
                "disabled-gap-is-caught-up-after-reenable",
                "read_duration_disabled_gap",
            ),
            (
                "enabled-at-call-disabled-at-execution-is-skipped",
                "read_duration_config_race",
            ),
            (
                "disabled-at-call-enabled-at-execution-is-settled",
                "read_duration_config_race",
            ),
            (
                "queued-settlement-observes-reset-book",
                "read_duration_reset_race",
            ),
            (
                "queued-settlement-is-not-durable-before-execution",
                "read_duration_durability_window",
            ),
        ),
        "nominal_cases": frozenset({
            "enabled-settlement-advances-session-clock",
            "consecutive-settlements-accumulate-monotonically",
            "disabled-gap-is-caught-up-after-reenable",
            "enabled-at-call-disabled-at-execution-is-skipped",
            "disabled-at-call-enabled-at-execution-is-settled",
            "queued-settlement-observes-reset-book",
            "queued-settlement-is-not-durable-before-execution",
        }),
    },
    "rl-reader-layout-incremental-stream-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "layout_configuration",
            "content_processing",
            "page_stream",
            "callback_projection",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "current-page-mode-refreshes-when-anchor-becomes-available",
                "current_layout_stream",
            ),
            (
                "current-page-mode-falls-back-after-unavailable-anchor",
                "current_layout_stream",
            ),
            (
                "current-scroll-mode-refreshes-near-persisted-page",
                "current_layout_stream",
            ),
            (
                "previous-chapter-waits-for-full-layout",
                "adjacent_layout_stream",
            ),
            (
                "next-chapter-refreshes-only-first-two-pages",
                "adjacent_layout_stream",
            ),
            (
                "current-layout-cancelled-after-first-page",
                "current_layout_stream",
            ),
            (
                "current-consumer-callback-fails-after-first-page",
                "current_layout_stream",
            ),
        ),
        "nominal_cases": frozenset({
            "current-page-mode-refreshes-when-anchor-becomes-available",
            "current-scroll-mode-refreshes-near-persisted-page",
            "next-chapter-refreshes-only-first-two-pages",
        }),
    },
    "rl-reader-layout-page-projection-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "layout_materialization",
            "character_projection",
            "boundary_evaluation",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "empty-layout-has-no-character-projection",
                "layout_projection",
            ),
            (
                "completed-layout-projects-read-and-navigation-boundaries",
                "layout_projection",
            ),
            (
                "incomplete-layout-accepts-exact-last-page-end",
                "layout_projection",
            ),
            (
                "partial-layout-rejects-positions-before-first-page",
                "layout_projection",
            ),
            (
                "same-character-anchor-reprojects-after-layout-change",
                "layout_reflow_projection",
            ),
        ),
        "nominal_cases": frozenset({
            "completed-layout-projects-read-and-navigation-boundaries",
            "same-character-anchor-reprojects-after-layout-change",
        }),
    },
    "rl-reader-progress-layout-save-runtime-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "layout_conversion",
            "read_session_action",
            "database_write",
            "room_query",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "page-index-maps-to-layout-char-position",
                "layout_set_page_index",
            ),
            (
                "negative-page-index-resets-to-zero",
                "layout_set_page_index",
            ),
            (
                "oversized-page-index-clamps-to-last-layout-page",
                "layout_set_page_index",
            ),
            (
                "completed-layout-maps-char-boundaries",
                "layout_char_to_page",
            ),
            (
                "incomplete-layout-rejects-position-past-page-end",
                "layout_char_to_page",
            ),
            (
                "page-save-same-chapter-preserves-existing-title",
                "save_read_page_changed",
            ),
            (
                "page-save-after-chapter-switch-refreshes-title",
                "save_read_page_changed",
            ),
            (
                "pause-default-save-refreshes-title",
                "save_read_page_changed",
            ),
            (
                "reset-clamps-chapter-index-without-immediate-write",
                "reset_progress",
            ),
            (
                "audio-save-refreshes-title-and-persists-book-fields",
                "audio_save_read",
            ),
        ),
        "nominal_cases": frozenset({
            "page-index-maps-to-layout-char-position",
            "negative-page-index-resets-to-zero",
            "oversized-page-index-clamps-to-last-layout-page",
            "completed-layout-maps-char-boundaries",
            "incomplete-layout-rejects-position-past-page-end",
            "page-save-same-chapter-preserves-existing-title",
            "page-save-after-chapter-switch-refreshes-title",
            "pause-default-save-refreshes-title",
            "reset-clamps-chapter-index-without-immediate-write",
            "audio-save-refreshes-title-and-persists-book-fields",
        }),
    },
    "rl-reader-progress-save-runtime-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "session_configuration",
            "executor_queue",
            "database_observation",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "queued-save-uses-execution-progress",
                "save_runtime_execution_state",
            ),
            (
                "queued-save-retargets-current-book",
                "save_runtime_book_switch",
            ),
            (
                "queued-save-drops-after-session-cleared",
                "save_runtime_session_clear",
            ),
            (
                "multiple-queued-saves-observe-final-state",
                "save_runtime_multi_queue",
            ),
            (
                "missing-chapter-keeps-existing-title",
                "save_runtime_missing_chapter",
            ),
            (
                "queued-save-is-not-durable-before-execution",
                "save_runtime_durability_window",
            ),
        ),
        "nominal_cases": frozenset({
            "queued-save-uses-execution-progress",
            "queued-save-retargets-current-book",
            "queued-save-drops-after-session-cleared",
            "multiple-queued-saves-observe-final-state",
            "missing-chapter-keeps-existing-title",
            "queued-save-is-not-durable-before-execution",
        }),
    },
    "rl-ui-book-detail-conditional-actions-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "ui_runtime",
        "stage_names": (
            "fixture_setup",
            "activity_launch",
            "state_projection",
            "menu_observation",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "remote-source-login-unshelved",
                "book_detail_action_projection",
            ),
            (
                "remote-source-no-login-shelved",
                "book_detail_action_projection",
            ),
            (
                "remote-source-whitespace-login",
                "book_detail_action_projection",
            ),
            (
                "remote-missing-source",
                "book_detail_action_projection",
            ),
            (
                "local-txt-shelved",
                "book_detail_action_projection",
            ),
            (
                "local-non-txt-unshelved",
                "book_detail_action_projection",
            ),
        ),
        "nominal_cases": frozenset({
            "remote-source-login-unshelved",
            "remote-source-no-login-shelved",
            "remote-source-whitespace-login",
            "remote-missing-source",
            "local-txt-shelved",
            "local-non-txt-unshelved",
        }),
    },
    "rl-reader-cache-prefetch-policy-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "policy_evaluation",
            "cache_probe",
            "cancellation",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "local-book-does-not-create-task",
                "reader_prefetch_policy",
            ),
            (
                "configuration-below-two-disables-prefetch",
                "reader_prefetch_policy",
            ),
            (
                "minimum-enabled-prefetches-both-directions",
                "reader_prefetch_policy",
            ),
            (
                "window-skips-adjacent-current-and-state",
                "reader_prefetch_policy",
            ),
            (
                "window-clamps-at-book-start",
                "reader_prefetch_policy",
            ),
            (
                "window-clamps-at-book-end",
                "reader_prefetch_policy",
            ),
            (
                "two-direction-workers-start-concurrently",
                "reader_prefetch_policy",
            ),
            (
                "new-invocation-cancels-previous-policy-job",
                "reader_prefetch_policy",
            ),
        ),
        "nominal_cases": frozenset({
            "local-book-does-not-create-task",
            "configuration-below-two-disables-prefetch",
            "minimum-enabled-prefetches-both-directions",
            "window-skips-adjacent-current-and-state",
            "window-clamps-at-book-start",
            "window-clamps-at-book-end",
            "two-direction-workers-start-concurrently",
            "new-invocation-cancels-previous-policy-job",
        }),
    },
    "rl-reader-progress-toc-remap-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "reader_runtime",
        "stage_names": (
            "fixture_setup",
            "title_normalization",
            "search_window",
            "number_fallback",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "old-index-zero-short-circuits-empty-toc",
                "reader_progress_toc_remap",
            ),
            (
                "empty-new-toc-preserves-old-index",
                "reader_progress_toc_remap",
            ),
            (
                "cleaned-title-finds-inserted-chapter",
                "reader_progress_toc_remap",
            ),
            (
                "duplicate-cleaned-title-selects-first",
                "reader_progress_toc_remap",
            ),
            (
                "chapter-number-exact-match-recovers",
                "reader_progress_toc_remap",
            ),
            (
                "nearest-number-without-exact-match-falls-back",
                "reader_progress_toc_remap",
            ),
            (
                "fallback-clamps-high-index-to-new-last",
                "reader_progress_toc_remap",
            ),
            (
                "old-size-ratio-expands-search-to-index-zero",
                "reader_progress_toc_remap",
            ),
            (
                "old-size-ratio-excludes-early-title",
                "reader_progress_toc_remap",
            ),
            (
                "jaccard-exactly-point-nine-six-falls-back",
                "reader_progress_toc_remap",
            ),
            (
                "jaccard-above-point-nine-six-selects-title",
                "reader_progress_toc_remap",
            ),
        ),
        "nominal_cases": frozenset({
            "old-index-zero-short-circuits-empty-toc",
            "empty-new-toc-preserves-old-index",
            "cleaned-title-finds-inserted-chapter",
            "duplicate-cleaned-title-selects-first",
            "chapter-number-exact-match-recovers",
            "nearest-number-without-exact-match-falls-back",
            "fallback-clamps-high-index-to-new-last",
            "old-size-ratio-expands-search-to-index-zero",
            "old-size-ratio-excludes-early-title",
            "jaccard-exactly-point-nine-six-falls-back",
            "jaccard-above-point-nine-six-selects-title",
        }),
    },
    "rl-app-startup-first-use-and-restore-001": {
        "status": "candidate",
        "fixture_kind": "android_runtime_scenario",
        "result_type": "app_runtime",
        "stage_names": (
            "fixture_setup",
            "activity_launch",
            "privacy_gate",
            "onboarding_sequence",
            "restore_check",
            "result_mapping",
        ),
        "expected_cases": (
            (
                "welcome-default-opens-main-only",
                "app_startup_welcome",
            ),
            (
                "welcome-default-to-read-opens-reader-after-main",
                "app_startup_welcome",
            ),
            (
                "privacy-refusal-stops-main-pipeline",
                "app_startup_main_pipeline",
            ),
            (
                "first-open-agreement-runs-help-then-password",
                "app_startup_main_pipeline",
            ),
            (
                "returning-current-version-skips-onboarding",
                "app_startup_main_pipeline",
            ),
            (
                "returning-version-change-debug-skips-update-log",
                "app_startup_main_pipeline",
            ),
        ),
        "nominal_cases": frozenset({
            "welcome-default-opens-main-only",
            "welcome-default-to-read-opens-reader-after-main",
            "privacy-refusal-stops-main-pipeline",
            "first-open-agreement-runs-help-then-password",
            "returning-current-version-skips-onboarding",
            "returning-version-change-debug-skips-update-log",
        }),
    },
    "il-integration-backup-webdav-001": {
        "status": "candidate",
        "fixture_kind": "integration_lab_scenario",
        "result_type": "integration_runtime",
        "stage_names": (
            "fixture_setup",
            "request_build",
            "protocol_exchange",
            "response_parse",
            "result_mapping",
        ),
        "expected_cases": (
            ("check-unauthorized-false", "webdav_check"),
            ("check-non-auth-error-true", "webdav_check"),
            ("exists-multistatus-true", "webdav_exists"),
            ("exists-not-found-false", "webdav_exists"),
            (
                "make-directory-after-missing-probe",
                "webdav_make_directory",
            ),
            ("list-multistatus-metadata", "webdav_list"),
            ("get-encoded-file-metadata", "webdav_get_file"),
            ("download-byte-array", "webdav_download"),
            ("upload-byte-array", "webdav_upload"),
            ("delete-success", "webdav_delete"),
            ("delete-not-found-false", "webdav_delete"),
            ("object-not-found-exception", "webdav_get_file"),
        ),
        "nominal_cases": frozenset({
            "check-unauthorized-false",
            "check-non-auth-error-true",
            "exists-multistatus-true",
            "exists-not-found-false",
            "make-directory-after-missing-probe",
            "list-multistatus-metadata",
            "get-encoded-file-metadata",
            "download-byte-array",
            "upload-byte-array",
            "delete-success",
            "delete-not-found-false",
        }),
    },
    "il-integration-remote-http-websocket-management-001": {
        "status": "candidate",
        "fixture_kind": "integration_lab_scenario",
        "result_type": "integration_runtime",
        "stage_names": (
            "fixture_setup",
            "listener_start",
            "protocol_exchange",
            "route_dispatch",
            "result_mapping",
        ),
        "expected_cases": (
            ("listener-contract", "remote_listener_contract"),
            ("options-origin-echo", "remote_http_request"),
            ("options-without-origin", "remote_http_request"),
            ("static-index", "remote_http_request"),
            ("seeded-bookshelf", "remote_http_request"),
            ("missing-static-asset", "remote_http_request"),
            (
                "book-source-debug-handshake",
                "remote_websocket_handshake",
            ),
            (
                "rss-source-debug-handshake",
                "remote_websocket_handshake",
            ),
            ("search-book-handshake", "remote_websocket_handshake"),
            ("unknown-websocket-path", "remote_websocket_handshake"),
        ),
        "nominal_cases": frozenset({
            "listener-contract",
            "options-origin-echo",
            "options-without-origin",
            "static-index",
            "seeded-bookshelf",
            "missing-static-asset",
            "book-source-debug-handshake",
            "rss-source-debug-handshake",
            "search-book-handshake",
            "unknown-websocket-path",
        }),
    },
    "il-integration-system-text-to-speech-001": {
        "status": "candidate",
        "fixture_kind": "integration_lab_scenario",
        "result_type": "integration_runtime",
        "device_origin": "android-platform://text-to-speech",
        "stage_names": (
            "fixture_setup",
            "adapter_injection",
            "queue_planning",
            "progress_update",
            "platform_engine_probe",
            "result_mapping",
        ),
        "expected_cases": (
            ("helper-multiline-queue", "tts_helper_queue"),
            (
                "helper-latest-text-during-init",
                "tts_helper_initialization",
            ),
            ("helper-stop-keeps-engine", "tts_helper_lifecycle"),
            (
                "helper-clear-stops-shuts-down",
                "tts_helper_lifecycle",
            ),
            (
                "service-custom-speech-rate",
                "tts_service_speech_rate",
            ),
            (
                "service-follow-system-no-rate-write",
                "tts_service_speech_rate",
            ),
            (
                "service-done-skips-punctuation",
                "tts_service_progress",
            ),
            (
                "platform-engine-contract",
                "tts_platform_engine_probe",
            ),
        ),
        "nominal_cases": frozenset({
            "helper-multiline-queue",
            "helper-latest-text-during-init",
            "helper-stop-keeps-engine",
            "helper-clear-stops-shuts-down",
            "service-custom-speech-rate",
            "service-follow-system-no-rate-write",
            "service-done-skips-punctuation",
            "platform-engine-contract",
        }),
    },
}
ROUTE_OBSERVATION_SCENARIOS = {
    "sl-source-request-header-cookie-retry-layering-001": (
        "retry-two-with-header-cookie",
        "retry-default",
    ),
    "sl-source-transport-request-dispatch-contract-001": (
        "get-response-metadata",
        "post-raw-content-type",
        "post-json-default",
        "typed-string-hex",
        "byte-array-network",
        "input-stream-network",
    ),
    "sl-source-transport-response-decoding-runtime-001": (
        "header-utf8",
        "header-gbk",
        "detected-gbk",
        "utf8-bom",
        "wrong-declared-charset",
        "gzip-transparent",
        "zip-first-entry",
        "malformed-zip",
        "redirect-final-url",
        "redirect-final-target",
        "redirect-loop-denied",
    ),
    "sl-source-transport-retry-redirect-runtime-001": (
        "retry-default-single-failure",
        "retry-two-repeated-failure",
        "redirect-success-start",
        "redirect-success-final",
        "redirect-failure-start",
        "redirect-failure-final",
    ),
    "sl-source-cookie-persistent-session-merge-runtime-001": (
        "cookie-enabled-observe",
        "cookie-disabled-set",
        "cookie-redirect-start",
        "cookie-redirect-final",
    ),
    "sl-source-transport-dynamic-web-runtime-001": (
        "dynamic-default-html",
        "dynamic-custom-js",
        "dynamic-http-bypass",
        "dynamic-option-disabled",
        "dynamic-post-bootstrap",
        "dynamic-sniff-page",
        "dynamic-sniff-target",
        "dynamic-cookie-bridge",
        "dynamic-user-agent",
    ),
    "il-integration-backup-webdav-001": (
        "check-unauthorized",
        "check-method-not-allowed",
        "exists-present",
        "exists-missing",
        "create-probe",
        "create-collection",
        "list-multistatus",
        "get-file-metadata",
        "download-object",
        "upload-object",
        "delete-object",
        "delete-missing",
        "object-not-found",
    ),
}
ANDROID_PRODUCT_PATHS = (
    "app/src/main",
    "app/build.gradle",
    "modules",
    "build.gradle",
    "settings.gradle",
    "gradle",
    "gradle.properties",
)


class AndroidOracleRunnerError(RuntimeError):
    def __init__(self, reason_code: str, detail: str = ""):
        super().__init__(reason_code)
        self.reason_code = reason_code
        self.detail = detail


def _canonical(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AndroidOracleRunnerError(
            "CONTROL_JSON_INVALID",
            path.as_posix(),
        ) from error


def _run(
    argv: Sequence[str],
    *,
    cwd: Path,
    timeout: int,
    check: bool = True,
    input_bytes: Optional[bytes] = None,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            list(argv),
            cwd=cwd,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AndroidOracleRunnerError(
            "COMMAND_EXECUTION_FAILED",
            Path(argv[0]).name,
        ) from error
    if check and result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        detail = f"{Path(argv[0]).name}:{result.returncode}"
        if stderr:
            detail += ":" + stderr[-8_192:]
        raise AndroidOracleRunnerError(
            "COMMAND_FAILED",
            detail,
        )
    return result


def _git(
    root: Path,
    *arguments: str,
    check: bool = True,
    timeout: int = 60,
) -> bytes:
    return _run(
        ["git", *arguments],
        cwd=root,
        timeout=timeout,
        check=check,
    ).stdout


def _safe_regular(path: Path) -> Path:
    if path.is_symlink() or not path.is_file():
        raise AndroidOracleRunnerError(
            "REGULAR_FILE_REQUIRED",
            path.as_posix(),
        )
    return path


def _file_sha(path: Path) -> str:
    return _sha256(_safe_regular(path).read_bytes())


def _runner_files() -> tuple[Path, ...]:
    directory = Path(__file__).resolve().parent
    return (
        directory / KOTLIN_RUNNER,
        directory / "orchestrator.py",
        directory.parents[1] / "integration-lab" / "integration_lab.py",
    )


def runner_digest() -> str:
    entries = [
        {
            "path": path.relative_to(
                Path(__file__).resolve().parents[4]
            ).as_posix(),
            "sha256": _file_sha(path),
        }
        for path in sorted(
            _runner_files(),
            key=lambda value: value.as_posix(),
        )
    ]
    return _sha256(_canonical(entries))


def fixture_digest(directory: Path) -> str:
    inventory = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise AndroidOracleRunnerError(
                "FIXTURE_ENTRY_INVALID",
                path.as_posix(),
            )
        if path.is_file():
            inventory.append({
                "path": path.relative_to(directory).as_posix(),
                "sha256": _file_sha(path),
            })
    return _sha256(_canonical(inventory))


def frozen_identity(root: Path) -> Dict[str, str]:
    baseline = _read_json(root / BASELINE_PATH)
    inventory = _read_json(root / INVENTORY_PATH)
    oracle = baseline.get("android_oracle")
    if not isinstance(oracle, dict):
        raise AndroidOracleRunnerError("ANDROID_BASELINE_MISSING")
    commit = oracle.get("git_commit")
    if (
        not isinstance(commit, str)
        or inventory.get("android_git_commit") != commit
    ):
        raise AndroidOracleRunnerError("ANDROID_COMMIT_BINDING_DRIFT")
    tree = (
        _git(root, "rev-parse", f"{commit}^{{tree}}")
        .decode("ascii")
        .strip()
    )
    if inventory.get("android_tree") != tree:
        raise AndroidOracleRunnerError("ANDROID_TREE_BINDING_DRIFT")
    product_diff = _git(
        root,
        "diff",
        "--name-only",
        commit,
        "--",
        *ANDROID_PRODUCT_PATHS,
    )
    dirty_product = _git(
        root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--",
        *ANDROID_PRODUCT_PATHS,
    )
    if product_diff.strip() or dirty_product.strip():
        raise AndroidOracleRunnerError("ANDROID_PRODUCT_TREE_DRIFT")
    return {"android_git_commit": commit, "android_git_tree": tree}


def _scenario_contract(scenario_id: str) -> Mapping[str, Any]:
    contract = SCENARIO_CONTRACTS.get(scenario_id)
    if contract is None:
        raise AndroidOracleRunnerError(
            "SCENARIO_NOT_SUPPORTED",
            scenario_id,
        )
    return contract


def repository_bindings(
    root: Path,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, str]:
    identity = frozen_identity(root)
    contract = _scenario_contract(scenario_id)
    fixture_manifest = _read_json(root / FIXTURE_MANIFEST_PATH)
    source_lab_manifest = _read_json(root / SOURCE_LAB_MANIFEST_PATH)
    fixture_entries = {
        entry.get("id"): entry
        for entry in fixture_manifest.get("fixtures", [])
        if isinstance(entry, dict)
    }
    source_lab_entries = {
        entry.get("id"): entry
        for entry in source_lab_manifest.get("scenarios", [])
        if isinstance(entry, dict)
    }
    fixture_entry = fixture_entries.get(scenario_id)
    scenario_entry = source_lab_entries.get(scenario_id)
    if (
        not isinstance(fixture_entry, dict)
        or not isinstance(scenario_entry, dict)
        or scenario_entry.get("status") != contract["status"]
    ):
        raise AndroidOracleRunnerError("SCENARIO_BINDING_MISSING")
    fixture_path = fixture_entry.get("path")
    fixture_kind = str(
        contract.get("fixture_kind", "source_lab_scenario")
    )
    fixture_root_name = {
        "android_runtime_scenario": "runtime-lab",
        "integration_lab_scenario": "integration-lab",
        "source_lab_scenario": "source-lab",
    }.get(fixture_kind)
    if fixture_root_name is None:
        raise AndroidOracleRunnerError("SCENARIO_KIND_DRIFT")
    expected_path = (
        f"ios/harness/fixtures/{fixture_root_name}/{scenario_id}"
    )
    if (
        fixture_path != expected_path
        or scenario_entry.get("path") != expected_path
    ):
        raise AndroidOracleRunnerError("SCENARIO_PATH_DRIFT")
    fixture_root = root / expected_path
    input_path = fixture_root / "input.json"
    case_path = fixture_root / "case.json"
    if fixture_entry.get("sha256") != fixture_digest(fixture_root):
        raise AndroidOracleRunnerError("FIXTURE_DIGEST_DRIFT")
    case = _read_json(case_path)
    if (
        not isinstance(case, dict)
        or case.get("kind") != fixture_kind
        or case.get("id") != scenario_id
    ):
        raise AndroidOracleRunnerError("SCENARIO_KIND_DRIFT")
    bindings = {
        **identity,
        "scenario_id": scenario_id,
        "runner_id": RUNNER_VERSION,
        "runner_digest": runner_digest(),
        "fixture_kind": fixture_kind,
        "fixture_path": expected_path,
        "fixture_sha256": str(fixture_entry.get("sha256")),
        "scenario_sha256": str(scenario_entry.get("sha256")),
        "input_sha256": _file_sha(input_path),
        "case_sha256": _file_sha(case_path),
        "fixture_manifest_sha256": _sha256(
            _canonical(fixture_manifest)
        ),
        "source_lab_manifest_sha256": _sha256(
            _canonical(source_lab_manifest)
        ),
        "canonicalizer_sha256": _sha256(
            _canonical(_read_json(root / CANONICALIZER_PATH))
        ),
    }
    if fixture_kind == "source_lab_scenario":
        bindings["source_template_sha256"] = _file_sha(
            fixture_root / "source.template.json"
        )
    return bindings


def _recursive_strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for entry in value:
            yield from _recursive_strings(entry)
    elif isinstance(value, dict):
        for entry in value.values():
            yield from _recursive_strings(entry)


def normalize_raw_artifact(
    raw: Mapping[str, Any],
    bindings: Mapping[str, str],
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    contract = _scenario_contract(scenario_id)
    expected_cases = tuple(contract["expected_cases"])
    nominal_cases = set(contract["nominal_cases"])
    fixture_kind = str(
        contract.get("fixture_kind", "source_lab_scenario")
    )
    runtime_scenario = fixture_kind == "android_runtime_scenario"
    integration_scenario = fixture_kind == "integration_lab_scenario"
    structured_stimulus = runtime_scenario or integration_scenario
    expected_origin = (
        "android-runtime://local"
        if runtime_scenario
        else INTEGRATION_LOGICAL_ORIGIN
        if integration_scenario
        else LOGICAL_ORIGIN
    )
    if (
        raw.get("schema_version") != 1
        or raw.get("scenario_id") != scenario_id
        or raw.get("logical_origin") != expected_origin
    ):
        raise AndroidOracleRunnerError("RAW_ARTIFACT_IDENTITY_INVALID")
    device_origin = raw.get("device_origin")
    expected_device_origin = contract.get("device_origin")
    if runtime_scenario:
        device_origin_valid = device_origin == "android-runtime://local"
    elif isinstance(expected_device_origin, str):
        device_origin_valid = device_origin == expected_device_origin
    else:
        device_origin_valid = (
            isinstance(device_origin, str)
            and device_origin.startswith("http://127.0.0.1:")
        )
    if not device_origin_valid:
        raise AndroidOracleRunnerError("RAW_DEVICE_ORIGIN_INVALID")
    request_plan = raw.get("request_plan")
    cases = raw.get("cases")
    if not isinstance(request_plan, list) or not isinstance(cases, list):
        raise AndroidOracleRunnerError("RAW_ARTIFACT_SHAPE_INVALID")
    actual_cases = [
        (entry.get("id"), entry.get("operation"))
        for entry in cases
        if isinstance(entry, dict)
    ]
    if actual_cases != list(expected_cases) or len(request_plan) != len(cases):
        raise AndroidOracleRunnerError("RAW_CASE_SELECTION_DRIFT")
    route_observation = None
    observed_route_ids = ROUTE_OBSERVATION_SCENARIOS.get(scenario_id)
    if observed_route_ids is not None:
        route_counts = raw.get("source_lab_route_counts")
        if (
            not isinstance(route_counts, dict)
            or set(route_counts) != set(observed_route_ids)
            or any(
                not isinstance(route_counts[route_id], int)
                or isinstance(route_counts[route_id], bool)
                or route_counts[route_id] < 1
                for route_id in observed_route_ids
            )
        ):
            raise AndroidOracleRunnerError(
                "SOURCE_LAB_OBSERVATION_INVALID",
                ",".join(
                    f"{route_id}:{route_counts.get(route_id, 'missing')}"
                    for route_id in observed_route_ids
                ),
            )
        route_observation = {
            "route_request_counts": [
                {
                    "route_id": route_id,
                    "request_count": route_counts[route_id],
                }
                for route_id in observed_route_ids
            ]
        }
        if integration_scenario:
            observations = raw.get("integration_lab_observations")
            if (
                not isinstance(observations, list)
                or len(observations) != len(observed_route_ids)
            ):
                raise AndroidOracleRunnerError(
                    "INTEGRATION_LAB_OBSERVATION_INVALID"
                )
            validated_observations = []
            for index, observation in enumerate(observations):
                expected_keys = {
                    "route_id",
                    "method",
                    "logical_target",
                    "depth",
                    "authorization_scheme",
                    "content_type",
                    "body_sha256",
                    "body_bytes",
                }
                if (
                    not isinstance(observation, dict)
                    or set(observation) != expected_keys
                    or observation.get("route_id")
                    != observed_route_ids[index]
                    or observation.get("method")
                    not in {"GET", "PUT", "DELETE", "PROPFIND", "MKCOL"}
                    or not isinstance(
                        observation.get("logical_target"),
                        str,
                    )
                    or not observation["logical_target"].startswith(
                        INTEGRATION_LOGICAL_ORIGIN + "/"
                    )
                    or observation.get("authorization_scheme") != "Basic"
                    or (
                        observation.get("depth") is not None
                        and not isinstance(observation.get("depth"), str)
                    )
                    or (
                        observation.get("content_type") is not None
                        and not isinstance(
                            observation.get("content_type"),
                            str,
                        )
                    )
                    or not isinstance(observation.get("body_sha256"), str)
                    or re.fullmatch(
                        r"[0-9a-f]{64}",
                        observation["body_sha256"],
                    )
                    is None
                    or not isinstance(observation.get("body_bytes"), int)
                    or isinstance(observation.get("body_bytes"), bool)
                    or observation["body_bytes"] < 0
                    or observation["body_bytes"] > 1024 * 1024
                ):
                    raise AndroidOracleRunnerError(
                        "INTEGRATION_LAB_OBSERVATION_INVALID",
                        str(index),
                    )
                validated_observations.append(dict(observation))
            route_observation["requests"] = validated_observations
    portable_cases = []
    issues = []
    android_exceptions = []
    for index, entry in enumerate(cases):
        if not isinstance(entry, dict) or set(entry) != {
            "id",
            "operation",
            "request",
            "result",
            "issue",
        }:
            raise AndroidOracleRunnerError("RAW_CASE_INVALID")
        issue = entry["issue"]
        result = entry["result"]
        if entry["id"] in nominal_cases and (
            issue is not None or not isinstance(result, dict)
        ):
            raise AndroidOracleRunnerError(
                "ANDROID_CHARACTERIZATION_FAILED",
                str(entry.get("id")),
            )
        if issue is not None and (
            not isinstance(issue, dict)
            or issue.get("code") != "android_exception"
            or not isinstance(issue.get("exception_type"), str)
            or result is not None
        ):
            raise AndroidOracleRunnerError("RAW_ISSUE_INVALID")
        if issue is None and not isinstance(result, dict):
            raise AndroidOracleRunnerError("RAW_RESULT_INVALID")
        if entry["request"] != request_plan[index]:
            raise AndroidOracleRunnerError("RAW_REQUEST_BINDING_DRIFT")
        request = request_plan[index]
        if structured_stimulus:
            if (
                not isinstance(request, dict)
                or set(request) != {"operation", "arguments"}
                or request.get("operation") != entry.get("operation")
                or not isinstance(request.get("arguments"), dict)
            ):
                raise AndroidOracleRunnerError(
                    "RAW_STRUCTURED_STIMULUS_INVALID"
                )
            if any(
                isinstance(value, str)
                and ("http://" in value or "https://" in value)
                for value in _recursive_strings(request)
            ):
                raise AndroidOracleRunnerError(
                    "RAW_STRUCTURED_NETWORK_STIMULUS_INVALID"
                )
            request = request_plan[index]
        else:
            request = request_plan[index]
            expected_request_keys = {
                "method",
                "url",
                "headers",
                "body",
                "timeout_ms",
            }
            if scenario_id == "sl-post-form-001":
                expected_request_keys.update(
                    {"body_base64", "form_fields"}
                )
            request_url = request.get("url") if isinstance(request, dict) else None
            request_url_valid = (
                isinstance(request_url, str)
                and request_url.startswith(LOGICAL_ORIGIN + "/")
            )
            if (
                scenario_id
                == "sl-source-transport-request-dispatch-contract-001"
                and entry.get("id") == "data-uri-short-circuit"
            ):
                request_url_valid = (
                    isinstance(request_url, str)
                    and request_url.startswith("data:")
                )
            if (
                not isinstance(request, dict)
                or (
                    request.get("method") not in {"GET", "POST"}
                    if scenario_id in {
                        "sl-source-request-field-encoding-runtime-001",
                        "sl-source-request-url-template-compilation-001",
                        "sl-source-transport-request-dispatch-contract-001",
                        "sl-source-transport-dynamic-web-runtime-001",
                    }
                    else request.get("method")
                    != (
                        "POST"
                        if scenario_id == "sl-post-form-001"
                        else "GET"
                    )
                )
                or not request_url_valid
                or set(request) != expected_request_keys
            ):
                raise AndroidOracleRunnerError("RAW_REQUEST_INVALID")
        if scenario_id == "sl-source-transport-request-dispatch-contract-001":
            headers = request.get("headers")
            body = request.get("body")
            timeout_ms = request.get("timeout_ms")
            if (
                not isinstance(headers, list)
                or any(
                    not isinstance(header, dict)
                    or set(header) != {"name", "value"}
                    or not isinstance(header["name"], str)
                    or not isinstance(header["value"], str)
                    for header in headers
                )
                or (body is not None and not isinstance(body, str))
                or (
                    timeout_ms is not None
                    and (
                        not isinstance(timeout_ms, int)
                        or isinstance(timeout_ms, bool)
                        or timeout_ms <= 0
                    )
                )
            ):
                raise AndroidOracleRunnerError(
                    "RAW_TRANSPORT_REQUEST_INVALID"
                )
        if scenario_id == "sl-post-form-001":
            body = request.get("body")
            body_base64 = request.get("body_base64")
            fields = request.get("form_fields")
            if (
                not isinstance(body, str)
                or not isinstance(body_base64, str)
                or not isinstance(fields, list)
                or any(
                    not isinstance(value, dict)
                    or set(value) != {"key", "value"}
                    or not isinstance(value["key"], str)
                    or not isinstance(value["value"], str)
                    for value in fields
                )
            ):
                raise AndroidOracleRunnerError(
                    "RAW_POST_REQUEST_INVALID"
                )
            try:
                decoded_body = base64.b64decode(
                    body_base64,
                    validate=True,
                ).decode("utf-8")
            except (ValueError, UnicodeDecodeError) as error:
                raise AndroidOracleRunnerError(
                    "RAW_POST_BODY_INVALID"
                ) from error
            if decoded_body != body:
                raise AndroidOracleRunnerError(
                    "RAW_POST_BODY_BINDING_DRIFT"
                )
        portable_issue = (
            {
                "code": "rule_failed",
                "stage": "field_evaluation",
            }
            if issue is not None
            else None
        )
        portable_cases.append(
            {
                "id": entry["id"],
                "operation": entry["operation"],
                "result": result,
                "issue": portable_issue,
            }
        )
        if issue is not None:
            issues.append(
                {
                    "case_id": entry["id"],
                    "code": "rule_failed",
                    "stage": "field_evaluation",
                }
            )
            android_exceptions.append(
                {
                    "case_id": entry["id"],
                    "exception_type": issue["exception_type"],
                }
            )
    normalized_values = list(_recursive_strings(portable_cases))
    if any(device_origin in value for value in normalized_values):
        raise AndroidOracleRunnerError("DEVICE_ORIGIN_LEAK")
    stages = []
    stage_names = tuple(
        contract.get(
            "stage_names",
            (
                "url_template",
                "request_build",
                "transport",
                "response_decode",
                "document_creation",
                "field_evaluation",
                "url_completion",
                "result_mapping",
            ),
        )
    )
    issue_cases = {entry["case_id"] for entry in issues}
    for case_id, _ in expected_cases:
        for stage in stage_names:
            failure_stage = (
                "room_query"
                if runtime_scenario
                else "response_parse"
                if integration_scenario
                else "field_evaluation"
            )
            stages.append(
                {
                    "case_id": case_id,
                    "stage": stage,
                    "outcome": (
                        "failed"
                        if case_id in issue_cases
                        and stage == failure_stage
                        else "completed"
                    ),
                    "issue_code": (
                        "rule_failed"
                        if case_id in issue_cases
                        and stage == failure_stage
                        else None
                    ),
                }
            )
            if (
                case_id in issue_cases
                and stage == failure_stage
            ):
                break
    fixture_integrity = {
        "fixture_kind": fixture_kind,
        "fixture_sha256": bindings["fixture_sha256"],
        "scenario_sha256": bindings["scenario_sha256"],
        "input_sha256": bindings["input_sha256"],
    }
    if fixture_kind == "source_lab_scenario":
        fixture_integrity["source_template_sha256"] = bindings[
            "source_template_sha256"
        ]
    artifact = {
        "schema_version": 1,
        "fixture_id": scenario_id,
        "engine": {
            "platform": "android",
            "revision": bindings["android_git_commit"],
            "compatibility_profile": "android-legado-v1",
        },
        "request_plan": request_plan,
        "decode": None,
        "stages": stages,
        "result": {
            "type": str(contract.get("result_type", "source_pipeline")),
            "value": {
                "fixture_integrity": fixture_integrity,
                "portable_known_projection": {
                    "cases": portable_cases,
                },
                "android_characterization": {
                    "runner_id": bindings["runner_id"],
                    "runner_digest": bindings["runner_digest"],
                    "case_count": len(portable_cases),
                    "exceptions": android_exceptions,
                },
            },
        },
        "issues": issues,
    }
    if route_observation is not None:
        artifact["result"]["value"]["android_characterization"][
            (
                "integration_lab_observation"
                if integration_scenario
                else "source_lab_observation"
            )
        ] = route_observation
    return artifact


def local_run_document(
    artifact: Mapping[str, Any],
    bindings: Mapping[str, str],
    *,
    emulator_serial: str,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    artifact_sha256 = _sha256(_canonical(artifact))
    return {
        "schema_version": 1,
        "kind": "android_oracle_local_run",
        "authority": "local_unverified",
        "status": "candidate_only",
        "scenario_id": scenario_id,
        "emulator": {
            "serial_sha256": _sha256(emulator_serial.encode("utf-8")),
        },
        "bindings": dict(bindings),
        "artifact_sha256": artifact_sha256,
        "artifact": dict(artifact),
    }


def _atomic_private_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.parent.is_symlink() or not path.parent.is_dir():
        raise AndroidOracleRunnerError("OUTPUT_DIRECTORY_INVALID")
    if stat.S_IMODE(path.parent.stat().st_mode) & 0o077:
        os.chmod(path.parent, 0o700)
    if path.exists() and (path.is_symlink() or not path.is_file()):
        raise AndroidOracleRunnerError("OUTPUT_PATH_INVALID")
    descriptor, raw_temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
    )
    temporary = Path(raw_temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.write(b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _output_path(
    root: Path,
    requested: Optional[Path],
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Path:
    output_root = root / ".harness-runtime/android-oracle"
    if requested is None:
        return output_root / f"{scenario_id}-local-run.json"
    candidate = requested if requested.is_absolute() else root / requested
    candidate = candidate.absolute()
    try:
        candidate.relative_to(output_root.absolute())
    except ValueError as error:
        raise AndroidOracleRunnerError("OUTPUT_OUTSIDE_RUNTIME") from error
    return candidate


def _package_present(
    root: Path,
    adb: Path,
    serial: str,
    package: str,
) -> bool:
    result = _run(
        [str(adb), "-s", serial, "shell", "pm", "path", package],
        cwd=root,
        timeout=30,
        check=False,
    )
    return result.returncode == 0 and result.stdout.startswith(b"package:")


def _device_ready(root: Path, adb: Path, serial: str) -> None:
    _safe_regular(adb)
    state = _run(
        [str(adb), "-s", serial, "get-state"],
        cwd=root,
        timeout=30,
    ).stdout.strip()
    booted = _run(
        [
            str(adb),
            "-s",
            serial,
            "shell",
            "getprop",
            "sys.boot_completed",
        ],
        cwd=root,
        timeout=30,
    ).stdout.strip()
    if state != b"device" or booted != b"1":
        raise AndroidOracleRunnerError("EMULATOR_NOT_READY")
    for package in (TARGET_PACKAGE, TEST_PACKAGE):
        if _package_present(root, adb, serial, package):
            raise AndroidOracleRunnerError(
                "DEVICE_PACKAGE_PRESENT",
                package,
            )


def _single_apk(worktree: Path, pattern: str) -> Path:
    matches = [
        path
        for path in worktree.glob(pattern)
        if path.is_file() and not path.is_symlink()
    ]
    if len(matches) != 1:
        raise AndroidOracleRunnerError(
            "APK_DISCOVERY_FAILED",
            pattern,
        )
    return matches[0]


def _render_source(
    root: Path,
    origin: str,
    scenario_id: str,
) -> Dict[str, Any]:
    source_lab_directory = root / "ios/harness/source-lab"
    if str(source_lab_directory) not in sys.path:
        sys.path.insert(0, str(source_lab_directory))
    import source_lab  # type: ignore

    return source_lab.build_source(root, scenario_id, origin)


def _source_lab_server(root: Path, scenario_id: str):
    source_lab_directory = root / "ios/harness/source-lab"
    if str(source_lab_directory) not in sys.path:
        sys.path.insert(0, str(source_lab_directory))
    import source_lab  # type: ignore

    return source_lab.running_server(root, scenario_id)


def _integration_lab_server(root: Path, scenario_id: str):
    integration_lab_directory = root / "ios/harness/integration-lab"
    if str(integration_lab_directory) not in sys.path:
        sys.path.insert(0, str(integration_lab_directory))
    import integration_lab  # type: ignore

    return integration_lab.running_server(root, scenario_id)


def _integration_lab_transport_mode(
    root: Path,
    scenario_id: str,
) -> str:
    case = _read_json(
        root
        / "ios/harness/fixtures/integration-lab"
        / scenario_id
        / "case.json"
    )
    transport = case.get("transport") if isinstance(case, dict) else None
    mode = transport.get("mode") if isinstance(transport, dict) else None
    if mode not in {
        "fixture_and_loopback",
        "android_loopback_listener",
        "android_platform_service",
    }:
        raise AndroidOracleRunnerError(
            "INTEGRATION_TRANSPORT_MODE_INVALID"
        )
    return str(mode)


def _render_inputs(root: Path, scenario_id: str) -> Dict[str, Any]:
    manifest = _read_json(root / FIXTURE_MANIFEST_PATH)
    matches = [
        entry
        for entry in manifest.get("fixtures", [])
        if isinstance(entry, dict) and entry.get("id") == scenario_id
    ]
    if len(matches) != 1 or not isinstance(matches[0].get("path"), str):
        raise AndroidOracleRunnerError("FIXTURE_BINDING_MISSING")
    path = root / str(matches[0]["path"]) / "input.json"
    value = _read_json(path)
    if not isinstance(value, dict):
        raise AndroidOracleRunnerError("INPUT_DOCUMENT_INVALID")
    return value


def _instrumentation_arguments(
    *,
    adb: Path,
    serial: str,
    source_base64: Optional[str],
    integration_scenario: bool,
    device_origin: Optional[str],
    logical_origin: str,
    scenario_id: str,
    input_base64: str,
) -> list[str]:
    arguments = [
        str(adb),
        "-s",
        serial,
        "shell",
        "am",
        "instrument",
        "-w",
        "-r",
        "-e",
        "class",
        TEST_CLASS,
    ]
    if source_base64 is not None:
        arguments.extend(["-e", "sourceBase64", source_base64])
    if integration_scenario:
        if device_origin is None:
            raise AndroidOracleRunnerError(
                "INTEGRATION_DEVICE_ORIGIN_MISSING"
            )
        arguments.extend(["-e", "deviceOrigin", device_origin])
    arguments.extend(
        [
            "-e",
            "logicalOrigin",
            logical_origin,
            "-e",
            "scenarioId",
            scenario_id,
            "-e",
            "inputBase64",
            input_base64,
            INSTRUMENTATION,
        ]
    )
    return arguments


def run_characterization(
    root: Path,
    *,
    adb: Path,
    serial: str,
    output: Optional[Path] = None,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    contract = _scenario_contract(scenario_id)
    expected_cases = tuple(contract["expected_cases"])
    bindings = repository_bindings(root, scenario_id)
    _device_ready(root, adb, serial)
    temporary_root = Path(
        tempfile.mkdtemp(prefix="legado-android-oracle-")
    ).resolve()
    worktree = temporary_root / "android"
    worktree_registered = False
    installed_packages: list[str] = []
    reverse_port: Optional[int] = None
    try:
        _git(
            root,
            "worktree",
            "add",
            "--detach",
            str(worktree),
            bindings["android_git_commit"],
        )
        worktree_registered = True
        overlay = worktree / OVERLAY_RELATIVE
        overlay.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            Path(__file__).resolve().parent / KOTLIN_RUNNER,
            overlay,
        )
        status = _git(
            worktree,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        ).decode("utf-8").splitlines()
        expected_status = f"?? {OVERLAY_RELATIVE}"
        if status != [expected_status]:
            raise AndroidOracleRunnerError(
                "WORKTREE_OVERLAY_DRIFT",
                ",".join(status),
            )
        _run(
            [
                str(worktree / "gradlew"),
                ":app:assembleAppDebug",
                ":app:assembleAppDebugAndroidTest",
                "--offline",
                "--no-daemon",
            ],
            cwd=worktree,
            timeout=1800,
        )
        main_apk = _single_apk(
            worktree,
            "app/build/outputs/apk/app/debug/*.apk",
        )
        test_apk = _single_apk(
            worktree,
            "app/build/outputs/apk/androidTest/app/debug/*.apk",
        )
        _run(
            [str(adb), "-s", serial, "install", str(main_apk)],
            cwd=root,
            timeout=180,
        )
        installed_packages.append(TARGET_PACKAGE)
        _run(
            [str(adb), "-s", serial, "install", str(test_apk)],
            cwd=root,
            timeout=180,
        )
        installed_packages.append(TEST_PACKAGE)

        fixture_kind = bindings["fixture_kind"]
        runtime_scenario = fixture_kind == "android_runtime_scenario"
        integration_scenario = fixture_kind == "integration_lab_scenario"
        integration_transport_mode = (
            _integration_lab_transport_mode(root, scenario_id)
            if integration_scenario
            else None
        )
        if runtime_scenario:
            server_context = contextlib.nullcontext(None)
        elif (
            integration_scenario
            and integration_transport_mode == "fixture_and_loopback"
        ):
            server_context = _integration_lab_server(root, scenario_id)
        elif integration_scenario:
            server_context = contextlib.nullcontext(None)
        else:
            server_context = _source_lab_server(root, scenario_id)
        source_lab_route_counts: Dict[str, int] = {}
        integration_lab_observations: list[Dict[str, Any]] = []
        with server_context as server:
            source_base64: Optional[str] = None
            device_origin: Optional[str] = {
                "android_loopback_listener": "http://127.0.0.1:0",
                "android_platform_service":
                    "android-platform://text-to-speech",
            }.get(integration_transport_mode)
            logical_origin = (
                "android-runtime://local"
                if runtime_scenario
                else INTEGRATION_LOGICAL_ORIGIN
                if integration_scenario
                else LOGICAL_ORIGIN
            )
            if server is not None:
                reverse_port = int(server.server_address[1])
                _run(
                    [
                        str(adb),
                        "-s",
                        serial,
                        "reverse",
                        f"tcp:{reverse_port}",
                        f"tcp:{reverse_port}",
                    ],
                    cwd=root,
                    timeout=30,
                )
                device_origin = f"http://127.0.0.1:{reverse_port}"
                if not integration_scenario:
                    source = _render_source(
                        root,
                        device_origin,
                        scenario_id,
                    )
                    source_base64 = base64.b64encode(
                        _canonical(source)
                    ).decode("ascii")
            inputs = _render_inputs(root, scenario_id)
            input_base64 = base64.b64encode(
                _canonical(inputs)
            ).decode("ascii")
            instrumentation_arguments = _instrumentation_arguments(
                adb=adb,
                serial=serial,
                source_base64=source_base64,
                integration_scenario=integration_scenario,
                device_origin=device_origin,
                logical_origin=logical_origin,
                scenario_id=scenario_id,
                input_base64=input_base64,
            )
            instrumentation = _run(
                instrumentation_arguments,
                cwd=root,
                timeout=300,
            )
            if (
                b"OK (" not in instrumentation.stdout
                or b"FAILURES!!!" in instrumentation.stdout
            ):
                diagnostic = (
                    instrumentation.stdout
                    + b"\n"
                    + instrumentation.stderr
                ).decode("utf-8", errors="replace")
                raise AndroidOracleRunnerError(
                    "INSTRUMENTATION_FAILED",
                    diagnostic[-16_384:],
                )
            raw_bytes = _run(
                [
                    str(adb),
                    "-s",
                    serial,
                    "exec-out",
                    "run-as",
                    TARGET_PACKAGE,
                    "cat",
                    RAW_DEVICE_PATH,
                ],
                cwd=root,
                timeout=30,
            ).stdout
            if server is not None:
                source_lab_route_counts = dict(
                    server.route_request_counts
                )
                if integration_scenario:
                    integration_lab_observations = [
                        dict(value)
                        for value in server.request_observations
                    ]
        try:
            raw = json.loads(raw_bytes)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise AndroidOracleRunnerError(
                "RAW_ARTIFACT_JSON_INVALID"
            ) from error
        if not isinstance(raw, dict):
            raise AndroidOracleRunnerError("RAW_ARTIFACT_SHAPE_INVALID")
        if scenario_id in ROUTE_OBSERVATION_SCENARIOS:
            raw["source_lab_route_counts"] = source_lab_route_counts
        if integration_scenario:
            raw["integration_lab_observations"] = (
                integration_lab_observations
            )
        artifact = normalize_raw_artifact(
            raw,
            bindings,
            scenario_id,
        )
        document = local_run_document(
            artifact,
            bindings,
            emulator_serial=serial,
            scenario_id=scenario_id,
        )
        output_path = _output_path(
            root,
            output,
            scenario_id,
        )
        payload = _canonical(document)
        _atomic_private_write(output_path, payload)
        return {
            "schema_version": 1,
            "authority": "local_unverified",
            "status": "candidate_only",
            "scenario_id": scenario_id,
            "runner_digest": bindings["runner_digest"],
            "artifact_sha256": document["artifact_sha256"],
            "local_run_sha256": _sha256(payload),
            "output": output_path.relative_to(root).as_posix(),
            "case_count": len(expected_cases),
        }
    finally:
        if reverse_port is not None:
            _run(
                [
                    str(adb),
                    "-s",
                    serial,
                    "reverse",
                    "--remove",
                    f"tcp:{reverse_port}",
                ],
                cwd=root,
                timeout=30,
                check=False,
            )
        for package in reversed(installed_packages):
            _run(
                [str(adb), "-s", serial, "uninstall", package],
                cwd=root,
                timeout=60,
                check=False,
            )
        if worktree_registered:
            _git(
                root,
                "worktree",
                "remove",
                "--force",
                str(worktree),
                check=False,
                timeout=300,
            )
        if temporary_root.name.startswith("legado-android-oracle-"):
            shutil.rmtree(temporary_root, ignore_errors=True)


def doctor(
    root: Path,
    scenario_id: str = DEFAULT_SCENARIO_ID,
) -> Dict[str, Any]:
    root = root.resolve(strict=True)
    bindings = repository_bindings(root, scenario_id)
    forbidden = {
        "accept",
        "publish",
        "promote",
        "record",
        "update-golden",
    }
    if forbidden.intersection(COMMANDS):
        raise AndroidOracleRunnerError("AUTHORITY_COMMAND_EXPOSED")
    return {
        "schema_version": 1,
        "ok": True,
        "commands": list(COMMANDS),
        "scenario_id": scenario_id,
        "android_git_commit": bindings["android_git_commit"],
        "android_git_tree": bindings["android_git_tree"],
        "runner_digest": bindings["runner_digest"],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="android-oracle-runner")
    commands = parser.add_subparsers(dest="command", required=True)
    doctor_parser = commands.add_parser("doctor")
    doctor_parser.add_argument("--root", type=Path, required=True)
    doctor_parser.add_argument(
        "--scenario",
        default=DEFAULT_SCENARIO_ID,
        choices=sorted(SCENARIO_CONTRACTS),
    )
    run_parser = commands.add_parser("run")
    run_parser.add_argument("--root", type=Path, required=True)
    run_parser.add_argument("--adb", type=Path, required=True)
    run_parser.add_argument("--serial", required=True)
    run_parser.add_argument("--output", type=Path)
    run_parser.add_argument(
        "--scenario",
        default=DEFAULT_SCENARIO_ID,
        choices=sorted(SCENARIO_CONTRACTS),
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "doctor":
        report = doctor(args.root, args.scenario)
    else:
        report = run_characterization(
            args.root,
            adb=args.adb.resolve(strict=True),
            serial=args.serial,
            output=args.output,
            scenario_id=args.scenario,
        )
    sys.stdout.buffer.write(_canonical(report) + b"\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AndroidOracleRunnerError as error:
        report = {
            "schema_version": 1,
            "ok": False,
            "reason_code": error.reason_code,
            "detail": error.detail,
        }
        sys.stdout.buffer.write(_canonical(report) + b"\n")
        raise SystemExit(2)
