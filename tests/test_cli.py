import json

import pytest

from omatube import cli
from tests.test_catalog import SEARCH_ROW, WATCH_ROW, FakeClient


class FakePlayer:
    def __init__(self, props=None):
        self.commands, self.props = [], props or {}

    def command(self, *args):
        self.commands.append(args)

    def get(self, name, default=None):
        return self.props.get(name, default)

    def alive(self):
        return True


@pytest.fixture(autouse=True)
def runtime(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path))
    return tmp_path


def test_play_queues_the_radio_and_titles_each_song(monkeypatch, capsys, runtime):
    player = FakePlayer()
    monkeypatch.setattr(cli, "ensure_running", lambda: player)
    client = FakeClient(rows=[SEARCH_ROW], tracks=[SEARCH_ROW, WATCH_ROW])
    assert cli.main(["play", "around", "the", "world"], client_factory=lambda: client) == 0
    loads = [c for c in player.commands if c[0] == "loadfile"]
    assert [c[2] for c in loads] == ["append", "append"]
    assert loads[0][4] == "force-media-title=%30%Daft Punk – Around the World"
    # The old playlist goes first; the new one starts at its first song.
    assert player.commands[0] == ("stop",)
    assert player.commands[-2:] == [("playlist-play-index", 0), ("set_property", "pause", False)]
    assert "Around the World" in capsys.readouterr().out
    queued = json.loads((runtime / "omatube" / "queue.json").read_text())
    assert [t["video_id"] for t in queued] == ["Jb6gcoR266U", "wU26xVT_vBU"]


def test_play_with_nothing_found(capsys):
    assert cli.main(["play", "zzz"], client_factory=lambda: FakeClient()) == 1
    assert "nothing found" in capsys.readouterr().err


def test_search_lists_songs(capsys):
    cli.main(["search", "daft"], client_factory=lambda: FakeClient(rows=[SEARCH_ROW]))
    assert "Jb6gcoR266U    7:10  Daft Punk – Around the World" in capsys.readouterr().out


def test_status_line(capsys):
    player = FakePlayer({"idle-active": False, "pause": False, "media-title": "Daft Punk – Around the World",
                         "time-pos": 65.2, "duration": 430, "playlist-pos": 0, "playlist-count": 50, "volume": 80})
    cli.cmd_status(player)
    assert capsys.readouterr().out.strip() == "▶ Daft Punk – Around the World  1:05 / 7:10  [1/50]  vol 80"


def test_controls_map_to_mpv_commands(monkeypatch):
    player = FakePlayer({"idle-active": True})
    monkeypatch.setattr(cli, "Mpv", lambda sock: player)
    for argv in (["pause"], ["next"], ["prev"], ["vol", "150"]):
        cli.main(argv)
    assert player.commands == [("cycle", "pause"), ("playlist-next", "force"),
                               ("playlist-prev", "force"), ("set_property", "volume", 100)]


def test_player_not_running_is_a_clean_error(capsys):
    assert cli.main(["next"]) == 1
    assert "not running" in capsys.readouterr().err


def test_play_by_id_skips_the_search(monkeypatch):
    player = FakePlayer()
    monkeypatch.setattr(cli, "ensure_running", lambda: player)
    client = FakeClient(tracks=[WATCH_ROW, SEARCH_ROW])
    assert cli.main(["play", "--id", "wU26xVT_vBU"], client_factory=lambda: client) == 0
    assert client.calls == [("radio", "wU26xVT_vBU", True)]
    assert player.commands[1][1] == "https://music.youtube.com/watch?v=wU26xVT_vBU"


def test_play_needs_something_to_play():
    with pytest.raises(SystemExit):
        cli.main(["play"], client_factory=lambda: FakeClient())


def test_search_json_is_what_the_panel_reads(capsys):
    cli.main(["search", "--json", "daft"], client_factory=lambda: FakeClient(rows=[SEARCH_ROW]))
    rows = json.loads(capsys.readouterr().out)
    assert rows == [{"videoId": "Jb6gcoR266U", "title": "Around the World", "artists": ["Daft Punk"],
                     "album": "Homework", "seconds": 430, "label": "Daft Punk – Around the World",
                     "thumb": "https://i.ytimg.com/vi/Jb6gcoR266U/mqdefault.jpg"}]


def test_queue_json_after_play(monkeypatch, capsys):
    monkeypatch.setattr(cli, "ensure_running", lambda: FakePlayer())
    cli.main(["play", "x"], client_factory=lambda: FakeClient(rows=[SEARCH_ROW], tracks=[SEARCH_ROW, WATCH_ROW]))
    capsys.readouterr()
    monkeypatch.setattr(cli, "Mpv", lambda sock: FakePlayer())
    cli.main(["queue", "--json"])
    assert [r["videoId"] for r in json.loads(capsys.readouterr().out)] == ["Jb6gcoR266U", "wU26xVT_vBU"]


def test_queue_json_with_no_queue(monkeypatch, capsys):
    monkeypatch.setattr(cli, "Mpv", lambda sock: FakePlayer())
    cli.main(["queue", "--json"])
    assert json.loads(capsys.readouterr().out) == []


def played_queue(monkeypatch):
    monkeypatch.setattr(cli, "ensure_running", lambda: FakePlayer())
    cli.main(["play", "x"], client_factory=lambda: FakeClient(rows=[SEARCH_ROW], tracks=[SEARCH_ROW, WATCH_ROW]))


def test_the_saved_queue_starts_again_at_any_song_with_no_lookup(monkeypatch):
    played_queue(monkeypatch)
    player = FakePlayer()
    monkeypatch.setattr(cli, "ensure_running", lambda: player)
    def no_client():
        raise AssertionError("resuming the saved queue must not ask YouTube")
    assert cli.main(["play", "--from-queue", "1"], client_factory=no_client) == 0
    assert [c[1] for c in player.commands if c[0] == "loadfile"] == [
        "https://music.youtube.com/watch?v=Jb6gcoR266U", "https://music.youtube.com/watch?v=wU26xVT_vBU"]
    assert ("playlist-play-index", 1) in player.commands


def test_from_queue_out_of_range_or_empty(monkeypatch, capsys):
    monkeypatch.setattr(cli, "ensure_running", lambda: FakePlayer())
    assert cli.main(["play", "--from-queue", "0"]) == 1
    assert "no saved queue" in capsys.readouterr().err
    played_queue(monkeypatch)
    assert cli.main(["play", "--from-queue", "5"]) == 1
    assert "no song 6" in capsys.readouterr().err


def test_stop_keeps_the_saved_queue(monkeypatch, runtime):
    played_queue(monkeypatch)
    monkeypatch.setattr(cli, "Mpv", lambda sock: FakePlayer())
    cli.main(["stop"])
    assert (runtime / "omatube" / "queue.json").exists()


def test_status_says_stopped_when_mpv_is_not_running(capsys):
    assert cli.main(["status"]) == 0
    assert capsys.readouterr().out.strip() == "stopped"
