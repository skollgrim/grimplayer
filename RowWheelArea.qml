// Wheel input that steps whole rows, for a list drawn as a Flickable.
//
// A handler on the Flickable itself never sees events aimed at the row under the
// pointer, so this empty item sits above the list. It has no mouse handling of
// its own, so clicks and hover still reach the rows below; all it does is turn a
// wheel event into rows.
//
// The rule -- one notch is one row, a touchpad's pixels are banked until they
// add up to one -- and the clamping live in Scroll.js, shared with the panels
// that scroll the same way. This file keeps only the bank between events.
import QtQuick
import "Scroll.js" as Scroll

Item {
    id: root

    // One row's height, gap included: a step lands on the next row.
    property real rowPitch: 1

    // How far to scroll, in rows; positive is down. The view decides what that
    // means for its own content.
    signal scrolled(int rows)

    WheelHandler {
        objectName: "wheelHandler"
        // TouchPad is listed explicitly: without it Qt drops wheel events whose
        // source is synthesized rather than a physical mouse, which also drops
        // some real touchpad gestures.
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

        // The pixels of a touchpad gesture that have not added up to a row yet.
        property real banked: 0

        onWheel: function (event) {
            var step = Scroll.wheelStep(event.pixelDelta.y, event.angleDelta.y,
                root.rowPitch, banked)
            banked = step.banked
            if (step.rows !== 0) root.scrolled(step.rows)
            // Taken either way: a delta that did not fill a row has been banked
            // and must not also reach a Flickable underneath.
            event.accepted = true
        }
    }
}
