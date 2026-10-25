pragma ComponentBehavior: Bound
// The panel's own colour tokens.
//
// The shell's Color singleton is global: writing an album's palette into it
// would recolour the bar, the notifications and every other panel, which is not
// what "the player matches its cover" means. So the player keeps its own copy
// of the handful of tokens it draws with, seeded from the theme and overwritten
// per track. Everything in the plugin that used to read Color.* reads this
// instead.
//
// The override is held as data and folded into a binding rather than assigned
// over the token directly. Assigning would break the Color.background binding
// permanently, so a theme switch made while adaptive colours were on would
// never reach the panel again once it was turned back off. Keeping the binding
// and selecting between it and the override means both follow their own source.
import QtQuick
import qs.Commons
import "Palette.js" as Palette

QtObject {
    id: root

    // null means "the theme's own colours", which is what shows whenever
    // adaptive colouring is off or there is no artwork to read.
    property var override: null
    property var paletteCache: ({})

    property color background: override ? override.background : Color.background
    property color foreground: override ? override.foreground : Color.foreground
    property color muted: override ? override.muted : Color.muted
    property color accent: override ? override.accent : Color.accent
    readonly property color accentHover: Util.alpha(accent, 0.8)
    readonly property color accentPressed: Util.alpha(accent, 0.65)
    readonly property color accentSubtle: Util.alpha(accent, 0.16)
    property color urgent: override ? override.urgent : Color.urgent

    // The wash under the caret row and the selected setting. Built from the
    // cover's accent rather than from Style.selectedFillFor: that yields a wash
    // of the foreground, which on a light panel is a dark-on-light smudge the
    // caret all but disappears into, and it is precomputed once from the shell
    // palette besides, so it would keep the theme's accent while the rest of the
    // panel moved to the cover's. The accent keeps the caret both visible and
    // part of the album's colour on either kind of ground.
    readonly property color selectedFill: Util.alpha(accent, 0.26)

    // Whether the panel's ground came out light. The derivation picks a light
    // ground for a mostly-white sleeve and a dark one otherwise, so anything
    // that steps away from the ground has to know which way is "away": shading a
    // light panel down by the same factor as a dark one would draw a near-black
    // band across it.
    readonly property bool light: (0.2126 * background.r
                                   + 0.7152 * background.g
                                   + 0.0722 * background.b) > 0.5

    // The now-playing strip sits a step away from the ground so it reads as a
    // band rather than as more list background. On a dark ground that is a
    // strong shade, on a light one a gentle tint -- the same eye-level step,
    // different maths. The light tint was pulled down (0.92 -> 0.86): at 0.92
    // the footer all but vanished into the panes above it on a near-white cover,
    // which is the case this band exists to separate from.
    readonly property color strip: light
        ? Qt.rgba(background.r * 0.86, background.g * 0.86, background.b * 0.86, 1.0)
        : Qt.rgba(background.r * 0.60, background.g * 0.60, background.b * 0.60, 1.0)

    // The live theme tokens, handed to the derivation as its fallback so a
    // colourless sleeve lands on the theme's accent rather than a grey. Read
    // fresh each time rather than captured, so a theme switch is picked up.
    function themeTokens() {
        return { background: Color.background, foreground: Color.foreground,
                 muted: Color.muted, accent: Color.accent, urgent: Color.urgent }
    }

    // Fold a cover's quantized colours into the panel. An empty list -- no
    // cover yet, or an album with none -- leaves the theme in place.
    function apply(colors) {
        if (!colors || colors.length === 0) { reset(); return }
        root.override = Palette.derive(colors, themeTokens())
    }

    // Linear blend, t = 0 gives a and t = 1 gives b. Used to tint a control's
    // resting state toward the cover accent without painting the glyphs the same
    // colour as the engaged state -- "accent" is reserved for "this toggle is on".
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t,
                       a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t,
                       a.a + (b.a - a.a) * t)
    }

    function reset() {
        root.override = null
    }

    // Crossfade rather than cut, so an album change reads as the room lights
    // shifting rather than a flicker. Style.duration is zero under
    // `omarchy toggle animations`, which turns every animation off at once.
    Behavior on background { ColorAnimation { duration: Style.duration(260) } }
    Behavior on foreground { ColorAnimation { duration: Style.duration(260) } }
    Behavior on muted { ColorAnimation { duration: Style.duration(260) } }
    Behavior on accent { ColorAnimation { duration: Style.duration(260) } }
    Behavior on urgent { ColorAnimation { duration: Style.duration(260) } }
}
