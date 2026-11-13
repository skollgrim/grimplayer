// Path arithmetic shared by the panel and the tag editor.
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

function libraryDir(musicDir) {
    var dir = String(musicDir === undefined || musicDir === null ? "" : musicDir)
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
        realFile: realFile,
        relative: relative,
        describe: describe,
        localPath: localPath,
        sharedDir: sharedDir,
        folderTarget: folderTarget
    }
}
