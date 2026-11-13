// Stand-in for Quickshell's FileView.
//
// It keeps the last text in memory instead of touching the disk, so a test run
// cannot overwrite the user's real palettes.json. The members below are the
// ones GrimPaletteStore.qml binds to; `content` and `writeCount` are the writes
// the test observes. `blockWrites` is honoured so the "directory not ready yet"
// case behaves the way the real FileView does -- a write that arrives too early
// is dropped rather than replayed.
import QtQuick

Item {
    id: root

    property string path: ""
    property bool blockLoading: false
    property bool blockWrites: false
    property bool watchChanges: false
    property bool printErrors: false
    property bool atomicWrites: false

    property string content: ""
    property int writeCount: 0

    function text() {
        return root.content
    }

    function setText(value) {
        root.writeCount++
        if (root.blockWrites) return
        root.content = value
    }
}
