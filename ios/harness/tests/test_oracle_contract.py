import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class OracleContractAuthorityTests(unittest.TestCase):
    def test_ci_and_trusted_import_share_repository_contract(self):
        ci_proposal = (
            REPOSITORY_ROOT / "ios/harness/oracle/ci_proposal.py"
        ).read_text(encoding="utf-8")
        trusted_import = (
            REPOSITORY_ROOT / "ios/harness/oracle/trusted_import.py"
        ).read_text(encoding="utf-8")

        self.assertIn("verify_proposal(", ci_proposal)
        self.assertIn("verify_proposal(", trusted_import)


if __name__ == "__main__":
    unittest.main()
