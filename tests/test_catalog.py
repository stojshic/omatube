from omatube import catalog
from omatube.catalog import Track

SEARCH_ROW = {"videoId": "Jb6gcoR266U", "title": "Around the World", "duration_seconds": 430,
              "artists": [{"name": "Daft Punk", "id": "x"}], "album": {"name": "Homework", "id": "y"}}
WATCH_ROW = {"videoId": "wU26xVT_vBU", "title": "One More Time", "length": "5:21",
             "artists": [{"name": "Daft Punk", "id": "x"}]}


class FakeClient:
    def __init__(self, rows=None, tracks=None):
        self.rows, self.tracks, self.calls = rows or [], tracks or [], []

    def search(self, query, filter=None, limit=20):
        self.calls.append(("search", query, filter))
        return self.rows

    def get_watch_playlist(self, videoId, radio=False, limit=25):
        self.calls.append(("radio", videoId, radio))
        return {"tracks": self.tracks}


def test_a_search_row_becomes_a_track():
    t = catalog.track_from(SEARCH_ROW)
    assert t == Track("Jb6gcoR266U", "Around the World", ("Daft Punk",), "Homework", 430)
    assert t.url == "https://music.youtube.com/watch?v=Jb6gcoR266U"
    assert t.label == "Daft Punk – Around the World"


def test_a_watch_row_reads_its_length_text():
    assert catalog.track_from(WATCH_ROW).seconds == 321


def test_rows_without_a_video_are_dropped():
    client = FakeClient(rows=[{"title": "an artist card"}, SEARCH_ROW])
    assert [t.video_id for t in catalog.search(client, "daft")] == ["Jb6gcoR266U"]
    assert client.calls == [("search", "daft", "songs")]


def test_radio_asks_for_the_songs_radio():
    client = FakeClient(tracks=[SEARCH_ROW, WATCH_ROW])
    assert [t.video_id for t in catalog.radio(client, "Jb6gcoR266U")] == ["Jb6gcoR266U", "wU26xVT_vBU"]
    assert client.calls == [("radio", "Jb6gcoR266U", True)]


def test_lengths():
    assert catalog.parse_length("1:02:03") == 3723
    assert catalog.parse_length("") == 0
    assert catalog.parse_length("live") == 0


def test_a_label_without_artists_is_the_title():
    assert Track("v", "Just a title", ()).label == "Just a title"
