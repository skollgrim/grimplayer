// LRC parsing, the playing-line search, and the lyric scroll arithmetic.
//
// Kept out of GrimPlayer.qml so the timing rules can be exercised without a
// shell: extras/test-lyrics.js loads this file under Node. The guarded module
// export at the bottom is inert inside QML, where `module` does not exist.

function asText(value) {
    return String(value === undefined || value === null ? "" : value)
}

// A lyric file as a flat list of { time, text }. Timed lines come first in
// time order; plain lines follow in file order with time -1. The panel renders
// the list in order and highlights the entry the playback clock has reached.
function parse(text) {
    var lines = asText(text).replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n")
    var out = []
    // [mm:ss.xx], and the [mm:ss:xx] spelling some writers emit. A third
    // fraction digit means milliseconds rather than hundredths.
    var re = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g
    // A line that is nothing but LRC metadata tags -- [ar:], [ti:],
    // [offset:] -- is not lyrics. Without this it would fall through to the
    // plain-text branch and be printed verbatim. Bracket words in plain files,
    // like a "[Chorus]" heading, are left alone.
    var metaOnly = /^(?:\[(?:ar|al|ti|au|by|re|ve|length|offset|tool):[^\]]*\]\s*)+$/i
    for (var i = 0; i < lines.length; i++) {
        var l = lines[i]
        re.lastIndex = 0
        var m
        var times = []
        while ((m = re.exec(l)) !== null) {
            var mm = parseInt(m[1]) || 0
            var ss = parseInt(m[2]) || 0
            var frac = m[3] !== undefined ? m[3] : "0"
            var part = frac.length === 1 ? parseInt(frac) / 10
                    : frac.length === 2 ? parseInt(frac) / 100
                    : parseInt(frac.substring(0, 3)) / 1000
            times.push(mm * 60 + ss + (part || 0))
        }
        if (times.length === 0) {
            var t = l.trim()
            if (t !== "" && !metaOnly.test(t)) out.push({ time: -1, text: t, order: out.length })
            continue
        }
        var content = l.replace(/\[[^\]]*\]/g, "").trim()
        if (content === "") continue
        for (var ti = 0; ti < times.length; ti++) {
            out.push({ time: times[ti], text: content, order: out.length })
        }
    }
    // `order` breaks ties: a plain file has no times at all, and every repeated
    // timestamp would otherwise be free to shuffle.
    out.sort(function (a, b) {
        if (a.time < 0 && b.time < 0) return a.order - b.order
        if (a.time < 0) return 1
        if (b.time < 0) return -1
        if (a.time === b.time) return a.order - b.order
        return a.time < b.time ? -1 : 1
    })
    var sorted = []
    for (var s = 0; s < out.length; s++) sorted.push({ time: out[s].time, text: out[s].text })
    return sorted
}

// Index of the last timed line the clock has reached, or -1 before the first
// one. The quarter second of lead lets a line light up as it is sung rather
// than after the word has gone by. offsetMs is the user's sync offset: positive
// means the lyrics run early, so the highlight is delayed.
function activeIndex(lines, elapsed, offsetMs) {
    if (!lines || lines.length === 0) return -1
    var at = (Number(elapsed) || 0) - (Number(offsetMs) || 0) / 1000
    var best = -1
    for (var i = 0; i < lines.length; i++) {
        var t = Number(lines[i].time)
        // Plain lines sit after the timed ones and have no moment of their own.
        if (t < 0) continue
        if (t <= at + 0.25) best = i
        else break
    }
    return best
}

// Where the view has to scroll for a line to sit in the middle of the visible
// text. Clamped to the scrollable range, so the first and last lines rest
// against their edges instead of leaving a blank half-screen.
function scrollTarget(itemY, itemHeight, viewportHeight, contentHeight) {
    var max = Math.max(0, contentHeight - viewportHeight)
    var target = itemY - (viewportHeight - itemHeight) / 2
    return Math.max(0, Math.min(target, max))
}

// A keyboard or wheel step, kept inside the same range.
function scrollBy(currentY, delta, contentHeight, viewportHeight) {
    var max = Math.max(0, contentHeight - viewportHeight)
    return Math.max(0, Math.min(currentY + delta, max))
}

// Home and End.
function scrollEdge(edge, contentHeight, viewportHeight) {
    var max = Math.max(0, contentHeight - viewportHeight)
    return edge === 0 ? 0 : max
}

// A tag value as the filename fetch_lyrics.py would have used. Mirrors
// safe_name() there; the cache lookup and the helper have to agree.
function safeName(name) {
    var s = asText(name)
    s = s.replace(/[/\\\x00-\x1f]+/g, "-")
    s = s.replace(/\s+/g, " ")
    s = s.replace(/^[ .]+/, "").replace(/[ .]+$/, "")
    return s || "Unknown"
}

// Cache stems (no extension) for a track, in the order they are tried: the
// title as MPD gives it, then without a trailing parenthetical, which covers
// earlier runs that filed a track under its shorter name.
function cacheStems(home, artist, title) {
    var base = asText(home)
    var names = [asText(title)]
    var short = asText(title).replace(/\s*[\(\[][^\)\]]*[\)\]]\s*$/, "").trim()
    if (short && short !== asText(title)) names.push(short)
    var stems = []
    for (var i = 0; i < names.length; i++) {
        var p = base + "/" + safeName(artist) + " - " + safeName(names[i])
        if (stems.indexOf(p) < 0) stems.push(p)
    }
    return stems
}

// The path a sidecar .lrc/.txt would sit at: the track beside the library,
// without its extension.
function localStem(musicDir, rel) {
    return (asText(musicDir) + "/" + asText(rel)).replace(/\.[^./]+$/, "")
}

// The helper's argv. The order is the contract with fetch_lyrics.py's parser.
function helperArgs(options) {
    var o = options || {}
    var args = ["python3", asText(o.script),
        "--music-dir", asText(o.musicDir),
        "--file", asText(o.file),
        "--artist", asText(o.artist),
        "--title", asText(o.title),
        "--album", asText(o.album),
        "--duration", asText(o.duration)]
    // "Fetch lyrics" off keeps the helper to local files only: embedded tags,
    // sidecars and the cache, with no request to lrclib.
    if (o.offline) args.push("--offline")
    return args
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parse: parse,
        activeIndex: activeIndex,
        scrollTarget: scrollTarget,
        scrollBy: scrollBy,
        scrollEdge: scrollEdge,
        safeName: safeName,
        cacheStems: cacheStems,
        localStem: localStem,
        helperArgs: helperArgs
    }
}
