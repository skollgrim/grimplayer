// Filename <-> tag arithmetic for the tag editor.
//
// The library's names are the other place a track's number and title are
// written down, and they are often better than the tags: a rip can arrive with
// "01 - Title.flac" and no tags at all. `parse()` reads that name back into a
// number and a title, and `build()` is the other direction, spelling
// "NN - Title.ext" from the tags.
//
// Plain script rather than a `.pragma library`, like Paths.js, so a change is
// picked up with the component that imports it and extras/test-names.js can
// exercise the rules under Node.

// The last component of an MPD path. A cue album's virtual tracks
// ("album.cue/track0003") are not files and are skipped by the caller, not here.
function baseName(path) {
    var p = String(path === undefined || path === null ? "" : path)
    var slash = p.lastIndexOf("/")
    return slash >= 0 ? p.substring(slash + 1) : p
}

// "01 - Title.flac" -> { stem: "01 - Title", ext: ".flac" }. An extension is a
// dot followed by one to five letters or digits at the very end, so a title
// that happens to contain a dot ("Mr. Brightside", "Song (Live).flac") is not
// cut at the wrong one.
function splitExtension(name) {
    var n = String(name === undefined || name === null ? "" : name)
    var m = /\.[A-Za-z0-9]{1,5}$/.exec(n)
    if (m) return { stem: n.substring(0, n.length - m[0].length), ext: m[0] }
    return { stem: n, ext: "" }
}

// Track numbers lose their leading zero when they become a tag: "01" and "1"
// are the same number, and the rest of the service treats them that way.
function cleanNumber(text) {
    var n = parseInt(String(text), 10)
    return isNaN(n) ? "" : String(n)
}

// What one dash-separated segment says. The shapes, in the order they are
// tried, are:
//
//   1-02 Title    disc 1, track 2
//   01. Title     track 1          (also "01) Title" and "01.")
//   01_Title      track 1
//   01-Title      track 1
//   01 Title      track 1
//   01            track 1, no title
//
// A segment that starts with anything else has nothing to say here. The track
// is capped at three digits, so a name like "2001 - A Space Odyssey" is not
// mistaken for track 2001.
function numberAtStart(segment) {
    var s = String(segment === undefined || segment === null ? "" : segment).trim()
    if (s === "") return null
    var m = /^(\d{1,2})\s*[-._]\s*(\d{1,3})[.)]?(?:\s+(.*))?$/.exec(s)
    if (m) return { disc: cleanNumber(m[1]), track: cleanNumber(m[2]),
                    rest: m[3] ? m[3].trim() : "" }
    m = /^(\d{1,3})[.)]\s*(.*)$/.exec(s)
    if (m) return { disc: "", track: cleanNumber(m[1]), rest: m[2].trim() }
    m = /^(\d{1,3})_(.*)$/.exec(s)
    if (m) return { disc: "", track: cleanNumber(m[1]), rest: m[2].trim() }
    m = /^(\d{1,3})\s*-\s*(.*)$/.exec(s)
    if (m) return { disc: "", track: cleanNumber(m[1]), rest: m[2].trim() }
    m = /^(\d{1,3})\s+(.*)$/.exec(s)
    if (m) return { disc: "", track: cleanNumber(m[1]), rest: m[2].trim() }
    m = /^(\d{1,3})$/.exec(s)
    if (m) return { disc: "", track: cleanNumber(m[1]), rest: "" }
    return null
}

// The number and title a file name carries, plus its extension.
//
// Names often stack an artist and album in front of the number:
// "Artist - Album - 01 Title". Only a segment that begins with a number is
// trusted, and everything after it is the title -- the parts before it are the
// prefixes, which this deliberately does not guess at.
//
// A name with dashes but no number is left alone ("Artist - Title" and
// "Album - Title" cannot be told apart). A name with no dashes at all is the
// title entire, since there is nothing else it could be.
function parse(path) {
    var parts = splitExtension(baseName(path))
    var stem = parts.stem.trim()
    var ext = parts.ext
    var empty = { title: "", track: "", disc: "", ext: ext }
    if (stem === "") return empty

    var segments = stem.split(/\s+[-\u2013\u2014]\s+/)
    for (var i = 0; i < segments.length; i++) {
        var head = numberAtStart(segments[i])
        if (!head) continue
        var rest = []
        if (head.rest !== "") rest.push(head.rest)
        for (var j = i + 1; j < segments.length; j++) rest.push(segments[j])
        return {
            title: rest.join(" - ").trim(),
            track: head.track,
            disc: head.disc,
            ext: ext
        }
    }

    // Dashes but no number: the prefixes are unknown, so nothing is read.
    if (segments.length > 1) return empty
    return { title: stem, track: "", disc: "", ext: ext }
}

// A number padded to the album's chosen width. Two digits is the convention
// ("01 - Title"); a three-digit album keeps all three, which the caller passes
// as trackWidth.
function padNumber(number, width) {
    var s = String(number)
    var w = width && width > 0 ? width : 2
    while (s.length < w) s = "0" + s
    return s
}

// A title as a file name can hold it. The slash is the one character that
// cannot appear; runs of whitespace collapse so a tag with a stray double space
// does not produce a name with one.
function tidyTitle(title) {
    return String(title === undefined || title === null ? "" : title)
        .replace(/\//g, "-")
        .replace(/\u0000/g, "")
        .replace(/\s+/g, " ")
        .trim()
}

// Tags -> name. Options are `trackWidth` (default 2). An empty or impossible
// title builds nothing, which the caller reports rather than writing " - .ext".
function build(track, title, ext, options) {
    var opts = options || {}
    var t = tidyTitle(title)
    if (t === "" || t === "." || t === "..") return ""
    var tail = String(ext === undefined || ext === null ? "" : ext)
    var number = String(track === undefined || track === null ? "" : track).trim()
    if (!/^\d+$/.test(number)) return t + tail
    return padNumber(number, opts.trackWidth) + " - " + t + tail
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        baseName: baseName,
        splitExtension: splitExtension,
        parse: parse,
        build: build,
        padNumber: padNumber,
        tidyTitle: tidyTitle
    }
}
