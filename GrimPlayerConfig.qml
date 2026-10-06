// Persisted preferences for GrimPlayer.
//
// shell.json decides how the panel is wired into the shell -- which service it
// talks to, whether it stays loaded -- but the things a person is likely to
// change while listening belong to the player itself: how thick the seeker
// draws, whether the lists stop or wrap at their ends.
//
// The values live in a JSON file under the shell state directory, written by
// hand rather than through PersistentProperties. PersistentProperties buffers
// writes and only flushes on its own schedule, so every shell restart -- and
// every plugin reload, which the shell does whenever a file here changes --
// dropped the buffer and came back at the code defaults. Loading and saving
// explicitly means a setting survives a restart the moment it is changed, and
// the code defaults below stay the fallback for a first run.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // Scalars rather than one packed object: a typed property is what
    // round-trips through JSON cleanly, and the row table below only ever
    // reaches them through get/set closures.
    QtObject {
        id: store

        // Down on the last row goes to the top and up on the first goes to the
        // bottom. On by default, because a list that stops dead at both ends
        // reads like a scrollbar that ran out of document.
        property bool wrapAround: true

        // Logical pixels. The bar is centred in a 14px slot, so much past 9
        // starts crowding the elapsed time above it.
        property int seekThickness: 7

        // Year prefix on the albums pane, from the tracks' Date tags.
        property bool albumYears: true

        // Tint plus accent bar on the row MPD is actually playing.
        property bool playingHighlight: true

        // Cover art keeps its gutter instead of running to the window edges.

        // Plain j/k/h/l/g/G navigation. Off leaves the arrow keys in charge.
        property bool vimKeys: true

        // Height of one list row in logical pixels. The gap between rows is
        // derived from this (an eighth of the row), so one control sets the whole
        // row rhythm -- a separate gap slider only ever fought the row height.
        property int rowSpacing: 32

        // Typing letters jumps the caret to the first matching row.
        property bool typeaheadSearch: true

        // A faint line between rows. Off is the cleaner, flatter look.
        property bool rowSeparators: false

        // Pull the inactive panes back so the focused one reads as foreground.
        property bool focusGlow: true

        // Rules. borderWidth drives both the heading underline and the rule
        // between panes, so the two are always the same weight. The cover art
        // ring has its own slider so the two never drag each other along.
        property int borderWidth: 1
        property bool coverBorder: true
        property int coverBorderWidth: 1

        // Thicker frame around the row the caret is on.
        property bool activeRowBorder: false

        // Which repeat mode the panel is in: 0 off, 1 repeat song, 2 repeat album.
        // Stored here rather than read back from MPD because MPD 0.24's repeat
        // is a plain boolean -- it rejects "repeat 2" outright -- so album mode
        // is a loop this player performs itself and MPD's flag stays off. That
        // makes the stored mode the only place the real answer lives.
        property int repeatMode: 0

        // Cover sizing
        property int coverSize: 210

        // Interface sizing. uiScale is a single multiplier over every derived size --
        // rows, gap, fonts, icons and cover art -- so one slider rescales the
        // whole player instead of only the lists, which is what it used to do.
        // The range runs 50% to 150%: far enough down to matter on a 4K screen,
        // far enough up to matter on a laptop.
        property real uiScale: 1.0

        // Icons
        property int iconSize: 16

        // Font sizes are offsets from the active Omarchy theme, not absolutes.
        // Zero means "whatever the theme says", so switching theme still
        // restyles the panel and these only nudge it from there. Storing an
        // absolute here fought the theme on every theme switch.
        property int fontTitle: 0
        property int fontSubtitle: 0
        property int fontBody: 0
        property int fontBodySmall: 4
        property int fontCaption: 0
    }

    // ---- persistence ----
    //
    // The file is the record of what the user chose; the properties above are
    // only the fallback for a machine that has never opened the settings card.
    // Every write goes through saveSoon() so a slider drag is one file write
    // rather than one per pixel.

    readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/grimplayer/settings.json"

    FileView {
        id: stateFile
        path: root.statePath
        // The shell edits this file only through us, so watching it would just
        // bounce our own writes back at us.
        watchChanges: false
        printErrors: false
        // Blocking is what makes the synchronous read in Component.onCompleted
        // below actually see anything. Without it FileView loads on a later tick,
        // text() is still empty when the panes have already bound to the
        // defaults, and every stored setting silently loses to its default.
        blockLoading: true
    }

    // Coalesces bursts of changes -- a slider drag, or reset() walking every
    // entry -- into a single write once the user stops moving.
    Timer {
        id: saveTimer
        interval: 400
        repeat: false
        onTriggered: root.saveNow()
    }

    function saveSoon() {
        saveTimer.restart()
    }

    function saveNow() {
        var out = {}
        // Only real properties, not the id or the functions hanging off it.
        var keys = ["wrapAround", "seekThickness", "albumYears", "playingHighlight",
                    "vimKeys", "rowSpacing", "typeaheadSearch", "rowSeparators",
                    "focusGlow", "borderWidth", "coverBorder",
                    "coverBorderWidth", "activeRowBorder", "repeatMode", "coverSize",
                    "uiScale", "iconSize",
                    "fontTitle", "fontSubtitle", "fontBody", "fontBodySmall",
                    "fontCaption"]
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i]
            if (store[k] !== undefined) out[k] = store[k]
        }
        var body = JSON.stringify(out, null, 2)
        var dir = root.statePath.substring(0, root.statePath.lastIndexOf("/"))
        // The heredoc is quoted so neither the path nor the JSON is expanded by
        // the shell; the JSON is passed as $1 and written with cat.
        saveProc.command = ["bash", "-c",
            "mkdir -p \"$1\" && cat > \"$2\" <<'GRIMJSON'\n" + body + "\nGRIMJSON",
            "grimplayer-save", dir, root.statePath]
        saveProc.running = true
    }

    // Applies a stored object over the defaults. Unknown keys are ignored and
    // keys of the wrong type are dropped by the try/catch, so a hand-edited or
    // older file degrades to "that one setting is at its default" rather than
    // taking the panel down with it.
    function applyStored(obj) {
        if (!obj || typeof obj !== "object") return
        for (var k in obj) {
            if (store[k] === undefined) continue
            var v = obj[k]
            var current = store[k]
            if (typeof current === "boolean" && typeof v === "boolean") store[k] = v
            else if (typeof current === "number" && typeof v === "number") store[k] = v
            else if (typeof current === "string" && typeof v === "string") store[k] = v
        }
    }

    Process {
        id: saveProc
        running: false
        command: []
    }


    Component.onCompleted: {
        // Read synchronously: the panel mounts at shell startup and the panes
        // bind to these values on their first evaluation, so an async load would
        // show one frame at the defaults and then jump.
        var raw = stateFile.text()
        if (raw && raw.length > 0) {
            try {
                applyStored(JSON.parse(raw))
            } catch (e) {
                // Malformed file: keep the defaults rather than failing to start.
            }
        }
    }

    readonly property bool wrapAround: store.wrapAround
    readonly property int seekThickness: store.seekThickness
    readonly property bool albumYears: store.albumYears
    readonly property bool playingHighlight: store.playingHighlight
    readonly property bool vimKeys: store.vimKeys
    readonly property int rowSpacing: store.rowSpacing
    readonly property bool typeaheadSearch: store.typeaheadSearch
    readonly property bool rowSeparators: store.rowSeparators
    readonly property bool focusGlow: store.focusGlow
readonly property int borderWidth: store.borderWidth
    readonly property bool coverBorder: store.coverBorder
    readonly property int coverBorderWidth: store.coverBorderWidth
    readonly property bool activeRowBorder: store.activeRowBorder
    readonly property int repeatMode: store.repeatMode

    // Written by the repeat-mode logic rather than by the settings card, hence
    // a setter instead of an exposed entry.
    function setRepeatMode(value) {
        store.repeatMode = value
        saveSoon()
    }
    readonly property int coverSize: store.coverSize
    readonly property real uiScale: store.uiScale
    readonly property int iconSize: store.iconSize
    readonly property int fontTitle: store.fontTitle
    readonly property int fontSubtitle: store.fontSubtitle
    readonly property int fontBody: store.fontBody
    readonly property int fontBodySmall: store.fontBodySmall
    readonly property int fontCaption: store.fontCaption

    function boolText(value) {
        return value ? "on" : "off"
    }

    // Font sizes are theme offsets, so the useful thing to print is the size the
    // theme resolves to, not the delta -- a theme at 12px and an offset of +2
    // land on the same 14px and should read the same. Zero says "theme", which is
    // the value people keep coming back to and should be obvious at a glance.
    function deltaText(value) {
        if (value === 0) return "theme"
        return (value > 0 ? "+" : "") + value + " px"
    }

    // The rows the settings card renders, in the order it shows them. The first
    // option is the default, which is what reset() restores, so adding an option
    // here needs nothing else. get/set are closures rather than store[key]
    // because dynamic property access on a typed QObject is not something to
    // lean on from QML.
    readonly property var entries: [
        {
            key: "wrapAround",
            label: "Wrap around lists",
            hint: "Down on the last row goes to the top, up on the first goes to the last",
            options: [true, false],
            get: function () { return store.wrapAround },
            set: function (v) { store.wrapAround = v },
            format: root.boolText
        },
        {
            key: "vimKeys",
            label: "Vim keys",
            hint: "Use j/k/h/l/g/G for navigation",
            options: [true, false],
            get: function () { return store.vimKeys },
            set: function (v) { store.vimKeys = v },
            format: root.boolText
        },
        {
            key: "typeaheadSearch",
            label: "Typeahead search",
            hint: "Jump by typing first letters of names",
            options: [true, false],
            get: function () { return store.typeaheadSearch },
            set: function (v) { store.typeaheadSearch = v },
            format: root.boolText
        },
        {
            key: "seekThickness",
            label: "Seeker thickness",
            hint: "How thick the bar above the transport is drawn",
            options: [3, 5, 7, 9],
            defaultValue: 7,
            get: function () { return store.seekThickness },
            set: function (v) { store.seekThickness = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "playingHighlight",
            label: "Playing track marker",
            hint: "Tint and mark the current track while browsing its album",
            options: [true, false],
            get: function () { return store.playingHighlight },
            set: function (v) { store.playingHighlight = v },
            format: root.boolText
        },
        {
            key: "albumYears",
            label: "Album years",
            hint: "Prefix each album with its release year, read from the Date tag",
            options: [true, false],
            get: function () { return store.albumYears },
            set: function (v) { store.albumYears = v },
            format: root.boolText
        },
        {
            key: "coverBorder",
            label: "Cover art border",
            hint: "Ring around the cover art, separate from the pane rules",
            options: [true, false],
            defaultValue: true,
            get: function () { return store.coverBorder },
            set: function (v) { store.coverBorder = v },
            format: root.boolText
        },
        {
            key: "borderWidth",
            label: "Border width",
            hint: "Thickness of the outline around each pane",
            options: [1, 2, 3, 4],
            get: function () { return store.borderWidth },
            set: function (v) { store.borderWidth = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "coverBorderWidth",
            label: "Cover art border width",
            hint: "Thickness of the ring around the cover art",
            options: [1, 2, 3, 4, 6, 8],
            defaultValue: 1,
            get: function () { return store.coverBorderWidth },
            set: function (v) { store.coverBorderWidth = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "activeRowBorder",
            label: "Extreme cursor highlight",
            hint: "Draw a bolder frame around the cursor row in the active pane",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.activeRowBorder },
            set: function (v) { store.activeRowBorder = v },
            format: root.boolText
        },
        {
            key: "rowSeparators",
            label: "Row separator lines",
            hint: "Draw a faint line between rows in each pane",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.rowSeparators },
            set: function (v) { store.rowSeparators = v },
            format: root.boolText
        },
        {
            key: "focusGlow",
            label: "Active pane emphasis",
            hint: "Dim the two inactive panes so the focused one stands out",
            options: [true, false],
            get: function () { return store.focusGlow },
            set: function (v) { store.focusGlow = v },
            format: root.boolText
        },
        {
            key: "rowSpacing",
            label: "Row spacing",
            hint: "Height of each list row; the gap between rows follows it",
            options: [24, 28, 32, 36, 40],
            defaultValue: 32,
            get: function () { return store.rowSpacing },
            set: function (v) { store.rowSpacing = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "uiScale",
            label: "UI scale",
            hint: "Scales rows, spacing, fonts, icons and cover art together",
            options: [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5],
            defaultValue: 1.0,
            get: function () { return store.uiScale },
            set: function (v) { store.uiScale = v },
            format: function (v) { return (v * 100).toFixed(0) + "%" }
        },
        {
            key: "fontTitle",
            label: "Font size playing song",
            hint: "Now playing song title, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 0,
            get: function () { return store.fontTitle },
            set: function (v) { store.fontTitle = v },
            format: root.deltaText
        },
        {
            key: "fontSubtitle",
            label: "Font size for items",
            hint: "Row text and track times, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 0,
            get: function () { return store.fontSubtitle },
            set: function (v) { store.fontSubtitle = v },
            format: root.deltaText
        },
        {
            key: "fontBody",
            label: "Font artist and time",
            hint: "Artist and the elapsed/total time, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 0,
            get: function () { return store.fontBody },
            set: function (v) { store.fontBody = v },
            format: root.deltaText
        },
        {
            key: "fontBodySmall",
            label: "Font pane heading",
            hint: "Pane headings and secondary text, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 4,
            get: function () { return store.fontBodySmall },
            set: function (v) { store.fontBodySmall = v },
            format: root.deltaText
        },
        {
            key: "coverSize",
            label: "Cover art size",
            hint: "Size of the floating cover art",
            options: [120, 150, 180, 210, 240, 270, 300],
            defaultValue: 210,
            get: function () { return store.coverSize },
            set: function (v) { store.coverSize = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "iconSize",
            label: "Icon size",
            hint: "Transport and UI icons",
            options: [12, 14, 16, 18, 20],
            defaultValue: 16,
            get: function () { return store.iconSize },
            set: function (v) { store.iconSize = v },
            format: function (v) { return v + " px" }
        },
    ]

    function textOf(entry) {
        return entry.format(entry.get())
    }

    // A slider is anything numeric; everything else is a switch or a named
    // choice. The card sorts on this to put every slider in one column and every
    // switch in the other, so it lives next to the table it describes rather
    // than in the view: the panel walks the columns for navigation and would
    // otherwise have to re-derive the same split independently.
    function isSlider(entry) {
        var o = entry ? entry.options : null
        return !!(o && o.length > 0 && typeof o[0] === "number")
    }

    // Same entry objects as `entries`, just filtered, so cycle(), textOf() and
    // indexOf against `entries` all keep working on them unchanged.
    readonly property var plainEntries: entries.filter(function (e) { return !isSlider(e) })
    readonly property var sliderEntries: entries.filter(function (e) { return isSlider(e) })

    // Step to the next or previous option. indexOf answers -1 for a value that
    // is not in the list at all -- an older or hand-edited state file -- and
    // -1 + 1 lands on options[0], so a stale file falls back to the default
    // rather than sticking.
    function cycle(entry, delta) {
        var options = entry.options
        var i = options.indexOf(entry.get())
        entry.set(options[(i + delta + options.length) % options.length])
        saveSoon()
    }

    // Restores each entry's own default rather than options[0]. Those two used to
    // be the same thing, but they part company the moment a setting's natural
    // resting point is not the low end of its range: the font offsets run -4..+4
    // so the slider knob sits centred on "theme", which would have made reset
    // slam every font down by four pixels. An entry without `defaultValue` still
    // falls back to options[0].
    function reset() {
        for (var i = 0; i < entries.length; i++) {
            var entry = entries[i]
            entry.set(entry.defaultValue !== undefined ? entry.defaultValue : entry.options[0])
        }
        saveSoon()
    }
}
