#!/usr/bin/env python3
"""Compare live iOS real-source output with frozen Android truth."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit, urlunsplit


def projection(document: dict) -> dict[str, dict]:
    artifact = document.get("artifact", document)
    cases = artifact["result"]["value"]["portable_known_projection"]["cases"]
    return {case["id"]: case for case in cases}


def normalized_url(value: str | None) -> str | None:
    if value is None:
        return None
    parts = urlsplit(value)
    return urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower(), unquote(parts.path), parts.query, "")
    )


def normalized_book(book: dict) -> dict:
    value = dict(book)
    value["book_url"] = normalized_url(value.get("book_url"))
    value["cover_url"] = normalized_url(value.get("cover_url"))
    return value


def normalized_detail(detail: dict) -> dict:
    value = normalized_book(detail)
    value["toc_url"] = normalized_url(value.get("toc_url"))
    return value


def normalized_chapters(chapters: list[dict]) -> list[dict]:
    return [{**chapter, "url": normalized_url(chapter["url"])} for chapter in chapters]


def compare(android: dict, ios: dict, target_title: str) -> dict:
    expected = projection(android)
    actual = projection(ios)
    required_ids = ["real-search", "real-book-info", "real-toc", "real-content"]
    checks: list[dict] = []

    def check(name: str, expected_value, actual_value) -> None:
        checks.append(
            {
                "name": name,
                "passed": expected_value == actual_value,
                "expected": expected_value,
                "actual": actual_value,
            }
        )

    check("case_ids", required_ids, list(actual))
    android_books = expected["real-search"]["result"]["books"]
    ios_books = actual["real-search"]["result"]["books"]
    android_target = next(book for book in android_books if book["name"] == target_title)
    ios_target = next((book for book in ios_books if book["name"] == target_title), None)
    check(
        "search_target",
        normalized_book(android_target),
        normalized_book(ios_target) if ios_target else None,
    )
    check(
        "book_info",
        normalized_detail(expected["real-book-info"]["result"]),
        normalized_detail(actual["real-book-info"]["result"]),
    )
    check(
        "toc",
        normalized_chapters(expected["real-toc"]["result"]["chapters"]),
        normalized_chapters(actual["real-toc"]["result"]["chapters"]),
    )

    expected_content = expected["real-content"]["result"]
    actual_content = actual["real-content"]["result"]
    check("content_title", expected_content["chapter_title"], actual_content["chapter_title"])
    check(
        "content_url",
        normalized_url(expected_content["chapter_url"]),
        normalized_url(actual_content["chapter_url"]),
    )
    check("content_sample", expected_content["content_sample"], actual_content["content_sample"])
    expected_count = expected_content["content_characters"]
    actual_count = actual_content["content_characters"]
    count_tolerance = max(8, round(expected_count * 0.01))
    checks.append(
        {
            "name": "content_character_count",
            "passed": abs(expected_count - actual_count) <= count_tolerance,
            "expected": expected_count,
            "actual": actual_count,
            "tolerance": count_tolerance,
        }
    )
    return {
        "schema_version": 1,
        "passed": all(item["passed"] for item in checks),
        "authority": "frozen_android_real_source",
        "checks": checks,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("android_golden", type=Path)
    parser.add_argument("--ios-output", type=Path)
    parser.add_argument("--target-title", default="論語")
    args = parser.parse_args()
    android = json.loads(args.android_golden.read_text())
    ios = json.loads(args.ios_output.read_text() if args.ios_output else sys.stdin.read())
    result = compare(android, ios, args.target_title)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
