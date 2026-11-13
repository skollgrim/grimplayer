// Colour maths for the album-art palette.
//
// Everything here is pure: colours in, hex strings out. Kept out of
// GrimTheme.qml because the arithmetic -- OKLCH conversion, gamut mapping, the
// luminance term the contrast guard leans on -- reads more clearly on its own
// than wrapped in property bindings, and because explicit function calls are not
// re-run on every unrelated change the way a binding would be.
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
//
// Lightness is moved in OKLCH rather than HSL. HSL's "lightness" is a bare
// average of the largest and smallest channel, so dropping it on a saturated
// colour changes how much of the hue the eye sees: a vivid blue darkened in HSL
// turns navy, while the same number in OKLCH keeps the blue's perceived
// brightness and only makes it darker. OKLCH also gives a natural place to hold
// chroma and hue fixed while the lightness moves, which is exactly what a panel
// ground, ink and accent need.

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

// sRGB's transfer function and its inverse. Relative luminance and OKLab both
// work on linear-light channels; the 0..1 values a QColor exposes are gamma
// encoded.
function srgbToLinear(v) {
    v = clamp(v, 0, 1)
    return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
}

function linearToSrgb(v) {
    v = clamp(v, 0, 1)
    return v <= 0.0031308 ? 12.92 * v : 1.055 * Math.pow(v, 1 / 2.4) - 0.055
}

function cbrt(x) {
    if (typeof Math.cbrt === "function") return Math.cbrt(x)
    return x < 0 ? -Math.pow(-x, 1 / 3) : Math.pow(x, 1 / 3)
}

// OKLCH L of a neutral grey with this sRGB channel value. The panel's lightness
// targets were chosen in HSL, where a mid-grey sits at 0.5; OKLCH's perceptual
// scale puts the same grey near 0.6, and its dark end is much darker. Mapping a
// target through this keeps the old, tuned look while the hue and chroma maths
// move to OKLCH. For a neutral, OKLab's L is the cube root of linear luminance.
function greyLightness(v) {
    return cbrt(srgbToLinear(v))
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

// Relative luminance, for the contrast ratio. This is the WCAG term, applied to
// linear-light channels; luminance() below is a cheap luma used only to scale
// the ground's lightness away from the middle of the range.
function relLuminance(rgb) {
    return 0.2126 * srgbToLinear(rgb.r)
         + 0.7152 * srgbToLinear(rgb.g)
         + 0.0722 * srgbToLinear(rgb.b)
}

function contrastRatio(a, b) {
    var la = relLuminance(a), lb = relLuminance(b)
    var hi = Math.max(la, lb), lo = Math.min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
}

// OKLab -> OKLCH (cylindrical). L is perceptual lightness in 0..1, C is chroma
// (0 for grey, higher for more colour), H is the hue angle in degrees.
function rgbToOklch(rgb) {
    var lr = srgbToLinear(rgb.r)
    var lg = srgbToLinear(rgb.g)
    var lb = srgbToLinear(rgb.b)

    var l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb
    var m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb
    var s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb

    var l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)

    var L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    var a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    var bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

    var C = Math.sqrt(a * a + bb * bb)
    var H = Math.atan2(bb, a) * 180 / Math.PI
    if (H < 0) H += 360
    return { L: L, C: C, H: H }
}

// OKLCH -> linear sRGB, before gamut handling. Channels outside 0..1 mean the
// requested colour does not exist on screen.
function oklchToLinear(L, C, H) {
    var hRad = H * Math.PI / 180
    var a = C * Math.cos(hRad)
    var b = C * Math.sin(hRad)

    var l_ = L + 0.3963377774 * a + 0.2158037573 * b
    var m_ = L - 0.1055613458 * a - 0.0638541728 * b
    var s_ = L - 0.0894841775 * a - 1.2914855480 * b

    var l = l_ * l_ * l_
    var m = m_ * m_ * m_
    var s = s_ * s_ * s_

    return {
        r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    }
}

function inGamut(lin) {
    var eps = 0.0005
    return lin.r >= -eps && lin.r <= 1 + eps
        && lin.g >= -eps && lin.g <= 1 + eps
        && lin.b >= -eps && lin.b <= 1 + eps
}

// OKLCH -> sRGB with gamut mapping. Clipping each channel independently is what
// shifts hue: a vivid blue whose red channel would go negative gets red removed,
// which reads as purple. Reducing chroma instead -- holding lightness and hue
// fixed -- walks the colour toward grey until the display can draw it, which is
// what keeps a cover's hue recognisable at panel lightnesses.
function oklchToRgb(L, C, H) {
    L = clamp(L, 0, 1)
    C = Math.max(0, C)
    var lin = oklchToLinear(L, C, H)
    if (!inGamut(lin)) {
        var lo = 0, hi = C
        for (var i = 0; i < 20; i++) {
            var mid = (lo + hi) / 2
            if (inGamut(oklchToLinear(L, mid, H))) lo = mid
            else hi = mid
        }
        lin = oklchToLinear(L, lo, H)
    }
    return { r: linearToSrgb(lin.r), g: linearToSrgb(lin.g),
             b: linearToSrgb(lin.b), a: 1 }
}

// Cheap luma. Used to place the ground within its dark or light band, not to
// decide which band that is: luma weights green heavily and so undervalues
// vivid reds, which made a bright pink sleeve look dark to the split.
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

// Walk a colour's lightness away from the ground until it clears `minRatio`.
// `direction` is -1 to darken (light ground) or +1 to lighten (dark ground).
// Chroma and hue are held, so the accent keeps the sleeve's colour as it moves
// rather than sliding toward black or white; gamut mapping trims the chroma only
// where the display cannot hold it.
function ensureContrast(rgb, bg, minRatio, direction) {
    var ok = rgbToOklch(rgb)
    var L = ok.L
    var step = direction < 0 ? -0.015 : 0.015
    for (var i = 0; i < 48; i++) {
        var candidate = oklchToRgb(L, ok.C, ok.H)
        if (contrastRatio(candidate, bg) >= minRatio) return candidate
        L = clamp(L + step, 0, 1)
    }
    return oklchToRgb(L, ok.C, ok.H)
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
//
// `bg` is the ground the accent will actually be drawn on, not an assumed one,
// so the 3:1 guard measures the real thing.
function pickAccent(cs, light, bg) {
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
        var neutral
        if (light) {
            neutral = oklchToRgb(greyLightness(0.45), 0, 0)
        } else {
            var maxL = 0
            for (var k = 0; k < cs.length; k++) maxL = Math.max(maxL, rgbToOklch(cs[k]).L)
            neutral = oklchToRgb(clamp(maxL, greyLightness(0.72), greyLightness(0.92)), 0, 0)
        }
        return toHex(ensureContrast(neutral, bg, 3.0, light ? -1 : 1))
    }

    // Keep the hue, lift the chroma enough to read as a colour, and place the
    // lightness where the ground needs it: lower on a light panel, higher on a
    // dark one. The bounds are OKLCH's own, so a blue and a green at the same
    // number look equally bright instead of HSL's channel average making the
    // blue look darker. Then move it away from that ground until 3:1 is real
    // rather than assumed.
    var ok = rgbToOklch(bestRgb)
    var accentC = clamp(ok.C * 1.50, 0.06, 0.20)
    var accentL = light ? clamp(ok.L, 0.42, 0.62)
                        : clamp(ok.L, 0.55, 0.80)
    var accentRgb = oklchToRgb(accentL, accentC, ok.H)
    return toHex(ensureContrast(accentRgb, bg, 3.0, light ? -1 : 1))
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
// sleeve averages dark, a mostly-white one light. The split is on the mean's
// OKLCH lightness at 0.64, not on a gamma luma: 0.64 is where the old 0.55 luma
// threshold lands on a neutral grey, so the tuned behaviour is kept, but a
// colour is judged by how bright it looks rather than by a green-weighted
// average. Luma put a hot-pink sleeve with a cream block on the dark side even
// though the eye sees a bright cover; the perceptual split gives it the light
// panel it belongs on, while a true mid-tone such as olive still averages dark.
// Requiring a real majority above the middle keeps the panel dark by default and
// reserves the light panel for covers that are actually light. It also snaps, so
// the ground never settles on a muddy mid-grey that neither black nor white text
// can sit on readably.
//
// One thing the ground must not do is carry the mean's HSL saturation across a
// lightness change. A near-black navy reports an HSL saturation near 1 while
// holding almost no colour, and rescaling that put a strong blue into the panel
// of a black sleeve. So the maths below carries the mean's OKLCH chroma -- a
// perceptual, hue-aware measure -- at the ground's new lightness, and the panel
// ends up as blue -- or as grey -- as the sleeve actually is.
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

    var mc = rgbToOklch(mean)
    var lum = luminance(mean)

    var light = mc.L >= 0.64
    // The 0.06..0.16 / 0.84..0.95 figures are the HSL targets this panel has
    // always used; greyLightness carries them onto OKLCH's perceptual scale so a
    // dark panel stays the same darkness it was tuned to.
    var bgL = greyLightness(light ? clamp(0.84 + (lum - 0.5) * 0.30, 0.84, 0.95)
                                  : clamp(0.06 + lum * 0.20, 0.06, 0.16))
    // On a light ground both steps sit darker than a bare "dark grey" would: the
    // panel is a page of text on a near-white sheet, and at the old 0.18/0.42 the
    // title and, especially, the muted times and icons read as a weak wash rather
    // than as ink. Pulling them down -- foreground to 0.15, muted to 0.36 --
    // restores the contrast that the theme's own light mode has, without going to
    // hard black. On a dark ground they are already legible, so only a whisper of
    // extra lift is added there.
    var fgL = greyLightness(light ? 0.15 : 0.90)
    var muL = greyLightness(light ? 0.36 : 0.57)

    // Chroma caps keep the ground and ink from shouting. The ground carries most
    // of the sleeve's colour, the muted step a little less, and the foreground
    // only a tint -- enough that text on a blue album reads warm rather than
    // neutral, not enough to look like coloured ink.
    var bgC = clamp(mc.C * 0.90, 0, 0.09)
    var bgRgb = oklchToRgb(bgL, bgC, mc.H)
    var background = toHex(bgRgb)

    var fgC = clamp(mc.C * 0.25, 0, 0.014)
    var foreground = toHex(oklchToRgb(fgL, fgC, mc.H))

    var muC = clamp(mc.C * 0.80, 0, 0.055)
    var muted = toHex(oklchToRgb(muL, muC, mc.H))

    // The fallback's urgent token, parsed rather than assumed: toHex() of a
    // missing or unparseable colour would throw, so a fallback without one falls
    // back to the derived background instead of taking the derivation down.
    var urgent = toRgb(fallback.urgent)
    return { background: background, foreground: foreground, muted: muted,
             accent: pickAccent(cs, light, bgRgb),
             urgent: urgent ? toHex(urgent) : background }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        clamp: clamp,
        toRgb: toRgb,
        toHex: toHex,
        relLuminance: relLuminance,
        contrastRatio: contrastRatio,
        rgbToOklch: rgbToOklch,
        oklchToRgb: oklchToRgb,
        luminance: luminance,
        chroma: chroma,
        derive: derive
    }
}
