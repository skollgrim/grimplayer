pragma Singleton
// Stand-in for the shell's Util singleton: the one helper GrimTheme uses.
import QtQuick

QtObject {
    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a)
    }
}
