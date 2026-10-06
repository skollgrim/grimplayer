// Transport control in the now-playing strip.
//
// The icons are drawn as vector paths rather than picked from a Unicode symbol
// or an emoji font. Both were the wrong tool here: the transport glyphs
// (U+23EE/U+23ED and friends) fall back to whatever font happens to cover the
// Private Use Area, so previous and next arrived as a chunky filled bar-and-
// triangle pair while the rest of the row came from a text face at a different
// weight. Emoji presentation made it worse -- the same codepoint renders as a
// coloured emoji on one machine and as text on the next.
//
// One family, one grid, one stroke weight. Every path below is drawn on the same
// 24x24 box with a 2px stroke, round caps and round joins, so the set reads as a
// single design rather than six borrowed symbols.
//
// Each icon is one SVG path string carrying all of its subpaths, feeding a
// single ShapePath. A Repeater would have been the obvious way to hold several
// subpaths, but Repeater delegates must be Items and ShapePath is not one -- it
// fails at runtime with "Delegate must be of Item type". Multiple move commands
// in one path string get the same result for free, since a ShapePath carries
// exactly one stroke and fill style anyway.
import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
    id: root

    property string icon: ""
    property bool prominent: false
    property bool active: false

    // A small marker naming which repeat mode is in force. Seated on the top edge of
    // the button rather than inside the glyph; see the comment at its declaration
    // for why. The convention is the familiar one: dim means off, lit means on,
    // and the dot narrows it to the single-track case.
    property bool modeDot: false

    signal clicked()

    // Item.enabled is the built-in, and setting it on the root would disable the
    // whole subtree including the handlers below, so interactivity is tracked
    // separately. Size has to be explicit as well: implicitWidth alone leaves a
    // bare Item at zero inside a RowLayout, which is what made the secondary
    // buttons render as slivers next to the prominent one.
    //
    // iconSize is the glyph's drawn size and the button is sized around it, so
    // one setting scales the whole control. The factors keep the default 16 at
    // the proportions the buttons already had (46/40 diameter, ~26px glyph).
    property int iconSize: 16
    property real uiScale: 1.0

    readonly property int glyphSize: Math.max(8, Math.round(iconSize * 1.6 * uiScale))
    readonly property int diameter: Math.max(16, Math.round(iconSize * (prominent ? 2.875 : 2.5) * uiScale))

    // implicitWidth/Height, not width/height: these buttons live in a RowLayout,
    // and a layout sizes its children from their implicit size and then
    // overwrites width/height with it. Setting width alone therefore left the
    // circle stuck at its default diameter while the glyph inside it scaled with
    // iconSize, which is what made the ring around play look unrelated to the
    // icon size slider.
    implicitWidth: diameter
    implicitHeight: diameter

    readonly property int strokeWidth: 2

    // The prominent button inverts, so its glyph has to as well. Declared on the
    // root rather than on the Shape: ShapePath is a QObject rather than an Item,
    // so `parent` does not resolve to the Shape that owns it and reads back
    // undefined.
    readonly property color glyphColor: prominent ? Color.background : (active ? Color.accent : Color.foreground)

    readonly property var glyph: ({
        // Bars sit at x=6/18 with the triangle filling the gap between them, so
        // previous and next are the same drawing mirrored rather than two
        // separate glyphs that happen to look similar.
        "previous": "M18 6 L18 18 L10 12 Z M6 6 L6 18",
        "next": "M6 6 L6 18 L14 12 Z M18 6 L18 18",
        "play": "M8.5 5.5 L18.5 12 L8.5 18.5 Z",
        // Two bars with nothing inside them, so at the shared weight this reads
        // thinner than the solid triangles beside it. Heavier by a notch, which
        // matches their optical weight without breaking the shared geometry.
        "pause": "M9 7 L9 17 M15 7 L15 17",
        // Two rails that cross in the middle, each ending in a chevron. This is
        // the shape that reads as "shuffle" at a glance; the earlier version
        // leaned on four separate arrowheads and diagonals that did not meet,
        // which at 25px came out as loose scribble rather than an icon.
        "shuffle": "M2 6 L8 6 L16 18 L22 18 M19 15 L22 18 L19 21 M2 18 L8 18 L16 6 L22 6 M19 3 L22 6 L19 9",
        "repeat": "M6.5 10.5 L6.5 9 A3.5 3.5 0 0 1 10 5.5 L17 5.5 M14 2.5 L17 5.5 L14 8.5 M17.5 13.5 L17.5 15 A3.5 3.5 0 0 1 14 18.5 L7 18.5 M10 15.5 L7 18.5 L10 21.5"
    })

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.prominent ? Color.foreground : "transparent"
        opacity: root.active ? 1.0 : (hover.hovered ? 0.72 : 0.55)
        Behavior on opacity { ColorAnimation { duration: Style.duration(90) } }

        // No ring for the secondary toggles. shuffle and repeat read as on/off through
        // the glyph itself -- accent when engaged, foreground when not -- so the
        // circle that used to wrap them was a third thing to look at, and it was
        // the only cue distinguishing those two buttons from prev/next.
        //
        // The paths are authored on a 24x24 grid in the Shape's own coordinates,
        // and PathSvg does not scale them to the Shape's box, so the box stays
        // 24x24 and is scaled to the glyph size: the artwork fills it exactly and
        // stays centred at any icon size.
        Item {
            anchors.centerIn: parent
            width: 24
            height: 24
            scale: root.glyphSize / 24

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: root.glyphColor
                    strokeWidth: root.icon === "pause" ? root.strokeWidth * 1.3 : root.strokeWidth
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin

                    PathSvg { path: root.glyph[root.icon] || "" }
                }
            }
        }
    }

    // Mode marker, as a filled dot rather than a stroked path: at this size a 2px
    // stroke on a tiny circle closes up into a blob anyway, and a plain rectangle
    // is honest about what it is drawing.
    //
    // It sits on the top edge of the button rather than inside the glyph. The
    // repeat path already runs its top rail and arrowhead through the middle of
    // the box, so a dot placed there overlapped the stroke and read as a smudge
    // rather than a marker -- and being a child of the button's Rectangle, it
    // inherited that Rectangle's 0.55 resting opacity, so at rest the dot was
    // barely distinguishable from the dimmed glyph it was supposed to annotate.
    // Both problems are solved by the same move: outside the glyph box it has
    // clear background, and outside the opacity Rectangle it is drawn at full
    // strength whether the button is engaged or not.
    Rectangle {
        visible: root.modeDot
        anchors.horizontalCenter: parent.horizontalCenter
        // Seated on the top edge, so it reads as a badge on the button. The glyph
        // box is inset by half the difference between the circle and the glyph,
        // and the glyph's own topmost stroke is a little below that, so the dot
        // clears the artwork at every icon size.
        y: 0
        width: Math.max(3, Math.round(4 * root.uiScale))
        height: width
        radius: width / 2
        color: root.active ? Color.accent : Color.foreground
    }

    HoverHandler { id: hover }
    TapHandler { onTapped: root.clicked() }
}
