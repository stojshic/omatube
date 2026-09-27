import json
import socket
import threading

import pytest

from omatube.mpv import Mpv, PlayerError, mpv_argv, mpv_env, quote_option


class FakeMpv:
    """A socket that answers like mpv: an event first, then the reply."""

    def __init__(self, path, reply):
        self.received = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen()
        self.reply = reply
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                req = json.loads(conn.makefile().readline())
                self.received.append(req["command"])
                event = json.dumps({"event": "playback-restart"}) + "\n"
                answer = json.dumps({**self.reply, "request_id": req["request_id"]}) + "\n"
                conn.sendall((event + answer).encode())


def test_a_command_gets_its_own_reply_past_events(tmp_path):
    sock = tmp_path / "mpv.sock"
    fake = FakeMpv(sock, {"error": "success", "data": 42})
    assert Mpv(sock).command("get_property", "volume") == 42
    assert fake.received == [["get_property", "volume"]]


def test_an_mpv_error_is_raised(tmp_path):
    sock = tmp_path / "mpv.sock"
    FakeMpv(sock, {"error": "property unavailable"})
    with pytest.raises(PlayerError, match="property unavailable"):
        Mpv(sock).command("get_property", "duration")
    assert Mpv(sock).get("duration", "none") == "none"


def test_no_player_running(tmp_path):
    player = Mpv(tmp_path / "missing.sock")
    assert player.alive() is False
    with pytest.raises(PlayerError, match="not running"):
        player.command("quit")


def test_mpv_runs_audio_only_and_idle(tmp_path):
    argv = mpv_argv(tmp_path / "s")
    assert "--no-video" in argv and "--idle=yes" in argv
    assert f"--input-ipc-server={tmp_path / 's'}" in argv


def test_titles_are_quoted_by_byte_length():
    assert quote_option("a, b=c") == "%6%a, b=c"
    assert quote_option("Björk") == "%6%Björk"


def test_the_stream_cache_is_capped_for_audio(tmp_path):
    # mpv's defaults (150 MiB ahead, 50 MiB behind) are sized for video;
    # an audio stream needs a small fraction of that.
    argv = mpv_argv(tmp_path / "s")
    assert "--demuxer-max-bytes=16MiB" in argv
    assert "--demuxer-max-back-bytes=4MiB" in argv


def test_mpv_keeps_few_malloc_arenas(monkeypatch):
    # Measured: 8 songs grew mpv from 61 to 112 MB with glibc's default
    # arenas, and held it near 74 MB with two.
    monkeypatch.setenv("HOME", "/home/x")
    env = mpv_env()
    assert env["MALLOC_ARENA_MAX"] == "2"
    assert env["HOME"] == "/home/x"
