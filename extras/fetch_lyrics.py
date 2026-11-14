#!/usr/bin/env python3
"""Lyrics for one track, for the panel's Alt+L view.

One subprocess answers the whole question, in the order a track's lyrics are
actually likely to be found:

  1. the lyrics embedded in the file itself,
  2. a .lrc or .txt sitting beside it,
  3. the shared ~/.lyrics cache,
  4. lrclib.net, which is written into that cache.

With --offline the last step is skipped: only what is already on this machine
answers, and a miss says so without touching the network. That is what the
player's "Fetch lyrics" setting turns off.

The answer is a single JSON object on stdout and nothing else, so the panel has
one thing to parse. Diagnostics go to stderr, where they cannot corrupt it.

    fetch_lyrics.py --music-dir DIR --file REL [--artist A] [--title T]
                    [--album B] [--duration SECONDS] [--offline]

REL is library-relative, the way MPD reports it. The optional tag values are
what MPD already knows, used when the file cannot be read (a cue sheet's
"album.cue/track1", or a file whose tags the player got from the folder name).
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from mutagen import File as MutagenFile
except Exception:  # noqa: BLE001 - no tag reader only costs embedded lyrics
    MutagenFile = None

APP = "GrimPlayer"
CONTACT = "https://github.com/skollgrim/grimplayer"
LRCLIB_GET = "https://lrclib.net/api/get"
LRCLIB_SEARCH = "https://lrclib.net/api/search"
TIMEOUT = 15

# The cache the user asked for, and the one the player has always read. Kept as
# a plain home-relative path rather than an XDG data dir so the files stay where
# they are easy to find and edit by hand.
LYRICS_DIR = os.path.join(os.path.expanduser("~"), ".lyrics")


def plugin_version():
    manifest = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "manifest.json")
    try:
        with open(manifest, "r", encoding="utf-8") as fh:
            return str(json.load(fh).get("version") or "unknown")
    except (OSError, ValueError):
        return "unknown"


USER_AGENT = "%s/%s ( %s )" % (APP, plugin_version(), CONTACT)


def out(payload):
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def fail(message):
    print(message, file=sys.stderr)
    out({"status": "none", "message": str(message)})
    sys.exit(0)


def clean_text(value):
    """A tag value as text. Mutagen hands back frames, lists, or plain strings."""
    if value is None:
        return ""
    if isinstance(value, (list, tuple)):
        parts = [clean_text(v) for v in value]
        return "\n".join(p for p in parts if p)
    text = getattr(value, "text", value)
    if text is not value:
        return clean_text(text)
    return str(value)


def embedded_lyrics(path):
    """The lyrics already tagged into the file, if any."""
    if MutagenFile is None:
        return ""
    try:
        audio = MutagenFile(path)
    except Exception:  # noqa: BLE001 - an unreadable file simply has none
        return ""
    tags = getattr(audio, "tags", None)
    if not tags:
        return ""
    keys = {
        "lyrics", "unsyncedlyrics", "unsynced lyrics", "unsynced lyric",
        "lyric", "©lyr", "lyr", "txxx:lyrics", "txxx:unsyncedlyrics",
    }
    found = []
    try:
        items = tags.items()
    except Exception:  # noqa: BLE001
        return ""
    for key, value in items:
        name = str(key).lower()
        if name.startswith("uslt") or name in keys:
            text = clean_text(value).strip()
            if text:
                found.append(text)
    return "\n".join(found)


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def sidecar_lyrics(path):
    """A .lrc or .txt next to the track, with the audio extension swapped."""
    base = os.path.splitext(path)[0]
    for ext in (".lrc", ".txt"):
        text = read_text(base + ext)
        if text:
            return text
    return ""


def safe_name(name):
    """A track title as a filename: no separators, no control characters."""
    name = re.sub(r"[/\\\x00-\x1f]+", "-", str(name or ""))
    name = re.sub(r"\s+", " ", name).strip(" .")
    return name or "Unknown"


def cache_paths(artist, title):
    """The cache stems (no extension) this track may have been saved under.

    The first is what this script writes. The rest cover titles MPD carries a
    parenthetical or a featured credit on, which earlier runs may have filed
    under the shorter name. The extension is chosen at write time: .lrc for
    synced lyrics, .txt for plain ones.
    """
    names = [title]
    short = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]\s*$", "", title).strip()
    if short and short != title:
        names.append(short)
    paths = []
    for name in names:
        path = os.path.join(LYRICS_DIR, "%s - %s" % (safe_name(artist),
                                                     safe_name(name)))
        if path not in paths:
            paths.append(path)
    return paths


def looks_synced(text):
    """True when the text carries LRC timestamps."""
    return bool(re.search(r"\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\]", text or ""))


def cached_lyrics(artist, title):
    for base in cache_paths(artist, title):
        for ext in (".lrc", ".txt"):
            text = read_text(base + ext)
            if text:
                return text
    return ""


def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in (0, 1):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                return json.loads(response.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as exc:
            # lrclib answers 429/503 when a burst arrives too fast. One short
            # retry rides that out; anything else is simply "no lyrics here".
            if exc.code not in (429, 503) or attempt == 1:
                return None
            time.sleep(1)
        except Exception:  # noqa: BLE001 - no network is just "no lyrics here"
            return None
    return None


def lyrics_of(entry):
    """Synced lyrics first: the panel highlights the current line and follows
    it. The timestamps are stripped for display, so a synced file reads exactly
    like a plain one. Plain is the fallback for recordings lrclib only has that
    way."""
    if not isinstance(entry, dict):
        return ""
    return (str(entry.get("syncedLyrics") or "").strip()
            or str(entry.get("plainLyrics") or "").strip())


def search_lrclib(artist, title, album, duration):
    """The best lrclib answer for this track, or an empty string.

    The exact endpoint is tried first, with the album and duration as extra
    discriminators. A miss falls back to a text search, which is how covers,
    live versions and lightly different titles still find something.
    """
    if not artist or not title:
        return ""
    params = {"artist_name": artist, "track_name": title}
    if album:
        params["album_name"] = album
    if duration:
        # lrclib's exact endpoint takes whole seconds; a fractional MPD duration
        # ("242.5") is rejected outright, which would quietly skip this endpoint
        # on every track whose length is not a round number.
        seconds = int(round(duration))
        if seconds > 0:
            params["duration"] = str(seconds)
    exact = fetch_json(LRCLIB_GET + "?" + urllib.parse.urlencode(params))
    text = lyrics_of(exact)
    if text:
        return text

    query = {"track_name": title, "artist_name": artist}
    results = fetch_json(LRCLIB_SEARCH + "?" + urllib.parse.urlencode(query))
    if not isinstance(results, list):
        return ""
    best = ""
    for entry in results:
        text = lyrics_of(entry)
        if not text:
            continue
        # A result with the right duration is the same recording; take it and
        # stop. Otherwise keep the first result that has any lyrics at all.
        if duration and entry.get("duration"):
            try:
                if abs(float(entry["duration"]) - duration) <= 2:
                    return text
            except (TypeError, ValueError):
                pass
        if not best:
            best = text
    return best


def save_cache(artist, title, text):
    """Write the lyrics to ~/.lyrics/<Artist> - <Title>.{lrc,txt}, atomically,
    so a half-written file is never read back by the next toggle.

    Synced lyrics go in .lrc so the panel can highlight and follow them; plain
    lyrics go in .txt. The other extension is removed once the new file is in
    place: readers try .lrc first, so a stale .lrc would shadow freshly written
    plain lyrics forever. Only the same stem is touched -- longer titles are
    tried before shorter ones, so their copies cannot shadow this one.
    """
    ext = ".lrc" if looks_synced(text) else ".txt"
    base = cache_paths(artist, title)[0]
    path = base + ext
    stale = base + (".txt" if ext == ".lrc" else ".lrc")
    try:
        os.makedirs(LYRICS_DIR, exist_ok=True)
        temp = path + ".tmp"
        with open(temp, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(temp, path)
        try:
            os.remove(stale)
        except OSError:
            pass
    except OSError as exc:
        print("Could not write %s: %s" % (path, exc), file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--music-dir", default="")
    parser.add_argument("--file", default="")
    parser.add_argument("--artist", default="")
    parser.add_argument("--title", default="")
    parser.add_argument("--album", default="")
    parser.add_argument("--duration", default="")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()

    rel = str(args.file or "").strip()
    if not rel:
        fail("No file given")

    # MPD's cue tracks are named "album.cue/track1"; the audio file is the cue
    # itself and has no per-track tags. Keep the name for the reply, but let the
    # MPD-provided artist/title carry the lookup.
    #
    # The path arrives on a command line, so it is checked rather than trusted:
    # an absolute path or one climbing out with ".." must not have this script
    # read a file outside the library.
    music_dir = os.path.normpath(os.path.expanduser(str(args.music_dir or "")))
    path = os.path.normpath(os.path.join(music_dir, rel))
    if os.path.isabs(rel) or (path != music_dir
                              and not path.startswith(music_dir + os.sep)):
        fail("File path is not library-relative: %s" % rel)
    exists = os.path.isfile(path)

    artist = str(args.artist or "").strip()
    title = str(args.title or "").strip()
    album = str(args.album or "").strip()
    try:
        duration = float(str(args.duration or "").strip())
    except (TypeError, ValueError):
        duration = 0.0
    if duration <= 0:
        duration = 0.0

    if exists and MutagenFile is not None:
        try:
            audio = MutagenFile(path, easy=True)
        except Exception:  # noqa: BLE001
            audio = None
        tags = getattr(audio, "tags", None) or {}
        artist = (clean_text(tags.get("artist")).strip()
                  or clean_text(tags.get("albumartist")).strip()
                  or artist)
        title = clean_text(tags.get("title")).strip() or title
        album = clean_text(tags.get("album")).strip() or album

    reply = {"status": "none", "file": rel}

    text = embedded_lyrics(path) if exists else ""
    if text:
        # File the embedded lyrics in the shared cache so the next open is a
        # local read and does not need this script at all.
        if artist and title:
            save_cache(artist, title, text)
        reply.update(status="ok", source="embedded", lyrics=text)
        out(reply)
        return

    text = sidecar_lyrics(path) if exists else ""
    if text:
        reply.update(status="ok", source="sidecar", lyrics=text)
        out(reply)
        return

    if artist and title:
        text = cached_lyrics(artist, title)
        if text:
            reply.update(status="ok", source="cache", lyrics=text)
            out(reply)
            return

    if not artist or not title:
        fail("Not enough tags to search for lyrics")

    if args.offline:
        fail("No lyrics on disk for %s - %s" % (artist, title))

    text = search_lrclib(artist, title, album, duration)
    if not text:
        fail("No lyrics found for %s - %s" % (artist, title))

    save_cache(artist, title, text)
    reply.update(status="ok", source="lrclib", lyrics=text)
    out(reply)


if __name__ == "__main__":
    main()
