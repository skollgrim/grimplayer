pragma Singleton
// Stand-in for the shell's Style singleton. GrimTheme asks for an animation
// duration, and the settings card reads the font scale through `themeFont`;
// zero turns the colour crossfades off in tests. The font tokens only need to
// exist -- their values are not asserted, but a missing one throws while the
// card binds its rows.
import QtQuick

QtObject {
    readonly property color selectedFill: "#282738"

    readonly property var font: ({
        family: "sans-serif",
        title: 22,
        subtitle: 16,
        body: 13,
        bodySmall: 12,
        caption: 11
    })

    function duration(ms) {
        return 0
    }
}
