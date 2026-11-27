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

check("browserListMinWidth: the old 40% until a readable maximum", () => {
    assert.equal(Layout.browserListMinWidth(1200, 1), 480)
    assert.equal(Layout.browserListMinWidth(2384, 1), 680)
    assert.equal(Layout.browserListMinWidth(3000, 1.5), 1020)
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

check("albumCoverSize: the shared right gutter is reserved once", () => {
    // Room is width - list - gutter - padding; the old formula took padding twice.
    assert.equal(Layout.albumCoverSize(1000, 900, 700, 0, 1, 100, 40), 260)
    assert.equal(Layout.albumCoverSize(1000, 900, 700, 0, 1, 100, 0), 300)
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1, 100, 40), 600)
})

check("albumCoverSize: the scale holds the art back from the natural fit", () => {
    // natural fit 600: 50% is 300, 25% is 150; an omitted scale still means 100%
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1), 600)
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1, 50), 300)
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1, 25), 150)
})

check("albumCoverSize: scaling never drops below the readability floor", () => {
    // fit 600, 5% is 30, floored at 48
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1, 5), 48)
})

check("albumCoverSize: above 100 grows into spare room but keeps the list", () => {
    // fit 600, 150% is 900, held to the 700px pane height.
    assert.equal(Layout.albumCoverSize(1200, 700, 240, 14, 1, 150), 700)
    // On a tall panel there is room: fit 592, 150% is 888, under the 904 room.
    assert.equal(Layout.albumCoverSize(1184, 1492, 240, 0, 1, 150, 40), 888)
})

// ---- the pane's square ----

const pane = (over) => Object.assign({
    shown: true, albumView: false, heroCover: 700, albumCover: 500,
    windowWidth: 1200, uiScale: 1
}, over)

check("paneCoverSize: hidden is zero", () => {
    assert.equal(Layout.paneCoverSize(pane({ shown: false })), 0)
})

check("paneCoverSize: the browser uses its hero while the lists keep their room", () => {
    assert.equal(Layout.paneCoverSize(pane({})), 700)
    assert.equal(Layout.paneCoverSize(pane({ windowWidth: 800 })), 480)
})

check("paneCoverSize: a tall large window fills the pane instead of stopping at 60%", () => {
    // 60% of 2384 is only 1430; the lists need 680 and the gutter 40, so all
    // 1492px still fit.
    assert.equal(Layout.paneCoverSize(pane({
        windowWidth: 2384, heroCover: 1492, edgeGap: 40
    })), 1492)
    // Padding, its rule and the gutter come out of the list room, not the cover.
    assert.equal(Layout.paneCoverSize(pane({
        windowWidth: 2384, heroCover: 1492, padded: true,
        coverPad: 14, rule: 1, edgeGap: 40
    })), 1492)
})

check("paneCoverSize: the shared right gutter holds the cover off the edge", () => {
    // The lists keep 480, the gutter keeps 40, so a 700px hero settles at 680.
    assert.equal(Layout.paneCoverSize(pane({
        windowWidth: 1200, heroCover: 700, edgeGap: 40
    })), 680)
})

check("paneCoverSize: a very large window stops at the readable list maximum", () => {
    // 40% would be 1200, but the lists hold at 680 and the gutter at 40,
    // leaving 2280 for the art.
    assert.equal(Layout.paneCoverSize(pane({
        windowWidth: 3000, heroCover: 2600, edgeGap: 40
    })), 2280)
})

check("paneCoverSize: album view uses its own square", () => {
    assert.equal(Layout.paneCoverSize(pane({ albumView: true })), 500)
    // The album square is already capped by the list room, not by the 60% here.
    assert.equal(Layout.paneCoverSize(pane({ albumView: true, windowWidth: 400 })), 500)
})

check("paneCoverSize: a tiny window falls back to the floor", () => {
    // The lists keep 40% of 70 = 28, leaving 42; 42 is floored to 48.
    assert.equal(Layout.paneCoverSize(pane({ windowWidth: 70 })), 48)
    assert.equal(Layout.paneCoverSize(pane({ windowWidth: 70, uiScale: 2 })), 96)
})

// ---- pane width and the rule it eats ----

const width = (over) => Object.assign({
    shown: true, albumView: false, paneCoverSize: 600,
    coverPad: 14, padded: true, rule: 1
}, over)

check("coverPaneWidth: padding adds the inner margin and the rule", () => {
    assert.equal(Layout.coverPaneWidth(width({})), 600 + 14 + 1)
})

check("coverPaneWidth: padding off leaves the cover on the divider, no rule strip", () => {
    assert.equal(Layout.coverPaneWidth(width({ padded: false })), 600)
    assert.equal(Layout.coverPaneWidth(width({ padded: false, rule: 3 })), 600)
})

check("coverPaneWidth: album view never reserves the rule", () => {
    assert.equal(Layout.coverPaneWidth(width({ albumView: true })), 600 + 14)
})

check("coverPaneWidth: the shared right gutter widens the pane, not the cover", () => {
    assert.equal(Layout.coverPaneWidth(width({ edgeGap: 40 })), 600 + 40 + 14 + 1)
    assert.equal(Layout.coverPaneWidth(width({ padded: false, edgeGap: 40 })), 600 + 40)
    assert.equal(Layout.coverPaneWidth(width({ albumView: true, edgeGap: 40 })), 600 + 40 + 14)
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

check("karaokeCoverSize: the scale holds the art back from the natural fit", () => {
    // natural fit 454: 50% is 227; an omitted scale still means 100%
    assert.equal(Layout.karaokeCoverSize(756, 826, 40, 10, 200, 1), 454)
    assert.equal(Layout.karaokeCoverSize(756, 826, 40, 10, 200, 1, 50), 227)
})

check("karaokeCoverSize: above 100 grows but keeps the words' column", () => {
    // 110% of 454 is 499, held to the 466px the text can spare.
    assert.equal(Layout.karaokeCoverSize(756, 826, 40, 10, 200, 1, 110), 466)
    // With more room the full rung applies: 110% of 710 is 781, under the 894 room.
    assert.equal(Layout.karaokeCoverSize(1184, 1558, 40, 10, 200, 1, 110), 781)
})

check("karaokeBackgroundCover: 100% fills the parent", () => {
    assert.deepEqual(Layout.karaokeBackgroundCover(1000, 800), {
        width: 1000, height: 800, x: 0, y: 0
    })
    assert.deepEqual(Layout.karaokeBackgroundCover(1000, 800, 100), {
        width: 1000, height: 800, x: 0, y: 0
    })
})

check("karaokeBackgroundCover: a smaller share stays centred", () => {
    assert.deepEqual(Layout.karaokeBackgroundCover(1000, 800, 50), {
        width: 500, height: 400, x: 250, y: 200
    })
    assert.deepEqual(Layout.karaokeBackgroundCover(1000, 800, 25), {
        width: 250, height: 200, x: 375, y: 300
    })
    assert.deepEqual(Layout.karaokeBackgroundCover(1000, 800, 30), {
        width: 300, height: 240, x: 350, y: 280
    })
})

check("karaokeBackgroundCover: odd sizes round without leaving the centre", () => {
    assert.deepEqual(Layout.karaokeBackgroundCover(1001, 801, 50), {
        width: 501, height: 401, x: 250, y: 200
    })
})

check("karaokeBackgroundCover: an unusable share never makes a negative box", () => {
    for (const pct of [-50, "nope", null]) {
        const box = Layout.karaokeBackgroundCover(1000, 800, pct)
        assert.ok(box.width >= 0 && box.height >= 0,
            "scale " + pct + " gave a negative box")
    }
    assert.equal(Layout.karaokeBackgroundCover(1000, 800, 0).width, 0)
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

// ---- tracks beside the lyrics ----

const companion = (over) => Object.assign({
    contentWidth: 900, minLyricsWidth: 240, uiScale: 1
}, over)

check("companionTrackWidth: about a third of the room beside the cover", () => {
    assert.equal(Layout.companionTrackWidth(companion({})), 306)
})

check("companionTrackWidth: the band caps a very wide column", () => {
    assert.equal(Layout.companionTrackWidth(companion({ contentWidth: 1500 })), 360)
})

check("companionTrackWidth: the readable floor holds on a tight panel", () => {
    // share is 170, but the floor is 180 and the lyrics still keep 260.
    assert.equal(Layout.companionTrackWidth(companion({ contentWidth: 500 })), 180)
})

check("companionTrackWidth: zero when the lyrics cannot keep their width", () => {
    // room is 160, below the 180 floor: the companion steps aside.
    assert.equal(Layout.companionTrackWidth(companion({ contentWidth: 400 })), 0)
    assert.equal(Layout.companionTrackWidth(companion({ contentWidth: 0 })), 0)
})

check("companionTrackWidth: the band scales with the interface", () => {
    assert.equal(Layout.companionTrackWidth(companion({
        contentWidth: 800, minLyricsWidth: 360, uiScale: 1.5
    })), 272)
    assert.equal(Layout.companionTrackWidth(companion({
        contentWidth: 400, minLyricsWidth: 360, uiScale: 1.5
    })), 0)
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

// ---- shared notice home ----

const readoutXBase = (over) => Object.assign({
    paneVisible: true, parentWidth: 1000, tracksLeft: 300,
    tracksCenter: 500, guard: 1000, gutter: 12, width: 100
}, over)

check("readoutX: a lone notice centres on the window without the browser", () => {
    assert.equal(Layout.readoutX(readoutXBase({ paneVisible: false })), 450)
})

check("readoutX: the band centres on the tracks pane", () => {
    assert.equal(Layout.readoutX(readoutXBase({})), 450)
})

check("readoutX: a floating cover pushes the box left by only what it needs", () => {
    assert.equal(Layout.readoutX(readoutXBase({ guard: 480 })), 380)
    // A cramped pane binds on the left gutter instead of the cover.
    assert.equal(Layout.readoutX(readoutXBase({
        tracksLeft: 300, tracksCenter: 350, guard: 480
    })), 312)
})

const stack = (over) => Object.assign({
    centered: false, parentHeight: 900, stripHeight: 84, gutter: 12,
    gap: 6, index: 0,
    items: [
        { visible: true, height: 30 },
        { visible: true, height: 24 },
        { visible: true, height: 40 }
    ]
}, over)

check("readoutStackY: the find readout owns the band and the notices stack above", () => {
    assert.equal(Layout.readoutStackY(stack({ index: 0 })), 774)
    assert.equal(Layout.readoutStackY(stack({ index: 1 })), 744)
    assert.equal(Layout.readoutStackY(stack({ index: 2 })), 698)
})

check("readoutStackY: hidden items leave no gap behind", () => {
    const one = stack({
        items: [
            { visible: false, height: 30 },
            { visible: true, height: 24 },
            { visible: true, height: 40 }
        ]
    })
    assert.equal(Layout.readoutStackY(Object.assign({}, one, { index: 1 })), 780)
    assert.equal(Layout.readoutStackY(Object.assign({}, one, { index: 2 })), 734)
})

check("readoutStackY: center centres the whole stack, not each box", () => {
    const centered = stack({ centered: true })
    assert.equal(Layout.readoutStackY(Object.assign({}, centered, { index: 0 })), 431)
    assert.equal(Layout.readoutStackY(Object.assign({}, centered, { index: 1 })), 401)
    assert.equal(Layout.readoutStackY(Object.assign({}, centered, { index: 2 })), 355)
})

// ---- now-playing strip ----

check("seekEdgeInset: the bar's slot plus air, scaled once", () => {
    assert.equal(Layout.seekEdgeInset(9, 1), 11)
    assert.equal(Layout.seekEdgeInset(15, 1), 17)
    assert.equal(Layout.seekEdgeInset(15, 1.25), 21)
    assert.equal(Layout.seekEdgeInset(0, 1), 3)
})

check("stripHeight: stacked progress keeps the original band", () => {
    assert.equal(Layout.stripHeight(false, 9, 1), 84)
    assert.equal(Layout.stripHeight(false, 3, 1), 84)
})

check("stripHeight: a taller seeker gives the title its room back", () => {
    assert.equal(Layout.stripHeight(false, 15, 1), 90)
    assert.equal(Layout.stripHeight(false, 11, 1), 86)
})

check("stripHeight: inline progress drops the clock's empty row", () => {
    assert.equal(Layout.stripHeight(true, 9, 1), 66)
    assert.equal(Layout.stripHeight(true, 15, 1), 72)
})

check("stripHeight: the scale rounds once at the end", () => {
    assert.equal(Layout.stripHeight(true, 9, 1.25), 83)
    assert.equal(Layout.stripHeight(false, 15, 1.25), 113)
})

check("stripHeight: top pad grows the band without moving the row", () => {
    // The row is inset by the same pad, so its height -- and the transport's
    // centre line -- is unchanged; only air above the title is added.
    assert.equal(Layout.stripHeight(true, 9, 1, false, 10) - Layout.stripHeight(true, 9, 1), 10)
    assert.equal(Layout.stripHeight(false, 15, 1.25, true, 13)
        - Layout.stripHeight(false, 15, 1.25, true), 13)
})

check("stripHeight: the seeker edge keeps the row's height", () => {
    var cases = [
        [false, 9, 1], [true, 9, 1], [true, 15, 1],
        [true, 9, 1.25], [false, 15, 1.15]
    ]
    for (var i = 0; i < cases.length; i++) {
        var c = cases[i]
        var plain = Layout.stripHeight(c[0], c[1], c[2], false)
        var edged = Layout.stripHeight(c[0], c[1], c[2], true)
        assert.equal(edged - plain, Layout.seekEdgeInset(c[1], c[2]))
    }
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

check("optionInt: an unusable CSS answer falls back to the int", () => {
    assert.equal(Layout.optionInt('{"css": "-2px", "int": 4}'), 4)
    assert.equal(Layout.optionInt('{"css": "auto", "int": 6}'), 6)
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
