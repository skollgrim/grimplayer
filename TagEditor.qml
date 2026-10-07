// Tag editor, modal over the browser.
//
// Editing is per-selection: the panel hands over the songs the caret covers, and
// every field shows what those songs agree on. A field the selection disagrees
// about reads "multiple" and is left alone unless it is touched -- editing the
// title of a whole album sets the same title on every track, and leaving it
// alone keeps each track's own.
//
// The distinction between "agreed and empty" and "disagreed" is the whole reason
// this is not just a form. An album where every track has no genre should be
// offered an empty genre field to fill in, not one reading "multiple"; an album
// where every track has a different title should not be offered track one's
// title as if it were the album's.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

Item {
    id: root

    property var mpd: null
    // The panel owns the selection; this only reads it.
    property var songs: []
    property real uiScale: 1.0

    signal dismissed()

    // ---- the fields ----
    //
    // The key is both the name on a song object and the tag this maps to; the
    // panel and the service agree on those names. Order is the reading order:
    // what a track is, then what it is on, then where it sits.
    readonly property var fields: [
        { key: "title", label: "Title" },
        { key: "artist", label: "Artist" },
        { key: "albumArtist", label: "Album artist" },
        { key: "album", label: "Album" },
        { key: "track", label: "Track" },
        { key: "disc", label: "Disc" },
        { key: "date", label: "Year" },
        { key: "genre", label: "Genre" },
        { key: "country", label: "Country" }
    ]

    // What the selection agrees on per field, or "" when they agree on nothing.
    // null means disagreement, which is a different answer from an empty value
    // and the reason this is a null check rather than a truthiness one.
    property var agreed: ({})

    // Fields the user has actually edited. A field left alone is not written, so
    // opening the editor on an album and changing one tag cannot quietly blank
    // the other seven.
    property var touched: ({})

    property int rowIndex: 0
    property string status: ""
    property bool busy: false

    // Every map here is rebuilt and reassigned rather than modified in place. A var
    // property holding a JS object does not report a change when a key is added to
    // it, so an in-place edit updates what a direct read returns while leaving
    // every binding that depends on it showing the values from before the edit.
    function load() {
        var agreed = {}
        for (var f = 0; f < root.fields.length; f++) {
            agreed[root.fields[f].key] = root.commonValue(root.fields[f].key)
        }
        root.agreed = agreed
        root.touched = {}
        root.draft = {}
        root.rowIndex = 0
        root.status = ""
        root.busy = false
        Qt.callLater(root.focusRow)
    }

    // Where a song's current value for a field comes from. Every tag but country is
    // something MPD reports and so is already on the song object. Country is not
    // in MPD's song model at all, so it is asked of the service, which keeps what
    // it found the last time it looked.
    function valueOf(song, key) {
        if (key === "country") {
            return root.mpd ? root.mpd.countryForDir(root.mpd.albumDirOf(song.file)) : ""
        }
        var raw = song[key]
        return raw === undefined || raw === null ? "" : String(raw).trim()
    }

    // Whitespace inside a subdivision code, as in "GB - SCT", is dropped before
    // it is stored so the flag and the tag agree on one spelling.
    function tidyCode(text) {
        return String(text === undefined || text === null ? "" : text)
            .trim().replace(/\s+/g, "").toUpperCase()
    }

    function commonValue(key) {
        var first = null
        for (var i = 0; i < root.songs.length; i++) {
            var value = root.valueOf(root.songs[i], key)
            if (i === 0) {
                first = value
                continue
            }
            if (value !== first) return null
        }
        return first === null ? "" : first
    }

    function isMixed(key) {
        return root.agreed[key] === null
    }

    // The flag for whatever the country field currently holds, agreed value or
    // fresh typing. Empty when what is in there is not a code.
    function flagPreview(key) {
        if (key !== "country") return ""
        return root.mpd ? root.mpd.flagEmoji(root.currentText(key)) : ""
    }

    function currentText(key) {
        // Untouched and mixed reads as empty, which is also what the user sees:
        // the "multiple" placeholder is the field saying so, not a value.
        if (root.touched[key]) return root.draft[key] === undefined ? "" : root.draft[key]
        var agreed = root.agreed[key]
        if (agreed === undefined) return ""
        return agreed === null ? "" : agreed
    }

    property var draft: ({})

    // Opening is what loads it, rather than the panel reaching in afterwards. The
    // two are set in the same tick, so `songs` is already in place by the time
    // this fires, and there is no window where the card is up showing fields that
    // have not been worked out yet.
    onVisibleChanged: if (visible && root.songs.length > 0) root.load()

    Component.onCompleted: if (visible && root.songs.length > 0) root.load()

    function setText(key, text) {
        var d = {}
        for (var k in root.draft) d[k] = root.draft[k]
        d[key] = key === "country" ? root.tidyCode(text) : text
        root.draft = d
        var t = {}
        for (var k2 in root.touched) t[k2] = root.touched[k2]
        t[key] = true
        root.touched = t
    }

    // The Save button is the last stop in the focus cycle, past the final field,
    // so rowIndex counts one past the fields rather than being a second cursor.
    // That keeps the wrap arithmetic in one place: there are fields + 1 stops, and
    // every key that moves a row just adds to the index and lets moveRow fold it.
    function saveStop() {
        return root.fields.length
    }

    // Focus goes to the text field inside the row rather than the row itself. The
    // row is a plain layout item, so focusing it takes the keyboard without a
    // caret in front of it -- which reads as "the fields are not editable" until
    // you click one.
    function focusRow() {
        if (root.rowIndex === root.saveStop()) {
            saveButton.forceActiveFocus()
            return
        }
        var rows = fieldColumn.children
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].fieldKey !== undefined && rows[i].fieldKey === root.fields[root.rowIndex].key) {
                rows[i].focusField()
                return
            }
        }
    }

    function moveRow(delta) {
        var n = root.saveStop() + 1
        root.rowIndex = ((root.rowIndex + delta) % n + n) % n
        root.focusRow()
    }

    // Tab out of the modal would otherwise walk focus into the panel underneath,
    // so the cycle is ours and Tab joins the arrows rather than escaping it.
    function onSaveKey(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.save()
            event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            root.dismissed()
            event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down
                || event.key === Qt.Key_Up) {
            root.moveRow(event.key === Qt.Key_Up || (event.key === Qt.Key_Tab
                && (event.modifiers & Qt.ShiftModifier)) ? -1 : 1)
            event.accepted = true
        }
    }

    function scopeText() {
        if (root.songs.length === 0) return "Nothing selected"
        if (root.songs.length === 1) return "1 track"
        return root.songs.length + " tracks"
    }

    function save() {
        if (root.busy) return
        var tags = {}
        var any = false
        for (var f = 0; f < root.fields.length; f++) {
            var key = root.fields[f].key
            if (!root.touched[key]) continue
            tags[key] = root.draft[key] === undefined ? "" : String(root.draft[key]).trim()
            any = true
        }
        if (!any) {
            root.status = "Nothing changed"
            return
        }
        var files = []
        for (var s = 0; s < root.songs.length; s++) files.push(root.songs[s])
        root.busy = true
        root.status = "Writing…"
        root.mpd.applyTags(files, tags, function (result) {
            root.busy = false
            var parts = []
            if (result.written > 0) parts.push(result.written + " updated")
            if (result.failed > 0) parts.push(result.failed + " failed")
            if (result.skipped > 0) parts.push(result.skipped + " skipped")
            root.status = parts.length > 0 ? parts.join(" · ") : "Nothing changed"
            // Everything the user just typed has been dealt with, so the draft is
            // no longer pending. Clearing `touched` is what stops the next open
            // from offering the previous edit's values as if they were agreed on.
            root.touched = {}
            root.draft = {}
            root.refreshAgreed()
        })
    }

    function refreshAgreed() {
        var a = {}
        for (var f = 0; f < root.fields.length; f++) {
            a[root.fields[f].key] = root.commonValue(root.fields[f].key)
        }
        root.agreed = a
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        MouseArea {
            anchors.fill: parent
            onClicked: if (!root.busy) root.dismissed()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.round(620 * root.uiScale)
        height: Math.round(552 * root.uiScale)
        radius: Math.round(12 * root.uiScale)
        color: Color.background
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.10)

        // Keys reach the card rather than the browser underneath, and the panel's
        // own key catcher is stood down while this is up for the same reason: a
        // j typed into the genre field must not move the caret.
        focus: true
        Keys.onPressed: function (event) {
            if (root.busy) {
                if (event.key === Qt.Key_Escape) root.dismissed()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
                root.dismissed()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.save()
                event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
                root.moveRow(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                root.moveRow(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                root.moveRow(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_G && (event.modifiers & Qt.ShiftModifier)) {
                root.moveRow(root.rowIndex === 0 ? root.fields.length - 1 : -1)
                event.accepted = true
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Math.round(24 * root.uiScale)
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(10 * root.uiScale)

                Text {
                    text: "Edit tags"
                    color: Color.foreground
                    font.pixelSize: Math.round(Style.font.subtitle * root.uiScale)
                    font.weight: Font.DemiBold
                    font.family: Style.font.family
                }

                Rectangle {
                    width: scopeLabel.implicitWidth + Math.round(16 * root.uiScale)
                    height: Math.round(20 * root.uiScale)
                    radius: height / 2
                    color: Util.alpha(Color.accent, 0.14)

                    Text {
                        id: scopeLabel
                        anchors.centerIn: parent
                        text: root.scopeText()
                        color: Color.accent
                        font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                        font.family: Style.font.family
                    }
                }

                Item { Layout.fillWidth: true }
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(6 * root.uiScale)
                text: "Fields the tracks disagree on read “multiple” and are left alone unless you change them. Country takes a two-letter code, and the flag beside it is the one the now-playing strip will show — use GB-ENG, GB-SCT or GB-WLS for the UK home nations."
                color: Util.alpha(Color.muted, 1.0)
                wrapMode: Text.WordWrap
                font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                font.family: Style.font.family
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(14 * root.uiScale)
                Layout.bottomMargin: Math.round(10 * root.uiScale)
                height: 1
                color: Qt.rgba(1, 1, 1, 0.08)
            }

            ColumnLayout {
                id: fieldColumn
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Repeater {
                    model: root.fields

                    delegate: RowLayout {
                        id: row
                        required property var modelData
                        required property int index

                        readonly property string fieldKey: modelData.key
                        readonly property bool focused: root.rowIndex === index

                        // Handed to the panel's focus walk, which only knows how to
                        // address a row and not what is inside it.
                        function focusField() { input.forceActiveFocus() }

                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(34 * root.uiScale)
                        spacing: Math.round(12 * root.uiScale)

                        Text {
                            Layout.preferredWidth: Math.round(130 * root.uiScale)
                            text: row.modelData.label
                            color: row.focused ? Color.foreground
                                                 : Util.alpha(Color.muted, 1.0)
                            font.pixelSize: Math.round(Style.font.body * root.uiScale)
                            font.family: Style.font.family
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.round(28 * root.uiScale)

                            TextField {
                                id: input
                                anchors.fill: parent
                                text: root.currentText(row.modelData.key)
                                // Only offered when the selection disagrees. A field
                                // the tracks all left empty stays empty and reads as
                                // empty, which is a different offer than "we differ".
                                placeholderText: root.isMixed(row.modelData.key) ? "multiple" : ""
                                placeholderTextColor: Util.alpha(Color.accent, 0.75)
                                color: Color.foreground
                                font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                font.family: Style.font.family
                                selectByMouse: true
                                // The flag stands in for the field while typing so
                                // there is room for it, rather than overlapping the
                                // caret on whatever the user has typed.
                                rightPadding: row.modelData.key === "country"
                                    ? Math.round(34 * root.uiScale) : 0

                                background: Rectangle {
                                    radius: Math.round(6 * root.uiScale)
                                    color: Util.alpha(Color.foreground, row.focused ? 0.10 : 0.05)
                                    border.width: 1
                                    border.color: row.focused
                                        ? Util.alpha(Color.accent, 0.7)
                                        : Util.alpha(Color.foreground, 0.12)
                                }

                                onTextEdited: root.setText(row.modelData.key, text)
                                onActiveFocusChanged: {
                                    if (activeFocus) root.rowIndex = row.index
                                }

                                // A focused text field eats arrows for caret movement
                                // and Tab for focus traversal, which would strand the
                                // keyboard in whichever field you happened to click.
                                // Taking them here is what makes the up/down and Tab
                                // in the card's handler reachable once a field has
                                // focus -- the card never sees an event its focused
                                // child already accepted.
                                Keys.onPressed: function (event) {
                                    if (event.key === Qt.Key_Up) {
                                        root.moveRow(-1)
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Down) {
                                        root.moveRow(1)
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Tab) {
                                        root.moveRow(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Return
                                            || event.key === Qt.Key_Enter) {
                                        // A focused field would otherwise insert
                                        // nothing and swallow the save.
                                        root.save()
                                        event.accepted = true
                                    } else if (event.key === Qt.Key_Escape) {
                                        root.dismissed()
                                        event.accepted = true
                                    }
                                }
                            }

                            // The country tag holds an ISO 3166-1 alpha-2 code, and
                            // the flag in the now-playing strip is derived from
                            // exactly those two characters -- so the flag shown here
                            // is what that strip will show. Appearing as the code is
                            // typed is also the only hint that a code is wanted: a
                            // country name has no way back to a code.
                            Text {
                                visible: row.modelData.key === "country"
                                    && root.flagPreview(row.modelData.key) !== ""
                                anchors.right: parent.right
                                anchors.rightMargin: Math.round(8 * root.uiScale)
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.flagPreview(row.modelData.key)
                                font.pixelSize: Math.round(16 * root.uiScale)
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(10 * root.uiScale)
                Layout.bottomMargin: Math.round(8 * root.uiScale)
                height: 1
                color: Qt.rgba(1, 1, 1, 0.08)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(10 * root.uiScale)

                Text {
                    Layout.fillWidth: true
                    text: root.status !== "" ? root.status
                        : "Enter saves · Esc cancels · Tab cycles fields and Save"
                    color: root.status === "" ? Util.alpha(Color.muted, 1.0)
                                               : Util.alpha(Color.accent, 1.0)
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                    font.family: Style.font.family
                }

                Rectangle {
                    id: saveButton
                    width: saveLabel.implicitWidth + Math.round(28 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: saveMouse.containsMouse || root.busy || activeFocus
                        ? Util.alpha(Color.accent, 0.26)
                        : Util.alpha(Color.accent, 0.16)

                    // Same affordance the focused field rows use, so landing on the
                    // button from the last field reads as focus having moved rather
                    // than as the editor having lost the caret.
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(Color.accent, 0.7)

                    // Ours, not the focus traversal's: Tab past the last field must
                    // come here rather than leave the modal for the panel under it.
                    activeFocusOnTab: false
                    Keys.onPressed: root.onSaveKey

                    Text {
                        id: saveLabel
                        anchors.centerIn: parent
                        text: root.busy ? "Writing…" : "Save"
                        color: Color.foreground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: saveMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.save()
                    }
                }
            }
        }
    }
}
