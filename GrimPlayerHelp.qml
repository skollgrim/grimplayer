pragma ComponentBehavior: Bound
// The key reference, modal over the browser.
//
// A plain cheat sheet: what keystroke does what, and -- since the settings card
// and the tag editor are reached from this window rather than the bar -- how to
// reach those two screens and this one. It is read-only, so it takes no caret and
// owns no state: the panel's key handler closes it on Esc, Q or ?.
//
// Clicking the scrim closes it, the way the settings card does.
import QtQuick
import QtQuick.Layouts
import qs.Commons

Item {
    id: root

    property real uiScale: 1.0

    // The panel's colour tokens, injected, so the reference sits in the same
    // palette as the card and the browser behind it.
    property var theme: null
    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent

    signal dismissed()

    // One block per kind of thing a key does. The key itself sits in a fixed
    // column on the left so the actions line up; the text follows.
    readonly property var sections: [
        {
            title: "Move & browse",
            rows: [
                { keys: "↑ ↓", action: "Change row" },
                { keys: "← →", action: "Change pane" },
                { keys: "any letter or digit", action: "Jump by typing a name (typeahead)" }
            ]
        },
        {
            title: "Vim keys",
            rows: [
                { keys: "j   k", action: "Change row" },
                { keys: "h   l", action: "Change pane" },
                { keys: "g   G", action: "First / last row" },
                { keys: "Shift + h  l", action: "Seek ∓ 5 s" }
            ]
        },
        {
            title: "Play",
            rows: [
                { keys: "Enter", action: "Play the artist, album or track under the caret" },
                { keys: "Space", action: "Play / pause" },
                { keys: "Shift + ← →", action: "Seek ∓ 5 s" }
            ]
        },
        {
            title: "Screens",
            rows: [
                { keys: "Alt + S", action: "Settings" },
                { keys: "Alt + T", action: "Tag editor — edit the selection's tags and cover" },
                { keys: "?", action: "This key reference" },
            ]
        }
    ]

    readonly property int keysWidth: Math.round(190 * uiScale)

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
        width: Math.min(Math.round(760 * root.uiScale), parent.width - Math.round(32 * root.uiScale))
        height: Math.min(Math.round(620 * root.uiScale), parent.height - Math.round(32 * root.uiScale))
        radius: Math.round(12 * root.uiScale)
        color: root.colBackground
        border.width: 1
        border.color: Util.alpha(root.colForeground, 0.10)

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Math.round(24 * root.uiScale)
            spacing: 0

            Text {
                text: "Keyboard"
                textFormat: Text.PlainText
                color: root.colForeground
                font.pixelSize: Math.round(Style.font.body * root.uiScale)
                font.weight: Font.Bold
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
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: contentColumn.implicitHeight
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: contentColumn
                    width: parent.width
                    spacing: 0

                    Repeater {
                        model: root.sections

                        delegate: ColumnLayout {
                            id: section
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.topMargin: Math.round(14 * root.uiScale)
                            spacing: Math.round(2 * root.uiScale)

                            Text {
                                Layout.fillWidth: true
                                text: section.modelData.title
                                textFormat: Text.PlainText
                                color: root.colMuted
                                font.pixelSize: Math.round(Style.font.bodySmall * root.uiScale)
                                font.weight: Font.Bold
                                font.letterSpacing: 0.8
                                font.capitalization: Font.AllUppercase
                                topPadding: Math.round(2 * root.uiScale)
                                bottomPadding: Math.round(2 * root.uiScale)
                            }

                            Repeater {
                                model: section.modelData.rows

                                delegate: RowLayout {
                                    id: row
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Math.round(30 * root.uiScale)
                                    spacing: Math.round(12 * root.uiScale)

                                    Text {
                                        Layout.preferredWidth: root.keysWidth
                                        text: row.modelData.keys
                                        textFormat: Text.PlainText
                                        color: root.colAccent
                                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                        font.weight: Font.Bold
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: row.modelData.action
                                        textFormat: Text.PlainText
                                        color: root.colForeground
                                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                        elide: Text.ElideRight
                                    }
                                }
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
                text: "Esc / Q / ? closes"
                textFormat: Text.PlainText
                color: root.colMuted
                font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                opacity: 0.8
            }
        }
    }
}
