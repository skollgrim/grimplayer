// Path arithmetic for the tag editor's "which file am I editing?" line.
//
// Kept out of TagEditor.qml so it can be exercised without a shell running:
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

if (typeof module !== "undefined" && module.exports) {
    module.exports = { realFile: realFile, relative: relative, describe: describe }
}
