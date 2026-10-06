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

    // The config object, taken whole rather than as the dozen individual values
    // the panes want. That indirection is the whole reason the styling block had
    // to be restated per pane.
    property var prefs: null

    property real paneWidth: 0
    property string activePane: "artists"

    property var artistList: []
    property var albumList: []
    property var trackList: []
    property int artistIndex: 0
    property int albumIndex: 0
    property int trackIndex: 0

    // The playing song, for the tracks pane's "this one" highlight.
    property var current: null

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
    // Four logical pixels is the smallest multiple that lands on a whole output
    // pixel for any quarter-step scale (1, 1.25, 1.5, 1.75, 2). Pinning the first
    // pane to it puts the first rule's left edge on the grid, and giving the
    // second pane the rule's thickness back puts the second rule's left edge
    // there too. Both rules then start phase-aligned with the same width and
    // measure identically at every border width.
    readonly property int deviceQuantum: 4
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

    function alignQuantum(logical) {
        var q = root.deviceQuantum
        return Math.max(q, Math.round(logical / q) * q)
    }

    // Resolved once here rather than in the shared pane below. Font sizes are
    // offsets from the active Omarchy theme, so each is a theme token plus a
    // stored offset, scaled -- the expression the panel used to repeat nine times.
    readonly property real fontScale: prefs ? prefs.uiScale : 1
    readonly property int fontSizeHeading: prefs
        ? Math.round((Style.font.bodySmall + prefs.fontBodySmall) * root.fontScale) : 0
    readonly property int fontSizeRow: prefs
        ? Math.round((Style.font.subtitle + prefs.fontSubtitle) * root.fontScale) : 0
    readonly property int fontSizeSublabel: prefs
        ? Math.round((Style.font.subtitle + prefs.fontSubtitle) * root.fontScale) : 0



// ---- panes ----

// The shared pane, with the styling that used to be copied into each of the
// three. An inline component rather than three hand-written PaneColumns
// because that is exactly what it is for: a type used here that has no
// existence outside this file. Per-pane differences are set on each instance.




component PaneSlot: PaneColumn {
    Layout.fillHeight: true
    rowSpacing: root.prefs ? root.prefs.rowSpacing : 0
    rowSeparators: root.prefs ? root.prefs.rowSeparators : false
    focusGlow: root.prefs ? root.prefs.focusGlow : true
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
    }

    PaneDivider {
        x: root.artistsWidth + root.albumsWidth
        width: root.dividerThickness
        height: parent.height
        thickness: root.dividerThickness
    }
}
