import ast
import unittest
from pathlib import Path
import sys


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
HARNESS_ROOT = REPOSITORY_ROOT / "ios/harness"
sys.path.insert(0, str(HARNESS_ROOT))

from oracle import ci_proposal, trusted_import  # noqa: E402
from oracle.contract import verify_proposal  # noqa: E402


class OracleContractAuthorityTests(unittest.TestCase):
    def test_ci_and_trusted_import_share_repository_contract(self):
        self._assert_shared_contract_call("ci_proposal.py", "finalize")
        self._assert_shared_contract_call("trusted_import.py", "verify")

    def _assert_shared_contract_call(self, module_name, function_name):
        module_path = REPOSITORY_ROOT / "ios/harness/oracle" / module_name
        tree = ast.parse(module_path.read_text(encoding="utf-8"))
        shared_imports = [
            node
            for node in tree.body
            if isinstance(node, ast.ImportFrom)
            and node.module == "oracle.contract"
            and any(alias.name == "verify_proposal" for alias in node.names)
        ]
        self.assertEqual(
            1,
            len(shared_imports),
            f"{module_name} must import the repository contract directly",
        )
        functions = [
            node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name == function_name
        ]
        self.assertEqual(1, len(functions), f"{module_name}.{function_name} missing")
        calls = [
            node
            for node in ast.walk(functions[0])
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "verify_proposal"
        ]
        self.assertEqual(
            1,
            len(calls),
            f"{module_name}.{function_name} must call the shared contract exactly once",
        )

    def test_ci_and_trusted_import_use_same_contract_function(self):
        self.assertIs(ci_proposal.verify_proposal, verify_proposal)
        self.assertIs(trusted_import.verify_proposal, verify_proposal)


if __name__ == "__main__":
    unittest.main()
