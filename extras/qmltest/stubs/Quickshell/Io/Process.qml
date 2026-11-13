// Stand-in for Quickshell's Process.
//
// The only process the palette store starts is `mkdir -p`, and all it needs
// back is "the directory exists now". This reports success synchronously when
// the store turns it on, so the store's own Component.onCompleted sees
// stateDirReady already true and writes are not blocked in the test.
import QtQuick

Item {
    id: root

    property bool running: false
    property var command: []

    signal exited(int exitCode, int exitStatus)

    Component.onCompleted: {
        if (root.running) root.finish()
    }

    function finish() {
        root.running = false
        root.exited(0, 0)
    }
}
