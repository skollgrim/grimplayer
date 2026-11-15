#!/usr/bin/env node
// Exercises the tag editor's path line without a running shell:
//   node extras/test-paths.js
"use strict"

const assert = require("node:assert/strict")
const Paths = require("../Paths.js")

const MUSIC = "/home/user/Music"
const cases = [
    ["empty selection", Paths.describe([], MUSIC), ""],
    ["lone track", Paths.describe([MUSIC + "/Slomosa/2024 - Tundra Rock/01. Afghansk Rev.mp3"], MUSIC),
        "Slomosa/2024 - Tundra Rock/01. Afghansk Rev.mp3"],
    ["lone track outside the library", Paths.describe(["/mnt/other/Album/01.flac"], MUSIC),
        "/mnt/other/Album/01.flac"],
    ["cue virtual track folds to the cue sheet",
        Paths.describe([MUSIC + "/Ayreon/2017 - The Source/album.cue/track0003"], MUSIC),
        "Ayreon/2017 - The Source/album.cue"],
    ["one album", Paths.describe([
        MUSIC + "/Slomosa/2024 - Tundra Rock/01. Afghansk Rev.mp3",
        MUSIC + "/Slomosa/2024 - Tundra Rock/02. Rice.mp3"
    ], MUSIC), "Slomosa/2024 - Tundra Rock/"],
    ["one artist, two albums", Paths.describe([
        MUSIC + "/Slomosa/2020 - Slomosa/01. Horses.mp3",
        MUSIC + "/Slomosa/2024 - Tundra Rock/02. Rice.mp3"
    ], MUSIC), "Slomosa/"],
    ["two artists", Paths.describe([
        MUSIC + "/Slomosa/2024 - Tundra Rock/01. Afghansk Rev.mp3",
        MUSIC + "/Alcest/2024 - Tundra Rock/01. Flamme Jumelle.mp3"
    ], MUSIC), "/"],
    ["prefix trap: Foo must not swallow Foobar", Paths.describe([
        MUSIC + "/Foo/01.mp3",
        MUSIC + "/Foobar/01.mp3"
    ], MUSIC), "/"],
    ["trap below one artist: Foo vs Foo Tribute", Paths.describe([
        MUSIC + "/Band/Foo/01.mp3",
        MUSIC + "/Band/Foo Tribute/01.mp3"
    ], MUSIC), "Band/"],
    ["files directly in the library root", Paths.describe([
        MUSIC + "/a.mp3",
        MUSIC + "/b.mp3"
    ], MUSIC), "/"],
    ["outside the library, shared folder", Paths.describe([
        "/mnt/other/Album/01.flac",
        "/mnt/other/Album/02.flac"
    ], MUSIC), "/mnt/other/Album/"],
    ["outside the library, shared parent", Paths.describe([
        "/mnt/a/01.flac",
        "/mnt/b/02.flac"
    ], MUSIC), "/mnt/"],
    ["outside the library, nothing shared", Paths.describe([
        "/mnt/a/01.flac",
        "/srv/b/02.flac"
    ], MUSIC), "/"],
    ["trailing slash on musicDir", Paths.describe([
        MUSIC + "/Slomosa/2024 - Tundra Rock/01. Afghansk Rev.mp3"
    ], MUSIC + "/"), "Slomosa/2024 - Tundra Rock/01. Afghansk Rev.mp3"],
    ["no musicDir configured", Paths.describe([
        "/home/user/Music/Slomosa/01.mp3",
        "/home/user/Music/Slomosa/02.mp3"
    ], ""), "/home/user/Music/Slomosa/"],
    ["single cue sheet in a folder", Paths.describe([
        MUSIC + "/Ayreon/2017 - The Source/album.cue/track0001",
        MUSIC + "/Ayreon/2017 - The Source/album.cue/track0002"
    ], MUSIC), "Ayreon/2017 - The Source/"],
    ["cue and plain track in one folder", Paths.describe([
        MUSIC + "/Ayreon/2017 - The Source/album.cue/track0001",
        MUSIC + "/Ayreon/2017 - The Source/bonus.flac"
    ], MUSIC), "Ayreon/2017 - The Source/"],
    ["undefined file entry", Paths.describe([undefined], MUSIC), ""]
]

let failed = 0
for (const [name, actual, expected] of cases) {
    try {
        assert.equal(actual, expected)
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     expected: " + JSON.stringify(expected)
            + "\n     actual:   " + JSON.stringify(actual))
    }
}

let more = 0
function check(name, actual, expected) {
    more++
    try {
        assert.deepEqual(actual, expected)
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     expected: " + JSON.stringify(expected)
            + "\n     actual:   " + JSON.stringify(actual))
    }
}

// ---- localPath ----

check("localPath: strips file:// and decodes",
    Paths.localPath("file:///home/user/Music/01%20Song.flac"),
    "/home/user/Music/01 Song.flac")
check("localPath: strips Quickshell's qs:// scheme",
    Paths.localPath("qs:///home/user/.config/omarchy/plugins/skollgrim.grimplayer/extras/fetch_lyrics.py"),
    "/home/user/.config/omarchy/plugins/skollgrim.grimplayer/extras/fetch_lyrics.py")
check("localPath: a plain path is untouched",
    Paths.localPath("/home/user/Music/a b.flac"), "/home/user/Music/a b.flac")
check("localPath: a relative path is untouched",
    Paths.localPath("extras/open_folder.sh"), "extras/open_folder.sh")
check("localPath: encoded plus sign",
    Paths.localPath("file:///tmp/a%2Bb.flac"), "/tmp/a+b.flac")
check("localPath: a broken escape is left as it was",
    Paths.localPath("file:///tmp/%E0%A4%A"), "/tmp/%E0%A4%A")
check("localPath: empty and undefined", [Paths.localPath(""), Paths.localPath(undefined)],
    ["", ""])

// ---- sharedDir ----

const dirs = (...list) => Paths.sharedDir(list)
check("sharedDir: empty list", dirs(), "")
check("sharedDir: one directory is itself", dirs("/music/A"), "/music/A")
check("sharedDir: siblings share their parent",
    dirs("/music/A", "/music/B"), "/music")
check("sharedDir: no sibling prefix bleed",
    dirs("/music/A", "/music/AB"), "/music")
check("sharedDir: root when nothing is shared",
    dirs("/a/x", "/b/y"), "/")
check("sharedDir: same directory twice", dirs("/music/A", "/music/A"), "/music/A")

// ---- folderTarget ----

const MUSIC_DIR = "/music"
const LISTS = {
    tracks: [{ file: "Band/Album/01.flac" }],
    albums: [{ tracks: [{ file: "Band/Album/01.flac" }] }, { tracks: [] }],
    artists: [
        { albums: [{ tracks: [{ file: "Band/One/01.flac" }] },
                   { tracks: [{ file: "Band/Two/01.flac" }] }] },
        { albums: [] }
    ]
}
const dirOf = (file) => file.split("/").slice(0, -1).join("/")
const target = (pane, index) => Paths.folderTarget(pane, index, LISTS, MUSIC_DIR, dirOf)

check("folderTarget: a track opens its album and selects the file", target("tracks", 0),
    { dir: "/music/Band/Album", select: "/music/Band/Album/01.flac" })
check("folderTarget: an album opens its directory, nothing selected",
    target("albums", 0), { dir: "/music/Band/Album", select: "" })
check("folderTarget: an album with no tracks has nothing to open",
    target("albums", 1), null)
check("folderTarget: an artist opens the shared directory of its albums",
    target("artists", 0), { dir: "/music/Band", select: "" })
check("folderTarget: an artist with no albums has nothing to open",
    target("artists", 1), null)
check("folderTarget: out-of-range rows", [target("tracks", 9), target("tracks", -1)],
    [null, null])
check("folderTarget: no music directory", Paths.folderTarget("tracks", 0, LISTS, "", dirOf),
    null)
check("folderTarget: no album-dir resolver",
    Paths.folderTarget("tracks", 0, LISTS, MUSIC_DIR, null), null)

// ---- environment paths ----

check("stateDir: XDG_STATE_HOME wins", Paths.stateDir("/state", "/home/user"),
    "/state/skollgrim.grimplayer")
check("stateDir: falls back to ~/.local/state", Paths.stateDir(null, "/home/user"),
    "/home/user/.local/state/skollgrim.grimplayer")
check("stateDir: an empty HOME is not spelled null", Paths.stateDir(null, null),
    "/.local/state/skollgrim.grimplayer")
check("stateDir: an empty XDG value falls back", Paths.stateDir("", "/home/user"),
    "/home/user/.local/state/skollgrim.grimplayer")

check("musicDir: XDG_MUSIC_DIR wins", Paths.musicDir("/library", "/home/user"), "/library")
check("musicDir: falls back to ~/Music", Paths.musicDir(null, "/home/user"),
    "/home/user/Music")
check("musicDir: an empty HOME is not spelled null", Paths.musicDir(null, null), "/Music")
check("musicDir: an empty XDG value falls back", Paths.musicDir("", "/home/user"),
    "/home/user/Music")

// ---- music root as the settings card stores it ----

check("musicRoot: an absolute path is kept", Paths.musicRoot("/library", "/home/user"),
    "/library")
check("musicRoot: a trailing slash is dropped", Paths.musicRoot("/library/", "/home/user"),
    "/library")
check("musicRoot: surrounding whitespace is trimmed",
    Paths.musicRoot("  /library\n", "/home/user"), "/library")
check("musicRoot: ~ expands to the home directory", Paths.musicRoot("~/Music", "/home/user"),
    "/home/user/Music")
check("musicRoot: ~ alone expands to the home directory", Paths.musicRoot("~", "/home/user"),
    "/home/user")
check("musicRoot: a relative path is refused", Paths.musicRoot("Music", "/home/user"), "")
check("musicRoot: a bare root is refused", Paths.musicRoot("/", "/home/user"), "")
check("musicRoot: empty and missing values are refused",
    [Paths.musicRoot("", "/home/user"), Paths.musicRoot(null, "/home/user")], ["", ""])
check("musicRoot: ~ without a home is refused", Paths.musicRoot("~/Music", null), "")

// ---- MPD's own music_directory ----

check("config: reads music_directory out of the full block",
    Paths.musicDirectoryFromConfig(
        "music_directory: /home/user/Music\nplaylist_directory: /home/user/.mpd/playlists\n"
        + "db_file: /home/user/.mpd/database\naudio_output: pulse\n", "/home/user"),
    "/home/user/Music")
check("config: expands ~ in the value",
    Paths.musicDirectoryFromConfig("music_directory: ~/Music\n", "/home/user"),
    "/home/user/Music")
check("config: drops a trailing slash",
    Paths.musicDirectoryFromConfig("music_directory: /srv/music/\n", "/home/user"),
    "/srv/music")
check("config: keeps spaces in the folder name",
    Paths.musicDirectoryFromConfig("music_directory: /mnt/My Music\n", "/home/user"),
    "/mnt/My Music")
check("config: a colon in the folder is not a separator",
    Paths.musicDirectoryFromConfig("music_directory: /mnt/music: archive\n", "/home/user"),
    "/mnt/music: archive")
check("config: tolerates CRLF line endings",
    Paths.musicDirectoryFromConfig(
        "music_directory: /home/user/Music\r\nplaylist_directory: /tmp\r\n", "/home/user"),
    "/home/user/Music")
check("config: a missing key leaves the default alone",
    Paths.musicDirectoryFromConfig("playlist_directory: /tmp\n", "/home/user"), "")
check("config: an empty value is refused",
    Paths.musicDirectoryFromConfig("music_directory: \n", "/home/user"), "")
check("config: a relative value is refused",
    Paths.musicDirectoryFromConfig("music_directory: Music\n", "/home/user"), "")
check("config: a bare root is refused",
    Paths.musicDirectoryFromConfig("music_directory: /\n", "/home/user"), "")
check("config: a key that merely starts the same is ignored",
    Paths.musicDirectoryFromConfig("music_directory_extra: /nope\n", "/home/user"), "")
check("config: an empty or missing answer is refused",
    [Paths.musicDirectoryFromConfig("", "/home/user"),
     Paths.musicDirectoryFromConfig(null, "/home/user")], ["", ""])

if (failed > 0) {
    console.log("\n" + failed + " of " + (cases.length + more) + " failed")
    process.exit(1)
}
console.log("\n" + (cases.length + more) + " passed")
