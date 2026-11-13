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
    // A var alias for the shell's theme font object: qmllint cannot see the
    // tokens inside Style.font, so reading them directly warns on every one.
    readonly property var themeFont: Style.font

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
        if (root.mpd && typeof root.mpd.adoptStoredShuffleMode === "function")
            root.mpd.adoptStoredShuffleMode(prefs.shuffleMode)
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
    //
    // A palette cached against the resolved cover is used before the quantized
    // colours are consulted: on a revisit the cover skips the colour pass, so
    // `cover.palette` is empty and the cache is the only answer.
    function syncTheme() {
        if (!prefs.adaptiveColors) { theme.reset(); return }
        var source = String(cover.resolvedSource || "")
        var cached = theme.cachedPalette(source)
        if (cached) { theme.applyDerived(cached); return }
        // Only a palette quantized from this very cover may be applied or
        // cached. While a new cover is loading the quantizer still holds the
        // previous album's colours, and applying those against the new source
        // would both show the wrong album's ground and poison the cache with
        // it; the guard leaves the previous palette up until the new pass
        // lands, which is also what keeps the theme from flashing mid-probe.
        if (cover.hasArt && cover.paletteSource === source
                && cover.palette && cover.palette.length > 0)
            theme.apply(cover.palette, source)
        else if (cover.noArt)
            theme.reset()
    }

    // Cached frame measurements per monitor, to skip three hyprctl spawns when the
    // panel is reopened soon after the last read. The cache expires: a gaps or
    // border change happens outside this process, so a cache keyed only on the
    // monitor name would serve the old figures for the rest of the session.
    property var frameCache: ({})
    property int frameCacheTtl: 30000

    function computeFrameCacheKey() {
        var mon = root.activeScreen ? (root.activeScreen.name || "") : ""
        return mon
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
    // Cache results per monitor for a short while: reopening the panel in quick
    // succession reuses them, while a change made between opens is picked up
    // once the entry expires.
    function readFrame() {
        if (prefs.coverBandMode !== "auto") return
        // Already reading: leave the run in flight alone. Restarting the count
        // under it would let the first run's answers arm frameRead as if
        // they were the second run's, and setting running on a live Process does
        // not restart it anyway, so the "re-read" would only corrupt the count.
        if (root.frameReading) return

        var key = root.computeFrameCacheKey()
        var cached = root.frameCache[key]
        if (cached && cached.physicalScreenWidth > 0
                && Date.now() - cached.readAt < root.frameCacheTtl) {
            root.frameGap = cached.frameGap
            root.frameBorder = cached.frameBorder
            root.frameRead = true
            return
        }

        root.frameReading = true
        // Drop the answering flag first: the figures are about to be replaced, and
        // between the spawn and the answer the old ones should not be trusted to
        // hide the pane. coverBand holds the pane while frameRead is false, so the
        // window keeps whatever placement it had until the new numbers land.
        root.frameRead = false
        root.frameParts = 0
        root.frameFailed = false
        root.frameAnswered = ({})
        gapReader.running = true
        borderReader.running = true
        monitorReader.running = true
    }
    // One of the three frame reads came back. Arm frameRead when the last of them
    // lands; each reader reports once per run (see framePartArrived), and readFrame
    // resets the count, so a re-read re-arms from scratch. frameReading clears on
    // the last answer, letting the next readFrame start a fresh run.
    //
    // A reader reports twice per successful run -- once when its collector hands
    // over the text, once when the process exits -- so the first report for a
    // reader is the one that counts. Without the per-reader guard the count would
    // run to six and the run would never arm. Guarding by name rather than by a
    // shared counter keeps the count honest however the two events interleave.
    function framePartArrived(name) {
        if (root.frameAnswered[name]) return
        root.frameAnswered[name] = true
        root.frameParts += 1
        if (root.frameParts < 3) return
        root.frameReading = false
        // A run the watchdog had to close out may be missing readings entirely, so
        // the figures could be at their zero defaults. Arming on it would compute
        // the inset from two zeroes and misfile every window size, so a failed run
        // holds the pane instead -- the same "unanswered is a reason to wait" rule
        // frameRead follows. The next open tries again.
        if (!root.frameFailed && root.physicalScreenWidth > 0) {
            root.frameRead = true
            var key = root.computeFrameCacheKey()
            root.frameCache[key] = {
                frameGap: root.frameGap,
                frameBorder: root.frameBorder,
                physicalScreenWidth: root.physicalScreenWidth,
                readAt: Date.now()
            }
        }
    }
    // The watchdog fired: the run has had long enough. A process that could not be
    // spawned reports nothing at all (see the note on frameWatchdog), so the parts
    // still outstanding are written off as failed and the count is closed out.
    // Marking the run failed keeps it from arming frameRead on zeroes, and clearing
    // frameReading lets the next open start a fresh read rather than the threshold
    // staying frozen for the session.
    function frameRunExpired() {
        if (!root.frameReading) return
        root.frameFailed = true
        root.frameAnswered = ({})
        root.frameParts = 3
        root.frameReading = false
    }

    property string lastPaletteDir: ""
    Timer {
        id: themeDebounce
        interval: 200
        repeat: false
        onTriggered: { root.syncTheme() }
    }

    Timer {
        id: paletteThrottle
        interval: 150
        repeat: false
        onTriggered: { root.syncTheme() }
    }

    Connections {
        target: cover
        function onPaletteChanged() {
            // Before anything reads it: the colours that just arrived belong to
            // the cover whose pass has finished, which is not necessarily the
            // one `resolvedSource` names yet (see notePalette).
            cover.notePalette()
            if (cover && cover.loadedDir) {
                if (cover.loadedDir !== root.lastPaletteDir) {
                    root.lastPaletteDir = cover.loadedDir
                    paletteThrottle.restart()
                } else {
                    root.syncTheme()
                }
            } else {
                themeDebounce.restart()
            }
        }
        function onHasArtChanged() { paletteThrottle.restart() }
        function onNoArtChanged() { paletteThrottle.restart() }
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
        // Turning following back on should pick up the playing line at once
        // rather than leave a paused reader waiting for the next scroll.
        function onLyricsFollowChanged() {
            if (prefs.lyricsFollow !== "follow") return
            root.lyricsFollowPaused = false
            root.scrollToCurrentLyric()
        }
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
        function onScreenChanged() {
            root.readFrame()
            scaleReader.running = true
        }
    }

    Component.onCompleted: { syncTheme(); readFrame(); scaleReader.running = true }

    // The rendering scale the divider geometry needs. Not the same number as the
    // screen's devicePixelRatio: under Hyprland's fractional scaling Quickshell
    // reports 1 for a 1.25 screen, because the surface is laid out at logical size
    // and the compositor scales it up. A rule placed at a logical x then lands at
    // a fractional device x, and a one-pixel-wide rectangle is rasterised to one
    // or two device pixels depending on that phase -- which is exactly how two
    // dividers with identical widths in logical pixels came out different widths
    // on screen. Hyprland reports the real ratio directly (physical pixels per
    // logical pixel), so read it there and fall back to the screen only until the
    // read answers.
    //
    // Kept separate from pixelRatio below, which the cover decoder uses: that one
    // stays on the screen's own ratio, so this fix does not change how large a
    // cover is decoded. Read here rather than in PaneRow because only this file
    // imports Quickshell, and a binding that names an unimported module fails
    // silently to 0 -- which is what a zero divider quantum does to the layout.
    // The read runs at mount and on a screen change, independent of the
    // cover-band mode: the dividers need the scale even when the frame readers
    // are pinned off.
    property real compositorScale: 0
    readonly property real renderScale: root.compositorScale > 0
        ? root.compositorScale
        : (root.activeScreen ? (root.activeScreen.devicePixelRatio || 0) : 0)

    // Device pixel ratio of the window's screen, used by the cover decoder to
    // decode a cover at display size in physical pixels rather than at full
    // source resolution. Read here because only this file imports Quickshell;
    // a binding that names an unimported module fails silently to 0.
    readonly property real pixelRatio: root.activeScreen
        ? (root.activeScreen.devicePixelRatio || 0) : 0

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
    // Whether this run has seen a reader fail to start. A failed run must not arm
    // frameRead, or the inset would be computed from zeroes.
    property bool frameFailed: false
    // Which of the three readers have reported this run, keyed by name. Each
    // reader has two chances to report -- the collector's stream-finished and the
    // process's exited -- and only the first of them counts (see
    // framePartArrived).
    property var frameAnswered: ({})
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
        // Auto-hide at very narrow widths to keep the three-pane layout usable
        if (root.width > 0 && root.width < Math.round(680 * prefs.uiScale)) return false
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
                root.framePartArrived("gap")
            }
        }
        // A process that starts but exits before its collector reports -- a
        // hyprctl that ran and failed, say -- still fires this, and only the first
        // report for a reader counts (see framePartArrived). The handler takes no
        // arguments deliberately: onExited carries an exit code, and a parameter
        // here would shadow the reader name this is reporting for.
        onExited: function () { root.framePartArrived("gap") }
    }
    Process {
        id: borderReader
        command: ["hyprctl", "-j", "getoption", "general:border_size"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.frameBorder = root.optionInt(text)
                root.framePartArrived("border")
            }
        }
        onExited: function () { root.framePartArrived("border") }
    }
    Process {
        id: monitorReader
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.physicalScreenWidth =
                    root.monitorWidthFor(text, root.activeScreen ? root.activeScreen.name : "")
                root.framePartArrived("monitor")
            }
        }
        onExited: function () { root.framePartArrived("monitor") }
    }

    // The divider scale, kept apart from the frame run above for two reasons: it
    // is needed in every cover-band mode, and the frame run is skipped entirely
    // when the pane is pinned. Fire-and-forget -- there is no count to arm, so a
    // failed hyprctl just leaves the screen's own ratio as the fallback.
    Process {
        id: scaleReader
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.compositorScale =
                    root.monitorScaleFor(text, root.activeScreen ? root.activeScreen.name : "")
            }
        }
    }

    // The folder shortcut's helper. Fire-and-forget: the file manager is its own
    // window, so there is nothing to read back.
    Process {
        id: folderOpener
        running: false
        command: []
    }

    // The reader reports above only cover a process that started. A command that
    // could not be spawned at all -- hyprctl missing -- fires neither the
    // collector nor onExited, so nothing would ever finish the run and
    // frameReading would stay true for the session, freezing the threshold and
    // blocking every later read. This watchdog closes that gap: it allows the
    // three commands what any of them could reasonably need, then writes off the
    // ones that never answered. A run that did answer has already cleared
    // frameReading by then, so the timer finds nothing to do.
    Timer {
        id: frameWatchdog
        interval: 4000
        repeat: false
        running: root.frameReading
        onTriggered: root.frameRunExpired()
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
    // The scale of the monitor the panel is on, matched by name for the same
    // reason as monitorWidthFor: on a mixed-scale desk the first entry is not
    // necessarily the screen this window opened on. Hyprland reports `scale` as
    // physical pixels per logical pixel, which is the number the divider quantum
    // is derived from. Zero means "not answered"; the panel then falls back to
    // the screen's own ratio.
    function monitorScaleFor(raw, name) {
        try {
            var list = JSON.parse(raw || "[]")
            if (!list || list.length === 0) return 0
            for (var i = 0; i < list.length; i++) {
                if (name !== "" && list[i].name === name && Number(list[i].scale) > 0)
                    return Number(list[i].scale)
            }
            if (Number(list[0].scale) > 0) return Number(list[0].scale)
        } catch (e) {
            // hyprctl missing / Hyprland not running: the fallback handles it.
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
    //
    // Album view borrows this pane even when the browser folds the cover back to
    // a floating corner. There it is a square beside a single centred column of
    // titles rather than a full-height pane, so it is capped at half the window
    // width: the titles are the content, and the cover should leave them room.
    // The last cap keeps a readable track list on a narrow window.
    readonly property int albumMinListWidth: Math.round(240 * prefs.uiScale)
    readonly property int albumCoverSize: {
        var room = window.width - root.albumMinListWidth
            - root.coverPad * 2
        return Math.max(Math.round(48 * prefs.uiScale),
            Math.min(root.paneHeight, Math.round(window.width * 0.50), room))
    }
    readonly property bool coverPaneShown: root.coverBand || root.albumView
    readonly property int paneCoverSize: root.coverPaneShown
        ? (root.albumView ? root.albumCoverSize
            : Math.max(Math.round(48 * prefs.uiScale),
                       Math.min(root.heroCover,
                                Math.round(window.width * 0.60))))
        : 0
    // Width of the artwork pane. With a margin (the padding setting on) the cover
    // is held in from the edges, so the pane spans that margin on each side plus
    // the rule strip on its inner edge. With no margin the cover runs flush to
    // both edges and rides over the rule, so the pane is sized to the cover alone
    // -- no strip reserved -- and the rule shows only above and below the art, as
    // if the cover had eaten the stretch it covers (see the CoverArt item below).
    readonly property int coverPaneWidth: root.coverPaneShown
        ? root.paneCoverSize + root.coverPad * 2
          + (prefs.coverPadding && !root.albumView ? root.coverPaneRule : 0)
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
    readonly property int trackArtGutter: root.coverPaneShown ? Math.round(8 * prefs.uiScale) : 0
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

    // Karaoke's cover, when it sits beside the lyrics: as tall as the reading
    // area, the way the artwork pane looks at full size. The width cap is the
    // same 60% the pane uses, so on a narrow window the cover gives way rather
    // than squeezing the lyrics into a sliver. The last cap is the one that
    // matters on a small panel: it keeps a readable text column instead of
    // letting the 60% share push the right margin past the left one.
    readonly property int karaokeMinTextWidth: Math.round(200 * prefs.uiScale)
    readonly property int karaokeCoverSize: Math.max(Math.round(48 * prefs.uiScale),
        Math.min(window.height - root.karaokeMargin * 2,
                 Math.round(window.width * 0.60),
                 window.width - root.karaokeMargin * 2 - root.karaokeCoverGap
                     - root.karaokeMinTextWidth))
    // The largest size the main cover can take in any view, so both of its Image
    // layers decode once and are scaled between placements instead of reloaded.
    // A reload blanks the picture for a frame or two, which is what flashed when
    // a view switch changed the cover's size -- the browser pane and karaoke's
    // side cover differ by a few pixels, and that was enough. A configured
    // placement that is not showing still counts, because a key can switch to it
    // at any moment. The background placement is the one non-square case: it
    // fills the window, so it sets the bounds itself.
    readonly property int coverDecodeBoundWidth: Math.max(
        root.heroCover, root.albumCoverSize, root.karaokeCoverSize,
        root.floatingCoverSize,
        prefs.karaokeCover === "background" ? window.width : 0)
    readonly property int coverDecodeBoundHeight: Math.max(
        root.heroCover, root.albumCoverSize, root.karaokeCoverSize,
        root.floatingCoverSize,
        prefs.karaokeCover === "background" ? window.height : 0)
    // The reading surface's margin, shared by the karaoke column and the side
    // cover so the text's edge and the art's edge line up.
    readonly property int karaokeMargin: Math.round(40 * prefs.uiScale)
    readonly property int karaokeCoverGap: Math.round(10 * prefs.uiScale)
    // The side cover's width plus the gap before the text. Reserved as a right
    // margin so the lyrics centre in the room left over, which is what moves
    // them left rather than letting the art sit on top of a line.
    readonly property int karaokeTextRightInset: root.karaokeCoverSide
        ? root.karaokeCoverSize + root.karaokeCoverGap : 0

    // Height of the now-playing strip. Named because two overlays sit clear of it
    // and have to agree with it: the typeahead readout and the MPD error banner.
    // They used to each repeat the number, which is how a change to the strip's
    // height would have left the error banner sitting on top of it.
    readonly property int stripHeight: Math.round(84 * prefs.uiScale)

    // The strip tightens in two steps before the title runs out of room. The
    // transport keeps a fixed footprint, so a narrow panel is paid for by the
    // text beside it: first the margins and volume track give some back, then
    // the volume track goes and the speaker alone stays for mute. Thresholds are
    // logical widths scaled with the interface, because the text grows with it.
    readonly property bool stripCompact: window.width < Math.round(700 * prefs.uiScale)
    readonly property bool stripTight: window.width < Math.round(560 * prefs.uiScale)

    // ---- selection ----
    property string pane: "artists"
    property int artistIndex: 0
    property int albumIndex: 0
    property int trackIndex: 0

    // ---- lyrics view (Alt+L) ----
    property bool lyricsView: false
    property string lyricsText: ""
    property var lyricsLines: []
    property int currentLyricLine: -1
    property string lyricsFileKey: ""
    // The file the running helper was started for. A stopped helper can still
    // emit an empty result; without this an in-flight fetch for the previous
    // track could wipe the lyrics a local hit just put on screen.
    property string lyricsProcessKey: ""
    // True from the moment a helper is started until its stdout stream has
    // ended. `running` turns false slightly before the stream's final data is
    // delivered, so it cannot be used to decide whether a new run may start.
    property bool lyricsStreamActive: false
    // The run waiting for the previous helper to finish. A Process cannot be
    // re-pointed at a new command while the old stream is still delivering, so
    // the next request is held here and started from onStreamFinished.
    property var lyricsPending: null
    property bool lyricsLoading: false
    // True only once a lookup has taken long enough to be worth announcing.
    // A cache or sidecar hit, or embedded lyrics read quickly, goes straight to
    // the text instead of flashing "Looking for lyrics…" first.
    property bool lyricsSearching: false
    // Follow the current line until the reader scrolls away. A manual scroll
    // pauses following for a few seconds rather than fighting the wheel.
    property bool lyricsFollowPaused: false
    // Karaoke presentation: the lyrics view with the browser's chrome gone and
    // the text set large. Alt+K toggles it in the open player, the way Alt+L
    // toggles the lyrics view; Esc leaves it for the browser.
    property bool karaokeView: false
    // Album view: the playing album's tracks on the left and its cover on the
    // right. It reuses the browser's selection, so j/k, typeahead and Enter keep
    // working; entering the view snaps that selection to the playing album.
    property bool albumView: false
    // The one view that is showing. The three flags above are alternatives, not
    // layers: entering one clears the other two. Named here so a mode key can
    // tell "switch to this view" from "its key again leaves for the browser".
    readonly property string viewName: root.albumView ? "album"
        : root.karaokeView ? "karaoke"
        : root.lyricsView ? "lyrics" : "browser"
    readonly property int lyricsScrollStep: Math.max(1, Math.round(48 * prefs.uiScale))

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

    // The album view's identity. It is read from the selected album rather than
    // from `mpd.current`, so the surface still has a name when nothing is
    // playing; entering album view snaps the selection to the playing album when
    // there is one, which is what keeps the two in step.
    readonly property var albumViewAlbum: albumIndex >= 0 && albumIndex < albumList.length
        ? albumList[albumIndex] : null
    readonly property string albumViewTitle: root.albumViewAlbum
        ? (root.albumViewAlbum.name || "") : ""
    readonly property string albumViewDetail: {
        var album = root.albumViewAlbum
        if (!album) return ""
        var parts = []
        var artist = root.artistList[root.artistIndex]
        if (artist && artist.name) parts.push(artist.name)
        if (album.year) parts.push(String(album.year))
        var tracks = album.tracks || []
        var total = 0
        for (var i = 0; i < tracks.length; i++) total += Number(tracks[i].duration) || 0
        var running = root.formatAlbumDuration(total)
        if (running !== "") parts.push(running)
        return parts.join(" · ")
    }
    readonly property string albumViewEmptyText: {
        if (!root.mpd) return "Waiting for MPD…"
        if (!root.mpd.connected)
            return root.mpd.everConnected ? "Reconnecting to MPD…" : "Waiting for MPD…"
        if (!root.mpd.libraryLoaded) return "Loading library…"
        if (root.albumList.length === 0) return "No albums by this artist"
        return "No tracks in this album"
    }

    // The now-playing strip's second line when nothing is playing. It answers
    // "why is this empty?" in the same voice as the panes, instead of repeating
    // the connection banner.
    readonly property string idleSubtitle: {
        if (!root.mpd) return "Waiting for MPD…"
        if (!root.mpd.connected)
            return root.mpd.everConnected ? "Reconnecting to MPD…" : "Waiting for MPD…"
        if (!root.mpd.libraryLoaded) return "Loading library…"
        return "Select an album and press Enter"
    }

    // The album that follows the playing one in the library, for album view's
    // small "up next" preview above the bar. Null at the end of the library,
    // and while shuffle or repeat is on: neither walks past the current album
    // in tree order, so a preview would promise an album the queue never plays.
    readonly property var upNextAlbum: {
        if (!prefs.upNextCover || !root.albumView) return null
        if (!mpd || !mpd.current || !mpd.current.file) return null
        if (mpd.shuffleMode !== 0 || mpd.repeatMode !== 0) return null
        var locations = mpd.trackLocations
        var loc = locations ? locations[String(mpd.current.file)] : null
        if (!loc) return null
        var artists = root.artistList
        for (var a = loc.artist; a < artists.length; a++) {
            var albums = artists[a].albums
            var first = a === loc.artist ? loc.album + 1 : 0
            if (first < albums.length) return albums[first]
        }
        return null
    }
    readonly property var upNextSubject: {
        var album = root.upNextAlbum
        if (!album || !album.tracks || album.tracks.length === 0) return null
        return { file: album.tracks[0].file, song: album.tracks[0] }
    }

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
        if (!keepSelection && albumView) syncAlbumView()
        settingsOpen = false
        settingsEditMode = false
        helpOpen = false
        // The tag editor is modal and its fields would otherwise hold a set of
        // songs picked in a previous summon, with the panel's key catcher still
        // disabled because tagOpen was left true.
        tagOpen = false
        tagSongs = []
        // A summon is a fresh start: a half-typed jump or a transport notice
        // from the last time the panel was up must not appear over the new
        // session. Stop the timers too, so they do not fire into this one.
        typeaheadTimer.stop()
        clearTypeahead()
        transportNoticeTimer.stop()
        transportNoticeVisible = false
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
        // The view is a mode of the panel, not a property of this summon: the
        // next open comes back to whichever of browser, lyrics, karaoke or
        // album was showing when it was put away.
    }

    // Alt+L, Alt+K and Alt+A. Each key selects its own view from any other, and
    // pressing the key of the view already showing returns to the browser, so
    // the three modes are siblings rather than layers. The modal cards close on
    // the way in -- they cannot stay in front of a full-window surface -- and
    // album view snaps the selection to the playing record so its track list
    // has something to show.
    function toggleView(name) {
        var next = root.viewName === name ? "browser" : name
        root.settingsOpen = false
        root.settingsEditMode = false
        root.helpOpen = false
        root.albumView = next === "album"
        root.karaokeView = next === "karaoke"
        root.lyricsView = next === "lyrics" || next === "karaoke"
        if (root.albumView) root.syncAlbumView()
    }

    // ---- activation ----

    // Playing means "this track in the context of its album, then everything
    // below the album in the order shown". The service keeps the album's earlier
    // tracks in the queue behind the play position, so Previous can walk back up
    // the record; nothing here has to remember the queue.
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
    //
    // Whitespace is dropped from both the buffer and the names: space is the
    // play/pause key, so a multi-word title could otherwise never be typed past
    // its first word ("The Twilight Sad" could only be reached as "the").
    //
    // In the tracks pane a numeric buffer is tried as a track number first, so
    // "12" reaches track 12 without having to type the title. A title that
    // starts with digits remains reachable: when no track number matches, the
    // same buffer falls through to the name search below.
    property string typeaheadBuffer: ""
    // One lowercased name list per pane, built the first time that pane is
    // searched and dropped when its list changes. Rebuilding all three on every
    // change walked the whole library each time the caret moved to another
    // artist (which replaces the album and track lists), for an index only the
    // active pane would ever read.
    property var typeaheadIndex: ({ artists: null, albums: null, tracks: null })

    function typeaheadKey(text) {
        return String(text === undefined || text === null ? "" : text)
            .toLowerCase().replace(/\s+/g, "")
    }

    // The number a track row displays and type-to-find matches.
    function trackNumberKey(item) {
        if (!item || item.track === null || item.track === undefined) return ""
        return String(item.track)
    }

    // The number as the tracks pane writes it, padded to two digits so a column
    // of tracks lines up. The stored format chooses the separator only; a track
    // number that is already wider than two digits is left as it is.
    function trackNumberText(item) {
        if (!item || item.track === null || item.track === undefined) return "--"
        var n = String(item.track)
        if (n.length < 2) n = "0" + n
        return prefs.trackNumberFormat === "dash" ? n + " -" : n + "."
    }

    function trackIndexByNumber(buffer) {
        if (!/^\d+$/.test(buffer)) return -1
        // Typeahead can arrive padded ("01") to match the row, so compare the
        // number the buffer stands for rather than its exact text.
        var want = String(parseInt(buffer, 10))
        for (var i = 0; i < trackList.length; i++) {
            if (root.trackNumberKey(trackList[i]) === want) return i
        }
        return -1
    }

    function invalidateTypeahead(which) {
        if (which === "artists") root.typeaheadIndex.artists = null
        else if (which === "albums") root.typeaheadIndex.albums = null
        else root.typeaheadIndex.tracks = null
    }

    function typeaheadNames(which) {
        var cached = which === "artists" ? root.typeaheadIndex.artists
            : which === "albums" ? root.typeaheadIndex.albums
            : root.typeaheadIndex.tracks
        if (cached) return cached
        var out = []
        if (which === "artists") {
            for (var i = 0; i < artistList.length; i++) out.push(root.typeaheadKey(artistList[i].name))
            root.typeaheadIndex.artists = out
        } else if (which === "albums") {
            for (var j = 0; j < albumList.length; j++) out.push(root.typeaheadKey(albumList[j].name))
            root.typeaheadIndex.albums = out
        } else {
            for (var k = 0; k < trackList.length; k++) {
                var tr = trackList[k]
                out.push(root.typeaheadKey(tr.title || tr.file || ""))
            }
            root.typeaheadIndex.tracks = out
        }
        return out
    }

    function clearTypeahead() {
        typeaheadBuffer = ""
    }

    function handleTypeahead(ch) {
        if (!prefs.typeaheadSearch) return
        typeaheadBuffer = (typeaheadBuffer + ch).toLowerCase()
        typeaheadTimer.restart()
        var which = pane === "artists" ? "artists" : pane === "albums" ? "albums" : "tracks"
        var list = pane === "artists" ? artistList : pane === "albums" ? albumList : trackList
        // A number in the tracks pane is a jump to that track, before the title
        // search gets a chance to interpret it as the start of a name.
        if (pane === "tracks") {
            var byNumber = root.trackIndexByNumber(typeaheadBuffer)
            if (byNumber >= 0) {
                trackIndex = byNumber
                return
            }
        }
        var idx = typeaheadNames(which)
        // A list replaced without its change signal -- or by a length the cache
        // cannot tell apart -- falls back to one rebuild rather than searching
        // stale names.
        if (!idx || idx.length !== list.length) {
            invalidateTypeahead(which)
            idx = typeaheadNames(which)
        }
        for (var i = 0; i < list.length; i++) {
            var nameIdx = idx ? idx[i] : ""
            if (!nameIdx) {
                var item = list[i]
                if (pane === "artists") nameIdx = root.typeaheadKey(item.name)
                else if (pane === "albums") nameIdx = root.typeaheadKey(item.name)
                else nameIdx = root.typeaheadKey(item.title || item.file || "")
            }
            if (nameIdx.indexOf(typeaheadBuffer) === 0) {
                if (pane === "artists") selectArtist(i, false)
                else if (pane === "albums") selectAlbum(i, false)
                else trackIndex = i
                return
            }
        }
    }

    onArtistListChanged: root.invalidateTypeahead("artists")
    onAlbumListChanged: root.invalidateTypeahead("albums")
    onTrackListChanged: root.invalidateTypeahead("tracks")

    // ---- lyrics helpers ----
    //
    // One helper process answers the whole question for a track: embedded
    // lyrics, a .lrc/.txt beside the file, the ~/.lyrics cache, or a download
    // into that cache. It only runs while the view is open, so toggling Alt+L
    // is what fetches -- nothing downloads for tracks nobody is looking at.
    // Lyrics already on disk are read here first, so the helper is only started
    // for a track whose lyrics have to be extracted or fetched.
    readonly property string lyricsMusicDir: {
        if (root.mpd && root.mpd.musicDir) return String(root.mpd.musicDir)
        var dir = Quickshell.env("XDG_MUSIC_DIR")
        if (dir) return String(dir)
        var home = Quickshell.env("HOME")
        return (home ? String(home) : "") + "/Music"
    }

    // fetch_lyrics.py, resolved beside this file so the plugin stays portable.
    // Quickshell serves its files under qs://, so the scheme is stripped to
    // leave the plain path python3 can open.
    readonly property string lyricsScript: {
        var url = String(Qt.resolvedUrl("fetch_lyrics.py"))
        var path = url.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "")
        try { path = decodeURIComponent(path) } catch (e) {}
        return path
    }

    // extras/open_folder.sh, resolved the same way. It owns the file-manager
    // fallbacks (Flea, Nautilus, FileManager1, xdg-open) so this file only has
    // to name a directory and a file to select.
    readonly property string folderScript: {
        var url = String(Qt.resolvedUrl("extras/open_folder.sh"))
        var path = url.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "")
        try { path = decodeURIComponent(path) } catch (e) {}
        return path
    }

    // The deepest directory a set of directories shares. Used for an artist,
    // which has no single album folder: in a normal library this is the artist
    // folder, and it falls back to the music root when the artist's albums are
    // scattered.
    function sharedDir(dirs) {
        if (dirs.length === 0) return ""
        var parts = String(dirs[0]).split("/")
        for (var i = 1; i < dirs.length; i++) {
            var other = String(dirs[i]).split("/")
            var n = 0
            while (n < parts.length && n < other.length && parts[n] === other[n]) n++
            parts = parts.slice(0, n)
            if (parts.length === 0) return "/"
        }
        return parts.join("/") || "/"
    }

    // What the folder shortcut opens for a row: the directory, plus the file to
    // select when the row is a track. The shell script folds a cue album's
    // virtual track back onto the cue sheet, which is the file that exists.
    function folderTarget(pane, index) {
        if (!root.mpd) return null
        var music = String(root.mpd.musicDir || "")
        if (music === "") return null

        if (pane === "tracks") {
            var track = index >= 0 && index < root.trackList.length ? root.trackList[index] : null
            if (!track) return null
            return {
                dir: music + "/" + root.mpd.albumDirOf(track.file),
                select: music + "/" + track.file
            }
        }

        if (pane === "albums") {
            var album = index >= 0 && index < root.albumList.length ? root.albumList[index] : null
            if (!album || !album.tracks || album.tracks.length === 0) return null
            return { dir: music + "/" + root.mpd.albumDirOf(album.tracks[0].file), select: "" }
        }

        var artist = index >= 0 && index < root.artistList.length ? root.artistList[index] : null
        if (!artist || !artist.albums || artist.albums.length === 0) return null
        var dirs = []
        for (var i = 0; i < artist.albums.length; i++) {
            var tracks = artist.albums[i].tracks
            if (tracks && tracks.length > 0)
                dirs.push(music + "/" + root.mpd.albumDirOf(tracks[0].file))
        }
        return dirs.length === 0 ? null : { dir: root.sharedDir(dirs), select: "" }
    }

    function openFolder(pane, index) {
        var target = root.folderTarget(pane, index)
        if (!target || target.dir === "") return
        folderOpener.command = target.select !== ""
            ? [root.folderScript, target.dir, target.select]
            : [root.folderScript, target.dir]
        folderOpener.running = true
    }

    function clearLyrics() {
        root.lyricsText = ""
        root.lyricsLines = []
        root.currentLyricLine = -1
    }

    // The shared cache the helper writes downloads into.
    readonly property string lyricsHome: (Quickshell.env("HOME") || "") + "/.lyrics"

    // Mirrors safe_name() in fetch_lyrics.py: a tag value as the filename the
    // helper would have used.
    function lyricsSafeName(name) {
        var s = String(name === undefined || name === null ? "" : name)
        s = s.replace(/[/\\\x00-\x1f]+/g, "-")
        s = s.replace(/\s+/g, " ")
        s = s.replace(/^[ .]+/, "").replace(/[ .]+$/, "")
        return s || "Unknown"
    }

    // Mirrors cache_paths() in the helper: the cache stem (no extension) for
    // the title as MPD gives it, then for the title without a trailing
    // parenthetical, which covers earlier runs that filed a track under its
    // shorter name. Synced lyrics are saved as .lrc, plain ones as .txt.
    function lyricsCacheStems(artist, title) {
        var names = [String(title)]
        var short = String(title).replace(/\s*[\(\[][^\)\]]*[\)\]]\s*$/, "").trim()
        if (short && short !== String(title)) names.push(short)
        var stems = []
        for (var i = 0; i < names.length; i++) {
            var p = root.lyricsHome + "/" + root.lyricsSafeName(artist)
                    + " - " + root.lyricsSafeName(names[i])
            if (stems.indexOf(p) < 0) stems.push(p)
        }
        return stems
    }

    // Synchronous read through FileView. Clearing the path first matters:
    // text() keeps returning the last file that loaded when the next path does
    // not exist, which would turn a miss into a false hit.
    function readLyricsFile(path) {
        lyricsFile.path = ""
        lyricsFile.path = path
        return String(lyricsFile.text() || "")
    }

    // A .lrc/.txt beside the track, then the shared cache. Empty when the track
    // has nothing on disk and the helper has to run.
    function localLyricsFor(rel, artist, title) {
        var base = (root.lyricsMusicDir + "/" + rel).replace(/\.[^./]+$/, "")
        var text = root.readLyricsFile(base + ".lrc")
        if (!text) text = root.readLyricsFile(base + ".txt")
        if (!text && artist && title) {
            var stems = root.lyricsCacheStems(artist, title)
            for (var i = 0; i < stems.length && !text; i++) {
                text = root.readLyricsFile(stems[i] + ".lrc")
                if (!text) text = root.readLyricsFile(stems[i] + ".txt")
            }
        }
        return text
    }

    // Jump the scroll back to the top for a new track, and let following
    // resume; a reader who scrolled the previous song has moved on.
    function resetLyricsScroll() {
        lyricsScrollAnim.stop()
        lyricsFlick.contentY = 0
        root.lyricsFollowPaused = false
        lyricsFollowTimer.stop()
    }

    // The lyrics view's own presentation, read straight from prefs so a change
    // in the settings card lands without reopening the view.
    //
    // Karaoke overrides two of those settings: it always marks and follows the
    // current line (that is what karaoke means) and always centres the text.
    readonly property bool lyricsMarking: root.karaokeView || prefs.lyricsFollow !== "off"
    readonly property bool lyricsFollowing: root.karaokeView || prefs.lyricsFollow === "follow"
    readonly property int lyricsTextAlign: (root.karaokeView || prefs.lyricsAlign === "center")
        ? Text.AlignHCenter : Text.AlignLeft
    readonly property real lyricsDimOpacity: prefs.lyricsDim === "subtle" ? 0.85
        : (prefs.lyricsDim === "strong" ? 0.5 : 0.7)

    // The header above the lyrics. Both surfaces read the same metadata but each
    // decides how much of it to show: the reading view from lyricsInfo, karaoke
    // from karaokeInfo. The header sits outside the Flickable in both, so the
    // details stay put while the words scroll.
    readonly property string lyricsTrackTitle: (mpd && mpd.current && (mpd.current.Title || mpd.current.file))
        ? (mpd.current.Title || mpd.current.file) : ""
    readonly property string lyricsTrackArtist: (mpd && mpd.current && (mpd.current.Artist || mpd.current.AlbumArtist))
        ? (mpd.current.Artist || mpd.current.AlbumArtist) : ""
    readonly property string lyricsTrackAlbum: (mpd && mpd.current && mpd.current.Album)
        ? mpd.current.Album : ""
    readonly property bool lyricsHeaderTitleVisible: root.karaokeView
        ? prefs.karaokeInfo !== "off"
        : prefs.lyricsInfo !== "off"
    readonly property bool lyricsHeaderArtistVisible: (root.karaokeView
        ? (prefs.karaokeInfo === "both" || prefs.karaokeInfo === "all")
        : prefs.lyricsInfo === "both") && root.lyricsTrackArtist !== ""
    readonly property bool lyricsHeaderAlbumVisible: root.karaokeView
        && prefs.karaokeInfo === "all" && root.lyricsTrackAlbum !== ""
    // Karaoke reads its header from further away, so its type is a little larger
    // than the reading view's; the ratio keeps the same hierarchy between rows.
    readonly property real lyricsHeaderScale: root.karaokeView ? 1.25 : 1

    // Relative luminance and the WCAG contrast ratio between two colours.
    // Palette.derive guarantees the accent at least 3:1 against the ground,
    // which on a near-white sleeve still reads as a faint tint; the highlight is
    // text, so it wants the 4.5:1 a reader's eye expects.
    function relativeLuminance(c) {
        function linear(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }
    function contrastRatio(a, b) {
        var la = root.relativeLuminance(a)
        var lb = root.relativeLuminance(b)
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05)
    }

    // The current line's colour. The cover accent is used when it is readable
    // on the panel's ground; otherwise the foreground ink takes over, so a
    // white sleeve gets a dark bold line instead of a pale accent one.
    readonly property color lyricsHighlightColor: root.contrastRatio(theme.accent, theme.background) >= 4.5
        ? theme.accent : theme.foreground

    // The reading column's width inside the flickable. "wide" and "narrow" cap
    // the measure and the column is centred, so a long line does not run the
    // full width of a large window. Karaoke uses the whole width; its margins
    // are what keep the line off the window edges.
    //
    // This reads the layout's width rather than the flickable's: the flickable's
    // width is what this property feeds (through the column and the header
    // rows), so asking the flickable would close a loop that leaves the text at
    // its old full width when the side cover appears.
    readonly property real lyricsColumnWidth: root.karaokeView
        ? lyricsLayout.width
        : (prefs.lyricsWidth === "wide"
            ? lyricsLayout.width * 0.8
            : (prefs.lyricsWidth === "narrow" ? lyricsLayout.width * 0.65 : lyricsLayout.width))
    // Whether the cover shares the reading view with the lyrics, and whether it
    // does so beside them (the browser's artwork pane) or in karaoke's own
    // placement. Only the lyrics view is affected; the browser keeps whatever
    // arrangement it had. The two placements have separate settings: the side
    // pane follows Cover beside lyrics, karaoke its own choice.
    readonly property bool lyricsSideCoverVisible: !(root.lyricsView
        && (prefs.lyricsCover === "hide" || root.karaokeView))
    readonly property bool karaokeCoverSide: root.karaokeView
        && prefs.karaokeCover === "side"
    readonly property bool karaokeCoverBackground: root.karaokeView
        && prefs.karaokeCover === "background"
    readonly property bool karaokeCoverVisible: root.karaokeCoverSide
        || root.karaokeCoverBackground
    readonly property bool lyricsCoverVisible: root.lyricsSideCoverVisible || root.karaokeCoverVisible
    // Lyric type. Karaoke has its own offset, so enlarging the words there does
    // not also enlarge the reading view; the 1.9 multiplier is what makes karaoke
    // read from across the room, and it applies on top of whichever size is in
    // charge.
    readonly property int lyricsFontPx: Math.round((root.themeFont.body
        + (root.karaokeView ? prefs.karaokeFont : prefs.lyricsFont))
        * (root.karaokeView ? 1.9 : 1) * prefs.uiScale)

    // A manual scroll suspends following. With "Never" it stays suspended until
    // the track changes or the view is reopened; otherwise the timer brings the
    // view back to the playing line after the configured wait.
    function pauseLyricsFollow() {
        // Only following has an automatic scroll to suppress.
        if (!root.lyricsFollowing) return
        root.lyricsFollowPaused = true
        if (prefs.lyricsResume > 0) lyricsFollowTimer.restart()
        else lyricsFollowTimer.stop()
    }

    // Keep the highlighted line in the middle of the view. Called when the
    // playback timer moves the highlight, and again when a paused reader lets
    // following resume. Only "follow" (and karaoke, which always follows)
    // scrolls: "highlight" marks the line in place, and "off" does not track it.
    function scrollToCurrentLyric() {
        if (!root.lyricsView || !root.lyricsFollowing) return
        if (root.lyricsFollowPaused) return
        if (root.currentLyricLine < 0) return
        var item = lyricsRepeater.itemAt(root.currentLyricLine)
        if (!item) return
        var max = Math.max(0, lyricsFlick.contentHeight - lyricsFlick.height)
        var target = item.y - (lyricsFlick.height - item.height) / 2
        target = Math.max(0, Math.min(target, max))
        if (Math.abs(target - lyricsFlick.contentY) < 2) return
        lyricsScrollAnim.stop()
        lyricsScrollAnim.from = lyricsFlick.contentY
        lyricsScrollAnim.to = target
        lyricsScrollAnim.start()
    }

    // Keyboard scrolling. Any manual movement pauses following for a few
    // seconds, so the next line change does not yank the text away.
    function scrollLyricsBy(delta) {
        var max = Math.max(0, lyricsFlick.contentHeight - lyricsFlick.height)
        lyricsScrollAnim.stop()
        lyricsFlick.contentY = Math.max(0, Math.min(lyricsFlick.contentY + delta, max))
        root.pauseLyricsFollow()
    }

    function scrollLyricsToEdge(edge) {
        var max = Math.max(0, lyricsFlick.contentHeight - lyricsFlick.height)
        lyricsScrollAnim.stop()
        lyricsFlick.contentY = edge === 0 ? 0 : max
        root.pauseLyricsFollow()
    }

    function parseLyrics(text) {
        var lines = String(text === undefined || text === null ? "" : text).replace(/\r\n/g, "\n").replace(/\r/g, "\n").split("\n")
        var out = []
        // [mm:ss.xx], and the [mm:ss:xx] spelling some writers emit. A third
        // fraction digit means milliseconds rather than hundredths.
        var re = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g
        // A line that is nothing but LRC metadata tags -- [ar:], [ti:],
        // [offset:] -- is not lyrics. Without this it would fall through to the
        // plain-text branch and be printed verbatim. Bracket words in plain
        // files, like a "[Chorus]" heading, are left alone.
        var metaOnly = /^(?:\[(?:ar|al|ti|au|by|re|ve|length|offset|tool):[^\]]*\]\s*)+$/i
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i]
            re.lastIndex = 0
            var m
            var times = []
            while ((m = re.exec(l)) !== null) {
                var mm = parseInt(m[1]) || 0
                var ss = parseInt(m[2]) || 0
                var frac = m[3] !== undefined ? m[3] : "0"
                var part = frac.length === 1 ? parseInt(frac) / 10
                        : frac.length === 2 ? parseInt(frac) / 100
                        : parseInt(frac.substring(0, 3)) / 1000
                times.push(mm * 60 + ss + (part || 0))
            }
            if (times.length === 0) {
                var t = l.trim()
                if (t !== "" && !metaOnly.test(t)) out.push({ time: -1, text: t, order: out.length })
                continue
            }
            var content = l.replace(/\[[^\]]*\]/g, "").trim()
            if (content === "") continue
            for (var ti = 0; ti < times.length; ti++) {
                out.push({ time: times[ti], text: content, order: out.length })
            }
        }
        // Timed lines first, then plain text. The original position breaks ties:
        // a plain file has no times at all, and an unstable sort would otherwise
        // be free to shuffle every line.
        out.sort(function (a, b) {
            if (a.time < 0 && b.time < 0) return a.order - b.order
            if (a.time < 0) return 1
            if (b.time < 0) return -1
            if (a.time === b.time) return a.order - b.order
            return a.time < b.time ? -1 : 1
        })
        return out
    }

    // MPD's current song, as the helper's fallback tags. The file's own tags
    // are authoritative and the script reads them; these only cover a track it
    // cannot read (a cue sheet, or an untagged file MPD named from its path).
    function lyricsTag(key) {
        var cur = root.mpd && root.mpd.current ? root.mpd.current : null
        var value = cur ? cur[key] : ""
        return value === undefined || value === null ? "" : String(value)
    }

    function loadLyricsFor(file) {
        var rel = String(file === undefined || file === null ? "" : file)
        root.lyricsFileKey = rel
        root.lyricsLoading = false
        root.clearLyrics()
        root.resetLyricsScroll()
        if (!root.lyricsView || rel === "") {
            root.stopLyricsRun()
            return
        }

        var artist = root.lyricsTag("Artist") || root.lyricsTag("AlbumArtist")
        var title = root.lyricsTag("Title")
        var album = root.lyricsTag("Album")
        var duration = root.lyricsTag("duration") || root.lyricsTag("Time")
        if (!title) {
            var name = rel.split("/").pop() || ""
            var dot = name.lastIndexOf(".")
            if (dot > 0) name = name.substring(0, dot)
            title = name.replace(/^\d+[\s.\-_]+/, "")
        }
        if (!artist && rel.indexOf("/") >= 0) artist = rel.split("/")[0]

        // A reload for the next track must not be answered by the process
        // still running for the previous one. A Process cannot be re-pointed
        // while its old stream is still delivering, so the old helper is
        // stopped and this request waits in lyricsPending for its finish.
        // Clearing the key first means the dying run's output can never be
        // read as the new run's.
        var defer = root.lyricsStreamActive || root.lyricsPending !== null
        if (defer) {
            root.lyricsProcessKey = ""
            root.lyricsPending = null
            if (lyricsProcess.running) lyricsProcess.running = false
        }
        lyricsTimeout.stop()
        lyricsSearchTimer.stop()
        root.lyricsSearching = false

        // Already on disk: show it now instead of spawning python just to read
        // the same file back.
        var local = root.localLyricsFor(rel, artist, title)
        if (local) {
            root.lyricsText = local
            root.lyricsLines = root.parseLyrics(local)
            root.currentLyricLine = -1
            return
        }

        root.lyricsLoading = true
        var command = ["python3", root.lyricsScript,
            "--music-dir", root.lyricsMusicDir,
            "--file", rel,
            "--artist", artist,
            "--title", title,
            "--album", album,
            "--duration", duration]
        // "Fetch lyrics" off keeps the helper to local files only: embedded
        // tags, sidecars and the cache, with no request to lrclib.
        if (!prefs.lyricsDownloads) command.push("--offline")
        if (defer) {
            root.lyricsPending = { file: rel, command: command }
            // Covers a killed helper whose stream never finishes: without it
            // the queued request would wait forever behind a dead process.
            lyricsTimeout.restart()
            return
        }
        root.startLyricsRun(rel, command)
    }

    // Starts the one helper run, or the run queued behind a stopped one. The
    // timers belong to the run that is actually executing, so they are started
    // here rather than at request time.
    function startLyricsRun(rel, command) {
        root.lyricsProcessKey = rel
        root.lyricsStreamActive = true
        lyricsProcess.command = command
        lyricsProcess.running = true
        lyricsTimeout.restart()
        // Announce the lookup only if it is slow. A quick hit should go
        // straight to the text rather than flash a message first.
        lyricsSearchTimer.restart()
    }

    // Forgets the current run and any queued one. Used when the view closes or
    // there is no track to look up: a helper has no reason to keep running for
    // lyrics nobody is looking at.
    //
    // A terminating process keeps lyricsStreamActive set until its stream has
    // actually finished. Clearing that here would let the next track start into
    // the gap, and the old stream's finish would then look like the new run's.
    function stopLyricsRun() {
        root.lyricsPending = null
        root.lyricsProcessKey = ""
        if (lyricsProcess.running) lyricsProcess.running = false
        else root.lyricsStreamActive = false
        lyricsTimeout.stop()
        lyricsSearchTimer.stop()
        root.lyricsSearching = false
    }

    // ---- settings ----
    //
    // The card owns no state of its own beyond which setting is under the caret;
    // opening it always starts at the top so the muscle memory for "the first
    // thing" survives having scrolled somewhere else last time.
    //
    // settingIndex is an index into prefs.visibleEntries -- the settings the card
    // is showing. Every entry is in that list now, greyed ones included, so the
    // index numbers every row on the card. Up/down walks the caret down its own
    // column (stepping over greyed rows), left/right crosses to the neighbouring
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

    // Up/down walks the rows of the visible tab, wrapping at its ends. A greyed
    // row is still a row: the caret can hold it, and Enter or a click simply
    // refuses to change it, so stepping never skips over a block of settings and
    // dead-ends on a row that looks like there is more below it.
    function moveSettingRows(delta) {
        if (!settingsOpen) return
        var step = delta < 0 ? -1 : 1
        var loader = settingsLoader.item
        if (!loader || !prefs.columns) return
        var cat = loader.categoryIndex || 0
        var items = prefs.columns[cat] ? prefs.columns[cat].items : []
        if (items.length === 0) return
        var idx = -1
        for (var i = 0; i < items.length; i++) {
            if (items[i].index === settingIndex) { idx = i; break }
        }
        idx = idx < 0 ? 0 : (idx + step + items.length) % items.length
        settingIndex = items[idx].index
        settingsEditMode = false
    }

    // Left/right cross the tabs, landing on the row the caret last held there
    // (or the tab's first row on a first visit). The card derives its visible
    // tab from the caret, so moving the caret is all that is needed.
    function moveSettingColumns(delta) {
        if (!settingsOpen) return
        var cols = prefs.columns || []
        if (cols.length === 0) return
        var loader = settingsLoader.item
        var cat = loader ? (loader.categoryIndex || 0) : prefs.columnOf(settingIndex)
        var c = cat + (delta < 0 ? -1 : 1)
        if (c < 0) c = cols.length - 1
        if (c >= cols.length) c = 0
        var items = cols[c].items || []
        if (items.length > 0) {
            var row = loader ? (loader.columnRow[c] || 0) : 0
            var target = items[Math.max(0, Math.min(row, items.length - 1))]
            settingIndex = target.index
        }
        settingsEditMode = false
    }

    // Every entry now stays in the card, so the list the caret indexes into is
    // fixed for the life of the panel and the index cannot drift on its own. A
    // dependent that goes inactive only greys: the row stays, the caret stays on
    // it, and the row simply refuses to be edited, which is why nothing jumps.
    //
    // What is left to guard is the list itself changing length, which can only
    // happen when the table is edited while the shell is running. The caret
    // re-finds its row by key when that happens, and clamps to its previous index
    // when the key is gone. settingIndexBefore is the index from before the
    // change, since the handler runs once the list has already reshaped.
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

    // Album view is a view of the playing record, so entering it -- and every
    // track change while it is up -- snaps the browser's selection to the
    // playing album. Keeping one selection rather than a second copy is what
    // lets the existing move/typeahead/activate paths work unchanged there.
    // Nothing playing leaves the current selection alone, so the view still has
    // an album to show.
    function syncAlbumView() {
        pane = "tracks"
        // Read the current song and the location map directly: this runs from
        // onCurrentChanged, where a dependent binding may not have been
        // re-evaluated yet and would still hand back the previous track.
        if (!root.mpd || !root.mpd.current || !root.mpd.current.file) return
        var locations = root.mpd.trackLocations
        var loc = locations ? locations[root.mpd.current.file] : null
        if (!loc) return
        if (loc.artist < 0 || loc.artist >= root.artistList.length) return
        var albums = root.artistList[loc.artist].albums
        if (loc.album < 0 || loc.album >= albums.length) return
        if (loc.track < 0 || loc.track >= albums[loc.album].tracks.length) return
        artistIndex = loc.artist
        albumIndex = loc.album
        trackIndex = loc.track
    }

    // h/l and the left/right arrows walk the panes, matching ncmpcpp's
    // previous_column/next_column. The ends are stops rather than wrap-arounds:
    // l on the last pane is a no-op, and there is nowhere further right to go.
    function shiftPane(delta) {
        // Album view has a single column; there is no pane to walk to.
        if (root.albumView) return
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
    // Latches the first open so the tag editor is built then and kept, rather
    // than on every summon (see tagEditorLoader).
    property bool tagEditorLoaded: false

    onTagOpenChanged: if (tagOpen) tagEditorLoaded = true

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

    // Seek to an absolute position, for the lyric lines (which carry a time in
    // seconds). Routed through seekToFraction so the bar re-anchors and clamps
    // exactly as it does for a click on the progress bar.
    function seekToSeconds(seconds) {
        if (!(duration > 0)) return -1
        return root.seekToFraction(seconds / duration)
    }

    Connections {
        target: root.mpd
        function onStatusChanged() {
            root.reanchor()
        }
        function onCurrentChanged() {
            root.reanchor()
            if (root.albumView) root.syncAlbumView()
            if (root.lyricsView) {
                var f = root.mpd && root.mpd.current ? root.mpd.current.file : ""
                root.loadLyricsFor(f)
            }
        }
        // A database event rebuilds and re-sorts the tree, so an index that was in
        // range a moment ago can point past the end. Clamp it here rather than
        // leaving an empty pane (and, for the artist index, an activation that
        // resolves to no files) until the caret is next moved.
        function onArtistsChanged() {
            // The whole tree was replaced, so every pane's cached names are stale.
            root.invalidateTypeahead("artists")
            root.invalidateTypeahead("albums")
            root.invalidateTypeahead("tracks")
            if (root.artistIndex >= root.artistList.length)
                root.selectArtist(Math.max(0, root.artistList.length - 1), false)
            else if (root.albumIndex >= root.albumList.length)
                root.selectAlbum(Math.max(0, root.albumList.length - 1), false)
            else if (root.trackIndex >= root.trackList.length)
                root.trackIndex = Math.max(0, root.trackList.length - 1)
            if (root.albumView) root.syncAlbumView()
        }
        // The service owns the repeat policy and holds no reference to the config,
        // so persisting the mode is the panel's half of the arrangement.
        function onRepeatModeSelected(mode) {
            prefs.setRepeatMode(mode)
        }
        // Same arrangement for the shuffle scope, which the service also owns.
        function onShuffleModeSelected(mode) {
            prefs.setShuffleMode(mode)
        }
    }

    onLyricsViewChanged: {
        if (lyricsView) {
            var f = root.mpd && root.mpd.current ? root.mpd.current.file : ""
            root.loadLyricsFor(f)
        } else {
            root.lyricsText = ""
            root.lyricsLines = []
            root.currentLyricLine = -1
            root.lyricsLoading = false
            // No view, no reason for the helper to keep fetching. This also
            // drops a request queued behind it.
            root.stopLyricsRun()
            root.lyricsFollowPaused = false
            lyricsFollowTimer.stop()
            lyricsScrollAnim.stop()
        }
    }

    onCurrentLyricLineChanged: root.scrollToCurrentLyric()

    // Entering karaoke should pick up the playing line at once, not wait for
    // the next line change. The lyrics may still be loading, in which case the
    // first current-line update does it.
    onKaraokeViewChanged: {
        if (!root.karaokeView) return
        root.lyricsFollowPaused = false
        root.scrollToCurrentLyric()
    }

    // A cheat sheet is read from the top: a sheet left scrolled at the bottom
    // from last time would open on the tail of the list.
    onHelpOpenChanged: {
        if (root.helpOpen) helpView.scrollToEdge(0)
    }

    function formatTime(seconds) {
        if (!seconds || seconds < 0) return "0:00"
        var total = Math.floor(seconds)
        var h = Math.floor(total / 3600)
        var m = Math.floor((total % 3600) / 60)
        var s = total % 60
        return (h > 0 ? h + ":" + (m < 10 ? "0" : "") + m : m) + ":" + (s < 10 ? "0" : "") + s
    }

    // A running time for the album header, in the shape people say it rather
    // than the seek bar's clock: "48 min", or "1 hr 12 min". Returns "" for an
    // album MPD has no durations for, so the header simply omits that part.
    function formatAlbumDuration(seconds) {
        var total = Math.floor(Number(seconds) || 0)
        if (total <= 0) return ""
        var minutes = Math.round(total / 60)
        if (minutes < 60) return minutes + " min"
        var h = Math.floor(minutes / 60)
        var m = minutes % 60
        return m === 0 ? h + " hr" : h + " hr " + m + " min"
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

                    visible: !root.lyricsView && !root.albumView
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
                    renderScale: root.renderScale
                    activePane: root.pane
                    artistList: root.artistList
                    albumList: root.albumList
                    trackList: root.trackList
                    artistIndex: root.artistIndex
                    albumIndex: root.albumIndex
                    trackIndex: root.trackIndex
                    connected: root.mpd ? root.mpd.connected : false
                    libraryLoaded: root.mpd ? root.mpd.libraryLoaded : false
                    everConnected: root.mpd ? root.mpd.everConnected : false

                    artistLabel: function (item) { return item.name }
                    albumLabel: function (item) { return root.albumText(item.year, item.name) }
                    trackNumber: function (item) { return root.trackNumberText(item) }
                    trackNumberMuted: prefs.trackNumberMuted
                    trackLabel: function (item) { return item.title || "Untitled" }
                    trackSublabel: function (item) { return root.formatTime(item.duration) }
                    playingMarkerSides: prefs.playingMarkerSides
                    trackArtGutter: root.trackArtGutter
                    isCurrent: prefs.playingHighlight ? function (item) {
                        return root.mpd && root.mpd.current && item.file === root.mpd.current.file
                    } : null

                    onArtistActivated: function (index) { root.selectArtist(index, true) }
                    onAlbumActivated: function (index) { root.selectAlbum(index, true) }
                    onTrackActivated: function (index) { root.selectTrack(index) }
                    onFolderRequested: function (pane, index) { root.openFolder(pane, index) }
                }

                // Album view's own surface: a single centred column of titles,
                // with the cover in the pane to its right. It is not a PaneRow
                // with two panes hidden -- the browser's numbers, durations,
                // heading and rules have no place here.
                AlbumView {
                    id: albumTrackView
                    visible: root.albumView
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Math.max(0, parent.width - root.coverPaneWidth)
                    theme: theme
                    prefs: prefs
                    model: root.trackList
                    currentIndex: root.trackIndex
                    albumTitle: root.albumViewTitle
                    albumDetail: root.albumViewDetail
                    showCaption: prefs.albumCaption
                    emptyText: root.albumViewEmptyText
                    isCurrent: prefs.playingHighlight ? function (item) {
                        return root.mpd && root.mpd.current && item.file === root.mpd.current.file
                    } : null
                    titleFor: function (item) { return item.title || "Untitled" }
                    playingColor: root.lyricsHighlightColor
                    // A click in album view is a play, not just a selection:
                    // this is a now-playing surface, so the first click should
                    // start the track rather than leave it waiting for Enter.
                    onActivated: function (index) {
                        root.selectTrack(index)
                        root.activate()
                    }
                    onFolderRequested: function (index) { root.openFolder("tracks", index) }
                }

                Item {
                    id: lyricsViewArea
                    visible: root.lyricsView && !root.albumView
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    // With the cover hidden for this view the lyrics take the
                    // full width; otherwise they stop where the artwork pane
                    // begins, as the browser does. Karaoke never uses the
                    // browser's side pane: its own cover sits beside the text,
                    // behind it, or nowhere, and the column below reserves the
                    // room that placement needs.
                    width: Math.max(0, parent.width - (root.lyricsSideCoverVisible ? root.coverPaneWidth : 0))

                    Rectangle {
                        anchors.fill: parent
                        // A background cover is drawn behind this whole area, so
                        // the opaque ground has to step aside for it. The window's
                        // own colour is still underneath, which keeps the panel
                        // looking the same when an album has no art.
                        visible: !root.karaokeCoverBackground
                        color: theme.background
                    }

                    ColumnLayout {
                        id: lyricsLayout
                        anchors.fill: parent
                        anchors.leftMargin: root.karaokeView
                            ? root.karaokeMargin : Math.round(24 * prefs.uiScale)
                        anchors.topMargin: root.karaokeView
                            ? root.karaokeMargin : Math.round(24 * prefs.uiScale)
                        anchors.bottomMargin: root.karaokeView
                            ? root.karaokeMargin : Math.round(24 * prefs.uiScale)
                        // The side cover's column is held back from the text, so
                        // centring happens in the remaining width and the lyrics
                        // move left as the art appears.
                        anchors.rightMargin: (root.karaokeView
                            ? root.karaokeMargin : Math.round(24 * prefs.uiScale))
                            + root.karaokeTextRightInset
                        spacing: Math.round(12 * prefs.uiScale)

                        // The track header. It sits above the Flickable rather
                        // than inside it, so the details hold still while the
                        // lyrics scroll past. Both surfaces use it; each decides
                        // from its own setting how many rows it carries.
                        Text {
                            Layout.preferredWidth: root.lyricsColumnWidth
                            Layout.alignment: Qt.AlignHCenter
                            visible: root.lyricsHeaderTitleVisible
                            text: root.lyricsTrackTitle !== "" ? root.lyricsTrackTitle : "Lyrics"
                            horizontalAlignment: root.lyricsTextAlign
                            color: theme.foreground
                            font.pixelSize: Math.round((root.themeFont.title + prefs.fontTitle)
                                * root.lyricsHeaderScale * prefs.uiScale)
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.preferredWidth: root.lyricsColumnWidth
                            Layout.alignment: Qt.AlignHCenter
                            text: root.lyricsTrackArtist
                            visible: root.lyricsHeaderArtistVisible
                            horizontalAlignment: root.lyricsTextAlign
                            color: theme.muted
                            font.pixelSize: Math.round((root.themeFont.body + prefs.fontBody)
                                * root.lyricsHeaderScale * prefs.uiScale)
                            elide: Text.ElideRight
                        }

                        // The album row is karaoke's alone: the reading view has
                        // no setting for it, and one more line above the text
                        // would only shorten the reading column.
                        Text {
                            Layout.preferredWidth: root.lyricsColumnWidth
                            Layout.alignment: Qt.AlignHCenter
                            text: root.lyricsTrackAlbum
                            visible: root.lyricsHeaderAlbumVisible
                            horizontalAlignment: root.lyricsTextAlign
                            color: theme.muted
                            font.pixelSize: Math.round((root.themeFont.bodySmall + prefs.fontBodySmall)
                                * root.lyricsHeaderScale * prefs.uiScale)
                            elide: Text.ElideRight
                        }

                        Flickable {
                            id: lyricsFlick
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            contentWidth: lyricsColumn.width
                            contentHeight: lyricsColumn.implicitHeight

                            // A drag or flick means the reader is looking
                            // somewhere else; stop following until they settle.
                            onMovementStarted: {
                                lyricsScrollAnim.stop()
                                root.pauseLyricsFollow()
                            }
                            onMovementEnded: {
                                if (prefs.lyricsResume > 0) lyricsFollowTimer.restart()
                            }

                            // The wheel moves contentY without a drag, so it
                            // never fires movementStarted. Any scroll that is
                            // not the follow animation itself counts as the
                            // reader taking over, and pauses following the same
                            // way a drag does.
                            onContentYChanged: {
                                if (lyricsScrollAnim.running || root.lyricsFollowPaused) return
                                root.pauseLyricsFollow()
                            }

                            ColumnLayout {
                                id: lyricsColumn
                                // The measure, capped by the text-width setting
                                // and centred, so a narrow column reads as a
                                // column rather than as text pinned to one side.
                                width: root.lyricsColumnWidth
                                x: (lyricsFlick.width - width) / 2
                                spacing: Math.round(prefs.lyricsSpacing
                                    * (root.karaokeView ? 1.6 : 1) * prefs.uiScale)

                                Repeater {
                                    id: lyricsRepeater
                                    model: root.lyricsLines
                                    delegate: Text {
                                        id: lyricLine
                                        required property var modelData
                                        required property int index
                                        Layout.fillWidth: true
                                        text: modelData.text || ""
                                        wrapMode: Text.WordWrap
                                        horizontalAlignment: root.lyricsTextAlign
                                        color: (root.lyricsMarking && root.currentLyricLine === index)
                                            ? root.lyricsHighlightColor : theme.foreground
                                        // Only the follow modes mark a line and fade
                                        // the rest; "off" leaves the whole text at
                                        // full strength, since nothing is current.
                                        opacity: (!root.lyricsMarking
                                                  || root.currentLyricLine === index)
                                            ? 1.0 : root.lyricsDimOpacity
                                        // Bold as well as coloured: the accent
                                        // alone can be too close to the ground on a
                                        // light sleeve, but weight never is.
                                        font.pixelSize: root.lyricsFontPx
                                        font.weight: (root.lyricsMarking
                                                      && root.currentLyricLine === index)
                                            ? Font.DemiBold : Font.Normal

                                        // Click a timed line to jump to it.
                                        // Untimed (plain) lyrics stay inert,
                                        // since there is nowhere to go.
                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: prefs.lyricsClickSeek
                                                && lyricLine.modelData.time >= 0
                                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                            onClicked: root.seekToSeconds(lyricLine.modelData.time)
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    Layout.topMargin: Math.round(12 * prefs.uiScale)
                                    visible: root.lyricsLines.length === 0
                                            && (!root.lyricsLoading || root.lyricsSearching)
                                    text: root.lyricsSearching ? "Looking for lyrics…" : "No lyrics found"
                                    horizontalAlignment: root.lyricsTextAlign
                                    color: theme.muted
                                    font.pixelSize: root.lyricsFontPx
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
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

                    visible: root.coverPaneShown && root.lyricsSideCoverVisible
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
                        // the art show. Album view has no boundary to draw: its
                        // cover floats beside the titles rather than capping a
                        // column.
                        visible: root.coverPaneRule > 0 && !root.albumView
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
                // Karaoke hides the whole footer so the lyrics get the window;
                // play/pause still works from Space, and a line click seeks.
                visible: !root.karaokeView
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
                    anchors.leftMargin: Math.round((root.stripCompact ? 12 : 20) * prefs.uiScale)
                    anchors.rightMargin: Math.round((root.stripCompact ? 12 : 20) * prefs.uiScale)
                    spacing: Math.round((root.stripCompact ? 10 : 16) * prefs.uiScale)

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: Math.round(4 * prefs.uiScale)

                        Text {
                            Layout.fillWidth: true
                            text: root.mpd && root.mpd.current && root.mpd.current.Title
                                ? root.mpd.current.Title : "Nothing playing"
                            color: theme.foreground
                            font.pixelSize: Math.round((root.themeFont.title + prefs.fontTitle) * prefs.uiScale)
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
                                : root.idleSubtitle
                            color: theme.muted
                            font.pixelSize: Math.round((root.themeFont.body + prefs.fontBody) * prefs.uiScale)
                            elide: Text.ElideRight
                        }

                        SeekBar {
                            Layout.fillWidth: true
                            theme: theme
                            uiScale: prefs.uiScale
                            progress: root.progress
                            duration: root.duration
                            thickness: prefs.seekThickness
                            formatTime: root.formatTime
                            onSeekRequested: function (fraction) { root.seekToFraction(fraction) }
                        }

                        Text {
                            text: root.formatTime(root.elapsed) + " / " + root.formatTime(root.duration)
                            color: theme.muted
                            font.pixelSize: Math.round((root.themeFont.body + prefs.fontBody) * prefs.uiScale)
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
                        spacing: Math.round((root.stripCompact ? 10 : 16) * prefs.uiScale)

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
                            // The track gives way before the speaker does: at
                            // the tight step mute still works, and the level is
                            // one tap away in any full-width view.
                            sliderVisible: !root.stripTight
                            sliderWidth: root.stripCompact ? 64 : 120
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
            // Decode once at the largest placement, not at whatever size the
            // current view gives it: a view switch then scales the picture
            // instead of reloading it (see coverDecodeBoundWidth).
            decodeBoundWidth: root.coverDecodeBoundWidth
            decodeBoundHeight: root.coverDecodeBoundHeight
            // Only work while the panel is on screen. The window is closed most of
            // the time (the shell mounts this once and summons it on demand), and
            // an instance left active probed every album change with nothing
            // looking at it -- an ffmpeg extraction or a store fetch per untagged
            // album, and the colour pass on each cover.
            active: window.visible
            // The lyrics view may take the whole width; then the side pane and
            // this cover's pane placement are hidden, but karaoke still shows it
            // in its own placement.
            visible: root.lyricsCoverVisible
            // The cover belongs to the album that is playing, so hiding the panel
            // keeps it rather than re-finding it: re-probing on the next summon
            // walked the candidate list from the top with the placeholder up in
            // the meantime, which looked like the artwork reloading (and, for a
            // name further down the list, briefly going missing).
            keepCoverWhileHidden: true
            // A background cover is a wash, not a framed picture: no ring, no
            // rounded corners, and the opacity setting decides how much of it
            // shows through the text. The side placement keeps the normal frame.
            coverBorder: prefs.coverBorder && !root.karaokeCoverBackground
            coverBorderWidth: prefs.coverBorderWidth
            rounded: prefs.coverRounded && !root.karaokeCoverBackground
            placeholder: prefs.coverPlaceholder && !root.karaokeCoverBackground
            fetchCovers: prefs.fetchCovers
            // The colours are only used when adaptive colouring is on; otherwise
            // the quantizer would run on every cover for a palette syncTheme
            // deliberately ignores.
            quantize: prefs.adaptiveColors
            transitionDuration: prefs.coverTransition
            opacity: root.karaokeCoverBackground ? prefs.karaokeCoverOpacity : 1.0
            // A background cover fills the reading area; a side cover is the
            // modest karaoke square; otherwise the browser's pane or floating
            // size applies.
            width: root.karaokeCoverBackground ? parent.width
                : (root.karaokeCoverSide ? root.karaokeCoverSize
                    : (root.coverPaneShown ? root.paneCoverSize : root.floatingCoverSize))
            height: root.karaokeCoverBackground ? parent.height : width
            // In the artwork pane the cover keeps the padding setting's margin on
            // the right, flush when it is off; the pane is sized to match, so with
            // no margin the art runs flush to the left edge too and covers the pane
            // rule over its own height. Floating, it keeps its gutter. A karaoke
            // side cover sits in the column reserved on the right, vertically
            // centred on the text; the background cover fills the area and is
            // pushed behind the lyrics with a negative z.
            x: root.karaokeCoverBackground ? 0
                : (root.karaokeCoverSide
                    ? parent.width - root.karaokeMargin - width
                    : (root.coverPaneShown
                        ? parent.width - root.coverPad - width
                        : parent.width - width - root.floatGutter))
            y: root.karaokeCoverBackground ? 0
                : (root.karaokeCoverSide
                    ? Math.round((parent.height - height) / 2)
                    : (root.coverPaneShown
                        ? root.coverBandY
                        : parent.height - root.stripHeight - root.floatGutter - height))
            z: root.karaokeCoverBackground ? -1 : 0
        }

        // The next album's cover, tucked into the lower-left corner of album
        // view. Album view is about the record that is playing, so the preview
        // belongs at the edge of that surface rather than in the footer: it sits
        // above the strip with the same gutter the lists keep, not flush to the
        // window. It is a glance at what follows, not a control, so it takes no
        // input and disappears when there is no next album or the queue is
        // shuffled or repeating.
        Item {
            id: upNextBadge
            readonly property int tileSize: Math.round(64 * prefs.uiScale)
            readonly property int gutter: Math.round(20 * prefs.uiScale)
            visible: root.albumView && prefs.upNextCover
                && root.upNextSubject !== null && upNextCover.showingArt
            width: tileSize
            height: upNextCaption.implicitHeight
                + Math.round(4 * prefs.uiScale) + tileSize
            x: gutter
            y: parent.height - root.stripHeight - gutter - height
            z: 1

            Text {
                id: upNextCaption
                anchors.left: parent.left
                anchors.bottom: upNextCover.top
                anchors.bottomMargin: Math.round(4 * prefs.uiScale)
                text: "Up next"
                color: theme.muted
                font.family: root.themeFont.family
                font.pixelSize: Math.round((root.themeFont.caption + prefs.fontCaption) * prefs.uiScale)
            }

            CoverArt {
                id: upNextCover
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                width: parent.tileSize
                height: parent.tileSize
                theme: theme
                mpd: root.mpd
                subject: root.upNextSubject
                uiScale: prefs.uiScale
                pixelRatio: root.pixelRatio
                active: window.visible && root.albumView && prefs.upNextCover
                    && root.upNextSubject !== null
                coverBorder: prefs.coverBorder
                coverBorderWidth: prefs.coverBorderWidth
                rounded: prefs.coverRounded
                // No CD in the corner: a preview with no artwork is better left
                // out than standing in a placeholder for an album that has none.
                placeholder: false
                fetchCovers: prefs.fetchCovers
                transitionDuration: prefs.coverTransition
                // Only the main cover feeds the panel's colours.
                quantize: false
            }
        }

        // Typeahead readout: the letters being jumped to, shown only while they
        // are buffered and gone the moment the buffer ages out, so it always
        // matches what the next typed letter will search for.
        //
        // Two homes, both centred horizontally on the window. "bottom" puts it in
        // the band just above the now-playing strip -- the same spot, at the same
        // height, as the Ctrl transport readout, so a typed jump and a mode change
        // are the same piece of furniture. "center" floats it in the middle of the
        // whole window, the one spot the eye lands on without hunting. It is
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
            // Center: dead middle of the pane area above the strip, so the readout
            // never rides down into the footer whatever the strip's thickness.
            // Bottom: the transport readout's band, lifted clear of the error
            // banner the same way that one is, so the two never stack.
            readonly property int paneArea: Math.max(0, parent.height - root.stripHeight)
            readonly property int bandY: parent.height - root.stripHeight - gutter - height
                - (errorBanner.visible ? errorBanner.height + Math.round(8 * prefs.uiScale) : 0)
            // A typed jump and a transport notice can be up at the same time --
            // type a letter, then nudge the volume. The notice owns the band,
            // so the typeahead rides above it instead of being covered. The lift
            // follows the notice box's own visibility, not the flag, so it holds
            // through the fade instead of dropping out from under the readout.
            readonly property int noticeLift: transportNoticeBox.visible
                ? transportNoticeBox.height + Math.round(6 * prefs.uiScale) : 0
            visible: root.typeaheadBuffer.length > 0
            width: typeaheadReadout.implicitWidth + Math.round(20 * prefs.uiScale)
            height: typeaheadReadout.implicitHeight + Math.round(12 * prefs.uiScale)
            x: Math.round((parent.width - width) / 2)
            y: centered ? Math.round((paneArea - height) / 2) : bandY - noticeLift
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
                font.pixelSize: Math.round((root.themeFont.subtitle + prefs.typeaheadScale) * prefs.uiScale)
                font.family: root.themeFont.family
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
            id: errorBanner
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
                font.pixelSize: Math.round((root.themeFont.bodySmall + prefs.fontCaption) * prefs.uiScale)
            }
        }

        // Transient readout for the Ctrl transport keys: what the last one did,
        // in the band above the now-playing strip. Same shape and palette as the
        // typeahead readout, so a mode change and a jump read as the same kind of
        // aside rather than as two different overlays. It fades rather than
        // blinking out, and rises clear of the error banner when that is up.
        //
        // Karaoke has no strip, and its lyrics stop short of the window's bottom
        // edge, so there the readout drops into that margin instead of hanging a
        // footer's height above the window.
        Rectangle {
            id: transportNoticeBox
            readonly property int gutter: Math.round(12 * prefs.uiScale)
            readonly property int baseMargin: root.karaokeView
                ? Math.round(10 * prefs.uiScale)
                : root.stripHeight + gutter
            visible: opacity > 0
            opacity: root.transportNoticeVisible ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.transportNoticeVisible ? 90 : 220
                    easing.type: Easing.OutCubic
                }
            }
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: baseMargin
                + (errorBanner.visible ? errorBanner.height + Math.round(8 * prefs.uiScale) : 0)
            width: transportNoticeText.implicitWidth + Math.round(20 * prefs.uiScale)
            height: transportNoticeText.implicitHeight + Math.round(12 * prefs.uiScale)
            radius: Math.round(6 * prefs.uiScale)
            color: Util.alpha(theme.foreground, 0.10)
            border.width: 1
            border.color: Util.alpha(theme.foreground, 0.16)

            Text {
                id: transportNoticeText
                anchors.centerIn: parent
                text: root.transportNotice
                // Accent, the same as the typeahead and a live value in the
                // settings card.
                color: theme.accent
                font.pixelSize: Math.round((root.themeFont.subtitle + prefs.noticeScale) * prefs.uiScale)
                font.family: root.themeFont.family
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

                // Any key means the compositor has hidden the pointer, so the
                // album view should not keep a row glowing under where it used
                // to be. Movement over the album's own rows sets this back; it
                // is tracked there rather than with a handler here, because Qt
                // gives hover to the topmost target only and a window-wide
                // handler would starve every row of it.
                if (root.albumView && albumTrackView) albumTrackView.pointerActive = false

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
                // editor, Alt+L toggles lyrics view in the panes area, Alt+K
                // toggles karaoke over it. Alt+C and Alt+O, and the size keys,
                // act on the view that is showing: the cover's placement, the
                // karaoke background's opacity, and the text or artwork size.
                // The tag editor is the exception -- it disables this catcher and
                // reads its own keys. Plain ? opens the reference, and is left to
                // the branches below so it can also close a screen.
                var sizeUp = event.key === Qt.Key_Equal || event.key === Qt.Key_Plus
                var sizeDown = event.key === Qt.Key_Minus || event.key === Qt.Key_Underscore
                if (alt && (event.key === Qt.Key_S || event.key === Qt.Key_T
                            || event.key === Qt.Key_L || event.key === Qt.Key_K
                            || event.key === Qt.Key_A
                            || event.key === Qt.Key_C || event.key === Qt.Key_O
                            || sizeUp || sizeDown)) {
                    if (event.key === Qt.Key_S) {
                        root.toggleSettings()
                    } else if (event.key === Qt.Key_T) {
                        root.settingsOpen = false
                        root.helpOpen = false
                        root.openTagEditor()
                    } else if (event.key === Qt.Key_L) {
                        root.toggleView("lyrics")
                    } else if (event.key === Qt.Key_K) {
                        root.toggleView("karaoke")
                    } else if (event.key === Qt.Key_A) {
                        root.toggleView("album")
                    } else if (event.key === Qt.Key_C) {
                        root.cycleCover()
                    } else if (event.key === Qt.Key_O) {
                        root.cycleCoverOpacity()
                    } else if (sizeUp) {
                        // Shift turns the same key from text size into cover
                        // size; the two axes otherwise share a key and a nudge
                        // would be ambiguous.
                        if (shift) root.cycleCoverSize(1)
                        else root.cycleTextSize(1)
                    } else if (sizeDown) {
                        if (shift) root.cycleCoverSize(-1)
                        else root.cycleTextSize(-1)
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
                    // The sheet is taller than the card, so the panel scrolls it
                    // the way the reader would with the wheel.
                    case Qt.Key_Down:
                    case Qt.Key_J:
                        helpView.scrollBy(helpView.rowStep)
                        break
                    case Qt.Key_Up:
                    case Qt.Key_K:
                        helpView.scrollBy(-helpView.rowStep)
                        break
                    case Qt.Key_PageDown:
                    case Qt.Key_Space:
                        helpView.scrollBy(helpView.pageStep * 0.9)
                        break
                    case Qt.Key_PageUp:
                        helpView.scrollBy(-helpView.pageStep * 0.9)
                        break
                    case Qt.Key_Home:
                        helpView.scrollToEdge(0)
                        break
                    case Qt.Key_End:
                        helpView.scrollToEdge(1)
                        break
                    default:
                        handled = false
                    }
                    if (handled) event.accepted = true
                    return
                }

                // Ctrl is the transport's modifier wherever the browser keys are
                // live. The bare arrows move the caret and change pane, bare
                // letters and digits belong to the typeahead, and the settings
                // card's R resets everything, so track changes, volume and the
                // mode switches ride on Ctrl instead. The help sheet stays modal
                // above this: its keys only scroll and close it.
                if (ctrl && !alt && root.handleTransportKey(event.key)) {
                    event.accepted = true
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
                    // A greyed row answers to none of the editing keys: it has no
                    // track to open and nothing to toggle. It can still hold the
                    // caret -- the row is on the card -- so the shape test is
                    // gated on active rather than the row being refused outright.
                    var editable = entry && prefs.isActive(entry)
                    var isNumeric = !!(editable && entry.options && entry.options.length > 0 && typeof entry.options[0] === "number")

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
                    case Qt.Key_Backspace:
                        // Restore just the row under the caret, whether or not a
                        // slider is open. R still resets the whole card.
                        if (prefs.visibleEntries.length > 0)
                            prefs.resetEntry(prefs.visibleEntries[root.settingIndex])
                        break
                    default:
                        handled = false
                    }
                    if (handled) event.accepted = true
                    return
                }

                // The lyrics view covers the panes, so it owns the keyboard
                // while it is up. Without this branch j/k and the arrows moved
                // the hidden selection, and Enter could start a different track
                // while the reader was looking at the lyrics.
                if (root.lyricsView) {
                    var page = Math.max(1, Math.round(lyricsFlick.height * 0.9))
                    switch (event.key) {
                    case Qt.Key_Escape:
                    case Qt.Key_Q:
                        // Karaoke is a detour: Esc leaves it for the browser
                        // rather than for whatever was underneath it.
                        if (root.karaokeView) {
                            root.karaokeView = false
                            root.lyricsView = false
                        } else {
                            root.lyricsView = false
                        }
                        break
                    case Qt.Key_Down:
                    case Qt.Key_J:
                        root.scrollLyricsBy(root.lyricsScrollStep)
                        break
                    case Qt.Key_Up:
                    case Qt.Key_K:
                        root.scrollLyricsBy(-root.lyricsScrollStep)
                        break
                    case Qt.Key_PageDown:
                        root.scrollLyricsBy(page)
                        break
                    case Qt.Key_PageUp:
                        root.scrollLyricsBy(-page)
                        break
                    case Qt.Key_Home:
                        root.scrollLyricsToEdge(0)
                        break
                    case Qt.Key_End:
                        root.scrollLyricsToEdge(1)
                        break
                    case Qt.Key_Left:
                        if (shift) root.seekBy(-5)
                        break
                    case Qt.Key_Right:
                        if (shift) root.seekBy(5)
                        break
                    case Qt.Key_Space:
                        root.mpd && root.mpd.togglePlay()
                        break
                    case Qt.Key_Question:
                        root.toggleHelp()
                        break
                    default:
                        // Everything else is swallowed: no typeahead into a
                        // list that is not on screen.
                        break
                    }
                    event.accepted = true
                    return
                }

                // Album view is a single-pane browsing surface, so the normal
                // browser keys below still drive it. Esc is the one key it claims
                // for leaving the view, the way Esc leaves the lyrics view.
                if (root.albumView && event.key === Qt.Key_Escape) {
                    root.albumView = false
                    event.accepted = true
                    return
                }

                // Alt and control are not part of any browser binding -- the Alt
                // screen keys and the Ctrl transport keys were taken above.
                // Without this, Alt+letter reached the typeahead and Ctrl+letter
                // could still trip a plain binding. Swallow them rather than
                // acting on the letter.
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
                        && /^[A-Za-z0-9æøåÆØÅ-]$/.test(event.text)) {
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
        // in settingIndex, and the card is rebuilt from it when it opens.
        Loader {
            id: settingsLoader
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
            id: helpView
            anchors.fill: parent
            theme: theme
            uiScale: prefs.uiScale
            visible: root.helpOpen
            onDismissed: root.helpOpen = false
        }

        // Above the settings card, which is itself above the panes: both are
        // modal, but the tag editor is opened from outside this window, so it has
        // to be able to appear over a settings card nobody is looking at.
        //
        // Behind a Loader for the same reason as the settings card: the editor is
        // a large tree (a field per tag, a lookup list, a cover preview) and it is
        // closed for all but a moment of the session, so building it at mount only
        // to hide it costs every summon. It is created on the first open and then
        // kept -- unlike the card, it can be dismissed mid-write, and destroying it
        // out from under a running save would strand the callback that reports the
        // result. `tagEditorLoaded` latches the first open so the cost is paid
        // once rather than on every summon.
        Loader {
            id: tagEditorLoader
            anchors.fill: parent
            active: root.tagEditorLoaded
            sourceComponent: tagEditorComponent
        }

        Component {
            id: tagEditorComponent

            Cfg.TagEditor {
                anchors.fill: parent
                theme: theme
                mpd: root.mpd
                songs: root.tagSongs
                uiScale: prefs.uiScale
                pixelRatio: root.pixelRatio
                coverTransition: prefs.coverTransition
                fetchCovers: prefs.fetchCovers
                coverRounded: prefs.coverRounded
                visible: root.tagOpen
                onDismissed: root.tagOpen = false
            }
        }
    }

    // MPD has no mute command, so muting is modelled the way every MPD client
    // does it: remember the last audible level, drop to zero, and put it back on
    // the way out. The remembered level starts at zero, so unmuting from a cold
    // start with nothing to restore lands on a usable 50 rather than staying
    // silent with no way back.
    property int lastAudibleVolume: 0

    // The one-line readout for the Ctrl transport keys, flashed above the strip
    // and faded out on its own. The strip's own buttons and slider are feedback
    // enough in the browser, but karaoke hides the footer, so a mode change
    // there had none at all. A second press restarts the timer and replaces the
    // text rather than queueing a second readout.
    property string transportNotice: ""
    // Whether the readout is up. Kept apart from the text so the line stays
    // whole while it fades: clearing the string first collapsed the box to its
    // padding mid-fade, leaving a shrinking sliver where the notice had been.
    property bool transportNoticeVisible: false

    function showTransportNotice(text) {
        transportNotice = text
        transportNoticeVisible = true
        transportNoticeTimer.restart()
    }

    // A settings row by key, for the presentation keys below. The row owns its
    // options, its format and its save, so a keypress takes the same path as a
    // nudge in the card rather than writing the store directly. An inactive row
    // answers null: it is parked behind a parent setting and would move a value
    // nothing on screen reads.
    function cycleSetting(key, delta) {
        var entry = prefs ? prefs.entryFor(key) : null
        if (!entry || !prefs.isActive(entry)) return null
        prefs.cycle(entry, delta)
        return entry
    }

    function settingText(entry) {
        return entry ? prefs.textOf(entry) : ""
    }

    // Alt+C: the cover of whatever is on screen. The browser's cover pane has
    // three placements, the lyrics view only keeps or drops its side pane, and
    // karaoke chooses beside/background/hidden. One key, three vocabularies,
    // because each view has its own sensible next state.
    function cycleCover() {
        if (root.karaokeView) {
            var k = root.cycleSetting("karaokeCover", 1)
            if (k) root.showTransportNotice("Karaoke cover: " + root.settingText(k))
        } else if (root.lyricsView) {
            var l = root.cycleSetting("lyricsCover", 1)
            if (l) root.showTransportNotice("Cover beside lyrics: " + root.settingText(l))
        } else {
            // The row's options run off, on, auto; stepping back from auto
            // lands on on, so the key reads auto → on → off → auto rather than
            // dropping the pane first.
            var b = root.cycleSetting("coverBandMode", -1)
            if (b) root.showTransportNotice("Cover pane: " + root.settingText(b))
        }
    }

    // Alt+O: how much of the karaoke background cover shows through. Only the
    // background placement reads it, so the key says so rather than turning a
    // knob nobody can see.
    function cycleCoverOpacity() {
        if (!root.karaokeView || !root.karaokeCoverBackground) {
            root.showTransportNotice("Cover opacity: only with the background cover")
            return
        }
        var e = root.cycleSetting("karaokeCoverOpacity", 1)
        if (e) root.showTransportNotice("Cover opacity: " + root.settingText(e))
    }

    // Alt+= / Alt+-: the text size of the view on screen -- karaoke's own offset
    // there, the reading view's in lyrics, the whole panel's scale in the
    // browser. This is the one size key that always does something visible.
    function cycleTextSize(delta) {
        if (root.karaokeView) {
            var k = root.cycleSetting("karaokeFont", delta)
            if (k) root.showTransportNotice("Karaoke text: " + root.settingText(k))
        } else if (root.lyricsView) {
            var l = root.cycleSetting("lyricsFont", delta)
            if (l) root.showTransportNotice("Lyrics text: " + root.settingText(l))
        } else {
            var u = root.cycleSetting("uiScale", delta)
            if (u) root.showTransportNotice("UI scale: " + root.settingText(u))
        }
    }

    // Alt+Shift+= / Alt+Shift+-: the artwork's size in the browser and lyrics
    // view. Karaoke's cover is tied to the reading area rather than a stored
    // share, so there is no separate number to turn; say what the current
    // placement does instead of moving a setting nothing there reads.
    function cycleCoverSize(delta) {
        if (root.karaokeView) {
            if (root.karaokeCoverBackground) {
                root.showTransportNotice("Karaoke cover fills the view")
            } else if (!root.karaokeCoverVisible) {
                root.showTransportNotice("Karaoke cover is hidden")
            } else {
                root.showTransportNotice("Karaoke cover follows the view")
            }
            return
        }
        var e = root.cycleSetting("coverScale", delta)
        if (e) {
            root.showTransportNotice("Cover size: " + root.settingText(e))
        } else {
            root.showTransportNotice("Cover size: set by the cover pane")
        }
    }

    function toggleMute() {
        if (!mpd || !mpd.status || mpd.status.volume === undefined) return
        // The level last asked for, not the last one MPD has reported: muting
        // right after a burst of volume keys has to remember where the burst
        // was heading, or unmute would restore the level it started from.
        var current = mpd.volumeNow()
        if (current > 0) {
            lastAudibleVolume = current
            mpd.setVolume(0)
            showTransportNotice("Muted")
        } else {
            mpd.setVolume(lastAudibleVolume > 0 ? lastAudibleVolume : 50)
            showTransportNotice("Sound on")
        }
    }

    // Transport keys shared by the browser, the lyrics view and karaoke, so a
    // track change or a volume nudge is the same chord wherever the reader is.
    // They ride on Ctrl because the bare arrows move the caret and change pane,
    // and bare letters and digits belong to the typeahead. Returns true when the
    // key was one of them, so the caller can stop before its own switch.
    function handleTransportKey(key) {
        switch (key) {
        case Qt.Key_Right:
            if (mpd) mpd.command("next")
            return true
        case Qt.Key_Left:
            if (mpd) mpd.command("previous")
            return true
        // Volume and the two mode switches say what they did, because their
        // only other tell is a control in the footer, which karaoke hides.
        case Qt.Key_Up:
            if (mpd && mpd.status && mpd.status.volume !== undefined) {
                var louder = Math.min(100, mpd.volumeNow() + 5)
                mpd.setVolume(louder)
                showTransportNotice("Volume " + louder + "%")
            }
            return true
        case Qt.Key_Down:
            if (mpd && mpd.status && mpd.status.volume !== undefined) {
                var quieter = Math.max(0, mpd.volumeNow() - 5)
                mpd.setVolume(quieter)
                showTransportNotice("Volume " + quieter + "%")
            }
            return true
        case Qt.Key_M:
            root.toggleMute()
            return true
        // The readout names the state the press is about to leave the player in,
        // read from the current one rather than from the reply, so it is up
        // before MPD has answered.
        case Qt.Key_S:
            if (mpd) {
                var nextShuffle = (mpd.shuffleMode + 1) % 4
                // A scope wider than the album cannot live in an album-sized
                // queue, so the service steps repeat album out; say so, or the
                // repeat badge would vanish with no explanation.
                var dropsRepeat = mpd.repeatMode === 1 && nextShuffle > 1
                mpd.cycleShuffleMode()
                var shuffleText = nextShuffle === 1 ? "Shuffle album on"
                    : nextShuffle === 2 ? "Shuffle artist on"
                    : nextShuffle === 3 ? "Shuffle library on" : "Shuffle off"
                showTransportNotice(shuffleText + (dropsRepeat ? " · repeat off" : ""))
            }
            return true
        case Qt.Key_R:
            if (mpd) {
                var nextMode = (mpd.repeatMode + 1) % 3
                // Repeat album narrows the queue to the album, which drags a
                // wider shuffle scope back with it.
                var narrowsShuffle = nextMode === 1 && mpd.shuffleMode > 1
                mpd.cycleRepeatMode()
                var repeatText = nextMode === 1 ? "Repeat album on"
                    : nextMode === 2 ? "Repeat song on" : "Repeat off"
                showTransportNotice(repeatText + (narrowsShuffle ? " · shuffle album" : ""))
            }
            return true
        }
        return false
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

    // Ages out the transport readout. Long enough to read a short line, short
    // enough that it is gone before it starts feeling like furniture; holding a
    // key restarts it, so the readout stays up until the last press.
    Timer {
        id: transportNoticeTimer
        interval: 1300
        repeat: false
        onTriggered: root.transportNoticeVisible = false
    }

    // The one lyrics helper. It prints a single JSON object; the `file` it
    // echoes back is checked against the key on screen, so a slow answer for
    // the previous track cannot land after the next one has started loading.
    Process {
        id: lyricsProcess
        command: []
        // A failed start never ends a stream, so onStreamFinished never runs and
        // lyricsStreamActive would stay set, blocking every later request. A
        // normal finish clears the flag in onStreamFinished, which is delivered
        // before runningChanged, so reaching here with it still set means there
        // was no stream to finish.
        onRunningChanged: {
            if (running || !root.lyricsStreamActive) return
            root.lyricsStreamActive = false
            root.lyricsProcessKey = ""
            if (root.lyricsPending) {
                var pending = root.lyricsPending
                root.lyricsPending = null
                root.startLyricsRun(pending.file, pending.command)
                return
            }
            root.lyricsLoading = false
            root.lyricsSearching = false
            lyricsTimeout.stop()
            lyricsSearchTimer.stop()
        }
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The stream is over, so the next run may start even though
                // `running` has not changed yet.
                root.lyricsStreamActive = false
                // A finish with no key is the tail of a helper stopped for a
                // track change: its output belongs to a file no longer on
                // screen and must not touch the timers or the view. It does
                // mark the process as gone, which is the cue to start whatever
                // request was queued behind it.
                if (root.lyricsProcessKey !== ""
                        && root.lyricsProcessKey === root.lyricsFileKey) {
                    lyricsTimeout.stop()
                    lyricsSearchTimer.stop()
                    root.lyricsProcessKey = ""
                    root.lyricsLoading = false
                    root.lyricsSearching = false
                    // A finish can arrive after the view was closed; the run is
                    // over either way, but there is nothing to put on screen.
                    if (root.lyricsView) {
                        var data = null
                        try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
                        // The helper echoes the file it answered for. A mismatch
                        // means this stream is not the run the key belongs to.
                        var forThis = !(data && data.file !== undefined
                                && String(data.file) !== root.lyricsFileKey)
                        if (forThis && data && data.status === "ok" && data.lyrics) {
                            root.lyricsText = String(data.lyrics)
                            root.lyricsLines = root.parseLyrics(root.lyricsText)
                            root.currentLyricLine = -1
                        } else if (forThis) {
                            root.clearLyrics()
                        }
                    }
                }
                if (root.lyricsPending) {
                    var pending = root.lyricsPending
                    root.lyricsPending = null
                    root.startLyricsRun(pending.file, pending.command)
                }
            }
        }
    }

    // A helper that cannot start -- python3 missing, the script moved -- never
    // produces a stream to finish, so the loading state would stay up forever.
    // This also covers a stopped helper whose stream never ends: the request
    // queued behind it is dropped rather than started after the view gave up.
    Timer {
        id: lyricsTimeout
        interval: 40000
        repeat: false
        onTriggered: {
            if (!root.lyricsLoading) return
            root.stopLyricsRun()
            root.lyricsLoading = false
            root.clearLyrics()
        }
    }

    // Turns a lookup into "Looking for lyrics…" only once it has taken long
    // enough to be worth saying. Local hits finish before this fires.
    Timer {
        id: lyricsSearchTimer
        interval: 350
        repeat: false
        onTriggered: {
            if (root.lyricsLoading) root.lyricsSearching = true
        }
    }

    // Reads sidecar and cached lyrics synchronously (blockLoading), so a track
    // that already has lyrics opens straight into them without a helper run.
    FileView {
        id: lyricsFile
        path: ""
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    // How long a manual scroll suspends following before the view returns to
    // the line that is playing. "Never" (0) leaves the reader where they put
    // the text until the track changes or the view is reopened.
    Timer {
        id: lyricsFollowTimer
        interval: prefs.lyricsResume
        repeat: false
        onTriggered: {
            root.lyricsFollowPaused = false
            root.scrollToCurrentLyric()
        }
    }

    NumberAnimation {
        id: lyricsScrollAnim
        target: lyricsFlick
        property: "contentY"
        duration: 240
        easing.type: Easing.OutCubic
    }

    // Update current lyric line based on elapsed time
    Timer {
        id: lyricsSyncTimer
        interval: 250
        repeat: true
        running: root.lyricsView && root.lyricsMarking
                 && root.lyricsLines && root.lyricsLines.length > 0
        onTriggered: {
            // The offset shifts the highlight against the audio: positive
            // delays it for lyrics that run early.
            var elapsed = (root.elapsed || 0) - prefs.lyricsOffset / 1000
            var best = -1
            var lines = root.lyricsLines
            for (var i = 0; i < lines.length; i++) {
                var t = lines[i].time
                if (t >= 0 && t <= elapsed + 0.25) {
                    best = i
                } else if (t > elapsed + 0.25) {
                    break
                }
            }
            if (best !== root.currentLyricLine) {
                root.currentLyricLine = best
            }
        }
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
