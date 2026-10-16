#!/usr/bin/env python3
"""Look an album up on MusicBrainz and fetch a front cover.

Called by the GrimPlayer service as one subprocess per lookup, with the album's
files handed over so the answer is about the selection the editor is showing and
not whatever happens to sit in a folder. The result is a single JSON object on
stdout, so the service has one thing to parse and the diagnostics stay on stderr
where they cannot corrupt it.

    lookup.py --music-dir DIR --file REL [--file REL ...] [--release MBID]

With no --release the files' own artist/album tags are searched and the best of
the matches is detailed; with --release that release is fetched directly, which
is how the editor walks on to the next candidate without searching again.

The cover is not taken from MusicBrainz. The Cover Art Archive is tied to the
release, which makes it the honest source, but it is community scans -- white
borders, odd crops, a photo of a CD on a table. The two stores (iTunes, then
Deezer) serve clean, square, well-lit artwork, so they are asked first and the
archive is only consulted when neither has a confident match. Each source is
queried for the size the caller wants, since none of them will let a local
resize happen and every one of them will serve a scaled copy for free:

    lookup.py --cover-only --artist A --album B [--year Y] [--tracks N]
                                  [--size 600] --cover-out PATH

That second mode exists for the player itself: an album with no sidecar and no
embedded picture asks for a display-sized cover, with no MusicBrainz round trip
and no dependency on the tagging libraries.
"""
import argparse
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

musicbrainzngs = None
MutagenFile = None
_IMPORT_ERROR = None
try:
    import musicbrainzngs
    from mutagen import File as MutagenFile
except Exception as exc:  # noqa: BLE001 - reported as a status, not a traceback
    _IMPORT_ERROR = exc

APP = "GrimPlayer"
CONTACT = "https://github.com/skollgrim/grimplayer"


def _plugin_version():
    """The version the stores are told, read from the plugin's manifest.

    Referenced rather than copied: a second copy of the number here drifts the
    moment the manifest is bumped, and the manifest sits one directory up from
    this script (extras/lookup.py). An unreadable manifest only costs the
    version in the User-Agent, so it must never abort a lookup.
    """
    manifest = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            os.pardir, "manifest.json")
    try:
        with open(manifest, "r", encoding="utf-8") as fh:
            return str(json.load(fh).get("version") or "unknown")
    except (OSError, ValueError):
        return "unknown"


VERSION = _plugin_version()
USER_AGENT = "%s/%s ( %s )" % (APP, VERSION, CONTACT)

ITUNES_SEARCH = "https://itunes.apple.com/search"
DEEZER_SEARCH = "https://api.deezer.com/search/album"
CAA_FRONT = "https://coverartarchive.org/release/%s/%s"

# Deezer serves a fixed handful of sizes and 403s on anything past 1400, so the
# nearest one at or above the request is used. iTunes takes any number and its
# CDN clamps to whatever the release actually has, so the request passes through.
DEEZER_SIZES = (500, 1000, 1200, 1400)
DEFAULT_SIZE = 1200

# Two store candidates whose match is this close are "the same album", and the
# better picture between them wins. A candidate further down is a different
# pressing and does not get to win on resolution alone.
MATCH_BAND = 0.12


def out(payload):
    json.dump(payload, sys.stdout)
    sys.stdout.write("\n")


def fail(message):
    out({"status": "error", "message": str(message)})
    sys.exit(0)


def first(value):
    """Mutagen easy tags are lists; the first entry is the value."""
    if not value:
        return ""
    if isinstance(value, (list, tuple)):
        value = value[0] if value else ""
    return str(value).strip()


def read_file(path):
    """The album-level and per-track tags this file already carries, or None."""
    try:
        audio = MutagenFile(path, easy=True)
    except Exception:
        return None
    if audio is None:
        return None
    try:
        tags = audio.tags or {}
    except Exception:
        tags = {}
    raw_track = first(tags.get("tracknumber"))
    raw_disc = first(tags.get("discnumber"))
    return {
        "path": path,
        "title": first(tags.get("title")),
        "artist": first(tags.get("artist")),
        "albumartist": first(tags.get("albumartist")),
        "album": first(tags.get("album")),
        "date": first(tags.get("date")),
        "track": raw_track.split("/")[0].strip(),
        "disc": raw_disc.split("/")[0].strip(),
    }


def as_int(text, default=0):
    try:
        return int(str(text).strip())
    except (TypeError, ValueError):
        return default


def most_common(values):
    counts = {}
    for value in values:
        if value == "":
            continue
        counts[value] = counts.get(value, 0) + 1
    if not counts:
        return ""
    return max(counts.items(), key=lambda kv: kv[1])[0]


def folder_hint(rel):
    """Artist and album guessed from the "Artist/Album" layout, for a folder
    whose files carry no tags at all. Still only a text search -- it just gives
    MusicBrainz something to search *with*, which an untagged album otherwise
    cannot."""
    parts = [p for p in str(rel).replace("\\", "/").split("/") if p]
    if len(parts) < 2:
        return "", ""
    dirs = parts[:-1]
    # A multi-disc album nests its files under "side 2"/"CD1"/"Disc 3"; those are
    # not the album, so they are stepped over before the layout is read.
    while dirs and re.match(r"^(side|cd|disc|disk)\s*\d+$", dirs[-1], re.IGNORECASE):
        dirs.pop()
    if not dirs:
        return "", ""
    album = dirs[-1]
    artist = dirs[-2] if len(dirs) >= 2 else ""
    # "1993 - Crowbar" and "1993 - Crowbar (disc 1)" read as "Crowbar".
    album = re.sub(r"^\d{3,4}\s*[-._]\s*", "", album)
    album = re.sub(r"\s*\((disc|cd)\s*\d+\)$", "", album, flags=re.IGNORECASE)
    return artist.strip(), album.strip()


def folder_year(rel):
    """The year a "1993 - Album" folder was filed under, for a release with no
    date tag to match pressings against."""
    parts = [p for p in str(rel).replace("\\", "/").split("/") if p]
    for part in reversed(parts[:-1]):
        if re.match(r"^(side|cd|disc|disk)\s*\d+$", part, re.IGNORECASE):
            continue
        match = re.match(r"^(\d{4})\s*[-._]", part)
        return match.group(1) if match else ""
    return ""


def sort_key(meta):
    """Order files the way an album reads: disc, then track, then filename.

    The editor hands the selection over in MPD's order, but that is not guaranteed
    to be the album's, and the matched tracks are a flat list that has to line up
    with something. Falling back to the name keeps untagged folders -- the ones
    this exists for -- in "01, 02, ..." order.
    """
    return (
        as_int(meta["disc"]),
        as_int(meta["track"]),
        os.path.basename(meta["path"]).lower(),
    )


def credit_name(entity):
    credit = entity.get("artist-credit") or []
    name = ""
    for part in credit:
        # A search result carries the name on the credit itself; a release
        # looked up by id nests it under `artist`, so both are read.
        name += part.get("name") or (part.get("artist") or {}).get("name", "")
        name += part.get("joinphrase", "")
    return name.strip()


def year_of(date):
    date = str(date or "").strip()
    return date[:4] if len(date) >= 4 and date[:4].isdigit() else ""


def candidate_meta(release):
    group = release.get("release-group") or {}
    primary = group.get("primary-type") or ""
    secondary = group.get("secondary-type-list") or []
    return {
        "mbid": release.get("id", ""),
        "artist": credit_name(release),
        "album": release.get("title", ""),
        "date": year_of(release.get("date")),
        "country": (release.get("country") or "").upper(),
        "score": int(release.get("ext:score") or release.get("score") or 0),
        "tracks": release.get("medium-track-count")
            or release.get("track-count") or 0,
        "_primary": primary,
        "_secondary": secondary,
        "_status": release.get("status", ""),
    }


def score_candidate(meta, artist, album, year, file_count):
    """A rough confidence, so the pressing the folder is tagged as outranks a
    reissue of it even when MusicBrainz rates them equally, and an album
    outranks a compilation that simply shares the name."""
    score = int(meta.get("score") or 0)
    title = (meta.get("album") or "").lower()
    if album and title:
        want = album.lower()
        if want not in title and title not in want:
            score -= 15
    cand_artist = (meta.get("artist") or "").lower()
    if artist and cand_artist:
        want = artist.lower()
        if want not in cand_artist and cand_artist not in want:
            score -= 15
    count = meta.get("tracks")
    if isinstance(count, int) and count and file_count:
        score += 10 if count == file_count else -min(30, abs(count - file_count) * 6)
    if year and meta.get("date"):
        score += 10 if meta["date"] == year else -6
    if meta.get("_primary") == "Album":
        score += 3
    if "Compilation" in meta.get("_secondary", []) or meta.get("_primary") == "Compilation":
        score -= 5
    if meta.get("_status") and meta["_status"] != "Official":
        score -= 3
    return score


def public(meta):
    return {k: v for k, v in meta.items() if not k.startswith("_")}


def release_tracks(release):
    """Flatten the release's media into one ordered list of disc/track/title."""
    tracks = []
    for medium in release.get("medium-list", []) or []:
        disc = medium.get("position", "")
        for track in medium.get("track-list", []) or []:
            title = track.get("title")
            if not title:
                title = (track.get("recording") or {}).get("title", "")
            number = track.get("number") or track.get("position") or ""
            tracks.append({
                "disc": str(disc).split("/")[0].strip(),
                "track": str(number).split("/")[0].strip(),
                "title": (title or "").strip(),
            })
    return tracks


# ---- artwork sources ---------------------------------------------------------
#
# Everything below is about one question: which of the covers on offer is the
# right album and the best picture. The stores are searched by name, so their
# answers have to be scored against what the tags say before any of them counts;
# the archive is already tied to a release id and needs no such check.


def fetch_bytes(url, timeout=20):
    """The body of a URL, or None. Every failure -- 404, 403, no network, a
    timeout -- is the same answer here: this source has nothing."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 403, 307):
            return None
        return None
    except Exception:
        return None


def fetch_json(url, timeout=20):
    data = fetch_bytes(url, timeout)
    if not data:
        return None
    try:
        return json.loads(data.decode("utf-8", "replace"))
    except Exception:
        return None


def image_dimensions(data):
    """(width, height) of a JPEG or PNG, or (0, 0).

    Enough header reading to tell a 600px thumbnail from a 1400px cover and to
    spot a non-square scan; a full decoder would be a dependency and this is the
    only question being asked."""
    if not data:
        return (0, 0)
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        width = int.from_bytes(data[16:20], "big")
        height = int.from_bytes(data[20:24], "big")
        return (width, height)
    if data[:2] == b"\xff\xd8":
        i = 2
        n = len(data)
        while i + 9 < n:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            # Standalone markers carry no length; padding 0xFFs are skipped.
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7 or marker == 0xFF:
                i += 2
                continue
            if marker in (0xD9, 0xDA):
                break
            segment = int.from_bytes(data[i + 2:i + 4], "big")
            # The SOFn frame header's height precedes its width.
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                height = int.from_bytes(data[i + 5:i + 7], "big")
                width = int.from_bytes(data[i + 7:i + 9], "big")
                return (width, height)
            i += 2 + segment
    return (0, 0)


def fold(text):
    """Lowercased, accent-stripped, punctuation-free, for comparison only."""
    text = unicodedata.normalize("NFKD", str(text or ""))
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.lower()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


def similarity(a, b):
    a, b = fold(a), fold(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    if a in b or b in a:
        return 0.85
    ta, tb = set(a.split()), set(b.split())
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / len(ta | tb) * 0.8


def match_score(cand_artist, cand_album, artist, album, cand_tracks, tracks,
                cand_year, year):
    """How likely a store hit is this album, or a negative number to reject it.

    Album and artist both have to line up before anything else is considered --
    the track count and the year only break ties between pressings of a match
    that already holds."""
    album_sim = similarity(cand_album, album)
    if album_sim < 0.6:
        return -1.0
    artist_sim = similarity(cand_artist, artist) if artist else 1.0
    if artist and artist_sim < 0.45:
        return -1.0
    score = 0.6 * album_sim + 0.35 * artist_sim
    if tracks and cand_tracks:
        if as_int(cand_tracks) == as_int(tracks):
            score += 0.1
    if year and cand_year and str(year)[:4] == str(cand_year)[:4]:
        score += 0.05
    return score


def itunes_candidates(artist, album, year, tracks, size):
    term = ("%s %s" % (artist, album)).strip()
    if not term:
        return []
    out = []
    # The US store front covers most catalog; a release only sold in the UK is
    # asked for again there, but only when the first search came up empty.
    for country in ("us", "gb"):
        query = urllib.parse.urlencode({
            "term": term, "entity": "album", "limit": 25, "country": country,
        })
        data = fetch_json(ITUNES_SEARCH + "?" + query)
        for entry in (data or {}).get("results") or []:
            url = entry.get("artworkUrl100") or ""
            if not url:
                continue
            score = match_score(
                entry.get("artistName"), entry.get("collectionName"),
                artist, album, entry.get("trackCount"), tracks,
                (entry.get("releaseDate") or "")[:4], year,
            )
            if score < 0:
                continue
            # The 100px thumbnail's size segment is all the CDN reads; asking
            # for a larger one is a plain rewrite of "100x100bb".
            out.append({
                "source": "iTunes",
                "url": re.sub(r"100x100bb", "%dx%dbb" % (size, size), url),
                "score": score,
            })
        if out:
            break
    return out


def deezer_candidates(artist, album, year, tracks, size):
    term = ("%s %s" % (artist, album)).strip()
    if not term:
        return []
    query = urllib.parse.urlencode({"q": term, "limit": 25})
    data = fetch_json(DEEZER_SEARCH + "?" + query)
    dz = DEEZER_SIZES[-1]
    for candidate_size in DEEZER_SIZES:
        if candidate_size >= size:
            dz = candidate_size
            break
    out = []
    for entry in (data or {}).get("data") or []:
        cover = entry.get("cover_xl") or entry.get("cover_big") or ""
        if not cover:
            continue
        score = match_score(
            (entry.get("artist") or {}).get("name"), entry.get("title"),
            artist, album, entry.get("nb_tracks"), tracks,
            (entry.get("release_date") or "")[:4], year,
        )
        if score < 0:
            continue
        # cover_xl carries its own size, as ".../<hash>/1000x1000-000000-80-0-0.jpg".
        out.append({
            "source": "Deezer",
            "url": re.sub(r"\d+x\d+", "%dx%d" % (dz, dz), cover, count=1),
            "score": score,
        })
    return out


def quality_key(item):
    """Sort key for "the better picture": a square one first, then the larger of
    the two sides -- a 1400x1400 and a 1188x1200 are both large, but only the
    square one fills the cover frame without a crop."""
    width, height = item["width"], item["height"]
    square = abs(width - height) <= max(2, int(0.03 * max(width, height)))
    return (1 if square else 0, min(width, height))


def choose_store(artist, album, year, tracks, size):
    """Download the best store matches and return the best picture, or None."""
    cands = itunes_candidates(artist, album, year, tracks, size)
    cands += deezer_candidates(artist, album, year, tracks, size)
    if not cands:
        return None
    cands.sort(key=lambda c: c["score"], reverse=True)
    top = cands[0]["score"]
    shortlist = [c for c in cands if c["score"] >= top - MATCH_BAND]
    # One download per source: iTunes and Deezer each get a shot at being the
    # larger picture, but the same store is never fetched twice for one album.
    per_source = {}
    for cand in shortlist:
        if cand["source"] not in per_source:
            per_source[cand["source"]] = cand
    best = None
    for cand in per_source.values():
        data = fetch_bytes(cand["url"])
        if not data:
            continue
        width, height = image_dimensions(data)
        if width <= 0 or height <= 0:
            continue
        item = {"source": cand["source"], "data": data,
                "width": width, "height": height, "score": cand["score"]}
        if best is None or quality_key(item) > quality_key(best):
            best = item
        # Good enough: square, and at least as large as was asked for. Stop here
        # rather than spend the second store's download on pixels the frame will
        # never show. The candidates are tried best-match first, so this keeps
        # the closest match among the sources that can satisfy the size.
        square, smallest = quality_key(item)
        if square and smallest >= size:
            break
    return best


def fetch_archive(mbid, size):
    """The release's own front cover, at the nearest offered size. Only reached
    when no store has the album."""
    if not mbid:
        return None
    if size <= 250:
        suffix = "front-250"
    elif size <= 500:
        suffix = "front-500"
    else:
        suffix = "front-1200"
    data = fetch_bytes(CAA_FRONT % (mbid, suffix))
    if not data:
        return None
    width, height = image_dimensions(data)
    if width <= 0 or height <= 0:
        return None
    return {"source": "Cover Art Archive", "data": data,
            "width": width, "height": height}


def resolve_cover(artist, album, year, tracks, mbid, size,
                  out_path=None, cache_dir=None, key=None):
    """Fetch the best cover for an album and write it to disk.

    Returns the same four keys every caller reads -- cover, coverSource,
    coverWidth, coverHeight -- with an empty cover when nothing was found, so a
    miss is a value and not an exception."""
    if size <= 0:
        size = DEFAULT_SIZE
    chosen = choose_store(artist, album, year, tracks, size)
    if chosen is None:
        chosen = fetch_archive(mbid, size)
    if chosen is None:
        return {"cover": "", "coverSource": "", "coverWidth": 0, "coverHeight": 0}

    target = out_path
    if not target:
        base = key or ("%s-%s" % (artist, album))
        base = re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-") or "cover"
        src = re.sub(r"[^A-Za-z0-9]+", "", chosen["source"]) or "image"
        target = os.path.join(cache_dir or ".", "%s-%s.jpg" % (base, src))
    directory = os.path.dirname(target)
    if directory:
        try:
            os.makedirs(directory, exist_ok=True)
        except OSError:
            pass
    try:
        with open(target, "wb") as handle:
            handle.write(chosen["data"])
    except OSError:
        return {"cover": "", "coverSource": "", "coverWidth": 0, "coverHeight": 0}
    return {"cover": target, "coverSource": chosen["source"],
            "coverWidth": chosen["width"], "coverHeight": chosen["height"]}


def cover_only(args):
    """The player's display fallback. No MusicBrainz, no tag reader: just the
    stores, at the size the panel draws, written wherever it asked."""
    artist = (args.artist or "").strip()
    album = (args.album or "").strip()
    if not artist and not album:
        fail("No artist or album to search from")
    year = (args.year or "").strip()[:4]
    try:
        cover = resolve_cover(artist, album, year, args.tracks, args.release,
                              args.size, out_path=args.cover_out or None)
    except Exception as exc:  # noqa: BLE001
        fail("Cover fetch failed: %s" % exc)
    payload = {"status": "ok"}
    payload.update(cover)
    out(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--music-dir", default="")
    parser.add_argument("--file", action="append", default=[], dest="files")
    parser.add_argument("--release", default="")
    parser.add_argument("--limit", type=int, default=5)
    # The player's own path: one cover, no metadata, no tag libraries.
    parser.add_argument("--cover-only", action="store_true")
    parser.add_argument("--artist", default="")
    parser.add_argument("--album", default="")
    parser.add_argument("--year", default="")
    parser.add_argument("--tracks", type=int, default=0)
    parser.add_argument("--size", type=int, default=DEFAULT_SIZE)
    parser.add_argument("--cover-out", default="")
    args = parser.parse_args()

    if args.cover_only:
        cover_only(args)
        return

    if _IMPORT_ERROR is not None:
        fail("Missing dependency: %s" % _IMPORT_ERROR)

    if not args.files:
        fail("No files given")

    musicbrainzngs.set_useragent(APP, VERSION, CONTACT)

    paths = [os.path.join(args.music_dir, rel) for rel in args.files]
    metas = [m for m in (read_file(p) for p in paths) if m is not None]
    if not metas:
        fail("Nothing to read tags from")

    # Pair each surviving meta back to the relative file the editor knows it by,
    # then line that ordered list up with the matched tracks.
    rels = {}
    for rel, path in zip(args.files, paths):
        rels[path] = rel
    metas.sort(key=sort_key)

    album = most_common([m["album"] for m in metas])
    artist = most_common([m["albumartist"] or m["artist"] for m in metas])
    year = most_common([year_of(m["date"]) for m in metas])
    if not year:
        year = folder_year(args.files[0])

    cache_dir = os.path.join(
        os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state")),
        "skollgrim.grimplayer", "lookup",
    )
    try:
        os.makedirs(cache_dir, exist_ok=True)
    except OSError:
        cache_dir = "/tmp"

    candidates = []
    best_release = None

    if args.release:
        try:
            best_release = musicbrainzngs.get_release_by_id(
                args.release,
                includes=["recordings", "artist-credits", "media"],
            )["release"]
        except Exception as exc:  # noqa: BLE001
            fail("Release lookup failed: %s" % exc)
        candidates = [public(candidate_meta(best_release))]
    else:
        if not album:
            hint_artist, hint_album = folder_hint(args.files[0])
            album = album or hint_album
            artist = artist or hint_artist
        if not album:
            fail("No album name to search from")
        query_artist = artist or None
        try:
            result = musicbrainzngs.search_releases(
                artist=query_artist, release=album, limit=max(1, args.limit)
            )
        except Exception as exc:  # noqa: BLE001
            fail("Search failed: %s" % exc)
        found = result.get("release-list", []) or []
        if not found:
            fail("No match on MusicBrainz")
        scored = []
        for entity in found:
            meta = candidate_meta(entity)
            meta["_score"] = score_candidate(meta, artist, album, year, len(metas))
            scored.append(meta)
        scored.sort(key=lambda m: m["_score"], reverse=True)
        for meta in scored:
            meta["score"] = meta.pop("_score")
        candidates = [public(m) for m in scored]
        try:
            best_release = musicbrainzngs.get_release_by_id(
                candidates[0]["mbid"],
                includes=["recordings", "artist-credits", "media"],
            )["release"]
        except Exception as exc:  # noqa: BLE001
            fail("Release lookup failed: %s" % exc)

    tracks = release_tracks(best_release)
    matched = []
    for index, meta in enumerate(metas):
        entry = {"file": rels.get(meta["path"], "")}
        if index < len(tracks):
            entry["title"] = tracks[index]["title"]
            entry["track"] = tracks[index]["track"]
            entry["disc"] = tracks[index]["disc"]
        matched.append(entry)

    # Prefer the detailed release's own metadata for the fields; the search
    # result lacks the release country and can carry a shorter date.
    best = candidate_meta(best_release)
    best["score"] = candidates[0]["score"] if candidates else best.get("score", 0)

    cover = {"cover": "", "coverSource": "", "coverWidth": 0, "coverHeight": 0}
    try:
        cover = resolve_cover(
            best.get("artist", ""), best.get("album", ""),
            str(best.get("date", ""))[:4], len(metas), best.get("mbid", ""),
            DEFAULT_SIZE, cache_dir=cache_dir, key=best.get("mbid", ""),
        )
    except Exception:  # noqa: BLE001 - a missing cover is not a failed lookup
        cover = {"cover": "", "coverSource": "", "coverWidth": 0, "coverHeight": 0}

    payload = {
        "status": "ok",
        "artist": best.get("artist", ""),
        "albumArtist": best.get("artist", ""),
        "album": best.get("album", ""),
        "date": best.get("date", ""),
        "country": best.get("country", ""),
        "candidates": candidates,
        "tracks": matched,
    }
    payload.update(cover)
    out(payload)


if __name__ == "__main__":
    main()
