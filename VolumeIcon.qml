pragma ComponentBehavior: Bound
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
    // player. A TapHandler rather than a MouseArea so the glyph keeps its
    // transparency and needs no fill of its own to stay clickable.
    signal clicked()

    // Drawn size of the glyph; the 24x24 path grid is scaled to fit. The 1.6
    // factor is the transport row's, so the speaker is the same visual size as
    // the buttons beside it rather than a shade smaller.
    property int iconSize: 16
    property real uiScale: 1.0

    // The panel's colour tokens, injected. Fallbacks keep the glyph correct if
    // it is ever placed outside the panel.
    property var theme: null
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent

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

    // The colour and weight of the idle transport glyphs. The colour is
    // foreground blended most of the way to the cover accent, so the speaker
    // moves with the artwork like its neighbours -- the 0.55 blend factor is the
    // transport buttons' own, so the hue matches exactly.
    //
    // The alpha is a different number and has to track the transport's: each
    // transport glyph is drawn inside the circle Rectangle, which sits at 0.66
    // opacity when idle, so the glyph inherits that weight -- the speaker has no
    // such container and has to carry it itself. The two are deliberately the
    // same 0.66 so the speaker is neither the brightest nor the faintest thing in
    // the row. (This was 0.55 while the circle was, and was left behind when the
    // circle stepped up to 0.66, which made the speaker read as systematically
    // dimmer than the buttons beside it.) Muted uses the muted token instead of
    // the blend, but at the same weight so it does not jump out.
    readonly property color strokeColor: Util.alpha(
        muted ? root.colMuted
              : (theme ? theme.mix(root.colForeground, root.colAccent, 0.55)
                       : root.colForeground),
        hover.hovered ? 0.80 : 0.66)

    // Every Shape draws into its own 24x24 box and the box is scaled to the Item,
    // rather than letting a Shape fill the Item and having PathSvg clip the
    // 0..24 coordinates against a smaller box. That clipping is what cut the
    // outer wave and the mute cross off at the previous 20px size.
    //
    // No opacity dimming on the item itself: the weight lives in the stroke
    // colour above. The transport glyphs are drawn at full stroke colour and get
    // their weight from the circle behind them, so dimming this item instead made
    // the speaker read as a thinner, lighter-weight icon than every icon next to
    // it.
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
                // Same colour rule as the body. Hard-coding foreground for the
                // muted case would leave the cross bright while the speaker
                // dims; muted is the only case this draws in.
                strokeColor: root.strokeColor
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.glyph.cross }
            }
        }
    }

    HoverHandler { id: hover }

    TapHandler {
        cursorShape: Qt.PointingHandCursor
        onTapped: root.clicked()
    }
}
