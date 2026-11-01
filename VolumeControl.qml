pragma ComponentBehavior: Bound
// The volume glyph and its slider, as one control.
//
// Same reason as TransportRow: the panel places the playback controls in two
// different arrangements now (the thin strip and the cover band) and this is the
// one definition both use. It reports the level it came from when dragged off
// zero -- the panel remembers that for its mute model -- and asks the panel to
// handle the mute tap, since mute is modelled at the panel level (MPD has no mute
// command).
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons

RowLayout {
    id: root

    property var mpd: null
    property var theme: null
    property int iconSize: 16
    property int sliderWidth: 120
    property real uiScale: 1.0

    signal muteToggled()
    signal audibleVolumeChanged(real volume)

    // A drag moves the slider through every step between the two ends, and
    // sending one `setvol` per step would put a hundred commands and a hundred
    // mixer events on the wire for one gesture. The handle already follows the
    // pointer locally, so only the latest value is sent, coalesced into one
    // command per 60ms, with the final value flushed on release.
    property int pendingVolume: -1
    function flushVolume() {
        volumeSend.stop()
        if (root.pendingVolume < 0) return
        var value = root.pendingVolume
        root.pendingVolume = -1
        if (root.mpd) root.mpd.setVolume(value)
    }
    Timer {
        id: volumeSend
        interval: 60
        repeat: false
        onTriggered: root.flushVolume()
    }

    // Fallbacks keep the control correct if it is ever placed outside the panel,
    // the same way the glyph and the transport buttons carry theirs.
    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colAccent: theme ? theme.accent : Color.accent

    spacing: Math.round(8 * uiScale)

    VolumeIcon {
        theme: root.theme
        iconSize: root.iconSize
        uiScale: root.uiScale
        level: root.mpd && root.mpd.status && root.mpd.status.volume !== undefined
            ? root.mpd.status.volume : 0
        onClicked: root.muteToggled()
    }

    // Themed rather than left on Qt's default Basic style: the stock slider comes
    // out in the platform's own greys and ignores the theme entirely, which is why
    // it was the one control in the panel that never changed with the rest. Track,
    // fill and handle are drawn from the same tokens as the seek bar, so the two
    // read as one pair.
    Slider {
        id: volumeSlider
        Layout.preferredWidth: Math.round(root.sliderWidth * root.uiScale)
        implicitHeight: Math.round(22 * root.uiScale)
        from: 0
        to: 100
        stepSize: 1

        // The level MPD last reported, kept apart from the slider's own value
        // rather than bound to it: a drag is echoed back one round trip later over
        // `idle mixer`, so a binding would pull the handle out from under the
        // pointer half way through the press. The echo is adopted whenever the
        // handle is not held.
        readonly property real reported: root.mpd && root.mpd.status
            && root.mpd.status.volume !== undefined ? root.mpd.status.volume : 0
        property bool dragging: false

        onReportedChanged: if (!dragging) value = reported
        onPressedChanged: {
            dragging = pressed
            if (!pressed) root.flushVolume()
        }

        // Dragging the slider to zero is also a mute, so it has to record the
        // level it came from or the icon click would have nothing to restore.
        onMoved: {
            if (value > 0) root.audibleVolumeChanged(value)
            root.pendingVolume = value
            if (!volumeSend.running) volumeSend.start()
        }

        Component.onCompleted: value = reported

        background: Rectangle {
            x: volumeSlider.leftPadding
            y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
            width: volumeSlider.availableWidth
            height: Math.max(2, Math.round(4 * root.uiScale))
            radius: height / 2
            color: Util.alpha(root.colForeground, 0.12)

            Rectangle {
                width: parent.width * volumeSlider.visualPosition
                height: parent.height
                radius: parent.radius
                color: root.colAccent
            }
        }

        handle: Rectangle {
            x: volumeSlider.leftPadding
                + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
            y: volumeSlider.topPadding + (volumeSlider.availableHeight - height) / 2
            width: Math.round(13 * root.uiScale)
            height: width
            radius: width / 2
            color: root.colForeground
            border.width: 2
            border.color: root.colBackground
            // Idle handle would sit as a permanent dot on the track; the transport
            // buttons behave the same way, showing their affordance only on hover
            // or press.
            visible: volumeSlider.pressed || volumeSlider.hovered
        }
    }
}
