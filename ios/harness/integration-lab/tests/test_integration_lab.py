import http.client
import json
import sys
import unittest
from pathlib import Path


INTEGRATION_LAB_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = INTEGRATION_LAB_ROOT.parents[2]
sys.path.insert(0, str(INTEGRATION_LAB_ROOT))

import integration_lab  # noqa: E402


class IntegrationLabTests(unittest.TestCase):
    scenario = "il-integration-backup-webdav-001"
    listener_scenario = (
        "il-integration-remote-http-websocket-management-001"
    )

    def test_scenario_contract_and_manifest_are_current(self):
        directory, case, inputs = integration_lab.load_scenario(
            REPO_ROOT,
            self.scenario,
        )
        self.assertEqual(
            [],
            integration_lab.validate_scenario(
                REPO_ROOT,
                directory,
                case,
            ),
        )
        self.assertEqual("integration_lab_scenario", case["kind"])
        self.assertEqual(12, len(inputs["cases"]))
        self.assertEqual(
            integration_lab.manifest_value(REPO_ROOT),
            json.loads(
                (
                    INTEGRATION_LAB_ROOT / "manifest.json"
                ).read_text(encoding="utf-8")
            ),
        )

    def test_server_binds_ipv4_loopback_and_records_only_redacted_shape(self):
        with integration_lab.running_server(
            REPO_ROOT,
            self.scenario,
        ) as server:
            host, port = server.server_address[:2]
            self.assertEqual("127.0.0.1", host)
            self.assertGreater(port, 0)
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request(
                "PUT",
                "/dav/upload.bin",
                body=b"private-body",
                headers={
                    "Host": server.authority,
                    "Authorization": "Basic must-not-escape",
                    "Content-Type": "application/octet-stream",
                },
            )
            response = connection.getresponse()
            response.read()
            connection.close()
            self.assertEqual(201, response.status)
            self.assertEqual(1, len(server.request_observations))
            observation = server.request_observations[0]
            self.assertEqual("Basic", observation["authorization_scheme"])
            self.assertEqual(12, observation["body_bytes"])
            rendered = json.dumps(observation, ensure_ascii=False)
            self.assertNotIn("must-not-escape", rendered)
            self.assertNotIn("private-body", rendered)

    def test_server_rejects_wrong_authority_and_undeclared_route(self):
        with integration_lab.running_server(
            REPO_ROOT,
            self.scenario,
        ) as server:
            host, port = server.server_address[:2]
            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request(
                "GET",
                "/dav/download.bin",
                headers={"Host": "localhost"},
            )
            wrong_host = connection.getresponse()
            wrong_host.read()
            connection.close()
            self.assertEqual(421, wrong_host.status)

            connection = http.client.HTTPConnection(host, port, timeout=2)
            connection.request(
                "GET",
                "/not-declared",
                headers={"Host": server.authority},
            )
            missing = connection.getresponse()
            missing.read()
            connection.close()
            self.assertEqual(404, missing.status)

    def test_protocol_replay_is_deterministic(self):
        report = integration_lab.verify_protocol(
            REPO_ROOT,
            self.scenario,
        )
        self.assertEqual(13, report["route_count"])
        self.assertEqual(
            integration_lab.LOGICAL_ORIGIN,
            report["logical_origin"],
        )

    def test_android_listener_scenario_is_deterministic_without_host_server(
        self,
    ):
        directory, case, inputs = integration_lab.load_scenario(
            REPO_ROOT,
            self.listener_scenario,
        )
        self.assertEqual(
            [],
            integration_lab.validate_scenario(
                REPO_ROOT,
                directory,
                case,
            ),
        )
        self.assertEqual(
            integration_lab.TRANSPORT_ANDROID_LISTENER,
            case["transport"]["mode"],
        )
        self.assertEqual(10, len(inputs["cases"]))
        report = integration_lab.verify_protocol(
            REPO_ROOT,
            self.listener_scenario,
        )
        self.assertEqual(0, report["route_count"])
        self.assertEqual(10, report["case_count"])
        with self.assertRaises(integration_lab.IntegrationLabError):
            with integration_lab.running_server(
                REPO_ROOT,
                self.listener_scenario,
            ):
                pass


if __name__ == "__main__":
    unittest.main()
