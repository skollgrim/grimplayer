pragma ComponentBehavior: Bound
// One of the library's three list panes.
//
// Rows are drawn as plain rectangles rather than with ListView's delegate
// recycling because the tallest pane holds at most a few hundred rows and the
// browser is only ever open while someone is looking at it. The simplicity is
// worth more here than the allocation, and it keeps the selection highlight and
// the playing-track marker in one place.
import QtQuick
import qs.Commons

Item {
    id: root

    property string title: ""
    property bool active: false
    property var model: []
    property int currentIndex: 0

    // Injected by the parent so this component stays free of library specifics.
    property var label: null
    property var sublabel: null
    property var isCurrent: null

    // The panel's colour tokens, injected the same way. Aliases keep the
    // fallback to the shell theme in one place, so this pane still draws
    // correctly if it is ever placed outside the panel.
    property var theme: null
    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent
    readonly property color colSelectedFill: theme ? theme.selectedFill : Style.selectedFill

    signal activated(int index)

    // rowSpacing is the row height setting; the gap is derived from it (an eighth
    // of the row) so one control sets the whole rhythm. uiScale multiplies the
    // result, and the fonts below ride along with it.
    property bool rowSeparators: false
    property bool focusGlow: true

    // Whether the pane draws its heading bar -- the name over an underline. Off,
    // the heading and its rule are dropped and the list runs to the very top of
    // the pane.
    property bool showHeading: true

    property real uiScale: 1.0
    property int rowSpacing: 32
    readonly property int rowHeight: Math.round(rowSpacing * uiScale)
    readonly property int rowGap: Math.max(1, Math.round(rowHeight / 8))

    // The right inset of the row content -- the label, the sublabel and the row
    // hairline all share it. A gutter rides on top of the base inset so a pane
    // that ends against the artwork (the tracks pane, when the cover band is on)
    // can keep its duration clear of the cover.
    property int rightGutter: 0
    readonly property int rowRightMargin: Math.round(12 * root.uiScale) + root.rightGutter

    // Which edges of the playing row carry the accent bar: "none", "left", "right"
    // or "both". The tint is unaffected -- this only places the bars. Only the
    // tracks pane is handed a current item, so the bars only ever show there.
    property string playingMarkerSides: "both"
    readonly property bool playingMarkerLeft: playingMarkerSides === "left" || playingMarkerSides === "both"
    readonly property bool playingMarkerRight: playingMarkerSides === "right" || playingMarkerSides === "both"
    // One width and one colour shared by both bars, so the pair can never render
    // as two differently-sized or differently-shaded marks.
    readonly property int playingMarkerWidth: Math.max(2, Math.round(3 * uiScale))

    // Resolved font sizes, injected by GrimPlayer as theme size plus the player's
    // offset, already scaled by uiScale. The defaults are the bare theme values,
    // which keep the pane correct if it is ever placed on its own.
    property int fontSizeHeading: Math.round(Style.font.bodySmall * uiScale)
    property int fontSizeRow: Math.round(Style.font.subtitle * uiScale)
    // Sublabels (track times) follow the row text, not the pane heading, so
    // the heading setting only ever touches the headings.
    property int fontSizeSublabel: Math.round(Style.font.subtitle * uiScale)

    // Thickness of the heading underline.
    property int borderWidth: 1

    // Thicker frame around the row the caret sits on.
    property bool activeRowBorder: false

    // Row pitch, used for scrolling: height plus the gap that follows it. The
    // gap is a real Column spacing, so it counts towards the scrollable extent
    // and the follow math has to step by this rather than by the bare row height.
    readonly property int rowPitch: rowHeight + rowGap

    // The focused pane holds full strength; the others pull back, but only when
    // focusGlow is on. It is a gentle pull (0.62) so the other two panes still
    // read as content rather than as disabled.
    readonly property real rowOpacity: !focusGlow || active ? 1.0 : 0.62

    Rectangle {
        anchors.fill: parent
        color: root.colBackground
        opacity: 0.97
    }

    // Everything the pane draws inside its outline.
    Item {
        anchors.fill: parent

        Text {
            id: heading
            visible: root.showHeading
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Math.round(16 * root.uiScale)
            anchors.rightMargin: Math.round(12 * root.uiScale)
            anchors.topMargin: Math.round(14 * root.uiScale)
            anchors.bottomMargin: Math.round(6 * root.uiScale)
            text: root.title
            color: root.active ? root.colForeground : root.colMuted
            font.pixelSize: root.fontSizeHeading
            font.weight: Font.DemiBold
            font.letterSpacing: 0.6
            elide: Text.ElideRight
        }

        Rectangle {
            visible: root.showHeading
            anchors.top: heading.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(1, Math.round(root.borderWidth * root.uiScale))
            color: Util.alpha(root.colForeground, 0.08)
        }

        Flickable {
            id: flick
            anchors.top: root.showHeading ? heading.bottom : parent.top
            anchors.topMargin: root.showHeading ? 1 : 0
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            contentWidth: width
            contentHeight: column.height
            boundsBehavior: Flickable.StopAtBounds

            // The parent's keyboard handling owns selection, so following
            // currentIndex is what keeps the cursor on screen. Padding keeps the
            // selected row clear of the pane edges instead of flush against them.
            Connections {
                target: root
                function onCurrentIndexChanged() {
                    var top = root.currentIndex * root.rowPitch
                    var bottom = top + root.rowHeight
                    if (top < flick.contentY)
                        flick.contentY = top
                    else if (bottom > flick.contentY + flick.height)
                        flick.contentY = bottom - flick.height
                }
            }

            Column {
                id: column
                width: flick.width
                // The gap between rows the rowSpacing setting promises. Column
                // spacing is part of column.height, so contentHeight picks it up
                // and the Flickable scrolls over it rather than clipping it.
                spacing: root.rowGap

                Repeater {
                    model: root.model

                    Rectangle {
                        id: row
                        required property var modelData
                        required property int index

                        width: flick.width
                        height: root.rowHeight

                        // The caret row gets a thicker frame when the preference is
                        // on, so the selection reads even when the row fill is
                        // scrolled partly off or sitting next to a playing tint.
                        // Only the focused pane frames it: every pane has a selected
                        // row, and framing all three at once reads as noise.
                        readonly property bool framed: root.activeRowBorder && root.active && index === root.currentIndex
                        border.width: framed ? Math.max(2, Math.round(2 * root.uiScale)) : 0
                        border.color: root.colAccent

                        // The track MPD is actually playing. Matching on the file is
                        // what keeps this honest: browsing any other album has no row
                        // whose file is the one MPD reports, so the highlight can only
                        // ever appear on the album the track actually belongs to.
                        readonly property bool playing: root.isCurrent !== null && root.isCurrent(modelData)

                        // Selection still wins, then hover. The caret is what the user
                        // is about to act on, so it stays the strongest thing in the
                        // row -- but the playing tint below marks the track when the
                        // caret happens to be somewhere else, which is the usual case
                        // while browsing. Both tints are held back in an inactive pane
                        // to match rowOpacity, apart from the accent bar, which is
                        // meant to stay findable.
                        color: index === root.currentIndex
                            ? (root.active ? root.colSelectedFill : Util.alpha(root.colForeground, 0.05))
                            : (row.playing ? Util.alpha(root.colAccent, root.active ? 0.11 : 0.07)
                               : (rowArea.containsMouse ? Util.alpha(root.colForeground, 0.03) : "transparent"))

                        // The marker that goes with the tint. A 2px bar was too easy to
                        // miss against a list of rows, and it is the one part of the
                        // treatment that stays at full strength when the pane is not
                        // focused. Left and right are the same bar, sharing their width
                        // and colour, so the pair reads as one frame rather than two
                        // marks; the playingMarkerSides setting decides which show.
                        Rectangle {
                            visible: row.playing && root.playingMarkerLeft
                            x: 0
                            width: root.playingMarkerWidth
                            height: parent.height
                            color: root.colAccent
                        }

                        Rectangle {
                            visible: row.playing && root.playingMarkerRight
                            // Placed from a floored x rather than anchored: the pane's
                            // right edge can land on a fraction when the window is not
                            // an even multiple of the UI scale, and an anchor there
                            // smears the bar across two pixels and shades it lighter
                            // than its left twin. Snapping keeps the two identical.
                            x: Math.floor(parent.width - width)
                            width: root.playingMarkerWidth
                            height: parent.height
                            color: root.colAccent
                        }

                        // Optional hairline between rows. Skipped on the last row so
                        // the list does not trail a line into empty space, and held
                        // below the row fill so a selected or playing row still reads
                        // as one solid block.
                        Rectangle {
                            visible: root.rowSeparators && row.index < root.model.length - 1
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: Math.round(16 * root.uiScale)
                            anchors.rightMargin: root.rowRightMargin
                            anchors.bottom: parent.bottom
                            height: 1
                            color: Util.alpha(root.colForeground, 0.06)
                        }

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: Math.round(16 * root.uiScale)
                            anchors.rightMargin: root.rowRightMargin
                            verticalAlignment: Text.AlignVCenter
                            text: root.label ? root.label(parent.modelData) : ""
                            color: root.colForeground
                            font.pixelSize: root.fontSizeRow
                            opacity: root.rowOpacity
                            elide: Text.ElideRight
                        }

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: Math.round(16 * root.uiScale)
                            anchors.rightMargin: root.rowRightMargin
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignRight
                            text: root.sublabel ? root.sublabel(parent.modelData) : ""
                            color: root.colMuted
                            font.pixelSize: root.fontSizeSublabel
                            opacity: root.rowOpacity
                            elide: Text.ElideRight
                        }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            hoverEnabled: true
                            // Selection is owned by the parent, which is the only
                            // thing that knows what the index means -- an artist
                            // index, an album index or a track index select against
                            // different lists. Assigning the local currentIndex here
                            // would drop the binding the parent set up and leave the
                            // parent still pointing at the old row.
                            onClicked: root.activated(row.index)
                        }
                    }
                }
            }
        }

        // Soft edges on the scroll area. A list that hard-clips at the top and
        // bottom reads as cut off; fading the first and last row into the pane
        // background shows there is more without drawing a scrollbar. Each fade only
        // appears while content is actually hidden past that edge. They carry no
        // input handlers, so rows underneath stay clickable.
        Rectangle {
            anchors.top: flick.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.round(18 * root.uiScale)
            visible: flick.contentY > 0.5
            gradient: Gradient {
                GradientStop { position: 0.0; color: Util.alpha(root.colBackground, 0.97) }
                GradientStop { position: 1.0; color: "transparent" }
            }
        }
        Rectangle {
            anchors.bottom: flick.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.round(18 * root.uiScale)
            visible: flick.contentY < flick.contentHeight - flick.height - 0.5
            gradient: Gradient {
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Util.alpha(root.colBackground, 0.97) }
            }
        }
    }


    // Nothing to show means the library has not loaded, or MPD is unreachable.
    // The window draws its own banner for that case, so this only covers a
    // genuinely empty pane rather than an error.
    //
    // Tested against model.length rather than a separate count property: it was
    // always handed the model's own length, and as a separate int it defaulted to
    // 0, so any caller that forgot it left the placeholder permanently on top of
    // a populated list.
    Text {
        anchors.centerIn: parent
        visible: root.model.length === 0
        text: "empty"
        color: root.colMuted
        font.pixelSize: root.fontSizeSublabel
    }
}
