"""Bounded test of synthetic media, never an actual desktop capture."""
import argparse
import http.server
import ipaddress
import json
import pathlib
import secrets
import socket
import threading
import time
import uuid

import pychromecast
from pychromecast.models import CastInfo
from pychromecast.discovery import ServiceInfo


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--movie", type=pathlib.Path, required=True)
    args = parser.parse_args()
    host = str(ipaddress.IPv4Address(args.host))
    if not any(ipaddress.ip_address(host) in ipaddress.ip_network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        parser.error("Use a local private IPv4 address")
    # Refuse arbitrary videos: this command serves only our generated synthetic fixture.
    movie = args.movie.resolve()
    if movie.name != "synthetic-test.mp4" or not movie.is_file():
        parser.error("Expected generated synthetic-test.mp4")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect((host, 8009))
        local = probe.getsockname()[0]
    path = "/" + secrets.token_urlsafe(32) + "/synthetic-test.mp4"
    fetched = threading.Event()
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.client_address[0] != host or self.path != path:
                self.send_error(404)
                return
            data = movie.read_bytes()
            start, end = 0, len(data) - 1
            if self.headers.get("Range"):
                value = self.headers["Range"]
                try:
                    first, last = value.removeprefix("bytes=").split("-")
                    if not value.startswith("bytes=") or "," in value or not first:
                        raise ValueError()
                    start = int(first)
                    end = min(int(last), end) if last else end
                    if not 0 <= start <= end:
                        raise ValueError()
                except ValueError:
                    self.send_error(416)
                    return
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            else:
                self.send_response(200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(data[start:end + 1])
            requests.append({"peer": self.client_address[0], "bytes": end - start + 1})
            fetched.set()

        def log_message(self, *_):
            pass  # The session URL contains a secret and must not be logged.

    info = CastInfo({ServiceInfo("host", (host, 8009))}, uuid.UUID("a6ea996f-85c9-44e9-9ea5-78f4d85b0e26"),
                    "AirReceiver", "SharkTV", host, 8009, "cast", "AirReceiver")
    cast = pychromecast.Chromecast(info, tries=1, timeout=5, retry_wait=1)
    server = None
    launched = False
    try:
        cast.wait(timeout=6)
        # Do not replace somebody's ongoing session.
        if cast.status is None or cast.status.app_id is not None:
            raise RuntimeError("Receiver is busy or status is unknown; no playback was started")
        server = http.server.ThreadingHTTPServer((local, 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://{local}:{server.server_port}{path}"
        launched = True
        cast.socket_client.receiver_controller.launch_app("CC1AD845")
        launch_deadline = time.monotonic() + 8
        while time.monotonic() < launch_deadline:
            if cast.status and cast.status.app_id == "CC1AD845" and "urn:x-cast:com.google.cast.media" in cast.status.namespaces:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("Default media receiver did not become ready")
        cast.media_controller.play_media(url, "video/mp4", title="BlueScreen: synthetic test, no captured screen")
        deadline = time.monotonic() + 20
        played = False
        states = []
        while time.monotonic() < deadline:
            cast.media_controller.update_status()
            time.sleep(0.5)
            state = cast.media_controller.status
            states.append({"state": state.player_state, "position": state.current_time})
            if fetched.is_set() and state.player_state == "PLAYING" and state.current_time >= 1:
                played = True
                break
        print(json.dumps({"host": host, "synthetic_only": True, "fetched": fetched.is_set(),
                          "playback_confirmed": played, "requests": requests, "states": states}, indent=2))
        if not played:
            raise RuntimeError("Playback of the synthetic clip was not confirmed")
    finally:
        try:
            if launched and cast.status and cast.status.app_id == "CC1AD845" and cast.socket_client.is_connected:
                cast.quit_app()
        finally:
            cast.disconnect()
            if server:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    main()
