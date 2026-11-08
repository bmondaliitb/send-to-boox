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
elif name == 'bluetoothctl':
    print('Device AA:BB:CC:DD:EE:FF My BOOX')
elif name == 'ip':
    print('192.168.44.1 dev ' + os.environ.get('BT_INTERFACE', 'bnep0') + ' src 192.168.44.2')
elif name == 'nmcli':
    if '-g' in args and args[args.index('-g') + 1].startswith('ipv4.never-default,'):
        print('\n'.join(['yes'] * 6)); sys.exit(0)
    if 'GENERAL.STATE' in args:
        print(os.environ.get('BT_STATE', 'deactivated')); sys.exit(0)
    if 'connection.type' in args:
        print('bluetooth'); sys.exit(0)
    if 'IP4.GATEWAY' in args:
        print(''); sys.exit(0)
    if 'DHCP4.OPTION' in args:
        print('broadcast_address = 192.168.44.255 | requested_routers = 1 | routers = 192.168.44.1 | subnet_mask = 255.255.255.0'); sys.exit(0)
    if 'GENERAL.DEVICES' in args:
        print('22:22:26:EF:88:F6'); sys.exit(0)
    if 'GENERAL.IP-IFACE' in args:
        print('bnep0'); sys.exit(0)
    if 'up' in args and os.environ.get('BT_FAIL') == '1':
        print('Bluetooth tethering unavailable'); sys.exit(1)
    print('home:802-11-wireless:Home' if '-t' in args else os.environ.get('ACTIVE', 'home'))
elif name == 'adb':
    if args[:4] == ['-d', 'shell', 'am', 'start']:
        if os.environ.get('TETHER_FAIL') == 'all' or (os.environ.get('TETHER_FAIL') == 'direct' and args[-1] == 'android.settings.TETHER_SETTINGS'):
            print('Error: Activity not started, unable to resolve Intent')
        else:
            print('Starting: Intent')
    elif args == ['mdns', 'services']:
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
        if os.environ.get('BT_OFFLINE') == '1' and not (root / 'disconnected').exists():
            print('offline'); sys.exit(1)
        if args[1].endswith(':9999'):
            print('error: device not found'); sys.exit(1)
        print('device')
    elif args[0] == 'disconnect':
        (root / 'disconnected').touch()
    elif 'getprop' in args:
        print('OTHER-SERIAL' if args[1].endswith(':38001') or (args[1] == '192.168.44.1:5555' and os.environ.get('BT_WRONG') == '1') else 'BOOX-SERIAL')
    elif args[:2] == ['-d', 'get-serialno']:
        print('BOOX-SERIAL')
    else:
        print('Success')
'''


class ConnectionFlow(unittest.TestCase):
    def run_flow(self, dialogs, *, usb=False, saved=None, send=False, mdns='', active='home', bt_fail=False, bt_wrong=False, bt_interface='bnep0', tether_fail='', bt_state='deactivated', bt_offline=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary = root / 'bin'
            binary.mkdir()
            mock = binary / 'mock'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ('zenity', 'adb', 'nmcli', 'bluetoothctl', 'ip'):
                (binary / name).symlink_to(mock)
            (root / 'dialogs').write_text(json.dumps(dialogs))
            config = root / 'send-to-boox' / 'wireless'
            if saved:
                config.parent.mkdir()
                config.write_text(saved)
            env = dict(os.environ, PATH=f'{binary}:' + os.environ['PATH'],
                       MOCK_ROOT=tmp, XDG_CONFIG_HOME=tmp, USB=str(int(usb)), MDNS=mdns, ACTIVE=active, BT_FAIL=str(int(bt_fail)),
                       BT_WRONG=str(int(bt_wrong)), BT_INTERFACE=bt_interface, TETHER_FAIL=tether_fail,
                       BT_STATE=bt_state, BT_OFFLINE=str(int(bt_offline)))
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

    def test_bluetooth_setup_guards_routes_and_dns_before_activation(self):
        config, calls = self.run_flow(['bluetooth', 'ready', 'AA:BB:CC:DD:EE:FF'], usb=True)
        self.assertTrue(config.endswith('192.168.44.1:5555\nBOOX-SERIAL\nbluetooth\n'))
        created = next(c[1] for c in calls if c[0] == 'nmcli' and 'add' in c[1])
        modified = next(c[1] for c in calls if c[0] == 'nmcli' and 'modify' in c[1])
        for args in (created, modified):
            for key in ('ipv4.never-default', 'ipv6.never-default',
                        'ipv4.ignore-auto-dns', 'ipv6.ignore-auto-dns',
                        'ipv4.ignore-auto-routes', 'ipv6.ignore-auto-routes'):
                self.assertEqual(args[args.index(key) + 1], 'yes')
        create_index = calls.index(['nmcli', created])
        up_index = next(i for i, c in enumerate(calls) if c[0] == 'nmcli' and 'up' in c[1])
        self.assertLess(create_index, up_index)
        self.assertIn(['ip', ['-4', 'route', 'get', '192.168.44.1']], calls)

    def test_open_tether_settings_then_finish_setup(self):
        config, calls = self.run_flow(['bluetooth', 'tether', 'ready', 'AA:BB:CC:DD:EE:FF'], usb=True)
        self.assertTrue(config.endswith('bluetooth\n'))
        self.assertIn(['adb', ['-d', 'shell', 'am', 'start', '-a', 'android.settings.TETHER_SETTINGS']], calls)
        self.assertFalse(any('android.settings.WIRELESS_SETTINGS' in str(c) for c in calls))

    def test_open_tether_settings_requires_authorized_usb(self):
        config, calls = self.run_flow(['bluetooth', 'tether', None, None])
        self.assertIsNone(config)
        self.assertFalse(any(c[0] == 'adb' and 'am' in c[1] for c in calls))
        self.assertTrue(any('Connect only your BOOX by USB' in str(c) for c in calls))

    def test_open_tether_settings_handles_missing_pages(self):
        saved = 'bt-profile\n192.168.44.1:5555\nBOOX-SERIAL\nbluetooth\n'
        for failure, message in [('direct', 'The direct tethering page is unavailable'),
                                 ('all', 'Could not open BOOX’s tethering or network settings')]:
            with self.subTest(failure=failure):
                config, calls = self.run_flow(['bluetooth', 'tether', None, None],
                                              usb=True, saved=saved, tether_fail=failure)
                self.assertEqual(config, saved)
                self.assertIn(['adb', ['-d', 'shell', 'am', 'start', '-a', 'android.settings.WIRELESS_SETTINGS']], calls)
                self.assertTrue(any(message in str(c) for c in calls))

    def test_bluetooth_reconnect_without_home_wifi(self):
        saved = 'bt-profile\n192.168.44.9:5555\nBOOX-SERIAL\nbluetooth\n'
        config, calls = self.run_flow([], saved=saved, send=True, active='elsewhere')
        self.assertEqual(config, saved.replace('44.9', '44.1'))
        self.assertNotIn(['adb', ['mdns', 'services']], calls)
        self.assertTrue(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))

    def test_bluetooth_active_link_is_not_restarted(self):
        saved = 'bt-profile\n192.168.44.1:5555\nBOOX-SERIAL\nbluetooth\n'
        _, calls = self.run_flow([], saved=saved, send=True, bt_state='activated', bt_fail=True)
        self.assertFalse(any(c[0] == 'nmcli' and 'up' in c[1] for c in calls))
        self.assertTrue(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))

    def test_bluetooth_offline_adb_is_reconnected(self):
        saved = 'bt-profile\n192.168.44.1:5555\nBOOX-SERIAL\nbluetooth\n'
        _, calls = self.run_flow([], saved=saved, send=True, bt_state='activated', bt_offline=True)
        self.assertIn(['adb', ['disconnect', '192.168.44.1:5555']], calls)
        self.assertIn(['adb', ['connect', '192.168.44.1:5555']], calls)
        self.assertTrue(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))

    def test_bluetooth_failure_cleans_profile_preserves_config(self):
        saved = 'home\n192.168.0.10:5555\nBOOX-SERIAL\n'
        config, calls = self.run_flow(['bluetooth', 'ready', 'AA:BB:CC:DD:EE:FF', None, None],
                                      usb=True, saved=saved, bt_fail=True)
        self.assertEqual(config, saved)
        self.assertTrue(any(c[0] == 'nmcli' and 'delete' in c[1] for c in calls))
        self.assertNotIn(['adb', ['-d', 'tcpip', '5555']], calls)

    def test_bluetooth_wrong_usb_identity_rejected(self):
        config, calls = self.run_flow(['bluetooth', 'ready', 'AA:BB:CC:DD:EE:FF', None, None],
                                      usb=True, bt_wrong=True)
        self.assertIsNone(config)
        self.assertTrue(any(c[0] == 'nmcli' and 'delete' in c[1] for c in calls))

    def test_bluetooth_wrong_route_never_contacts_endpoint(self):
        saved = 'bt-profile\n192.168.44.1:5555\nBOOX-SERIAL\nbluetooth\n'
        config, calls = self.run_flow([None], saved=saved, send=True, bt_interface='wlan0')
        self.assertEqual(config, saved)
        self.assertNotIn(['adb', ['connect', '192.168.44.1:5555']], calls)
        self.assertFalse(any(c[0] == 'adb' and 'https://example.com/article' in str(c[1]) for c in calls))

    def test_bluetooth_cancel_before_usb_does_not_create_profile(self):
        config, calls = self.run_flow(['bluetooth', 'ready', 'AA:BB:CC:DD:EE:FF', None, None])
        self.assertIsNone(config)
        self.assertFalse(any(c[0] == 'nmcli' and 'add' in c[1] for c in calls))


if __name__ == '__main__':
    unittest.main()
