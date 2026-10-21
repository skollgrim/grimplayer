pragma ComponentBehavior: Bound
// GrimPlayer panel: the MPD media-library browser.
//
// An ordinary resizable window. It asks the compositor for no placement at all:
// where it floats, tiles or lands, and whether the bar overlaps it, is the window
// manager's business, so this file needs no compositor rules to work and none of
// the user's. It sizes itself as a fraction of the monitor it opens on, so there
// is nothing screen-shaped to hardcode either.
//
// The manifest sets keepLoaded, so the shell mounts this once at startup and it
// stays mounted; something asks the shell to toggle this panel's id, and the shell
// calls open()/close() below. See the host contract comment further down for why
// visibility is owned here instead of by flipping a special workspace.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons

// The sibling components live beside this file, so the directory needs to be on
// the import path: an implicit-directory import is not applied to files loaded
// through a Loader by absolute URL. PaneColumn and PaneDivider resolve bare, via
// that path, so only the two qualified uses need a namespace of their own.
import "." as Cfg

Item {
    id: root

    // ---- injected by shell.qml (panel Loader) ----
    property var shell: null
    property var service: null
    property var manifest: null

    // The service is paired with this plugin. shell.serviceFor is the live
    // lookup rather than the injected `service` property, because the panel and
    // the service are loaded independently: a keepLoaded panel mounts at shell
    // startup while _syncServices may still be creating the service, and reading
    // the injected property once would latch null forever. serviceFor is a plain
    // map read, so this binding re-evaluates and picks the service up whenever it
    // appears. nosignal.omasend does the same thing and seeds itself from
    // onSvcChanged for the same reason.
    readonly property var selfId: root.manifest && root.manifest.id ? root.manifest.id : "skollgrim.grimplayer"
    readonly property var mpd: root.shell && typeof root.shell.serviceFor === "function"
        ? root.shell.serviceFor(root.selfId)
        : root.service

    // The service starts each shell session at mode 0, so the persisted mode has
    // to be handed over once the service appears. Handing it over as a binding
    // would fight the service's own updates: this is a one-way seed, not a mirror.
    onMpdChanged: {
        if (root.mpd && typeof root.mpd.adoptStoredMode === "function")
            root.mpd.adoptStoredMode(prefs.repeatMode)
    }

    // ---- persisted preferences ----
    //
    // A child rather than a property of the window: it has no visual presence,
    // and giving it its own id is what names the state file the values live in.
    // Named prefs rather than config so the settings card below can have a
    // property called config and still be handed this object by its bare id:
    // an id is only in scope as a plain name, not as root.something.
    Cfg.GrimPlayerConfig {
        id: prefs
    }

    // The panel's live colour tokens. Seeded from the shell theme, and folded
    // from the playing cover's palette when adaptive colouring is on. Every
    // colour in this file and in the child components reads from here rather
    // than from the shell's Color singleton, which is global and must not be
    // written.
    GrimTheme {
        id: theme
    }

    // Fold the current cover's colours into the panel, or settle back on the
    // theme. Called on every palette change, when the image stops loading, and
    // when the setting is flipped.
    //
    // While a new cover is loading the previous palette is deliberately left in
    // place: resetting here would flash the theme through between tracks. Only
    // an album the probe has finished on with no artwork at all falls back to
    // the theme -- keyed on cover.noArt, not on the Image's own status, which
    // reports Error between candidates and would flash the theme mid-probe.
    function syncTheme() {
        if (!prefs.adaptiveColors) { theme.reset(); return }
        if (cover.hasArt && cover.palette && cover.palette.length > 0)
            theme.apply(cover.palette)
        else if (cover.noArt)
            theme.reset()
    }

    // Re-read the compositor's frame figures. Called at mount and on every open,
    // which is when a gap or border change is about to matter -- reading on the
    // Hyprland config-reload event would need the Hyprland import for a value
    // that only shifts the threshold by a few pixels.
    //
    // Only under auto: the threshold is the one thing these feed, and it is only
    // consulted while the window is deciding. With the pane pinned on or off the
    // figures are dead weight, so pinning skips three process spawns per summon
    // rather than asking the compositor a question whose answer is unused.
    function readFrame() {
        if (prefs.coverBandMode !== "auto") return
        // Already reading: leave the run in flight alone. Restarting the count
        // under it would let the first run's three answers arm frameRead as if
        // they were the second run's, and setting running on a live Process does
        // not restart it anyway, so the "re-read" would only corrupt the count.
        // The figures cannot have moved in the few milliseconds between two
        // calls, so dropping the second is what the caller wanted regardless.
        //
        // A flag rather than Process.running, because running goes false when the
        // process exits, which is one event-loop turn before the collector hands
        // over the text. A call landing in that gap would look idle and reset the
        // count the pending answers are still arriving against.
        if (root.frameReading) return
        root.frameReading = true
        // Drop the answering flag first: the figures are about to be replaced, and
        // between the spawn and the answer the old ones should not be trusted to
        // hide the pane. coverBand holds the pane while frameRead is false, so the
        // window keeps whatever placement it had until the new numbers land.
        root.frameRead = false
        root.frameParts = 0
        gapReader.running = true
        borderReader.running = true
        monitorReader.running = true
    }
    // One of the three frame reads came back. Arm frameRead when the last of them
    // lands; each Process fires this once per run, and readFrame resets the count,
    // so a re-read re-arms from scratch. frameReading clears on the last answer,
    // letting the next readFrame start a fresh run.
    function framePartArrived() {
        root.frameParts += 1
        if (root.frameParts < 3) return
        root.frameReading = false
        if (root.physicalScreenWidth > 0) root.frameRead = true
    }

    Connections {
        target: cover
        function onPaletteChanged() { root.syncTheme() }
        function onHasArtChanged() { root.syncTheme() }
        function onNoArtChanged() { root.syncTheme() }
    }

    Connections {
        target: prefs
        function onAdaptiveColorsChanged() { root.syncTheme() }
        // Pinning skips the frame reads (see readFrame), so switching back to
        // auto has to ask for them: without this the figures would still be at
        // their zero defaults and the threshold would be the raw screen width,
        // which is the maximised-window fault the frame subtraction exists to
        // fix. Harmless when auto was already the mode and the values are fresh.
        function onCoverBandModeChanged() { root.readFrame() }
    }

    // Re-read on the monitor changing under the open window. The frame figures
    // are per-monitor (a desk with a scaled display beside an unscaled one has
    // two different ratios), so a window dragged to the other screen would keep
    // converting with the first screen's numbers until the next summon.
    //
    // Watching the window's own `screen` property, which is notifyable. The
    // screen's `name` was the obvious thing to watch and is the wrong thing: it
    // is a constant in Quickshell's ShellScreen, so it has no change signal and a
    // handler named for one matches nothing -- the engine warns about it and the
    // re-read simply never happens. `screenChanged` fires on exactly the event
    // this wants, a different monitor under the surface. readFrame is a no-op
    // unless the mode is auto, so a move under a pinned pane costs nothing.
    Connections {
        target: window
        function onScreenChanged() { root.readFrame() }
    }

    Component.onCompleted: { syncTheme(); readFrame() }

    // Read here rather than in PaneRow because only this file imports Quickshell,
    // and a binding that names an unimported module fails silently to 0 -- which
    // is what a zero divider quantum does to the layout. Zero until the shell
    // reports a screen, at which point PaneRow's quantum resolves.
    readonly property real pixelRatio: {
        var screens = Quickshell.screens
        return screens && screens.length > 0 ? (screens[0].devicePixelRatio || 0) : 0
    }

    // The artwork-pane setting gives the cover its own pane: a fourth column on
    // the right, as tall as the lists beside it, with the cover set into the pane
    // at a chosen height (top, middle or bottom). It wears the same rounded
    // corners as the floating cover, so it reads as a deliberate panel of the
    // layout rather than something crammed against the frame. The track details
    // stay in the footer, which is otherwise unchanged, so the bar reads the same
    // whether the pane is on or off. That is the Georgia-ReBORN idea -- art as a
    // first-class panel rather than a footer -- adapted to keep all three lists
    // in view.
    //
    // The setting has three states: pin the pane on, pin it off, or let the
    // window decide. The pane only earns its width when there is room for it
    // beside three readable lists, so below the threshold auto folds the art
    // back into the floating corner cover.
    //
    // The threshold is a floor read as a share of the monitor the panel is on,
    // not of the window itself: a window at or above that share of the screen's
    // width keeps the pane, and one narrower than it folds the art into the
    // floating corner cover. A share of the window would be circular, since the
    // window is what is being judged, and a fixed pixel figure would ignore the
    // very difference between monitors this is meant to track.
    //
    // Reading the knob as a floor flips the sense of the two ends: 100% is the
    // strictest setting, keeping the pane only while the window fills the whole
    // screen width, and every step down admits narrower windows until at 50% the
    // pane is kept for a window no wider than half the screen -- the half-width
    // tile, the corner float.
    //
    // Width alone decides it. Height was measured too once, but the panes are
    // laid out across the width and the cover only needs a slice of the height
    // it already shares with the lists, so a window tall enough to read was
    // always tall enough for the pane; the second axis only gave a second way
    // for the pane to disappear.
    //
    // The share is measured against the screen minus the compositor's frame. A
    // maximised window is not the full screen width: Hyprland reserves the outer
    // gap and the window border around it, so a window filling the monitor
    // measures a little narrower than it. Against the raw screen width, 100% was
    // therefore unreachable while maximised -- the pane appeared only in
    // fullscreen, which drops those reservations, and nowhere else, which is
    // exactly the wrong way round. Subtracting the frame puts the maximised
    // window back at the top of the range, where "fills the screen" is what it
    // actually means. The figures are read from Hyprland rather than assumed, so a
    // theme, a gaps change or `omarchy toggle window-gaps` moves this with it
    // instead of leaving a stale constant to misfile every window size by a few
    // pixels.
    readonly property var activeScreen: window && window.screen ? window.screen
        : (Quickshell.screens && Quickshell.screens.length > 0 ? Quickshell.screens[0] : null)
    readonly property int screenWidth: root.activeScreen ? (root.activeScreen.width || 0) : 0
    // What one edge of a tiled window loses to the compositor: the outer gap plus
    // the window border. Both are physical pixels in Hyprland's options, while the
    // screen and window widths here are logical, so the sum is scaled back by the
    // same ratio the screen reports. Read under auto at mount and on every open
    // (see readFrame). Until the first read arrives the inset is 0, but the
    // threshold is not judged on it: frameRead holds the pane until all three
    // readings land, so a zero inset never decides anything.
    property int frameGap: 0
    property int frameBorder: 0
    // Hyprland reports the monitor at physical resolution; the shell reports the
    // screen logical. The ratio between them is the scale the frame converts by.
    property int physicalScreenWidth: 0
    // Whether the compositor has answered since the last readFrame(). The frame is
    // read by spawning hyprctl, so for the first frames after an open the figures
    // are still the zero defaults and windowInset is 0 -- which makes the
    // threshold the raw screen width and drops the pane for a beat on a maximised
    // window at 100%, then brings it back when the answer lands. Judging only on
    // a real reading skips that blink: an unanswered frame is a reason to wait,
    // not a reason to hide.
    //
    // All three reads have to land, not just one: the inset is the gap plus the
    // border scaled by the monitor ratio, so it is only meaningful once the gap,
    // the border and the monitor width are all in. Arming on the first answer
    // would compute the inset from two zeroes and flicker exactly as the stale
    // defaults did.
    property bool frameRead: false
    property int frameParts: 0
    // Whether a read is in flight, so a second readFrame cannot restart the count
    // under the answers still arriving (see readFrame).
    property bool frameReading: false
    readonly property int windowInset: root.screenWidth > 0 && root.physicalScreenWidth > 0
        ? Math.round((root.frameGap + root.frameBorder) * root.screenWidth / root.physicalScreenWidth)
        : 0
    readonly property int usableWidth: Math.max(0, root.screenWidth - 2 * root.windowInset)
    readonly property int coverBandMinWidth: Math.round(root.usableWidth * prefs.coverBandMinPct / 100)
    // The compositor's own frame arithmetic does not match the sum derived above
    // to the pixel: it rounds the gap and the border separately and per side, so a
    // maximised window measures a few pixels narrower than screenWidth minus twice
    // the derived inset. On this machine (1536-logical screen, 3px gap, 3px border,
    // scale 1.25) the derived inset is 5 and predicts a 1526-wide maximum, while
    // Hyprland actually places the window at 1521 -- 9 in from the left and 6 from
    // the right. Without a slack the top of the range would again be unreachable by
    // that discrepancy, which is the exact fault the frame subtraction exists to
    // fix. Six covers the measured five with a pixel to spare. It is a fixed number
    // rather than a scaled one: the discrepancy comes from device-pixel rounding
    // and does not grow with the panel's own UI scale. Six is far under any step
    // the setting offers (5% of a 1536 screen is 77), so it cannot pull a smaller
    // window up into the pane.
    readonly property int coverBandSlack: 6
    readonly property bool coverBand: {
        if (prefs.coverBandMode === "on") return true
        if (prefs.coverBandMode === "off") return false
        // No screen reported yet, or no frame read back: keep the pane rather than
        // flicker it away for the frame before the compositor answers.
        if (root.screenWidth <= 0 || !root.frameRead) return true
        return window.width + root.coverBandSlack >= root.coverBandMinWidth
    }
    readonly property string coverBandAlign: prefs.coverBandAlign
    // Read the compositor's frame so the threshold tracks a gaps change rather
    // than holding the value it started with. Reading on the Hyprland config-reload
    // event would need the Hyprland import for a value that only shifts the
    // threshold by a few pixels, and every open is when it is about to matter.
    Process {
        id: gapReader
        command: ["hyprctl", "-j", "getoption", "general:gaps_out"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.frameGap = root.gapsOutHorizontal(text)
                root.framePartArrived()
            }
        }
    }
    Process {
        id: borderReader
        command: ["hyprctl", "-j", "getoption", "general:border_size"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.frameBorder = root.optionInt(text)
                root.framePartArrived()
            }
        }
    }
    Process {
        id: monitorReader
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.physicalScreenWidth =
                    root.monitorWidthFor(text, root.activeScreen ? root.activeScreen.name : "")
                root.framePartArrived()
            }
        }
    }
    // The single integer an option carries. border_size is a plain int, so it is
    // read from `int`; a value given as CSS would still parse through the same
    // path, which is why both keys are tried rather than assuming one shape.
    function optionInt(raw) {
        try {
            var json = JSON.parse(raw || "{}")
            var css = String(json.css || "")
            var parts = css.match(/-?\d+(?:\.\d+)?/g) || []
            var n = parts.length > 0 ? Number(parts[0]) : Number(json.int)
            return isFinite(n) && n >= 0 ? Math.round(n) : 0
        } catch (e) {
            return 0
        }
    }
    // One side of a css_gaps option, in the order Hyprland reads them:
    // "top right bottom left" when four numbers are given, "top/bottom left/right"
    // when two, and all four the same when one. The width a window loses is the
    // left plus the right gap, so a lone number is correct for a uniform config
    // and wrong for an asymmetric one -- `gaps_out = 20 40` puts 40 on the sides
    // and would otherwise measure 20. Reading the horizontal pair is the whole
    // point of not just taking the first number.
    function gapsOutHorizontal(raw) {
        try {
            var json = JSON.parse(raw || "{}")
            var css = String(json.css || "")
            var parts = css.match(/-?\d+(?:\.\d+)?/g)
            if (!parts || parts.length === 0) {
                var n = Number(json.int)
                return isFinite(n) && n >= 0 ? Math.round(n) : 0
            }
            var v = parts.map(Number)
            var left, right
            if (v.length >= 4) { right = v[1]; left = v[3] }
            else if (v.length === 3) { right = v[1]; left = v[1] }
            else if (v.length === 2) { right = v[1]; left = v[1] }
            else { right = v[0]; left = v[0] }
            if (!isFinite(left) || !isFinite(right) || left < 0 || right < 0) return 0
            // The inset is per side, and this figure is used as one side, so the
            // two sides are averaged: an asymmetric gap has no single per-side
            // value, and the threshold only needs the window's reduction, which
            // left + right gives exactly when doubled at the call site.
            return Math.round((left + right) / 2)
        } catch (e) {
            return 0
        }
    }
    // The physical width of the monitor the panel is on, found by name rather
    // than taken as the first entry: on a multi-monitor desk Hyprland lists the
    // monitors in its own order, and the first is not necessarily the one this
    // window opened on. Falling back to the first is only for the case where the
    // screen has no name to match yet; the inset is then wrong on a mixed-scale
    // desk, which is the same fault as before and no worse.
    function monitorWidthFor(raw, name) {
        try {
            var list = JSON.parse(raw || "[]")
            if (!list || list.length === 0) return 0
            for (var i = 0; i < list.length; i++) {
                if (name !== "" && list[i].name === name && isFinite(Number(list[i].width)))
                    return Math.round(Number(list[i].width))
            }
            if (isFinite(Number(list[0].width))) return Math.round(Number(list[0].width))
        } catch (e) {
            // hyprctl missing / Hyprland not running: leave the inset at zero.
        }
        return 0
    }
    // The share of the pane region the art takes. The two placements want
    // different sizes -- the pane is the point of its layout and opens full, the
    // floating cover is a corner accent and rests small -- so in auto mode the
    // placement the window chose picks the size rather than the stored value.
    // Pinning the pane on or off leaves the artwork-size setting in charge, which
    // is why the card still offers that slider there and hides it under auto.
    readonly property int coverScalePct: prefs.coverBandMode === "auto"
        ? (root.coverBand ? 100 : 30)
        : prefs.coverScale
    // Vertical breathing room kept above and below the cover inside its pane, and
    // the gutter the floating cover keeps from the window edges. Whether the
    // artwork pane keeps a margin on the sides too is the coverPadding setting
    // (see coverPad); the vertical margin gives way on its own as the cover grows
    // to fill the pane.
    readonly property int bandPadding: Math.round(14 * prefs.uiScale)
    readonly property int floatGutter: Math.round(20 * prefs.uiScale)
    // Everything above the footer strip: the lists and the artwork pane.
    readonly property int paneHeight: Math.max(0, window.height - root.stripHeight)
    // Horizontal margin kept around the cover inside the artwork pane, from the
    // padding setting. Off is zero: the pane is then sized to the cover, so the
    // art runs flush to both edges and rides over the pane rule along its own
    // height (see coverPaneWidth).
    readonly property int coverPad: prefs.coverPadding ? root.bandPadding : 0

    // The artwork size is a share of the pane region rather than a pixel count,
    // so the art scales with the window: 100% is the full distance from the very
    // top of the player to the now-playing strip, and every smaller value is that
    // fraction of it. A share is what lets one setting mean "fill the pane" on
    // any monitor, instead of landing at a different effective size on each. The
    // share itself comes from coverScalePct, so this never reads the raw setting.
    readonly property int heroCover: Math.max(Math.round(48 * prefs.uiScale),
        Math.round(root.paneHeight * root.coverScalePct / 100))

    // The square the cover is drawn at in its pane: the chosen share of the pane
    // height, capped at 60% of the window width so the three lists keep a readable
    // share of the width. On a short, wide window a height-driven square would
    // otherwise grow straight over them.
    readonly property int paneCoverSize: root.coverBand
        ? Math.max(Math.round(48 * prefs.uiScale),
                   Math.min(root.heroCover,
                            Math.round(window.width * 0.60)))
        : 0
    // Width of the artwork pane. With a margin (the padding setting on) the cover
    // is held in from the edges, so the pane spans that margin on each side plus
    // the rule strip on its inner edge. With no margin the cover runs flush to
    // both edges and rides over the rule, so the pane is sized to the cover alone
    // -- no strip reserved -- and the rule shows only above and below the art, as
    // if the cover had eaten the stretch it covers (see the CoverArt item below).
    readonly property int coverPaneWidth: root.coverBand
        ? root.paneCoverSize + root.coverPad * 2 + (prefs.coverPadding ? root.coverPaneRule : 0)
        : 0
    // Thickness of the rule on the artwork pane's inner edge, shared with the pane
    // row so the two never drift. Zero when the column separators are off.
    // Otherwise it is always drawn: with no margin the cover sits over it and
    // hides the stretch it spans, leaving the rule visible only above and below
    // the art; with a margin the cover is held clear of it and the rule runs its
    // full height.
    readonly property int coverPaneRule: prefs.paneSeparators
        ? Math.max(1, Math.round(prefs.borderWidth * prefs.uiScale))
        : 0
    // Extra inset for the tracks pane's rows. The pane rule sits on the cover's
    // inner edge and the cover hides it, so with only the shared inset the
    // durations would run right up against the art; this holds them off it. Only
    // the tracks pane meets the cover, and only when the cover band is on --
    // floating, the pane keeps the shared inset.
    readonly property int trackArtGutter: root.coverBand ? Math.round(8 * prefs.uiScale) : 0
    // How far the cover is held off the pane edge it is aligned to, from the
    // padding setting. Fixed at coverPad until the cover is large enough that the
    // space left over shrinks to less than that, at which point the inset gives
    // way so a full pane-height cover sits exactly against the top and the strip
    // -- flush, not short by a margin it can no longer afford.
    readonly property int coverBandInset: Math.min(root.coverPad,
        Math.max(0, Math.round((root.paneHeight - root.paneCoverSize) / 2)))
    // The cover's y inside the pane, from the pane-position setting: against the
    // top or bottom edge (bar the inset above), or centred.
    readonly property int coverBandY: {
        if (root.coverBandAlign === "top") return root.coverBandInset
        if (root.coverBandAlign === "middle")
            return Math.round((root.paneHeight - root.paneCoverSize) / 2)
        return root.paneHeight - root.coverBandInset - root.paneCoverSize
    }
    // The floating cover: the same share of the pane height, capped so it never
    // spills past the gutter it keeps from the window edges.
    readonly property int floatingCoverSize: Math.max(Math.round(48 * prefs.uiScale),
        Math.min(root.heroCover,
                 window.width - root.floatGutter * 2,
                 root.paneHeight - root.floatGutter * 2))

    // Height of the now-playing strip. Named because two overlays sit clear of it
    // and have to agree with it: the typeahead readout and the MPD error banner.
    // They used to each repeat the number, which is how a change to the strip's
    // height would have left the error banner sitting on top of it.
    readonly property int stripHeight: Math.round(84 * prefs.uiScale)

    // ---- selection ----
    property string pane: "artists"
    property int artistIndex: 0
    property int albumIndex: 0
    property int trackIndex: 0

    // The settings card and the key reference are both modal: while either is up
    // the browser keeps its state underneath but stops answering keys, so j/k
    // cannot walk a list that is behind a dialog.
    property bool settingsOpen: false
    property int settingIndex: 0
    // The key of the setting under the caret. The caret is an index into
    // prefs.visibleEntries, but that list is a filtered view: switching a setting
    // can hide or reveal its dependents and renumber everything after it. Keeping
    // the key alongside the index lets the caret re-anchor to the same setting when
    // the list changes, instead of sliding onto whichever row moved into its slot.
    property string settingKey: ""
    property bool settingsEditMode: false
    property bool helpOpen: false

    readonly property var artistList: mpd && mpd.artists ? mpd.artists : []
    readonly property var albumList: artistIndex >= 0 && artistIndex < artistList.length
        ? artistList[artistIndex].albums : []
    readonly property var trackList: albumIndex >= 0 && albumIndex < albumList.length
        ? albumList[albumIndex].tracks : []

    // ---- host contract ----
    //
    // The shell owns whether this panel is open: it tracks that in openPanelIds
    // and calls open()/close() accordingly.
    //
    // This used to be driven the other way round, by having the launch
    // binding toggle a compositor special workspace. That only ever moved the
    // surface in and out of the workspace and never told the panel anything, which
    // worked only for as long as the window was permanently visible. It failed
    // permanently on the first real close: the compositor destroys the surface,
    // but keeps the workspace marked active because the hidden surface still
    // belongs to it, and every press after that toggled a workspace with nothing
    // in it. Owning visibility here fixes both halves -- the panel comes back in
    // one press, and closing it leaves no workspace behind to toggle.
    property bool closingFromHost: false

    // keepSelection is for the editTags IPC: the tag editor works from whatever
    // the panel has selected, so resetting the pane to artists would make it edit
    // a different set of songs than the one on screen. Every other caller wants
    // the fresh-summon reset.
    function open(payloadJson, keepSelection) {
        closingFromHost = true
        window.visible = true
        closingFromHost = false
        if (!keepSelection) pane = "artists"
        settingsOpen = false
        settingsEditMode = false
        helpOpen = false
        // The tag editor is modal and its fields would otherwise hold a set of
        // songs picked in a previous summon, with the panel's key catcher still
        // disabled because tagOpen was left true.
        tagOpen = false
        tagSongs = []
        // The service may have loaded its one status before this panel attached
        // its status listener. If nothing is playing, no further event arrives,
        // so without this the bar would sit at zero until the next playback
        // change. Re-anchoring on open picks up whatever MPD already answered.
        reanchor()
        root.readFrame()
        Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    }

    function close() {
        closingFromHost = true
        window.visible = false
        closingFromHost = false
    }

    // ---- activation ----

    // Playing means "this track and everything below it in the order shown".
    // The service owns that queue, so nothing here has to remember it.
    function activate() {
        if (!mpd) return
        if (pane === "artists") {
            mpd.playArtistAndBelow(artistIndex, 0, 0)
        } else if (pane === "albums") {
            mpd.playArtistAndBelow(artistIndex, albumIndex, 0)
        } else {
            mpd.playArtistAndBelow(artistIndex, albumIndex, trackIndex)
        }
    }

    // Down on the last row goes to the top and up on the first goes to the
    // bottom, unless the preference says the lists stop at their ends. The
    // double modulo is what makes the upward side work: JavaScript's % keeps the
    // sign of the dividend, so -1 % 10 is -1 and not 9, and a single modulo
    // would leave up on the first row pointing off the end of the list.
    function stepIndex(index, delta, length) {
        if (length <= 0) return 0
        if (!prefs.wrapAround) return Math.max(0, Math.min(length - 1, index + delta))
        return ((index + delta) % length + length) % length
    }

    function move(delta) {
        if (pane === "artists") selectArtist(stepIndex(artistIndex, delta, artistList.length), false)
        else if (pane === "albums") selectAlbum(stepIndex(albumIndex, delta, albumList.length), false)
        else trackIndex = stepIndex(trackIndex, delta, trackList.length)
    }

    // g and G jump to the first and last row. They used to reach move() as a
    // million-step delta and lean on the clamp to stop them there, which a
    // wrapping step cannot replace: a step that happens to be a multiple of the
    // list length lands back on the row it started from, and these three lists
    // are all short enough for that to be the normal case.
    function moveToEnd(last) {
        if (pane === "artists") selectArtist(last ? Math.max(0, artistList.length - 1) : 0, false)
        else if (pane === "albums") selectAlbum(last ? Math.max(0, albumList.length - 1) : 0, false)
        else trackIndex = last ? Math.max(0, trackList.length - 1) : 0
    }

    // Typeahead: typing letters jumps the caret to the first row whose label
    // starts with what has been typed. The buffer ages out after a short pause
    // so a fresh word starts a fresh search, the way file managers behave. It is
    // scoped to the active pane, which is where the caret is, and it never
    // steals a keystroke that a switch case above already claimed.
    property string typeaheadBuffer: ""

    function clearTypeahead() {
        typeaheadBuffer = ""
    }

    function handleTypeahead(ch) {
        if (!prefs.typeaheadSearch) return
        typeaheadBuffer = (typeaheadBuffer + ch).toLowerCase()
        typeaheadTimer.restart()
        var list = pane === "artists" ? artistList : pane === "albums" ? albumList : trackList
        for (var i = 0; i < list.length; i++) {
            var item = list[i]
            var name
            if (pane === "artists") name = item.name || ""
            // Match the album's own name, not the year-prefixed label the pane
            // draws: with "Album years" on, that label starts with the year, so a
            // typed letter could never match it.
            else if (pane === "albums") name = item.name || ""
            else name = item.title || item.file || ""
            if (name.toLowerCase().startsWith(typeaheadBuffer)) {
                if (pane === "artists") selectArtist(i, false)
                else if (pane === "albums") selectAlbum(i, false)
                else trackIndex = i
                return
            }
        }
    }

    // ---- settings ----
    //
    // The card owns no state of its own beyond which setting is under the caret;
    // opening it always starts at the top so the muscle memory for "the first
    // thing" survives having scrolled somewhere else last time.
    //
    // settingIndex is an index into prefs.visibleEntries -- the settings the card
    // is actually showing. Hidden dependents are not in that list, so navigation
    // never lands on a row nobody can see. The card is four columns; up/down
    // walks the caret down its own column, left/right crosses to the neighbouring
    // column at the same height. The config owns that geometry, keyed on the bare
    // index, so the panel and the card cannot disagree about where anything is.
    //
    // The index is only good for as long as the list does not change shape. A
    // setting that reveals or hides its dependents rebuilds it, so the caret also
    // remembers the setting's key and re-anchors to it whenever the list changes
    // (see onVisibleEntriesChanged). The index follows the setting; it is not
    // allowed to lead it onto a different row.
    function rememberSetting() {
        var e = prefs.visibleEntries[settingIndex]
        settingKey = e ? e.key : ""
        // The index at the last caret move. onVisibleEntriesChanged fires after
        // the list has already reshaped, so this is the stale index it needs to
        // fall back on when the key itself has gone (see the handler below).
        settingIndexBefore = settingIndex
    }

    onSettingIndexChanged: rememberSetting()

    function toggleSettings() {
        settingsOpen = !settingsOpen
        if (settingsOpen) {
            helpOpen = false
            settingIndex = 0
            // Assigning 0 is a no-op when it is already 0, so the change handler
            // above would not fire and a stale key from a previous summon would
            // re-anchor the caret somewhere else. Seed it here as well.
            rememberSetting()
            settingsEditMode = false
        }
    }

    // The key reference. Opening it closes the settings card, since both are
    // modal and only one can be on top.
    function toggleHelp() {
        helpOpen = !helpOpen
        if (helpOpen) {
            settingsOpen = false
            settingsEditMode = false
        }
    }

    function moveSettingRows(delta) {
        if (prefs.visibleEntries.length === 0) return
        var next = prefs.indexAt(prefs.columnOf(settingIndex), prefs.rowOf(settingIndex) + delta)
        if (next < 0 || next === settingIndex) return
        settingIndex = next
        settingsEditMode = false
    }

    function moveSettingColumns(delta) {
        if (prefs.visibleEntries.length === 0) return
        var column = prefs.columnOf(settingIndex) + delta
        if (column < 0 || column >= prefs.columns.length) return
        var next = prefs.indexAt(column, prefs.rowOf(settingIndex))
        if (next < 0 || next === settingIndex) return
        settingIndex = next
        settingsEditMode = false
    }

    // A dependent setting disappears the moment its parent is switched off, which
    // renumbers the visible list, so the caret's index no longer means what it
    // did. Re-find the setting it was on by key and move the index with it; only
    // fall back to clamping when there is no key to follow. This is what keeps the
    // caret -- and the highlighted row -- parked on "Artwork pane" while its size
    // and position rows appear and disappear beside it.
    //
    // The key cannot save a setting that hides *itself*, only one whose dependents
    // changed. That happens when the parent is changed by mouse: the caret sits on
    // "Artwork size" and the pane-mode slider is clicked to auto, so the size row
    // leaving the list takes the caret's key with it. Clamping to the list's end
    // would jump the caret to the bottom row; clamping to the index it already had
    // keeps it in place -- the row that slid up into that slot is the neighbour it
    // was already beside -- which is the same "nothing moved under the caret"
    // promise the key lookup keeps for the other case.
    property int settingIndexBefore: 0
    Connections {
        target: prefs
        function onVisibleEntriesChanged() {
            if (root.settingKey !== "") {
                for (var i = 0; i < prefs.visibleEntries.length; i++) {
                    if (prefs.visibleEntries[i].key === root.settingKey) {
                        root.settingIndex = i
                        return
                    }
                }
            }
            root.settingIndex = Math.max(0,
                Math.min(root.settingIndexBefore, prefs.visibleEntries.length - 1))
        }
    }

    function changeSetting(delta) {
        if (prefs.visibleEntries.length === 0) return
        prefs.cycle(prefs.visibleEntries[settingIndex], delta)
    }

    // Every index change has to reset the panes to its right, otherwise the
    // albums pane keeps showing the previous artist's albums and the tracks pane
    // keeps showing an album that is no longer on screen. focus is false for
    // keyboard movement, where the caret stays put, and true for a click, which
    // should also move the caret so the two agree on what Enter will play.
    function selectArtist(index, focus) {
        if (index < 0 || index >= artistList.length) return
        artistIndex = index
        albumIndex = 0
        trackIndex = 0
        if (focus) pane = "albums"
    }

    function selectAlbum(index, focus) {
        if (index < 0 || index >= albumList.length) return
        albumIndex = index
        trackIndex = 0
        if (focus) pane = "tracks"
    }

    function selectTrack(index) {
        if (index < 0 || index >= trackList.length) return
        trackIndex = index
        pane = "tracks"
    }

    // h/l and the left/right arrows walk the panes, matching ncmpcpp's
    // previous_column/next_column. The ends are stops rather than wrap-arounds:
    // l on the last pane is a no-op, and there is nowhere further right to go.
    function shiftPane(delta) {
        if (delta < 0) {
            if (pane === "artists") return
            pane = pane === "tracks" ? "albums" : "artists"
            return
        }
        if (pane === "artists") pane = "albums"
        else if (pane === "albums") pane = "tracks"
    }

    // ---- tag editing ----
    //
    // What a tag edit applies to is whatever the caret is sitting on, which is the
    // same three levels the browser is already built from: one track in the tracks
    // pane, the whole album in the albums pane, every track by that artist across
    // their albums in the artists pane. There is no separate selection to keep in
    // step with the caret, and no way for the two to disagree about what is
    // selected.
    property var tagSongs: []
    property bool tagOpen: false

    function selectionSongs() {
        if (pane === "tracks") {
            return (trackIndex >= 0 && trackIndex < trackList.length) ? [trackList[trackIndex]] : []
        }
        if (pane === "albums") {
            if (albumIndex < 0 || albumIndex >= albumList.length) return []
            return albumList[albumIndex].tracks
        }
        if (artistIndex < 0 || artistIndex >= artistList.length) return []
        var albums = artistList[artistIndex].albums
        var out = []
        for (var a = 0; a < albums.length; a++) out = out.concat(albums[a].tracks)
        return out
    }

    function openTagEditor() {
        if (!mpd) return
        var songs = selectionSongs()
        if (songs.length === 0) return
        tagSongs = songs
        tagOpen = true
    }

    // The flag for the release currently playing. Empty for an album with no
    // country, and for one tagged Worldwide, where the service substitutes a
    // globe because there is no territory to draw a flag for.
    readonly property string nowPlayingFlag: mpd ? mpd.flagEmoji(mpd.playingCountry) : ""

    // ---- elapsed time, interpolated locally ----
    // `time` is deliberately not an idle subsystem, so subscribing to it would
    // mean a status read every second. The bar is advanced from a local anchor
    // and re-anchored whenever real state arrives, so it stays smooth without
    // talking to MPD.
    property real anchorElapsed: 0
    property real anchorAt: 0
    property real elapsed: 0
    property real duration: mpd && mpd.status ? (mpd.status.duration || 0) : 0

    // The progress bar has to advance on its own. A binding over Date.now()
    // cannot work here: nothing it reads ever changes, so QML would evaluate
    // it once and never again, freezing the bar between events. So elapsed is
    // written imperatively from the timer below and re-anchored on real state.
    function reanchor() {
        if (!mpd) return
        anchorElapsed = mpd.status && mpd.status.elapsed ? mpd.status.elapsed : 0
        anchorAt = Date.now() / 1000
        root.elapsed = anchorElapsed
    }

    function advance() {
        if (!mpd || !mpd.status) return
        // Interpolate from the local anchor, not from mpd.status.elapsed. The
        // status map only changes when MPD sends an event, so right after a seek
        // it still holds the pre-seek position; adding the wall-clock delta to
        // that stale base dragged the bar back to roughly where playback was
        // before the click until the next status refresh arrived. anchorElapsed
        // already means "position at anchorAt", which is what this wants.
        if (mpd.status.state === "play") {
            root.elapsed = Math.min(anchorElapsed + (Date.now() / 1000 - anchorAt), root.duration)
        } else {
            root.elapsed = anchorElapsed
        }
    }

    readonly property real progress: duration > 0 ? Math.max(0, Math.min(1, elapsed / duration)) : 0

    // A seek has to move the bar at once. Seeking is a round trip: MPD answers
    // the command, then the next status refresh carries the new elapsed value, and
    // reanchor() only fires when that arrives. Depending on how promptly MPD
    // answers that left the bar parked at the old position for up to a second or
    // more after a click, which read as the click being ignored even though the
    // audio moved. So the click re-anchors to the requested position first, and
    // the real status refresh corrects it if the two disagree.
    //
    // seekFraction returns the position it asked MPD for, or -1 when it declined
    // to send anything. Re-anchoring on a declined seek is what made the bar snap
    // back: the click moved it, the next reanchor() restored the real position
    // because no command had ever gone out, and the click looked ignored.
    function seekToFraction(fraction) {
        if (!mpd) return -1
        if (!(duration > 0)) return -1
        var requested = mpd.seekFraction(Math.max(0, Math.min(1, fraction)))
        if (requested < 0) return -1
        anchorElapsed = requested
        anchorAt = Date.now() / 1000
        elapsed = anchorElapsed
        return requested
    }

    Connections {
        target: root.mpd
        function onStatusChanged() {
            root.reanchor()
        }
        function onCurrentChanged() {
            root.reanchor()
        }
        // A database event rebuilds and re-sorts the tree, so an index that was in
        // range a moment ago can point past the end. Clamp it here rather than
        // leaving an empty pane (and, for the artist index, an activation that
        // resolves to no files) until the caret is next moved.
        function onArtistsChanged() {
            if (root.artistIndex >= root.artistList.length)
                root.selectArtist(Math.max(0, root.artistList.length - 1), false)
            else if (root.albumIndex >= root.albumList.length)
                root.selectAlbum(Math.max(0, root.albumList.length - 1), false)
            else if (root.trackIndex >= root.trackList.length)
                root.trackIndex = Math.max(0, root.trackList.length - 1)
        }
        // The service owns the repeat policy and holds no reference to the config,
        // so persisting the mode is the panel's half of the arrangement.
        function onRepeatModeSelected(mode) {
            prefs.setRepeatMode(mode)
        }
    }

    function formatTime(seconds) {
        if (!seconds || seconds < 0) return "0:00"
        var total = Math.floor(seconds)
        var h = Math.floor(total / 3600)
        var m = Math.floor((total % 3600) / 60)
        var s = total % 60
        return (h > 0 ? h + ":" + (m < 10 ? "0" : "") + m : m) + ":" + (s < 10 ? "0" : "") + s
    }

    // "2024 - Little Weight", or the bare name for an album MPD has no Date tag
    // for. Only the albums pane uses this; the now-playing strip shows the track
    // and artist alone.
    function albumText(year, name) {
        if (!name) return ""
        if (!prefs.albumYears) return name
        return year ? year + " - " + name : name
    }

    FloatingWindow {
        id: window
        title: "GrimPlayer"
        color: theme.background
        // Starts closed; the shell summons the panel on demand. Starting visible
        // meant the surface outliving whatever it was pinned to, which is what
        // left its workspace stuck as active after a close.
        visible: false

        onVisibleChanged: {
            // Hidden by something other than close() -- the window manager
            // destroying the toplevel, which is its own decision and not one this
            // panel asked for. The host has to be told, or it keeps reporting the
            // panel as open and the next request to show it would hide it again
            // instead.
            if (!visible && !root.closingFromHost && root.shell && root.manifest
                    && typeof root.shell.hide === "function") {
                root.shell.hide(root.manifest.id)
            }
        }

        // No size is requested. The panes size themselves from window.width
        // (0.26/0.30 and whatever is left over), so any size derived from the
        // content would be a loop -- content <-> parent -- which Qt resolves to
        // the 100x100 default. Stating a number here would only be one more
        // opinion about geometry, and the compositor has better information than
        // QML does: it knows the monitor, the work area and the user's own
        // layout rules. A window rule that maximizes or sizes this panel overrides
        // anything stated here anyway, so the honest thing is to ask for nothing
        // and let the panes follow whatever size comes back.
        //
        // A window rule is therefore not required to *work*, only to look how you
        // want: without one the compositor picks the size itself, which is what
        // any other application gets.

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ---- lists + artwork ----
            //
            // One region: the three lists, and -- with the cover band on -- the
            // artwork pane to their right. The lists take the width the pane does
            // not, and PaneRow is told that width, so its 0.26/0.30 splits are
            // shares of the lists rather than of the whole window.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                PaneRow {
                    id: paneRow

                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(0, parent.width - root.coverPaneWidth)

                    // Bare `prefs`, not `root.prefs`: the config object is reached by its id, and an
                    // id is only in scope as a plain name. `root.prefs` is undefined,
                    // which left PaneRow silently on its fallback values -- dividers
                    // pinned to 1px whatever the setting said.
                    prefs: prefs
                    theme: theme
                    paneWidth: width
                    pixelRatio: root.pixelRatio
                    activePane: root.pane
                    artistList: root.artistList
                    albumList: root.albumList
                    trackList: root.trackList
                    artistIndex: root.artistIndex
                    albumIndex: root.albumIndex
                    trackIndex: root.trackIndex

                    artistLabel: function (item) { return item.name }
                    albumLabel: function (item) { return root.albumText(item.year, item.name) }
                    trackLabel: function (item) {
                        var n = item.track === null ? "--" : item.track
                        if (item.disc !== null && item.disc > 1) n = item.disc + "-" + n
                        return n + ". " + (item.title || "Untitled")
                    }
                    trackSublabel: function (item) { return root.formatTime(item.duration) }
                    playingMarkerSides: prefs.playingMarkerSides
                    trackArtGutter: root.trackArtGutter
                    isCurrent: prefs.playingHighlight ? function (item) {
                        return root.mpd && root.mpd.current && item.file === root.mpd.current.file
                    } : null

                    onArtistActivated: function (index) { root.selectArtist(index, true) }
                    onAlbumActivated: function (index) { root.selectAlbum(index, true) }
                    onTrackActivated: function (index) { root.selectTrack(index) }
                }

                // The artwork pane. A fourth column in the panel's own background,
                // so it reads as a peer of the lists rather than as a footer; ruled
                // on its inner edge like every other boundary. With no padding the
                // cover is drawn over that rule and hides the stretch it spans, so
                // the rule reads as broken exactly where the art is; the CoverArt
                // item below supplies the cover, so there is still only one
                // album-art loader and one palette extraction running.
                Rectangle {
                    id: coverPane

                    visible: root.coverBand
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: root.coverPaneWidth
                    color: theme.background

                    PaneDivider {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        thickness: root.coverPaneRule
                        // The same column-separator setting the list rules obey.
                        // With no padding the cover rides over this rule and hides
                        // the stretch it spans, so only the parts above and below
                        // the art show.
                        visible: root.coverPaneRule > 0
                        // Stepped up on a light ground, like the PaneRow rules: a
                        // 0.16 rule that is clear on a dark pane vanishes on a
                        // near-white one.
                        ruleColor: theme
                            ? Util.alpha(theme.foreground, theme.light ? 0.24 : 0.16)
                            : Qt.rgba(1, 1, 1, 0.08)
                    }
                }
            }

            // ---- now playing ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.stripHeight
                // A step away from the panes, so the footer reads as a strip
                // rather than as more of the same list background. The shade
                // comes from the theme (see GrimTheme.strip), because how far to
                // step depends on whether the ground is light or dark.
                color: theme.strip

                // The now-playing strip. Unchanged by the cover-band setting: the
                // track details stay here, in the footer, whether or not the
                // artwork pane is showing, so the bar looks the same either way
                // and the artwork pane holds only the art.
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Math.round(20 * prefs.uiScale)
                    anchors.rightMargin: Math.round(20 * prefs.uiScale)
                    spacing: Math.round(16 * prefs.uiScale)

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Math.round(4 * prefs.uiScale)

                        Text {
                            Layout.fillWidth: true
                            text: root.mpd && root.mpd.current && root.mpd.current.Title
                                ? root.mpd.current.Title : "Nothing playing"
                            color: theme.foreground
                            font.pixelSize: Math.round((Style.font.title + prefs.fontTitle) * prefs.uiScale)
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            // Artist only. The album is already the heading of the
                            // middle pane, so repeating it here said nothing the
                            // list does not, and the year prefix made the line
                            // long enough to elide on a two-word artist.
                            //
                            // The flag rides at the end of the same run rather than
                            // in a column beside it: country is a fact about the
                            // release, not about who plays it, so it reads as an
                            // aside on the artist rather than a second attribute.
                            // As part of the text it also elides with the name,
                            // which a fixed-position flag would not.
                            text: root.mpd && root.mpd.current && root.mpd.current.file
                                ? (root.mpd.current.Artist || root.mpd.current.AlbumArtist || "Unknown artist")
                                    + (root.nowPlayingFlag ? "  " + root.nowPlayingFlag : "")
                                : (root.mpd && root.mpd.connected ? "Library ready" : "Not connected to MPD")
                            color: theme.muted
                            font.pixelSize: Math.round((Style.font.body + prefs.fontBody) * prefs.uiScale)
                            elide: Text.ElideRight
                        }

                        SeekBar {
                            Layout.fillWidth: true
                            theme: theme
                            uiScale: prefs.uiScale
                            progress: root.progress
                            duration: root.duration
                            thickness: prefs.seekThickness
                            onSeekRequested: function (fraction) { root.seekToFraction(fraction) }
                        }

                        Text {
                            text: root.formatTime(root.elapsed) + " / " + root.formatTime(root.duration)
                            color: theme.muted
                            font.pixelSize: Math.round((Style.font.body + prefs.fontBody) * prefs.uiScale)
                        }
                    }

                    // ---- transport + volume ----
                    //
                    // Kept in one row so the volume rides at the same level as the
                    // buttons rather than on the floor: centred against each other
                    // their centrelines pin together, and the row centres with the
                    // text beside it.
                    RowLayout {
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Math.round(16 * prefs.uiScale)

                        TransportRow {
                            Layout.alignment: Qt.AlignVCenter
                            theme: theme
                            mpd: root.mpd
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                        }

                        VolumeControl {
                            Layout.alignment: Qt.AlignVCenter
                            theme: theme
                            mpd: root.mpd
                            iconSize: prefs.iconSize
                            sliderWidth: 120
                            uiScale: prefs.uiScale
                            onMuteToggled: root.toggleMute()
                            onAudibleVolumeChanged: function (v) { root.lastAudibleVolume = v }
                        }
                    }
                }
            }
        }

        // Album art for the current track. Two placements, both computed rather
        // than anchored: floating over the tracks pane's lower-right corner by
        // default, or -- when the cover band is on -- set into the artwork pane,
        // flush to its right edge with the optional margin, at the top, middle or
        // bottom of the pane. Nothing is anchored here on purpose -- toggling an
        // anchor to `undefined` does not reliably clear it, so a mode switch could
        // leave both edges anchored and stretch the art across the window. Plain
        // x/y is a value change the layout cannot get stuck on.
        CoverArt {
            id: cover
            theme: theme
            mpd: root.mpd
            uiScale: prefs.uiScale
            pixelRatio: root.pixelRatio
            // Only work while the panel is on screen. The window is closed most of
            // the time (the shell mounts this once and summons it on demand), and
            // an instance left active probed every album change with nothing
            // looking at it -- an ffmpeg extraction or a store fetch per untagged
            // album, and the colour pass on each cover.
            active: window.visible
            // The cover belongs to the album that is playing, so hiding the panel
            // keeps it rather than re-finding it: re-probing on the next summon
            // walked the candidate list from the top with the placeholder up in
            // the meantime, which looked like the artwork reloading (and, for a
            // name further down the list, briefly going missing).
            keepCoverWhileHidden: true
            coverBorder: prefs.coverBorder
            coverBorderWidth: prefs.coverBorderWidth
            rounded: prefs.coverRounded
            placeholder: prefs.coverPlaceholder
            fetchCovers: prefs.fetchCovers
            transitionDuration: prefs.coverTransition
            width: root.coverBand ? root.paneCoverSize : root.floatingCoverSize
            height: width
            // In the artwork pane the cover keeps the padding setting's margin on
            // the right, flush when it is off; the pane is sized to match, so with
            // no margin the art runs flush to the left edge too and covers the pane
            // rule over its own height. Floating, it keeps its gutter.
            x: root.coverBand
                ? parent.width - root.coverPad - width
                : parent.width - width - root.floatGutter
            y: root.coverBand
                ? root.coverBandY
                : parent.height - root.stripHeight - root.floatGutter - height
        }

        // Typeahead readout: the letters being jumped to, shown only while they
        // are buffered and gone the moment the buffer ages out, so it always
        // matches what the next typed letter will search for.
        //
        // Two homes. "corner" tucks it into the lower-left of the panel -- which
        // is the artists pane's lower corner, since that pane is leftmost and
        // starts at x=0 -- clear of the caret and the cover art: a glanceable
        // aside. "center" floats in the middle of the whole window, the one spot
        // the eye lands on without hunting, which is why it centres on both axes
        // rather than sharing the error banner's band above the strip. It is
        // centred on the window rather than tucked in a pane because the buffer is
        // about the session, not about whichever pane the caret happens to be in.
        //
        // Both placements measure against the window, not the lists region: this
        // item is a sibling of the panes, so parent is the whole surface. The
        // vertical positions subtract the strip because the readout belongs to the
        // list area above it, not to the footer.
        //
        // Position is set with x/y rather than by swapping anchors between the two
        // placements. Toggling a property that feeds an anchor between undefined
        // and an anchor line leaves Qt with a half-applied anchor -- an item bound
        // to both `left` and `horizontalCenter` for a frame stretches to span
        // them, which is the wide stray rule that showed up when the setting was
        // flipped. A plain x/y binding has no anchor state to get stuck in.
        Rectangle {
            id: typeaheadReadoutBox
            readonly property bool centered: prefs.typeaheadPlace === "center"
            readonly property int gutter: Math.round(12 * prefs.uiScale)
            // Corner: tucked left, just above the now-playing strip. Center: dead
            // middle of the pane area above the strip, so the readout never rides
            // down into the footer whatever the strip's thickness.
            readonly property int paneArea: Math.max(0, parent.height - root.stripHeight)
            visible: root.typeaheadBuffer.length > 0
            width: typeaheadReadout.implicitWidth + Math.round(20 * prefs.uiScale)
            height: typeaheadReadout.implicitHeight + Math.round(12 * prefs.uiScale)
            x: centered ? Math.round((parent.width - width) / 2) : gutter
            y: centered
                ? Math.round((paneArea - height) / 2)
                : parent.height - root.stripHeight - gutter - height
            radius: Math.round(6 * prefs.uiScale)
            // Themed like the rest of the panel: a low foreground wash rather
            // than flat black, so it sits in the palette and follows a theme
            // switch instead of punching a dark hole in it.
            color: Util.alpha(theme.foreground, 0.10)
            border.width: 1
            border.color: Util.alpha(theme.foreground, 0.16)

            Text {
                id: typeaheadReadout
                anchors.centerIn: parent
                text: root.typeaheadBuffer
                // Accent, matching how the settings card marks a live value.
                color: theme.accent
                // Subtitle rather than body: one step up from the panel's default
                // text, because this is a transient readout that has to be legible
                // away from the caret. The size setting is an offset on top, so the
                // centred placement can be pushed larger without touching the
                // panel's other type.
                font.pixelSize: Math.round((Style.font.subtitle + prefs.typeaheadScale) * prefs.uiScale)
                font.family: Style.font.family
            }
        }

        // Failure has to be loud: a player that silently shows an empty library
        // is indistinguishable from an empty one.
        //
        // It shares the typeahead's band above the now-playing strip -- the one
        // part of the window nothing else competes for, and the part least likely
        // to be over a row the user is reading -- but centred rather than tucked
        // into the artists pane's corner, because this is a statement about the
        // whole panel and not about the caret. The band comes from stripHeight so
        // the two cannot drift apart.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.stripHeight + Math.round(12 * prefs.uiScale)
            visible: !!root.mpd && (!root.mpd.connected || root.mpd.lastError !== "")
            width: errorText.implicitWidth + Math.round(32 * prefs.uiScale)
            height: errorText.implicitHeight + Math.round(12 * prefs.uiScale)
            radius: Math.round(6 * prefs.uiScale)
            // Built like the typeahead rather than as a filled slab: a low wash of
            // the theme's own alert token, a firmer edge on the same token, and
            // readable text. The previous urgent fill at 0.92 under hardcoded white
            // was the one part of this panel that ignored the theme, which is why
            // it read as a system dialog dropped onto a themed surface -- and why a
            // theme with a paler alert colour turned it into a flat pink block.
            //
            // The text stays in foreground rather than urgent: `urgent` is allowed
            // to be a dark muted red (it defaults to one), so tinting the label
            // with it too could leave the text unreadable on a dark theme. The
            // tint and the border carry the urgency, and they use the same two
            // stops the typeahead already uses.
            color: Util.alpha(theme.urgent, 0.18)
            border.width: 1
            border.color: Util.alpha(theme.urgent, 0.6)

            Text {
                id: errorText
                anchors.centerIn: parent
                text: root.mpd && root.mpd.lastError !== "" ? "MPD: " + root.mpd.lastError : "MPD not connected"
                color: theme.foreground
                // bodySmall, one step up from caption: this is a status line that
                // has to be read at a glance, and caption was the smallest text in
                // the panel. The user offset still applies on top, so anyone who
                // wants it larger from the settings card can have it.
                font.pixelSize: Math.round((Style.font.bodySmall + prefs.fontCaption) * prefs.uiScale)
            }
        }

        // Keyboard handling lives on one item rather than on the views, so j/k/h/l
        // behave the same wherever the caret is and the lists never fight it for
        // arrow-key navigation.
        //
        // It covers the whole window but takes no mouse input: enabled is false
        // on the implicit grab, which would otherwise sit above every pane and
        // eat the row clicks.
        Item {
            id: keyCatcher
            anchors.fill: parent
            // Stands down while the tag editor is up: the editor's fields are real
            // text inputs, and a focused catcher above them would take every
            // letter before it reached a field.
            enabled: !root.tagOpen
            focus: !root.tagOpen

            // Focus is claimed here on mount and again by open() on every summon
            // (the shell calls it -- see the host contract above), which together
            // are what make the keys work. This item's own visible never changes,
            // so an onVisibleChanged here would never fire.
            Component.onCompleted: Qt.callLater(function () { if (!root.tagOpen) keyCatcher.forceActiveFocus() })

            Keys.onPressed: function (event) {
                var handled = true

                // Shift, control and alt are read before the switch. shift+left
                // and shift+right report the same Qt.Key_Left/Qt.Key_Right as the
                // bare arrows, so a case matching on the key alone ran first and
                // changed pane instead of seeking -- the seek branch below was
                // unreachable and could never be taken. Alt is what separates the
                // screen-opening keys from the letters the typeahead wants.
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                var alt = (event.modifiers & Qt.AltModifier) !== 0

                // The Alt screen keys, handled before the modal branches so they
                // work from inside the settings card or the key reference as well
                // as from the browser: Alt+S toggles the card, Alt+T opens the tag
                // editor. The tag editor is the exception -- it disables this
                // catcher and reads its own keys. Plain ? opens the reference, and
                // is left to the branches below so it can also close a screen.
                if (alt && (event.key === Qt.Key_S || event.key === Qt.Key_T)) {
                    if (event.key === Qt.Key_S) {
                        root.toggleSettings()
                    } else {
                        root.settingsOpen = false
                        root.helpOpen = false
                        root.openTagEditor()
                    }
                    event.accepted = true
                    return
                }

                // The key reference is modal too, and sits above the settings
                // card, so it takes first refusal while it is up. Any key but the
                // ones that dismiss it is swallowed, so nothing behind it moves.
                if (root.helpOpen) {
                    switch (event.key) {
                    case Qt.Key_Escape:
                    case Qt.Key_Q:
                    case Qt.Key_Question:
                        if (!alt) root.helpOpen = false
                        break
                    default:
                        handled = false
                    }
                    if (handled) event.accepted = true
                    return
                }

                // Settings is modal, so it gets first refusal on every key: the
                // browser underneath must not answer j/k while the card is up, or
                // the caret moves in a list nobody can see.
                //
                // Two modes. Browsing: all four arrows, and the hjkl equivalents,
                // walk the grid -- up/down a column, left/right across columns.
                // Editing: a slider is open, so left/right belong to it and
                // up/down go back to moving the caret. Enter is the toggle for
                // the plain switches and the way into a slider, which is the
                // only reason edit mode exists at all.
                if (root.settingsOpen) {
                    var count = prefs.visibleEntries.length
                    var entry = count > 0 ? prefs.visibleEntries[Math.max(0, Math.min(root.settingIndex, count - 1))] : null
                    var isNumeric = !!(entry && entry.options && entry.options.length > 0 && typeof entry.options[0] === "number")

                    switch (event.key) {
                    case Qt.Key_Escape:
                        // Esc backs out one level: leave the slider first, close
                        // the card second. Closing outright from inside a slider
                        // loses the setting you were standing on.
                        if (root.settingsEditMode) root.settingsEditMode = false
                        else root.settingsOpen = false
                        break
                    case Qt.Key_Q: root.settingsOpen = false; break
                    case Qt.Key_Question:
                        // ? is the key reference everywhere, so from the card it
                        // hands over to that rather than just closing. Only the
                        // bare key: Alt+? is not the shortcut.
                        if (!alt) {
                            root.settingsOpen = false
                            root.helpOpen = true
                        }
                        break

                    case Qt.Key_Up:
                    case Qt.Key_K: root.moveSettingRows(-1); break
                    case Qt.Key_Down:
                    case Qt.Key_J: root.moveSettingRows(1); break

                    case Qt.Key_Left:
                    case Qt.Key_H:
                        if (root.settingsEditMode) root.changeSetting(-1)
                        else root.moveSettingColumns(-1)
                        break
                    case Qt.Key_Right:
                    case Qt.Key_L:
                        if (root.settingsEditMode) root.changeSetting(1)
                        else root.moveSettingColumns(1)
                        break

                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                    case Qt.Key_Space:
                        if (root.settingsEditMode) root.settingsEditMode = false
                        else if (isNumeric) root.settingsEditMode = true
                        else root.changeSetting(1)
                        break

                    case Qt.Key_G:
                        if (root.settingsEditMode) {
                            root.changeSetting(shift ? -1 : 1)
                        } else {
                            // The first and last settings in the card. With four
                            // columns there is no single end column to ask for, so
                            // the ends are the ends of the flat visible list.
                            if (count > 0) root.settingIndex = shift ? count - 1 : 0
                            root.settingsEditMode = false
                        }
                        break
                    case Qt.Key_R:
                        // Bare R only. Shift is not read for the reset, so Shift+R
                        // -- which reports the same Key_R -- would otherwise wipe
                        // every setting just as easily as R. Reset is destructive
                        // enough to want the plain key.
                        if (!root.settingsEditMode && !shift && !ctrl && !alt) prefs.reset()
                        break
                    default:
                        handled = false
                    }
                    if (handled) event.accepted = true
                    return
                }

                // Alt and control are not part of any browser binding -- the Alt
                // screen keys were taken above. Without this, Alt+letter reached
                // the typeahead and Ctrl+arrow moved the caret or changed pane.
                // Swallow them rather than acting on the letter.
                if (alt || ctrl) {
                    event.accepted = true
                    return
                }

                // Shift+arrows seek. h and l are the vim spelling of the same
                // two arrows, so with Vim keys on their shifted forms seek the
                // same way rather than changing pane.
                if (shift && (event.key === Qt.Key_Left
                        || (prefs.vimKeys && event.key === Qt.Key_H))) {
                    root.seekBy(-5)
                } else if (shift && (event.key === Qt.Key_Right
                        || (prefs.vimKeys && event.key === Qt.Key_L))) {
                    root.seekBy(5)
                } else {
                // Arrows mirror the hjkl bindings, so both schemes navigate the
                // same way: up/down move within a pane, left/right change pane.
                // Seeking keeps shift+left/shift+right rather than the bare
                // arrows, which are wanted for pane changes.
                switch (event.key) {
                case Qt.Key_Down:
                    root.move(1); break
                case Qt.Key_Up:
                    root.move(-1); break
                case Qt.Key_Right:
                    root.shiftPane(1); break
                case Qt.Key_Left:
                    root.shiftPane(-1); break
                // The vim letters only act as navigation while vimKeys is on.
                // With it off they are ordinary text, so they fall through to
                // the typeahead check below instead of being swallowed here.
                case Qt.Key_J: if (prefs.vimKeys) root.move(1); else handled = false; break
                case Qt.Key_K: if (prefs.vimKeys) root.move(-1); else handled = false; break
                case Qt.Key_L: if (prefs.vimKeys) root.shiftPane(1); else handled = false; break
                case Qt.Key_H: if (prefs.vimKeys) root.shiftPane(-1); else handled = false; break
                case Qt.Key_G: if (prefs.vimKeys) root.moveToEnd(shift); else handled = false; break
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.activate(); break
                case Qt.Key_Space:
                    root.mpd && root.mpd.togglePlay(); break
                case Qt.Key_Question:
                    // ? (Shift+/) opens the key reference. Alt+? never gets
                    // here: it is swallowed by the modifier guard above.
                    root.toggleHelp()
                    break
                default:
                    handled = false
                }

                // Typeahead is the fallback for any printable key no command
                // above claimed: it jumps the caret to the first row starting
                // with what has been typed. handleTypeahead checks the
                // typeaheadSearch preference itself.
                if (!handled && event.text && event.text.length === 1
                        && /^[A-Za-z0-9æøåÆØÅ]$/.test(event.text)) {
                    root.handleTypeahead(event.text)
                    handled = true
                }
                }
                if (handled) event.accepted = true
            }
        }

        // Last child of the window, so it stacks over the panes and the key
        // catcher rather than under them.
        //
        // Behind a Loader so the card's thirty-odd cells are only built while it
        // is open: it is closed the overwhelming majority of the time, and each
        // column is a Repeater that builds every control whether or not anything
        // is looking at it. Destroying the card on close also drops its own
        // scratch state, which is what the panel wants anyway -- the caret lives
        // in settingIndex, so a reopened card comes back where it was left.
        Loader {
            anchors.fill: parent
            active: root.settingsOpen
            sourceComponent: settingsCard
        }

        Component {
            id: settingsCard

            Cfg.GrimPlayerSettings {
                // Fill is what makes the card land in the middle of the window: an
                // unanchored Item is 0x0, and the card centres inside it.
                anchors.fill: parent
                theme: theme
                config: prefs
                index: root.settingIndex
                editMode: root.settingsEditMode
                uiScale: prefs.uiScale
                visible: root.settingsOpen
                // The card asks, the panel decides. Assigning settingIndex back
                // from onIndexChanged would only work until the first click inside
                // the card, which rebinds nothing and leaves the keyboard driving a
                // caret the card has stopped showing.
                onIndexRequested: function (i) { root.settingIndex = i }
                onEditModeRequested: function (on) { root.settingsEditMode = on }
                onDismissed: { root.settingsOpen = false; root.settingsEditMode = false }
            }
        }

        // The key reference, above the settings card and the panes. Read-only, so
        // it never takes focus.
        Cfg.GrimPlayerHelp {
            anchors.fill: parent
            theme: theme
            uiScale: prefs.uiScale
            visible: root.helpOpen
            onDismissed: root.helpOpen = false
        }

        // Above the settings card, which is itself above the panes: both are
        // modal, but the tag editor is opened from outside this window, so it has
        // to be able to appear over a settings card nobody is looking at.
        Cfg.TagEditor {
            id: tagEditor
            anchors.fill: parent
            theme: theme
            mpd: root.mpd
            songs: root.tagSongs
            uiScale: prefs.uiScale
            coverTransition: prefs.coverTransition
            fetchCovers: prefs.fetchCovers
            coverRounded: prefs.coverRounded
            visible: root.tagOpen
            onDismissed: root.tagOpen = false
        }
    }

    // MPD has no mute command, so muting is modelled the way every MPD client
    // does it: remember the last audible level, drop to zero, and put it back on
    // the way out. The remembered level starts at zero, so unmuting from a cold
    // start with nothing to restore lands on a usable 50 rather than staying
    // silent with no way back.
    property int lastAudibleVolume: 0

    function toggleMute() {
        if (!mpd || !mpd.status || mpd.status.volume === undefined) return
        var current = mpd.status.volume
        if (current > 0) {
            lastAudibleVolume = current
            mpd.setVolume(0)
        } else {
            mpd.setVolume(lastAudibleVolume > 0 ? lastAudibleVolume : 50)
        }
    }

    function seekBy(seconds) {
        if (!mpd || !duration) return
        // Through seekToFraction so the bar re-anchors to the target and clamps
        // to the track, the same way a click on the bar does. Sending the raw
        // fraction straight to MPD left elapsed on its old anchor, so the bar
        // snapped back to where it was on the next tick.
        root.seekToFraction((root.elapsed + seconds) / root.duration)
    }

    // Only ticks while something is playing: a paused transport has nothing to
    // interpolate, so the timer stops rather than waking the shell every second.
    Timer {
        interval: 1000
        running: !!root.mpd && root.mpd.status && root.mpd.status.state === "play"
        repeat: true
        onTriggered: root.advance()
    }

    // Ages out the typeahead buffer. Short enough that two deliberate presses
    // of the same letter search "aa" rather than restarting, long enough that a
    // pause reads as "new word".
    Timer {
        id: typeaheadTimer
        interval: 800
        repeat: false
        onTriggered: root.clearTypeahead()
    }

    // Reached from outside the window as well as from inside it, so the editor can
    // be opened on whatever is selected without the panel having to be focused
    // first. The panel is summoned first: openTagEditor only sets the editor's
    // state, and an editor on a hidden window is invisible, which is what the
    // desktop entry used to hit.
    IpcHandler {
        target: "skollgrim.grimplayer"
        function editTags(): void {
            root.open("", true)
            root.openTagEditor()
        }
    }
}
