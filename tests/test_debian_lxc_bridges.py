"""Regression checks for bridge discovery; never contact a Proxmox host."""
import json
import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/proxmox-debian-lxc-create.sh'


class BridgeDiscoveryTests(unittest.TestCase):
    def discover(self, response, fail=False):
        env = dict(os.environ, TEST_NETWORK=response, TEST_API_FAIL=str(int(fail)))
        code = '''source "$1"
pvesh() {
    [[ "$1" == get && "$2" == /nodes/*/network && "$3" == --type && "$4" == bridge && "$5" == --output-format && "$6" == json ]] || return 90
    [[ "$TEST_API_FAIL" == 0 ]] || return 2
    printf '%s' "$TEST_NETWORK"
}
configured_linux_bridges
'''
        return subprocess.run(['bash', '-c', code, '--', str(SCRIPT)], env=env,
                              text=True, capture_output=True)

    def test_reported_runtime_bridges_are_hidden(self):
        names = ['docker0', 'fwbr200i0', 'fwbr210i0', 'fwbr211i0',
                 'fwbr212i0', 'fwbr214i0', 'fwbr239i0', 'fwbr241i0',
                 'fwbr241i1', 'br-aabbcc', 'vmbr0', 'vmbr1']
        result = self.discover(json.dumps([
            {'iface': name, 'type': 'bridge', 'active': 1} for name in names]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['vmbr0', 'vmbr1'])

    def test_custom_names_natural_order_and_inactive_filter(self):
        data = [{'iface': name, 'type': 'bridge', 'active': 1}
                for name in ['vmbr10', 'labnet', 'vmbr2', 'vmbr2']]
        data += [{'iface': 'vmbr3', 'type': 'bridge', 'active': 0},
                 {'iface': 'eno1', 'type': 'eth', 'active': 1},
                 {'iface': 'ovsbr0', 'type': 'OVSBridge', 'active': 1},
                 {'iface': 'not a bridge', 'type': 'bridge', 'active': 1}]
        result = self.discover(json.dumps(data))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['labnet', 'vmbr2', 'vmbr10'])

    def test_api_failure_does_not_fall_back_to_runtime_interfaces(self):
        result = self.discover('[]', fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not read Proxmox network configuration', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_invalid_json_and_wrong_response_shape_fail(self):
        for data in ['bad-json', '{}']:
            with self.subTest(data=data):
                result = self.discover(data)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_no_active_bridge_produces_no_choices(self):
        result = self.discover('[{"iface":"vmbr0","type":"bridge","active":0}]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
