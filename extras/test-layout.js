#!/usr/bin/env node
// Exercises the cover geometry without a compositor or a running shell:
//   node extras/test-layout.js
"use strict"

const assert = require("node:assert/strict")
const Layout = require("../Layout.js")

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
const near = (actual, expected, what) =>
    assert.ok(Math.abs(actual - expected) < 1e-9,
        (what || "value") + ": expected " + expected + ", got " + actual)

// ---- artwork share ----

check("coverScalePct: auto reads the placement, pinned reads the setting", () => {
    assert.equal(Layout.coverScalePct("auto", true, 60), 100)
    assert.equal(Layout.coverScalePct("auto", false, 60), 30)
    assert.equal(Layout.coverScalePct("on", false, 60), 60)
    assert.equal(Layout.coverScalePct("off", true, 45), 45)
})

check("heroCover: a share of the pane, with a scaled floor", () => {
    assert.equal(Layout.heroCover(700, 100, 1), 700)
    assert.equal(Layout.heroCover(700, 30, 1), 210)
    assert.equal(Layout.heroCover(100, 30, 1), 48)
    assert.equal(Layout.heroCover(100, 30, 1.5), 72)
    assert.equal(Layout.heroCover(0, 100, 1), 48)
})

// ---- album view's square ----

check("albumCoverSize: half the window width binds on a normal panel", () => {
    // room = 1200 - 240 - 28 = 932; min(700, 600, 932)
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1), 600)
})

check("albumCoverSize: the track list's minimum width can bind", () => {
    // room = 1000 - 900 - 0 = 100
    assert.equal(Layout.albumCoverSize(1000, 700, 900, 0, 1), 100)
})

check("albumCoverSize: the pane height binds on a tall narrow window", () => {
    // min(400, 500, 1200 - 240) = 400
    assert.equal(Layout.albumCoverSize(1000, 400, 240, 0, 1), 400)
})

check("albumCoverSize: a cramped window still gets the floor", () => {
    // room = 300 - 240 - 40 = 20
    assert.equal(Layout.albumCoverSize(300, 700, 240, 20, 1), 48)
    assert.equal(Layout.albumCoverSize(300, 700, 240, 20, 1.5), 72)
})

// ---- the pane's square ----

const pane = (over) => Object.assign({
    shown: true, albumView: false, heroCover: 700, albumCover: 500,
    windowWidth: 1200, uiScale: 1
}, over)

check("paneCoverSize: hidden is zero", () => {
    assert.equal(Layout.paneCoverSize(pane({ shown: false })), 0)
})

check("paneCoverSize: the browser uses its hero, capped at 60% of the width", () => {
    assert.equal(Layout.paneCoverSize(pane({})), 700)
    assert.equal(Layout.paneCoverSize(pane({ windowWidth: 800 })), 480)
})

check("paneCoverSize: album view uses its own square", () => {
    assert.equal(Layout.paneCoverSize(pane({ albumView: true })), 500)
    // The album square is already capped by the list room, not by the 60% here.
    assert.equal(Layout.paneCoverSize(pane({ albumView: true, windowWidth: 400 })), 500)
})

check("paneCoverSize: a tiny window falls back to the floor", () => {
    // min(700, round(70 * 0.6) = 42) -> 42, floored to 48
    assert.equal(Layout.paneCoverSize(pane({ windowWidth: 70 })), 48)
    assert.equal(Layout.paneCoverSize(pane({ windowWidth: 70, uiScale: 2 })), 96)
})

// ---- pane width and the rule it eats ----

const width = (over) => Object.assign({
    shown: true, albumView: false, paneCoverSize: 600,
    coverPad: 14, padded: true, rule: 1
}, over)

check("coverPaneWidth: padding on reserves both margins and the rule", () => {
    assert.equal(Layout.coverPaneWidth(width({})), 600 + 28 + 1)
})

check("coverPaneWidth: padding off leaves the cover flush, no rule strip", () => {
    assert.equal(Layout.coverPaneWidth(width({ padded: false })), 600)
    assert.equal(Layout.coverPaneWidth(width({ padded: false, rule: 3 })), 600)
})

check("coverPaneWidth: album view never reserves the rule", () => {
    assert.equal(Layout.coverPaneWidth(width({ albumView: true })), 600 + 28)
})

check("coverPaneWidth: hidden is zero", () => {
    assert.equal(Layout.coverPaneWidth(width({ shown: false })), 0)
})

// ---- band placement ----

check("coverBandInset: the padding holds until the cover fills the pane", () => {
    assert.equal(Layout.coverBandInset(14, 700, 600), 14)
    assert.equal(Layout.coverBandInset(14, 700, 690), 5)
    assert.equal(Layout.coverBandInset(14, 700, 700), 0)
    // A cover larger than the pane must not produce a negative inset.
    assert.equal(Layout.coverBandInset(14, 700, 760), 0)
})

check("coverBandY: top, middle and bottom", () => {
    assert.equal(Layout.coverBandY("top", 700, 600, 14), 14)
    assert.equal(Layout.coverBandY("middle", 700, 600, 14), 50)
    assert.equal(Layout.coverBandY("bottom", 700, 600, 14), 86)
    assert.equal(Layout.coverBandY("bottom", 700, 700, 0), 0)
})

check("floatingCoverSize: hero, edges and floor", () => {
    assert.equal(Layout.floatingCoverSize(700, 756, 826, 20, 1), 700)
    assert.equal(Layout.floatingCoverSize(700, 400, 826, 20, 1), 360)
    assert.equal(Layout.floatingCoverSize(700, 400, 280, 20, 1), 240)
    assert.equal(Layout.floatingCoverSize(700, 80, 826, 20, 1), 48)
})

// ---- karaoke ----

check("karaokeCoverSize: the 60% width cap on a normal panel", () => {
    // min(826 - 80 = 746, round(756 * 0.6) = 454, 756 - 80 - 10 - 200 = 466)
    assert.equal(Layout.karaokeCoverSize(756, 826, 40, 10, 200, 1), 454)
})

check("karaokeCoverSize: the text column binds on a narrow panel", () => {
    // min(746, 300, 500 - 80 - 10 - 200 = 210)
    assert.equal(Layout.karaokeCoverSize(500, 826, 40, 10, 200, 1), 210)
})

check("karaokeCoverSize: the reading height binds on a short panel", () => {
    // min(200 - 80 = 120, 454, 466)
    assert.equal(Layout.karaokeCoverSize(756, 200, 40, 10, 200, 1), 120)
})

check("karaokeCoverSize: never below the scaled floor", () => {
    assert.equal(Layout.karaokeCoverSize(756, 100, 40, 10, 200, 1), 48)
    assert.equal(Layout.karaokeCoverSize(756, 100, 40, 10, 200, 2), 96)
})

// ---- lyric measure ----

check("lyricsColumnWidth: karaoke ignores the text-width setting", () => {
    assert.equal(Layout.lyricsColumnWidth(900, true, "narrow"), 900)
    assert.equal(Layout.lyricsColumnWidth(900, true, "wide"), 900)
})

check("lyricsColumnWidth: the reading view narrows by its setting", () => {
    near(Layout.lyricsColumnWidth(900, false, "wide"), 720)
    near(Layout.lyricsColumnWidth(900, false, "narrow"), 585)
    assert.equal(Layout.lyricsColumnWidth(900, false, "medium"), 900)
    assert.equal(Layout.lyricsColumnWidth(900, false, undefined), 900)
})

// ---- auto-hide of the artwork pane ----

const band = (over) => Object.assign({
    mode: "auto", width: 1000, windowWidth: 1000, uiScale: 1,
    screenWidth: 1536, frameRead: true, minWidth: 1000, slack: 6
}, over)

check("coverBandVisible: pinned modes win outright", () => {
    assert.equal(Layout.coverBandVisible(band({ mode: "on", width: 300 })), true)
    assert.equal(Layout.coverBandVisible(band({ mode: "off", width: 5000 })), false)
})

check("coverBandVisible: auto hides on a narrow window", () => {
    assert.equal(Layout.coverBandVisible(band({ width: 679 })), false)
    assert.equal(Layout.coverBandVisible(band({ width: 680 })), true)
    assert.equal(Layout.coverBandVisible(band({ width: 1019, uiScale: 1.5 })), false)
    assert.equal(Layout.coverBandVisible(band({ width: 1020, uiScale: 1.5 })), true)
})

check("coverBandVisible: unknown frame keeps the pane rather than flickering", () => {
    assert.equal(Layout.coverBandVisible(band({ screenWidth: 0, minWidth: 5000 })), true)
    assert.equal(Layout.coverBandVisible(band({ frameRead: false, minWidth: 5000 })), true)
})

check("coverBandVisible: the slack covers the compositor's rounding", () => {
    assert.equal(Layout.coverBandVisible(band({ windowWidth: 1013 })), true)   // 1019 >= 1000
    assert.equal(Layout.coverBandVisible(band({ windowWidth: 993 })), false)   // 999 < 1000
    assert.equal(Layout.coverBandVisible(band({ windowWidth: 994 })), true)    // 1000 >= 1000
    assert.equal(Layout.coverBandVisible(band({ windowWidth: 1014, minWidth: 1020 })), true)
    assert.equal(Layout.coverBandVisible(band({ windowWidth: 1013, minWidth: 1020 })), false)
})

// ---- window inset ----

check("windowInset: the measured panel frame", () => {
    // (3 + 3) * 1536 / 1920 = 4.8 -> 5, the value Hyprland's own window measures
    assert.equal(Layout.windowInset(3, 3, 1536, 1920), 5)
})

check("windowInset: unknown widths leave it at zero", () => {
    assert.equal(Layout.windowInset(3, 3, 0, 1920), 0)
    assert.equal(Layout.windowInset(3, 3, 1536, 0), 0)
    assert.equal(Layout.windowInset(0, 0, 1536, 1920), 0)
    assert.equal(Layout.windowInset(3, 3, 1536, 1536), 6)
})

// ---- compositor readings ----

check("optionInt: a plain int, and a CSS value that wins over it", () => {
    assert.equal(Layout.optionInt('{"int": 4}'), 4)
    assert.equal(Layout.optionInt('{"css": "3px", "int": 9}'), 3)
    assert.equal(Layout.optionInt('{"css": "2.6px"}'), 3)
    assert.equal(Layout.optionInt('{"int": 4.4}'), 4)
})

check("optionInt: negative and unusable answers become zero", () => {
    assert.equal(Layout.optionInt('{"css": "-2px"}'), 0)
    assert.equal(Layout.optionInt(""), 0)
    assert.equal(Layout.optionInt("null"), 0)
    assert.equal(Layout.optionInt("{}"), 0)
    assert.equal(Layout.optionInt("not json"), 0)
})

check("gapsOutHorizontal: one number is every side", () => {
    assert.equal(Layout.gapsOutHorizontal('{"css": "10"}'), 10)
    assert.equal(Layout.gapsOutHorizontal('{"int": 8}'), 8)
    assert.equal(Layout.gapsOutHorizontal('{"css": "10 10 10 10"}'), 10)
})

check("gapsOutHorizontal: two numbers are vertical then horizontal", () => {
    assert.equal(Layout.gapsOutHorizontal('{"css": "5 20"}'), 20)
    assert.equal(Layout.gapsOutHorizontal('{"css": "5 20 5 20"}'), 20)
})

check("gapsOutHorizontal: three numbers keep Hyprland's odd middle rule", () => {
    assert.equal(Layout.gapsOutHorizontal('{"css": "1 6 2"}'), 6)
})

check("gapsOutHorizontal: an asymmetric pair is averaged, not half-read", () => {
    // left 40 and right 20: the window loses 60 across, i.e. 30 per side.
    assert.equal(Layout.gapsOutHorizontal('{"css": "5 20 5 40"}'), 30)
    assert.equal(Layout.gapsOutHorizontal('{"css": "0 30 0 10"}'), 20)
})

check("gapsOutHorizontal: a negative side and malformed input are zero", () => {
    assert.equal(Layout.gapsOutHorizontal('{"css": "5 -20 5 40"}'), 0)
    assert.equal(Layout.gapsOutHorizontal(""), 0)
    assert.equal(Layout.gapsOutHorizontal("nope"), 0)
})

const monitors = JSON.stringify([
    { name: "DP-1", width: 2560, scale: 1.5 },
    { name: "HDMI-A-1", width: 1920, scale: 1 }
])

check("monitorWidthFor: matches the panel's screen by name", () => {
    assert.equal(Layout.monitorWidthFor(monitors, "HDMI-A-1"), 1920)
    assert.equal(Layout.monitorWidthFor(monitors, "DP-1"), 2560)
})

check("monitorWidthFor: falls back to the first entry when it cannot match", () => {
    assert.equal(Layout.monitorWidthFor(monitors, ""), 2560)
    assert.equal(Layout.monitorWidthFor(monitors, "UNKNOWN"), 2560)
})

check("monitorWidthFor: unusable answers are zero", () => {
    assert.equal(Layout.monitorWidthFor("[]", "DP-1"), 0)
    assert.equal(Layout.monitorWidthFor("nope", "DP-1"), 0)
    assert.equal(Layout.monitorWidthFor(JSON.stringify([{ name: "DP-1" }]), "DP-1"), 0)
})

check("monitorScaleFor: matches the panel's screen by name", () => {
    assert.equal(Layout.monitorScaleFor(monitors, "DP-1"), 1.5)
    assert.equal(Layout.monitorScaleFor(monitors, "HDMI-A-1"), 1)
})

check("monitorScaleFor: falls back to the first entry when it cannot match", () => {
    assert.equal(Layout.monitorScaleFor(monitors, ""), 1.5)
    assert.equal(Layout.monitorScaleFor(monitors, "UNKNOWN"), 1.5)
})

check("monitorScaleFor: a zero or unusable scale is zero", () => {
    assert.equal(Layout.monitorScaleFor(JSON.stringify([{ name: "DP-1", scale: 0 }]), "DP-1"), 0)
    assert.equal(Layout.monitorScaleFor("[]", "DP-1"), 0)
    assert.equal(Layout.monitorScaleFor("nope", "DP-1"), 0)
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
