.pragma library

// Where the artwork pulled out of a file is cached, and how its name is derived.
//
// The name has to be agreed on by two places that never talk to each other: the
// reader, CoverArt.qml, which writes the extraction and then loads it, and the
// writer, GrimPlayerMpd.qml, which deletes a cached cover when the user clears
// one. A shared hash is the one way to keep them from drifting apart -- the
// alternative, a second copy of the arithmetic, is a bug waiting for whichever
// one gets edited.
//
// Pure on purpose: a .pragma library script cannot be relied on to see the
// Quickshell singleton, so the base directory is composed at each call site and
// only the filename is computed here.

// FNV-1a. Only has to be stable and well spread, not cryptographic: a collision
// would mean one album showing another's artwork, which is vanishingly unlikely
// at this scale and no worse than the filename collisions the probe already
// tolerates. A readable album-directory name would not do -- the names contain
// slashes and characters the filesystem treats specially.
//
// Math.imul is not an optimisation, it is the only correct option here. The
// naive `h * 16777619` multiplies a 32-bit value by a 24-bit one and lands
// around 2^56, which is past Number.MAX_SAFE_INTEGER, so the double silently
// drops low bits and two different albums can land on the same name. imul does
// the multiply in 32-bit space where it cannot.
function stem(dir) {
    var h = 0x811c9dc5
    for (var i = 0; i < dir.length; i++) {
        h ^= dir.charCodeAt(i)
        h = Math.imul(h, 0x01000193)
    }
    return ("00000000" + (h >>> 0).toString(16)).slice(-8)
}

// Always a .jpg: the extraction re-encodes to mjpeg rather than copying the
// embedded stream, so the cached file is a real JPEG whatever the source was.
function fileName(dir) {
    return stem(dir) + ".jpg"
}

// The cover downloaded for an album that had none anywhere, kept alongside the
// extraction under its own suffix. Two names rather than one because they are
// different claims: the extraction is what the file actually holds, the
// download is what a store thinks the album looks like, and the probe has to be
// able to tell them apart to keep the embedded picture winning.
function onlineFileName(dir) {
    return stem(dir) + ".online.jpg"
}

// The album directory a library-relative path belongs to. One implementation,
// because two components key their caches on it and a second copy is a bug: the
// reader, CoverArt.qml, decides where to look for artwork, and the writer,
// GrimPlayerMpd.qml, decides which cache entry an override or a cover removal
// addresses -- they have to agree on the string.
//
// Two shapes need care. A cue album is presented by MPD as one virtual track per
// song under "<dir>/<album>.cue/trackNNNN", a directory that does not exist; the
// fold back onto the cue file's own path gives the real album directory, so the
// artwork beside the cue and its audio is found. And a track sitting directly in
// the music root has no directory to name, so it is keyed on "." -- a real,
// distinguishable place rather than the empty string, which every caller reads
// as "no album" and refuses to store anything under.
function albumDir(rel) {
    var f = String(rel === undefined || rel === null ? "" : rel)
    if (f === "") return ""
    var m = /\.cue\/track\d+$/i.exec(f)
    if (m) f = f.substring(0, m.index + 4)
    var i = f.lastIndexOf("/")
    return i > 0 ? f.substring(0, i) : "."
}

// A file:// URL for an arbitrary local path. Concatenating "file://" onto the
// path is wrong for a name containing a space, '#', '?' or '%': the loader
// reads those as separators or escapes and the image silently fails to load,
// which then looks exactly like "the album has no cover". Encoding each segment
// separately leaves the slashes alone. The first element is the empty string
// before a leading slash on an absolute path, so it is left untouched.
function fileUrl(path) {
    if (!path) return ""
    var parts = String(path).split("/")
    for (var i = 1; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
    return "file://" + parts.join("/")
}
