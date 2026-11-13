#!/usr/bin/env node
// Exercises the lyrics parser and its scroll arithmetic without a running shell:
//   node extras/test-lyrics.js
"use strict"

const assert = require("node:assert/strict")
const Lyrics = require("../Lyrics.js")

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
function lines(list) {
    return list.map(([time, text]) => ({ time: time, text: text }))
}

// ---- parse ----

check("parse: empty input is an empty list", () => {
    assert.deepEqual(Lyrics.parse(""), [])
    assert.deepEqual(Lyrics.parse(undefined), [])
})

check("parse: plain text keeps file order, drops blank lines", () => {
    assert.deepEqual(Lyrics.parse("first line\n\n  second line  \r\nthird"),
        lines([[-1, "first line"], [-1, "second line"], [-1, "third"]]))
})

check("parse: hundredths", () => {
    assert.deepEqual(Lyrics.parse("[00:12.34] hello"),
        lines([[12.34, "hello"]]))
})

check("parse: colon fraction spelling", () => {
    assert.deepEqual(Lyrics.parse("[01:02:05] late"),
        lines([[62.05, "late"]]))
})

check("parse: three fraction digits are milliseconds", () => {
    assert.deepEqual(Lyrics.parse("[00:01.250] mid"),
        lines([[1.25, "mid"]]))
})

check("parse: one fraction digit is tenths", () => {
    assert.deepEqual(Lyrics.parse("[00:03.5] half"), lines([[3.5, "half"]]))
})

check("parse: three minute digits", () => {
    assert.deepEqual(Lyrics.parse("[100:00.00] long"), lines([[6000, "long"]]))
})

check("parse: metadata-only lines vanish", () => {
    assert.deepEqual(Lyrics.parse("[ar:A Band]\n[ti:A Song]\n[offset:+500]\nreal"),
        lines([[-1, "real"]]))
})

check("parse: a bracket heading in a plain file survives", () => {
    assert.deepEqual(Lyrics.parse("[Chorus]\nsing"), lines([[-1, "[Chorus]"], [-1, "sing"]]))
})

check("parse: one timestamp repeated on a line yields one entry per time", () => {
    assert.deepEqual(Lyrics.parse("[00:10.00][00:20.00] same"),
        lines([[10, "same"], [20, "same"]]))
})

check("parse: a timestamp with no words is dropped", () => {
    assert.deepEqual(Lyrics.parse("[00:10.00]\n[00:11.00] words"), lines([[11, "words"]]))
})

check("parse: timed lines sort first, plain lines follow in order", () => {
    assert.deepEqual(Lyrics.parse("intro\n[00:20.00] second\n[00:10.00] first\noutro"),
        lines([[10, "first"], [20, "second"], [-1, "intro"], [-1, "outro"]]))
})

check("parse: equal timestamps keep their file order", () => {
    assert.deepEqual(Lyrics.parse("[00:10.00] one\n[00:10.00] two"),
        lines([[10, "one"], [10, "two"]]))
})

check("parse: bare carriage returns split lines too", () => {
    assert.deepEqual(Lyrics.parse("a\rb"), lines([[-1, "a"], [-1, "b"]]))
})

// ---- activeIndex ----

const timed = lines([[5, "one"], [10, "two"], [15, "three"]])

check("activeIndex: nothing before the first line", () => {
    assert.equal(Lyrics.activeIndex(timed, 0), -1)
    assert.equal(Lyrics.activeIndex([], 10), -1)
    assert.equal(Lyrics.activeIndex(null, 10), -1)
})

check("activeIndex: a line lights up as its moment arrives", () => {
    assert.equal(Lyrics.activeIndex(timed, 5), 0)
    assert.equal(Lyrics.activeIndex(timed, 9.7), 0)
    // Within the lead, the next line is already the one to mark.
    assert.equal(Lyrics.activeIndex(timed, 9.9), 1)
    assert.equal(Lyrics.activeIndex(timed, 10), 1)
    assert.equal(Lyrics.activeIndex(timed, 99), 2)
})

check("activeIndex: the quarter second of lead", () => {
    assert.equal(Lyrics.activeIndex(timed, 4.76), 0)
    assert.equal(Lyrics.activeIndex(timed, 4.74), -1)
})

check("activeIndex: a positive offset delays the highlight", () => {
    assert.equal(Lyrics.activeIndex(timed, 10, 1000), 0)
    assert.equal(Lyrics.activeIndex(timed, 11, 1000), 1)
})

check("activeIndex: a negative offset advances it", () => {
    assert.equal(Lyrics.activeIndex(timed, 9, -1000), 1)
})

check("activeIndex: plain lines never become the active one", () => {
    assert.equal(Lyrics.activeIndex(lines([[-1, "a"], [-1, "b"]]), 100), -1)
    assert.equal(Lyrics.activeIndex(lines([[-1, "a"], [5, "b"]]), 1), -1)
})

// ---- scroll arithmetic ----

check("scrollTarget: centres a line in the viewport", () => {
    assert.equal(Lyrics.scrollTarget(500, 20, 200, 1000), 410)
})

check("scrollTarget: the first lines rest against the top", () => {
    assert.equal(Lyrics.scrollTarget(0, 20, 200, 1000), 0)
})

check("scrollTarget: the last lines rest against the bottom", () => {
    assert.equal(Lyrics.scrollTarget(980, 20, 200, 1000), 800)
})

check("scrollTarget: content shorter than the viewport does not scroll", () => {
    assert.equal(Lyrics.scrollTarget(50, 20, 200, 120), 0)
})

check("scrollBy: a step, clamped at both ends", () => {
    assert.equal(Lyrics.scrollBy(400, 50, 1000, 200), 450)
    assert.equal(Lyrics.scrollBy(10, -50, 1000, 200), 0)
    assert.equal(Lyrics.scrollBy(790, 50, 1000, 200), 800)
    assert.equal(Lyrics.scrollBy(0, 50, 150, 200), 0)
})

check("scrollEdge: home and end, clamped for short content", () => {
    assert.equal(Lyrics.scrollEdge(0, 1000, 200), 0)
    assert.equal(Lyrics.scrollEdge(1, 1000, 200), 800)
    assert.equal(Lyrics.scrollEdge(1, 150, 200), 0)
})

// ---- cache paths ----

check("safeName: mirrors the helper's filename rules", () => {
    assert.equal(Lyrics.safeName("Sigur Rós"), "Sigur Rós")
    assert.equal(Lyrics.safeName("AC/DC"), "AC-DC")
    assert.equal(Lyrics.safeName("a\\b"), "a-b")
    assert.equal(Lyrics.safeName("  spaced   out  "), "spaced out")
    assert.equal(Lyrics.safeName("..hidden.."), "hidden")
    assert.equal(Lyrics.safeName(""), "Unknown")
    assert.equal(Lyrics.safeName(null), "Unknown")
    assert.equal(Lyrics.safeName("a\u0001b"), "a-b")
})

check("cacheStems: full title and its parenthetical-free short form", () => {
    assert.deepEqual(Lyrics.cacheStems("/home/grim/.lyrics", "Sigur Rós", "Hoppípolla (Live)"),
        ["/home/grim/.lyrics/Sigur Rós - Hoppípolla (Live)",
         "/home/grim/.lyrics/Sigur Rós - Hoppípolla"])
})

check("cacheStems: one stem when there is nothing to shorten", () => {
    assert.deepEqual(Lyrics.cacheStems("/cache", "Band", "Song"),
        ["/cache/Band - Song"])
})

check("cacheStems: bracketed suffixes count as a parenthetical", () => {
    assert.deepEqual(Lyrics.cacheStems("/cache", "Band", "Song [Remastered]"),
        ["/cache/Band - Song [Remastered]", "/cache/Band - Song"])
})

check("localStem: a sidecar sits beside the track, without its extension", () => {
    assert.equal(Lyrics.localStem("/music", "Band/Album/01. Song. Final.flac"),
        "/music/Band/Album/01. Song. Final")
    assert.equal(Lyrics.localStem("/music", "Band/Album/readme"), "/music/Band/Album/readme")
    assert.equal(Lyrics.localStem("/music", "Band/Album.cue/track0003"),
        "/music/Band/Album.cue/track0003")
})

// ---- helper argv ----

const base = {
    script: "/plugins/fetch_lyrics.py",
    musicDir: "/music",
    file: "Band/Album/01.flac",
    artist: "Band",
    title: "Song",
    album: "Album",
    duration: "245"
}

check("helperArgs: the argument order the helper parses", () => {
    assert.deepEqual(Lyrics.helperArgs(base), ["python3", "/plugins/fetch_lyrics.py",
        "--music-dir", "/music", "--file", "Band/Album/01.flac",
        "--artist", "Band", "--title", "Song", "--album", "Album",
        "--duration", "245"])
})

check("helperArgs: offline appends the flag, online leaves it out", () => {
    assert.equal(Lyrics.helperArgs(base).includes("--offline"), false)
    assert.deepEqual(Lyrics.helperArgs(Object.assign({}, base, { offline: true })).slice(-1),
        ["--offline"])
})

check("helperArgs: missing values become empty strings", () => {
    assert.deepEqual(Lyrics.helperArgs({ script: "s" }), ["python3", "s",
        "--music-dir", "", "--file", "", "--artist", "", "--title", "",
        "--album", "", "--duration", ""])
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
