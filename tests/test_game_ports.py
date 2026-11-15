"""Test the actual embedded allocation helper without Linux, Docker or a Panel."""
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

SOURCE = (Path(__file__).resolve().parents[1] / 'install.sh').read_text(encoding='utf-8')
CATALOG = re.search(r"game_port_catalog\(\).*?<<'PORTS'\n(.*?)\nPORTS", SOURCE, re.S)[1]
HELPER = SOURCE.split('configure_game_ports() {', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]


class GamePortsTests(unittest.TestCase):
    def generate(self, selection='all', requested='', preferred='eth0'):
        # Use the workspace to support the Windows sandbox as well as Linux CI.
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as temporary:
            folder = Path(temporary)
            catalog, interfaces, result = (folder / name for name in ('catalog', 'interfaces.json', 'ports.json'))
            catalog.write_text(CATALOG, encoding='utf-8')
            interfaces.write_text(json.dumps([
                {'ifname': 'docker0', 'addr_info': [{'local': '172.17.0.1'}]},
                {'ifname': 'eth0', 'addr_info': [{'local': '10.0.0.5'}]},
                {'ifname': 'eth1', 'addr_info': [{'local': '203.0.113.10'}]},
            ]))
            with patch.dict(os.environ, GAME_PORTS=selection, ALLOCATION_IP=requested), patch('sys.argv',
                    ['helper', str(catalog), str(interfaces), preferred, str(result)]):
                exec(compile(HELPER, 'allocation-helper', 'exec'), {})
            self.assertFalse((folder / 'ports.json.new').exists())
            return json.loads(result.read_text())

    def test_all_profiles_deduplicate_shared_ports(self):
        manifest = self.generate()
        self.assertEqual(manifest['allocation_ip'], '10.0.0.5')
        self.assertEqual(len(manifest['ports']), 45)
        for port in (25565, 27015, 19132, 28015, 30120, 2456, 7777, 34197, 16261):
            self.assertIn(port, manifest['ports'])
        self.assertGreater(len(manifest['games']['27015']), 1)
        for port in (3306, 3307, 2022, 8080, 25575, 40120):
            self.assertNotIn(port, manifest['ports'])

    def test_specific_profiles(self):
        self.assertEqual(self.generate('minecraft,source')['ports'], list(range(25565, 25575)) + list(range(27015, 27025)))

    def test_detects_address_on_default_interface(self):
        self.assertEqual(self.generate(preferred='eth1')['allocation_ip'], '203.0.113.10')

    def test_explicit_local_address(self):
        self.assertEqual(self.generate(requested='203.0.113.10')['allocation_ip'], '203.0.113.10')

    def test_unassigned_public_nat_address_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.generate(requested='198.51.100.20')


if __name__ == '__main__':
    unittest.main()
