pragma ComponentBehavior: Bound
// The album view's track column.
//
// This is deliberately not a PaneColumn. Album view is a now-playing surface,
// not a browser: the titles are the content, so there are no track numbers, no
// durations, no heading, no rules and no row fills. The column is centred in the
// space beside the cover, the playing title is the one full-strength line, and
// everything else is held back so the record reads at a glance.
//
// It is also the reading view's companion column when its lyrics keep the
// album's titles beside them. In that mode it steps down a size, lines the
// titles up on the left and gives up the wide caption measure, so it reads as a
// companion list beside the words rather than as the main surface. In album
// view the column keeps its own scale and vertical centring even when the
// lyrics join it; the stored alignment decides whether the titles are centred
// or drawn from the left margin.
//
// It is a Flickable rather than a ListView because an album is short -- a few
// dozen rows at most -- and the positioner makes it easy to centre the whole
// column when it fits. The parent still owns the selection: currentIndex and
// isCurrent are read, never written.
import QtQuick
import "Scroll.js" as Scroll
import qs.Commons

Item {
    id: root
    // A var alias for the shell's theme font object: qmllint cannot see the
    // tokens inside Style.font, so reading them directly warns on every one.
    readonly property var themeFont: Style.font

    property var theme: null
    property var prefs: null
    property var model: []
    property int currentIndex: 0

    // Smaller type and rows, left-aligned titles, and the full width of the
    // column as the measure. Used for the reading view's companion column,
    // where the lyrics are the subject and this list sits beside them.
    property bool compact: false

    // Where the titles and caption sit in album view. The reading view's
    // companion is always left: there the words are the subject and this list
    // is deliberately subdued, whatever the album's own alignment is.
    property string align: "center"
    readonly property bool alignLeft: root.compact || root.align === "left"
    readonly property int textAlignment: root.alignLeft
        ? Text.AlignLeft : Text.AlignHCenter

    // Injected by the panel. isCurrent identifies the track MPD is playing;
    // the panel always supplies it now that the tint has no off switch.
    property var isCurrent: null
    property var titleFor: null

    // The album this column belongs to. A now-playing surface that shows only
    // titles leaves the record unnamed; the panel supplies the identity so this
    // file stays free of library shape. `albumDetail` is the rest of the caption
    // (artist, year, running time), already joined by the panel.
    property string albumTitle: ""
    property string albumDetail: ""
    // Whether that caption is drawn. Album view can be left to the songs alone,
    // so this is a stored preference rather than a fixed part of the surface.
    property bool showCaption: true
    // How the caption is drawn, separately from what it says. "quiet" is the
    // small muted sleeve label the view opened with; "label" lifts the type a
    // step, and "heading" gives it a heavier, small-title treatment.
    property string captionStyle: "quiet"
    readonly property bool captionLabel: root.captionStyle !== "quiet"
    readonly property bool captionHeading: root.captionStyle === "heading"
    readonly property int captionFontOffset: root.prefs ? root.prefs.fontCaption : 0

    // Shown when the column has no rows. The panel supplies the reason -- still
    // connecting, loading, or an album with no tracks -- so the empty surface
    // says what is happening rather than just "empty".
    property string emptyText: ""

    // The playing title's ink. The panel passes the accent when it clears the
    // background, the foreground otherwise, so a pale sleeve still gets a
    // readable line.
    property color playingColor: colAccent

    signal activated(int index)
    signal folderRequested(int index)

    // Whether the pointer is "live". The compositor hides the cursor on a key
    // press (Hyprland's cursor:hide_on_key_press), so the row under a hidden
    // pointer should stop glowing too: otherwise the last hovered row stays lit
    // while the keyboard moves the caret. The panel clears this on any key and
    // sets it again on pointer movement.
    property bool pointerActive: true

    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent

    readonly property real uiScale: prefs ? prefs.uiScale : 1

    // Bigger than a browser row, but not karaoke-sized: this is read at a glance
    // while the record plays, not from across the room. The offset follows the
    // same theme-plus-stored-delta rule as every other font in the panel, but it
    // is album view's own -- changing the browser's "Rows" no longer resizes
    // these titles. The compact column steps down to body size and tightens its
    // rows so it can sit beside a full reading column without crowding it.
    readonly property int fontSize: root.compact
        ? Math.round((root.themeFont.body
            + (root.prefs ? root.prefs.fontBody : 0)) * 1.3 * uiScale)
        : Math.round((root.themeFont.subtitle
            + (root.prefs ? root.prefs.albumFont : 0)) * 1.9 * uiScale)
    readonly property int rowHeight: Math.round(fontSize * (root.compact ? 1.7 : 2.0))
    // The gap still scales with the title font; the stored spacing is extra
    // headroom on top, so zero is exactly the rhythm the view opened with.
    readonly property int rowGap: Math.round(fontSize * (root.compact ? 0.35 : 0.45))
        + Math.round((root.prefs ? root.prefs.albumTrackSpacing : 0) * uiScale)
    readonly property int rowPitch: rowHeight + rowGap
    readonly property int sideMargin: Math.round((root.compact ? 14 : 24) * uiScale)

    // A single line of titles does not want to run the full width of a large
    // window, so the text block is capped and centred inside the column. The
    // compact column is the width it is given: its measure is the column itself,
    // which is already narrow.
    readonly property int textWidth: root.compact
        ? Math.max(0, root.width - root.sideMargin * 2)
        : Math.max(0, Math.min(
            root.width - root.sideMargin * 2, Math.round(520 * root.uiScale)))
    // The block is centred by its anchor. Left alignment shifts it by however
    // far that centring put its edge from the column's margin, so a left-aligned
    // record starts at the same margin on a wide window as on a narrow one.
    readonly property int textOffset: root.sideMargin
        - (root.width - root.textWidth) / 2

    // The playing row is the anchor; the caret is the row the user is about to
    // act on. Both are stronger than the rest, and the caret is the stronger of
    // the two when it is somewhere else.
    readonly property real dimOpacity: 0.38
    readonly property real selectedOpacity: 0.80

    // Centre the whole column when it fits, and the caret row when it does not.
    // The row pitch is the same gap the Column uses, so the arithmetic and the
    // drawing can never disagree.
    function followCurrent(animated) {
        if (root.model.length === 0) return
        var index = Math.max(0, Math.min(root.currentIndex, root.model.length - 1))
        var rowCenter = column.y + index * root.rowPitch + root.rowHeight / 2
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        var target = Math.max(0, Math.min(rowCenter - flick.height / 2, maxY))
        if (animated && root.visible) {
            scrollAnim.stop()
            scrollAnim.to = target
            scrollAnim.start()
        } else {
            scrollAnim.stop()
            flick.contentY = target
        }
    }

    // Whole-row steps, the same rule the browser panes use (see Scroll.js).
    function scrollRows(rows) {
        if (rows === 0) return
        flick.contentY = Scroll.rowScrollTarget(flick.contentY, flick.contentHeight,
            flick.height, root.rowPitch, rows)
    }

    onCurrentIndexChanged: root.followCurrent(true)
    onModelChanged: {
        scrollAnim.stop()
        flick.contentY = 0
        // The column's height is only known after the new delegates exist.
        Qt.callLater(function () { root.followCurrent(false) })
    }
    onVisibleChanged: {
        if (root.visible) Qt.callLater(function () { root.followCurrent(false) })
    }

    // The record's identity above the titles. The panel supplies the words; this
    // file only draws them, elided rather than wrapped when the column is narrow.
    // By default it is a sleeve label -- small, muted and tracked like the panel's
    // other captions -- but the look is a stored choice, so "heading" can read as
    // a small title without changing what it says.
    Column {
        id: caption
        anchors.top: parent.top
        anchors.topMargin: Math.round((root.compact ? 12 : 20) * root.uiScale)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.horizontalCenterOffset: root.alignLeft ? root.textOffset : 0
        width: root.textWidth
        spacing: Math.round((root.captionHeading ? 4 : 2) * root.uiScale)
        visible: root.showCaption && (root.albumTitle !== "" || root.albumDetail !== "")

        Text {
            width: parent.width
            visible: text !== ""
            text: root.albumTitle
            color: root.colMuted
            font.family: root.themeFont.family
            font.pixelSize: Math.round((root.themeFont.bodySmall
                + (root.captionHeading ? 4 : root.captionLabel ? 2 : 0)
                + root.captionFontOffset) * root.uiScale)
            font.weight: root.captionHeading ? Font.DemiBold
                : root.captionLabel ? Font.Medium : Font.Normal
            font.letterSpacing: root.captionHeading ? 0.2 : root.captionLabel ? 0.4 : 0.6
            horizontalAlignment: root.textAlignment
            elide: Text.ElideRight
        }

        Text {
            width: parent.width
            visible: text !== ""
            text: root.albumDetail
            color: root.colMuted
            opacity: root.captionHeading ? 0.9 : root.captionLabel ? 0.85 : 0.75
            font.family: root.themeFont.family
            font.pixelSize: Math.round((root.themeFont.caption
                + (root.captionHeading ? 3 : root.captionLabel ? 1 : 0)
                + root.captionFontOffset) * root.uiScale)
            font.weight: root.captionHeading ? Font.Medium : Font.Normal
            font.letterSpacing: root.captionHeading ? 0.2 : root.captionLabel ? 0.4 : 0.6
            horizontalAlignment: root.textAlignment
            elide: Text.ElideRight
        }
    }

    Flickable {
        id: flick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: caption.visible ? caption.bottom : parent.top
        anchors.topMargin: caption.visible ? Math.round(14 * root.uiScale) : 0
        anchors.bottom: parent.bottom
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: Math.max(column.implicitHeight, height)

        Column {
            id: column
            width: flick.width
            // Centred when the album fits; pinned to the top and scrolled when it
            // does not. The compact column has no reason to float in the middle
            // of its share, so it starts at the top like the prose beside it.
            y: root.compact ? 0 : Math.max(0, (flick.height - implicitHeight) / 2)
            spacing: root.rowGap

            Repeater {
                model: root.model

                delegate: Item {
                    id: row
                    required property var modelData
                    required property int index

                    width: column.width
                    height: root.rowHeight

                    readonly property bool playing: root.isCurrent !== null
                        && root.isCurrent(modelData)
                    readonly property bool selected: index === root.currentIndex
                    // The pointer lights a row exactly as the caret does, and
                    // only while the pointer is live. The compositor hides the
                    // cursor on a key press, so a key also takes this highlight
                    // away; moving the pointer brings it back.
                    readonly property bool hovered: root.pointerActive && rowArea.containsMouse
                    readonly property bool lit: selected || hovered

                    Text {
                        id: title
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.horizontalCenterOffset: root.alignLeft ? root.textOffset : 0
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.textWidth
                        horizontalAlignment: root.textAlignment
                        verticalAlignment: Text.AlignVCenter
                        text: root.titleFor ? root.titleFor(row.modelData) : ""
                        color: row.playing ? root.playingColor : root.colForeground
                        opacity: row.playing ? 1.0
                            : (row.lit ? root.selectedOpacity : root.dimOpacity)
                        font.pixelSize: root.fontSize
                        font.weight: row.playing ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        // The pointer's own liveness, read from the row it is
                        // over rather than from a handler above the whole
                        // window: Qt delivers hover to the topmost hover target
                        // only, so a window-wide HoverHandler kept every row
                        // from ever seeing the pointer. Any movement over the
                        // column re-arms the highlight a key press cleared.
                        onEntered: root.pointerActive = true
                        onPositionChanged: root.pointerActive = true
                        onClicked: function (mouse) {
                            if (mouse.button === Qt.RightButton) root.folderRequested(row.index)
                            else root.activated(row.index)
                        }
                    }
                }
            }
        }
    }

    // Soft edges on the scroll area, as in the browser panes: a list that
    // hard-clips reads as cut off. They only appear while content is actually
    // hidden past that edge, and carry no input handlers, so the rows underneath
    // stay clickable.
    Rectangle {
        anchors.top: flick.top
        anchors.left: flick.left
        anchors.right: flick.right
        height: Math.round(root.rowHeight * 0.7)
        visible: flick.contentY > 0.5
        gradient: Gradient {
            GradientStop { position: 0.0; color: Util.alpha(root.colBackground, 0.98) }
            GradientStop { position: 1.0; color: "transparent" }
        }
    }
    Rectangle {
        anchors.bottom: flick.bottom
        anchors.left: flick.left
        anchors.right: flick.right
        height: Math.round(root.rowHeight * 0.7)
        visible: flick.contentY < flick.contentHeight - flick.height - 0.5
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Util.alpha(root.colBackground, 0.98) }
        }
    }

    // Whole-row wheel steps, matching the browser panes: the area sits above the
    // list because a handler on the Flickable itself never sees events aimed at
    // the row under the pointer, and it takes no clicks of its own.
    RowWheelArea {
        anchors.fill: flick
        rowPitch: root.rowPitch
        onScrolled: function (rows) { root.scrollRows(rows) }
    }

    NumberAnimation {
        id: scrollAnim
        target: flick
        property: "contentY"
        duration: 240
        easing.type: Easing.OutCubic
    }

    Text {
        anchors.centerIn: flick
        width: Math.max(0, Math.min(flick.width - Math.round(48 * root.uiScale),
            Math.round(420 * root.uiScale)))
        visible: root.model.length === 0
        text: root.emptyText !== "" ? root.emptyText : "No tracks"
        color: root.colMuted
        font.family: root.themeFont.family
        font.pixelSize: Math.round((root.themeFont.bodySmall
            + (root.prefs ? root.prefs.fontBodySmall : 0)) * root.uiScale)
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
}
