// How a tag edit becomes a command line, and how the readers' output is
// understood again.
//
// MPD cannot write tags: it has no command for it and treats the library as
// read-only. So the files are edited in place by the tools that already ship on
// the machine -- mid3v2 for ID3v2 and metaflac for Vorbis comments -- both of
// which rewrite only the tag block and leave the audio stream alone. Nothing is
// discovered at runtime beyond the extension: there is no ffmpeg fallback,
// because if it failed partway the file is the thing that was at risk.
//
// The tables and rules live here, away from the service, so
// extras/test-tag-frames.js can check the exact argv without a shell or MPD.

var ID3_FRAMES = {
    title: "TIT2", artist: "TPE1", albumArtist: "TPE2", album: "TALB",
    track: "TRCK", disc: "TPOS", date: "TDRC", genre: "TCON"
}

var VORBIS_FIELDS = {
    title: "TITLE", artist: "ARTIST", albumArtist: "ALBUMARTIST", album: "ALBUM",
    track: "TRACKNUMBER", disc: "DISCNUMBER", date: "DATE", genre: "GENRE",
    comment: "COMMENT"
}

// MP3 carries a release country as a TXXX user frame, so it cannot go through
// ID3_FRAMES: a TXXX is identified by its description, not by the frame name.
// The tag itself is Picard's, and holds an ISO 3166-1 alpha-2 code.
var ID3_TXXX = {
    country: "MusicBrainz Album Release Country"
}

// Vorbis comments are a flat list of named fields, and readers disagree about
// which name a release country goes under, so both Picard names are written and
// all three spellings are accepted on the way in. Plain COUNTRY is not written
// -- it is the least specific of the three -- but a library tagged by something
// else may carry it, and refusing to read it would show a tagged album as
// untagged.
function vorbisFieldsFor(key) {
    if (key === "country") return ["MUSICBRAINZ_ALBUMRELEASECOUNTRY", "RELEASECOUNTRY"]
    var field = VORBIS_FIELDS[key]
    return field ? [field] : []
}

// Per-file first, shared second: a value the user typed into a shared field is
// a deliberate override and must beat a matched per-track one.
function mergeTags(common, perFile, file) {
    var out = {}
    var extra = perFile ? perFile[file] : undefined
    if (extra) for (var e in extra) out[e] = extra[e]
    for (var k in common) out[k] = common[k]
    return out
}

// An argument list, undefined when there was nothing to write, or null when
// this file is not a format a tagger here can open. The two are different
// answers: the first means the file already says what was asked of it, the
// second means it was never touched.
function command(item) {
    var path = item && item.path !== undefined ? String(item.path) : ""
    var tags = (item && item.tags) || {}
    var lower = path.toLowerCase()
    var isMp3 = lower.slice(-4) === ".mp3"
    var isFlac = lower.slice(-5) === ".flac"
    if (!isMp3 && !isFlac) return null

    var args = [isMp3 ? "mid3v2" : "metaflac"]
    var handled = 0
    var keys = Object.keys(tags)
    for (var k = 0; k < keys.length; k++) {
        var key = keys[k]
        var value = tags[key] === undefined || tags[key] === null
            ? "" : String(tags[key]).trim()

        if (isMp3) {
            // COMM is a description/language frame, not a simple text frame, so
            // it cannot go through ID3_FRAMES. mid3v2 splits the value on ":" as
            // description:value:language, so a comment containing a colon has to
            // be wrapped. The empty description and eng language replace the
            // main comment frame while leaving other COMM frames (the iTunNORM
            // loudness note, for one) alone. An empty value still writes the
            // frame: deleting COMM would take those with it.
            if (key === "comment") {
                args.push("--COMM", ":" + value + ":eng")
                handled++
                continue
            }
            var txxx = ID3_TXXX[key]
            if (txxx) {
                // mid3v2 addresses a TXXX by description, so writing and clearing
                // both name the frame and let the value be empty:
                // `--delete-frames=TXXX` would have taken the ReplayGain and
                // MusicBrainz frames on the way out.
                args.push("--TXXX", txxx + ":" + value)
                handled++
                continue
            }
            var frame = ID3_FRAMES[key]
            if (!frame) continue
            if (value === "") args.push("--delete-frames=" + frame)
            else args.push("--" + frame, value)
            handled++
        } else {
            var fields = vorbisFieldsFor(key)
            for (var f = 0; f < fields.length; f++) {
                // Vorbis comments allow a field to repeat, and metaflac's
                // --set-tag appends rather than replaces: without the remove
                // first, every edit left the old value behind as a second copy
                // of the same tag and readers picked whichever they liked.
                args.push("--remove-tag=" + fields[f])
                if (value !== "") args.push("--set-tag=" + fields[f] + "=" + value)
                handled++
            }
        }
    }
    if (handled === 0) return undefined
    args.push(path)
    return args
}

// Pulls a country out of whichever reader produced the output. Returns "" for
// "no country here", which is a legitimate answer and gets cached as one so an
// untagged album is not probed again on every play.
//
// Both spellings are matched with the separators squeezed out, because the
// Picard name is words ("MusicBrainz Album Release Country") while the Vorbis
// field is one token (MUSICBRAINZ_ALBUMRELEASECOUNTRY). A TXXX is only answered
// once its description has been checked: a library carries dozens of them, and
// taking the first would return whatever frame happened to sort first.
function parseCountry(output) {
    var lines = String(output === undefined || output === null ? "" : output).split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        var eq = line.indexOf("=")
        if (eq < 0) continue
        var head = line.slice(0, eq).trim()
        var rest = line.slice(eq + 1)
        var candidate = ""

        if (head.toUpperCase() === "TXXX") {
            // "TXXX=<description>=<value>"
            var cut = rest.indexOf("=")
            if (cut < 0) continue
            var desc = rest.slice(0, cut).replace(/[\s_-]/g, "").toUpperCase()
            if (desc.indexOf("RELEASECOUNTRY") < 0 && desc !== "COUNTRY") continue
            candidate = rest.slice(cut + 1).trim()
        } else if (head.replace(/[\s_-]/g, "").toUpperCase() === "COUNTRY"
                || head.replace(/[\s_-]/g, "").toUpperCase().indexOf("RELEASECOUNTRY") >= 0) {
            candidate = rest.trim()
        } else continue

        if (candidate !== "") return candidate
    }
    return ""
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        ID3_FRAMES: ID3_FRAMES,
        VORBIS_FIELDS: VORBIS_FIELDS,
        ID3_TXXX: ID3_TXXX,
        vorbisFieldsFor: vorbisFieldsFor,
        mergeTags: mergeTags,
        command: command,
        parseCountry: parseCountry
    }
}
