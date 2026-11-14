#!/usr/bin/env node
// Exercises the tag editor's path line without a running shell:
//   node extras/test-paths.js
"use strict"

const assert = require("node:assert/strict")
const Paths = require("../Paths.js")

const MUSIC = "/home/grim/Music"
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
        "/home/grim/Music/Slomosa/01.mp3",
        "/home/grim/Music/Slomosa/02.mp3"
    ], ""), "/home/grim/Music/Slomosa/"],
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
    Paths.localPath("file:///home/grim/Music/01%20Song.flac"),
    "/home/grim/Music/01 Song.flac")
check("localPath: strips Quickshell's qs:// scheme",
    Paths.localPath("qs:///home/grim/.config/omarchy/plugins/skollgrim.grimplayer/fetch_lyrics.py"),
    "/home/grim/.config/omarchy/plugins/skollgrim.grimplayer/fetch_lyrics.py")
check("localPath: a plain path is untouched",
    Paths.localPath("/home/grim/Music/a b.flac"), "/home/grim/Music/a b.flac")
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

check("stateDir: XDG_STATE_HOME wins", Paths.stateDir("/state", "/home/grim"),
    "/state/skollgrim.grimplayer")
check("stateDir: falls back to ~/.local/state", Paths.stateDir(null, "/home/grim"),
    "/home/grim/.local/state/skollgrim.grimplayer")
check("stateDir: an empty HOME is not spelled null", Paths.stateDir(null, null),
    "/.local/state/skollgrim.grimplayer")
check("stateDir: an empty XDG value falls back", Paths.stateDir("", "/home/grim"),
    "/home/grim/.local/state/skollgrim.grimplayer")

check("musicDir: XDG_MUSIC_DIR wins", Paths.musicDir("/library", "/home/grim"), "/library")
check("musicDir: falls back to ~/Music", Paths.musicDir(null, "/home/grim"),
    "/home/grim/Music")
check("musicDir: an empty HOME is not spelled null", Paths.musicDir(null, null), "/Music")
check("musicDir: an empty XDG value falls back", Paths.musicDir("", "/home/grim"),
    "/home/grim/Music")

if (failed > 0) {
    console.log("\n" + failed + " of " + (cases.length + more) + " failed")
    process.exit(1)
}
console.log("\n" + (cases.length + more) + " passed")
