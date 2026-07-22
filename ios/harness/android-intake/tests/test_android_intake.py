import copy
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
        self.assertEqual(12, len(first["facts"]))

    def test_book_source_fact_is_data_contract_not_runtime_proof(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        facts = {entry["id"]: entry for entry in inventory["facts"]}
        fact = facts["AF-BOOKSOURCE-CONSTRUCTOR"]
        names = {entry["name"] for entry in fact["payload"]["properties"]}
        self.assertIn("ruleReview", names)
        self.assertEqual("L1", fact["evidence_level"])
        self.assertEqual("declaration_only", fact["support_state"])

    def test_pipeline_entrypoints_require_characterization(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        catalog = android_intake.catalog_value(REPO_ROOT, inventory)
        entry = next(
            value for value in catalog["requirements"]
            if value["id"] == "REQ-ANDROID-SOURCE-PIPELINE-001"
        )
        self.assertEqual("characterization_required", entry["readiness"])

    def test_source_format_work_item_has_content_addressed_selection(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        catalog = android_intake.catalog_value(REPO_ROOT, inventory)
        item = json.loads(
            (REPO_ROOT / "ios/harness/work-items/IOS-SOURCE-FORMAT-001.json").read_text(encoding="utf-8")
        )
        selection = android_intake.requirement_selection(REPO_ROOT, item, inventory, catalog)
        self.assertIsNotNone(selection)
        self.assertEqual("implementation", selection["mode"])
        self.assertEqual(64, len(android_intake.sha256_json(selection)))

    def test_implementation_rejects_uncharacterized_pipeline(self):
        inventory = android_intake.inventory_value(REPO_ROOT)
        catalog = android_intake.catalog_value(REPO_ROOT, inventory)
        item = json.loads(
            (REPO_ROOT / "ios/harness/work-items/IOS-SOURCELAB-ENGINE-001.json").read_text(encoding="utf-8")
        )
        candidate = copy.deepcopy(item)
        candidate["spec"]["requirements"]["mode"] = "implementation"
        with self.assertRaises(android_intake.IntakeError):
            android_intake.requirement_selection(REPO_ROOT, candidate, inventory, catalog)


if __name__ == "__main__":
    unittest.main()
