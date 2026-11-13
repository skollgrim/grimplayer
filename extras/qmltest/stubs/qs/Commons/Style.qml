pragma Singleton
// Stand-in for the shell's Style singleton. GrimTheme only asks for an
// animation duration; zero turns the colour crossfades off in tests.
import QtQuick

QtObject {
    function duration(ms) {
        return 0
    }
}
