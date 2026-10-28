"""Exercise the graphical workflow using scripted dialog and ADB responses."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'send-to-boox.sh'
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as f:
    f.write(json.dumps([name, args]) + '\n')
if name == 'zenity':
    if '--progress' in args:
        sys.stdin.read()
        sys.exit(0)
    if '--info' in args or '--error' in args:
        sys.exit(0)
    q = json.loads((root / 'dialogs').read_text())
    if not q:
        sys.exit(1)
    answer = q.pop(0)
    (root / 'dialogs').write_text(json.dumps(q))
    if answer is None:
        sys.exit(1)
    print(answer)
elif name == 'nmcli':
    print('home:802-11-wireless:Home' if '-t' in args else os.environ.get('ACTIVE', 'home'))
elif name == 'adb':
    if args == ['mdns', 'services']:
        print(os.environ.get('MDNS', ''))
    elif args[:2] == ['-d', 'get-state']:
        print('device' if os.environ.get('USB') == '1' else 'error: no devices')
        sys.exit(0 if os.environ.get('USB') == '1' else 1)
    elif args[:2] == ['-d', 'tcpip']:
        print('restarting in TCP mode')
    elif args[:3] == ['-d', 'shell', 'ip']:
        print('wlan0 inet 192.168.0.10/24')
    elif args[0] == 'pair':
        code = sys.stdin.read().strip()
        if code != '123456':
            print('Failed'); sys.exit(1)
        print('Successfully paired')
    elif args[0] == 'connect':
        print('connected')
    elif args[0] == '-s' and args[2] == 'get-state':
        if args[1].endswith(':9999'):
            print('error: device not found'); sys.exit(1)
        print('device')
    elif 'getprop' in args:
        print('OTHER-SERIAL' if args[1].endswith(':38001') else 'BOOX-SERIAL')
    elif args[:2] == ['-d', 'get-serialno']:
        print('BOOX-SERIAL')
    else:
        print('Success')
'''


class ConnectionFlow(unittest.TestCase):
    def run_flow(self, dialogs, *, usb=False, saved=None, send=False, mdns='', active='home'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / 'bin'
            binary.mkdir()
            mock = binary / 'mock'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ('zenity', 'adb', 'nmcli'):
                (binary / name).symlink_to(mock)
            (root / 'dialogs').write_text(json.dumps(dialogs))
            config = root / 'send-to-boox' / 'wireless'
            if saved:
                config.parent.mkdir()
                config.write_text(saved)
            env = dict(os.environ, PATH=f'{binary}:' + os.environ['PATH'],
                       MOCK_ROOT=tmp, XDG_CONFIG_HOME=tmp, USB=str(int(usb)), MDNS=mdns, ACTIVE=active)
            args = ['https://example.com/article'] if send else ['--setup-wireless']
            result = subprocess.run(['bash', str(SCRIPT), *args], env=env,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
            return config.read_text() if config.exists() else None, calls

    def test_usb_setup_detects_ip_and_saves_identity(self):
        config, calls = self.run_flow(['home', 'usb', '192.168.0.10'], usb=True)
        self.assertEqual(config, 'home\n192.168.0.10:5555\nBOOX-SERIAL\n')
        self.assertIn(['adb', ['-d', 'tcpip', '5555']], calls)

    def test_pairing_uses_separate_connection_port(self):
        config, calls = self.run_flow(['home', 'pair', '192.168.0.10:37000',
                                       '123456', '192.168.0.10:38000'])
        self.assertIn(':38000\n', config)
        self.assertIn(['adb', ['pair', '192.168.0.10:37000']], calls)
        self.assertFalse(any('123456' in str(c) for c in calls))

    def test_invalid_address_and_refused_connection_retry(self):
        config, _ = self.run_flow(['home', 'reconnect', '999.1.1.1:5555',
                                   '192.168.0.10:9999', 'retry', '192.168.0.10:5555'])
        self.assertIn(':5555\n', config)

    def test_cancel_preserves_saved_settings(self):
        saved = 'home\n192.168.0.10:5555\nBOOX-SERIAL\n'
        config, _ = self.run_flow(['home', 'pair', None, None], saved=saved)
        self.assertEqual(config, saved)

    def test_missing_usb_can_return_to_pairing(self):
        config, _ = self.run_flow(['home', 'usb', 'back', 'pair',
                                   '192.168.0.10:37000', '123456', '192.168.0.10:38000'])
        self.assertIn(':38000\n', config)

    def test_send_resumes_after_wizard(self):
        _, calls = self.run_flow(['setup', 'home', 'reconnect', '192.168.0.10:38000'], send=True)
        self.assertTrue(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))

    def test_wrong_device_never_receives_pending_url(self):
        _, calls = self.run_flow([None], saved='home\n192.168.0.10:5555\nWRONG\n', send=True)
        self.assertFalse(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))

    def test_discovers_changed_address_and_persists_it(self):
        saved = 'home\n192.168.0.10:9999\nBOOX-SERIAL\n'
        mdns = 'adb-boox _adb-tls-connect._tcp. 192.168.0.20:38000'
        config, calls = self.run_flow([], saved=saved, send=True, mdns=mdns)
        self.assertEqual(config, 'home\n192.168.0.20:38000\nBOOX-SERIAL\n')
        self.assertTrue(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))
        self.assertFalse(any(c[0] == 'zenity' and '--list' in c[1] for c in calls))

    def test_discovery_skips_other_devices_and_pairing_ports(self):
        mdns = ('other _adb-tls-connect._tcp 192.168.0.20:38001\n'
                'pair _adb-tls-pairing._tcp 192.168.0.20:37000\n'
                'boox _adb-tls-connect._tcp 192.168.0.20:38000')
        config, calls = self.run_flow([], saved='home\n192.168.0.10:9999\nBOOX-SERIAL\n',
                                      send=True, mdns=mdns)
        self.assertIn(':38000\n', config)
        self.assertNotIn(['adb', ['connect', '192.168.0.20:37000']], calls)
        sends = [c for c in calls if c[0] == 'adb' and 'https://example.com/article' in str(c[1])]
        self.assertEqual(sends[0][1][1], '192.168.0.20:38000')

    def test_no_discovery_outside_saved_network(self):
        saved = 'home\n192.168.0.10:9999\nBOOX-SERIAL\n'
        config, calls = self.run_flow([None], saved=saved, send=True, active='elsewhere',
                                      mdns='boox _adb-tls-connect._tcp 192.168.0.20:38000')
        self.assertEqual(config, saved)
        self.assertNotIn(['adb', ['mdns', 'services']], calls)

    def test_wizard_reconnect_remembers_device(self):
        config, _ = self.run_flow(['home', 'reconnect'],
                                  saved='home\n192.168.0.10:9999\nBOOX-SERIAL\n',
                                  mdns='boox _adb-tls-connect._tcp 192.168.0.20:38000')
        self.assertIn('192.168.0.20:38000', config)


if __name__ == '__main__':
    unittest.main()
