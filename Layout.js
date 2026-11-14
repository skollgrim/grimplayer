// The cover's geometry: how big it is in each placement, where the artwork
// pane sits, and the window inset the threshold is measured against.
//
// These are the numbers behind the divider and anchor regressions: a cover a
// few pixels too wide eats the pane rule, a band that does not yield to a full
// height cover leaves a margin it cannot afford, and an inset derived wrongly
// makes the widest allowed panel unreachable. Kept here so
// extras/test-layout.js can exercise the clamps without a compositor.

function asNumber(value) {
    var n = Number(value)
    return isFinite(n) ? n : 0
}

// The share of the pane region the art takes. In auto mode the placement the
// compositor chose picks the size; with the pane pinned on or off the stored
// artwork-size setting is in charge.
function coverScalePct(mode, band, scale) {
    return mode === "auto" ? (band ? 100 : 30) : asNumber(scale)
}

// 100% is the full distance from the top of the player to the now-playing
// strip; every smaller value is that fraction. A share, not a pixel count, so
// one setting means the same thing on any monitor.
function heroCover(paneHeight, scalePct, uiScale) {
    return Math.max(Math.round(48 * uiScale),
        Math.round(asNumber(paneHeight) * asNumber(scalePct) / 100))
}

// Album view borrows the artwork pane even when the browser folds the cover
// back to a floating corner. There it is a square beside one centred column of
// titles, so it is capped at half the window width rather than 60%.
function albumCoverSize(windowWidth, paneHeight, minListWidth, coverPad, uiScale) {
    var room = asNumber(windowWidth) - asNumber(minListWidth) - asNumber(coverPad) * 2
    return Math.max(Math.round(48 * uiScale),
        Math.min(asNumber(paneHeight), Math.round(asNumber(windowWidth) * 0.50), room))
}

// The square the cover is drawn at in its pane, or 0 when no pane is showing.
// The 60% cap leaves the three lists a readable share of the width on a short,
// wide window; the floor keeps a tiny panel from drawing a postage stamp.
function paneCoverSize(options) {
    var o = options || {}
    if (!o.shown) return 0
    if (o.albumView) return o.albumCover
    return Math.max(Math.round(48 * o.uiScale),
        Math.min(o.heroCover, Math.round(asNumber(o.windowWidth) * 0.60)))
}

// Width of the artwork pane. With a margin the cover is held in from the edges,
// so the pane spans that margin on each side plus the rule on its inner edge.
// With no margin the cover runs flush to both edges and rides over the rule, so
// the pane is sized to the cover alone and no strip is reserved. Album view
// never reserves the rule: its pane sits beside the centred column instead.
function coverPaneWidth(options) {
    var o = options || {}
    if (!o.shown) return 0
    var pad = o.padded ? asNumber(o.coverPad) : 0
    var rule = o.padded && !o.albumView ? asNumber(o.rule) : 0
    return asNumber(o.paneCoverSize) + pad * 2 + rule
}

// How far the cover is held off the pane edge it is aligned to. Fixed at the
// padding until the space left over shrinks below it, at which point the inset
// gives way so a full-height cover sits flush against the top and the strip.
function coverBandInset(coverPad, paneHeight, paneCoverSize) {
    return Math.min(asNumber(coverPad),
        Math.max(0, Math.round((asNumber(paneHeight) - asNumber(paneCoverSize)) / 2)))
}

// The cover's y inside the pane: against the top or bottom edge (bar the inset
// above), or centred.
function coverBandY(align, paneHeight, paneCoverSize, inset) {
    if (align === "top") return inset
    if (align === "middle")
        return Math.round((asNumber(paneHeight) - asNumber(paneCoverSize)) / 2)
    return asNumber(paneHeight) - inset - asNumber(paneCoverSize)
}

// The floating cover: the same share of the pane height, capped so it never
// spills past the gutter it keeps from the window edges.
function floatingCoverSize(hero, windowWidth, paneHeight, gutter, uiScale) {
    return Math.max(Math.round(48 * uiScale),
        Math.min(hero, asNumber(windowWidth) - gutter * 2,
            asNumber(paneHeight) - gutter * 2))
}

// Karaoke's cover beside the lyrics: as tall as the reading area, capped at the
// same 60% the pane uses and by the readable text column that has to remain.
function karaokeCoverSize(windowWidth, windowHeight, margin, gap, minTextWidth, uiScale) {
    return Math.max(Math.round(48 * uiScale),
        Math.min(asNumber(windowHeight) - margin * 2,
            Math.round(asNumber(windowWidth) * 0.60),
            asNumber(windowWidth) - margin * 2 - gap - minTextWidth))
}

// The measure of the lyric column. Karaoke always takes the full layout width;
// the reading view narrows it by the text-width setting.
function lyricsColumnWidth(layoutWidth, karaoke, setting) {
    if (karaoke) return layoutWidth
    if (setting === "wide") return layoutWidth * 0.8
    if (setting === "narrow") return layoutWidth * 0.65
    return layoutWidth
}

// Whether the artwork pane is showing. Auto hides it on a narrow window so the
// three-pane layout stays usable, and keeps it while the screen's frame is
// still unknown rather than flickering it away for the frame before the
// compositor answers. A few pixels of slack cover the compositor's own
// per-side rounding, which otherwise makes the top of the range unreachable.
function coverBandVisible(options) {
    var o = options || {}
    if (o.mode === "on") return true
    if (o.mode === "off") return false
    // Auto-hide at very narrow widths to keep the three-pane layout usable.
    if (o.width > 0 && o.width < Math.round(680 * o.uiScale)) return false
    if (o.screenWidth <= 0 || !o.frameRead) return true
    return o.windowWidth + o.slack >= o.minWidth
}

// The compositor's frame around the panel, in logical pixels. Hyprland reports
// the gap and border in physical pixels, so they are scaled by the ratio of the
// panel's logical width to its physical one. Zero when either width is unknown.
function windowInset(gap, border, logicalWidth, physicalWidth) {
    if (!(logicalWidth > 0 && physicalWidth > 0)) return 0
    return Math.round((asNumber(gap) + asNumber(border)) * logicalWidth / physicalWidth)
}

// ---- compositor readings ----
//
// hyprctl's JSON, reduced to the few numbers the layout needs. These are string
// parsing rather than geometry, but they are the *input* to windowInset and the
// artwork threshold, and they fail in quiet ways (a missing hyprctl, Hyprland
// not running, a CSS-shaped option), so they are kept pure and tested beside
// the geometry they feed instead of in a binding only a live shell can reach.

// The single integer an option carries. border_size is a plain int, so it is
// read from `int`; a value given as CSS would still parse through the same
// path, which is why both keys are tried rather than assuming one shape.
function optionInt(raw) {
    try {
        var json = JSON.parse(raw || "{}")
        var css = String(json.css || "")
        var parts = css.match(/-?\d+(?:\.\d+)?/g) || []
        var n = parts.length > 0 ? Number(parts[0]) : Number(json.int)
        return isFinite(n) && n >= 0 ? Math.round(n) : 0
    } catch (e) {
        return 0
    }
}

// One side of a css_gaps option, in the order Hyprland reads them:
// "top right bottom left" when four numbers are given, "top/bottom left/right"
// when two, and all four the same when one. The width a window loses is the
// left plus the right gap, so a lone number is correct for a uniform config
// and wrong for an asymmetric one -- `gaps_out = 20 40` puts 40 on the sides
// and would otherwise measure 20. Reading the horizontal pair is the whole
// point of not just taking the first number.
function gapsOutHorizontal(raw) {
    try {
        var json = JSON.parse(raw || "{}")
        var css = String(json.css || "")
        var parts = css.match(/-?\d+(?:\.\d+)?/g)
        if (!parts || parts.length === 0) {
            var n = Number(json.int)
            return isFinite(n) && n >= 0 ? Math.round(n) : 0
        }
        var v = parts.map(Number)
        var left, right
        if (v.length >= 4) { right = v[1]; left = v[3] }
        else if (v.length === 3) { right = v[1]; left = v[1] }
        else if (v.length === 2) { right = v[1]; left = v[1] }
        else { right = v[0]; left = v[0] }
        if (!isFinite(left) || !isFinite(right) || left < 0 || right < 0) return 0
        // The inset is per side, and this figure is used as one side, so the
        // two sides are averaged: an asymmetric gap has no single per-side
        // value, and the threshold only needs the window's reduction, which
        // left + right gives exactly when doubled at the call site.
        return Math.round((left + right) / 2)
    } catch (e) {
        return 0
    }
}

// The physical width of the monitor the panel is on, found by name rather
// than taken as the first entry: on a multi-monitor desk Hyprland lists the
// monitors in its own order, and the first is not necessarily the one this
// window opened on. Falling back to the first is only for the case where the
// screen has no name to match yet; the inset is then wrong on a mixed-scale
// desk, which is the same fault as before and no worse.
function monitorWidthFor(raw, name) {
    try {
        var list = JSON.parse(raw || "[]")
        if (!list || list.length === 0) return 0
        for (var i = 0; i < list.length; i++) {
            if (name !== "" && list[i].name === name && isFinite(Number(list[i].width)))
                return Math.round(Number(list[i].width))
        }
        if (isFinite(Number(list[0].width))) return Math.round(Number(list[0].width))
    } catch (e) {
        // hyprctl missing / Hyprland not running: leave the inset at zero.
    }
    return 0
}

// The scale of the monitor the panel is on, matched by name for the same
// reason as monitorWidthFor: on a mixed-scale desk the first entry is not
// necessarily the screen this window opened on. Hyprland reports `scale` as
// physical pixels per logical pixel, which is the number the divider quantum
// is derived from. Zero means "not answered"; the panel then falls back to
// the screen's own ratio.
function monitorScaleFor(raw, name) {
    try {
        var list = JSON.parse(raw || "[]")
        if (!list || list.length === 0) return 0
        for (var i = 0; i < list.length; i++) {
            if (name !== "" && list[i].name === name && Number(list[i].scale) > 0)
                return Number(list[i].scale)
        }
        if (Number(list[0].scale) > 0) return Number(list[0].scale)
    } catch (e) {
        // hyprctl missing / Hyprland not running: the fallback handles it.
    }
    return 0
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        coverScalePct: coverScalePct,
        heroCover: heroCover,
        albumCoverSize: albumCoverSize,
        paneCoverSize: paneCoverSize,
        coverPaneWidth: coverPaneWidth,
        coverBandInset: coverBandInset,
        coverBandY: coverBandY,
        floatingCoverSize: floatingCoverSize,
        karaokeCoverSize: karaokeCoverSize,
        lyricsColumnWidth: lyricsColumnWidth,
        coverBandVisible: coverBandVisible,
        windowInset: windowInset,
        optionInt: optionInt,
        gapsOutHorizontal: gapsOutHorizontal,
        monitorWidthFor: monitorWidthFor,
        monitorScaleFor: monitorScaleFor
    }
}
