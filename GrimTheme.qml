pragma ComponentBehavior: Bound
// The panel's own colour tokens.
//
// The shell's Color singleton is global: writing an album's palette into it
// would recolour the bar, the notifications and every other panel, which is not
// what "the player matches its cover" means. So the player keeps its own copy
// of the handful of tokens it draws with, seeded from the theme and overwritten
// per track. Everything in the plugin that read Color.* reads this instead.
//
// The override is held as data and folded into a binding rather than assigned
// over the token directly. Assigning would break the Color.background binding
// permanently, so a theme switch made while adaptive colours were on would
// never reach the panel again once it was turned back off. Keeping the binding
// and selecting between it and the override means both follow their own source.
import QtQuick
import qs.Commons
// Qt 6.12's QtQuick also exposes a `Color` value type. Naming the shell's tokens
// through the module keeps them unambiguous in any engine that registers QtQuick
// first -- the QML test runner does, and would otherwise shadow the singleton
// with its own colour helpers. The shell's engine already resolves this the same
// way, so the qualification changes nothing there.
import qs.Commons as Commons
import "Palette.js" as Palette

QtObject {
    id: root

    // null means "the theme's own colours", which is what shows whenever
    // adaptive colouring is off or there is no artwork to read.
    property var override: null

    // Derived palettes keyed by the cover's resolved source. An album visited
    // again should not pay for another quantization and derivation; the key is
    // the URL the Image actually loaded, so a sidecar cover, an extracted one
    // and a downloaded one are distinct entries.
    //
    // The map itself lives in GrimPaletteStore, which also writes it to the
    // state directory: a QtObject cannot own a FileView. It is null until the
    // panel wires the store up, and without one the panel still derives a
    // palette -- it just forgets it when the shell stops.
    property var store: null

    readonly property var paletteCache: root.store ? root.store.cache : ({})

    function cachedPalette(source) {
        return root.store ? root.store.get(source) : null
    }

    function hasPalette(source) {
        return root.store ? root.store.has(source) : false
    }

    function storePalette(source, derived) {
        if (root.store) root.store.put(source, derived)
    }

    // A cover edit rewrites the picture behind an unchanged path, so the
    // palette cached against that path is stale. Clearing the whole map is
    // coarse but cheap: edits are rare and the cache refills on the next visit.
    function clearPaletteCache() {
        if (root.store) root.store.clear()
    }

    function applyDerived(derived) {
        root.override = derived
    }

    property color background: override ? override.background : Commons.Color.background
    property color foreground: override ? override.foreground : Commons.Color.foreground
    property color muted: override ? override.muted : Commons.Color.muted
    property color accent: override ? override.accent : Commons.Color.accent
    // The alert colour is semantic, not part of the album, so it always follows
    // the live theme rather than the palette copy. Cached palettes are derived
    // once and can outlive a theme switch; reading the token straight from the
    // theme keeps an alert from staying on the previous theme's red until the
    // cover changes again.
    property color urgent: Commons.Color.urgent

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

    // The live theme tokens, handed to the derivation as its fallback. Derive
    // reads only the urgent token from it -- a colourless sleeve makes its own
    // neutral accent and the other tokens come from the artwork -- and the panel
    // takes that token live rather than from the returned palette (see urgent).
    // Read fresh each time rather than captured, so a theme switch is picked up.
    function themeTokens() {
        return { background: Commons.Color.background, foreground: Commons.Color.foreground,
                 muted: Commons.Color.muted, accent: Commons.Color.accent,
                 urgent: Commons.Color.urgent }
    }

    // Fold a cover's quantized colours into the panel. An empty list -- no
    // cover yet, or an album with none -- leaves the theme in place. `source` is
    // the resolved cover URL; when it is present the derived palette is cached
    // against it so a later visit skips both the quantization and the derivation.
    function apply(colors, source) {
        if (!colors || colors.length === 0) { reset(); return }
        var cached = root.cachedPalette(source)
        if (cached) { root.override = cached; return }
        var derived = Palette.derive(colors, themeTokens())
        root.storePalette(source, derived)
        root.override = derived
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
