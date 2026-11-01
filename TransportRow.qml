pragma ComponentBehavior: Bound
// The five transport buttons, as one row.
//
// Lifted out of the panel so the two now-playing layouts can share a single
// definition: the thin strip lays the panel out one way and the cover band
// another, and the alternative was five buttons with their bindings duplicated in
// both. The buttons read their engaged state straight from the service and call
// its methods, so the row needs the service and nothing else wired in.
import QtQuick
import QtQuick.Layouts

RowLayout {
    id: root

    property var mpd: null
    property var theme: null
    property int iconSize: 16
    property real uiScale: 1.0

    spacing: Math.round(6 * uiScale)

    TransportButton {
        icon: "shuffle"
        theme: root.theme
        iconSize: root.iconSize
        uiScale: root.uiScale
        // Four scopes, cycled off -> album -> artist -> library. Lit for all
        // three shuffled scopes, with a badge above naming the pool: "Alb" the
        // playing album, "Art" the artist, "Lib" the whole library. Three
        // letters each, so the badge is a word rather than a puzzle to decode
        // and the three scopes stay the same width above the button.
        active: !!(root.mpd && root.mpd.shuffleMode > 0)
        modeBadge: root.mpd && root.mpd.shuffleMode === 1 ? "Alb"
                 : root.mpd && root.mpd.shuffleMode === 2 ? "Art"
                 : root.mpd && root.mpd.shuffleMode === 3 ? "Lib" : ""
        onClicked: root.mpd && root.mpd.cycleShuffleMode()
    }
    TransportButton {
        icon: "previous"
        theme: root.theme
        iconSize: root.iconSize
        uiScale: root.uiScale
        onClicked: root.mpd && root.mpd.command("previous")
    }
    TransportButton {
        icon: root.mpd && root.mpd.status && root.mpd.status.state === "play" ? "pause" : "play"
        prominent: true
        theme: root.theme
        iconSize: root.iconSize
        uiScale: root.uiScale
        onClicked: root.mpd && root.mpd.togglePlay()
    }
    TransportButton {
        icon: "next"
        theme: root.theme
        iconSize: root.iconSize
        uiScale: root.uiScale
        onClicked: root.mpd && root.mpd.command("next")
    }
    TransportButton {
        icon: "repeat"
        theme: root.theme
        iconSize: root.iconSize
        uiScale: root.uiScale
        // Three modes, cycled off -> repeat album -> repeat song. Lit for both
        // repeat modes, with a letter above naming which: "A" the album and "S"
        // the single track.
        active: root.mpd && root.mpd.repeatMode > 0
        modeBadge: root.mpd && root.mpd.repeatMode === 1 ? "A"
                 : root.mpd && root.mpd.repeatMode === 2 ? "S" : ""
        onClicked: root.mpd && root.mpd.cycleRepeatMode()
    }
}
