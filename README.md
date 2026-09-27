# OmaTube

A spike: YouTube Music without a browser. Solfa drives the real
music.youtube.com page in a hidden Chromium (roughly 350–800 MB); this
asks YouTube Music's API directly (`ytmusicapi`) and plays the audio with
`mpv` + `yt-dlp` (about 60–75 MB while playing, nothing while stopped).

## Use

    bin/omatube play daft punk around the world   # plays it and queues its radio
    bin/omatube status | queue
    bin/omatube pause | next | prev | stop
    bin/omatube vol 60
    bin/omatube search <query>

mpv is the only background process: an idle, audio-only mpv with a control
socket at `$XDG_RUNTIME_DIR/omatube/mpv.sock`. `stop` quits it.

## Setup

    python3 -m venv .venv && .venv/bin/pip install ytmusicapi pytest pytest-cov
    .venv/bin/python -m pytest --cov=omatube

Needs `/usr/bin/mpv` and `yt-dlp` on the system.

## Not yet

- Sign-in (library, likes, playlists, personal radio). ytmusicapi can use
  browser cookies; the sign-in itself still needs a browser once.
- The Omarchy panel/bar: this is a CLI only.
- Lyrics, album/artist/playlist pages, the EQ.

## Known risk

Playback depends on yt-dlp keeping up with YouTube's stream protection.
When YouTube changes it, playback stops until yt-dlp is updated.
