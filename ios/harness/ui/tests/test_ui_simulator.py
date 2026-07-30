import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]
MODULE_PATH = ROOT / "ios/harness/ui/ui_simulator.py"
SPEC = importlib.util.spec_from_file_location("ui_simulator", MODULE_PATH)
assert SPEC and SPEC.loader
ui_simulator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ui_simulator)


class UISimulatorContractTests(unittest.TestCase):
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
