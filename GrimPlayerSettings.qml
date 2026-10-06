// The settings card, modal over the browser.
//
// Two columns of settings. Each cell puts the label on the left and a control
// block on the right whose width does not depend on whether that setting happens
// to be a slider, so every value lines up on the same vertical edge down both
// columns. That fixed-width block is the whole trick to it looking deliberate
// rather than ragged: without it the numeric rows push their values further
// right than the switches do and the eye reads the grid as misaligned.
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

    // The caret belongs to the panel, which also drives it from the keyboard, so
    // the card asks for a change instead of making one: assigning `index` or
    // `editMode` from in here would delete the binding the panel established and
    // every later keyboard move would stop reaching the card.
    signal indexRequested(int index)
    signal editModeRequested(bool on)

    // The card is two columns that are not two halves of one list: the sliders
    // all live in the right column and the switches and named choices in the
    // left, so the sizes read as their own group instead of being scattered
    // between the toggles. placement() flattens that back into one model with
    // an explicit row and column per entry, which lets a single Repeater drive
    // both columns.
    readonly property var plainItems: place(config ? config.plainEntries : [], 0)
    readonly property var sliderItems: place(config ? config.sliderEntries : [], 1)
    readonly property var items: plainItems.concat(sliderItems)

    // Slider plus value, in one fixed-width block. The value column is the
    // widest text any setting produces ("100%", "spacious"), so 58 holds the
    // odd one without the numbers jumping about as values change.
    readonly property int sliderWidth: Math.round(104 * uiScale)
    readonly property int valueWidth: Math.round(58 * uiScale)
    readonly property int controlWidth: sliderWidth + Math.round(8 * uiScale) + valueWidth

    // The hint belongs to the entry under the caret, and the caret is an index
    // into config.entries -- not into `items`, which groups switches and sliders
    // into two runs and so disagrees with the entries order.
    readonly property var current: config && config.entries.length > 0
        ? config.entries[Math.max(0, Math.min(index, config.entries.length - 1))]
        : null

    signal dismissed()

    // Park the caret on a row and leave edit mode.
    function caretAt(i) {
        root.indexRequested(i)
        root.editModeRequested(false)
    }

    // Each entry carries its index into the config's `entries` table, not its
    // position on screen, so the panel can keep settingIndex meaning the same
    // thing in both columns and prefs.entries[settingIndex] stays correct.
    function place(list, column) {
        var out = []
        if (!config) return out
        for (var i = 0; i < list.length; i++) {
            out.push({ entry: list[i], index: config.entries.indexOf(list[i]), row: i, column: column })
        }
        return out
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
        // Wide enough for two columns of label-left / control-right without the
        // labels having to elide.
        width: Math.round(900 * uiScale)
        // Fixed rather than window-relative: the entry list scrolls inside a
        // Flickable, so the card has no reason to grow with the panel.
        height: Math.round(700 * uiScale)
        radius: Math.round(12 * uiScale)
        color: Color.background
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.10)

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Math.round(24 * uiScale)
            spacing: 0

            Text {
                text: "Settings"
                color: Color.foreground
                font.pixelSize: Math.round(Style.font.body * uiScale)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.6
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(12 * uiScale)
                Layout.bottomMargin: Math.round(12 * uiScale)
                height: 1
                color: Qt.rgba(1, 1, 1, 0.08)
            }

            Flickable {
                id: flick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: grid.width
                contentHeight: grid.height
                boundsBehavior: Flickable.StopAtBounds

                GridLayout {
                    id: grid
                    // Two is the column count, but the rows are not sequential:
                    // every entry states its own, so the grid is 11 rows tall and
                    // the left one stops a row early.
                    columns: 2
                    columnSpacing: Math.round(24 * uiScale)
                    rowSpacing: Math.round(6 * uiScale)
                    width: card.width - Math.round(48 * uiScale)

                    Repeater {
                        model: root.items

                        Rectangle {
                            id: row
                            required property var modelData

                            readonly property var entryData: modelData.entry
                            readonly property var opts: entryData.options || []
                            readonly property bool numeric: opts.length > 0 && typeof opts[0] === "number"
                            readonly property int optIndex: opts.indexOf(entryData.get())
                            readonly property real fraction: opts.length > 1 ? Math.max(0, optIndex) / (opts.length - 1) : 0
                            readonly property bool selected: modelData.index === root.index

                            Layout.row: modelData.row
                            Layout.column: modelData.column
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.round(36 * root.uiScale)
                            radius: Math.round(6 * root.uiScale)
                            color: selected ? Style.selectedFill : "transparent"

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    // Clicking elsewhere just parks the caret.
                                    if (root.index !== row.modelData.index) {
                                        root.caretAt(row.modelData.index)
                                        return
                                    }
                                    // Clicking the row you are already on does
                                    // what Enter does: a plain switch flips, a
                                    // slider opens for editing.
                                    if (row.numeric) {
                                        root.editModeRequested(!root.editMode)
                                    } else {
                                        root.config.cycle(row.entryData, 1)
                                    }
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Math.round(10 * root.uiScale)
                                anchors.rightMargin: Math.round(10 * root.uiScale)
                                spacing: Math.round(8 * root.uiScale)

                                Text {
                                    Layout.fillWidth: true
                                    text: row.entryData.label
                                    color: Color.foreground
                                    font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                    opacity: row.selected ? 1.0 : 0.72
                                    elide: Text.ElideRight
                                }

                                // Only the slider column reserves the track. Giving the left column the
                                    // same block would hold its value 104px from its
                                    // label across an empty gap, which reads as a
                                    // broken row; values still line up within each
                                    // column, which is what the divider asks for.
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
                                            color: Qt.rgba(1, 1, 1, row.selected ? 0.18 : 0.10)
                                        }
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: parent.width * row.fraction
                                            height: Math.max(1, Math.round(4 * root.uiScale))
                                            radius: Math.max(1, Math.round(2 * root.uiScale))
                                            color: Color.accent
                                            opacity: row.selected ? 1.0 : 0.55
                                        }
                                        // Drawn only once the setting is under the
                                        // caret, so a column of resting sliders
                                        // reads as a scale rather than a row of
                                        // knobs competing with the labels.
                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            x: Math.max(0, Math.min(parent.width - width, parent.width * row.fraction - width / 2))
                                            width: Math.round(12 * root.uiScale)
                                            height: Math.round(12 * root.uiScale)
                                            radius: Math.round(6 * root.uiScale)
                                            color: Color.accent
                                            border.width: (row.selected && root.editMode) ? 2 : 1
                                            border.color: Color.background
                                            visible: row.selected
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            function pick(mx) {
                                                if (row.opts.length === 0) return
                                                var f = Math.max(0, Math.min(1, mx / width))
                                                var i = Math.round(f * (row.opts.length - 1))
                                                root.indexRequested(row.modelData.index)
                                                row.entryData.set(row.opts[i])
                                                // Debounced inside the config, so a
                                                // drag is one write and not one per pixel.
                                                if (root.config) root.config.saveSoon()
                                            }
                                            onClicked: function (mouse) { pick(mouse.x); root.indexRequested(row.modelData.index); root.editModeRequested(true) }
                                            onPositionChanged: function (mouse) { if (pressed) { pick(mouse.x); root.indexRequested(row.modelData.index); root.editModeRequested(true) } }
                                        }
                                    }

                                    Text {
                                        text: root.config ? root.config.textOf(row.entryData) : ""
                                        color: Color.accent
                                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                        font.weight: row.selected ? Font.DemiBold : Font.Normal
                                        horizontalAlignment: Text.AlignRight
                                        Layout.preferredWidth: root.valueWidth
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(12 * uiScale)
                Layout.bottomMargin: Math.round(10 * uiScale)
                height: 1
                color: Qt.rgba(1, 1, 1, 0.08)
            }

            Text {
                Layout.fillWidth: true
                text: root.current ? root.current.hint : ""
                color: Color.muted
                font.pixelSize: Math.round(Style.font.bodySmall * uiScale)
                wrapMode: Text.WordWrap
                Layout.bottomMargin: Math.round(8 * uiScale)
            }

            Text {
                text: (root.editMode
                        ? "EDITING — ←/→ or H/L adjust  ·  Enter/Esc step back"
                        : "↑↓←→ or J K H L move  ·  Enter toggles, or opens a slider  ·  g/G ends  ·  R resets  ·  Esc/?/Q closes")
                color: root.editMode ? Color.accent : Color.muted
                font.pixelSize: Math.round(Style.font.caption * uiScale)
                opacity: 0.8
            }
        }
    }
}