pragma Singleton
// Stand-in for the shell's Color singleton: just the tokens GrimTheme reads.
// The values are Catppuccin dark, so a test can tell "the theme" apart from any
// palette derived from a cover.
import QtQuick

QtObject {
    property color background: "#181825"
    property color foreground: "#cdd6f4"
    property color muted: "#a6adc8"
    property color accent: "#89b4fa"
    property color urgent: "#f38ba8"
}
