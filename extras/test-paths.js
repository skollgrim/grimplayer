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

if (failed > 0) {
    console.log("\n" + failed + " of " + cases.length + " failed")
    process.exit(1)
}
console.log("\n" + cases.length + " passed")
