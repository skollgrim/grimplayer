pragma ComponentBehavior: Bound
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

        // Logical pixels. The bar is centred in a slot the thickness itself sets
        // (see SeekBar), so a thick bar pushes the row taller rather than
        // spilling over the elapsed time above it. 9 is where the useful
        // settings start, and the rungs above it are for anyone who wants the
        // bar to read as a deliberate band under the now-playing strip.
        property int seekThickness: 9

        // Year prefix on the albums pane, from the tracks' Date tags.
        property bool albumYears: true

        // Tint plus accent bar on the row MPD is actually playing.
        property bool playingHighlight: true

        // Which edges of the playing row carry the accent bar: "none", "left",
        // "right" or "both". The tint below is unaffected -- this only decides
        // where the bars sit, so "none" keeps the tint and drops the bars. The
        // right edge is the default: the labels start at the left margin, so a
        // bar on the right sits in the margin past the text's end and marks the
        // row without crowding what it says.
        property string playingMarkerSides: "right"

        // Recolour the whole panel from the playing album's cover art, instead
        // of following the shell theme. Off is the theme-following look.
        property bool adaptiveColors: false

        // Look up a cover from the stores (iTunes, then Deezer) for an album with
        // no sidecar and no embedded picture, and cache it for display. Off keeps
        // the player entirely offline and such albums on the placeholder.
        property bool fetchCovers: true

        // Plain j/k/h/l/g/G navigation. Off leaves the arrow keys in charge.
        property bool vimKeys: false

        // Height of one list row in logical pixels. The gap between rows is
        // derived from this (an eighth of the row), so one control sets the whole
        // row rhythm -- a separate gap slider only ever fought the row height.
        property int rowSpacing: 28

        // Typing letters jumps the caret to the first matching row.
        property bool typeaheadSearch: true

        // Where the typeahead readout sits: "corner" tucks it into the artists
        // pane's lower corner, clear of the caret and the cover art, and
        // "center" floats it in the middle of the window, where the eye already
        // is when the lists are long enough that a corner readout is easy to
        // miss. Kept as a named choice rather than a flag so a third position
        // has somewhere to land without another boolean.
        property string typeaheadPlace: "corner"

        // The readout's font size as an offset from the theme, like the font-size
        // settings. The corner readout is a glanceable aside and the centred one
        // has to hold the eye from across the window, so it starts well above the
        // panel's body text. The range starts at zero -- the theme's own size --
        // rather than below it: the readout is meant to stand out from the text
        // it is drawn over, so a smaller-than-theme setting had no good use.
        property int typeaheadScale: 6

        // A faint line between rows. Off is the cleaner, flatter look.
        property bool rowSeparators: false

        // Pull the inactive panes back so the focused one reads as foreground.
        property bool focusGlow: true

        // The heading bar atop each pane: the pane's name over an underline rule.
        // Off, the heading and its rule are dropped and the list starts at the
        // very top of the pane.
        property bool paneHeadings: false

        // The vertical rules between the list panes, and between the lists and
        // the artwork pane. Off drops them so the panes meet with nothing drawn
        // between.
        property bool paneSeparators: true

        // Rules. borderWidth drives both the heading underline and the rule
        // between panes, so the two are always the same weight. The cover art
        // ring has its own slider so the two never drag each other along.
        property int borderWidth: 1
        property bool coverBorder: false
        property bool coverPlaceholder: true
        property int coverBorderWidth: 1

        // Rounded corners on the artwork. Off draws it as a plain square, corner
        // to corner.
        property bool coverRounded: true

        // Thicker frame around the row the caret is on.
        property bool activeRowBorder: false

        // Which repeat mode the panel is in: 0 off, 1 repeat album, 2 repeat song.
        // Stored here rather than read back from MPD because album repeat is a loop
        // this player performs itself: MPD's repeat is a plain boolean over the
        // whole queue and its flag stays off in album mode, so the stored mode is
        // the only place the real answer lives.
        property int repeatMode: 0

        // Artwork sizing, as a percentage of the pane region -- everything above
        // the now-playing strip. A share rather than a pixel count, so 100% fills
        // that region from the very top of the player to the strip at any window
        // size, and a smaller value scales with the window instead of meaning one
        // thing on a laptop and another on a large screen. Drives both placements:
        // the floating corner cover and the artwork pane. The stored value is used
        // when the artwork pane is pinned on or off; under "auto" the window picks
        // the placement and the panel derives the share to match, so the card hides
        // this slider there. Pinning still moves it between 100% (pane, where the
        // art is the point) and 30% (floating, where it is a corner accent), so
        // toggling the pane lands on a sensible size without a second slider to
        // visit.
        property int coverScale: 30

        // How long a cover takes to fade in when the album changes, in
        // milliseconds. Zero swaps instantly. The previous cover stays on screen
        // until the new one is ready either way, so even zero is flicker-free --
        // this only decides whether the swap is visibly animated.
        property int coverTransition: 400

        // Where the cover art sits: pinned in its own pane on the right ("on"),
        // pinned as the small floating corner cover ("off"), or left to "auto",
        // which shows the pane on a window with room for it beside the three
        // lists and falls back to the floating cover when the window is small.
        property string coverBandMode: "auto"

        // The smallest the panel may get, as a share of the usable width of the
        // screen it is on, and still keep the artwork pane. At or above that share
        // the pane shows; smaller than it the art folds into the floating corner
        // cover. A share of the screen rather than a pixel count, so the same
        // tiled half makes the same call on a small laptop and a large desktop
        // instead of the figure meaning one thing on one panel and another on the
        // next. The usable width is the screen less the compositor's own frame
        // (see the panel), which is what a maximised window actually measures, so
        // 100% means "fills the screen" rather than a figure nothing can reach.
        // 100% is the strictest end -- only a window filling the whole screen
        // keeps the pane -- and each step down admits smaller windows.
        property int coverBandMinPct: 100

        // Where the cover sits vertically inside the artwork pane: "top",
        // "middle" or "bottom". Only meaningful while cover band is active.
        property string coverBandAlign: "middle"

        // Keep a margin between the cover and the pane edges in the artwork pane.
        // Off runs the cover flush to the edges, filling the pane; on restores the
        // original inset on all four sides. Only meaningful while cover band is active.
        property bool coverPadding: false

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
        property int fontBody: 2
        property int fontBodySmall: 4
        property int fontCaption: 0
    }

    // ---- persistence ----
    //
    // The file is the record of what the user chose; the properties above are
    // only the fallback for a machine that has never opened the settings card.
    // Every write goes through saveSoon() so a slider drag is one file write
    // rather than one per pixel.

    readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/skollgrim.grimplayer/settings.json"
    readonly property string stateDir: statePath.substring(0, statePath.lastIndexOf("/"))

    // Quickshell.Io cannot make a directory, so the mkdir below has to run before
    // the first write. Writes are blocked until it reports back rather than
    // raced against it: on a first run the save would otherwise land in a
    // directory that does not exist yet and be lost silently.
    property bool stateDirReady: false

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
        blockWrites: !root.stateDirReady
        // Write to a temporary file and rename it into place. The obvious way to
        // write this -- `cat >` from a shell -- truncates first and writes second,
        // so two saves close together, or a shell restart mid-write, could leave
        // half a file behind. applyStored() would then meet unparseable JSON and
        // quietly reset every setting to its default, which reads as "the panel
        // forgot everything" rather than as the corruption it was. atomicWrites
        // means a reader only ever sees a whole file.
        atomicWrites: true
    }

    // `mkdir -p` in argv form, so no shell is involved: nothing to quote, and no
    // JSON anywhere near a command line. It is idempotent, so running it on every
    // start costs nothing once the directory exists. This is the only subprocess
    // left in the plugin, and it makes a directory rather than doing any of the
    // panel's work.
    Process {
        id: mkdirProc
        running: true
        command: ["mkdir", "-p", root.stateDir]
        onExited: {
            root.stateDirReady = true
        }
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
                    "playingMarkerSides", "adaptiveColors", "fetchCovers",
                    "vimKeys", "rowSpacing", "typeaheadSearch", "typeaheadPlace",
                    "typeaheadScale", "rowSeparators",
                    "focusGlow", "paneHeadings", "paneSeparators", "borderWidth", "coverBorder", "coverPlaceholder",
                    "coverBorderWidth", "coverRounded", "activeRowBorder", "repeatMode", "coverScale",
                    "coverTransition", "coverBandMode", "coverBandAlign", "coverPadding",
                    "coverBandMinPct",
                    "uiScale", "iconSize",
                    "fontTitle", "fontSubtitle", "fontBody", "fontBodySmall",
                    "fontCaption"]
        for (var i = 0; i < keys.length; i++) {
            var k = keys[i]
            if (store[k] !== undefined) out[k] = store[k]
        }
        // The schema this file was written under. Bumped only when the meaning of
        // a stored value changes rather than the value itself, so a load can tell
        // an old file from a new one. The first such change renumbered the repeat
        // modes (see Component.onCompleted).
        out.version = 2
        var body = JSON.stringify(out, null, 2)
        // The same FileView that reads the file writes it back, so there is one
        // code path for persistence rather than a native read beside a shell
        // write. atomicWrites on the FileView is what makes this safe to call on
        // every change.
        stateFile.setText(body)
    }

    // The settings-row entry behind a stored key, or null. repeatMode has no row
    // (the repeat button writes it), so it is handled by range below.
    function entryFor(key) {
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].key === key) return entries[i]
        }
        return null
    }

    // Applies a stored object over the defaults. Unknown keys are ignored and a
    // value that is not one this version offers -- the wrong type, or a number
    // or name outside the entry's options -- is dropped, so a hand-edited,
    // restored or older file degrades to "that one setting is at its default"
    // rather than taking the panel down with it. The type check alone was not
    // enough: a stored uiScale of 0 is a number, and it collapsed the settings
    // card and the now-playing strip to nothing with no way back from inside
    // the panel.
    function applyStored(obj) {
        if (!obj || typeof obj !== "object") return
        // Migrate legacy coverBand boolean to coverBandMode
        if (obj && typeof obj.coverBand === "boolean" && obj.coverBandMode === undefined) {
            obj.coverBandMode = obj.coverBand ? "on" : "off"
        }
        for (var k in obj) {
            if (store[k] === undefined) continue
            var v = obj[k]
            var current = store[k]
            var entry = root.entryFor(k)
            if (entry) {
                var offered = entry.options || []
                var accepted = false
                for (var i = 0; i < offered.length; i++) {
                    if (offered[i] === v && typeof offered[i] === typeof current) {
                        accepted = true
                        break
                    }
                }
                if (accepted) store[k] = v
                continue
            }
            // No settings row: only repeatMode, whose three modes are checked by
            // range rather than against an options list.
            if (k === "repeatMode" && typeof v === "number")
                store[k] = Math.max(0, Math.min(2, Math.round(v)))
        }
    }

    Component.onCompleted: {
        // Read synchronously: the panel mounts at shell startup and the panes
        // bind to these values on their first evaluation, so an async load would
        // show one frame at the defaults and then jump.
        var raw = stateFile.text()
        if (raw && raw.length > 0) {
            try {
                var parsed = JSON.parse(raw)
                // The repeat modes were renumbered once: a file written before that
                // stored 1 for repeat song and 2 for repeat album, where the panel
                // now numbers them the other way (1 album, 2 song). A file with no
                // schema version predates the change, so its two non-zero modes are
                // swapped before anything reads them; without this a stored repeat
                // song would come back as repeat album. Writes from here on carry
                // version 2 and take the values as they are.
                if (parsed && typeof parsed === "object"
                        && Number(parsed.version || 0) < 2) {
                    if (parsed.repeatMode === 1) parsed.repeatMode = 2
                    else if (parsed.repeatMode === 2) parsed.repeatMode = 1
                }
                applyStored(parsed)
            } catch (e) {
                // Malformed file: keep the defaults rather than failing to start.
            }
        }
    }

    readonly property bool wrapAround: store.wrapAround
    readonly property int seekThickness: store.seekThickness
    readonly property bool albumYears: store.albumYears
    readonly property bool playingHighlight: store.playingHighlight
    readonly property string playingMarkerSides: store.playingMarkerSides
    readonly property bool adaptiveColors: store.adaptiveColors
    readonly property bool fetchCovers: store.fetchCovers
    readonly property bool vimKeys: store.vimKeys
    readonly property int rowSpacing: store.rowSpacing
    readonly property bool typeaheadSearch: store.typeaheadSearch
    readonly property string typeaheadPlace: store.typeaheadPlace
    readonly property int typeaheadScale: store.typeaheadScale
    readonly property bool rowSeparators: store.rowSeparators
    readonly property bool focusGlow: store.focusGlow
    readonly property bool paneHeadings: store.paneHeadings
    readonly property bool paneSeparators: store.paneSeparators
    readonly property int borderWidth: store.borderWidth
    readonly property bool coverBorder: store.coverBorder
    readonly property bool coverPlaceholder: store.coverPlaceholder
    readonly property int coverBorderWidth: store.coverBorderWidth
    readonly property bool coverRounded: store.coverRounded
    readonly property bool activeRowBorder: store.activeRowBorder
    readonly property int repeatMode: store.repeatMode

    // Written by the repeat-mode logic rather than by the settings card, hence
    // a setter instead of an exposed entry.
    function setRepeatMode(value) {
        store.repeatMode = value
        saveSoon()
    }
    readonly property int coverScale: store.coverScale
    readonly property int coverTransition: store.coverTransition
    readonly property string coverBandMode: store.coverBandMode
    readonly property string coverBandAlign: store.coverBandAlign
    readonly property bool coverPadding: store.coverPadding
    readonly property int coverBandMinPct: store.coverBandMinPct
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

    // Bare words like "bottom" read better with a capital on a settings row.
    function titleText(value) {
        var s = String(value)
        return s.charAt(0).toUpperCase() + s.slice(1)
    }

    // Font sizes are theme offsets, so the useful thing to print is the size the
    // theme resolves to, not the delta -- a theme at 12px and an offset of +2
    // land on the same 14px and should read the same. Zero says "theme", which is
    // the value people keep coming back to and should be obvious at a glance.
    function deltaText(value) {
        if (value === 0) return "theme"
        return (value > 0 ? "+" : "") + value + " px"
    }

    // The rows the settings card offers, in the order each column shows them.
    // Each entry carries its own defaultValue, which is what reset() restores, so
    // adding an option here needs nothing else. get/set are closures rather than
    // store[key] because dynamic property access on a typed QObject is not
    // something to lean on from QML.
    //
    // Which column an entry lands in follows from a single `section` tag, and
    // table order is the order each section shows its rows. Sections are cut by
    // topic -- what part of the player the setting is about -- and not by the
    // kind of control it is, so a slider and a switch sit side by side wherever
    // the subject they share says they should. Sorting by shape instead (as this
    // table did before) put a list setting next to a font size and left every
    // new entry needing to be told which of the four columns it "was".
    //
    // An entry with `dependsOn` is greyed and non-navigable until its predicate
    // is true, rather than being hidden. Keeping the row in place means a hunt
    // for a setting always finds it. A dependent also names the row it waits on
    // in `after`, and the card sits it directly beneath that row, so the row
    // above a greyed setting is why it is greyed. Its value is kept either way,
    // so switching the parent back on restores it exactly as it was, and reset()
    // still restores it too.
    readonly property var entries: [
        // ---- List & playing ----
        {
            key: "wrapAround",
            section: "list",
            label: "Wrap lists",
            hint: "Down on the last row goes to the top, up on the first goes to the last",
            options: [true, false],
            get: function () { return store.wrapAround },
            set: function (v) { store.wrapAround = v },
            format: root.boolText
        },
        {
            key: "playingHighlight",
            section: "list",
            label: "Playing tint",
            hint: "Tint the current track while browsing its album",
            options: [true, false],
            get: function () { return store.playingHighlight },
            set: function (v) { store.playingHighlight = v },
            format: root.boolText
        },
        {
            key: "playingMarkerSides",
            section: "list",
            label: "Marker sides",
            hint: "Which edges of the playing row carry the accent bar; the tint stays either way",
            options: ["none", "left", "right", "both"],
            defaultValue: "right",
            dependsOn: function () { return store.playingHighlight },
            after: "playingHighlight",
            get: function () { return store.playingMarkerSides },
            set: function (v) { store.playingMarkerSides = v },
            format: root.titleText
        },
        {
            key: "rowSpacing",
            section: "list",
            label: "Row height",
            hint: "Height of each list row; the gap between rows follows it",
            options: [24, 28, 32, 36, 40],
            defaultValue: 28,
            get: function () { return store.rowSpacing },
            set: function (v) { store.rowSpacing = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "rowSeparators",
            section: "list",
            label: "Row lines",
            hint: "Draw a faint line between rows in each pane",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.rowSeparators },
            set: function (v) { store.rowSeparators = v },
            format: root.boolText
        },
        {
            key: "seekThickness",
            section: "list",
            label: "Seeker height",
            hint: "How thick the bar above the transport is drawn",
            // Rungs up to 15: the bar is a thin strip by default, and the top of
            // the old range (9) was where the useful settings started rather than
            // ended. The bar's slot grows with it (see SeekBar), so a thicker bar
            // takes more room rather than crowding the elapsed time above it.
            options: [3, 5, 7, 9, 11, 13, 15],
            defaultValue: 9,
            get: function () { return store.seekThickness },
            set: function (v) { store.seekThickness = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "paneHeadings",
            section: "panes",
            label: "Headings",
            hint: "Show the pane name over a rule at the top; off starts the lists at the very top",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.paneHeadings },
            set: function (v) { store.paneHeadings = v },
            format: root.boolText
        },
        {
            key: "fontBodySmall",
            section: "panes",
            label: "Heading size",
            hint: "The pane name over each pane's rule, as an offset from the theme",
            // The heading is drawn as part of the pane's header, so its size only
            // has anything to size while paneHeadings is on. It sits directly
            // under that switch, greyed while the switch is off, so the row above
            // is why it is greyed.
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 4,
            dependsOn: function () { return store.paneHeadings },
            after: "paneHeadings",
            get: function () { return store.fontBodySmall },
            set: function (v) { store.fontBodySmall = v },
            format: root.deltaText
        },
        {
            key: "paneSeparators",
            section: "panes",
            label: "Pane dividers",
            hint: "Draw the rules between the list panes and the artwork pane",
            options: [true, false],
            defaultValue: true,
            get: function () { return store.paneSeparators },
            set: function (v) { store.paneSeparators = v },
            format: root.boolText
        },
        {
            key: "focusGlow",
            section: "panes",
            label: "Dim unfocused",
            hint: "Fade the two unfocused panes so the active one stands out",
            options: [true, false],
            get: function () { return store.focusGlow },
            set: function (v) { store.focusGlow = v },
            format: root.boolText
        },
        {
            key: "activeRowBorder",
            section: "panes",
            label: "Caret frame",
            hint: "Draw a heavier frame around the caret row in the focused pane",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.activeRowBorder },
            set: function (v) { store.activeRowBorder = v },
            format: root.boolText
        },
        {
            key: "borderWidth",
            section: "panes",
            label: "Border width",
            hint: "Thickness of the outline around each pane",
            options: [1, 2, 3, 4],
            get: function () { return store.borderWidth },
            set: function (v) { store.borderWidth = v },
            format: function (v) { return v + " px" }
        },

        // ---- Navigation ----
        {
            key: "vimKeys",
            section: "list",
            label: "Vim keys",
            hint: "Use j/k/h/l/g/G for navigation",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.vimKeys },
            set: function (v) { store.vimKeys = v },
            format: root.boolText
        },
        {
            key: "typeaheadSearch",
            section: "list",
            label: "Type-to-find",
            hint: "Jump by typing first letters of names",
            options: [true, false],
            get: function () { return store.typeaheadSearch },
            set: function (v) { store.typeaheadSearch = v },
            format: root.boolText
        },
        {
            key: "typeaheadPlace",
            section: "list",
            label: "Readout",
            hint: "Where the typed letters appear: tucked in the artists pane's corner, or centred in the middle of the window",
            options: ["corner", "center"],
            defaultValue: "corner",
            dependsOn: function () { return store.typeaheadSearch },
            after: "typeaheadSearch",
            get: function () { return store.typeaheadPlace },
            set: function (v) { store.typeaheadPlace = v },
            format: root.titleText
        },
        {
            key: "typeaheadScale",
            section: "list",
            label: "Readout size",
            hint: "The readout's text size, as an offset from the theme",
            // Bias large: the readout is a transient overlay read at a glance from
            // wherever the eye happens to be, so the useful half of the range is
            // the upper one and +6 is the resting size. The floor is the theme's
            // own size rather than a step below it -- the readout is meant to
            // stand out, and a smaller-than-theme setting was a way to make it
            // harder to read than the text it is drawn over.
            options: [0, 1, 2, 3, 4, 5, 6, 7, 8],
            defaultValue: 6,
            dependsOn: function () { return store.typeaheadSearch },
            after: "typeaheadSearch",
            get: function () { return store.typeaheadScale },
            set: function (v) { store.typeaheadScale = v },
            format: root.deltaText
        },

        // ---- Text & scale ----
        {
            key: "uiScale",
            section: "text",
            label: "UI scale",
            hint: "Scales rows, spacing, fonts, icons and cover art together",
            options: [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5],
            defaultValue: 1.0,
            get: function () { return store.uiScale },
            set: function (v) { store.uiScale = v },
            format: function (v) { return (v * 100).toFixed(0) + "%" }
        },
        {
            key: "iconSize",
            section: "text",
            label: "Icon size",
            hint: "Transport and UI icons",
            options: [12, 14, 16, 18, 20],
            defaultValue: 16,
            get: function () { return store.iconSize },
            set: function (v) { store.iconSize = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "fontTitle",
            section: "text",
            label: "Now playing",
            hint: "Now playing title, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 0,
            get: function () { return store.fontTitle },
            set: function (v) { store.fontTitle = v },
            format: root.deltaText
        },
        {
            key: "fontSubtitle",
            section: "text",
            label: "Rows",
            hint: "Album and track rows, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 0,
            get: function () { return store.fontSubtitle },
            set: function (v) { store.fontSubtitle = v },
            format: root.deltaText
        },
        {
            key: "fontBody",
            section: "text",
            label: "Artist & time",
            hint: "Artist and the elapsed/total time, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 2,
            get: function () { return store.fontBody },
            set: function (v) { store.fontBody = v },
            format: root.deltaText
        },
        {
            key: "fontCaption",
            section: "text",
            label: "Status banner",
            hint: "The MPD error banner, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            defaultValue: 0,
            get: function () { return store.fontCaption },
            set: function (v) { store.fontCaption = v },
            format: root.deltaText
        },
        {
            key: "adaptiveColors",
            section: "wide",
            label: "Cover recolour",
            hint: "Follow the current album cover instead of the shell theme",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.adaptiveColors },
            set: function (v) { store.adaptiveColors = v },
            format: root.boolText
        },
        {
            key: "albumYears",
            section: "text",
            label: "Album years",
            hint: "Prefix each album with its release year, read from the Date tag",
            options: [true, false],
            get: function () { return store.albumYears },
            set: function (v) { store.albumYears = v },
            format: root.boolText
        },

        // ---- Cover art ----
        //
        // Every entry in this section carries section: "artwork". That is what
        // the card gathers into its own Artwork column, so the cover settings sit
        // together in one place rather than split across the other topics.
        {
            key: "coverBorder",
            section: "artwork",
            label: "Cover border",
            hint: "Ring around the cover art, separate from the pane rules",
            options: [true, false],
            defaultValue: false,
            get: function () { return store.coverBorder },
            set: function (v) { store.coverBorder = v },
            format: root.boolText
        },
        {
            key: "coverBorderWidth",
            section: "artwork",
            label: "Cover border width",
            hint: "Thickness of the ring around the cover art",
            options: [1, 2, 3, 4, 6, 8],
            defaultValue: 1,
            dependsOn: function () { return store.coverBorder },
            after: "coverBorder",
            get: function () { return store.coverBorderWidth },
            set: function (v) { store.coverBorderWidth = v },
            format: function (v) { return v + " px" }
        },
        {
            key: "coverRounded",
            section: "artwork",
            label: "Round corners",
            hint: "Round the artwork's corners; off draws it as a plain square",
            options: [true, false],
            defaultValue: true,
            get: function () { return store.coverRounded },
            set: function (v) { store.coverRounded = v },
            format: root.boolText
        },
        {
            key: "coverTransition",
            section: "artwork",
            label: "Cover fade",
            hint: "Fade the new album cover in over the old one; instant is a plain swap",
            options: [0, 100, 200, 300, 400, 500, 600],
            defaultValue: 400,
            get: function () { return store.coverTransition },
            set: function (v) { store.coverTransition = v },
            format: function (v) { return v === 0 ? "instant" : v + " ms" }
        },
        {
            key: "coverPlaceholder",
            section: "artwork",
            label: "Placeholder art",
            hint: "Show a CD when the album has no artwork, or leave the space empty",
            options: [true, false],
            defaultValue: true,
            get: function () { return store.coverPlaceholder },
            set: function (v) { store.coverPlaceholder = v },
            format: root.boolText
        },

        // The pane settings sit together, the mode row first, with its dependents
        // grouped under it: the card sits each one directly beneath the row it
        // waits on, so the mode reads as the head of its own little block.
        {
            key: "coverBandMode",
            section: "artwork",
            label: "Cover pane",
            hint: "Give the album art its own pane on the right, or let it follow window size",
            options: ["off", "on", "auto"],
            defaultValue: "auto",
            get: function () { return store.coverBandMode },
            set: function (v) {
                store.coverBandMode = v
                // Pinning the placement moves the artwork size to match it: the
                // pane wants to be full, the floating cover small. Auto reads the
                // size from the window instead, so it leaves the stored value
                // alone rather than writing a number auto will ignore.
                //
                // No save here: every caller of set already persists (cycle for a
                // keypress, reset for the reset key, the slider's own pick), so a
                // save in here would only restart the same debounce. The write it
                // does is a second property on the same store, which the caller's
                // save then covers along with this one.
                if (v === "on") store.coverScale = 100
                else if (v === "off") store.coverScale = 30
            },
            format: root.titleText
        },
        {
            key: "coverBandAlign",
            section: "artwork",
            label: "Cover position",
            hint: "Where the cover sits vertically in the artwork pane",
            options: ["top", "middle", "bottom"],
            defaultValue: "middle",
            dependsOn: function () { return store.coverBandMode !== "off" },
            after: "coverBandMode",
            get: function () { return store.coverBandAlign },
            set: function (v) { store.coverBandAlign = v },
            format: root.titleText
        },
        {
            key: "coverPadding",
            section: "artwork",
            label: "Cover padding",
            hint: "Keep a margin between the cover and the pane edges; off runs it flush",
            options: [true, false],
            defaultValue: false,
            dependsOn: function () { return store.coverBandMode !== "off" },
            after: "coverBandMode",
            get: function () { return store.coverPadding },
            set: function (v) { store.coverPadding = v },
            format: root.boolText
        },
        {
            key: "coverScale",
            section: "artwork",
            label: "Cover size",
            hint: "Height of the artwork as a share of the space above the now-playing bar; 100% fills it top to bottom",
            // Even ten-step rungs, rather than the old fives low down and tens up
            // top, so a nudge moves the cover the same amount wherever the knob is.
            options: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
            // The floating placement's resting size; the pane's 100% is applied by
            // the artwork-pane toggle above. This is what reset() lands on. It is
            // only editable while the pane is pinned off, where the floating cover
            // is the arrangement and its size is genuinely the user's to set: under
            // "auto" the window picks the placement and the size that goes with it,
            // and pinned "on" the pane's own full height is what the toggle above
            // just wrote into this value, so offering the slider there would be
            // offering to undo the choice that was just made.
            defaultValue: 30,
            dependsOn: function () { return store.coverBandMode === "off" },
            after: "coverBandMode",
            get: function () { return store.coverScale },
            set: function (v) { store.coverScale = v },
            format: function (v) { return v + "%" }
        },
        {
            key: "coverBandMinPct",
            section: "artwork",
            label: "Pane above",
            hint: "Show the pane while the window is at least this share of the screen's width; smaller than that the cover floats instead",
            // The size floor the panel measures the window against, as a share of
            // the screen it is on. 100% keeps the pane only while the window fills
            // the screen; lower it to admit smaller windows. Five-step rungs so a
            // nudge is visible without walking a long ramp.
            options: [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100],
            defaultValue: 100,
            dependsOn: function () { return store.coverBandMode === "auto" },
            after: "coverBandMode",
            get: function () { return store.coverBandMinPct },
            set: function (v) { store.coverBandMinPct = v },
            format: function (v) { return v + "%" }
        },

        // ---- Player wide ----
        {
            key: "fetchCovers",
            section: "wide",
            label: "Fetch covers",
            hint: "Look a cover up on iTunes or Deezer when an album has none, and cache it",
            options: [true, false],
            defaultValue: true,
            get: function () { return store.fetchCovers },
            set: function (v) { store.fetchCovers = v },
            format: root.boolText
        },
    ]

    function textOf(entry) {
        return entry.format(entry.get())
    }

    // A slider is anything numeric; everything else is a switch or a named
    // choice. This no longer decides which column an entry lands in -- topic
    // does -- but the card still needs it to know whether a row draws a track.
    function isSlider(entry) {
        var o = entry ? entry.options : null
        return !!(o && o.length > 0 && typeof o[0] === "number")
    }

    // Whether a dependent setting's parent is satisfied. Every entry is in the
    // card either way; this is what the row is greyed and made non-navigable on
    // while it is false.
    function isActive(entry) {
        return !entry || !entry.dependsOn || entry.dependsOn()
    }

    // Every entry the card draws, in table order. Nothing is filtered out any
    // more: a dependent whose parent is off stays in the list, greyed, so a hunt
    // for a setting always finds the row and the row can say what it is waiting
    // on. It is not navigable and not editable in that state (see isActive, which
    // the panel's movement and the card's clicks both check), but its stored
    // value is untouched and reset() still restores it.
    readonly property var visibleEntries: entries

    // The sections the card draws, in column order, each a name and the tag its
    // entries carry. A section is one topic -- the lists and what plays them, the
    // panes and their rules, the text and scale, the cover art, the extras --
    // rather than one kind of control, so a slider and a switch sit together
    // wherever their subject says they should.
    //
    // The last section hugs its content instead of taking an equal share: it
    // holds a single row with a short label, so filling a full column with it
    // only starved the sections beside it.
    readonly property var sections: [
        { tag: "list", name: "List & playing" },
        { tag: "panes", name: "Panes & layout" },
        { tag: "text", name: "Text & scale" },
        { tag: "artwork", name: "Artwork" },
        { tag: "wide", name: "Player wide", fill: false }
    ]

    // Each row carries its entry, that entry's index into the table, and whether
    // the entry is currently active. The index is the caret's currency: an object
    // identity does not survive the trip through a Repeater's model -- the
    // delegate's modelData hands back a copy, so comparing references never
    // matched and nothing ever read as selected -- while a plain integer does.
    //
    // The index comes from the entry's own position rather than an indexOf scan:
    // visibleEntries is the entries table itself now, so the row's index is the
    // table index, and stamping it here is what lets the Repeater hand it back as
    // a plain number.
    function indexed(list) {
        var out = []
        for (var i = 0; i < list.length; i++)
            out.push({
                entry: list[i],
                index: visibleEntries.indexOf(list[i]),
                active: isActive(list[i])
            })
        return out
    }

    // The table order, arranged so every dependent sits directly under the row it
    // waits on. An entry naming a parent in `after` is pulled up beside it; one
    // without keeps its table position. The arrangement is done here rather than
    // left to the table's written order so that "a dependent sits under its
    // parent" is a property of the list the card draws, not a thing a later edit
    // to the table can quietly break -- and so a parent's dependents keep their
    // own order among themselves.
    //
    // Each parent is walked once, emitting the parent and then everything that
    // names it, in table order. Entries are only emitted once, so a table written
    // in any order comes out the same way.
    function arranged() {
        var out = []
        var used = {}
        for (var i = 0; i < visibleEntries.length; i++) {
            var e = visibleEntries[i]
            if (used[e.key]) continue
            out.push(e)
            used[e.key] = true
            // Everything waiting on this row, in table order, goes directly
            // beneath it.
            for (var j = 0; j < visibleEntries.length; j++) {
                var d = visibleEntries[j]
                if (d.after === e.key && !used[d.key]) {
                    out.push(d)
                    used[d.key] = true
                }
            }
        }
        return out
    }

    // The entries behind each section, worked out once and read by the card, the
    // navigation and the caret's column lookup alike. Filtering the table five
    // times over on every read would be five passes over every entry each time
    // the caret moves a row, for a list that only changes when a dependent flips.
    readonly property var sectionLists: {
        var out = {}
        for (var i = 0; i < sections.length; i++) out[sections[i].tag] = []
        var rows = arranged()
        for (var e = 0; e < rows.length; e++) {
            var tag = rows[e].section
            if (out[tag] !== undefined) out[tag].push(rows[e])
        }
        return out
    }

    readonly property var columns: sections.map(function (s) {
        return { name: s.name, items: indexed(sectionLists[s.tag] || []), fill: s.fill }
    })

    // The entries behind a column, for the panel's navigation.
    function columnEntries(column) {
        var s = sections[column]
        return s ? (sectionLists[s.tag] || []) : []
    }

    // Which column an entry sits in, from its section tag. An entry with no tag
    // -- one added without reading the note above -- falls to the first section
    // rather than vanishing, so the card still shows it.
    function columnOf(index) {
        var e = visibleEntries[index]
        if (!e) return 0
        for (var i = 0; i < sections.length; i++) {
            if (sections[i].tag === e.section) return i
        }
        return 0
    }

    function rowOf(index) {
        var e = visibleEntries[index]
        if (!e) return 0
        var list = columnEntries(columnOf(index))
        return Math.max(0, list.indexOf(e))
    }

    // The visibleEntries index at a column and row. A row past the end clamps to
    // the column's last entry -- so stepping sideways into a shorter column lands
    // on its bottom rather than stalling -- and an empty column answers -1.
    function indexAt(column, row) {
        var list = columnEntries(column)
        if (list.length === 0) return -1
        var r = Math.max(0, Math.min(row, list.length - 1))
        return visibleEntries.indexOf(list[r])
    }

    // Step to the next or previous option. indexOf answers -1 for a value that
    // is not in the list at all -- an older or hand-edited state file. A stale
    // value takes the first option whichever way the user steps: the bare
    // arithmetic wraps -1 past the end on a step back and would land on the
    // second-to-last option instead.
    //
    // An inactive entry refuses outright. The row is visible but parked behind
    // the setting it waits on, so changing it from the card would edit something
    // with no effect and no way to see that it is doing anything.
    function cycle(entry, delta) {
        if (!isActive(entry)) return
        var options = entry.options
        var i = options.indexOf(entry.get())
        if (i === -1) {
            entry.set(options[0])
            saveSoon()
            return
        }
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
