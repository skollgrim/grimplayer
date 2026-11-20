#!/usr/bin/env node
// Exercises the cover cache naming and file URLs without a running shell:
//   node extras/test-covers.js
"use strict"

const assert = require("node:assert/strict")
const Covers = require("../Covers.js")

let failed = 0
function check(name, fn) {
    try {
        fn()
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     " + String(err.message).replace(/\n/g, "\n     "))
    }
}

check("the cache hash is stable and agrees with the recorded values", () => {
    assert.equal(Covers.stem("A/Album"), "3d0dbc40")
    assert.equal(Covers.stem("B/Album"), "b00e9a7d")
    assert.equal(Covers.stem("A/Album/01.flac"), "9d574fda")
    assert.notEqual(Covers.stem("A/Album"), Covers.stem("B/Album"))
})

check("extracted and downloaded covers get distinct names", () => {
    assert.equal(Covers.fileName("A/Album"), "3d0dbc40.jpg")
    assert.equal(Covers.onlineFileName("A/Album"), "3d0dbc40.online.jpg")
})

check("albumDir folds cue tracks and names the music root", () => {
    assert.equal(Covers.albumDir("A/album.cue/track0003"), "A")
    assert.equal(Covers.albumDir("song.flac"), ".")
    assert.equal(Covers.albumDir("/song.flac"), "/")
    assert.equal(Covers.albumDir(""), "")
})

check("fileUrl encodes every segment, absolute or relative", () => {
    assert.equal(Covers.fileUrl("/music/my album/cover #1.jpg"),
        "file:///music/my%20album/cover%20%231.jpg")
    assert.equal(Covers.fileUrl("my album/cover #1.jpg"),
        "file://my%20album/cover%20%231.jpg")
    assert.equal(Covers.fileUrl("#tag/cover.jpg"), "file://%23tag/cover.jpg")
    assert.equal(Covers.fileUrl("/music/100% sure/¿cover?.jpg"),
        "file:///music/100%25%20sure/%C2%BFcover%3F.jpg")
    assert.equal(Covers.fileUrl(""), "")
})

check("pathFromUrl round-trips fileUrl and leaves plain paths alone", () => {
    for (const p of ["/music/a b/#tag/100% ü.jpg", "relative/a b/#tag/ü.jpg", "/plain/path.jpg"]) {
        assert.equal(Covers.pathFromUrl(Covers.fileUrl(p)), p)
    }
    assert.equal(Covers.pathFromUrl("/not/a/url.jpg"), "/not/a/url.jpg")
    assert.equal(Covers.pathFromUrl("https://example.com/cover.jpg"),
        "https://example.com/cover.jpg")
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
