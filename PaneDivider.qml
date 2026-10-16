pragma ComponentBehavior: Bound
// Vertical divider between two panes.
//
// A good idea here, for one reason: without it the three panes are three
// near-identical dark rectangles butted together with no gaps, so the only thing
// telling you where one list ends and the next begins is the header text. That
// makes the tracks list look like it continues the albums list, which is exactly
// the confusion the three-pane layout exists to remove.
//
// It is kept thin, and takes its colour from the active theme rather than a
// hardcoded white: an 8% white rule is invisible on the light themes, where the
// pane background is already near-white. The panel hands it the theme's
// foreground at low opacity -- the same token the pane heading underlines use --
// so on a light theme it reads as a faint dark rule and on a dark one as a faint
// light rule, which is the whole job. A heavier or higher-contrast rule would
// compete with the selected-row highlight, and that highlight is what should be
// the loudest line on screen. The thickness is the borderWidth preference, shared
// with the pane outline, the heading underlines and the rule above the now playing
// strip.
//
// Named PaneDivider rather than Separator because QtQuick.Controls exports a
// Separator of its own, and the collision made the component fail to resolve.
// It is also deliberately not setting any Layout attached properties: this file
// does not import QtQuick.Layouts, and PaneRow positions these as anchored
// siblings rather than laying them out. Attached properties are resolved in the
// scope of the file that writes them, so declaring them here fails with
// "Non-existent attached object".
import QtQuick

Rectangle {
    property int thickness: 1

    // Injected by PaneRow from the panel's theme. The default keeps the divider
    // legible if this file is ever placed on its own against a dark background.
    property color ruleColor: Qt.rgba(1, 1, 1, 0.08)

    // A sensible size when nothing overrides it. PaneRow sets width explicitly
    // from the same thickness, because a rule anchored to a pane boundary only
    // lines up if nothing downstream resizes it.
    implicitWidth: thickness
    implicitHeight: 1

    color: ruleColor
}
