#!/usr/bin/env python3
"""Compatibility front end for Teleimager clients and MediaMTX."""

import argparse
import json
import logging
import signal
import ssl
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import zmq


LOG = logging.getLogger("teleimager-compat")
MAX_REQUEST_BYTES = 1024 * 1024
PROXY_REQUEST_HEADERS = (
    "Accept",
    "Authorization",
    "Content-Type",
    "If-Match",
    "Origin",
    "Access-Control-Request-Headers",
    "Access-Control-Request-Method",
)
PROXY_RESPONSE_HEADERS = (
    "Content-Type",
    "Location",
    "ETag",
    "Link",
    "Accept-Post",
    "Accept-Patch",
    "Access-Control-Allow-Origin",
    "Access-Control-Allow-Headers",
    "Access-Control-Allow-Methods",
    "Access-Control-Expose-Headers",
    "Cache-Control",
)


class ClientError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class CompatibilityHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, upstream, stream_path):
        super().__init__(address, CompatibilityHandler)
        self.upstream = upstream.rstrip("/")
        self.stream_path = stream_path.strip("/")
        if not self.stream_path:
            raise ValueError("stream path must not be empty")

        parsed = urlsplit(self.upstream)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError("upstream must be an absolute HTTP(S) URL")

        self.upstream_ssl_context = None
        if parsed.scheme == "https":
            if parsed.hostname in ("127.0.0.1", "::1", "localhost"):
                # MediaMTX presents the public certificate on loopback, where
                # its hostname normally does not match the certificate SAN.
                self.upstream_ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                self.upstream_ssl_context.check_hostname = False
                self.upstream_ssl_context.verify_mode = ssl.CERT_NONE
            else:
                self.upstream_ssl_context = ssl.create_default_context()


class CompatibilityHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "teleimager-compat/1"

    def do_GET(self):
        if urlsplit(self.path).path == "/":
            self._proxy(f"/{self.server.stream_path}/")
            return
        if self._redirect_player():
            return
        self._proxy()

    def do_HEAD(self):
        if urlsplit(self.path).path == "/":
            self._proxy(f"/{self.server.stream_path}/")
            return
        if self._redirect_player():
            return
        self._proxy()

    def do_POST(self):
        if urlsplit(self.path).path == "/offer":
            self._handle_offer()
            return
        self._proxy()

    def do_PATCH(self):
        self._proxy()

    def do_DELETE(self):
        self._proxy()

    def do_OPTIONS(self):
        if urlsplit(self.path).path == "/offer":
            self.send_response(204)
            self._send_offer_cors_headers()
            self.end_headers()
            return
        self._proxy()

    def _redirect_player(self):
        path = urlsplit(self.path).path
        if path != f"/{self.server.stream_path}":
            return False
        self.send_response(302)
        self.send_header("Location", f"/{self.server.stream_path}/")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return True

    def _read_body(self):
        if self.headers.get("Transfer-Encoding"):
            raise ClientError(501, "chunked request bodies are not supported")

        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return b""
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise ClientError(400, "invalid Content-Length") from exc
        if length < 0 or length > MAX_REQUEST_BYTES:
            raise ClientError(413, "request body is too large")
        return self.rfile.read(length)

    def _handle_offer(self):
        try:
            body = self._read_body()
            payload = json.loads(body)
            if payload.get("type") != "offer":
                raise ClientError(400, "type must be 'offer'")
            offer = payload.get("sdp")
            if not isinstance(offer, str) or not offer:
                raise ClientError(400, "sdp must be a non-empty string")
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json_error(400, "request body must be valid JSON", offer_cors=True)
            return
        except (AttributeError, ClientError) as exc:
            status = exc.status if isinstance(exc, ClientError) else 400
            message = exc.message if isinstance(exc, ClientError) else "request JSON must be an object"
            self._send_json_error(status, message, offer_cors=True)
            return

        target = f"/{self.server.stream_path}/whep"
        try:
            status, _headers, answer = self._upstream_request(
                "POST",
                target,
                offer.encode("utf-8"),
                {"Accept": "application/sdp", "Content-Type": "application/sdp"},
            )
        except urllib.error.URLError as exc:
            LOG.warning("WHEP upstream unavailable: %s", exc.reason)
            self._send_json_error(502, "WebRTC signaling service is unavailable", offer_cors=True)
            return

        if status not in (200, 201):
            detail = answer.decode("utf-8", errors="replace").strip()
            LOG.warning("WHEP offer failed with status %d: %.300s", status, detail)
            self._send_json_error(502, f"WebRTC offer failed (upstream status {status})", offer_cors=True)
            return

        try:
            answer_sdp = answer.decode("utf-8")
        except UnicodeDecodeError:
            self._send_json_error(502, "WebRTC service returned invalid SDP", offer_cors=True)
            return
        if not answer_sdp:
            self._send_json_error(502, "WebRTC service returned empty SDP", offer_cors=True)
            return

        response = json.dumps(
            {"sdp": answer_sdp, "type": "answer"}, separators=(",", ":")
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self._send_offer_cors_headers()
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def _proxy(self, target=None):
        try:
            body = self._read_body()
            request_headers = {
                name: self.headers[name]
                for name in PROXY_REQUEST_HEADERS
                if self.headers.get(name) is not None
            }
            target = self.path if target is None else target
            parsed = urlsplit(target)
            if parsed.path == "/whep":
                target = urlunsplit(
                    ("", "", f"/{self.server.stream_path}/whep", parsed.query, "")
                )
            status, headers, response = self._upstream_request(
                self.command, target, body, request_headers
            )
        except ClientError as exc:
            self._send_json_error(exc.status, exc.message)
            return
        except urllib.error.URLError as exc:
            LOG.warning("MediaMTX upstream unavailable: %s", exc.reason)
            self._send_json_error(502, "MediaMTX is unavailable")
            return

        self.send_response(status)
        for name in PROXY_RESPONSE_HEADERS:
            for value in headers.get_all(name, []):
                if name.lower() == "location":
                    value = self._external_location(value)
                self.send_header(name, value)
        if status not in (204, 304):
            self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        if self.command != "HEAD" and response:
            self.wfile.write(response)

    def _upstream_request(self, method, target, body, headers):
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path.startswith("/"):
            raise ClientError(400, "invalid request target")
        target = urlunsplit(("", "", parsed.path, parsed.query, ""))

        data = body if method in ("POST", "PATCH", "PUT") else None
        request = urllib.request.Request(
            self.server.upstream + target,
            data=data,
            headers=headers,
            method=method,
        )
        kwargs = {"timeout": 10}
        if self.server.upstream_ssl_context is not None:
            kwargs["context"] = self.server.upstream_ssl_context
        try:
            with urllib.request.urlopen(request, **kwargs) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as exc:
            return exc.code, exc.headers, exc.read()

    def _external_location(self, value):
        if value.startswith(self.server.upstream):
            return value[len(self.server.upstream) :] or "/"
        return value

    def _send_json_error(self, status, message, offer_cors=False):
        response = json.dumps({"error": message}, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if offer_cors:
            self._send_offer_cors_headers()
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def _send_offer_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def log_message(self, fmt, *args):
        LOG.info("%s - %s", self.address_string(), fmt % args)


class ConfigResponder:
    def __init__(self, config, host, port):
        self.config = config
        self.endpoint = f"tcp://{host}:{port}"
        self.stop_event = threading.Event()
        self.ready_event = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self._run, name="config-responder", daemon=True)

    def start(self):
        self.thread.start()
        if not self.ready_event.wait(timeout=5):
            raise RuntimeError("timed out starting camera config responder")
        if self.error is not None:
            raise RuntimeError(f"could not start camera config responder: {self.error}")

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=2)

    def _run(self):
        context = zmq.Context()
        socket = context.socket(zmq.REP)
        socket.setsockopt(zmq.LINGER, 0)
        poller = zmq.Poller()
        try:
            socket.bind(self.endpoint)
            poller.register(socket, zmq.POLLIN)
            self.ready_event.set()
            LOG.info("camera config responder listening on %s", self.endpoint)
            while not self.stop_event.is_set():
                events = dict(poller.poll(timeout=250))
                if events.get(socket) == zmq.POLLIN:
                    socket.recv()
                    socket.send_json(self.config)
        except Exception as exc:
            self.error = exc
            self.ready_event.set()
            LOG.exception("camera config responder failed")
        finally:
            socket.close()
            context.term()


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", default=60001, type=int)
    parser.add_argument("--upstream", default="https://127.0.0.1:8889")
    parser.add_argument("--stream-path", default="d435")
    parser.add_argument("--config-listen", default="0.0.0.0")
    parser.add_argument("--config-port", default=60000, type=int)
    parser.add_argument("--camera-config", default="/etc/teleimager/compat-camera.json")
    parser.add_argument("--cert", default="/etc/mediamtx/tls/server.crt")
    parser.add_argument("--key", default="/etc/mediamtx/tls/server.key")
    return parser.parse_args()


def load_camera_config(path):
    with Path(path).open("r", encoding="utf-8") as source:
        config = json.load(source)
    for camera in ("head_camera", "left_wrist_camera", "right_wrist_camera"):
        if camera not in config:
            raise ValueError(f"camera config is missing {camera}")
    return config


def main():
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    camera_config = load_camera_config(args.camera_config)
    server = CompatibilityHTTPServer(
        (args.listen, args.port), args.upstream, args.stream_path
    )
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
    tls_context.load_cert_chain(args.cert, args.key)
    server.socket = tls_context.wrap_socket(server.socket, server_side=True)

    responder = ConfigResponder(camera_config, args.config_listen, args.config_port)
    try:
        responder.start()
    except Exception:
        server.server_close()
        raise

    def request_shutdown(signum, _frame):
        LOG.info("received signal %d, shutting down", signum)
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_shutdown)
    signal.signal(signal.SIGINT, request_shutdown)

    LOG.info(
        "HTTPS compatibility listener on %s:%d, MediaMTX upstream %s",
        args.listen,
        args.port,
        args.upstream,
    )
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        responder.stop()
        server.server_close()


if __name__ == "__main__":
    main()
