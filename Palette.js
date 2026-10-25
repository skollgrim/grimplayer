// Colour maths for the album-art palette.
//
// Everything here is pure: colours in, hex strings out. Kept out of
// GrimTheme.qml because the arithmetic -- HSL conversion, the luminance term the
// contrast guard leans on -- reads more clearly on its own than wrapped in
// property bindings, and because explicit function calls are not re-run on every
// unrelated change the way a binding would be.
//
// Deliberately not a `.pragma library`: a library script is compiled once per
// engine and cached across reloads, so an edit to one would be stuck behind that
// cache as well as the shell's, while a plain script is recompiled with the
// component that imports it.
//
// Colour values arrive either as a QColor handed over by ColorQuantizer or as a
// `color` token from the theme singletons; both expose r/g/b/a in 0..1, which is
// the only shape this file understands. Strings are parsed only defensively --
// nothing internal produces one until the very end.

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v))
}

function toRgb(c) {
    if (c === undefined || c === null) return null
    if (typeof c === "string") {
        var m = c.match(/^#([0-9a-fA-F]{6})/)
        if (!m) return null
        var n = parseInt(m[1], 16)
        return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255,
                 b: (n & 255) / 255, a: 1 }
    }
    if (c.r === undefined) return null
    return { r: c.r, g: c.g, b: c.b, a: (c.a === undefined ? 1 : c.a) }
}

function toHex(rgb) {
    function part(v) {
        var n = Math.round(clamp(v, 0, 1) * 255)
        return (n < 16 ? "0" : "") + n.toString(16)
    }
    return "#" + part(rgb.r) + part(rgb.g) + part(rgb.b)
}

function rgbToHsl(rgb) {
    var r = rgb.r, g = rgb.g, b = rgb.b
    var max = Math.max(r, g, b), min = Math.min(r, g, b)
    var l = (max + min) / 2
    if (max === min) return { h: 0, s: 0, l: l }
    var d = max - min
    var s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    var h
    if (max === r) h = (g - b) / d + (g < b ? 6 : 0)
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    return { h: h / 6, s: s, l: l }
}

function hslToRgb(h, s, l) {
    if (s === 0) return { r: l, g: l, b: l }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s
    var p = 2 * l - q
    function hue(t) {
        if (t < 0) t += 1
        if (t > 1) t -= 1
        if (t < 1 / 6) return p + (q - p) * 6 * t
        if (t < 1 / 2) return q
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
        return p
    }
    return { r: hue(h + 1 / 3), g: hue(h), b: hue(h - 1 / 3) }
}

// Relative luminance. Used to read the sleeve's overall lightness and to keep
// the text on the opposite side of the ground from it.
function luminance(rgb) {
    return 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
}

// Plain RGB chroma: the spread between the largest and smallest channel. This,
// not HSL saturation, is what says "this pixel is actually coloured". HSL
// reports a near-black with a one-point blue cast as fully saturated, so a
// mostly-black sleeve used to hand the whole panel a strong blue it did not
// contain; in chroma those pixels are almost grey and contribute almost nothing.
function chroma(rgb) {
    return Math.max(rgb.r, rgb.g, rgb.b) - Math.min(rgb.r, rgb.g, rgb.b)
}

// Distinct, opaque colours only: a PNG with alpha can leave transparent or
// near-black entries behind, and duplicates say nothing about the sleeve.
function sanitize(colors) {
    var out = []
    var seen = {}
    for (var i = 0; i < (colors ? colors.length : 0); i++) {
        var rgb = toRgb(colors[i])
        if (!rgb || rgb.a < 0.5) continue
        var key = toHex(rgb)
        if (seen[key]) continue
        seen[key] = true
        out.push(rgb)
    }
    return out
}

// The liveliest colour in the cover, scored toward saturated mid-tones so a
// dark navy or a near-white cream does not win by being merely prevalent. Score
// is chroma-based for the same reason as above: a near-black pixel must not win
// on a cast.
//
// When the sleeve has no colour at all, the accent is a neutral grey -- dark on a
// light panel, light on a dark one -- built from the sleeve's own tones and never
// taken from the theme. A black-and-white cover is supposed to give a
// black-and-white panel, and reaching for the theme's blue there is exactly the
// bug this function avoids.
function pickAccent(cs, light) {
    var best = null, bestRgb = null, bestScore = -1
    for (var i = 0; i < cs.length; i++) {
        var hsl = rgbToHsl(cs[i])
        var c = chroma(cs[i])
        if (c < 0.03) continue
        var score = c * (1 - Math.abs(hsl.l - 0.5) * 2) * (1 + Math.min(c, 0.3))
        if (score > bestScore) { bestScore = score; best = hsl; bestRgb = cs[i] }
    }
    if (bestScore < 0) {
        for (var j = 0; j < cs.length; j++) {
            var hsl2 = rgbToHsl(cs[j])
            var score2 = chroma(cs[j]) * (1 - Math.abs(hsl2.l - 0.5) * 2)
            if (score2 > bestScore) { bestScore = score2; best = hsl2; bestRgb = cs[j] }
        }
    }
    if (!bestRgb || chroma(bestRgb) < 0.04) {
        if (light) return toHex(hslToRgb(0, 0, 0.45))
        var maxL = 0
        for (var j = 0; j < cs.length; j++) maxL = Math.max(maxL, rgbToHsl(cs[j]).l)
        return toHex(hslToRgb(0, 0, clamp(maxL, 0.72, 0.92)))
    }
    // On a light ground the accent has to come down in lightness to keep its
    // contrast; on a dark ground it stays bright.
    var accentL = light ? clamp(best.l, 0.34, 0.52) : clamp(best.l, 0.52, 0.70)
    var accentS = clamp(best.s * 1.8, 0.50, 0.95)
    var accentRgb = hslToRgb(best.h, accentS, accentL)
    // Simple contrast guard: ensure minimum contrast against background
    // Background is approximated; if too low, bump lightness
    var bgL = light ? 0.9 : 0.11
    function relL(c) {
        function ch(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        var r = ch(c.r), g = ch(c.g), b = ch(c.b)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    var al = relL(accentRgb), bl = relL({r:bgL,g:bgL,b:bgL})
    var cr = (Math.max(al, bl) + 0.05) / (Math.min(al, bl) + 0.05)
    if (cr < 3.0) {
        if (light) accentL = Math.max(0.25, accentL - 0.15)
        else accentL = Math.min(0.8, accentL + 0.15)
        accentRgb = hslToRgb(best.h, accentS, accentL)
    }
    return toHex(accentRgb)
}

// Derive a full panel palette from the quantized cover colours.
//
// Everything here is read from the artwork. The live theme is consulted for one
// thing only -- the alert colour, which stays semantic rather than following a
// sleeve -- and never for a hue, so a colourless cover cannot inherit the
// theme's blue the way it used to.
//
// Hue, the small amount of colour in the ground and text, and the lightness all
// come from one colour: the mean of the quantized clusters. That mean is not a
// mean of eight arbitrary samples -- the quantizer is a median cut, which sorts
// the pixels by their widest channel and splits at the median, so a cluster at a
// given depth holds half as many pixels as its parent and every cluster at the
// same depth holds the same number. Averaging them therefore averages the
// sleeve. It is deliberately not the first cluster: the walk appends the low half
// of each split before the high half, so colors[0] is always the *darkest* cluster
// -- a gold sun over dark earth put a near-black first and turned the whole panel
// dark. The accent is the liveliest colour anywhere in the cover, which is often a
// brighter spot than the average -- that amber sun again.
//
// Lightness from that mean is what carries the cover's proportions: a mostly-black
// sleeve averages dark, a mostly-white one light. The split is at 0.55 rather than
// 0.50 because a mean of exactly the middle is a sleeve split between a dark ground
// and bright highlights, and those read as dark albums -- a light panel for them is
// the surprise this threshold avoids. Requiring a real majority above the middle
// keeps the panel dark by default and reserves the light panel for covers that are
// actually light. It also snaps, so the ground never settles on a muddy mid-grey
// that neither black nor white text can sit on readably.
//
// One thing the ground must not do is carry the mean's HSL saturation across a
// lightness change. A near-black navy reports an HSL saturation near 1 while
// holding almost no colour, and rescaling that put a strong blue into the panel
// of a black sleeve. So the maths below preserves the mean's absolute chroma
// (its channel spread) at the ground's new lightness, and the panel ends up as
// blue -- or as grey -- as the sleeve actually is.
function derive(colors, fallback) {
    // Defensive: the caller always hands the live theme tokens, but this is a
    // pure library and a missing fallback should not throw -- a null deref on the
    // urgent token below took the whole palette derivation with it.
    if (!fallback) fallback = {}
    var cs = sanitize(colors)
    if (!cs.length) return fallback

    var mean = { r: 0, g: 0, b: 0 }
    for (var k = 0; k < cs.length; k++) {
        mean.r += cs[k].r
        mean.g += cs[k].g
        mean.b += cs[k].b
    }
    mean.r /= cs.length
    mean.g /= cs.length
    mean.b /= cs.length

    var dh = rgbToHsl(mean)
    var dc = chroma(mean)
    var lum = luminance(mean)

    var light = lum >= 0.55
    var bgL = light ? clamp(0.84 + (lum - 0.5) * 0.30, 0.84, 0.95)
                    : clamp(0.06 + lum * 0.20, 0.06, 0.16)
    // On a light ground both steps sit darker than a bare "dark grey" would: the
    // panel is a page of text on a near-white sheet, and at the old 0.18/0.42 the
    // title and, especially, the muted times and icons read as a weak wash rather
    // than as ink. Pulling them down -- foreground to 0.15, muted to 0.36 --
    // restores the contrast that the theme's own light mode has, without going to
    // hard black. On a dark ground they are already legible, so only a whisper of
    // extra lift is added there.
    var fgL = light ? 0.15 : 0.90
    var muL = light ? 0.36 : 0.57

    // HSL saturation that reproduces the mean's chroma at the ground's
    // lightness: chroma = 2 * l * s below the middle, (2 - 2l) * s above. A grey
    // sleeve has dc = 0 and lands neutral; a vivid one approaches full
    // saturation.
    var bgS = light ? clamp(dc / (2 - 2 * bgL), 0, 0.85)
                    : clamp(dc / (2 * bgL), 0, 0.85)
    var background = toHex(hslToRgb(dh.h, bgS, bgL))

    var foreground = toHex(hslToRgb(dh.h, clamp(dc * 1.1, 0, 0.14), fgL))
    var muted = toHex(hslToRgb(dh.h, clamp(dc * 1.6, 0, 0.22), muL))

    // The fallback's urgent token, parsed rather than assumed: toHex() of a
    // missing or unparseable colour would throw, so a fallback without one falls
    // back to the derived background instead of taking the derivation down.
    var urgent = toRgb(fallback.urgent)
    return { background: background, foreground: foreground, muted: muted,
             accent: pickAccent(cs, light),
             urgent: urgent ? toHex(urgent) : background }
}
