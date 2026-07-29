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
        self.assertEqual(14, len(first["facts"]))

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

if __name__ == "__main__":
    unittest.main()
