"""Run with python3 -m unittest discover -s tests -v. No downloads or hardware."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('daily_demo_build', ROOT / 'daily_demo_build.py')
daily = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daily)


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def fixture_repo(self, fail=False):
        repo = self.root / 'repo'
        scripts = repo / 'pc2/vr_teleops'
        scripts.mkdir(parents=True)
        # Exercise the runner orchestration against a real local Git clone.
        body = 'printf "STAGE: prepare_xr_sources\\n"\n'
        if fail:
            body += 'echo "missing submodule" >&2\nexit 7\n'
        else:
            body += '[[ "$*" == *--software-only* && "$*" == *--user-only* ]]\n'
            body += '[[ -z "${PIP_CONSTRAINT:-}" && "$GIT_TERMINAL_PROMPT" == 0 ]]\n'
        (scripts / 'setup_pc2_xr_teleop.sh').write_text('#!/bin/bash\nset -e\n' + body)
        (scripts / 'demo.sh').write_text('#!/bin/bash\n[[ "$1" == --help ]]\n')
        environment = daily.clean_environment()
        for args in (['init', '-b', 'main'], ['add', '.'],
                     ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                      '-c', 'commit.gpgsign=false', 'commit', '-m', 'fixture']):
            subprocess.run(['git', '-C', str(repo)] + args, env=environment,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
        return repo

    def run_fixture(self, fail=False):
        repo = self.fixture_repo(fail)
        results = self.root / 'results'
        with patch.object(daily.os, 'geteuid', return_value=1000), contextlib.redirect_stdout(io.StringIO()):
            result = daily.main(['--repo', str(repo), '--results-dir', str(results)])
        return result, json.loads((results / 'latest.json').read_text())

    def test_fresh_build_reports_success_and_versions(self):
        with patch.dict(os.environ, {'PIP_CONSTRAINT': '/missing/user-file'}):
            result, report = self.run_fixture()
        self.assertEqual(result, 0)
        self.assertEqual(report['status'], 'passed')
        self.assertFalse(report['hardware_tested'])
        self.assertFalse(report['promoted'])
        revisions = json.loads((Path(report['run_directory']) / 'revisions.json').read_text())
        self.assertEqual(len(revisions['checkout']), 40)

    def test_failure_is_nonzero_and_names_setup_stage(self):
        result, report = self.run_fixture(fail=True)
        self.assertEqual(result, 1)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['setup_stage'], 'prepare_xr_sources')
        self.assertIn('status 7', report['error'])

    def test_timeout_terminates_command(self):
        build = daily.Build(self.root, daily.clean_environment(), time.monotonic() + 0.15, {})
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(subprocess.TimeoutExpired):
            build.command('timeout-test', ['bash', '-c', 'sleep 20'])

    def test_overlapping_run_is_rejected(self):
        results = self.root / 'results'
        results.mkdir()
        with (results / 'build.lock').open('w') as lock:
            daily.fcntl.flock(lock, daily.fcntl.LOCK_EX | daily.fcntl.LOCK_NB)
            with patch.object(daily.os, 'geteuid', return_value=1000), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(daily.main(['--results-dir', str(results)]), 2)
        self.assertFalse((results / 'runs').exists())

    def test_retention_keeps_reports_and_does_not_follow_symlinks(self):
        old = self.root / '20260101T000000Z-aaaaaaaa'
        current = self.root / '20260102T000000Z-bbbbbbbb'
        for path in (old, current):
            path.mkdir()
            (path / '.teleop-ci-run').touch()
            (path / 'work').mkdir()
            (path / 'summary.json').write_text('{}')
        outside = self.root / 'unrelated'
        outside.mkdir()
        (outside / 'keep').touch()
        (old / 'checkout').symlink_to(outside, target_is_directory=True)
        daily.prune_workspaces(self.root, 1, current)
        self.assertFalse((old / 'work').exists())
        self.assertTrue((old / 'summary.json').exists())
        self.assertTrue((current / 'work').exists())
        self.assertTrue((outside / 'keep').exists())

    def setup_functions(self, tail):
        source = (ROOT / 'setup_pc2_xr_teleop.sh').read_text().rsplit('main "$@"', 1)[0]
        source = source.replace('SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
                                f'SCRIPT_DIR="{ROOT}"', 1)
        script = self.root / 'check.sh'
        script.write_text(source + '\n' + tail)
        return subprocess.run(['bash', str(script)], text=True, capture_output=True,
                              env={**os.environ, 'TEST_ROOT': str(self.root)}, timeout=10)

    def test_software_config_does_not_probe_hardware_or_modify_live_config(self):
        result = self.setup_functions('''
SOFTWARE_ONLY=1
USER_ONLY=1
CONFIG_DIR="$TEST_ROOT/config"
DDS_IFACE=lo
WIFI_IFACE=lo
CAMERA_BACKEND=opencv
detect_realsense_video_id() { echo 'unexpected camera probe' >&2; exit 80; }
detect_realsense_serial() { echo 'unexpected USB probe' >&2; exit 81; }
prepare_cyclonedds_home() { printf '%s' "$TEST_ROOT/dds"; }
iface_ipv4() { printf '127.0.0.1'; }
ensure_camera_access
configure_teleimager
write_runtime_config
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('G1_TELEOP_PRIVILEGE_MODE="user"',
                      (self.root / 'config/pc2_teleop.env').read_text())

    def test_incomplete_submodule_fails_before_pip(self):
        result = self.setup_functions('''
XR_REPO_DIR="$TEST_ROOT/xr"
mkdir -p "$XR_REPO_DIR/teleop/televuer"
ensure_repo() { :; }
prepare_xr_sources
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Missing Python project files', result.stderr)


if __name__ == '__main__':
    unittest.main()
