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
    readonly property var selfId: root.manifest && root.manifest.id ? root.manifest.id : "grimplayer"
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

    // Read here rather than in PaneRow because only this file imports Quickshell,
    // and a binding that names an unimported module fails silently to 0 -- which
    // is what a zero divider quantum does to the layout. Zero until the shell
    // reports a screen, at which point PaneRow's quantum resolves.
    readonly property real pixelRatio: {
        var screens = Quickshell.screens
        return screens && screens.length > 0 ? (screens[0].devicePixelRatio || 0) : 0
    }

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

    // The settings card is modal: while it is up the browser keeps its state
    // underneath but stops answering keys, so j/k cannot walk a list that is
    // behind a dialog.
    property bool settingsOpen: false
    property int settingIndex: 0
    property bool settingsEditMode: false

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

    function open(payloadJson) {
        closingFromHost = true
        window.visible = true
        closingFromHost = false
        pane = "artists"
        settingsOpen = false
        settingsEditMode = false
        // The service may have loaded its one status before this panel attached
        // its status listener. If nothing is playing, no further event arrives,
        // so without this the bar would sit at zero until the next playback
        // change. Re-anchoring on open picks up whatever MPD already answered.
        reanchor()
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
            else if (pane === "albums") name = albumText(item.year, item.name)
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
    // opening it always starts at the top-left so the muscle memory for "s,
    // change the first thing" survives having scrolled somewhere else last time.
    //
    // The two columns are not two halves of one list. The right column is every
    // slider and the left is every switch and named choice, so the sizes group
    // together instead of alternating with the toggles. That means up/down walk
    // one column's own list and left/right cross between them, and because the
    // columns are different lengths the cross has to clamp.
    //
    // settingIndex stays an index into prefs.entries rather than a screen
    // position. The two orderings disagree, so the functions below convert
    // between them; keeping the canonical index means cycle(), textOf() and
    // reset() need no notion of columns at all.
    function toggleSettings() {
        settingsOpen = !settingsOpen
        if (settingsOpen) {
            settingIndex = settingIndexAt(0, 0) >= 0 ? settingIndexAt(0, 0) : 0
            settingsEditMode = false
        }
    }

    function settingColumnOf(index) {
        return prefs.isSlider(prefs.entries[index]) ? 1 : 0
    }

    function settingRowOf(index) {
        var entry = prefs.entries[index]
        if (!entry) return 0
        var list = prefs.isSlider(entry) ? prefs.sliderEntries : prefs.plainEntries
        return list.indexOf(entry)
    }

    // Clamps rather than refusing: crossing from a long column into a shorter
    // one lands on that column's last entry instead of doing nothing, which is
    // what makes left/right feel like movement when the columns differ.
    function settingIndexAt(column, row) {
        var list = column === 1 ? prefs.sliderEntries : prefs.plainEntries
        if (list.length === 0) return -1
        var clamped = Math.max(0, Math.min(row, list.length - 1))
        return prefs.entries.indexOf(list[clamped])
    }

    function moveSettingRows(delta) {
        if (prefs.entries.length === 0) return
        var column = settingColumnOf(settingIndex)
        var next = settingIndexAt(column, settingRowOf(settingIndex) + delta)
        if (next < 0 || next === settingIndex) return
        settingIndex = next
        settingsEditMode = false
    }

    function moveSettingColumns(delta) {
        if (prefs.entries.length === 0) return
        var column = settingColumnOf(settingIndex) + delta
        if (column < 0 || column > 1) return
        var next = settingIndexAt(column, settingRowOf(settingIndex))
        if (next < 0 || next === settingIndex) return
        settingIndex = next
        settingsEditMode = false
    }

    function changeSetting(delta) {
        if (prefs.entries.length === 0) return
        prefs.cycle(prefs.entries[settingIndex], delta)
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
        var target = Math.max(0, Math.min(1, fraction)) * duration
        if (!(duration > 0)) return -1
        var requested = mpd.seekFraction(fraction)
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
        color: Color.background
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

            // ---- panes ----
            PaneRow {
                Layout.fillWidth: true
                Layout.fillHeight: true
                // Bare `prefs`, not `root.prefs`: the config object is reached by its id, and an
                // id is only in scope as a plain name. `root.prefs` is undefined,
                // which left PaneRow silently on its fallback values -- dividers
                // pinned to 1px whatever the setting said.
                prefs: prefs
                paneWidth: window.width
                pixelRatio: root.pixelRatio
                activePane: root.pane
                artistList: root.artistList
                albumList: root.albumList
                trackList: root.trackList
                artistIndex: root.artistIndex
                albumIndex: root.albumIndex
                trackIndex: root.trackIndex
                current: root.mpd ? root.mpd.current : null

                artistLabel: function (item) { return item.name }
                albumLabel: function (item) { return root.albumText(item.year, item.name) }
                trackLabel: function (item) {
                    var n = item.track === null ? "--" : item.track
                    if (item.disc !== null && item.disc > 1) n = item.disc + "-" + n
                    return n + ". " + (item.title || "Untitled")
                }
                trackSublabel: function (item) { return root.formatTime(item.duration) }
                isCurrent: prefs.playingHighlight ? function (item) {
                    return root.mpd && root.mpd.current && item.file === root.mpd.current.file
                } : null

                onArtistActivated: function (index) { root.selectArtist(index, true) }
                onAlbumActivated: function (index) { root.selectAlbum(index, true) }
                onTrackActivated: function (index) { root.selectTrack(index) }
            }

            // ---- now playing ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.stripHeight
                color: Qt.rgba(0, 0, 0, 0.35)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Math.round(20 * prefs.uiScale)
                    anchors.rightMargin: Math.round(20 * prefs.uiScale)
                    spacing: Math.round(16 * prefs.uiScale)

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Math.round(4 * prefs.uiScale)

                        Text {
                            Layout.fillWidth: true
                            text: root.mpd && root.mpd.current && root.mpd.current.Title
                                ? root.mpd.current.Title : "Nothing playing"
                            color: Color.foreground
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
                            text: root.mpd && root.mpd.current && root.mpd.current.file
                                ? (root.mpd.current.Artist || root.mpd.current.AlbumArtist || "Unknown artist")
                                : (root.mpd && root.mpd.connected ? "Library ready" : "Not connected to MPD")
                            color: Color.muted
                            font.pixelSize: Math.round((Style.font.body + prefs.fontBody) * prefs.uiScale)
                            elide: Text.ElideRight
                        }

                        // Seek bar. Press and drag scrubs; the fill previews the
                        // dragged position and only the release sends a seek, so
                        // a drag is one MPD command instead of one per pixel.
                        Item {
                            id: seek

                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.round(14 * prefs.uiScale)

                            readonly property real shown: seekArea.pressed
                                ? seekArea.scrubFraction
                                : root.progress

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                height: prefs.seekThickness
                                radius: prefs.seekThickness / 2
                                color: Qt.rgba(1, 1, 1, 0.14)
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width * seek.shown
                                height: prefs.seekThickness
                                radius: prefs.seekThickness / 2
                                color: Color.accent
                            }

                            // Handle, shown on hover or while dragging, so the bar
                            // reads as draggable rather than as a progress display.
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: seekArea.containsMouse || seekArea.pressed
                                width: Math.round(11 * prefs.uiScale)
                                height: Math.round(11 * prefs.uiScale)
                                radius: Math.round(5.5 * prefs.uiScale)
                                color: Color.accent
                                x: Math.max(0, Math.min(seek.width - width,
                                    seek.width * seek.shown - width / 2))
                            }

                            MouseArea {
                                id: seekArea
                                anchors.fill: parent
                                enabled: root.duration > 0
                                hoverEnabled: true

                                property real scrubFraction: 0

                                function fractionAt(x) {
                                    return Math.max(0, Math.min(1, x / Math.max(1, seek.width)))
                                }

                                onPressed: function (mouse) { scrubFraction = fractionAt(mouse.x) }
                                onPositionChanged: function (mouse) {
                                    if (pressed) scrubFraction = fractionAt(mouse.x)
                                }
                                onReleased: function (mouse) {
                                    root.seekToFraction(fractionAt(mouse.x))
                                }
                                onCanceled: scrubFraction = seek.shown
                            }
                        }

                        Text {
                            text: root.formatTime(root.elapsed) + " / " + root.formatTime(root.duration)
                            color: Color.muted
                            font.pixelSize: Math.round((Style.font.body + prefs.fontBody) * prefs.uiScale)
                        }
                    }

                    // ---- transport ----
                    RowLayout {
                        spacing: Math.round(6 * prefs.uiScale)

                        TransportButton {
                            icon: "shuffle"
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                            active: !!(root.mpd && root.mpd.status && root.mpd.status.random)
                            onClicked: root.mpd && root.mpd.toggleRandom()
                        }
                        TransportButton {
                            icon: "previous"
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                            onClicked: root.mpd && root.mpd.command("previous")
                        }
                        TransportButton {
                            icon: root.mpd && root.mpd.status && root.mpd.status.state === "play" ? "pause" : "play"
                            prominent: true
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                            onClicked: root.mpd && root.mpd.togglePlay()
                        }
                        TransportButton {
                            icon: "next"
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                            onClicked: root.mpd && root.mpd.command("next")
                        }
                        TransportButton {
                            icon: "repeat"
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                            // Three modes: off, repeat song, repeat album. Lit for
                            // both repeat modes, with the dot marking the
                            // single-track one, which is the same read every
                            // other player trains you on.
                            active: root.mpd && root.mpd.repeatMode > 0
                            modeDot: root.mpd && root.mpd.repeatMode === 1
                            onClicked: root.mpd && root.mpd.cycleRepeatMode()
                        }
                    }

                    // ---- volume ----
                    RowLayout {
                        spacing: Math.round(8 * prefs.uiScale)

                        VolumeIcon {
                            iconSize: prefs.iconSize
                            uiScale: prefs.uiScale
                            level: root.mpd && root.mpd.status && root.mpd.status.volume !== undefined
                                ? root.mpd.status.volume : 0
                            onClicked: root.toggleMute()
                        }
                        // Themed rather than left on Qt's default Basic style: the stock slider comes
                        // out in the platform's own greys and ignores the theme entirely, which is why
                        // it was the one control in the panel that never changed with the rest. Track,
                        // fill and handle are drawn from the same tokens as the seek bar above, so the
                        // two read as one pair.
                        Slider {
                            id: volumeSlider
                            Layout.preferredWidth: Math.round(120 * prefs.uiScale)
                            implicitHeight: Math.round(22 * prefs.uiScale)
                            from: 0
                            to: 100
                            stepSize: 1

                            // The level MPD last reported, kept apart from the
                            // slider's own value rather than bound to it: a drag
                            // is echoed back one round trip later over `idle
                            // mixer`, so a binding would pull the handle out from
                            // under the pointer half way through the press. The
                            // echo is adopted whenever the handle is not held.
                            readonly property real reported: root.mpd && root.mpd.status
                                && root.mpd.status.volume !== undefined ? root.mpd.status.volume : 0
                            property bool dragging: false

                            onReportedChanged: if (!dragging) value = reported
                            onPressedChanged: dragging = pressed

                            // Dragging the slider to zero is also a mute, so it has to record the level it
                            // came from or the icon click would have nothing to restore.
                            onMoved: {
                                if (value > 0) root.lastAudibleVolume = value
                                if (root.mpd) root.mpd.setVolume(value)
                            }

                            Component.onCompleted: value = reported

                            background: Rectangle {
                                x: volumeSlider.leftPadding
                                y: volumeSlider.topPadding + volumeSlider.availableHeight / 2 - height / 2
                                width: volumeSlider.availableWidth
                                height: Math.max(2, Math.round(4 * prefs.uiScale))
                                radius: height / 2
                                color: Qt.rgba(1, 1, 1, 0.12)

                                Rectangle {
                                    width: parent.width * volumeSlider.visualPosition
                                    height: parent.height
                                    radius: parent.radius
                                    color: Color.accent
                                }
                            }

                            handle: Rectangle {
                                x: volumeSlider.leftPadding
                                    + volumeSlider.visualPosition * (volumeSlider.availableWidth - width)
                                y: volumeSlider.topPadding + (volumeSlider.availableHeight - height) / 2
                                width: Math.round(13 * prefs.uiScale)
                                height: width
                                radius: width / 2
                                color: Color.foreground
                                border.width: 2
                                border.color: Color.background
                                // Idle handle would sit as a permanent dot on the
                                // track; the transport buttons behave the same way,
                                // showing their affordance only on hover or press.
                                visible: volumeSlider.pressed || volumeSlider.hovered
                            }
                        }
                    }
                }
            }
        }

        // Album art for the current track, floating over the tracks pane's lower
        // right corner. Inset, it keeps a gutter on both edges; the preference
        // drops both to 0 for artwork that runs to the window edges instead.
        // bottomMargin always clears the 84px now-playing strip so the cover sits
        // above the footer rather than on top of it.
        CoverArt {
            mpd: root.mpd
            uiScale: prefs.uiScale
            coverBorder: prefs.coverBorder
            coverBorderWidth: prefs.coverBorderWidth
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: Math.round(20 * prefs.uiScale)
            anchors.bottomMargin: root.stripHeight + Math.round(20 * prefs.uiScale)
            width: Math.round(prefs.coverSize * prefs.uiScale)
            height: Math.round(prefs.coverSize * prefs.uiScale)
        }

        // Typeahead readout: the letters being jumped to, shown only while they
        // are buffered and gone the moment the buffer ages out, so it always
        // matches what the next typed letter will search for. Sits in the
        // artists pane's lower corner, clear of the caret and the cover art.
        Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.leftMargin: Math.round(12 * prefs.uiScale)
            anchors.bottomMargin: root.stripHeight + Math.round(12 * prefs.uiScale)
            visible: root.typeaheadBuffer.length > 0
            width: typeaheadReadout.implicitWidth + Math.round(20 * prefs.uiScale)
            height: typeaheadReadout.implicitHeight + Math.round(12 * prefs.uiScale)
            radius: Math.round(6 * prefs.uiScale)
            // Themed like the rest of the panel: a low foreground wash rather
            // than flat black, so it sits in the palette and follows a theme
            // switch instead of punching a dark hole in it.
            color: Util.alpha(Color.foreground, 0.10)
            border.width: 1
            border.color: Util.alpha(Color.foreground, 0.16)

            Text {
                id: typeaheadReadout
                anchors.centerIn: parent
                text: root.typeaheadBuffer
                // Accent, matching how the settings card marks a live value.
                color: Color.accent
                // Body rather than caption: at caption this was the smallest text
                // in the panel, which made a transient indicator easy to miss.
                font.pixelSize: Math.round(Style.font.body * prefs.uiScale)
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
            visible: root.mpd !== null && (!root.mpd.connected || root.mpd.lastError !== "")
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
            color: Util.alpha(Color.urgent, 0.18)
            border.width: 1
            border.color: Util.alpha(Color.urgent, 0.6)

            Text {
                id: errorText
                anchors.centerIn: parent
                text: root.mpd && root.mpd.lastError !== "" ? "MPD: " + root.mpd.lastError : "MPD not connected"
                color: Color.foreground
                font.pixelSize: Math.round((Style.font.caption + prefs.fontCaption) * prefs.uiScale)
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
            focus: true

            // The manifest sets keepLoaded, so the panel mounts with the shell
            // and open() is never called to claim focus. Taking it when the
            // window becomes visible is what makes the keys work at all.
            onVisibleChanged: if (visible) Qt.callLater(function () { keyCatcher.forceActiveFocus() })

            Component.onCompleted: Qt.callLater(function () { keyCatcher.forceActiveFocus() })

            Keys.onPressed: function (event) {
                var handled = true

                // Shift and control are read before the switch. shift+left and
                // shift+right report the same Qt.Key_Left/Qt.Key_Right as the
                // bare arrows, so a case matching on the key alone ran first and
                // changed pane instead of seeking -- the seek branch below was
                // unreachable and could never be taken.
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

                // Settings is modal, so it gets first refusal on every key: the
                // browser underneath must not answer j/k while the card is up, or
                // the caret moves in a list nobody can see.
                //
                // Two modes. Browsing: all four arrows, and the hjkl equivalents, walk the
                // two-dimensional grid -- up/down a row, left/right a column.
                // Editing: a slider is open, so left/right belong to it and
                // up/down go back to moving the caret. Enter is the toggle for
                // the plain switches and the way into a slider, which is the
                // only reason edit mode exists at all.
                if (root.settingsOpen) {
                    var count = prefs.entries.length
                    var entry = count > 0 ? prefs.entries[Math.max(0, Math.min(root.settingIndex, count - 1))] : null
                    var isNumeric = !!(entry && entry.options && entry.options.length > 0 && typeof entry.options[0] === "number")

                    switch (event.key) {
                    case Qt.Key_Escape:
                        // Esc backs out one level: leave the slider first, close
                        // the card second. Closing outright from inside a slider
                        // loses the setting you were standing on.
                        if (root.settingsEditMode) root.settingsEditMode = false
                        else root.settingsOpen = false
                        break
                    case Qt.Key_Q:
                    case Qt.Key_Question: root.settingsOpen = false; break

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
                            // First and last of the whole card, which are the top
                            // of the left column and the bottom of the right one.
                            var edge = shift ? 1 : 0
                            var target = root.settingIndexAt(edge, shift ? 9999 : 0)
                            if (target >= 0) root.settingIndex = target
                            root.settingsEditMode = false
                        }
                        break
                    case Qt.Key_R:
                        if (!root.settingsEditMode) prefs.reset()
                        break
                    default:
                        handled = false
                    }
                    if (handled) event.accepted = true
                    return
                }

                if (shift && event.key === Qt.Key_Left) {
                    root.seekBy(-5)
                } else if (shift && event.key === Qt.Key_Right) {
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
                case Qt.Key_G: if (prefs.vimKeys) root.moveToEnd(false); else handled = false; break
                case Qt.Key_Greater: if (prefs.vimKeys) root.moveToEnd(true); else handled = false; break
                case Qt.Key_Return:
                case Qt.Key_Enter:
                    root.activate(); break
                case Qt.Key_Space:
                    root.mpd && root.mpd.togglePlay(); break
                case Qt.Key_Question:
                    root.toggleSettings(); break
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
        Cfg.GrimPlayerSettings {
            // Fill is what makes the card land in the middle of the window: an
            // unanchored Item is 0x0, and the card centres inside it.
            anchors.fill: parent
            config: prefs
            index: root.settingIndex
            editMode: root.settingsEditMode
            uiScale: prefs.uiScale
            visible: root.settingsOpen
            // The card asks, the panel decides. Assigning settingIndex back from
            // onIndexChanged would only work until the first click inside the
            // card, which rebinds nothing and leaves the keyboard driving a
            // caret the card has stopped showing.
            onIndexRequested: function (i) { root.settingIndex = i }
            onEditModeRequested: function (on) { root.settingsEditMode = on }
            onDismissed: { root.settingsOpen = false; root.settingsEditMode = false }
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
        mpd.seekFraction((elapsed + seconds) / duration)
    }

    // Only ticks while something is playing: a paused transport has nothing to
    // interpolate, so the timer stops rather than waking the shell every second.
    Timer {
        interval: 1000
        running: root.mpd !== null && root.mpd.status && root.mpd.status.state === "play"
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
}
