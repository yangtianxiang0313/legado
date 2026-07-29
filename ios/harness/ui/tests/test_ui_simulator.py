import base64
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
MODULE_PATH = ROOT / "ios/harness/ui/ui_simulator.py"
SPEC = importlib.util.spec_from_file_location("ui_simulator", MODULE_PATH)
assert SPEC and SPEC.loader
ui_simulator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ui_simulator)


class UISimulatorContractTests(unittest.TestCase):
    def test_first_difference_is_stable_json_pointer(self):
        expected = {"steps": [{"screen": "shelf"}, {"screen": "search"}]}
        actual = {"steps": [{"screen": "shelf"}, {"screen": "reader"}]}

        self.assertEqual(
            "/steps/1/screen",
            ui_simulator.first_difference(expected, actual),
        )

    def test_observed_payload_requires_one_valid_marker(self):
        value = {"simulator_id": "SIM-PHONE-COMPACT-001"}
        encoded = base64.b64encode(
            json.dumps(value).encode("utf-8")
        ).decode("ascii")

        self.assertEqual(
            value,
            ui_simulator.observed_payload(
                f"noise\n{ui_simulator.MARKER}{encoded}\n"
            ),
        )
        with self.assertRaisesRegex(
            ui_simulator.UIAcceptanceError,
            "UI_OBSERVED_MARKER_INVALID",
        ):
            ui_simulator.observed_payload("no marker")

    def test_safe_path_rejects_escape(self):
        with self.assertRaisesRegex(
            ui_simulator.UIAcceptanceError,
            "UI_PATH_INVALID",
        ):
            ui_simulator.safe_path(ROOT, "../secret")

    def test_ui_test_method_defaults_and_rejects_injection(self):
        self.assertEqual(
            "testRootTopology",
            ui_simulator.ui_test_method({}),
        )
        self.assertEqual(
            "testStartupFirstUseAndRestore",
            ui_simulator.ui_test_method(
                {"test_method": "testStartupFirstUseAndRestore"}
            ),
        )
        with self.assertRaisesRegex(
            ui_simulator.UIAcceptanceError,
            "UI_TEST_METHOD_INVALID",
        ):
            ui_simulator.ui_test_method(
                {"test_method": "testRootTopology;rm"}
            )


if __name__ == "__main__":
    unittest.main()
