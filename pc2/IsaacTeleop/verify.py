#!/usr/bin/env python3
"""Standalone package and live XR input checks; no LeRobot or robot transport."""

import argparse
import importlib
import inspect
import ipaddress
import json
import math
import os
import socket
import shutil
import subprocess
import sys
import time
from importlib.metadata import version
from pathlib import Path


def load_hardware_profile() -> dict[str, str]:
    """Use the repo's shell loader, including its configured/required-field checks."""
    loader = Path(__file__).resolve().parent.parent / "load_g1_pc2_hardware.sh"
    result = subprocess.run(
        ["bash", "--noprofile", "--norc", "-c",
         'set -e; unset G1_WIFI_IP; source "$1"; '
         'printf "%s\\0" "$G1_HARDWARE_CONFIG_FILE" "$G1_WIFI_IFACE" "${G1_WIFI_IP:-}"',
         "hardware-profile", str(loader)],
        capture_output=True, text=True, env=os.environ.copy(), check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Could not load PC2 hardware profile")
    fields = result.stdout.split("\0")
    if len(fields) != 4 or fields[-1]:
        raise RuntimeError("Unexpected output from hardware profile; use shell assignments only")
    return dict(zip(("path", "wifi_iface", "wifi_ip"), fields[:3], strict=True))


def resolve_host_ip(override: str | None, hardware: dict[str, str]) -> str:
    """Prefer CLI, then optional profile IP, then the configured interface's address."""
    address = override or hardware["wifi_ip"]
    if not address:
        result = subprocess.run(
            ["ip", "-j", "-4", "addr", "show", "dev", hardware["wifi_iface"]],
            capture_output=True, text=True, check=False, timeout=10,
        )
        if result.returncode:
            raise RuntimeError(f"Cannot inspect Wi-Fi interface {hardware['wifi_iface']}: "
                               f"{result.stderr.strip()}. Use --host-ip or set G1_WIFI_IP in the profile.")
        addresses = sorted({item["local"] for device in json.loads(result.stdout)
                            for item in device.get("addr_info", [])
                            if item.get("family") == "inet" and item.get("scope") == "global"})
        if len(addresses) != 1:
            raise RuntimeError(f"Expected one IPv4 address on {hardware['wifi_iface']}, found {addresses}. "
                               "Use --host-ip or set G1_WIFI_IP in the profile.")
        address = addresses[0]
    parsed = ipaddress.IPv4Address(address)
    if parsed.is_unspecified or parsed.is_loopback or parsed.is_multicast or parsed.is_link_local:
        raise ValueError(f"Use a headset-reachable PC2 IPv4 address, got {address}")
    return str(parsed)


def make_pipeline():
    from isaacteleop.retargeting_engine.deviceio_source_nodes import ControllersSource, HeadSource
    from isaacteleop.retargeting_engine.interface import OutputCombiner

    controllers = ControllersSource(name="controllers")
    head = HeadSource(name="head")
    return OutputCombiner({
        "left": controllers.output("controller_left"),
        "right": controllers.output("controller_right"),
        "head": head.output("head"),
    })


def check_installation():
    from isaacteleop.cloudxr import CloudXRLauncher
    from isaacteleop.cloudxr.runtime import get_sdk_path, resolve_cloudxr_runtime_module
    from isaacteleop.retargeting_engine.tensor_types.indices import ControllerInputIndex, HeadPoseIndex
    from isaacteleop.teleop_session_manager import TeleopSession, TeleopSessionConfig

    installed = version("isaacteleop")
    if installed != "1.4.145":
        raise RuntimeError(f"Expected Isaac Teleop 1.4.145, found {installed}. Run install.sh.")
    inspect.signature(CloudXRLauncher).bind(device_profile="Quest3", accept_eula=False)
    pipeline = make_pipeline()
    TeleopSessionConfig(app_name="Standalone Quest verification", pipeline=pipeline)
    for enum, names in (
        (ControllerInputIndex, ("GRIP_IS_VALID", "GRIP_POSITION", "TRIGGER_VALUE")),
        (HeadPoseIndex, ("IS_VALID", "POSITION")),
    ):
        for name in names:
            getattr(enum, name)
    runtime = resolve_cloudxr_runtime_module()
    importlib.import_module(runtime + ".runtime")
    native = Path(get_sdk_path())
    for filename in ("libcloudxr.so", "libopenxr_cloudxr.so", "openxr_cloudxr.json"):
        if not (native / filename).is_file():
            raise RuntimeError(f"Missing CloudXR file: {native / filename}")
    if shutil.which("ldd"):
        for filename in ("libcloudxr.so", "libopenxr_cloudxr.so"):
            result = subprocess.run(["ldd", str(native / filename)], capture_output=True, text=True, timeout=15)
            if result.returncode or "not found" in result.stdout + result.stderr:
                raise RuntimeError(f"CloudXR native dependency check failed for {filename}:\n"
                                   f"{result.stdout}{result.stderr}")
    else:
        print("NOTE: ldd unavailable; native shared-library dependencies were not checked.")
    compatible = Path("/proc/device-tree/compatible")
    if compatible.is_file() and b"tegra234" in compatible.read_bytes() and runtime != "isaacteleop.cloudxr_exp":
        raise RuntimeError("Jetson Orin should select cloudxr_exp. Unset ISAAC_TELEOP_CLOUDXR_EXP=0.")
    print(f"PASS: Isaac Teleop {installed}; head/controller graph constructed.", flush=True)
    print(f"CloudXR selected: {runtime}\nBundled runtime: {native}", flush=True)
    print("Import checks do not verify runtime startup, GPU, networking, or headset tracking.", flush=True)
    return pipeline


def tracked(value, index) -> bool:
    return value is not None and not getattr(value, "is_none", False) and bool(value[index])


def headset_test(args: argparse.Namespace, pipeline) -> int:
    from isaacteleop.cloudxr import CloudXRLauncher
    from isaacteleop.retargeting_engine.interface import ExecutionEvents, ExecutionState
    from isaacteleop.retargeting_engine.tensor_types.indices import ControllerInputIndex as C
    from isaacteleop.retargeting_engine.tensor_types.indices import HeadPoseIndex as H
    from isaacteleop.teleop_session_manager import TeleopSession, TeleopSessionConfig

    for port in (48322, 49100):
        with socket.socket() as probe:
            probe.settimeout(0.3)
            if probe.connect_ex(("127.0.0.1", port)) == 0:
                raise RuntimeError(f"Port {port} is in use. Stop the existing XR runtime first.")
    print(f"In the Quest browser, open https://{args.host_ip}:48322 and accept the local certificate if prompted.")
    print("Then open https://nvidia.github.io/IsaacTeleop/client and connect to " + args.host_ip)
    print("Wear the headset, wake both controllers, move them, and press the triggers.")
    print("This checks tracking only: there is no MuJoCo view or robot connection. Ctrl+C stops it.", flush=True)
    consecutive = 0
    peak = 0
    # Reverse context order closes OpenXR before stopping CloudXR.
    with CloudXRLauncher(device_profile=args.profile, accept_eula=args.accept_eula):
        session = TeleopSession(TeleopSessionConfig(app_name="Standalone Quest verification", pipeline=pipeline))
        try:
            session.__enter__()
        except BaseException:
            # SDK versions can leave partially entered contexts on setup failure.
            stack = getattr(session, "_exit_stack", None)
            if stack is not None:
                stack.close()
            raise
        try:
            deadline = time.monotonic() + args.duration
            last_print = 0.0
            while time.monotonic() < deadline:
                result = session.step(execution_events=ExecutionEvents(
                    execution_state=ExecutionState.RUNNING, reset=False))
                info = session.last_step_info
                if info is not None and info.worker_exception is not None:
                    raise RuntimeError("XR input worker failed") from info.worker_exception
                fresh = info is not None and not info.frame_deadline_miss
                states = {"head": tracked(result["head"], H.IS_VALID),
                          "left": tracked(result["left"], C.GRIP_IS_VALID),
                          "right": tracked(result["right"], C.GRIP_IS_VALID)}
                consecutive = consecutive + 1 if fresh and all(states.values()) else 0
                peak = max(peak, consecutive)
                now = time.monotonic()
                if now - last_print >= 1:
                    print(f"fresh={fresh} tracking={states} consecutive={consecutive}", flush=True)
                    for side in ("left", "right"):
                        if fresh and states[side]:
                            print(f"  {side}: position={result[side][C.GRIP_POSITION]} "
                                  f"trigger={float(result[side][C.TRIGGER_VALUE]):.2f}", flush=True)
                    last_print = now
                if consecutive >= 90:
                    print("PASS: 90 consecutive fresh frames with head and both controllers tracked.", flush=True)
                    return 0
                time.sleep(1 / 90)
        finally:
            session.__exit__(*sys.exc_info())
    print(f"FAIL: no sustained head + dual-controller tracking before timeout (best {peak}/90 frames).")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check-only", action="store_true", help="Package/API checks only (default)")
    mode.add_argument("--headset", action="store_true", help="Start CloudXR and verify live headset/controller input")
    mode.add_argument("--show-config", action="store_true", help="Show profile and resolved Wi-Fi IP without starting XR")
    parser.add_argument("--host-ip", help="Override profile G1_WIFI_IP or address detected on G1_WIFI_IFACE")
    parser.add_argument("--profile", default="Quest3", help="CloudXR headset profile (default: Quest3)")
    parser.add_argument("--duration", type=float, default=120, help="Tracking timeout after XR startup, seconds")
    parser.add_argument("--accept-eula", action="store_true", help="Explicitly accept NVIDIA's CloudXR EULA")
    args = parser.parse_args()
    if not math.isfinite(args.duration) or args.duration <= 0:
        parser.error("--duration must be finite and positive")
    if args.headset:
        if not args.accept_eula:
            parser.error("--headset requires explicit --accept-eula after reviewing NVIDIA's EULA")
    try:
        hardware = load_hardware_profile()
        print(f"Hardware profile: {hardware['path']}\nWi-Fi interface: {hardware['wifi_iface']}", flush=True)
        if args.headset or args.show_config:
            args.host_ip = resolve_host_ip(args.host_ip, hardware)
            print(f"Headset host IP: {args.host_ip}", flush=True)
        if args.show_config:
            return 0
        pipeline = check_installation()
        return headset_test(args, pipeline) if args.headset else 0
    except KeyboardInterrupt:
        print("Stopped by user; headset verification did not finish.", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"FAIL: {type(exc).__name__}: {exc}", file=sys.stderr)
        print("For runtime startup failures, inspect ~/.cloudxr/logs and run with the Quest on the same network.",
              file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
