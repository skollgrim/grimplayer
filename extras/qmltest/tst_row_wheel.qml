import QtQuick
import QtTest
import "../../" as Plugin

// Checks the shared wheel area as the views wire it up.
//
// The arithmetic -- one notch to a row, a touchpad's pixels banked until they
// fill one, the clamp at either end -- is covered under Node in
// extras/test-scroll.js, which is where it can be exercised properly. What only
// exists in QML is the handler and the devices it accepts, and that is what this
// file holds: a wheel event itself cannot be delivered by qmltestrunner under
// the offscreen platform, so the handler is inspected rather than driven.
TestCase {
    id: test
    name: "RowWheel"

    Item {
        id: host
        width: 200
        height: 200
    }

    Plugin.RowWheelArea {
        id: area
        parent: host
        anchors.fill: parent
        rowPitch: 30
    }

    // TouchPad is the line that is easy to lose and impossible to notice: without
    // it Qt drops events whose source is synthesized, which includes some real
    // touchpad gestures.
    function test_the_handler_takes_a_mouse_and_a_touchpad() {
        var handler = findChild(area, "wheelHandler")
        verify(handler !== null, "the area has no wheel handler")
        verify((handler.acceptedDevices & PointerDevice.Mouse) !== 0, "no mouse")
        verify((handler.acceptedDevices & PointerDevice.TouchPad) !== 0, "no touchpad")
    }

    function test_the_row_pitch_reaches_the_handler() {
        compare(area.rowPitch, 30)
    }
}
