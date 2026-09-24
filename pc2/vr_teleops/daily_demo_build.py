#!/usr/bin/env python3
"""Fresh, report-only teleop installation; never launches a hardware service."""

import argparse
import datetime as dt
import fcntl
import json
import os
import platform
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


def atomic_json(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def clean_environment():
    # Keep the actual account/home, not a simulated demo home. Do not inherit
    # Conda, pip constraints, Python paths, or personal Git authentication.
    result = {k: os.environ[k] for k in ('HOME', 'USER', 'LOGNAME', 'LANG') if k in os.environ}
    result.update(PATH='/usr/local/bin:/usr/bin:/bin',
                  GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
                  GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/bin/false',
                  SSH_ASKPASS='/bin/false', PIP_CONFIG_FILE='/dev/null',
                  PYTHONNOUSERSITE='1', PIP_NO_INPUT='1',
                  TELEIMAGER_SKIP_UVC_RELOAD='1', CMAKE_BUILD_PARALLEL_LEVEL='2',
                  G1_TELEOP_BUILD_JOBS='2',
                  MAKEFLAGS='-j2', OPENBLAS_NUM_THREADS='1', OMP_NUM_THREADS='1')
    return result


def prune_workspaces(runs, keep, current):
    """Only delete build payloads in our marked run directories; retain reports."""
    candidates = sorted((p for p in runs.iterdir()
                         if re.fullmatch(r'\d{8}T\d{6}Z-[0-9a-f]{8}', p.name)
                         and not p.is_symlink() and p.is_dir()
                         and (p / '.teleop-ci-run').is_file()), reverse=True)
    for directory in candidates[keep:]:
        if directory == current:
            continue
        for name in ('work', 'checkout'):
            payload = directory / name
            if payload.is_dir() and not payload.is_symlink():
                shutil.rmtree(payload)


class Build:
    def __init__(self, directory, environment, deadline, report):
        self.directory = directory
        self.environment = environment
        self.deadline = deadline
        self.report = report

    def command(self, stage, args):
        self.report['stage'] = stage
        atomic_json(self.directory / 'summary.json', self.report)
        print(f'[{stage}] {self.directory / "build.log"}', flush=True)
        with (self.directory / 'build.log').open('a') as log:
            log.write('\nCOMMAND ' + json.dumps(args) + '\n')
            log.flush()
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                       env=self.environment, start_new_session=True)
            try:
                result = process.wait(timeout=max(0.1, self.deadline - time.monotonic()))
            except BaseException:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    pass
                raise
            if result:
                raise RuntimeError(f'{stage} exited with status {result}')

    def inventory(self):
        # Read-only best effort: inventory must never obscure the original error.
        repos = {}
        work = self.directory / 'work'
        for path in [self.directory / 'checkout'] + sorted(work.glob('*')):
            if (path / '.git').exists():
                try:
                    repos[path.name] = subprocess.check_output(
                        ['git', '-C', str(path), 'rev-parse', 'HEAD'],
                        env=self.environment, stderr=subprocess.DEVNULL,
                        timeout=10, text=True).strip()
                    if path.name == 'xr_teleoperate':
                        repos['xr_submodules'] = subprocess.check_output(
                            ['git', '-C', str(path), 'submodule', 'status', '--recursive'],
                            env=self.environment, stderr=subprocess.DEVNULL,
                            timeout=10, text=True).splitlines()
                except (subprocess.SubprocessError, OSError):
                    pass
        atomic_json(self.directory / 'revisions.json', repos)
        conda = work / 'miniforge3/bin/conda'
        python = work / 'miniforge3/envs/tv/bin/python'
        commands = {'conda-packages.json': [str(conda), 'list', '-n', 'tv', '--json'],
                    'pip-freeze.txt': [str(python), '-m', 'pip', 'freeze', '--all']}
        for filename, command in commands.items():
            if Path(command[0]).exists():
                try:
                    output = subprocess.check_output(command, env=self.environment,
                                                     stderr=subprocess.DEVNULL,
                                                     timeout=30, text=True)
                    (self.directory / filename).write_text(output)
                except (subprocess.SubprocessError, OSError):
                    pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default='https://github.com/MoissanClub/unitree_g1_dev.git')
    parser.add_argument('--ref', default='main', help='Launcher branch or tag to clone')
    parser.add_argument('--xr-url', default='https://github.com/MoissanClub/xr_teleoperate.git')
    parser.add_argument('--results-dir', type=Path,
                        default=Path.home() / '.local/state/teleop-ci')
    parser.add_argument('--timeout', type=int, default=14400, help='Build time limit in seconds')
    parser.add_argument('--keep-workspaces', type=int, default=2,
                        help='Retain this many builds; all small reports/logs remain')
    parser.add_argument('--dry-run', action='store_true', help='Print plan without downloads or writes')
    args = parser.parse_args(argv)
    if args.timeout < 1 or args.keep_workspaces < 1:
        parser.error('timeout and keep-workspaces must be positive')
    if args.dry_run:
        print(json.dumps({'repo': args.repo, 'ref': args.ref, 'xr_url': args.xr_url,
                          'results_dir': str(args.results_dir),
                          'setup': ['--user-only', '--software-only', '--workspace-root', '<new run>/work',
                                    '--no-pull', '--input-mode', 'hand', '--ee', 'brainco'],
                          'hardware_tests': False, 'promote_to_demo': False}, indent=2))
        return 0
    if os.geteuid() == 0:
        parser.error('Run as the dedicated unprivileged teleop-ci account, not root')
    os.umask(0o077)
    results = args.results_dir.expanduser().resolve()
    results.mkdir(parents=True, exist_ok=True)
    with (results / 'build.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Another daily build is still running.', file=sys.stderr)
            return 2
        stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        directory = results / 'runs' / f'{stamp}-{uuid.uuid4().hex[:8]}'
        directory.mkdir(parents=True)
        (directory / '.teleop-ci-run').touch()
        report = {'status': 'running', 'started_utc': stamp, 'stage': 'prepare',
                  'hardware_tested': False, 'promoted': False,
                  'platform': platform.platform(), 'python': platform.python_version(),
                  'repo': args.repo, 'ref': args.ref, 'xr_url': args.xr_url,
                  'run_directory': str(directory)}
        atomic_json(directory / 'summary.json', report)
        atomic_json(results / 'latest.json', report)
        environment = clean_environment()
        environment['G1_TELEOP_XR_URL'] = args.xr_url
        # Prevent inherited/user .condarc from selecting defaults or named env paths.
        condarc = directory / 'condarc'
        condarc.write_text('channels:\n  - conda-forge\nchannel_priority: strict\n')
        environment['CONDARC'] = str(condarc)
        build = Build(directory, environment, time.monotonic() + args.timeout, report)
        def interrupted(*_):
            raise InterruptedError('SIGTERM')

        old_handler = signal.signal(signal.SIGTERM, interrupted)
        try:
            # Bound disk use before the new payload is downloaded as well as afterwards.
            prune_workspaces(directory.parent, args.keep_workspaces, directory)
            checkout = directory / 'checkout'
            build.command('clone-launcher', ['git', 'clone', '--depth', '1', '--branch', args.ref,
                                            '--', args.repo, str(checkout)])
            scripts = checkout / 'pc2/vr_teleops'
            for script in sorted(scripts.glob('*.sh')):
                build.command('shell-syntax', ['bash', '-n', str(script)])
            build.command('setup', ['bash', str(scripts / 'setup_pc2_xr_teleop.sh'),
                                    '--user-only', '--software-only', '--workspace-root', str(directory / 'work'),
                                    '--no-pull', '--input-mode', 'hand', '--ee', 'brainco'])
            build.command('launcher-help', ['bash', str(scripts / 'demo.sh'), '--help'])
            report.update(status='passed', stage='complete')
        except (Exception, KeyboardInterrupt) as error:
            report.update(status='failed', error=str(error) or type(error).__name__)
            log_path = directory / 'build.log'
            if report['stage'] == 'setup' and log_path.exists():
                stages = re.findall(r'STAGE: ([a-z_]+)', log_path.read_text(errors='replace'))
                if stages:
                    report['setup_stage'] = stages[-1]
        finally:
            try:
                build.inventory()
            except Exception as error:
                report['inventory_error'] = str(error)
            report['finished_utc'] = dt.datetime.now(dt.timezone.utc).isoformat()
            atomic_json(directory / 'summary.json', report)
            atomic_json(results / 'latest.json', report)
            signal.signal(signal.SIGTERM, old_handler)
        print(json.dumps(report, indent=2), flush=True)
        return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
