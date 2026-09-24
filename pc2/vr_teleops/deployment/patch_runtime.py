#!/usr/bin/env python3
"""Apply reviewed release-specific write-path adaptations; fail on source drift."""
import ast
from pathlib import Path
import re
import sys


def patch_sources(xr):
    server = xr / 'teleop/teleimager/src/teleimager/image_server.py'
    text = server.read_text()
    if 'G1_TELEIMAGER_CONFIG' not in text:
        anchor = 'CONFIG_PATH = os.path.normpath(CONFIG_PATH)'
        if text.count(anchor) != 1:
            raise RuntimeError('Teleimager config loader changed; review release adaptation')
        text = text.replace(anchor, 'CONFIG_PATH = os.path.normpath(os.environ.get("G1_TELEIMAGER_CONFIG", CONFIG_PATH))')
        ast.parse(text)
        server.write_text(text)
    ik = xr / 'teleop/robot_control/robot_arm_ik.py'
    text = ik.read_text()
    if 'G1_TELEOP_CACHE_DIR' not in text:
        text, count = re.subn(r'self\.cache_path = (["\'])([^"\']+_model_cache\.pkl)\1',
                             r'self.cache_path = os.path.join(os.environ.get("G1_TELEOP_CACHE_DIR", "."), "\2")', text)
        if count < 1:
            raise RuntimeError('IK cache path changed; review release adaptation')
        ast.parse(text)
        ik.write_text(text)


if __name__ == '__main__':
    patch_sources(Path(sys.argv[1]))
