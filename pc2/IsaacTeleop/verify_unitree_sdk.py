#!/usr/bin/env python3
"""Check the installed Unitree native CRC without opening DDS or publishing commands."""

import argparse
from pathlib import Path


def main() -> None:
    """Verify native CRC loading and checksum calculation without hardware access."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-dir", type=Path, help="Require imports from this SDK checkout")
    args = parser.parse_args()

    from unitree_sdk2py.idl.default import unitree_hg_msg_dds__LowCmd_
    from unitree_sdk2py.utils import crc as crc_module

    module_path = Path(crc_module.__file__).resolve()
    if args.sdk_dir and not module_path.is_relative_to(args.sdk_dir.resolve()):
        raise RuntimeError(f"SDK import comes from {module_path}, not {args.sdk_dir}; check PYTHONPATH")
    crc = crc_module.CRC()
    vectors = ([0], [0xFFFFFFFF], [0, 1, 0x12345678, 0xFFFFFFFF])
    for words in vectors:
        if crc._crc_ctypes(words) != crc._crc_py(words):
            raise RuntimeError("Native CRC disagrees with the SDK Python reference")
    command = unitree_hg_msg_dds__LowCmd_()
    before = crc.Crc(command)
    command.motor_cmd[15].q = 0.125
    after = crc.Crc(command)
    if before == after:
        raise RuntimeError("G1 command CRC did not change after changing a motor field")
    print(f"PASS: Unitree native CRC loaded from {module_path.parent / 'lib'}")
    print("Native/reference CRC and G1 command checks passed; no DDS or robot connection opened.")


if __name__ == "__main__":
    main()
