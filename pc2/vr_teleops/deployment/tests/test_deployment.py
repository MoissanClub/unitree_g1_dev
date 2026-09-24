import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deploy = load('deployment')
runtime_patch = load('patch_runtime')


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'releases').mkdir()
        (self.root / 'session.lock').touch()
        deploy.write_json(self.root / 'selection.json', {'candidate': None, 'current': None, 'previous': None})

    def release(self, identifier):
        path = deploy.release_dir(self.root, identifier)
        (path / 'payload/runtime-template').mkdir(parents=True)
        (path / 'payload/runtime-template/config').write_text(identifier)
        deploy.write_json(path / 'release.json', {'status': 'frozen',
                                                 'digest': deploy.digest_payload(path / 'payload')})
        return path

    def select(self, **values):
        selection = deploy.read_json(self.root / 'selection.json')
        selection.update(values)
        deploy.write_json(self.root / 'selection.json', selection)

    def test_promote_then_rollback_selects_exact_release(self):
        self.release('old')
        self.release('new')
        self.select(current='old', candidate='new')
        with patch.object(deploy, 'require_root'), patch.object(deploy, 'assert_frozen'), contextlib.redirect_stdout(io.StringIO()):
            deploy.promote(argparse.Namespace(id='new', accept_tested=True), self.root)
            selection = deploy.read_json(self.root / 'selection.json')
            self.assertEqual((selection['current'], selection['previous']), ('new', 'old'))
            deploy.rollback(self.root)
        selection = deploy.read_json(self.root / 'selection.json')
        self.assertEqual((selection['current'], selection['previous']), ('old', 'new'))

    def test_promotion_requires_human_approval(self):
        self.release('new')
        self.select(candidate='new')
        with patch.object(deploy, 'require_root'), self.assertRaisesRegex(ValueError, 'accept-tested'):
            deploy.promote(argparse.Namespace(id='new', accept_tested=False), self.root)
        self.assertIsNone(deploy.read_json(self.root / 'selection.json')['current'])

    def test_changed_release_cannot_be_promoted(self):
        release = self.release('new')
        self.select(candidate='new')
        (release / 'payload/runtime-template/config').write_text('changed after trial')
        with patch.object(deploy, 'require_root'), patch.object(deploy, 'assert_frozen'), self.assertRaisesRegex(ValueError, 'changed after freeze'):
            deploy.promote(argparse.Namespace(id='new', accept_tested=True), self.root)

    def test_shared_lock_excludes_second_operator_and_admin(self):
        with deploy.session_lock(self.root):
            with self.assertRaisesRegex(RuntimeError, 'session is active'):
                with deploy.session_lock(self.root):
                    self.fail('Second session acquired lock')

    def test_path_traversal_and_symlink_release_rejected(self):
        for value in ('../demo', '/', '..', 'x/y'):
            with self.assertRaises(ValueError):
                deploy.release_dir(self.root, value)
        (self.root / 'releases/fake').symlink_to(self.root)
        with self.assertRaises(ValueError):
            deploy.release_dir(self.root, 'fake')

    def test_external_hardlinks_rejected_before_chown(self):
        release = self.release('new')
        external = self.root / 'external'
        external.write_text('do not chown')
        os.link(external, release / 'payload/hardlink')
        with patch.object(deploy.os, 'chown') as chown, self.assertRaisesRegex(ValueError, 'Hardlink extends outside'):
            deploy.freeze_payload(release / 'payload', os.getgid())
        chown.assert_not_called()

    def test_external_account_symlink_rejected_before_chown(self):
        release = self.release('new')
        (release / 'payload/source').symlink_to('/home/teleops-ci/mutable-source')
        with patch.object(deploy.os, 'chown') as chown, self.assertRaisesRegex(ValueError, 'Symlink points outside'):
            deploy.freeze_payload(release / 'payload', os.getgid())
        chown.assert_not_called()

    def test_runtime_patches_are_idempotent_and_handle_cache_and_camera_paths(self):
        xr = self.root / 'xr'
        server = xr / 'teleop/teleimager/src/teleimager/image_server.py'
        server.parent.mkdir(parents=True)
        server.write_text('import os\nCONFIG_PATH = "default.yaml"\nCONFIG_PATH = os.path.normpath(CONFIG_PATH)\n')
        ik = xr / 'teleop/robot_control/robot_arm_ik.py'
        ik.parent.mkdir(parents=True)
        ik.write_text('import os\nclass IK:\n    def __init__(self):\n        self.cache_path = "g1_29_model_cache.pkl"\n')
        runtime_patch.patch_sources(xr)
        first = (server.read_text(), ik.read_text())
        runtime_patch.patch_sources(xr)
        self.assertEqual(first, (server.read_text(), ik.read_text()))
        namespace = {}
        with patch.dict(os.environ, {'G1_TELEIMAGER_CONFIG': '/tmp/account-camera.yaml',
                                     'G1_TELEOP_CACHE_DIR': '/tmp/account-cache'}):
            exec(compile(server.read_text(), str(server), 'exec'), namespace)
            self.assertEqual(namespace['CONFIG_PATH'], '/tmp/account-camera.yaml')
            exec(compile(ik.read_text(), str(ik), 'exec'), namespace)
            self.assertEqual(namespace['IK']().cache_path, '/tmp/account-cache/g1_29_model_cache.pkl')

    def test_source_drift_fails_closed(self):
        xr = self.root / 'xr'
        server = xr / 'teleop/teleimager/src/teleimager/image_server.py'
        server.parent.mkdir(parents=True)
        server.write_text('CONFIG_PATH = "upstream-changed"\n')
        with self.assertRaisesRegex(RuntimeError, 'config loader changed'):
            runtime_patch.patch_sources(xr)


if __name__ == '__main__':
    unittest.main()
