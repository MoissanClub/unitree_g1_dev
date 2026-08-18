# RealSense to MediaMTX WebRTC on Jetson Orin NX

This deployment publishes the D435i RGB stream at 1920x1080, 30 fps through
Jetson's dedicated video hardware:

```text
D435i RGB sensor
  -> USB/UVC kernel driver
  -> V4L2 YUYV capture
  -> nvvidconv (VIC: YUYV to NV12 in NVMM)
  -> nvv4l2h264enc (NVENC: H.264 Baseline, no B-frames)
  -> RTSP over loopback TCP
  -> MediaMTX
  -> WebRTC (DTLS-SRTP) over UDP
  -> browser
```

Signaling is handled separately and does not carry video frames:

```text
Vuer POST /offer (JSON) -> compatibility adapter :60001
                        -> MediaMTX WHEP 127.0.0.1:8889 (raw SDP)

ImageClient config request -> compatibility adapter ZMQ REP :60000
```

This path handles RGB video only. It intentionally does not load
`librealsense`/`pyrealsense2`, depth, IMU, CUDA, or DeepStream. MediaMTX does
not transcode; the browser receives the H.264 produced by NVENC. The adapter
translates signaling and returns static camera metadata, but never touches the
encoded stream or WebRTC media packets.

## Requirements

- Jetson Orin NX with JetPack 6 / L4T r36
- Intel RealSense D435i connected over USB 3
- Ubuntu `systemd` and outbound access to GitHub during installation
- Browser network access to Jetson TCP 60001 and UDP 8189
- Teleop process access to TCP 60000 when it runs on another host

Do not run the existing `teleimager.service` against the same camera at the
same time. A V4L2 node normally has one active capture owner.

## Install

From this directory on the Jetson:

```bash
sudo ./install.sh
```

If the old Python image server is active and this deployment replaces it:

```bash
sudo ./install.sh --replace-python-server
```

The installer pins MediaMTX 1.20.0, verifies the release checksum, installs
only the required GStreamer packages, verifies the NVIDIA elements, probes the
camera-to-VIC path, and starts all three services. It preserves an existing camera
environment file. For TLS, it copies the invoking user's existing
`~/.config/xr_teleoperate/cert.pem` and `key.pem` after validating the pair.

Useful installation variants:

```bash
# Used only when the existing xr_teleoperate certificate pair is absent.
sudo TLS_EXTRA_NAMES=robot.example.test,10.0.0.20 ./install.sh

# Install while the camera is disconnected, then start it later.
sudo ./install.sh --skip-camera-check --no-start
```

## Open The Stream

Open this URL in a browser using the same certificate trust setup as the
original Teleimager server:

```text
https://JETSON_HOSTNAME_OR_IP:60001/
```

The compatibility adapter serves MediaMTX's `/d435/` player at `/`, so the
internal stream path remains hidden in the normal browser URL.

Use a hostname or IP included in the certificate. Inspect the names with:

```bash
openssl x509 -in /etc/mediamtx/tls/server.crt -noout -ext subjectAltName
```

The direct WHEP endpoint for a custom client is:

```text
https://JETSON_HOSTNAME_OR_IP:60001/d435/whep
```

### Teleop Compatibility

The existing `teleop_hand_and_arm.py` URL works unchanged:

```text
https://JETSON_HOSTNAME_OR_IP:60001/offer
```

Vuer posts JSON containing `type` and `sdp`. The adapter extracts the offer SDP,
posts it as `application/sdp` to MediaMTX at `/d435/whep`, then wraps the SDP
answer in Teleimager's JSON response format. Current Vuer gathers ICE candidates
before posting, so this compatibility route does not need WHEP trickle-ICE
`PATCH` handling. Direct WHEP routes are still proxied for standards-based
clients.

MediaMTX requires every stream to have a non-empty path because one server can
route multiple streams. The internal path remains `d435`, but clients using the
old Teleimager API do not need to know it.

The adapter also answers the existing `ImageClient` ZMQ configuration request
on TCP 60000. It advertises one 1920x1080 mono head stream with WebRTC enabled
and ZMQ image transport disabled. This avoids the one-second fallback timeout
and prevents stale local configuration from incorrectly advertising binocular
or raw-image streams. The disabled wrist entries are retained because
`ImageClient` expects all three dictionary keys.

`request_bgr=True` remains harmless: `ImageClient` creates a decoder subscriber
only when `enable_zmq` is true. All raw-frame reads in `teleop_hand_and_arm.py`
are guarded by the same flag. The consequence is that `--record` cannot include
camera images with this deployment; its recorder consumes ZMQ BGR frames, not
the browser's WebRTC stream. Robot state recording still runs, but logs that the
head image is unavailable. Add a separate recording branch to the GStreamer
pipeline if synchronized image recording is required.

If `WIDTH`, `HEIGHT`, or `FPS` is changed in
`/etc/default/teleimager-webrtc`, update the head values in
`/etc/teleimager/compat-camera.json` and restart `teleimager-compat.service` so
the display aspect ratio and advertised metadata stay accurate.

### Why This Is Not Only Nginx Or A Shell Script

A stock Nginx configuration can proxy and redirect HTTP, but cannot parse the
JSON request, extract `sdp`, build a different upstream request, and wrap raw
SDP back into JSON. Doing that requires an Nginx scripting module such as njs
or Lua, and Nginx still cannot implement the ZMQ REP configuration endpoint.

`curl` is an HTTP client, not a server. A loop around `nc` would also need to
implement concurrent HTTPS, HTTP framing, JSON validation, CORS, SDP forwarding,
error handling, and the ZMQ wire protocol. The small Python service uses the
standard HTTP/TLS libraries plus Ubuntu's `python3-zmq` and is less code than a
reliable shell implementation.

## TLS: Exact Files And Meaning

MediaMTX and the compatibility adapter both read the following installed TLS
pair. MediaMTX serves HTTPS only on loopback `127.0.0.1:8889`; the adapter
presents the same certificate on public TCP 60001.

```yaml
webrtcEncryption: true
webrtcServerCert: /etc/mediamtx/tls/server.crt
webrtcServerKey: /etc/mediamtx/tls/server.key
```

`webrtcEncryption` enables HTTPS for MediaMTX's internal player and WHEP
signaling listener.
WebRTC media itself is always encrypted independently with DTLS-SRTP. HTTPS is
not inherently required by the WebRTC wire protocol, and browsers treat
`http://localhost` specially, but HTTPS with a trusted certificate is the
reliable setup when the page is opened remotely from a Mac.

By default, the installer copies:

```text
~/.config/xr_teleoperate/cert.pem -> /etc/mediamtx/tls/server.crt
~/.config/xr_teleoperate/key.pem  -> /etc/mediamtx/tls/server.key
```

The source home is resolved from `SUDO_USER`, so `sudo ./install.sh` uses the
non-root operator's home. Override discovery with `XR_TELEOP_CERT` and
`XR_TELEOP_KEY`. MediaMTX reads only the installed copies, allowing its
restricted service account to avoid access to the operator's home directory.

Installed files are:

| File | Purpose | Reader |
| --- | --- | --- |
| `/etc/mediamtx/tls/server.crt` | Jetson HTTPS server certificate | MediaMTX |
| `/etc/mediamtx/tls/server.key` | Server private key | MediaMTX group only |
| `/etc/mediamtx/tls/ca.crt` | Fallback private CA certificate, when generated | Clients |
| `/etc/mediamtx/tls/ca.key` | Fallback private CA key, when generated | Root only |

Continue using the client trust configuration already used by Teleimager. If
the existing pair is absent, the installer invokes `generate-tls.sh`; only in
that fallback case, copy `ca.crt` to the Mac and trust it:

```bash
scp unitree@JETSON_HOST:/etc/mediamtx/tls/ca.crt ./teleimager-ca.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ./teleimager-ca.crt
```

Then fully restart the browser.

To regenerate a certificate after changing the hostname or IP:

```bash
sudo TLS_EXTRA_NAMES=10.0.0.20 \
  /usr/local/libexec/teleimager/generate-tls.sh --force
sudo systemctl restart mediamtx.service teleimager-compat.service
```

For a publicly trusted certificate, set `webrtcServerCert` to the full chain
(for example, Let's Encrypt `fullchain.pem`) and `webrtcServerKey` to its
`privkey.pem`. Grant the `mediamtx` service read access through a restricted
group or certificate deployment hook; do not make the private key world-readable.

## Camera And Encoder Tuning

Runtime settings live in `/etc/default/teleimager-webrtc`:

```bash
sudoedit /etc/default/teleimager-webrtc
sudo systemctl restart teleimager-realsense-webrtc.service
```

The defaults are optimized for capture-to-video latency:

- `BITRATE=8000000`: 8 Mbit/s CBR is a practical 1080p30 starting point.
- `GOP=30`: an IDR every second limits join/recovery delay.
- H.264 Baseline and `num-B-Frames=0`: browser-compatible, no frame reordering.
- `preset-level=1`: NVIDIA UltraFast preset.
- `V4L2_IO_MODE=auto`: use DMABUF when supported, otherwise reliable mmap.
- Four VIC output buffers prevent Jetson buffer-pool starvation. This is buffer
  pool capacity, not a four-frame queue; two buffers stall this D435i pipeline.
- No explicit GStreamer `queue`: avoids hidden frame accumulation.
- Local RTSP uses TCP with `latency=0`; browser media prefers UDP ICE.
- No CPU affinity: the remaining lightweight GStreamer and MediaMTX threads
  can be scheduled around the latency-sensitive teleoperation process.

If auto-discovery selects the wrong node, inspect the persistent links and
identify the color interface by its advertised YUYV mode:

```bash
ls -l /dev/v4l/by-path/ /dev/v4l/by-id/
v4l2-ctl --device=/dev/videoN --list-formats-ext
```

Then set `CAMERA_DEVICE=/dev/v4l/by-path/...` in the environment file. D435i
by-id links can collide because its depth and color interfaces share a serial
number and video-index values; by-path distinguishes the UVC interfaces. V4L2
calls the packed format `YUYV`; GStreamer calls the same byte layout `YUY2`.

DMABUF can remove a userspace copy between V4L2 and the NVIDIA conversion
element, but UVC/driver combinations vary. A successful probe is useful but is
not proof that every transfer from the USB controller to NVMM is zero-copy.
The mmap fallback still uses VIC for color conversion and NVENC for encoding,
but buffer transfer into NVMM can consume some CPU and memory bandwidth.

## Operations

```bash
systemctl status mediamtx.service teleimager-compat.service \
  teleimager-realsense-webrtc.service
journalctl -u teleimager-realsense-webrtc.service -f
journalctl -u mediamtx.service -f
journalctl -u teleimager-compat.service -f

# MediaMTX process/path state and Prometheus metrics are loopback-only.
curl http://127.0.0.1:9997/v3/paths/list
curl http://127.0.0.1:9998/metrics

# Jetson CPU, VIC, NVENC, memory, and thermal activity.
tegrastats
```

For host firewalls, allow TCP 60001 and UDP 8189. Also allow TCP 60000 from the
teleop host when it is not the Jetson itself. MediaMTX HTTPS 8889, RTSP 8554,
API 9997, and metrics 9998 bind only to loopback and must not be opened. If
direct UDP cannot cross the network, add a TURN server under
`webrtcICEServers2`; enabling ICE TCP is a weaker fallback because congestion
can produce growing latency.

The default `d435` path allows anonymous viewing but permits publishing only
from loopback. Anyone who can reach TCP 60001 can view the camera, which is
usually appropriate only on a private robot LAN. Add a named MediaMTX user and
password before exposing this endpoint to an untrusted network.

## Compatibility Notes

- The deployment is pinned to MediaMTX 1.20.0 so config keys and asset names do
  not drift silently. Update the version only after checking the release notes.
- JetPack provides `nvvidconv` and `nvv4l2h264enc`. Do not install random
  upstream GStreamer packages over NVIDIA's matching L4T multimedia stack.
- NVIDIA's `nvv4l2camerasrc` is not used: NVIDIA documents it as verified for
  its own UYVY V4L2 sensor path, while the D435i USB color node supplies YUYV.
- Stock JetPack 6 has GStreamer 1.20.x, so the publisher uses RTSP. Direct WHIP
  publishing from GStreamer requires newer elements and offers no encoding
  advantage here.
- NVENC is a dedicated fixed-function engine; it does not consume CUDA cores.
  `nvvidconv` uses VIC by default here and is selected explicitly.

Primary references:

- [MediaMTX configuration reference](https://mediamtx.org/docs/references/configuration-file)
- [MediaMTX GStreamer publishing](https://mediamtx.org/docs/publish/gstreamer)
- [MediaMTX WebRTC details](https://mediamtx.org/docs/features/webrtc-specific-features)
- [NVIDIA accelerated GStreamer guide](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/SD/Multimedia/AcceleratedGstreamer.html)
