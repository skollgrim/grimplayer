// Volume glyph for the now-playing strip.
//
// Same reason as TransportButton: the speaker was a 🔊 emoji, which renders as a
// coloured glyph under some font configurations and as a text glyph under others,
// and it had no way to show volume at all. Drawn from the same 24x24 grid and 2px
// stroke as the transport row, with the speaker body fixed and only the waves
// changing, so it reads as one set with its neighbours.
//
// One ShapePath per state, carrying every subpath as extra move commands. A
// Repeater cannot be used here: its delegates must be Items, and ShapePath is
// not one.
import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
    id: root

    property int level: 0

    // The speaker doubles as the mute switch, the way it does in every other
    // player. TappingHandler rather than a MouseArea so the glyph keeps its
    // transparency and needs no fill of its own to stay clickable.
    signal clicked()

    // Drawn size of the glyph; the 24x24 path grid is scaled to fit. The 1.6
    // factor is the transport row's, so the speaker is the same visual size as
    // the buttons beside it rather than a shade smaller.
    property int iconSize: 16
    property real uiScale: 1.0

    readonly property bool muted: level <= 0
    readonly property bool loud: level > 66

    implicitWidth: Math.round(iconSize * 1.6 * uiScale)
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight

    readonly property var glyph: ({
        // Body and driver, identical in every state.
        "body": "M4 9.5 L7.5 9.5 L12 5.5 L12 18.5 L7.5 14.5 L4 14.5 Z",
        "waveLow": "M15 9.5 A4 4 0 0 1 15 14.5",
        "waveHigh": "M17.5 7 A7.5 7.5 0 0 1 17.5 17",
        // A slash through the waves rather than a change of body shape, so the
        // icon keeps its silhouette and only the level readout changes.
        "cross": "M15.5 9.5 L20.5 14.5 M20.5 9.5 L15.5 14.5"
    })

    // Same hue as the transport glyphs -- Color.foreground, not a second grey --
    // but held at the 0.55 their idle circles use. Full-strength foreground with
    // no shape behind it left the speaker reading as the brightest thing in the
    // strip; dimming the same colour matches the perceived weight of its
    // neighbours without introducing a second foreground tone.
    readonly property color strokeColor: muted ? Color.muted : Util.alpha(Color.foreground, 0.55)

    // Every Shape draws into its own 24x24 box and the box is scaled to the Item,
    // rather than letting a Shape fill the Item and having PathSvg clip the
    // 0..24 coordinates against a smaller box. That clipping is what cut the
    // outer wave and the mute cross off at the previous 20px size.
    //
    // No opacity dimming on the item itself. The transport glyphs are drawn at
    // full stroke colour and get their weight from the circle behind them, so a
    // 0.55 fade here made the speaker read as a thinner, lighter-weight icon
    // than every icon next to it.
    Item {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: root.width / 24

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: root.strokeColor
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.glyph.body }
            }
        }

        // The waves, drawn as a second layer so the level can change without
        // redrawing the body. One wave at any volume, a second only once it is
        // genuinely loud -- the count is the level readout, since the strip has no
        // numeric volume display.
        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            visible: !root.muted

            ShapePath {
                strokeColor: root.strokeColor
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg {
                    path: root.loud
                        ? root.glyph.waveLow + " " + root.glyph.waveHigh
                        : root.glyph.waveLow
                }
            }
        }

        Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            visible: root.muted

            ShapePath {
                // Same colour rule as the body. This used to hard-code foreground
                // for the muted case, which is the only case it ever draws in, so
                // the cross stayed bright while the speaker dimmed.
                strokeColor: root.strokeColor
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.glyph.cross }
            }
        }
    }

    TapHandler {
        onTapped: root.clicked()
    }
}
