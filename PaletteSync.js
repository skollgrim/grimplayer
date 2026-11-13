// Which palette the panel should show for the cover it is on.
//
// Three sources can disagree for a moment while a cover loads: the cache keyed
// on the resolved cover URL, the colours the quantizer last produced, and the
// previous album's palette still on screen. The rules between them sit here,
// not in an if-chain in GrimPlayer.syncTheme(), where only a running shell
// could exercise the one that matters most -- the race guard that keeps a stale
// quantization from being shown against the new cover and cached under it.
//
// Keeping the decision here makes that table explicit and testable without a
// shell. The function is pure: state in, one action out, no theme touched. The
// caller performs the action, so the same decision can be read in a test and
// still drive the real panel.
//
// Deliberately not a `.pragma library`, for the same reason as Palette.js: a
// library is compiled once per engine and would not pick up edits on reload.

var DERIVED = "derived"
var APPLY = "apply"
var RESET = "reset"
var HOLD = "hold"

// state: {
//     adaptive: bool,        // the adaptive-colours setting is on
//     hasArt: bool,          // the probe found artwork for this cover
//     paletteSource: string, // the cover URL the held colours were read from
//     paletteSize: int,      // how many colours are held
//     noArt: bool            // the probe finished with nothing to read
// }
// source is the resolved cover URL the panel is on now, cached the palette
// already known for it (or null).
function pick(state, source, cached) {
    if (!state.adaptive) return { action: RESET }
    // A cache hit is the whole point of the cache: on a revisit the cover skips
    // the colour pass, so there is nothing else to apply.
    if (cached) return { action: DERIVED, palette: cached }

    var key = source ? String(source) : ""
    // Only colours quantized from this very cover may be applied or cached.
    // While a new cover loads the quantizer still holds the previous album's
    // colours, and applying those against the new source would both show the
    // wrong album's ground and poison the cache with it. Holding leaves the
    // previous palette up until the new pass lands, which also keeps the theme
    // from flashing mid-probe.
    if (state.hasArt && String(state.paletteSource || "") === key
            && state.paletteSize > 0)
        return { action: APPLY }

    // The probe has finished and this cover has no artwork at all, so there is
    // nothing to wait for. An empty or still-probing cover holds instead: the
    // Image reports Error between candidates, and resetting on that would flash
    // the theme through between tracks.
    if (state.noArt) return { action: RESET }
    return { action: HOLD }
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        DERIVED: DERIVED,
        APPLY: APPLY,
        RESET: RESET,
        HOLD: HOLD,
        pick: pick
    }
}
