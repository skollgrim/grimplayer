#!/usr/bin/env node
// Exercises the album-art palette maths without a running shell:
//   node extras/test-palette.js
"use strict"

const assert = require("node:assert/strict")
const Palette = require("../Palette.js")

function rgb(hex) {
    return Palette.toRgb(hex)
}

function channelsClose(a, b, tolerance) {
    const t = tolerance === undefined ? 2 / 255 : tolerance
    return Math.abs(a.r - b.r) <= t
        && Math.abs(a.g - b.g) <= t
        && Math.abs(a.b - b.b) <= t
}

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

// ---- primitives -----------------------------------------------------------

check("hex strings parse and print back", () => {
    for (const hex of ["#000000", "#ffffff", "#c24a1b", "#1d2b53", "#7fc8a9"]) {
        assert.equal(Palette.toHex(rgb(hex)), hex)
    }
})

check("bad input parses as null rather than throwing", () => {
    assert.equal(Palette.toRgb(null), null)
    assert.equal(Palette.toRgb(undefined), null)
    assert.equal(Palette.toRgb("not a colour"), null)
    assert.equal(Palette.toRgb({ g: 1, b: 1 }), null)
})

check("contrast ratio of black and white is 21:1", () => {
    const ratio = Palette.contrastRatio(rgb("#000000"), rgb("#ffffff"))
    assert.ok(Math.abs(ratio - 21) < 0.01, "got " + ratio)
})

check("contrast ratio is symmetric", () => {
    const a = rgb("#123456"), b = rgb("#abcdef")
    assert.ok(Math.abs(Palette.contrastRatio(a, b) - Palette.contrastRatio(b, a)) < 1e-12)
})

// ---- OKLCH ----------------------------------------------------------------

check("OKLCH round trip keeps each colour", () => {
    const samples = ["#000000", "#ffffff", "#808080", "#ff0000", "#00a050",
                     "#1d2b53", "#c24a1b", "#e8d8a0"]
    for (const hex of samples) {
        const source = rgb(hex)
        const oklch = Palette.rgbToOklch(source)
        const back = Palette.oklchToRgb(oklch.L, oklch.C, oklch.H)
        assert.ok(channelsClose(source, back),
            hex + " came back as " + Palette.toHex(back))
    }
})

check("OKLCH reports neutral greys with no chroma", () => {
    for (const hex of ["#000000", "#404040", "#808080", "#ffffff"]) {
        assert.ok(Palette.rgbToOklch(rgb(hex)).C < 1e-6, hex)
    }
})

check("out-of-gamut OKLCH is brought back into range", () => {
    // Deep blue at near-white lightness: the naive conversion needs a negative
    // red channel, so this is exactly the case channel clipping would ruin.
    const mapped = Palette.oklchToRgb(0.95, 0.4, 264)
    for (const channel of ["r", "g", "b"]) {
        assert.ok(mapped[channel] >= 0 && mapped[channel] <= 1,
            channel + " = " + mapped[channel])
    }
    // Mapping trims chroma, not hue: the result should still read blue.
    assert.ok(mapped.b > mapped.r, "expected a blue cast, got " + Palette.toHex(mapped))
})

check("gamut mapping leaves in-gamut colours untouched", () => {
    const direct = Palette.oklchToRgb(0.62, 0.12, 30)
    const hex = Palette.toHex(direct)
    assert.equal(Palette.toHex(Palette.oklchToRgb(Palette.rgbToOklch(direct).L, 0.12, 30)), hex)
})

// ---- derivation -----------------------------------------------------------

const FALLBACK = { urgent: "#ff3b30" }

const covers = [
    ["vivid orange", ["#c24a1b", "#e8892c", "#7a2b0e", "#f3c26b"]],
    ["mostly black", ["#050505", "#0b0b0d", "#161616", "#222222"]],
    ["near white", ["#f7f4ec", "#e8e2d4", "#ffffff", "#d8cfbc"]],
    ["blue sleeve", ["#1d2b53", "#27406e", "#3a5a92", "#8fb3d9"]],
    ["green sleeve", ["#0f3d2e", "#1f6b4d", "#5fb98a", "#d8f0df"]],
    ["black and white", ["#111111", "#888888", "#dddddd", "#ffffff"]]
]

function paletteOf(name) {
    const cover = covers.find((c) => c[0] === name)
    return Palette.derive(cover[1], FALLBACK)
}

check("every derived token is a real hex colour", () => {
    for (const [, colors] of covers) {
        const p = Palette.derive(colors, FALLBACK)
        for (const token of ["background", "foreground", "muted", "accent", "urgent"]) {
            assert.match(p[token], /^#[0-9a-f]{6}$/, token + " in " + Palette.toHex(rgb(colors[0])))
        }
    }
})

check("accent clears 3:1 against the ground it is drawn on", () => {
    for (const [name, colors] of covers) {
        const p = Palette.derive(colors, FALLBACK)
        const ratio = Palette.contrastRatio(rgb(p.accent), rgb(p.background))
        assert.ok(ratio >= 3.0,
            name + ": " + p.accent + " on " + p.background + " is " + ratio.toFixed(2) + ":1")
    }
})

check("a light sleeve gets a light ground and dark ink", () => {
    const p = paletteOf("near white")
    const bg = rgb(p.background)
    assert.ok(Palette.luminance(bg) > 0.55,
        "background " + p.background + " is not light")
    assert.ok(Palette.luminance(rgb(p.foreground)) < Palette.luminance(bg),
        "foreground should sit darker than a light ground")
})

// The split used to read a green-weighted luma, which put a sleeve that is
// mostly hot pink plus a cream block on the dark side of the panel. It is now
// the mean cluster's OKLCH lightness; these two fixtures pin both sides.
check("a vivid pink sleeve gets a light ground", () => {
    const p = Palette.derive(["#6d1e4b", "#e91792", "#ee038e", "#ee2499",
                              "#bb8ba0", "#eedbd9", "#ee97c1", "#efe7de"], FALLBACK)
    const bg = rgb(p.background)
    assert.ok(Palette.luminance(bg) > 0.55,
        "background " + p.background + " is not light")
    assert.ok(bg.r > bg.b && bg.b > bg.g, "ground should keep the pink hue: " + p.background)
    assert.ok(Palette.luminance(rgb(p.foreground)) < Palette.luminance(bg),
        "foreground should sit darker than the pink ground")
})

check("a mid-dark olive sleeve stays on a dark ground", () => {
    const p = Palette.derive(["#181817", "#262524", "#3c3b31", "#52514d",
                              "#7d7748", "#cdbe44", "#8d8a83", "#d0cbb4"], FALLBACK)
    const bg = rgb(p.background)
    assert.ok(Palette.luminance(bg) < 0.3,
        "background " + p.background + " is not dark")
    assert.ok(Palette.luminance(rgb(p.foreground)) > Palette.luminance(bg),
        "foreground should sit lighter than the olive ground")
})

check("a dark sleeve gets a dark ground and light ink", () => {
    const p = paletteOf("mostly black")
    const bg = rgb(p.background)
    assert.ok(Palette.luminance(bg) < 0.3,
        "background " + p.background + " is not dark")
    assert.ok(Palette.luminance(rgb(p.foreground)) > Palette.luminance(bg),
        "foreground should sit lighter than a dark ground")
})

check("a colourless sleeve gives a neutral accent", () => {
    const p = paletteOf("black and white")
    const accent = rgb(p.accent)
    const spread = Math.max(accent.r, accent.g, accent.b) - Math.min(accent.r, accent.g, accent.b)
    assert.ok(spread < 0.01, "accent " + p.accent + " is not neutral")
    // ...and not the theme's accent, which is the bug this guards against.
    assert.notEqual(p.accent, FALLBACK.urgent)
})

check("a coloured sleeve keeps its hue in the accent", () => {
    const p = paletteOf("blue sleeve")
    const accent = rgb(p.accent)
    assert.ok(accent.b > accent.r, "expected blue, got " + p.accent)
    assert.ok(accent.b > accent.g, "expected blue, got " + p.accent)
})

check("the fallback's urgent token is carried through unchanged", () => {
    const p = paletteOf("vivid orange")
    assert.equal(p.urgent, FALLBACK.urgent)
})

check("no colours returns the fallback untouched", () => {
    assert.equal(Palette.derive([], FALLBACK), FALLBACK)
    assert.equal(Palette.derive(null, FALLBACK), FALLBACK)
})

check("transparent and duplicate entries do not change the result", () => {
    const plain = Palette.derive(covers[0][1], FALLBACK)
    const noisy = Palette.derive(covers[0][1].concat([
        { r: 1, g: 1, b: 1, a: 0 },
        covers[0][1][0],
        covers[0][1][1]
    ]), FALLBACK)
    assert.deepEqual(noisy, plain)
})

// A spread of one-off colours, so the contrast guard is tested on more than the
// tidy groups above. Every one of these should end up legible on its own ground.
check("accent contrast holds across single-colour sleeves", () => {
    const singles = ["#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff",
                     "#00ffff", "#7f0000", "#007f00", "#00007f", "#f0e68c",
                     "#c0c0c0", "#303030", "#fedcba", "#123456", "#abcdef"]
    for (const hex of singles) {
        const p = Palette.derive([hex], FALLBACK)
        const ratio = Palette.contrastRatio(rgb(p.accent), rgb(p.background))
        assert.ok(ratio >= 3.0,
            hex + ": " + p.accent + " on " + p.background + " is " + ratio.toFixed(2) + ":1")
    }
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
