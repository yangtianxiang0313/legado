import json
import sys
import unittest
from pathlib import Path


INTAKE_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = INTAKE_ROOT.parents[2]
sys.path.insert(0, str(INTAKE_ROOT))

import android_intake  # noqa: E402


class AndroidIntakeTests(unittest.TestCase):
    def test_inventory_is_deterministic_and_bound_to_baseline(self):
        first = android_intake.inventory_value(REPO_ROOT)
        second = android_intake.inventory_value(REPO_ROOT)
        self.assertEqual(first, second)
        baseline = json.loads((REPO_ROOT / "ios/project/baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(baseline["android_oracle"]["git_commit"], first["android_git_commit"])
        self.assertEqual(44, len(first["facts"]))

    def test_book_source_fact_is_data_contract_not_runtime_proof(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        fact = facts["AF-BOOKSOURCE-CONSTRUCTOR"]
        names = {entry["name"] for entry in fact["payload"]["properties"]}
        self.assertIn("ruleReview", names)
        self.assertEqual("L1", fact["evidence_level"])
        self.assertEqual("declaration_only", fact["support_state"])

    def test_pipeline_entrypoints_are_ready_after_android_characterization(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        catalog = android_intake.catalog_value(REPO_ROOT, inventory)
        entry = next(
            value for value in catalog["requirements"]
            if value["id"] == "REQ-ANDROID-SOURCE-PIPELINE-001"
        )
        self.assertEqual("implementation_ready", entry["readiness"])

    def test_bookmark_query_fact_preserves_sql_precedence(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        query = facts["AF-BOOKMARK-FLOW-SEARCH-QUERY"]
        self.assertEqual("kotlin_room_query", query["payload"]["kind"])
        self.assertIn(
            "and chapterName like '%'||:key||'%' or content like '%'||:key||'%'",
            query["payload"]["sql"],
        )
        bookmark = facts["AF-BOOKMARK-CONSTRUCTOR"]
        self.assertEqual(
            [
                "time",
                "bookName",
                "bookAuthor",
                "chapterIndex",
                "chapterPos",
                "chapterName",
                "bookText",
                "content",
            ],
            [value["name"] for value in bookmark["payload"]["properties"]],
        )

    def test_analyze_rule_string_consumers_are_inventory_anchors(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        self.assertEqual(
            "getString",
            facts["AF-ANALYZE-RULE-GET-STRING"]["payload"]["symbol"],
        )
        self.assertEqual(
            "getStringList",
            facts["AF-ANALYZE-RULE-GET-STRING-LIST"]["payload"]["symbol"],
        )

    def test_jsonpath_and_regex_backends_have_source_anchors(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        self.assertEqual(
            "getObject",
            facts["AF-ANALYZE-JSONPATH-GET-OBJECT"]["payload"]["symbol"],
        )
        self.assertEqual(
            "getList",
            facts["AF-ANALYZE-JSONPATH-GET-LIST"]["payload"]["symbol"],
        )
        self.assertEqual(
            "getElement",
            facts["AF-ANALYZE-REGEX-GET-ELEMENT"]["payload"]["symbol"],
        )
        self.assertEqual(
            "getElements",
            facts["AF-ANALYZE-REGEX-GET-ELEMENTS"]["payload"]["symbol"],
        )
        self.assertEqual(
            "replaceRegex",
            facts["AF-ANALYZE-RULE-REPLACE-REGEX"]["payload"]["symbol"],
        )

    def test_read_record_runtime_risk_has_source_anchors(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        self.assertEqual(
            "select sum(readTime) from readRecord where bookName = :bookName",
            facts["AF-READ-RECORD-AGGREGATE-QUERY"]["payload"]["sql"],
        )
        self.assertEqual(
            ["deviceId", "bookName", "readTime", "lastRead"],
            [
                value["name"]
                for value in
                facts["AF-READ-RECORD-CONSTRUCTOR"]["payload"]["properties"]
            ],
        )
        self.assertEqual(
            "resetData",
            facts["AF-READ-BOOK-RESET-DATA"]["payload"]["symbol"],
        )
        self.assertEqual(
            "upReadTime",
            facts["AF-READ-BOOK-UP-READ-TIME"]["payload"]["symbol"],
        )
        self.assertEqual(
            "onPause",
            facts["AF-READ-ACTIVITY-ON-PAUSE"]["payload"]["symbol"],
        )

    def test_reader_progress_runtime_has_layout_and_save_anchors(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        self.assertEqual(
            "setPageIndex",
            facts["AF-READ-BOOK-SET-PAGE-INDEX"]["payload"]["symbol"],
        )
        self.assertEqual(
            "getReadLength",
            facts["AF-TEXT-CHAPTER-GET-READ-LENGTH"]["payload"]["symbol"],
        )
        self.assertEqual(
            "getPageIndexByCharIndex",
            facts["AF-TEXT-CHAPTER-GET-PAGE-INDEX"]["payload"]["symbol"],
        )
        self.assertEqual(
            "saveRead",
            facts["AF-AUDIO-PLAY-SAVE-READ"]["payload"]["symbol"],
        )

    def test_reader_prefetch_runtime_has_policy_and_index_anchors(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        self.assertEqual(
            "preDownload",
            facts["AF-READ-BOOK-PRE-DOWNLOAD"]["payload"]["symbol"],
        )
        self.assertEqual(
            "downloadIndex",
            facts["AF-READ-BOOK-DOWNLOAD-INDEX"]["payload"]["symbol"],
        )

    def test_reader_toc_remap_has_book_help_anchor(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        self.assertEqual(
            "getDurChapter",
            facts["AF-BOOK-HELP-GET-DUR-CHAPTER"]["payload"]["symbol"],
        )

    def test_webdav_runtime_has_protocol_operation_anchors(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        expected = {
            "AF-WEBDAV-CHECK": "check",
            "AF-WEBDAV-EXISTS": "exists",
            "AF-WEBDAV-MAKE-DIR": "makeAsDir",
            "AF-WEBDAV-LIST-FILES": "listFiles",
            "AF-WEBDAV-GET-FILE": "getWebDavFile",
            "AF-WEBDAV-DOWNLOAD": "download",
            "AF-WEBDAV-UPLOAD": "upload",
            "AF-WEBDAV-DELETE": "delete",
        }
        self.assertEqual(
            expected,
            {
                fact_id: facts[fact_id]["payload"]["symbol"]
                for fact_id in expected
            },
        )

if __name__ == "__main__":
    unittest.main()
