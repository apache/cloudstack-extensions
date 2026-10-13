# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

"""Unit tests for vmnet.py, run with: python3 -m unittest test_vmnet.py"""

import json
import os
import tempfile
import unittest

import vmnet


class VmnetTest(unittest.TestCase):

    def run_command(self, command, data):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump(data, fh)
        try:
            return vmnet.execute(command, fh.name)
        finally:
            os.unlink(fh.name)

    def test_implements_l2_network_with_default_mode(self):
        output = self.run_command("implement-network", {
            "physical-network-extension-details": {},
            "payload": {"network_id": 42, "guest_type": "l2"},
        })
        self.assertEqual(output, {"network.broadcast_domain_type": "Vswitch",
                                  "network.broadcast_uri": "vs://cs-net-42?mode=nat"})

    def test_reads_registration_details_given_as_json_string(self):
        output = self.run_command("implement-network", {
            "physical-network-extension-details": json.dumps({"mode": "Internal", "name_prefix": "lab-"}),
            "payload": {"network_id": "7", "guest_type": "l2"},
        })
        self.assertEqual(output["network.broadcast_uri"], "vs://lab-7?mode=internal")

    def test_rejects_networks_with_cloudstack_managed_addresses(self):
        with self.assertRaisesRegex(vmnet.VmnetError, "only L2"):
            self.run_command("implement-network", {"payload": {"network_id": 1, "guest_type": "isolated"}})

    def test_rejects_invalid_settings(self):
        with self.assertRaisesRegex(vmnet.VmnetError, "Invalid mode"):
            vmnet.network_settings({"physical-network-extension-details": {"mode": "bridged"}})
        with self.assertRaisesRegex(vmnet.VmnetError, "Invalid name_prefix"):
            vmnet.network_settings({"physical-network-extension-details": {"name_prefix": "a_b"}})
        with self.assertRaisesRegex(vmnet.VmnetError, "network_id"):
            vmnet.network_name("cs-net-", "")

    def test_other_commands(self):
        self.assertEqual(self.run_command("ensure-network-device", {"payload": {}}), {})
        self.assertIsNone(self.run_command("destroy-network", {"payload": {"network_id": 1}}))
        self.assertIsNone(self.run_command("save-userdata", {"payload": {"network_id": 1}}))
        with self.assertRaisesRegex(vmnet.VmnetError, "Unsupported command"):
            vmnet.execute("custom-action", "/nonexistent")


if __name__ == "__main__":
    unittest.main()
