// Path arithmetic shared by the panel, the tag editor and the service: the XDG
// state and music roots, MPD's own music_directory from its `config` answer, the
// file behind an MPD path, and how a selection is summarised in the tag editor's
// header.
//
// Kept out of the QML so it can be exercised without a shell running:
// extras/test-paths.js loads this file under Node. The guarded module export at
// the bottom is inert inside QML, where `module` does not exist.

// The file that really exists behind an MPD path. A cue album is listed as
// virtual tracks ("album.cue/track0003"), and the cue sheet is the thing on
// disk. Same fold as Covers.albumDir.
function realFile(path) {
    var p = String(path === undefined || path === null ? "" : path)
    var cue = /\.cue\/track\d+$/i.exec(p)
    return cue ? p.substring(0, cue.index + 4) : p
}

// The plugin's own directory under the XDG state home: settings, the palette
// cache and the cover cache all live below it.
//
// The two environment values are passed in rather than read here, so this stays
// a pure script Node can exercise. Quickshell.env() answers null for an unset
// variable, and null does not stringify to "", so both are guarded: an
// unguarded HOME would root the path at "null/.local/state" instead of failing.
// An empty HOME leaves the path rooted at "/.local/state", which is still one
// real path rather than a concatenation accident.
function stateDir(xdgStateHome, home) {
    var base = xdgStateHome
        ? String(xdgStateHome)
        : (home ? String(home) : "") + "/.local/state"
    return base + "/skollgrim.grimplayer"
}

// The XDG guess at MPD's music_directory: $XDG_MUSIC_DIR, or ~/Music. It is what
// the player starts with until -- or unless -- the server's own `config` answer
// arrives, since MPD does not have to live where the XDG spec suggests. Guarded
// for the same reason as stateDir: an unset HOME must not become "null/Music".
function musicDir(xdgMusicDir, home) {
    if (xdgMusicDir) return String(xdgMusicDir)
    return (home ? String(home) : "") + "/Music"
}

// A music root as the settings card stores it: absolute, trimmed and without a
// trailing slash, so the panel's `root + "/" + rel` never doubles the separator.
// `home` lets a typed `~/Music` become the real path rather than a folder named
// "~". An empty or relative value -- or a bare "/", which no library lives at --
// answers "" so the caller keeps the previous root instead of pointing every
// file operation at a path that cannot be right.
function musicRoot(value, home) {
    var p = String(value === undefined || value === null ? "" : value).trim()
    var base = home ? String(home) : ""
    if (base !== "") {
        if (p === "~") p = base
        else if (p.indexOf("~/") === 0) p = base + p.substring(1)
    }
    if (p.length < 2 || p.charAt(0) !== "/") return ""
    return libraryDir(p)
}

// The library root MPD reports for itself. The `config` command answers with one
// `key: value` line per configured setting, and `music_directory` is the folder
// every path in `listallinfo` is relative to -- so it is the one value that is
// right by construction, where the XDG derivation is only a guess. Normalised
// through musicRoot, which expands `~` and refuses a value that is not an
// absolute path. Returns "" when the answer has no usable line: a server that
// refuses `config` (older or remote MPD) simply leaves the caller's default
// alone.
function musicDirectoryFromConfig(text, home) {
    var lines = String(text === undefined || text === null ? "" : text).split("\n")
    for (var i = 0; i < lines.length; i++) {
        // Tolerate CRLF: a trailing \r would otherwise be carried into the path.
        var line = lines[i]
        if (line.length > 0 && line.charAt(line.length - 1) === "\r")
            line = line.substring(0, line.length - 1)
        var sep = line.indexOf(": ")
        if (sep < 0) continue
        if (line.substring(0, sep) !== "music_directory") continue
        return musicRoot(line.substring(sep + 2), home)
    }
    return ""
}

function libraryDir(root) {
    var dir = String(root === undefined || root === null ? "" : root)
    // A trailing slash would turn the prefix test into "//" and leak the
    // absolute path into the line.
    while (dir.length > 1 && dir.charAt(dir.length - 1) === "/") {
        dir = dir.substring(0, dir.length - 1)
    }
    return dir
}

// Relative to the music library when inside it, absolute otherwise. The library
// prefix is the same for every file in a selection and only pushes the part that
// tells two files apart out of the line.
function relative(path, musicDir) {
    var dir = libraryDir(musicDir)
    var p = String(path)
    if (dir !== "" && p.indexOf(dir + "/") === 0) p = p.substring(dir.length + 1)
    return p
}

// One line naming the selection: a lone file's path, or the deepest folder every
// file shares. `paths` is an array of MPD file paths; an empty selection gives "".
function describe(paths, musicDir) {
    if (!paths || paths.length === 0) return ""
    var dir = libraryDir(musicDir)
    var first = realFile(paths[0])
    if (paths.length === 1) return relative(first, dir)

    var cut = first.lastIndexOf("/")
    var prefix = cut > 0 ? first.substring(0, cut) : ""
    // Walk the shared prefix up one folder at a time until every file is under
    // it. Comparing against prefix + "/" rather than the bare prefix is what
    // keeps "Foo" from swallowing "Foobar".
    for (var i = 1; i < paths.length && prefix !== ""; i++) {
        var p = realFile(paths[i])
        while (prefix !== "" && p.indexOf(prefix + "/") !== 0) {
            var slash = prefix.lastIndexOf("/")
            prefix = slash > 0 ? prefix.substring(0, slash) : ""
        }
    }
    // Nothing shared, or the selection is the whole library: the library root is
    // the honest answer, and "/" reads better than the absolute path it stands
    // for.
    if (prefix === "" || prefix === dir) return "/"
    return relative(prefix, dir) + "/"
}

// A local filesystem path from a URL the QML engine produced. Quickshell
// serves the plugin's own files under qs:// and an Image reports file://, so
// the scheme is stripped and the rest decoded. A string that is already a plain
// path comes back untouched. Only meant for local URLs.
function localPath(url) {
    var u = String(url === undefined || url === null ? "" : url)
    var scheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//
    if (!scheme.test(u)) return u
    u = u.replace(scheme, "")
    try { u = decodeURIComponent(u) } catch (e) {}
    return u
}

// The deepest directory every path in `dirs` shares. An artist has no single
// album folder, so the folder shortcut opens this instead; when the albums are
// scattered it falls back to the root they do share.
function sharedDir(dirs) {
    if (!dirs || dirs.length === 0) return ""
    var parts = String(dirs[0]).split("/")
    for (var i = 1; i < dirs.length; i++) {
        var other = String(dirs[i]).split("/")
        var n = 0
        while (n < parts.length && n < other.length && parts[n] === other[n]) n++
        parts = parts.slice(0, n)
        if (parts.length === 0) return "/"
    }
    return parts.join("/") || "/"
}

// What the folder shortcut opens for a row: the directory, plus the file to
// select when the row is a track. `lists` carries the three pane models. The
// album directory comes from the caller's albumDirOf, so the cue fold stays in
// the one place that already implements it. Null when there is nothing to open.
function folderTarget(pane, index, lists, musicDir, albumDirOf) {
    var music = String(musicDir === undefined || musicDir === null ? "" : musicDir)
    if (music === "" || typeof albumDirOf !== "function") return null
    var source = lists || {}
    var artists = source.artists || []
    var albums = source.albums || []
    var tracks = source.tracks || []
    var dirOf = function (file) { return String(albumDirOf(file)) }

    if (pane === "tracks") {
        var track = index >= 0 && index < tracks.length ? tracks[index] : null
        if (!track) return null
        return {
            dir: music + "/" + dirOf(track.file),
            select: music + "/" + track.file
        }
    }

    if (pane === "albums") {
        var album = index >= 0 && index < albums.length ? albums[index] : null
        if (!album || !album.tracks || album.tracks.length === 0) return null
        return { dir: music + "/" + dirOf(album.tracks[0].file), select: "" }
    }

    var artist = index >= 0 && index < artists.length ? artists[index] : null
    if (!artist || !artist.albums || artist.albums.length === 0) return null
    var dirs = []
    for (var i = 0; i < artist.albums.length; i++) {
        var artistTracks = artist.albums[i].tracks
        if (artistTracks && artistTracks.length > 0)
            dirs.push(music + "/" + dirOf(artistTracks[0].file))
    }
    return dirs.length === 0 ? null : { dir: sharedDir(dirs), select: "" }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        stateDir: stateDir,
        musicDir: musicDir,
        musicRoot: musicRoot,
        musicDirectoryFromConfig: musicDirectoryFromConfig,
        relative: relative,
        describe: describe,
        localPath: localPath,
        sharedDir: sharedDir,
        folderTarget: folderTarget
    }
}
