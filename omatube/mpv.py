"""mpv as the player: one idle, audio-only process driven over its JSON IPC socket.

mpv's own yt-dlp hook turns each music.youtube.com URL into an audio stream
when it is reached in the playlist, so a queue costs nothing until it plays.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import time
from pathlib import Path
from typing import Any

MPV = "/usr/bin/mpv"
CONNECT_TIMEOUT_S = 5.0
REPLY_TIMEOUT_S = 5.0


class PlayerError(RuntimeError):
    pass


def runtime_dir() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/omatube-{os.getuid()}"
    path = Path(base) / "omatube"
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def socket_path() -> Path:
    return runtime_dir() / "mpv.sock"


def mpv_argv(sock: Path) -> list[str]:
    return [
        MPV,
        "--idle=yes",
        "--no-video",
        "--no-terminal",
        "--force-window=no",
        f"--input-ipc-server={sock}",
        "--ytdl-format=bestaudio/best",
        # Resolve the next song while this one plays, so there is no gap.
        "--prefetch-playlist=yes",
        # mpv sizes its stream cache for video (150 MiB ahead, 50 MiB
        # behind); 16 MiB is still minutes of audio at 160 kbps.
        "--demuxer-max-bytes=16MiB",
        "--demuxer-max-back-bytes=4MiB",
    ]


def mpv_env() -> dict[str, str]:
    """The environment mpv starts with. Two malloc arenas: with glibc's
    default, memory freed after each song is kept rather than reused, and
    mpv grew about 6 MB a song (61 to 112 MB over 8 songs); with two it
    held near 74 MB."""
    return {**os.environ, "MALLOC_ARENA_MAX": "2"}


def quote_option(value: str) -> str:
    """mpv's %len% quoting, so a title with commas or '=' stays one value."""
    return f"%{len(value.encode())}%{value}"


class Mpv:
    """A JSON IPC client for one request at a time."""

    def __init__(self, sock: Path) -> None:
        self.sock = sock
        self._next_id = 1

    def command(self, *args: Any) -> Any:
        request_id = self._next_id
        self._next_id += 1
        payload = json.dumps({"command": list(args), "request_id": request_id}) + "\n"
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(REPLY_TIMEOUT_S)
                s.connect(str(self.sock))
                s.sendall(payload.encode())
                return self._reply(s, request_id)
        except (ConnectionRefusedError, FileNotFoundError) as e:
            raise PlayerError("the player is not running") from e
        except socket.timeout as e:
            raise PlayerError("the player did not answer") from e

    @staticmethod
    def _reply(s: socket.socket, request_id: int) -> Any:
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                raise PlayerError("the player closed the connection")
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                msg = json.loads(line)
                if msg.get("request_id") != request_id:
                    continue  # an event, or someone else's reply
                if msg.get("error") != "success":
                    raise PlayerError(str(msg.get("error")))
                return msg.get("data")

    def get(self, name: str, default: Any = None) -> Any:
        try:
            return self.command("get_property", name)
        except PlayerError:
            return default

    def alive(self) -> bool:
        try:
            self.command("get_property", "idle-active")
            return True
        except PlayerError:
            return False


def ensure_running(sock: Path | None = None) -> Mpv:
    """The running player, started (detached) if there is none."""
    sock = sock or socket_path()
    player = Mpv(sock)
    if player.alive():
        return player
    sock.unlink(missing_ok=True)
    subprocess.Popen(mpv_argv(sock), env=mpv_env(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    deadline = time.monotonic() + CONNECT_TIMEOUT_S
    while time.monotonic() < deadline:
        if player.alive():
            return player
        time.sleep(0.05)
    raise PlayerError("the player did not start")
