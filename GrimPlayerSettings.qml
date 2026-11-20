pragma ComponentBehavior: Bound
// The settings card, modal over the browser.
//
// The settings are cut into tabs by topic: General, Now playing, Artwork, Lyrics,
// Library view, Album view, Lyrics view and Karaoke view. A tab is one subject
// rather than one kind of control, so a slider and a switch sit together where
// their subject says they should, and a setting is always in the same place every
// time the card opens.
//
// A setting that waits on another is drawn greyed rather than hidden, and is
// indented beneath the row it waits on, so the row above is why it is greyed and
// the block of rows reads as one setting's details. Keeping the row in place
// means a hunt for it always finds it; the caret never rests on a greyed row.
//
// Within a cell the label sits on the left and a fixed-width control block on the
// right, so every value in a tab lines up on the same vertical edge. That fixed
// width is what makes it look deliberate rather than ragged: without it the
// numeric rows push their values further right than the switches do.
//
// The visible tab scrolls, and the caret's own cell is brought into view as it
// moves, so a keyboard walk never lands on a row off the bottom edge.
//
// The selected row is marked three ways at once -- a filled background, an accent
// bar down its edge, and its label picked out in the accent -- so the caret is
// unmistakable whether the pointer or the keyboard put it there.
//
// Clicking the scrim closes the card.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
    id: root
    // A var alias for the shell's theme font object: qmllint cannot see the
    // tokens inside Style.font, so reading them directly warns on every one.
    readonly property var themeFont: Style.font

    property var config: null
    property int index: 0
    property bool editMode: false
    property real uiScale: 1.0

    // The tab always follows the caret: a setting lives in exactly one section,
    // so the section that contains the caret is the one to show. Tab clicks move
    // the caret into the tab they choose, which is what changes this.
    readonly property int categoryIndex: config ? config.tabOf(index) : 0

    // The row the caret last held in each tab, so stepping away and back returns
    // to the row you left rather than to the tab's first row. The caret itself
    // lives in the panel; this is only the card's memory of where it was.
    property var tabRow: ({})

    // The panel's colour tokens, injected. The card is modal over the panel, so
    // it follows the same palette as everything behind it.
    property var theme: null
    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent
    readonly property color colSelectedFill: theme ? theme.selectedFill : Style.selectedFill

    // The caret belongs to the panel, which also drives it from the keyboard, so
    // the card asks for a change instead of making one: assigning `index` or
    // `editMode` from in here would delete the binding the panel established and
    // every later keyboard move would stop reaching the card.
    signal indexRequested(int index)
    signal editModeRequested(bool on)
    signal dismissed()

    // The card renders the config's tabs directly. Each tab arrives as a
    // name plus its entries, and each entry carries its own index into the
    // visible list along with whether it is currently active -- that index, not
    // the entry object, is what the caret compares against, because an object
    // identity does not survive the trip through the Repeater's model.
    readonly property var tabs: config ? config.tabs : []

    // Slider plus value, in one fixed-width block, so the values line up down the
    // tab. The value block is the widest text any setting produces ("300 ms",
    // "instant"), so it holds the odd one without the numbers jumping about.
    readonly property int sliderWidth: Math.round(56 * uiScale)
    readonly property int valueWidth: Math.round(44 * uiScale)
    readonly property int controlWidth: sliderWidth + Math.round(6 * uiScale) + valueWidth
    // A free-text row prints a whole path, which is far wider than any switch
    // value. It gets its own width and elides on the left, so the tail -- the
    // part that says which folder -- is what stays visible.
    readonly property int textWidth: Math.round(260 * uiScale)

    // The hint belongs to the entry under the caret, and the caret is an index
    // into config.visibleEntries -- the same list the panel walks.
    readonly property var current: config && config.visibleEntries.length > 0
        ? config.visibleEntries[Math.max(0, Math.min(index, config.visibleEntries.length - 1))]
        : null

    // Park the caret on a row and leave edit mode.
    function caretAt(i) {
        root.indexRequested(i)
        root.editModeRequested(false)
    }

    // Remember where the caret sits inside its tab, so a later return to that
    // tab can restore the row instead of landing on its first entry.
    function rememberRow() {
        if (!root.config) return
        var c = root.config.tabOf(root.index)
        var r = root.config.rowOf(root.index)
        var next = {}
        for (var k in root.tabRow) next[k] = root.tabRow[k]
        next[c] = r
        root.tabRow = next
    }

    onIndexChanged: root.rememberRow()
    Component.onCompleted: root.rememberRow()

    // One setting cell. The same component draws every tab; the model
    // states the entry and its index, and the cell reads the entry for the label
    // and value and for whether it is a slider.
    Component {
        id: settingCell

        Rectangle {
            id: row

            required property var modelData
            readonly property var entryData: modelData.entry
            readonly property var opts: entryData.options || []
            readonly property bool numeric: root.config ? root.config.isSlider(entryData) : false
            readonly property bool textRow: root.config ? root.config.isText(entryData) : false
            readonly property int optIndex: root.config
                ? opts.indexOf(root.config.valueFor(entryData)) : -1
            readonly property real fraction: opts.length > 1 ? Math.max(0, optIndex) / (opts.length - 1) : 0
            // The caret's currency is this integer, straight from the model.
            readonly property int visIndex: modelData.index
            readonly property bool selected: visIndex === root.index
            // A dependent whose parent is off. It is drawn, but greyed and kept
            // out of the caret's way, so it cannot change a value nothing reads.
            readonly property bool active: modelData.active !== false
            // A row that names a parent in `after` is a child of that row, and
            // tucks in a step so the block reads as one setting's details. The
            // indent is what lets a child carry a bare name -- "Size", "Position"
            // -- without the row above being the only thing that says what it
            // sizes. It is layout, not state: the row does not move when its
            // parent flips, only fades.
            readonly property bool dependent: !!entryData.after
            readonly property int indent: Math.round(16 * root.uiScale)

            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(32 * root.uiScale)
            // The row's own content width, exposed so the tab has something to
            // size to. The inner RowLayout is anchored, so it does not feed the
            // implicit width on its own; its natural width plus the two margins
            // is what the cell actually needs. The child indent is part of that,
            // or an indented row would claim less width than it draws.
            implicitWidth: innerRow.implicitWidth
                + Math.round(16 * root.uiScale) + Math.round(10 * root.uiScale)
                + (dependent ? indent : 0)
            radius: Math.round(6 * root.uiScale)
            // The caret's fill snaps from row to row. Animating it along with
            // the hover fill makes an up/down step look like the selection is
            // still catching up while the accent bar and the label have already
            // moved.
            color: selected ? root.colSelectedFill : "transparent"

            // The pointer's own answer, drawn under the row's content and faded
            // in and out separately. Keeping it off the row's background is what
            // lets selection stay instant without losing the soft hover.
            Rectangle {
                anchors.fill: parent
                radius: row.radius
                color: Util.alpha(root.colForeground, 0.04)
                opacity: (row.active && !row.selected && rowMouse.containsMouse) ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: Style.duration(90) } }
            }

            // A greyed dependent stays visible but reads as switched off: the
            // whole row fades, and the value ink stops being the accent it is on a
            // live row. It is drawn for discovery only; the caret skips it.
            opacity: active ? 1.0 : 0.4

            // Keep the caret's row on screen as it moves, and once more when the
            // cell is created, since a cell that appears already selected never
            // fires selectedChanged.
            onSelectedChanged: if (selected) Qt.callLater(function() { if (flick) flick.reveal(row) })
            Component.onCompleted: if (selected) Qt.callLater(function () { if (flick) flick.reveal(row) })

            // An accent bar down the selected row's edge: a second, pointer-proof
            // mark of the caret, so selection reads even where the fill alone is
            // faint against a busy cover colour.
            Rectangle {
                visible: row.selected
                anchors.left: parent.left
                anchors.leftMargin: Math.round(4 * root.uiScale)
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(2, Math.round(3 * root.uiScale))
                height: Math.max(0, parent.height - Math.round(10 * root.uiScale))
                radius: width / 2
                color: root.colAccent
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: row.active ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    // A greyed row is drawn only so its dependency is discoverable.
                    // It never takes the caret and never edits a value nothing on
                    // screen reads; the row above it says what it waits on.
                    if (!row.active) return
                    // Clicking elsewhere just parks the caret.
                    if (root.index !== row.visIndex) {
                        root.caretAt(row.visIndex)
                        return
                    }
                    // Clicking the row you are already on does what Enter does: a
                    // plain switch flips, a slider or a text row opens for
                    // editing (and clicking it again accepts the edit).
                    if (row.numeric || row.textRow) {
                        root.editModeRequested(!root.editMode)
                    } else if (root.config) {
                        root.config.cycle(row.entryData, 1)
                    }
                }
            }

            RowLayout {
                id: innerRow
                anchors.fill: parent
                anchors.leftMargin: Math.round(16 * root.uiScale)
                    + (row.dependent ? row.indent : 0)
                anchors.rightMargin: Math.round(10 * root.uiScale)
                spacing: Math.round(8 * root.uiScale)

                // The label is deliberately not bolded when the row is selected.
                // Bolding changes its advance, which moves the elide point and
                // makes the longest label jitter under the caret. The accent ink,
                // the filled row and the bar down its edge already carry the
                // selection.
                //
                // A greyed dependent carries no note of its own: the indented row
                // above is the only explanation. When active but not selected, a
                // child label reads a touch quieter than a top-level row so the
                // parent-child link is clearer without adding extra chrome.
                Text {
                    Layout.fillWidth: true
                    text: row.entryData.label
                    textFormat: Text.PlainText
                    color: row.selected ? root.colAccent : root.colForeground
                    font.pixelSize: Math.round(root.themeFont.body * root.uiScale)
                    opacity: row.selected ? 1.0 : (row.dependent ? 0.58 : 0.72)
                    elide: Text.ElideRight
                }

                // Only a slider row reserves the track. A switch only needs the
                // value, and holding it a track's width from its label across an
                // empty gap would read as a broken row; values still line up
                // within a tab, which is what the layout asks for.
                RowLayout {
                    Layout.preferredWidth: row.numeric ? root.controlWidth
                        : (row.textRow ? root.textWidth : root.valueWidth)
                    Layout.alignment: Qt.AlignRight
                    spacing: 8

                    Item {
                        visible: row.numeric
                        Layout.preferredWidth: root.sliderWidth
                        Layout.preferredHeight: Math.round(20 * root.uiScale)

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: Math.max(1, Math.round(4 * root.uiScale))
                            radius: Math.max(1, Math.round(2 * root.uiScale))
                            color: Util.alpha(root.colForeground, row.selected ? 0.18 : 0.10)
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width * row.fraction
                            height: Math.max(1, Math.round(4 * root.uiScale))
                            radius: Math.max(1, Math.round(2 * root.uiScale))
                            color: root.colAccent
                            opacity: row.selected ? 1.0 : 0.55
                        }
                        // Drawn only once the setting is under the caret, so a
                        // stack of resting sliders reads as a scale rather than
                        // a row of knobs competing with the labels.
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            x: Math.max(0, Math.min(parent.width - width, parent.width * row.fraction - width / 2))
                            width: Math.round(12 * root.uiScale)
                            height: Math.round(12 * root.uiScale)
                            radius: Math.round(6 * root.uiScale)
                            color: root.colAccent
                            border.width: (row.selected && root.editMode) ? 2 : 1
                            border.color: root.colBackground
                            visible: row.selected
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            function pick(mx) {
                                // A greyed row's track is inert: clicks do nothing.
                                if (!row.active) return
                                if (row.opts.length === 0) return
                                var f = Math.max(0, Math.min(1, mx / width))
                                var i = Math.round(f * (row.opts.length - 1))
                                root.indexRequested(row.visIndex)
                                if (!root.config) return
                                root.config.assign(row.entryData, row.opts[i])
                                // Debounced inside the config, so a drag is one
                                // write and not one per pixel.
                                root.config.saveSoon()
                            }
                            onClicked: function (mouse) { pick(mouse.x); root.editModeRequested(true) }
                            onPositionChanged: function (mouse) { if (pressed) { pick(mouse.x); root.editModeRequested(true) } }
                        }
                    }

                    // The value keeps one weight: a bold one is wider, and since
                    // the box is fixed and the ink right-aligned, bolding would
                    // nudge the value sideways as the caret lands on the row.
                    Text {
                        text: root.config ? root.config.displayText(row.entryData) : ""
                        textFormat: Text.PlainText
                        // The accent marks a live value; a greyed row's value is
                        // muted so it reads as held-but-inactive rather than
                        // current.
                        color: row.active ? root.colAccent : root.colMuted
                        font.pixelSize: Math.round((row.textRow
                            ? root.themeFont.bodySmall : root.themeFont.body) * root.uiScale)
                        // The path's tail names the folder; the head is what can
                        // be spared on a narrow card.
                        elide: row.textRow ? Text.ElideLeft : Text.ElideNone
                        // An underline on the row being typed into is the one
                        // cue that the text is a draft and not the stored value.
                        font.underline: row.textRow && root.config
                            ? root.config.textEditKey === row.entryData.key : false
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: root.valueWidth
                        Layout.fillWidth: row.textRow
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        MouseArea {
            anchors.fill: parent
            onClicked: root.dismissed()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        // Wide enough for a label-left / control-right row without the labels
        // having to elide, and no wider than the window allows: on a panel too
        // small for the full width this falls back to the panel width less its
        // margin rather than overflowing it. The tabs take turns in this width
        // rather than sharing it, so the card never has to grow to fit every
        // topic at once.
        width: Math.min(Math.round(700 * root.uiScale),
                        parent.width - Math.round(16 * root.uiScale))
        // Fixed rather than window-relative: the list scrolls inside a Flickable,
        // so the card has no reason to grow with the panel.
        height: Math.min(Math.round(700 * root.uiScale), parent.height - Math.round(32 * root.uiScale))
        radius: Math.round(12 * root.uiScale)
        color: root.colBackground
        border.width: 1
        border.color: Util.alpha(root.colForeground, 0.10)

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Math.round(24 * root.uiScale)
            spacing: 0

            Text {
                text: "Settings"
                textFormat: Text.PlainText
                color: root.colForeground
                font.pixelSize: Math.round(root.themeFont.body * root.uiScale)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.6
            }

            // A Flow rather than a Row: the topics outgrew one row when album
            // view got a tab of its own. A Row would shrink every pill below
            // its label and let the text spill over its neighbours; wrapping
            // keeps each pill at its natural width and puts the remainder on a
            // second line, which is also what a large uiScale needs on a narrow
            // panel.
            Flow {
                id: tabFlow
                Layout.fillWidth: true
                Layout.topMargin: Math.round(10 * root.uiScale)
                Layout.bottomMargin: Math.round(10 * root.uiScale)
                Layout.preferredHeight: childrenRect.height
                spacing: Math.round(6 * root.uiScale)

                Repeater {
                    model: root.tabs
                    delegate: Rectangle {
                        id: tab
                        required property var modelData
                        required property int index
                        height: Math.round(28 * root.uiScale)
                        width: tabText.implicitWidth + Math.round(14 * root.uiScale)
                        radius: Math.round(6 * root.uiScale)
                        color: tab.index === root.categoryIndex
                            ? Util.alpha(root.colAccent, 0.18)
                            : (tabMouse.containsMouse ? Util.alpha(root.colForeground, 0.05) : "transparent")
                        border.width: tab.index === root.categoryIndex ? 0 : 1
                        border.color: Util.alpha(root.colForeground, 0.12)

                        MouseArea {
                            id: tabMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                // Clicking the tab the caret is already in changes
                                // nothing: moving to its first row would throw away
                                // the row you were on for no reason.
                                if (root.categoryIndex === tab.index) {
                                    root.editModeRequested(false)
                                    return
                                }
                                var items = root.tabs[tab.index]
                                    ? root.tabs[tab.index].items : []
                                if (items.length === 0) return
                                var row = root.tabRow[tab.index] || 0
                                // A remembered row may have gone inactive while
                                // we were away. Let the config find the nearest
                                // live row rather than parking the caret on a
                                // greyed one that refuses every editing key.
                                var target = root.config
                                    ? root.config.activeIndexAt(tab.index, row) : -1
                                if (target < 0) return
                                root.indexRequested(target)
                                root.editModeRequested(false)
                            }
                        }

                        Text {
                            id: tabText
                            anchors.centerIn: parent
                            text: tab.modelData.name
                            color: tab.index === root.categoryIndex ? root.colForeground : root.colMuted
                            font.pixelSize: Math.round(root.themeFont.bodySmall * root.uiScale)
                            font.weight: tab.index === root.categoryIndex ? Font.DemiBold : Font.Normal
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.bottomMargin: Math.round(10 * root.uiScale)
                Layout.preferredHeight: 1
                color: Util.alpha(root.colForeground, 0.08)
            }

            Flickable {
                id: flick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: itemList.implicitHeight + Math.round(20 * root.uiScale)
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                function reveal(item) {
                    if (!item) return
                    var y = item.mapToItem(contentItem, 0, 0).y
                    var h = item.height
                    var pad = Math.round(12 * root.uiScale)
                    var bottom = Math.max(0, contentItem.height - height)
                    if (y - pad < contentY) {
                        contentY = Math.max(0, y - pad)
                    } else if (y + h + pad > contentY + height) {
                        contentY = Math.max(0, Math.min(bottom, y + h + pad - height))
                    }
                }

                ColumnLayout {
                    id: itemList
                    width: flick.width
                    spacing: Math.round(2 * root.uiScale)

                    Repeater {
                        model: root.tabs[root.categoryIndex] ? root.tabs[root.categoryIndex].items : []
                        delegate: settingCell
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(12 * root.uiScale)
                Layout.bottomMargin: Math.round(10 * root.uiScale)
                Layout.preferredHeight: 1
                color: Util.alpha(root.colForeground, 0.08)
            }

            Text {
                Layout.fillWidth: true
                text: root.current ? root.current.hint : ""
                textFormat: Text.PlainText
                color: root.colMuted
                font.pixelSize: Math.round(root.themeFont.bodySmall * root.uiScale)
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 1
                Layout.bottomMargin: Math.round(6 * root.uiScale)
            }

            Text {
                Layout.fillWidth: true
                text: root.editMode
                    ? (root.config && root.config.textEditKey !== ""
                        ? "EDITING — type a path  ·  Enter saves  ·  Esc cancels  ·  Backspace deletes"
                        : "EDITING — ←/→ or H/L adjust  ·  Enter/Esc step back")
                    : "↑↓←→ or J K H L move  ·  Enter toggles, or edits a slider or path  ·  g/G first/last  ·  Backspace resets row  ·  R resets all  ·  ? keys  ·  Esc/Q closes"
                textFormat: Text.PlainText
                color: root.editMode ? root.colAccent : root.colMuted
                font.pixelSize: Math.round(root.themeFont.caption * root.uiScale)
                opacity: 0.8
            }
        }
    }
}
