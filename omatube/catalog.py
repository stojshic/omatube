"""YouTube Music's catalog, asked directly through its own API (ytmusicapi).

No browser: search and radio are plain InnerTube requests. Results become
Track values, the only shape the rest of the app sees.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

WATCH_URL = "https://music.youtube.com/watch?v="


@dataclass(frozen=True)
class Track:
    video_id: str
    title: str
    artists: tuple[str, ...]
    album: str = ""
    seconds: int = 0

    @property
    def url(self) -> str:
        return WATCH_URL + self.video_id

    @property
    def thumb(self) -> str:
        return f"https://i.ytimg.com/vi/{self.video_id}/mqdefault.jpg"

    def to_json(self) -> dict[str, Any]:
        return {"videoId": self.video_id, "title": self.title, "artists": list(self.artists),
                "album": self.album, "seconds": self.seconds, "label": self.label, "thumb": self.thumb}

    @property
    def label(self) -> str:
        who = ", ".join(self.artists)
        return f"{who} – {self.title}" if who else self.title


class Client(Protocol):
    def search(self, query: str, filter: str | None = None, limit: int = 20) -> list[dict[str, Any]]: ...
    def get_watch_playlist(self, videoId: str, radio: bool = False, limit: int = 25) -> dict[str, Any]: ...


def parse_length(text: str | None) -> int:
    """'5:21' or '1:02:03' as seconds; anything else is 0."""
    if not text:
        return 0
    try:
        seconds = 0
        for part in text.split(":"):
            seconds = seconds * 60 + int(part)
        return seconds
    except ValueError:
        return 0


def _artists(raw: dict[str, Any]) -> tuple[str, ...]:
    return tuple(a["name"] for a in raw.get("artists") or [] if a and a.get("name"))


def _album(raw: dict[str, Any]) -> str:
    album = raw.get("album")
    return str(album.get("name") or "") if isinstance(album, dict) else ""


def track_from(raw: dict[str, Any]) -> Track | None:
    """A search row or a watch-playlist row as a Track; None when unplayable."""
    video_id = raw.get("videoId")
    if not video_id:
        return None
    seconds = raw.get("duration_seconds")
    return Track(
        video_id=str(video_id),
        title=str(raw.get("title") or ""),
        artists=_artists(raw),
        album=_album(raw),
        seconds=int(seconds) if isinstance(seconds, int) else parse_length(raw.get("length") or raw.get("duration")),
    )


def _tracks(rows: list[dict[str, Any]]) -> list[Track]:
    return [t for t in (track_from(r) for r in rows) if t is not None]


def search(client: Client, query: str, limit: int = 10) -> list[Track]:
    return _tracks(client.search(query, filter="songs", limit=limit))[:limit]


def radio(client: Client, video_id: str, limit: int = 25) -> list[Track]:
    """The song's radio: the song itself first, then what YouTube picks after it."""
    return _tracks(client.get_watch_playlist(videoId=video_id, radio=True, limit=limit).get("tracks") or [])


def default_client() -> Client:
    from ytmusicapi import YTMusic
    return YTMusic()
