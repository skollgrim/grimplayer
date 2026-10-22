pragma ComponentBehavior: Bound
// The progress bar, as one control.
//
// Same reason as TransportRow and VolumeControl: the panel places the seek bar
// in two different arrangements now (inline in the thin strip's column, and
// stretched edge to edge under the cover band) and this is the one definition
// both use. It owns no state of its own -- it draws whatever progress it is
// handed and reports the fraction a drag lands on -- so the panel keeps its
// scrub-then-release model (one MPD command per drag instead of one per pixel)
// and both placements behave identically.
import QtQuick
import qs.Commons

Item {
    id: root

    property var theme: null
    property real uiScale: 1.0
    // 0..1. Where the fill should sit, from the panel's own elapsed/duration.
    property real progress: 0
    // Seconds. Zero (nothing playing, or an unknown length) disables scrubbing,
    // so a drag on a dead bar does nothing rather than seeking to zero.
    property real duration: 0
    property real thickness: 3

    // The fraction the user dropped the handle on. The panel decides what to do
    // with it, so the release path stays in one place.
    signal seekRequested(real fraction)

    // While dragging, preview the position under the pointer rather than the
    // progress coming back from the service, which would lag a round trip behind
    // and yank the fill out from under the drag.
    readonly property real shown: seekArea.pressed
        ? seekArea.scrubFraction
        : Math.max(0, Math.min(1, progress))

    // The bar's slot. The thickness sets it once the bar is thick enough to
    // need the room: a thick bar keeps a couple of pixels of air above and
    // below so it never crowds the elapsed time above it, while the thin rungs
    // still sit in the original 14px slot rather than shrinking it.
    implicitHeight: Math.max(Math.round(14 * uiScale), root.thickness + Math.round(4 * uiScale))

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: root.thickness
        radius: root.thickness / 2
        color: root.theme ? Util.alpha(root.theme.foreground, 0.14) : Util.alpha(Color.foreground, 0.14)
    }
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width * root.shown
        height: root.thickness
        radius: root.thickness / 2
        color: root.theme ? root.theme.accent : Color.accent
    }

    // Handle, shown on hover or while dragging, so the bar reads as draggable
    // rather than as a progress display.
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: seekArea.containsMouse || seekArea.pressed
        width: Math.round(11 * root.uiScale)
        height: Math.round(11 * root.uiScale)
        radius: Math.round(5.5 * root.uiScale)
        color: root.theme ? root.theme.accent : Color.accent
        x: Math.max(0, Math.min(root.width - width,
            root.width * root.shown - width / 2))
    }

    MouseArea {
        id: seekArea
        anchors.fill: parent
        enabled: root.duration > 0
        hoverEnabled: true

        property real scrubFraction: 0

        function fractionAt(x) {
            return Math.max(0, Math.min(1, x / Math.max(1, root.width)))
        }

        onPressed: function (mouse) { scrubFraction = fractionAt(mouse.x) }
        onPositionChanged: function (mouse) {
            if (pressed) scrubFraction = fractionAt(mouse.x)
        }
        onReleased: function (mouse) {
            root.seekRequested(fractionAt(mouse.x))
        }
        onCanceled: scrubFraction = root.shown
    }
}
