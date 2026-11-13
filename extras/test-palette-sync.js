#!/usr/bin/env node
// Exercises the palette-selection rules that GrimPlayer.syncTheme() used to
// hold inline: the cache hit, the cover race guard and the no-art fallback.
//   node extras/test-palette-sync.js
"use strict"

const assert = require("node:assert/strict")
const Sync = require("../PaletteSync.js")

const CACHED = { background: "#231512", foreground: "#eae4e3",
                 muted: "#8a7a76", accent: "#b84a2f" }

let failed = 0
function check(name, fn) {
    try {
        fn()
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     " + err.message)
    }
}

// A cover mid-probe: artwork exists, the quantizer still holds the previous
// album's colours (note the source), and nothing has been cached yet.
function state(overrides) {
    return Object.assign({
        adaptive: true,
        hasArt: true,
        paletteSource: "file:///old.jpg",
        paletteSize: 8,
        noArt: false
    }, overrides || {})
}

check("adaptive colours off resets even when the cover is cached", () => {
    assert.deepEqual(Sync.pick(state({ adaptive: false }), "file:///new.jpg", CACHED),
        { action: Sync.RESET })
})

check("a cache hit is applied without consulting the quantizer", () => {
    const out = Sync.pick(state({ paletteSource: "" }), "file:///new.jpg", CACHED)
    assert.equal(out.action, Sync.DERIVED)
    assert.equal(out.palette, CACHED)
})

check("a cache hit wins over a still-stale quantizer", () => {
    const out = Sync.pick(state(), "file:///new.jpg", CACHED)
    assert.equal(out.action, Sync.DERIVED)
})

check("colours claimed for this exact cover are applied", () => {
    const out = Sync.pick(state({ paletteSource: "file:///new.jpg" }),
        "file:///new.jpg", null)
    assert.equal(out.action, Sync.APPLY)
})

check("the race guard holds the previous palette while a new cover loads", () => {
    // The quantizer's colours still belong to the old cover: applying them
    // would paint the new album with the old one's ground and cache it there.
    assert.equal(Sync.pick(state(), "file:///new.jpg", null).action, Sync.HOLD)
})

check("the race guard also holds when the palette is empty", () => {
    assert.equal(Sync.pick(state({ paletteSize: 0 }), "file:///new.jpg", null).action,
        Sync.HOLD)
})

check("a cover with no artwork at all resets", () => {
    assert.equal(Sync.pick(state({ hasArt: false, paletteSize: 0, noArt: true }),
        "file:///new.jpg", null).action, Sync.RESET)
})

check("a cover with no artwork resets even with stale colours held", () => {
    assert.equal(Sync.pick(state({ noArt: true }), "file:///new.jpg", null).action,
        Sync.RESET)
})

check("an empty, still-probing cover holds rather than flashing the theme", () => {
    assert.equal(Sync.pick(state({ hasArt: false, paletteSize: 0 }),
        "file:///new.jpg", null).action, Sync.HOLD)
})

check("a missing resolved source never matches quantizer colours from a cover", () => {
    assert.equal(Sync.pick(state({ paletteSource: "" }), "", null).action, Sync.APPLY,
        "empty to empty is still a match, which is how the panel behaved before")
    assert.equal(Sync.pick(state(), "", null).action, Sync.HOLD)
})

check("cache hits and resets are mutually exclusive and ordered", () => {
    // Adaptive off beats everything; the cache beats the race guard.
    assert.equal(Sync.pick(state({ adaptive: false }), "file:///new.jpg", CACHED).action,
        Sync.RESET)
    assert.equal(Sync.pick(state({ noArt: true }), "file:///new.jpg", CACHED).action,
        Sync.DERIVED)
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
