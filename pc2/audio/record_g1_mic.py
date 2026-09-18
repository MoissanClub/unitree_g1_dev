#!/usr/bin/env python3
"""Record the Unitree G1 microphone array to a WAV file, from PC2.

HOW THE PIECES FIT TOGETHER
---------------------------
The G1's microphone array is wired to PC1 (the robot's internal computer,
192.168.123.161), not to PC2. PC2 has no usable sound card of its own:

  * "tegra-hda" only drives HDMI/DisplayPort audio out.
  * "tegra-ape" is the Jetson's internal audio engine with no codec attached.
  * There is no USB audio device.

So ALSA tools such as `arecord` cannot see the G1 microphone. Instead, PC1
runs a Unitree audio service that continuously publishes the microphone signal
on the wired robot network (192.168.123.0/24) as UDP *multicast*:

    PC1 mic array --> PC1 audio service --> UDP multicast 239.168.123.161:5555
                                                  |
                                     wired Ethernet (enP8p1s0 on PC2)
                                                  |
                              this script joins the group, receives datagrams,
                              and writes them to a WAV file

Stream format (measured on the robot, not taken from a spec):

  * raw PCM, 16 kHz sample rate, 16-bit signed little-endian, 1 channel
  * no header and no sequence numbers: every datagram is just audio bytes
  * datagrams are 5120 bytes = 2560 samples = 160 ms of audio each
  * PC1 sends the stream whether or not anyone is listening, so a recording
    starts at the moment this script joins the multicast group

Because the payload is already plain PCM, "recording" is only three steps:
join the multicast group, append each datagram's bytes to a WAV file, and let
the `wave` module write the 44-byte WAV header that players need.

Multicast in one paragraph: a sender addresses packets to a group address in
224.0.0.0/4 (here 239.168.123.161). A receiver tells its kernel "I want that
group on this network interface" (IP_ADD_MEMBERSHIP). The kernel then sends
an IGMP join so switches forward the group to that port, and delivers matching
UDP packets to any socket bound to the group's port. Many receivers can listen
at once, so this script does not disturb other consumers of the audio.

Usage examples:
    ./record_g1_mic.py                       # until Ctrl-C, auto-named file
    ./record_g1_mic.py -d 10 -o hello.wav    # exactly 10 seconds
    ./record_g1_mic.py --interface 192.168.123.164

Only the Python standard library is used.
"""

import argparse
import array
import math
import signal
import socket
import struct
import sys
import time
import wave
from datetime import datetime

# --- Stream constants (see the module docstring) ---------------------------
DEFAULT_GROUP = "239.168.123.161"   # multicast group PC1 publishes the mic on
DEFAULT_PORT = 5555                 # UDP port of that stream
DEFAULT_ROBOT_IP = "192.168.123.161"  # PC1; used only to pick the right NIC
SAMPLE_RATE = 16000                 # Hz
SAMPLE_WIDTH = 2                    # bytes per sample (16-bit)
CHANNELS = 1                        # mono
BYTES_PER_SECOND = SAMPLE_RATE * SAMPLE_WIDTH * CHANNELS  # 32000

# A datagram can be up to 65535 bytes. recvfrom(n) SILENTLY TRUNCATES anything
# longer than n, which would chop audio out of every packet (the stream's
# 5120-byte datagrams are larger than the common 4096 default), so always read
# with the maximum size.
MAX_DATAGRAM = 65535

# How long to wait for the very first packet before giving up.
FIRST_PACKET_TIMEOUT_S = 5.0

# If we receive less than this fraction of the audio a real-time 16 kHz stream
# should deliver, warn that packets were probably dropped.
MIN_EXPECTED_RATE_FRACTION = 0.95


def local_ip_towards(remote_ip):
    """Return the local IPv4 address the kernel would use to reach `remote_ip`.

    Multicast membership is per network interface. PC2 has several interfaces
    (wired robot LAN, Wi-Fi, ...), and joining on the wrong one would receive
    nothing. Connecting a UDP socket does not send any packet; it only makes
    the kernel run its routing lookup, after which getsockname() reveals the
    source address (and therefore the interface) it picked. Since PC1 lives on
    the wired robot subnet, this yields PC2's wired address.
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((remote_ip, 9))  # port is irrelevant; nothing is sent
        return probe.getsockname()[0]
    finally:
        probe.close()


def open_multicast_socket(group, port, interface_ip):
    """Create a UDP socket that receives datagrams sent to `group`:`port`."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)

    # SO_REUSEADDR lets several programs on this machine (for example a second
    # recorder or a speech-recognition tool) listen to the same multicast port.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    # A larger kernel receive buffer absorbs short stalls (disk writes, GC
    # pauses) so bursts are not dropped. The kernel may clamp the value.
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)

    # Binding to the group address (not "") makes the kernel deliver only
    # packets addressed to this group, not other traffic on the same port.
    sock.bind((group, port))

    # ip_mreq = { multicast group, local interface }, both as 4-byte addresses.
    # This is what triggers the IGMP join on the chosen interface.
    membership = struct.pack(
        "4s4s", socket.inet_aton(group), socket.inet_aton(interface_ip)
    )
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)

    # A short timeout keeps the receive loop responsive: it wakes up at least
    # twice a second to check for Ctrl-C, the duration limit and the
    # "no packets ever arrived" condition, even if PC1 stops sending.
    sock.settimeout(0.5)
    return sock


def peak_dbfs(pcm_bytes):
    """Peak level of a chunk of 16-bit PCM, in dB relative to full scale.

    0 dBFS is the loudest value a 16-bit sample can hold; -60 dBFS and below
    is near-silence. Used only for the live level meter.
    """
    usable = len(pcm_bytes) - (len(pcm_bytes) % SAMPLE_WIDTH)
    samples = array.array("h")
    samples.frombytes(pcm_bytes[:usable])
    if sys.byteorder == "big":  # the stream is little-endian
        samples.byteswap()
    peak = max((abs(s) for s in samples), default=0)
    return -math.inf if peak == 0 else 20 * math.log10(peak / 32768.0)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Record the G1 microphone (streamed by PC1 over UDP "
        "multicast) to a 16 kHz, 16-bit, mono WAV file.",
    )
    parser.add_argument(
        "-o", "--output",
        help="output WAV path (default: g1_mic_<timestamp>.wav in the "
        "current directory)",
    )
    parser.add_argument(
        "-d", "--duration", type=float, default=None, metavar="SECONDS",
        help="stop after this many seconds (default: record until Ctrl-C)",
    )
    parser.add_argument(
        "--interface", default=None, metavar="IP",
        help="local IPv4 address of the NIC on the robot network "
        "(default: auto-detect by routing towards PC1)",
    )
    parser.add_argument("--group", default=DEFAULT_GROUP,
                        help="multicast group (default: %(default)s)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="UDP port (default: %(default)s)")
    parser.add_argument("--robot-ip", default=DEFAULT_ROBOT_IP,
                        help="PC1 address used for NIC auto-detection "
                        "(default: %(default)s)")
    parser.add_argument("--no-meter", action="store_true",
                        help="disable the live level meter")
    return parser.parse_args()


def main():
    args = parse_args()

    output = args.output or datetime.now().strftime("g1_mic_%Y%m%d_%H%M%S.wav")

    interface_ip = args.interface or local_ip_towards(args.robot_ip)
    print(f"Joining {args.group}:{args.port} on interface {interface_ip}",
          file=sys.stderr)
    sock = open_multicast_socket(args.group, args.port, interface_ip)

    # Ctrl-C (SIGINT) and `kill` (SIGTERM) only set a flag. The loop below
    # notices it and exits normally, so the WAV file is always closed and its
    # header finalized. Without this, an interrupted recording could be left
    # with a header that claims zero length and would not play.
    stop_requested = False

    def request_stop(signum, frame):
        nonlocal stop_requested
        stop_requested = True

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)

    total_bytes = 0            # audio bytes written so far
    first_packet_time = None   # monotonic time of the first datagram
    last_packet_time = None    # monotonic time of the latest datagram
    wait_started = time.monotonic()
    last_meter_time = 0.0
    pending = b""              # odd trailing byte carried between datagrams

    # The `wave` module writes a placeholder header when the file is opened and
    # rewrites it with the true length when the file is closed (the `with`
    # block guarantees that), so the file need not fit in memory.
    with wave.open(output, "wb") as wav:
        wav.setnchannels(CHANNELS)
        wav.setsampwidth(SAMPLE_WIDTH)
        wav.setframerate(SAMPLE_RATE)

        while not stop_requested:
            now = time.monotonic()

            # Stop once the requested duration has elapsed, measured from the
            # first audio packet rather than from program start.
            if (args.duration is not None and first_packet_time is not None
                    and now - first_packet_time >= args.duration):
                break

            # Nothing has arrived: PC1 is not sending, the wrong interface was
            # picked, or a firewall is dropping multicast/IGMP.
            if (first_packet_time is None
                    and now - wait_started > FIRST_PACKET_TIMEOUT_S):
                print(
                    f"\nNo audio received within {FIRST_PACKET_TIMEOUT_S:.0f} s. "
                    "Check that PC1 is reachable (ping 192.168.123.161), that "
                    "--interface is the wired robot NIC, and that no firewall "
                    "blocks multicast.",
                    file=sys.stderr,
                )
                sock.close()
                return 1

            try:
                datagram = sock.recvfrom(MAX_DATAGRAM)[0]
            except socket.timeout:
                continue  # loop again: re-check stop flag / limits

            now = time.monotonic()
            if first_packet_time is None:
                first_packet_time = now
            last_packet_time = now

            # Keep samples 2-byte aligned in case a datagram ever ends in the
            # middle of a sample (the observed stream never does).
            data = pending + datagram
            if len(data) % SAMPLE_WIDTH:
                pending, data = data[-1:], data[:-1]
            else:
                pending = b""

            wav.writeframes(data)
            total_bytes += len(data)

            # Refresh the meter at most twice a second. "\r" redraws the same
            # terminal line instead of scrolling.
            if not args.no_meter and now - last_meter_time >= 0.5:
                last_meter_time = now
                elapsed = total_bytes / BYTES_PER_SECOND
                level = peak_dbfs(data)
                level_text = "  -inf" if level == -math.inf else f"{level:6.1f}"
                print(f"\r  recorded {elapsed:7.1f} s   peak {level_text} dBFS ",
                      end="", file=sys.stderr, flush=True)

    sock.close()
    print(file=sys.stderr)  # finish the meter line

    if total_bytes == 0:
        print("No audio was recorded.", file=sys.stderr)
        return 1

    audio_seconds = total_bytes / BYTES_PER_SECOND
    print(f"Saved {output}: {audio_seconds:.1f} s of audio "
          f"({total_bytes} bytes, {SAMPLE_RATE} Hz, 16-bit, mono)")

    # Loss check. UDP has no retransmission, so lost datagrams simply vanish
    # and would make the audio glitchy and shorter than real time. A real-time
    # stream delivers 32000 bytes per wall-clock second, so compare the audio
    # received with the time that actually passed between first and last
    # packet. (The first packet's own 160 ms is excluded from the span.)
    span = last_packet_time - first_packet_time
    if span > 1.0:
        received = total_bytes - len(datagram)
        fraction = received / (span * BYTES_PER_SECOND)
        if fraction < MIN_EXPECTED_RATE_FRACTION:
            print(f"WARNING: only {fraction:.0%} of the expected audio arrived; "
                  "packets were probably dropped (busy network or CPU?).",
                  file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
