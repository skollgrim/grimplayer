// Vertical divider between two panes.
//
// A good idea here, for one reason: without it the three panes are three
// near-identical dark rectangles butted together with no gaps, so the only thing
// telling you where one list ends and the next begins is the header text. That
// makes the tracks list look like it continues the albums list, which is exactly
// the confusion the three-pane layout exists to remove.
//
// It is kept thin at the same 8% white the pane headers already use for their own
// underline. A heavier or higher-contrast rule would compete with the selected-row
// highlight, and that highlight is what should be the loudest line on screen.
// The thickness is the borderWidth preference, shared with the pane
// outline, the heading underlines and the rule above the now playing strip.
//
// Named PaneDivider rather than Separator because QtQuick.Controls exports a
// Separator of its own, and the collision made the component fail to resolve.
// It is also deliberately not setting any Layout attached properties: this file
// does not import QtQuick.Layouts, and the other pane components take theirs from
// the scope in GrimPlayer.qml that places them. Attached properties are resolved in
// the scope of the file that writes them, so declaring them here fails with
// "Non-existent attached object".
import QtQuick

Rectangle {
    property int thickness: 1

    // implicitWidth, not width. These sit in a RowLayout, and a layout sizes its
    // children from their implicit size and then overwrites width with it -- so an
    // explicit width binding here was being thrown away and each divider ended up
    // with whatever the layout had left rather than the thickness both of them
    // were handed, which is how the two of them came out different widths.
    implicitWidth: thickness
    implicitHeight: 1

    color: Qt.rgba(1, 1, 1, 0.08)
}
