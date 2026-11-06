pragma ComponentBehavior: Bound
// The album view's track column.
//
// This is deliberately not a PaneColumn. Album view is a now-playing surface,
// not a browser: the titles are the content, so there are no track numbers, no
// durations, no heading, no rules and no row fills. The column is centred in the
// space beside the cover, the playing title is the one full-strength line, and
// everything else is held back so the record reads at a glance.
//
// It is a Flickable rather than a ListView because an album is short -- a few
// dozen rows at most -- and the positioner makes it easy to centre the whole
// column when it fits. The parent still owns the selection: currentIndex and
// isCurrent are read, never written.
import QtQuick
import qs.Commons

Item {
    id: root

    property var theme: null
    property var prefs: null
    property var model: []
    property int currentIndex: 0

    // Injected by the panel. isCurrent is null when the playing highlight is
    // turned off, which leaves the list as plain titles.
    property var isCurrent: null
    property var titleFor: null

    // The playing title's ink. The panel passes the accent when it clears the
    // background, the foreground otherwise, so a pale sleeve still gets a
    // readable line.
    property color playingColor: colAccent

    signal activated(int index)

    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent

    readonly property real uiScale: prefs ? prefs.uiScale : 1

    // Bigger than a browser row, but not karaoke-sized: this is read at a glance
    // while the record plays, not from across the room. The offset follows the
    // same theme-plus-stored-delta rule as every other font in the panel.
    readonly property int fontSize: Math.round((Style.font.subtitle
        + (prefs ? prefs.fontSubtitle : 0)) * 1.9 * uiScale)
    readonly property int rowHeight: Math.round(fontSize * 2.0)
    readonly property int rowGap: Math.round(fontSize * 0.45)
    readonly property int rowPitch: rowHeight + rowGap
    readonly property int sideMargin: Math.round(24 * uiScale)

    // A single line of titles does not want to run the full width of a large
    // window, so the text block is capped and centred inside the column.
    readonly property int textWidth: Math.max(0, Math.min(
        root.width - root.sideMargin * 2, Math.round(520 * root.uiScale)))

    // The playing row is the anchor; the caret is the row the user is about to
    // act on. Both are stronger than the rest, and the caret is the stronger of
    // the two when it is somewhere else.
    readonly property real dimOpacity: 0.38
    readonly property real selectedOpacity: 0.80
    readonly property real hoverOpacity: 0.58

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

    function scrollRows(rows) {
        if (rows === 0) return
        var pitch = root.rowPitch
        var maxY = Math.max(0, flick.contentHeight - flick.height)
        var base = Math.round(flick.contentY / pitch) * pitch
        flick.contentY = Math.max(0, Math.min(base + rows * pitch, maxY))
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

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        contentWidth: width
        contentHeight: Math.max(column.implicitHeight, height)

        Column {
            id: column
            width: flick.width
            // Centred when the album fits; pinned to the top and scrolled when it
            // does not.
            y: Math.max(0, (flick.height - implicitHeight) / 2)
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
                    readonly property bool hovered: rowArea.containsMouse

                    Text {
                        id: title
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.textWidth
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: root.titleFor ? root.titleFor(row.modelData) : ""
                        color: row.playing ? root.playingColor : root.colForeground
                        opacity: row.playing ? 1.0
                            : (row.selected ? root.selectedOpacity
                                : (row.hovered ? root.hoverOpacity : root.dimOpacity))
                        font.pixelSize: root.fontSize
                        font.weight: row.playing ? Font.DemiBold : Font.Normal
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: rowArea
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.activated(row.index)
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

    // Whole-row wheel steps, matching the browser panes. A handler on the
    // Flickable itself never sees events aimed at the row under the pointer, so
    // this empty item sits above the list; it has no mouse handling of its own,
    // so clicks and hover still reach the rows below.
    Item {
        anchors.fill: flick

        WheelHandler {
            id: wheelHandler
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            property real banked: 0
            onWheel: function (event) {
                var pitch = root.rowPitch
                var dy = event.pixelDelta.y
                if (dy !== 0) {
                    wheelHandler.banked += dy
                    if (Math.abs(wheelHandler.banked) < pitch) {
                        event.accepted = true
                        return
                    }
                    const rows = Math.trunc(wheelHandler.banked / pitch)
                    wheelHandler.banked -= rows * pitch
                    root.scrollRows(-rows)
                } else {
                    const angle = event.angleDelta.y
                    if (angle !== 0) root.scrollRows(angle < 0 ? 1 : -1)
                }
                event.accepted = true
            }
        }
    }

    NumberAnimation {
        id: scrollAnim
        target: flick
        property: "contentY"
        duration: 240
        easing.type: Easing.OutCubic
    }

    Text {
        anchors.centerIn: parent
        visible: root.model.length === 0
        text: "empty"
        color: root.colMuted
        font.pixelSize: Math.round(root.fontSize * 0.8)
    }
}
