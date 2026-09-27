"""omatube: YouTube Music without a browser (ytmusicapi + mpv).

  omatube play <query>    search, play the first song and queue its radio
  omatube play --id <id>  play this song and queue its radio
  omatube play --from-queue <n>  play the saved queue again from song n (0-based)
  omatube search <query>  list matching songs (--json for the panel)
  omatube pause | next | prev | stop
  omatube vol <0-100>
  omatube status | queue
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path
from typing import Callable, Sequence

from . import catalog
from .catalog import Track
from .mpv import Mpv, PlayerError, ensure_running, quote_option, runtime_dir, socket_path


def queue_file() -> Path:
    return runtime_dir() / "queue.json"


def clock(seconds: float | None) -> str:
    s = int(seconds or 0)
    return f"{s // 60}:{s % 60:02d}"


def load_queue(player: Mpv, tracks: Sequence[Track], start: int = 0) -> None:
    """Replace mpv's playlist with these tracks and play from `start`.
    Appended, not loaded one by one: only the song at `start` is resolved."""
    player.command("stop")  # also clears the old playlist
    for t in tracks:
        player.command("loadfile", t.url, "append", -1, "force-media-title=" + quote_option(t.label))
    player.command("playlist-play-index", start)
    player.command("set_property", "pause", False)
    queue_file().write_text(json.dumps([asdict(t) for t in tracks]))


def cmd_play_saved(start: int) -> int:
    """The saved queue again (the player was stopped), from song `start`."""
    tracks = saved_queue()
    if not tracks:
        print("no saved queue", file=sys.stderr)
        return 1
    if not 0 <= start < len(tracks):
        print(f"no song {start + 1} in the saved queue", file=sys.stderr)
        return 1
    load_queue(ensure_running(), tracks, start)
    print(f"▶ {tracks[start].label}")
    return 0


def cmd_play(args: argparse.Namespace, client_factory: Callable[[], catalog.Client]) -> int:
    if args.from_queue is not None:
        return cmd_play_saved(args.from_queue)
    client = client_factory()
    if args.id:
        tracks = catalog.radio(client, args.id)
    else:
        found = catalog.search(client, args.query, limit=1)
        tracks = (catalog.radio(client, found[0].video_id) or found) if found else []
    if not tracks:
        print("nothing found", file=sys.stderr)
        return 1
    load_queue(ensure_running(), tracks)
    print(f"▶ {tracks[0].label}  (+{len(tracks) - 1} in the radio queue)")
    return 0


def cmd_search(args: argparse.Namespace, client_factory: Callable[[], catalog.Client]) -> int:
    found = catalog.search(client_factory(), args.query)
    if args.json:
        print(json.dumps([t.to_json() for t in found]))
        return 0
    for t in found:
        print(f"{t.video_id}  {clock(t.seconds):>6}  {t.label}")
    return 0


def cmd_status(player: Mpv) -> int:
    if not player.alive():
        print("stopped")
        return 0
    if player.get("idle-active", True):
        print("idle")
        return 0
    state = "⏸" if player.get("pause") else "▶"
    pos, count = player.get("playlist-pos", -1), player.get("playlist-count", 0)
    print(f"{state} {player.get('media-title', '')}  {clock(player.get('time-pos'))} / "
          f"{clock(player.get('duration'))}  [{pos + 1}/{count}]  vol {int(player.get('volume', 0))}")
    return 0


def saved_queue() -> list[Track]:
    try:
        rows = json.loads(queue_file().read_text())
        return [Track(**{**r, "artists": tuple(r["artists"])}) for r in rows]
    except (OSError, ValueError, TypeError, KeyError):
        return []


def cmd_queue(player: Mpv, as_json: bool = False) -> int:
    tracks = saved_queue()
    if as_json:
        print(json.dumps([t.to_json() for t in tracks]))
        return 0
    if not tracks:
        print("no queue")
        return 0
    pos = player.get("playlist-pos", -1)
    for i, t in enumerate(tracks):
        mark = "▶" if i == pos else " "
        print(f"{mark} {i + 1:>2}. {t.label}")
    return 0


def player_commands(player: Mpv, args: argparse.Namespace) -> int:
    if args.cmd == "pause":
        player.command("cycle", "pause")
    elif args.cmd == "next":
        player.command("playlist-next", "force")
    elif args.cmd == "prev":
        player.command("playlist-prev", "force")
    elif args.cmd == "vol":
        player.command("set_property", "volume", max(0, min(100, args.level)))
    elif args.cmd == "stop":
        # The queue stays saved: the panel plays it again from any song.
        player.command("quit")
        return 0
    elif args.cmd == "queue":
        return cmd_queue(player, args.json)
    return cmd_status(player)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="omatube", description="YouTube Music without a browser")
    sub = p.add_subparsers(dest="cmd", required=True)
    play = sub.add_parser("play")
    play.add_argument("--id", help="a YouTube Music video id")
    play.add_argument("--from-queue", type=int, metavar="N", help="play the saved queue from song N (0-based)")
    play.add_argument("query", nargs="*")
    search = sub.add_parser("search")
    search.add_argument("--json", action="store_true")
    search.add_argument("query", nargs="+")
    sub.add_parser("queue").add_argument("--json", action="store_true")
    for name in ("pause", "next", "prev", "stop", "status"):
        sub.add_parser(name)
    sub.add_parser("vol").add_argument("level", type=int)
    return p


def main(argv: Sequence[str] | None = None,
         client_factory: Callable[[], catalog.Client] = catalog.default_client) -> int:
    p = parser()
    args = p.parse_args(argv)
    if hasattr(args, "query"):
        args.query = " ".join(args.query)
    if args.cmd == "play" and not (args.id or args.query or args.from_queue is not None):
        p.error("play needs a query, --id or --from-queue")
    try:
        if args.cmd == "play":
            return cmd_play(args, client_factory)
        if args.cmd == "search":
            return cmd_search(args, client_factory)
        return player_commands(Mpv(socket_path()), args)
    except PlayerError as e:
        print(f"omatube: {e}", file=sys.stderr)
        return 1
    except Exception as e:  # network or YouTube answering oddly
        print(f"omatube: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
