#!/usr/bin/env python3
"""Manual build -> freeze -> supervised trial -> explicit promotion/rollback."""
import argparse
import contextlib
import datetime as dt
import fcntl
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import stat
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ID_PATTERN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z')


def write_json(path, value):
    tmp = path.with_name(path.name + '.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.chmod(0o644)
    tmp.replace(path)


def read_json(path):
    return json.loads(path.read_text())


def release_dir(root, identifier):
    if not ID_PATTERN.fullmatch(identifier) or identifier in ('.', '..'):
        raise ValueError('Invalid release ID')
    path = root / 'releases' / identifier
    if path.is_symlink():
        raise ValueError('Release directory must not be a symlink')
    return path


@contextlib.contextmanager
def session_lock(root):
    # Read-only open: operators may lock it but cannot replace/truncate it.
    with (root / 'session.lock').open('rb') as file:
        try:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('A deployment operation or teleoperation session is active. Stop it first.')
        yield file


def walk_payload(payload):
    if payload.is_symlink() or not payload.is_dir():
        raise ValueError('Missing or symlinked payload')
    yield payload
    for parent, directories, files in os.walk(payload, followlinks=False):
        for name in sorted(directories + files):
            yield Path(parent) / name


def digest_payload(payload):
    digest = hashlib.sha256()
    for path in sorted(walk_payload(payload)):
        relative = str(path.relative_to(payload))
        info = path.lstat()
        digest.update(relative.encode() + b'\0')
        if stat.S_ISLNK(info.st_mode):
            digest.update(b'link\0' + os.readlink(path).encode())
        elif stat.S_ISREG(info.st_mode):
            digest.update(b'file\0')
            with path.open('rb') as file:
                for block in iter(lambda: file.read(1024 * 1024), b''):
                    digest.update(block)
        elif stat.S_ISDIR(info.st_mode):
            digest.update(b'dir\0')
        else:
            raise ValueError(f'Unexpected special file in release: {relative}')
        digest.update(b'\0')
    return digest.hexdigest()


def freeze_payload(payload, gid):
    # Do not chown a Conda hardlink that also exists outside this payload.
    paths = list(walk_payload(payload))
    links = {}
    for path in paths:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            target = path.resolve()
            if payload.resolve() not in target.parents and target != payload.resolve():
                # ROS/system library links are external dependencies; account-owned
                # source/cache links would violate exact-build promotion.
                if not any(target == Path(p) or Path(p) in target.parents
                           for p in ('/usr', '/lib', '/lib64', '/opt/ros', '/etc/alternatives')):
                    raise ValueError(f'Symlink points outside release/system libraries: {path} -> {target}')
        if stat.S_ISREG(info.st_mode):
            key = (info.st_dev, info.st_ino)
            links[key] = links.get(key, 0) + 1
    for path in paths:
        info = path.lstat()
        if stat.S_ISREG(info.st_mode) and links[(info.st_dev, info.st_ino)] != info.st_nlink:
            raise ValueError(f'Hardlink extends outside release: {path}')
    # Symlinks are preserved, never dereferenced for ownership/mode changes.
    for path in reversed(paths):
        info = path.lstat()
        os.chown(path, 0, gid, follow_symlinks=False)
        if not stat.S_ISLNK(info.st_mode):
            path.chmod(0o550 if stat.S_ISDIR(info.st_mode) or info.st_mode & 0o111 else 0o440)


def assert_frozen(payload):
    for path in walk_payload(payload):
        info = path.lstat()
        if info.st_uid != 0 or (not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o222):
            raise ValueError(f'Release is not frozen: {path}')


def require_root():
    if os.geteuid() != 0:
        raise PermissionError('Run this administrator operation using sudo.')


def check_legacy_sessions():
    result = subprocess.run(
        ['pgrep', '-f', r'(^|/)(brainco_hand_server|start_brainco_hand_server\.sh|teleimager-server|start_teleimager\.sh|teleop_hand_and_arm\.py)( |$)'],
        stdout=subprocess.PIPE, text=True)
    if result.returncode == 0:
        raise RuntimeError('Existing hand/camera/XR processes must be stopped by their owner first: ' + result.stdout.strip())
    if result.returncode != 1:
        raise RuntimeError('Could not check existing teleoperation processes')


def initialize(args, root):
    require_root()
    if (root / 'deployment.json').exists():
        raise ValueError('Deployment already initialized; do not reset its selection state.')
    for name in (args.builder, args.demo):
        account = pwd.getpwnam(name)
        if account.pw_uid == 0:
            raise ValueError('Builder and demo must be non-root accounts')
    if args.builder == args.demo:
        raise ValueError('Use separate builder and demo accounts')
    try:
        group = grp.getgrnam('teleops-releases')
    except KeyError:
        subprocess.run(['groupadd', '--system', 'teleops-releases'], check=True)
        group = grp.getgrnam('teleops-releases')
    for name in (args.builder, args.demo):
        subprocess.run(['usermod', '-aG', group.gr_name, name], check=True)
    root.mkdir(parents=True, exist_ok=True)
    if root.stat().st_uid != 0 or root.stat().st_mode & 0o022:
        raise ValueError('Deployment root must be administrator-owned and not group/world writable')
    root.chmod(0o755)
    for name in ('bin', 'releases'):
        (root / name).mkdir(exist_ok=True)
        (root / name).chmod(0o755)
    # Install trusted orchestration before executing anything from a build.
    for name in ('deployment.py', 'build_worker.sh'):
        shutil.copyfile(HERE / name, root / 'bin' / name)
        (root / 'bin' / name).chmod(0o755)
    (root / 'session.lock').touch()
    (root / 'session.lock').chmod(0o644)
    write_json(root / 'deployment.json', {'builder': args.builder, 'demo': args.demo,
                                         'group': group.gr_name})
    write_json(root / 'selection.json', {'candidate': None, 'current': None, 'previous': None})
    print('Initialized. Log both operator accounts out and back in to activate group membership.')


def build(args, root, settings):
    require_root()
    release = release_dir(root, args.id)
    release.mkdir()  # Never reuse or delete an existing release.
    release.chmod(0o755)
    payload = release / 'payload'
    payload.mkdir()
    builder = pwd.getpwnam(settings['builder'])
    os.chown(payload, builder.pw_uid, builder.pw_gid)
    shutil.copyfile(Path(args.hardware_profile).resolve(), payload / 'hardware.env')
    (payload / 'hardware.env').chmod(0o644)
    metadata = {'id': args.id, 'status': 'building', 'repo': args.repo, 'ref': args.ref,
                'xr_url': args.xr_url, 'built_at': dt.datetime.now(dt.timezone.utc).isoformat()}
    write_json(release / 'release.json', metadata)
    print(f'Building {args.id} as {settings["builder"]}. Log: {release / "build.log"}', flush=True)
    # runuser supplies the real target user's HOME; no synthetic HOME or root builds.
    command = ['runuser', '-u', settings['builder'], '--', 'bash', str(root / 'bin/build_worker.sh'),
               str(payload), args.repo, args.ref, args.xr_url]
    try:
        with (release / 'build.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        metadata['status'] = 'built'
    except BaseException:
        metadata['status'] = 'failed'
        raise
    finally:
        write_json(release / 'release.json', metadata)
    print(f'Build passed. Next: freeze {args.id}. No candidate/current selection changed.')


def freeze(args, root, settings):
    require_root()
    release = release_dir(root, args.id)
    metadata = read_json(release / 'release.json')
    if metadata['status'] != 'built':
        raise ValueError('Only a successful, unfrozen build can be frozen')
    freeze_payload(release / 'payload', grp.getgrnam(settings['group']).gr_gid)
    metadata.update(status='frozen', digest=digest_payload(release / 'payload'))
    write_json(release / 'release.json', metadata)
    selection = read_json(root / 'selection.json')
    selection['candidate'] = args.id
    write_json(root / 'selection.json', selection)
    print(f'Frozen candidate {args.id}. Test as {settings["builder"]} before promotion.')


def verify_release(root, identifier):
    release = release_dir(root, identifier)
    metadata = read_json(release / 'release.json')
    if metadata['status'] != 'frozen':
        raise ValueError('Release must be frozen')
    assert_frozen(release / 'payload')
    if digest_payload(release / 'payload') != metadata['digest']:
        raise ValueError('Release content changed after freeze; build and test a new candidate')
    return release, metadata


def promote(args, root):
    require_root()
    selection = read_json(root / 'selection.json')
    if selection['candidate'] != args.id:
        raise ValueError('Only the selected candidate can be promoted')
    if not args.accept_tested:
        raise ValueError('After your supervised trial, explicitly pass --accept-tested')
    release, metadata = verify_release(root, args.id)
    if selection['current'] == args.id:
        raise ValueError('Already current')
    selection.update(previous=selection['current'], current=args.id)
    selection['accepted_by'] = os.environ.get('SUDO_USER', 'root')
    selection['accepted_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
    selection['accepted_digest'] = metadata['digest']
    write_json(root / 'selection.json', selection)
    print(f'Promoted {args.id}. Now perform a supervised acceptance test as demo.')


def rollback(root):
    require_root()
    selection = read_json(root / 'selection.json')
    identifier = selection['previous']
    if not identifier:
        raise ValueError('No previous release exists')
    verify_release(root, identifier)
    selection['current'], selection['previous'] = identifier, selection['current']
    selection['rolled_back_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
    write_json(root / 'selection.json', selection)
    print(f'Rolled back to {identifier}. Start a new demo session to use it.')


def launch(args, root, settings, lock, extra):
    if os.geteuid() == 0:
        raise PermissionError('Launch as the operator account, not root')
    role = 'candidate' if args.candidate else 'current'
    expected = settings['builder'] if args.candidate else settings['demo']
    if pwd.getpwuid(os.getuid()).pw_name != expected:
        raise PermissionError(f'Run {role} as {expected}')
    identifier = read_json(root / 'selection.json')[role]
    if not identifier:
        raise ValueError(f'No {role} release selected')
    release, _ = verify_release(root, identifier)
    runtime = Path.home() / '.local/state/teleops' / identifier
    command = ['bash', str(release / 'payload/launcher/pc2/vr_teleops/deployment/launch_release.sh'),
               str(release / 'payload'), str(runtime)] + extra
    if args.dry_run:
        print(json.dumps({'account': expected, 'release': identifier,
                          'runtime': str(runtime), 'command': command}, indent=2))
        return
    runtime.mkdir(parents=True, exist_ok=True, mode=0o700)
    print(f'Launching {role}: {identifier}. This starts real robot/hand/camera services.', flush=True)
    # Keep the global lock inherited by descendants, even if the manager exits.
    subprocess.run(command, check=True, pass_fds=(lock.fileno(),))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/opt/teleops'))
    sub = parser.add_subparsers(dest='action', required=True)
    init = sub.add_parser('init', help='Administrator: initialize paths/group; accounts must already exist')
    init.add_argument('--builder', default='teleops-ci')
    init.add_argument('--demo', default='demo')
    build_parser = sub.add_parser('build', help='Administrator: build at final path as the builder account')
    build_parser.add_argument('id')
    build_parser.add_argument('--hardware-profile', required=True)
    build_parser.add_argument('--repo', default='https://github.com/MoissanClub/unitree_g1_dev.git')
    build_parser.add_argument('--ref', default='main')
    build_parser.add_argument('--xr-url', default='https://github.com/MoissanClub/xr_teleoperate.git')
    sub.add_parser('freeze', help='Administrator: freeze and select candidate').add_argument('id')
    approve = sub.add_parser('promote', help='Administrator: approve the tested candidate')
    approve.add_argument('id')
    approve.add_argument('--accept-tested', action='store_true')
    sub.add_parser('rollback', help='Administrator: restore previous release')
    sub.add_parser('status', help='Show selected releases')
    run = sub.add_parser('run', help='Operator: run selected release; pass XR arguments after --')
    run.add_argument('--candidate', action='store_true')
    run.add_argument('--dry-run', action='store_true')
    args, extra = parser.parse_known_args(argv)
    if extra and (args.action != 'run' or extra[0] != '--'):
        parser.error('Unknown arguments; put XR arguments after --')
    root = args.root.expanduser().absolute()
    if root.is_symlink():
        parser.error('Deployment root must not be a symlink')
    try:
        if args.action == 'init':
            initialize(args, root)
            return 0
        for protected in (root, root / 'releases', root / 'deployment.json',
                          root / 'selection.json', root / 'session.lock'):
            info = protected.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                raise ValueError(f'Deployment control path must be administrator-owned: {protected}')
        settings = read_json(root / 'deployment.json')
        if args.action == 'status':
            print(json.dumps(read_json(root / 'selection.json'), indent=2))
            return 0
        with session_lock(root) as lock:
            if not (args.action == 'run' and args.dry_run):
                check_legacy_sessions()
            if args.action == 'build':
                build(args, root, settings)
            elif args.action == 'freeze':
                freeze(args, root, settings)
            elif args.action == 'promote':
                promote(args, root)
            elif args.action == 'rollback':
                rollback(root)
            elif args.action == 'run':
                launch(args, root, settings, lock, extra[1:])
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
