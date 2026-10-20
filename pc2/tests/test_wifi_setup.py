"""Host-side regression tests; all networking/system commands use test doubles.

Run with: python3 -m unittest discover -s pc2/tests -v
This checks script behavior, not NetworkManager or Jetson compatibility.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "g1_pc2_wifi_setup.sh"
FAKE_COMMAND = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import uuid

state_path = Path(os.environ["WIFI_TEST_STATE"])
state = json.loads(state_path.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
state["calls"].append([command, *args])

def finish(code=0, output=""):
    state_path.write_text(json.dumps(state))
    if output:
        print(output)
    sys.exit(code)

if command == "nmcli":
    if args[:2] == ["general", "status"]:
        finish()
    if args[:2] == ["--wait", "45"]:
        args = args[2:]
    if args[:5] == ["-g", "connection.uuid", "connection", "show", "id"]:
        if state.get("lookup_error"):
            finish(state["lookup_error"])
        matches = [u for u, p in state["profiles"].items() if p["connection.id"] == args[5]]
        finish(0 if matches else 10, "\n\n".join(matches))
    if args[:5] == ["-g", "connection.type", "connection", "show", "uuid"]:
        finish(output=state["profiles"][args[5]]["connection.type"])
    if args[:2] == ["connection", "add"]:
        values = dict(zip(args[2::2], args[3::2]))
        state["profiles"][str(uuid.uuid4())] = {
            "connection.id": values["con-name"],
            "connection.type": "802-11-wireless",
            "802-11-wireless.ssid": values["ssid"],
        }
        finish()
    if args[:2] in (["connection", "modify"], ["connection", "up"], ["connection", "delete"]):
        # Reject ambiguous name-based writes/activation, even with a single match.
        if args[2] != "uuid" or args[3] not in state["profiles"]:
            finish(2)
        if args[1] == "modify":
            state["profiles"][args[3]].update(zip(args[4::2], args[5::2]))
        elif args[1] == "delete":
            del state["profiles"][args[3]]
        else:
            state["active"] = args[3]
        finish()
    if args[:2] == ["-t", "-f"] and args[2:] == ["DEVICE,TYPE", "device", "status"]:
        finish(output="wlan0:wifi")
    if args[:2] in (["radio", "wifi"], ["device", "set"], ["device", "wifi"]):
        finish()
    if args[:1] == ["-f"] and args[2:4] in (["device", "show"], ["device", "wifi"]):
        finish()
    # In particular, -f NAME connection show <name> is invalid.
    finish(2)
elif command == "systemctl":
    if args[0] == "is-enabled":
        finish(0 if args[-1] in state["enabled"] else 1)
    if args[0] == "disable":
        state["enabled"].remove(args[-1])
        finish()
    if args[0] == "enable":
        state["enabled"].append(args[-1])
        finish()
    if args[0] == "daemon-reload":
        finish()
    finish(2)
elif command == "ip":
    if args[:4] == ["-4", "-o", "addr", "show"]:
        finish(output="3: wlan0 inet 10.10.20.164/24")
    if args[:1] in (["link"], ["route"]):
        finish()
    finish(2)
elif command in ("rfkill", "ping", "getent"):
    finish()
else:
    finish(2)
'''


class WifiSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state_path = self.root / "state.json"
        self.write_state({"profiles": {}, "enabled": [], "calls": []})
        self.service_path = self.root / "g1-pc2-wifi.service"

        # Adapt only privilege and systemd filesystem boundaries for macOS.
        # The script's argument parsing, functions and main flow run unchanged.
        source = SCRIPT.read_text()
        replacements = {
            'if [[ "$EUID" -ne 0 ]]; then': 'if false; then',
            '/run/systemd/system': str(self.root),
            '/etc/systemd/system/g1-pc2-wifi.service': str(self.service_path),
        }
        for old, new in replacements.items():
            self.assertIn(old, source)
            source = source.replace(old, new)
        self.script = self.root / SCRIPT.name
        self.script.write_text(source)

        fake = self.root / "fake_command.py"
        fake.write_text(FAKE_COMMAND)
        fake.chmod(0o755)
        for command in ("nmcli", "systemctl", "rfkill", "ip", "ping", "getent"):
            (self.root / command).symlink_to(fake)
        self.env = dict(os.environ, WIFI_TEST_STATE=str(self.state_path),
                        PATH=f"{self.root}:{os.environ['PATH']}")

    def state(self):
        return json.loads(self.state_path.read_text())

    def write_state(self, state):
        self.state_path.write_text(json.dumps(state))

    def setup_wifi(self, ssid="LabWiFi", *options, success=True):
        args = ["bash", str(self.script), "--yes"]
        if ssid:
            args += ["--ssid", ssid]
        if "--open" not in options and "--scan-only" not in options:
            args += ["--password", "test-password"]
        result = subprocess.run(args + list(options), env=self.env, text=True,
                                capture_output=True, timeout=20)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_repeated_setup_reuses_uuid_and_keeps_other_networks(self):
        # Exercise quoting without interpreting SSID text as shell syntax.
        ssid = 'Lab: "G1" \\ guest $(false)'
        self.setup_wifi(ssid, "--hidden", "--ip", "10.10.20.164/24", "--gateway", "10.10.20.1")
        first_uuid = self.state()["active"]
        self.setup_wifi("HomeWiFi")
        self.setup_wifi(ssid)
        state = self.state()
        self.assertEqual(len(state["profiles"]), 2)
        self.assertEqual(state["active"], first_uuid)
        profile = state["profiles"][first_uuid]
        self.assertEqual(profile["connection.id"], ssid)
        self.assertEqual(profile["802-11-wireless.ssid"], ssid)
        self.assertEqual(profile["connection.autoconnect"], "yes")
        self.assertEqual(profile["802-11-wireless-security.psk-flags"], "0")
        self.assertEqual(profile["802-11-wireless.hidden"], "no")
        self.assertEqual(profile["ipv4.method"], "auto")
        self.assertEqual(profile["ipv4.addresses"], "")
        self.assertFalse(self.service_path.exists())

    def test_explicit_name_is_reused(self):
        for _ in range(2):
            self.setup_wifi("LabWiFi", "--connection-name", "custom-profile")
        profiles = list(self.state()["profiles"].values())
        self.assertEqual(len(profiles), 1)
        self.assertEqual(profiles[0]["connection.id"], "custom-profile")

    def test_ambiguous_name_fails_without_changing_profiles(self):
        self.setup_wifi()
        state = self.state()
        profile = next(iter(state["profiles"].values()))
        state["profiles"]["00000000-0000-4000-8000-000000000001"] = profile.copy()
        self.write_state(state)
        result = self.setup_wifi(success=False)
        self.assertIn("Multiple profiles", result.stderr)
        self.assertEqual(self.state()["profiles"], state["profiles"])

    def test_lookup_failure_does_not_create_profile(self):
        for error in (1, 2, 8):
            with self.subTest(error=error):
                state = self.state()
                state["lookup_error"] = error
                self.write_state(state)
                self.setup_wifi(success=False)
                self.assertEqual(self.state()["profiles"], {})

    def test_non_wifi_name_collision_is_rejected(self):
        self.setup_wifi()
        state = self.state()
        state["profiles"][state["active"]]["connection.type"] = "802-3-ethernet"
        self.write_state(state)
        result = self.setup_wifi(success=False)
        self.assertIn("not Wi-Fi", result.stderr)
        self.assertEqual(self.state()["profiles"], state["profiles"])

    def test_default_disables_legacy_service_and_enable_nm_flag_works(self):
        state = self.state()
        state["enabled"] = ["g1-pc2-wifi.service"]
        self.write_state(state)
        self.setup_wifi("LabWiFi", "--enable-networkmanager-at-boot")
        self.assertEqual(self.state()["enabled"], ["NetworkManager.service"])
        self.assertFalse(self.service_path.exists())

    def test_opt_in_service_only_enables_radio(self):
        self.setup_wifi("LabWiFi", "--boot-service")
        service = self.service_path.read_text()
        self.assertIn("radio wifi on", service)
        self.assertIn("unblock wlan", service)
        self.assertNotIn("connection up", service)
        self.assertNotIn("LabWiFi", service)
        self.assertIn("g1-pc2-wifi.service", self.state()["enabled"])
        self.setup_wifi("LabWiFi", "--no-boot-service")
        self.assertNotIn("g1-pc2-wifi.service", self.state()["enabled"])

    def test_dry_run_does_not_activate_or_modify_existing_state(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    self.setup_wifi()
                before = self.state()
                before["enabled"] = ["g1-pc2-wifi.service"]
                self.write_state(before)
                self.setup_wifi("LabWiFi", "--dry-run")
                after = self.state()
                calls = after.pop("calls")[len(before.pop("calls")):]
                self.assertEqual(after, before)
                self.assertFalse(any("up" in call or "modify" in call or "disable" in call
                                     for call in calls))

    def test_open_network_replaces_security_without_leaving_duplicates(self):
        self.setup_wifi()
        self.setup_wifi("LabWiFi", "--open")
        profiles = list(self.state()["profiles"].values())
        self.assertEqual(len(profiles), 1)
        self.assertNotIn("802-11-wireless-security.psk", profiles[0])

    def test_scan_only_does_not_change_profiles_or_boot_service(self):
        state = self.state()
        state["enabled"] = ["g1-pc2-wifi.service"]
        self.write_state(state)
        self.setup_wifi("", "--scan-only")
        self.assertEqual(self.state()["profiles"], {})
        self.assertEqual(self.state()["enabled"], state["enabled"])


if __name__ == "__main__":
    unittest.main()
