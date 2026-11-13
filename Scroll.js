// Where a wheel or a keypress should leave a row list, and how far one wheel
// event moves it.
//
// The browser panes and album view scroll the same way -- whole rows, never a
// free pixel -- because a row sliced in half under the fade at either edge reads
// as a rendering fault. That rule lived twice, once per view, with the same
// arithmetic and the same touchpad banking; it lives here now, where
// extras/test-scroll.js can hold it still.
//
// Plain script rather than a `.pragma library`, like the other modules: a change
// must be picked up with the views that import it.

// The contentY that puts `rows` whole rows further down the list, from wherever
// it is now. Rows are counted from the nearest row boundary rather than from a
// raw pixel offset, so a list that has been nudged by something else still lands
// on the grid. Clamped to the scrollable range, so a step at either end does
// nothing rather than overshooting into blank space.
function rowScrollTarget(contentY, contentHeight, viewportHeight, pitch, rows) {
    if (!rows || !(pitch > 0)) return contentY
    var maxY = Math.max(0, contentHeight - viewportHeight)
    var base = Math.round(contentY / pitch) * pitch
    return Math.max(0, Math.min(base + rows * pitch, maxY))
}

// One wheel event's worth of movement, and the touchpad remainder to carry into
// the next event.
//
// A mouse wheel reports an angle delta and means "one notch, one row". A
// touchpad reports pixels, which are banked until they add up to a row -- a
// two-finger flick should move a readable number of rows, not race through the
// list. `banked` is the caller's running remainder; it is returned so the caller
// can put it back.
//
// The sign follows the wheel: pixel deltas are positive downwards, so a positive
// delta scrolls down, while a positive angle delta is a notch up, which is why
// the angle branch answers with the opposite sign. Both are returned as rows
// already directed, ready to hand to rowScrollTarget.
function wheelStep(pixelDelta, angleDelta, pitch, banked) {
    var carry = Number(banked) || 0
    var px = Number(pixelDelta) || 0
    var angle = Number(angleDelta) || 0
    if (!(pitch > 0)) return { rows: 0, banked: carry }

    if (px !== 0) {
        carry += px
        if (Math.abs(carry) < pitch) return { rows: 0, banked: carry }
        var rows = Math.trunc(carry / pitch)
        return { rows: -rows, banked: carry - rows * pitch }
    }
    if (angle !== 0) return { rows: angle < 0 ? 1 : -1, banked: carry }
    return { rows: 0, banked: carry }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        rowScrollTarget: rowScrollTarget,
        wheelStep: wheelStep
    }
}
