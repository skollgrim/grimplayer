pragma Singleton
// Stand-in for the shell's own Quickshell singleton.
//
// The real one belongs to the running shell and cannot be loaded by
// qmltestrunner, but the palette store only asks it where the state directory
// is. Nothing in the test writes to this path: the FileView below keeps its
// contents in memory, and the store is exercised through serialize()/load().
import QtQuick

QtObject {
    id: root

    readonly property string stateHome: "/tmp/grimplayer-qmltest-state"

    function env(name) {
        if (name === "XDG_STATE_HOME") return root.stateHome
        if (name === "HOME") return "/tmp/grimplayer-qmltest-home"
        return null
    }
}
