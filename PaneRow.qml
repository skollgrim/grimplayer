pragma ComponentBehavior: Bound
// The three list panes and the rules between them.
//
// This is a row of three panes that differ only in data, label and activation:
// everything else -- the styling block, the row rhythm, the fonts, the heading
// underline -- is identical across all three. Held together here rather than in
// the panel so that shared part is written once. In the panel it was a nine-line
// block repeated verbatim three times, twenty-seven lines that had to be edited in
// lockstep, and a fourth copy of the same Style.font expression appeared in the
// now-playing strip.
//
// The divider geometry comes with it for the same reason: a rule's position is
// only meaningful relative to the panes it divides, and the alignment that keeps
// the two rules the same width is a relationship between pane widths rather than a
// property of either rule. See deviceQuantum below.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
    id: root
    // A var alias for the shell's theme font object: qmllint cannot see the
    // tokens inside Style.font, so reading them directly warns on every one.
    readonly property var themeFont: Style.font

    // The config object, taken whole rather than as the dozen individual values
    // the panes want. That indirection is the whole reason the styling block had
    // to be restated per pane.
    property var prefs: null

    // The panel's colour tokens, forwarded to each pane. Not read here: this
    // row only lays the three panes out, and none of them draw anything of
    // their own.
    property var theme: null

    property real paneWidth: 0
    property string activePane: "artists"

    property var artistList: []
    property var albumList: []
    property var trackList: []
    property int artistIndex: 0
    property int albumIndex: 0
    property int trackIndex: 0

    // Which edges of the playing row carry the accent bar. Forwarded to the panes
    // untouched; only the tracks pane is handed a current item, so it only ever
    // shows there.
    property string playingMarkerSides: "both"

    // Extra right inset the panel hands the tracks pane, so its rows keep clear of
    // the artwork when the cover band is on. Only the tracks pane is set; the other
    // two keep the shared inset.
    property int trackArtGutter: 0

    // Per-pane text, as callbacks because the three panes phrase their rows
    // differently. PaneColumn treats a null callback as "this pane has no such
    // column", which is how the tracks pane gets a sublabel and duration the
    // others do not.
    property var artistLabel: null
    property var albumLabel: null
    property var trackLabel: null
    property var trackSublabel: null
    property var isCurrent: null

    signal artistActivated(int index)
    signal albumActivated(int index)
    signal trackActivated(int index)

    // ---- divider geometry ----
    //
    // The surface is rendered at logical size and the compositor scales it up,
    // so a rule that starts on a whole logical pixel lands between two output
    // pixels and gets smeared across both. Two rules of the same thickness on
    // different phases therefore rasterise to different widths -- which is what
    // made the artists|albums rule and the albums|tracks rule look mismatched
    // even though both were handed the same thickness.
    //
    // The quantum is the smallest whole number of logical pixels that lands on a
    // whole output pixel: for a device pixel ratio r, the smallest n with n*r
    // integral. At 1.25 that is 4 (4 * 1.25 = 5), and 4 is also the answer for
    // every other quarter-step scale -- 1, 1.5, 1.75, 2 -- which is why a hardcoded
    // 4 looked correct and was only ever correct by luck. A 1.3 display wants 10
    // and a 4/3 one wants 3; handing either of them 4 puts the rules back off the
    // grid and the mismatch comes straight back.
    //
    // Read from the screen the window is on, falling back to 4 when nothing
    // reports a ratio, which is the quarter-step case the old constant assumed.
    // Pinning the first pane to the quantum puts the first rule's left edge on the
    // grid, and the second rule is placed from that same quantum, so both rules
    // start phase-aligned with the same width and measure identically at every
    // border width.
    // Read from the panel rather than from Quickshell here: this file does not
    // import Quickshell, and referencing `Quickshell` from it is a ReferenceError
    // inside a binding, which does not fail loudly -- the property is simply left
    // at 0. A zero quantum then divides to Infinity inside alignQuantum, which
    // hands NaN to Layout.preferredWidth and collapses two of the three panes to
    // nothing. So the panel passes the ratio in, the same way it passes uiScale,
    // and a zero default means "not told yet" rather than "quantum of zero".
    property real pixelRatio: 0

    readonly property int deviceQuantum: {
        var ratio = root.pixelRatio
        if (!ratio || ratio <= 0) return 4
        // The tolerance is what lets a ratio that has no finite binary form --
        // 1.1, 4/3 -- land on its answer, since n * ratio lands a rounding error
        // away from the whole number rather than on it. The cap is what keeps an
        // exotic ratio with a huge denominator (1.234) from pinning the panes to
        // some enormous quantum; it falls back instead.
        for (var n = 1; n <= 64; n++) {
            var scaled = n * ratio
            if (Math.abs(scaled - Math.round(scaled)) < 0.000001) return n
        }
        return 4
    }
    // Whole logical pixels on purpose: the layout re-quantises item sizes to
    // them, so a fractional thickness would just be rounded away again.
    //
    // Every prefs test below is parenthesised, and the guard is not optional:
    // these bindings are evaluated while PaneRow is being constructed, which is
    // before the panel has assigned the config object to it. Reading through an
    // undefined prefs is a TypeError that takes the whole row down, and a
    // multi-line ternary without brackets is worse still -- the binding parser
    // treats the newline as a statement break, silently keeps only `prefs`, and
    // hands the property an object where an int belongs.
    readonly property int dividerThickness: prefs
        ? Math.max(1, Math.round(prefs.borderWidth * prefs.uiScale)) : 1

    // A light ground needs a firmer rule than a dark one: the same alpha that
    // reads clearly as a line on a dark pane all but disappears on a near-white
    // one, so the light case is stepped up. theme.light is the panel's own read
    // of its ground, so this follows an adaptive light cover and a light shell
    // theme alike. Shared by both rules so they can never drift apart.
    readonly property color ruleColor: root.theme
        ? Util.alpha(root.theme.foreground, root.theme.light ? 0.24 : 0.16)
        : Qt.rgba(1, 1, 1, 0.08)

    function alignQuantum(logical) {
        var q = root.deviceQuantum
        return Math.max(q, Math.round(logical / q) * q)
    }

    // Resolved once here rather than in the shared pane below. Font sizes are
    // offsets from the active Omarchy theme, so each is a theme token plus a
    // stored offset, scaled -- the expression the panel used to repeat nine times.
    readonly property real fontScale: prefs ? prefs.uiScale : 1
    readonly property int fontSizeHeading: prefs
        ? Math.round((root.themeFont.bodySmall + prefs.fontBodySmall) * root.fontScale) : 0
    readonly property int fontSizeRow: prefs
        ? Math.round((root.themeFont.subtitle + prefs.fontSubtitle) * root.fontScale) : 0
    readonly property int fontSizeSublabel: prefs
        ? Math.round((root.themeFont.subtitle + prefs.fontSubtitle) * root.fontScale) : 0

    // ---- panes ----

    // The shared pane, with the styling that used to be copied into each of the
    // three. An inline component rather than three hand-written PaneColumns
    // because that is exactly what it is for: a type used here that has no
    // existence outside this file. Per-pane differences are set on each instance.
    component PaneSlot: PaneColumn {
    theme: root.theme
    Layout.fillHeight: true
    rowSpacing: root.prefs ? root.prefs.rowSpacing : 0
    rowSeparators: root.prefs ? root.prefs.rowSeparators : false
    focusGlow: root.prefs ? root.prefs.focusGlow : true
    showHeading: root.prefs ? root.prefs.paneHeadings : true
    playingMarkerSides: root.playingMarkerSides
    uiScale: root.prefs ? root.prefs.uiScale : 1
    borderWidth: root.prefs ? root.prefs.borderWidth : 1
    activeRowBorder: root.prefs ? root.prefs.activeRowBorder : false
    fontSizeHeading: root.fontSizeHeading
    fontSizeRow: root.fontSizeRow
    fontSizeSublabel: root.fontSizeSublabel
}


    // The pane widths are read here rather than left to the layout to agree on,
    // because the rules are anchored to the boundaries between panes instead of
    // being laid out as items of their own. Both rules then get their position
    // and their width from the same two numbers, which is the whole point: the
    // layout had been handing them whatever it had left over, and that is how
    // two rules given the same thickness came out different widths.
    readonly property int artistsWidth: alignQuantum(paneWidth * 0.26)
    readonly property int albumsWidth: alignQuantum(paneWidth * 0.30)

    RowLayout {
        anchors.fill: parent
        spacing: 0

        PaneSlot {
            Layout.preferredWidth: root.artistsWidth
            title: "Artists"
            active: root.activePane === "artists"
            model: root.artistList
            currentIndex: root.artistIndex
            label: root.artistLabel
            onActivated: function (index) { root.artistActivated(index) }
        }

        PaneSlot {
            Layout.preferredWidth: root.albumsWidth
            title: "Albums"
            active: root.activePane === "albums"
            model: root.albumList
            currentIndex: root.albumIndex
            label: root.albumLabel
            onActivated: function (index) { root.albumActivated(index) }
        }

        PaneSlot {
            // Takes whatever the two fixed panes leave, rather than a share of its
            // own: the rules are pinned to the boundaries, so this is the one pane
            // that has to give way when the window is narrow.
            Layout.fillWidth: true
            title: "Tracks"
            active: root.activePane === "tracks"
            model: root.trackList
            currentIndex: root.trackIndex
            label: root.trackLabel
            sublabel: root.trackSublabel
            isCurrent: root.isCurrent
            // The one pane that ends against the artwork pane; held off it so the
            // durations do not crowd the cover.
            rightGutter: root.trackArtGutter
            onActivated: function (index) { root.trackActivated(index) }
        }
    }

    // The rules sit on the pane boundaries rather than in a slot of their own, so
    // a rule's left edge is exactly a pane's right edge and both are whole
    // multiples of the quantum. Anchored rather than laid out, and given their
    // thickness directly, because the alignment above only holds if nothing
    // downstream is free to resize them.
    PaneDivider {
        x: root.artistsWidth
        width: root.dividerThickness
        height: parent.height
        thickness: root.dividerThickness
        ruleColor: root.ruleColor
        // The column-separator setting. Off hides the rule; the panes still meet
        // at the same boundary, so nothing moves.
        visible: root.prefs ? root.prefs.paneSeparators : true
    }

    PaneDivider {
        x: root.artistsWidth + root.albumsWidth
        width: root.dividerThickness
        height: parent.height
        thickness: root.dividerThickness
        ruleColor: root.ruleColor
        visible: root.prefs ? root.prefs.paneSeparators : true
    }
}
