pragma ComponentBehavior: Bound
// The settings card, modal over the browser.
//
// The settings are laid out as columns cut by topic, each a single list under its
// own heading: the list and what plays it, the panes and their rules, the text
// and its scale, the cover art, and the player-wide extras. A column is one
// subject rather than one kind of control, so a slider and a switch sit together
// in a column where the thing they share says they should, and a setting is
// always in the same place every time the card opens.
//
// A setting that waits on another is drawn greyed rather than hidden, and is
// indented beneath the row it waits on, so the row above is why it is greyed and
// the block of rows reads as one setting's details. Keeping the row in place
// means a hunt for it always finds it, and a row that greys while the caret is on
// it does not move the thing under the caret.
//
// Within a cell the label sits on the left and a fixed-width control block on the
// right, so every value in a column lines up on the same vertical edge. That fixed
// width is what makes it look deliberate rather than ragged: without it the
// numeric rows push their values further right than the switches do.
//
// The columns scroll together, and the caret's own cell is brought into view as
// it moves, so a keyboard walk never lands on a row off the bottom edge.
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

    property var config: null
    property int index: 0
    property bool editMode: false
    property real uiScale: 1.0

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

    // The card renders the config's columns directly. Each column arrives as a
    // name plus its entries, and each entry carries its own index into the
    // visible list along with whether it is currently active -- that index, not
    // the entry object, is what the caret compares against, because an object
    // identity does not survive the trip through the Repeater's model.
    readonly property var columns: config ? config.columns : []

    // Compact mode for narrow windows
    readonly property bool compact: root.width < Math.round(850 * root.uiScale)
    
    // Slider plus value, in one fixed-width block, so the values line up down the
    // column. The value column is the widest text any setting produces ("300 ms",
    // "instant"), so it holds the odd one without the numbers jumping about.
    readonly property int sliderWidth: compact ? Math.round(56 * uiScale) : Math.round(80 * uiScale)
    readonly property int valueWidth: compact ? Math.round(44 * uiScale) : Math.round(56 * uiScale)
    readonly property int controlWidth: sliderWidth + Math.round(6 * uiScale) + valueWidth

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

    // One setting cell. The same component draws every column; the model
    // states the entry and its index, and the cell reads the entry for the label
    // and value and for whether it is a slider.
    Component {
        id: settingCell

        Rectangle {
            id: row

            required property var modelData
            readonly property var entryData: modelData.entry
            readonly property var opts: entryData.options || []
            readonly property bool numeric: opts.length > 0 && typeof opts[0] === "number"
            readonly property int optIndex: opts.indexOf(entryData.get())
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
            Layout.preferredHeight: Math.round((root.compact ? 32 : 36) * root.uiScale)
            // The row's own content width, exposed so a column that hugs its
            // content (see the columns' fill flag) has something to size to. The
            // inner RowLayout is anchored, so it does not feed the implicit width
            // on its own; its natural width plus the two margins is what the cell
            // actually needs. The child indent is part of that, or an indented row
            // would claim less width than it draws.
            implicitWidth: innerRow.implicitWidth
                + Math.round(12 * root.uiScale) + Math.round(10 * root.uiScale)
                + (dependent ? indent : 0)
            radius: Math.round(6 * root.uiScale)
            color: selected ? root.colSelectedFill : "transparent"

            // A greyed dependent stays visible but reads as switched off: the
            // whole row fades, and the value ink stops being the accent it is on a
            // live row. The caret fill is left alone so a row that greys while the
            // caret is already on it does not change under the eye.
            opacity: active ? 1.0 : 0.4

            // Keep the caret's row on screen as it moves, and once more when the
            // cell is created, since a cell that appears already selected never
            // fires selectedChanged.
            onSelectedChanged: if (selected) flick.reveal(row)
            Component.onCompleted: if (selected) Qt.callLater(function () { flick.reveal(row) })

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
                anchors.fill: parent
                onClicked: {
                    // Clicking elsewhere just parks the caret.
                    if (root.index !== row.visIndex) {
                        root.caretAt(row.visIndex)
                        return
                    }
                    // A greyed row does nothing but hold the caret: its value has
                    // no effect until the setting it waits on is on, and the card
                    // says so right there on the row.
                    if (!row.active) return
                    // Clicking the row you are already on does what Enter does: a
                    // plain switch flips, a slider opens for editing.
                    if (row.numeric) {
                        root.editModeRequested(!root.editMode)
                    } else if (root.config) {
                        root.config.cycle(row.entryData, 1)
                    }
                }
            }

            RowLayout {
                id: innerRow
                anchors.fill: parent
                anchors.leftMargin: Math.round(12 * root.uiScale)
                    + (row.dependent ? row.indent : 0)
                anchors.rightMargin: Math.round(10 * root.uiScale)
                spacing: Math.round(8 * root.uiScale)

                // The label is deliberately not bolded when the row is selected.
                // Bolding changes its advance, which changes this cell's implicit
                // width, which changes the column's -- and the columns divide the
                // row in proportion to their implicit widths, so every column
                // would shift a pixel or two each time the caret reached the
                // longest label. The accent ink, the filled row and the bar down
                // its edge already carry the selection.
                //
                // A greyed dependent carries no note of its own: it is indented
                // under the setting it waits on, so the row above is the note. When
                // active but not selected, a child label reads a touch quieter than
                // a top-level row so the parent-child link is clearer without adding
                // extra chrome.
                Text {
                    Layout.fillWidth: true
                    text: row.entryData.label
                    textFormat: Text.PlainText
                    color: row.selected ? root.colAccent : root.colForeground
                    font.pixelSize: Math.round(Style.font.body * root.uiScale)
                    opacity: row.selected ? 1.0 : (row.dependent ? 0.58 : 0.72)
                    elide: Text.ElideRight
                }

                // Only a slider row reserves the track. A switch only needs the
                // value, and holding it a track's width from its label across an
                // empty gap would read as a broken row; values still line up
                // within a column, which is what the layout asks for.
                RowLayout {
                    Layout.preferredWidth: row.numeric ? root.controlWidth : root.valueWidth
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
                        // column of resting sliders reads as a scale rather than
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
                            function pick(mx) {
                                // A greyed row's track is drawn but inert; the only
                                // thing a click may do is park the caret on it.
                                if (!row.active) return
                                if (row.opts.length === 0) return
                                var f = Math.max(0, Math.min(1, mx / width))
                                var i = Math.round(f * (row.opts.length - 1))
                                root.indexRequested(row.visIndex)
                                row.entryData.set(row.opts[i])
                                // Debounced inside the config, so a drag is one
                                // write and not one per pixel.
                                if (root.config) root.config.saveSoon()
                            }
                            onClicked: function (mouse) { pick(mouse.x); root.editModeRequested(true) }
                            onPositionChanged: function (mouse) { if (pressed) { pick(mouse.x); root.editModeRequested(true) } }
                        }
                    }

                    // The value keeps one weight: a bold one is wider, and since
                    // the box is fixed and the ink right-aligned, bolding would
                    // nudge the value sideways as the caret lands on the row.
                    Text {
                        text: root.config ? root.config.textOf(row.entryData) : ""
                        textFormat: Text.PlainText
                        // The accent marks a live value; a greyed row's value is
                        // muted so it reads as held-but-inactive rather than
                        // current.
                        color: row.active ? root.colAccent : root.colMuted
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: root.valueWidth
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
        // Wide enough for five columns of label-left / control-right without the
        // labels having to elide, and no wider than the window allows: on a panel
        // too small for the full width this falls back to the panel width less its
        // margin rather than overflowing it.
        //
        // Five rather than four columns is what the topic cut costs: splitting by
        // subject needs somewhere for the panes and the text to each live on their
        // own. The width is fixed and generous enough that no label has to elide at
        // full size, so on a narrow panel the columns share what there is and the
        // labels elide rather than the card overflowing.
        width: root.compact 
            ? Math.min(Math.round(700 * root.uiScale), parent.width - Math.round(16 * root.uiScale))
            : Math.min(Math.round(1100 * root.uiScale), parent.width - Math.round(32 * root.uiScale))
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
                font.pixelSize: Math.round(Style.font.body * root.uiScale)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.6
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(12 * root.uiScale)
                Layout.bottomMargin: Math.round(12 * root.uiScale)
                Layout.preferredHeight: 1
                color: Util.alpha(root.colForeground, 0.08)
            }

            Flickable {
                id: flick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: root.compact ? boardCompact.implicitHeight : board.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                // Flickable has no ensureVisible of its own, so the card scrolls
                // the caret's own cell into view whenever it moves. Without it a
                // keyboard walk off the bottom edge selects a row nobody can see.
                function reveal(item) {
                    if (!item) return
                    var y = item.mapToItem(contentItem, 0, 0).y
                    var h = item.height
                    var pad = Math.round(8 * root.uiScale)
                    var bottom = Math.max(0, contentItem.height - height)
                    if (y - pad < contentY) {
                        contentY = Math.max(0, y - pad)
                    } else if (y + h + pad > contentY + height) {
                        contentY = Math.max(0, Math.min(bottom, y + h + pad - height))
                    }
                }

                RowLayout {
                    id: board
                    visible: !root.compact
                    width: flick.width
                    spacing: Math.round(16 * root.uiScale)

                    Repeater {
                        model: root.columns

                        delegate: ColumnLayout {
                            id: columnBlock
                            required property var modelData
                            Layout.fillWidth: modelData.fill !== false
                            Layout.alignment: Qt.AlignTop
                            spacing: Math.round(2 * root.uiScale)

                            Text {
                                Layout.fillWidth: true
                                text: columnBlock.modelData.name
                                textFormat: Text.PlainText
                                color: root.colMuted
                                font.pixelSize: Math.round((Style.font.bodySmall - 1) * root.uiScale)
                                font.weight: Font.Bold
                                font.letterSpacing: 0.8
                                font.capitalization: Font.AllUppercase
                                topPadding: Math.round(2 * root.uiScale)
                                bottomPadding: Math.round(4 * root.uiScale)
                            }

                            Repeater {
                                model: columnBlock.modelData.items
                                delegate: settingCell
                            }
                        }
                    }
                }

                ColumnLayout {
                    id: boardCompact
                    visible: root.compact
                    width: flick.width
                    spacing: Math.round(12 * root.uiScale)

                    Repeater {
                        model: root.columns

                        delegate: ColumnLayout {
                            id: sectionBlock
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignTop
                            spacing: Math.round(2 * root.uiScale)

                            Text {
                                Layout.fillWidth: true
                                text: sectionBlock.modelData.name
                                textFormat: Text.PlainText
                                color: root.colMuted
                                font.pixelSize: Math.round((Style.font.bodySmall - 1) * root.uiScale)
                                font.weight: Font.Bold
                                font.letterSpacing: 0.8
                                font.capitalization: Font.AllUppercase
                                topPadding: Math.round(6 * root.uiScale)
                                bottomPadding: Math.round(4 * root.uiScale)
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 1
                                color: Util.alpha(root.colForeground, 0.06)
                            }

                            Repeater {
                                model: sectionBlock.modelData.items
                                delegate: settingCell
                            }
                        }
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
                font.pixelSize: Math.round((Style.font.bodySmall - (root.compact ? 1 : 0)) * root.uiScale)
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: root.compact ? 1 : 2
                Layout.bottomMargin: Math.round(6 * root.uiScale)
            }

            Text {
                text: (root.editMode
                        ? "EDITING — ←/→ or H/L adjust  ·  Enter/Esc step back"
                        : "↑↓←→ or J K H L move  ·  Enter toggles, or opens a slider  ·  g/G first/last  ·  R resets  ·  ? keys  ·  Esc/Q closes")
                textFormat: Text.PlainText
                color: root.editMode ? root.colAccent : root.colMuted
                font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                opacity: 0.8
            }
        }
    }
}
