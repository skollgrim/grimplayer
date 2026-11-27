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
import "Paths.js" as Paths

Item {
    id: root

    // Scalars rather than one packed object: a typed property is what
    // round-trips through JSON cleanly, and the row table below only ever
    // reaches them through get/set closures.
    QtObject {
        id: store

        // The root MPD reports every file path relative to: mpd.conf's
        // music_directory. On a machine that has never saved a folder, the panel
        // adopts the value MPD reports over its own `config` command (see
        // GrimPlayer.adoptMusicDir); until then -- and for a remote or older MPD
        // that refuses that command -- it starts at $XDG_MUSIC_DIR, or ~/Music.
        // Every local path in the plugin follows it: tag saves, embedded
        // artwork, sidecar lyrics and the folder shortcut. A value that is not
        // an absolute path is refused on load, leaving the default in place
        // rather than pointing every file operation at a path that cannot be
        // right.
        property string musicDir:
            Paths.musicDir(Quickshell.env("XDG_MUSIC_DIR"), Quickshell.env("HOME"))

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

        // Air above the now-playing title, in logical pixels. The strip grows by
        // this much and its content row is inset by the same amount, so raising
        // it adds breathing room without moving the title or the transport. The
        // small default keeps the strip tight on a laptop panel.
        property int stripTopGap: 2

        // Year prefix on the albums pane, from the tracks' Date tags.
        property bool albumYears: true

        // Which edges of the playing row carry the accent bar: "none", "left",
        // "right" or "both". The tint is always on -- this only decides where
        // the bars sit, so "none" keeps the tint and drops the bars. The left
        // edge is the default: it marks the row in the margin before the labels
        // and leaves the duration on the right unobstructed.
        property string playingMarker: "left"
        property string coverDecodeSize: "medium"

        // Recolour the whole panel from the playing album's cover art, instead
        // of following the shell theme. Off is the theme-following look.
        property bool adaptiveColors: false

        // Look up a cover from the stores (iTunes, then Deezer) for an album with
        // no sidecar and no embedded picture, and cache it for display. Off keeps
        // the player entirely offline and such albums on the placeholder.
        property bool fetchCovers: true

        // What the letter keys do in the lists: "find" jumps to a matching row
        // as it is typed, "vim" uses j/k/h/l/g/G, and "off" leaves letters
        // inert. The arrow keys navigate in every mode.
        property string keyboardStyle: "find"

        // Height of one list row in logical pixels. The gap between rows is
        // derived from this (an eighth of the row), so one control sets the whole
        // row rhythm -- a separate gap slider only ever fought the row height.
        property int rowSpacing: 28

        // Where the transient readouts sit: typed letters, the Ctrl transport reply
        // and MPD's error banner all share this home. Both places centre on the
        // tracks pane (yielding left when a floating cover is in the way):
        // "bottom" puts them in the band just above the now-playing strip, and
        // "center" floats them in the middle of the list area, where the eye already
        // is when the lists are long enough that a band readout is easy to miss.
        // The old key is kept so an existing file's choice survives the rename to
        // "Notice position"; a named choice leaves room for a third place.
        property string findPlace: "bottom"

        // One size for every transient notice: typed letters, the transport
        // reply and MPD's error line. It is an offset from each notice's own
        // resting size, so the default keeps the panel's current look and moving
        // the one knob moves all three together. The original "find" name stays
        // as the stored key; the settings row is now called "Notice size".
        property int findScale: 6

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

        // Line width: the vertical rules between the panes, the underline beneath
        // each pane heading, and the two rules on the now-playing strip. One
        // setting for them all, so lines that meet the eye together carry the same
        // weight -- a divider and a heading underline that disagreed would read as
        // two different sorts of line. The cover art's ring is deliberately not
        // one of them: it has its own width (coverBorderWidth) so the art's frame
        // and the pane rules never drag each other along. This is greyed only
        // while all four of its homes are off (see the entry), which is the one
        // state where nothing on screen is drawn with it.
        property int borderWidth: 1

        // A quiet hairline along the strip's top edge, in the pane rule colour and
        // width. Off leaves the colour step in GrimTheme.strip as the only
        // boundary, which is how the strip looked before the rule. The hairline
        // stands down while the seeker itself is the edge.
        property bool stripSeparator: true

        // The bolder boundary: the seek bar runs the full width of the strip's
        // top edge, with the track details and controls beneath it. The strip
        // grows by the bar's slot and the row is inset by the same amount, so
        // the transport does not get pushed around when this is switched on.
        property bool stripSeekEdge: false

        // How the strip's progress reads. On, elapsed, seek and total share one
        // row and the strip gives back the space the old clock line took; off
        // restores the stacked seek and `elapsed / total` line.
        property bool progressInline: true

        // The clock is a detail beside the track, not a second artist line. On,
        // it uses the theme's small body size; off restores the older body size
        // shared with the artist.
        property bool quietTime: true

        property bool coverBorder: false
        property bool coverPlaceholder: true
        property int coverBorderWidth: 1

        // The small preview of the album that follows the playing one, shown in
        // album view above the now-playing bar. Off leaves that corner empty; the
        // size is a share of the default tile, so the preview can be nudged
        // without changing the panel's general UI scale.
        property bool upNextCover: true
        property int upNextCoverSize: 150

        // What is named above the titles in album view: "off" leaves the surface
        // to the songs, "title" names the record, "artist" names the artist,
        // "both" names the two, and "full" adds the year and running time. How
        // that line is drawn is no longer a second choice: Info text sets both
        // its size and, as it grows, its weight from muted label to small heading.
        property string albumInfo: "full"

        // Album view's track list has its own type size and rhythm: the large
        // centred titles are read at a glance while the record plays, so the
        // browser's "Rows" no longer changes them. Both are offsets from the
        // current look -- zero keeps today's type and gap exactly as they are.
        property int albumFont: 0
        property int albumTrackSpacing: 0

        // Where album view's titles sit. "center" is the surface's own look;
        // "left" lines them up with the column margin. The words have their own
        // alignment (see lyricsAlign) that follows them through every surface.
        property string trackAlign: "center"

        // The playing track's lyrics beside the album's titles, sharing album
        // view with the compact track column. Off leaves the surface to the
        // record alone.
        property bool albumLyrics: false

        // How the tracks pane writes each number before its title. "dot" is
        // "01. Title" and "dash" is "01 - Title"; both are zero-padded to two
        // digits so a column of tracks lines up.
        property string trackNumberFormat: "dot"

        // Draw the track numbers in the muted ink, the same grey as the
        // durations, so the titles lead and the numbers read as quiet indexes.
        property bool trackNumberMuted: false

        // Corner radius of the artwork, in logical pixels. Zero draws a plain
        // square, corner to corner; the border ring follows the same radius. Ten
        // is the radius the rounded look always had.
        property int coverRoundness: 10

        // Album view and karaoke frame a large cover, so each can choose the
        // fuller 20px radius instead of the global artwork radius. Both start on.
        property bool albumCoverRound: true
        property bool karaokeCoverRound: true

        // Which repeat mode the panel is in: 0 off, 1 repeat album, 2 repeat song.
        // Stored here rather than read back from MPD because album repeat is a loop
        // this player performs itself: MPD's repeat is a plain boolean over the
        // whole queue and its flag stays off in album mode, so the stored mode is
        // the only place the real answer lives.
        property int repeatMode: 0

        // Which shuffle scope is in force: 0 off, 1 the playing album, 2 the
        // artist, 3 the whole library. MPD's random flag says only that something
        // is shuffled, never what the pool is, so the scope lives here for the same
        // reason the repeat mode does.
        property int shuffleMode: 0

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

        // The covers album view and karaoke size for themselves, as a share of
        // the room each layout can give them: 100 leaves the natural fit alone,
        // smaller values hold the art back. The library/browser cover keeps its
        // own size under Artwork (coverScale); these two live with their views.
        property int albumCoverScale: 100
        property int karaokeCoverScale: 100

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

        // Keep a margin between the cover and the library pane edges. Off runs the
        // browser art flush; on restores the inset on all four sides. Album view
        // keeps the same right margin as karaoke either way. Only meaningful while
        // cover band is active.
        property bool coverPadding: false

        // Interface sizing. uiScale is a single multiplier over every derived size --
        // rows, gap, fonts, icons and cover art -- so one slider rescales the
        // whole player rather than only the lists.
        // The range runs 50% to 150%: far enough down to matter on a 4K screen,
        // far enough up to matter on a laptop.
        property real uiScale: 1.0

        // How solid the settings card is over the panel. One keeps the opaque
        // card it has always had; lower values let the dimmed player show through.
        property real settingsOpacity: 1.0

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

        // ---- lyrics ----
        //
        // The lyric surfaces are set apart from the lists: they have their own
        // size offsets, line spacing and measure rather than borrowing the pane
        // rows' values. Every default here reproduces the views as they looked
        // before these settings existed.
        //
        // Marking the current line is the point, and each surface has its own
        // choice: lyricsFollow governs the reading view and the words that share
        // album view, karaokeFollow the surface read from across the room. Both
        // use "follow" to scroll to the line, "highlight" to mark it in place and
        // "off" to mark nothing. The two surfaces also keep separate size,
        // alignment, track header and cover values -- karaoke's below, the
        // reading view's later in the file.
        property string lyricsAlign: "left"
        // A lyrics-only offset from the theme, like the other font sizes. It
        // starts at the body text's own +2 so the view opens exactly as it did.
        property int lyricsFont: 2
        // Which pieces of the track's identity are written above the reading
        // view's words. Separate switches so any one can stand on its own.
        property bool lyricsInfoTitle: true
        property bool lyricsInfoArtist: true
        property bool lyricsInfoAlbum: false
        // The current line is highlighted by default; "follow" also scrolls the
        // view to keep it centred, "highlight" leaves the text where it is, and
        // "off" marks nothing -- the reading mode for plain lyrics or reading
        // ahead. Highlighting is the main behaviour; following is the modifier.
        property string lyricsFollow: "follow"
        // Karaoke opens marking and following as it always has, but its own
        // choice means turning the reading view's highlight off need not dim a
        // view built around the moving line.
        property string karaokeFollow: "follow"
        // Gap between lyric lines, in logical pixels. Shared with karaoke.
        property int lyricsSpacing: 8
        // How wide the reading column may get: "full", "wide" (80%) or "narrow"
        // (65%). The column stays centred, so a narrow measure reads as a column
        // rather than as text pushed against one side.
        property string lyricsWidth: "full"
        // How far the non-current lines fade: "subtle", "medium" or "strong".
        // Shared with karaoke.
        property string lyricsDim: "medium"
        // Whether the cover stays beside the lyrics or gives them the full
        // width. "hide" affects the lyrics view's side pane only; the browser
        // and karaoke are untouched.
        property string lyricsCover: "show"
        // Show the playing album's tracks beside the lyrics. Off leaves the
        // reading view as words and cover alone; on a panel too narrow for both
        // columns the words keep the width and the tracks step aside.
        property bool lyricsTracks: false

        // ---- karaoke view ----
        //
        // Karaoke has its own size rather than borrowing the lyrics view's: it
        // is read from across the room, so wanting the words larger there should
        // not also enlarge the reading view. It starts at the lyrics default so
        // the view opens exactly as it did before the setting existed.
        property int karaokeFont: 2
        // Where karaoke's words sit. Centre is where the view opened; left lines
        // them up with the margin beside the cover. Separate from lyricsAlign so
        // a change to the reading view cannot move a view read from across the
        // room.
        property string karaokeAlign: "center"
        // Which details are written above karaoke's scrolling words. Each piece
        // has its own switch, so an artist can be shown without a title and the
        // album can join either. The header sits outside the scroll, so the
        // details stay put while the words move.
        property bool karaokeInfoTitle: true
        property bool karaokeInfoArtist: true
        property bool karaokeInfoAlbum: false
        // Where karaoke puts the cover: "side" sets it to the right of the
        // lyrics and shifts the text left, "background" lays a sized wash over
        // the view at low opacity behind the text, and "hide" leaves the lyrics
        // centred on their own. A separate choice from the side pane: the two
        // layouts are different enough that hiding one should not silently hide
        // the other.
        property string karaokeCover: "side"
        // How strongly the background cover shows through. Only read in the
        // "background" mode; a side cover is drawn at full strength.
        property real karaokeCoverOpacity: 0.2
        // How much of the karaoke view the background cover fills. Separate from
        // the side cover's size: a wash can be pulled in without shrinking the
        // square artwork beside the words. 100 is the full-window wash.
        property int karaokeBackgroundScale: 100

        // ---- shared lyric behaviour ----
        //
        // These apply to the words wherever they are drawn: the reading view,
        // karaoke, and album view when it shares the playing track's lyrics.
        // How long a manual scroll suspends following before the view returns
        // to the playing line. Zero never resumes: the reader keeps the view
        // where they put it until the track changes or the view is reopened.
        property int lyricsResume: 5000
        // Timing correction for synced lyrics that run early or late, in
        // milliseconds. Positive delays the highlight.
        property int lyricsOffset: 0
        // Ask lrclib when a track has nothing on disk. Off keeps the player
        // offline and local-only, the same promise Fetch covers makes.
        property bool lyricsDownloads: true
        // Clicking a timed lyric line seeks to it. Off makes the text inert,
        // for anyone who would rather not seek by accident.
        property bool lyricsClickSeek: true
    }

    // ---- persistence ----
    //
    // The file is the record of what the user chose; the properties above are
    // only the fallback for a machine that has never opened the settings card.
    // Every write goes through saveSoon() so a slider drag is one file write
    // rather than one per pixel.

    readonly property string stateDir:
        Paths.stateDir(Quickshell.env("XDG_STATE_HOME"), Quickshell.env("HOME"))
    readonly property string statePath: stateDir + "/settings.json"

    // Quickshell.Io cannot make a directory, so the mkdir below has to run before
    // the first write. Writes are blocked until it reports back rather than
    // raced against it: on a first run the save would otherwise land in a
    // directory that does not exist yet and be lost silently.
    property bool stateDirReady: false

    // What reset() restores: the store's own initialisers, captured before the
    // stored file is applied. Keeping them here rather than in every entry means
    // a row cannot drift from the state it is meant to restore -- the property
    // declaration at the top of this file is the only place a default is written
    // down -- and adding an option still needs nothing else.
    property var codeDefaults: ({})

    // Whether the current music folder came from the stored file or from a
    // choice made in the card. False on a machine that has never saved one,
    // which is the only state in which the service may adopt MPD's own
    // music_directory over the XDG default. Not persisted: a file that carries a
    // musicDir is itself the record that one was chosen.
    property bool musicDirSaved: false

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
        var keys = ["musicDir", "wrapAround", "seekThickness", "stripTopGap", "albumYears",
                    "playingMarker", "adaptiveColors", "fetchCovers",
                    "keyboardStyle", "rowSpacing", "findPlace",
                    "findScale", "rowSeparators",
                    "focusGlow", "paneHeadings", "paneSeparators", "borderWidth", "stripSeparator",
                    "stripSeekEdge", "progressInline", "quietTime", "coverBorder", "coverPlaceholder",
                    "coverBorderWidth", "coverRoundness", "albumCoverRound", "karaokeCoverRound",
                    "upNextCover", "upNextCoverSize",
                    "albumInfo", "albumFont", "albumTrackSpacing",
                    "trackAlign", "albumLyrics",
                    "repeatMode", "shuffleMode", "coverScale",
                    "albumCoverScale", "karaokeCoverScale",
                    "trackNumberFormat", "trackNumberMuted",
                    "coverTransition", "coverBandMode", "coverBandAlign", "coverPadding",
                    "coverBandMinPct",
                    "uiScale", "settingsOpacity", "iconSize",
                    "fontTitle", "fontSubtitle", "fontBody", "fontBodySmall",
                    "fontCaption", "coverDecodeSize",
                    "lyricsAlign", "lyricsFont", "lyricsInfoTitle", "lyricsInfoArtist",
                    "lyricsInfoAlbum", "lyricsFollow",
                    "karaokeAlign", "karaokeFollow",
                    "lyricsDim", "lyricsResume", "lyricsSpacing", "lyricsWidth",
                    "lyricsCover", "karaokeFont", "karaokeInfoTitle", "karaokeInfoArtist",
                    "karaokeInfoAlbum", "karaokeCover", "karaokeCoverOpacity", "karaokeBackgroundScale",
                    "lyricsOffset", "lyricsClickSeek", "lyricsDownloads", "lyricsTracks"]
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
        // A file written before the cover gained modes stored the band as a
        // boolean. Keep that choice: true means the band and false means off,
        // rather than letting the value fail the type check and fall back to the
        // default.
        if (obj && typeof obj.coverBand === "boolean" && obj.coverBandMode === undefined) {
            obj.coverBandMode = obj.coverBand ? "on" : "off"
        }
        // Corner rounding was a toggle; it is a radius now. A file that chose
        // square keeps square, and one that chose round keeps the old 10px look.
        // An explicit radius always wins over the old switch.
        if (obj.coverRoundness === undefined && obj.coverRounded !== undefined)
            obj.coverRoundness = obj.coverRounded ? 10 : 0
        // The playing row's tint used to be a switch; it is always on now. A
        // file that chose where the accent bar sits keeps that choice.
        if (obj.playingMarker === undefined && obj.playingMarkerSides !== undefined)
            obj.playingMarker = obj.playingMarkerSides
        // Vim keys and type-to-find were two switches over the same letter keys,
        // so they are one choice now. Vim wins when both were on; with both off
        // the letters stay inert. An explicit keyboardStyle always wins.
        if (obj.keyboardStyle === undefined
                && (obj.vimKeys !== undefined || obj.typeaheadSearch !== undefined)) {
            if (obj.vimKeys === true) obj.keyboardStyle = "vim"
            else if (obj.typeaheadSearch === false) obj.keyboardStyle = "off"
            else obj.keyboardStyle = "find"
        }
        // The find readout moved with the setting's rename. Its old second home
        // was the artists pane's corner, which no longer exists: keep the band
        // placement rather than falling back to the default by accident.
        if (obj.findPlace === undefined && obj.typeaheadPlace !== undefined)
            obj.findPlace = obj.typeaheadPlace === "corner" ? "bottom" : obj.typeaheadPlace
        if (obj.findScale === undefined && obj.typeaheadScale !== undefined)
            obj.findScale = obj.typeaheadScale
        // Alignment used to be one setting for the album's titles and the words
        // sharing the surface. It is now split: trackAlign for the titles, and
        // the words follow lyricsAlign wherever they appear. A file with the old
        // key keeps the title alignment it chose; the words take the reading
        // view's alignment, which is the setting they now share.
        if (obj.trackAlign === undefined && obj.albumAlign !== undefined) {
            obj.trackAlign = obj.albumAlign
        }
        // The album caption used to be a plain switch. A file that chose it keeps
        // the same surface: on keeps the full caption, off shows none of it.
        if (obj.albumInfo === undefined && obj.albumCaption !== undefined) {
            obj.albumInfo = obj.albumCaption ? "full" : "off"
        }
        // Caption style and caption size were two rows over the same line; Info
        // text is one. Fold the old style's size lift into the stored offset so a
        // label or heading keeps its emphasis instead of silently going quiet.
        // An explicit Info text value still wins on its own; both together add
        // the lift, clamped to the new range.
        var oldStyleLift = obj.albumInfoStyle === "heading" ? 4
            : obj.albumInfoStyle === "label" ? 1 : 0
        if (oldStyleLift !== 0) {
            var oldInfoOffset = Number(obj.fontCaption)
            if (!isFinite(oldInfoOffset)) oldInfoOffset = 0
            obj.fontCaption = Math.max(-4,
                Math.min(16, oldInfoOffset + oldStyleLift))
        }
        // Karaoke used to share the lyrics view's size. A file written before
        // the split has no karaokeFont, so seed it from the lyrics size: the
        // karaoke text keeps the size it had, and the two only part company once
        // one of them is changed. A file that has neither keeps the default.
        if (obj.karaokeFont === undefined && obj.lyricsFont !== undefined) {
            obj.karaokeFont = obj.lyricsFont
        }
        // The karaoke cover was a plain switch before it gained placements. A
        // stored true keeps the cover on the new default side; false keeps it
        // hidden rather than letting the old value fail the type check and
        // silently turn the cover back on.
        if (typeof obj.karaokeCover === "boolean") {
            obj.karaokeCover = obj.karaokeCover ? "side" : "hide"
        }
        // The track headers used to be one choice per view. Fold each stored
        // choice into the switches that replace it: "off" shows nothing, "track"
        // and "title" only the name, "both" the name and artist, and "all" the
        // album as well. The reading view never offered an album line, so its
        // new switch starts off. An explicit switch always wins over the choice.
        var oldKaraokeInfo = obj.karaokeInfo
        if (oldKaraokeInfo === "off" || oldKaraokeInfo === "track"
                || oldKaraokeInfo === "both" || oldKaraokeInfo === "all") {
            if (obj.karaokeInfoTitle === undefined)
                obj.karaokeInfoTitle = oldKaraokeInfo !== "off"
            if (obj.karaokeInfoArtist === undefined)
                obj.karaokeInfoArtist = oldKaraokeInfo === "both" || oldKaraokeInfo === "all"
            if (obj.karaokeInfoAlbum === undefined)
                obj.karaokeInfoAlbum = oldKaraokeInfo === "all"
        }
        var oldLyricsInfo = obj.lyricsInfo
        if (oldLyricsInfo === "off" || oldLyricsInfo === "title"
                || oldLyricsInfo === "both") {
            if (obj.lyricsInfoTitle === undefined)
                obj.lyricsInfoTitle = oldLyricsInfo !== "off"
            if (obj.lyricsInfoArtist === undefined)
                obj.lyricsInfoArtist = oldLyricsInfo === "both"
            if (obj.lyricsInfoAlbum === undefined)
                obj.lyricsInfoAlbum = false
        }
        // Album view and karaoke's side cover used to share one size. Seed both
        // view rows from the old key so an existing file keeps the size it had;
        // an explicit new key always wins. The background wash was seeded from
        // the same old value when it gained its own row.
        if (obj.stageCoverScale !== undefined) {
            // The old row reached 10%; the new one starts at 50, so lift a
            // smaller saved value into the first rung rather than losing it.
            var oldStage = Number(obj.stageCoverScale)
            if (isFinite(oldStage)) {
                if (obj.albumCoverScale === undefined)
                    obj.albumCoverScale = Math.max(50, Math.min(150, oldStage))
                if (obj.karaokeCoverScale === undefined)
                    obj.karaokeCoverScale = Math.max(50, Math.min(110, oldStage))
            }
            if (obj.karaokeBackgroundScale === undefined)
                obj.karaokeBackgroundScale = obj.stageCoverScale
        }
        for (var k in obj) {
            if (store[k] === undefined) continue
            var v = obj[k]
            var current = store[k]
            var entry = root.entryFor(k)
            if (entry) {
                // A free-text row has no rungs to check against. Its own
                // normaliser decides: an absolute path (with ~ expanded and a
                // trailing slash dropped) is accepted, anything else leaves the
                // default in place.
                if (entry.kind === "text") {
                    if (typeof v === "string") {
                        var clean = entry.normalize ? entry.normalize(v) : v
                        if (clean !== "" && clean !== undefined) {
                            store[k] = clean
                            // A folder in the file is a folder that was chosen, or
                            // one an earlier run adopted and wrote down. Either way
                            // the MPD hint must not move it again.
                            if (k === "musicDir") root.musicDirSaved = true
                        }
                    }
                    continue
                }
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
            // No settings row: only the repeat and shuffle modes, whose values
            // are checked by range rather than against an options list.
            if (k === "repeatMode" && typeof v === "number")
                store[k] = Math.max(0, Math.min(2, Math.round(v)))
            else if (k === "shuffleMode" && typeof v === "number")
                store[k] = Math.max(0, Math.min(3, Math.round(v)))
        }
    }

    // Takes MPD's own music_directory as the root, once, when no folder has ever
    // been saved. After this the value is an ordinary explicit setting: the card
    // shows what the player uses, a later edit is not overwritten by the hint on
    // the next start, and a library the user chose is never silently moved.
    // Returns whether the store actually changed, so tests can tell adoption
    // from a no-op. A hint that is not a usable absolute path is ignored.
    function adoptMusicDir(value) {
        if (root.musicDirSaved) return false
        var clean = Paths.musicRoot(value, Quickshell.env("HOME"))
        if (clean === "") return false
        // A hint that agrees with the default still settles the question: the
        // derived value was right, so there is nothing to write and nothing to
        // keep asking MPD about.
        root.musicDirSaved = true
        if (clean === store.musicDir) return false
        store.musicDir = clean
        saveSoon()
        return true
    }

    Component.onCompleted: {
        // Capture the defaults while the store still holds them: this runs before
        // applyStored() touches a single one, and never again.
        for (var d = 0; d < entries.length; d++)
            codeDefaults[entries[d].key] = store[entries[d].key]
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

    readonly property string musicDir: store.musicDir
    readonly property bool wrapAround: store.wrapAround
    readonly property int seekThickness: store.seekThickness
    readonly property int stripTopGap: store.stripTopGap
    readonly property bool albumYears: store.albumYears
    readonly property string playingMarker: store.playingMarker
    readonly property string coverDecodeSize: store.coverDecodeSize
    readonly property bool adaptiveColors: store.adaptiveColors
    readonly property bool fetchCovers: store.fetchCovers
    readonly property string keyboardStyle: store.keyboardStyle
    readonly property int rowSpacing: store.rowSpacing
    readonly property string findPlace: store.findPlace
    readonly property int findScale: store.findScale
    readonly property bool rowSeparators: store.rowSeparators
    readonly property bool focusGlow: store.focusGlow
    readonly property bool paneHeadings: store.paneHeadings
    readonly property bool paneSeparators: store.paneSeparators
    readonly property int borderWidth: store.borderWidth
    readonly property bool stripSeparator: store.stripSeparator
    readonly property bool stripSeekEdge: store.stripSeekEdge
    // With the seeker as the edge the stacked arrangement has no bar to stack,
    // so the strip always uses the inline geometry. The stored choice is left
    // alone; it comes back when the edge is switched off.
    readonly property bool progressInline: store.stripSeekEdge || store.progressInline
    readonly property bool quietTime: store.quietTime
    readonly property bool coverBorder: store.coverBorder
    readonly property bool coverPlaceholder: store.coverPlaceholder
    readonly property int coverBorderWidth: store.coverBorderWidth
    readonly property bool upNextCover: store.upNextCover
    readonly property int upNextCoverSize: store.upNextCoverSize
    readonly property string albumInfo: store.albumInfo
    readonly property int albumFont: store.albumFont
    readonly property int albumTrackSpacing: store.albumTrackSpacing
    readonly property string trackAlign: store.trackAlign
    readonly property bool albumLyrics: store.albumLyrics
    readonly property string trackNumberFormat: store.trackNumberFormat
    readonly property bool trackNumberMuted: store.trackNumberMuted
    readonly property int coverRoundness: store.coverRoundness
    readonly property bool albumCoverRound: store.albumCoverRound
    readonly property bool karaokeCoverRound: store.karaokeCoverRound
    readonly property int repeatMode: store.repeatMode
    readonly property int shuffleMode: store.shuffleMode

    // Written by the repeat-mode logic rather than by the settings card, hence
    // a setter instead of an exposed entry.
    function setRepeatMode(value) {
        store.repeatMode = value
        saveSoon()
    }

    // Same, for the shuffle scope.
    function setShuffleMode(value) {
        store.shuffleMode = value
        saveSoon()
    }
    readonly property int coverScale: store.coverScale
    readonly property int albumCoverScale: store.albumCoverScale
    readonly property int karaokeCoverScale: store.karaokeCoverScale
    readonly property int karaokeBackgroundScale: store.karaokeBackgroundScale
    readonly property int coverTransition: store.coverTransition
    readonly property string coverBandMode: store.coverBandMode
    readonly property string coverBandAlign: store.coverBandAlign
    readonly property bool coverPadding: store.coverPadding
    readonly property int coverBandMinPct: store.coverBandMinPct
    readonly property real uiScale: store.uiScale
    readonly property real settingsOpacity: store.settingsOpacity
    readonly property int iconSize: store.iconSize
    readonly property int fontTitle: store.fontTitle
    readonly property int fontSubtitle: store.fontSubtitle
    readonly property int fontBody: store.fontBody
    readonly property int fontBodySmall: store.fontBodySmall
    readonly property int fontCaption: store.fontCaption
    readonly property string lyricsAlign: store.lyricsAlign
    readonly property int lyricsFont: store.lyricsFont
    readonly property bool lyricsInfoTitle: store.lyricsInfoTitle
    readonly property bool lyricsInfoArtist: store.lyricsInfoArtist
    readonly property bool lyricsInfoAlbum: store.lyricsInfoAlbum
    readonly property string lyricsFollow: store.lyricsFollow
    readonly property string lyricsDim: store.lyricsDim
    readonly property int lyricsResume: store.lyricsResume
    readonly property int lyricsSpacing: store.lyricsSpacing
    readonly property string lyricsWidth: store.lyricsWidth
    readonly property string lyricsCover: store.lyricsCover
    readonly property bool lyricsTracks: store.lyricsTracks
    readonly property int karaokeFont: store.karaokeFont
    readonly property string karaokeAlign: store.karaokeAlign
    readonly property string karaokeFollow: store.karaokeFollow
    readonly property bool karaokeInfoTitle: store.karaokeInfoTitle
    readonly property bool karaokeInfoArtist: store.karaokeInfoArtist
    readonly property bool karaokeInfoAlbum: store.karaokeInfoAlbum
    readonly property string karaokeCover: store.karaokeCover
    readonly property real karaokeCoverOpacity: store.karaokeCoverOpacity
    readonly property int lyricsOffset: store.lyricsOffset
    readonly property bool lyricsClickSeek: store.lyricsClickSeek
    readonly property bool lyricsDownloads: store.lyricsDownloads

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

    // Notice size is measured from the resting look, not from the theme: six is
    // where all three notices sit today, so that value reads "Default" and the
    // steps either side read as bigger or smaller than that.
    function noticeSizeText(value) {
        var delta = value - 6
        if (delta === 0) return "Default"
        return (delta > 0 ? "+" : "") + delta + " px"
    }

    // The rows the settings card offers, in the order each tab shows them.
    // An entry is a name, a place and a set of rungs: the value itself is the
    // store property the key names, reached through valueFor() and assign(). The
    // defaults live with the store at the top of the file; an entry names only
    // the rungs a value may take.
    //
    // A row prints itself without a `format` wherever the obvious reading is the
    // right one -- on/off for a switch, a capitalised word for a named choice, a
    // bare number -- and spells one out only for a unit, a percentage or a
    // phrasing that says more than the option does.
    //
    // Which tab an entry lands in follows from a single `section` tag, and
    // table order is the order each section shows its rows. Sections are cut by
    // topic -- what part of the player the setting is about -- and not by the
    // kind of control it is, so a slider and a switch sit side by side wherever
    // the subject they share says they should. Sorting by shape instead would
    // put a list setting next to a font size and leave every new entry needing
    // to be told which tab it "was".
    //
    // An entry with `dependsOn` is greyed and non-navigable until its predicate
    // is true, rather than being hidden. Keeping the row in place means a hunt
    // for a setting always finds it. A dependent also names the row it waits on
    // in `after`, and the card sits it directly beneath that row, so the row
    // above a greyed setting is why it is greyed. Its value is kept either way,
    // so switching the parent back on restores it exactly as it was, and reset()
    // still restores it too.
    readonly property var entries: [
        // ---- General ----
        // Player-wide choices: where the library lives, what the letter keys do,
        // whether lists stop or wrap at their ends, how the settings card sits over
        // the panel, and what the player brings
        // in from outside -- colours sampled from the playing sleeve and metadata
        // fetched when a file has none on disk. They stay out of the view tabs
        // because they change the instrument rather than one surface on it.
        {
            key: "musicDir",
            section: "general",
            label: "Music folder",
            // A free-text row rather than a list of rungs: the library can live
            // anywhere, so there is nothing finite to offer. The card gives it
            // an editing mode of its own (see the panel's key handler).
            kind: "text",
            hint: "The folder MPD plays from; it must match MPD's music_directory. Absolute, or start with ~ for your home folder",
            normalize: function (v) { return Paths.musicRoot(v, Quickshell.env("HOME")) }
        },
        {
            key: "rescanLibrary",
            section: "general",
            label: "Rescan library",
            kind: "action",
            action: "rescanLibrary",
            buttonText: "Rescan",
            hint: "Ask MPD to scan the music folder for new, changed or removed files",
            orderAfter: "musicDir"
        },
        {
            key: "keyboardStyle",
            section: "general",
            label: "Keyboard style",
            hint: "What the letter keys do: jump to a matching row, move with j/k/h/l/g/G, or leave letters inert. Arrows navigate in every mode",
            options: ["find", "vim", "off"],
            format: function (v) {
                return v === "find" ? "Find" : (v === "vim" ? "Vim" : "Off")
            }
        },
        {
            key: "wrapAround",
            section: "general",
            label: "Wrap lists",
            hint: "Down on the last row goes to the top, up on the first goes to the last; applies to album view's track list too",
            options: [true, false]
        },
        {
            key: "findPlace",
            section: "general",
            label: "Notice position",
            hint: "Where typed letters, transport replies and MPD errors appear: above the now-playing strip or centred in the tracks pane",
            options: ["bottom", "center"],
            // Next to the keyboard style it used to belong to, but not one of
            // its greyed-out children: notices still land somewhere in every
            // style. orderAfter places the row; only `after` indents it.
            orderAfter: "keyboardStyle"
        },
        {
            key: "findScale",
            section: "general",
            label: "Notice size",
            hint: "Text size of typed letters, transport replies and MPD errors, together",
            // One knob for every transient notice. The resting size sits in the
            // middle of the range so it can grow or shrink without changing what
            // the find letters, the transport reply and the error line mean.
            options: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
            orderAfter: "findPlace",
            format: root.noticeSizeText
        },
        {
            key: "uiScale",
            section: "general",
            label: "UI scale",
            hint: "Scales rows, spacing, fonts, icons and cover art together",
            options: [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5],
            format: function (v) { return (v * 100).toFixed(0) + "%" }
        },
        {
            key: "settingsOpacity",
            section: "general",
            label: "Settings opacity",
            hint: "How solid the settings card is; lower values let the player show through",
            options: [0.6, 0.7, 0.8, 0.9, 1.0],
            format: function (v) { return Math.round(v * 100) + "%" }
        },
        {
            key: "adaptiveColors",
            section: "general",
            label: "Adaptive colours",
            hint: "Follow the current album cover instead of the shell theme",
            options: [true, false],
        },
        {
            key: "fetchCovers",
            section: "general",
            label: "Fetch covers",
            hint: "Look a cover up on iTunes or Deezer when an album has none, and cache it",
            options: [true, false],
        },
        {
            key: "lyricsDownloads",
            section: "general",
            label: "Fetch lyrics",
            hint: "Ask lrclib when a track has no lyrics on disk, for both views; off keeps the player local-only",
            options: [true, false],
        },

        // ---- Library ----
        // Everything tied to the three-pane browser: the rules and focus between
        // the lists, and how the playing row is marked. Album years writes the
        // albums pane's label, so it belongs here too. List wrapping is general:
        // the same up/down keys drive album view's tracks, so it lives there.
        {
            key: "playingMarker",
            section: "library",
            label: "Playing marker",
            hint: "Which edges of the playing row carry the accent bar; the tint is always on",
            options: ["none", "left", "right", "both"]
        },
        {
            key: "rowSpacing",
            section: "library",
            label: "Row height",
            hint: "Height of each list row; the gap between rows follows it",
            options: [24, 28, 32, 36, 40],
            format: function (v) { return v + " px" }
        },
        {
            key: "rowSeparators",
            section: "library",
            label: "Row lines",
            hint: "Draw a faint line between rows in each pane",
            options: [true, false],
        },
        {
            key: "fontSubtitle",
            section: "library",
            label: "Rows",
            hint: "Artist and album rows in the browser, as an offset from the theme; album view has its own type size",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            format: root.deltaText
        },
        {
            key: "paneHeadings",
            section: "library",
            label: "Headings",
            hint: "Show the pane name over a rule at the top; off starts the lists at the very top",
            options: [true, false],
        },
        {
            key: "fontBodySmall",
            section: "library",
            label: "Heading size",
            hint: "The pane name over each pane's rule, as an offset from the theme",
            // The heading is drawn as part of the pane's header, so its size only
            // has anything to size while paneHeadings is on. It sits directly
            // under that switch, greyed while the switch is off, so the row above
            // is why it is greyed.
            //
            // The range runs from the theme's own size up to eight steps above it,
            // so the resting +4 sits dead centre: a step either way is available
            // without the knob starting at one end, and the floor is "theme" rather
            // than a size below it, since a heading smaller than the theme's own
            // small text has nothing to be smaller than.
            options: [0, 1, 2, 3, 4, 5, 6, 7, 8],
            dependsOn: function () { return store.paneHeadings },
            after: "paneHeadings",
            format: root.deltaText
        },
        {
            key: "paneSeparators",
            section: "library",
            label: "Pane dividers",
            hint: "Draw the rules between the list panes and the artwork pane",
            options: [true, false],
        },
        {
            key: "borderWidth",
            section: "library",
            label: "Line width",
            hint: "Thickness of the pane dividers, heading underlines and the strip separator",
            // One width for the pane rules, heading underlines and the strip's
            // hairline. The seeker edge uses its own thickness instead, so a
            // separator hidden behind it no longer keeps this knob live.
            options: [1, 2, 3, 4],
            dependsOn: function () {
                return store.paneSeparators || store.paneHeadings
                    || (store.stripSeparator && !store.stripSeekEdge)
            },
            after: "paneSeparators",
            format: function (v) { return v + " px" }
        },
        {
            key: "focusGlow",
            section: "library",
            label: "Dim unfocused",
            hint: "Fade the two unfocused panes so the active one stands out",
            options: [true, false]
        },
        {
            key: "trackNumberFormat",
            section: "library",
            label: "Number format",
            hint: "How the tracks pane writes each number before its title; numbers are padded to two digits",
            options: ["dot", "dash"],
            format: function (v) { return v === "dash" ? "01 - Title" : "01. Title" }
        },
        {
            key: "trackNumberMuted",
            section: "library",
            label: "Quiet numbers",
            hint: "Draw track numbers in the muted ink, like the durations, so the titles lead",
            options: [true, false],
        },

        // Album years labels the albums pane, so it closes the Library block.
        {
            key: "albumYears",
            section: "library",
            label: "Album years",
            hint: "Prefix each album with its release year, read from the Date tag",
            options: [true, false]
        },

        // ---- Now playing ----
        // The bar that stays on screen in every view: how its top edge is drawn,
        // how its progress and clock read, how tall its seeker is, and how big
        // its icons and title read. Notice placement and size live under General.
        {
            key: "stripSeparator",
            section: "nowPlaying",
            label: "Strip separator",
            hint: "Draw a quiet hairline above the now-playing strip in the pane rule colour",
            options: [true, false]
        },
        {
            key: "stripSeekEdge",
            section: "nowPlaying",
            label: "Seeker as edge",
            hint: "Use the seek bar as the strip's full-width top boundary instead of a separate hairline",
            options: [true, false],
            orderAfter: "stripSeparator"
        },
        {
            key: "progressInline",
            section: "nowPlaying",
            label: "Inline progress",
            hint: "Put elapsed, seek and total on one row and trim the strip to fit. Seeker as edge holds this on",
            options: [true, false],
            // The stored value survives, but the card reads On and refuses edits
            // while the seeker is the edge: there is no in-strip bar to stack.
            get: function () { return root.progressInline },
            set: function (v) { if (!store.stripSeekEdge) store.progressInline = v },
            dependsOn: function () { return !store.stripSeekEdge },
            after: "stripSeekEdge"
        },
        {
            key: "quietTime",
            section: "nowPlaying",
            label: "Time size",
            hint: "Draw the elapsed and total time in the small body size instead of the regular one",
            options: [true, false],
            format: function (v) { return v ? "Small" : "Regular" }
        },
        {
            key: "seekThickness",
            section: "nowPlaying",
            label: "Seeker height",
            hint: "How thick the bar above the transport is drawn",
            // Rungs up to 15: the bar is a thin strip by default, and 9 is the
            // bottom of the useful range rather than its top. The bar's slot and
            // the strip both grow with it (see SeekBar and LayoutMath.stripHeight),
            // so a thicker bar takes more room rather than crowding the title.
            options: [3, 5, 7, 9, 11, 13, 15],
            format: function (v) { return v + " px" }
        },
        {
            key: "stripTopGap",
            section: "nowPlaying",
            label: "Strip top gap",
            hint: "Air above the now-playing title. The strip grows by the same amount, so the title and transport stay put",
            // Zero restores the old flush title; 2 is the tight default. The
            // wider rungs above it are for a panel read from further away.
            options: [0, 2, 4, 6, 8, 10, 12, 16, 20, 24],
            format: function (v) { return v + " px" }
        },
        {
            key: "iconSize",
            section: "nowPlaying",
            label: "Icon size",
            hint: "Transport and UI icons",
            options: [12, 14, 16, 18, 20],
            format: function (v) { return v + " px" }
        },
        {
            key: "fontTitle",
            section: "nowPlaying",
            label: "Now playing",
            hint: "Now playing title, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            format: root.deltaText
        },
        {
            key: "fontBody",
            section: "nowPlaying",
            label: "Artist & time",
            hint: "Artist, elapsed/total time, and the compact companion titles, as an offset from the theme",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            format: root.deltaText
        },
        // ---- Cover art ----
        //
        // Every entry in this section carries section: "artwork". That is what
        // the card gathers into its own Artwork tab: how the cover looks and sits.
        // Where it comes from, and whether it colours the panel, are player-wide
        // choices and live under General.
        {
            key: "coverBorder",
            section: "artwork",
            label: "Cover border",
            hint: "Ring around the cover art, separate from the pane rules",
            options: [true, false],
        },
        {
            key: "coverBorderWidth",
            section: "artwork",
            label: "Cover border width",
            hint: "Thickness of the ring around the cover art",
            options: [1, 2, 3, 4, 6, 8],
            dependsOn: function () { return store.coverBorder },
            after: "coverBorder",
            format: function (v) { return v + " px" }
        },
        {
            key: "coverRoundness",
            section: "artwork",
            label: "Artwork rounding",
            hint: "Corner radius of the cover art; zero draws square corners, and the border ring follows the same radius",
            options: [0, 2, 4, 6, 8, 10, 12, 16, 20, 24],
            format: function (v) { return v === 0 ? "square" : v + " px" }
        },
        {
            key: "coverTransition",
            section: "artwork",
            label: "Cover fade",
            hint: "Fade the new album cover in over the old one; instant is a plain swap",
            options: [0, 100, 200, 300, 400, 500, 600],
            format: function (v) { return v === 0 ? "instant" : v + " ms" }
        },
        {
            key: "coverPlaceholder",
            section: "artwork",
            label: "Placeholder art",
            hint: "Show a CD when the album has no artwork, or leave the space empty",
            options: [true, false],
        },
        {
            key: "coverDecodeSize",
            section: "artwork",
            label: "Cover decode size",
            hint: "Maximum resolution to decode embedded art at",
            options: ["full", "large", "medium"],
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
            }
        },
        {
            key: "coverBandAlign",
            section: "artwork",
            label: "Cover position",
            hint: "Where the cover sits vertically in the artwork pane",
            options: ["top", "middle", "bottom"],
            dependsOn: function () { return store.coverBandMode !== "off" },
            after: "coverBandMode"
        },
        {
            key: "coverPadding",
            section: "artwork",
            label: "Cover padding",
            hint: "Margin between the cover and the library pane edges; off runs it flush",
            options: [true, false],
            dependsOn: function () { return store.coverBandMode !== "off" },
            after: "coverBandMode"
        },
        {
            key: "coverScale",
            section: "artwork",
            label: "Cover size",
            hint: "Height of the artwork as a share of the space above the now-playing bar; 100% fills it top to bottom",
            // Even ten-step rungs, low to high, so a nudge moves the cover the
            // same amount wherever the knob is.
            options: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
            // The floating placement's resting size; the pane's 100% is applied by
            // the artwork-pane toggle above. This is what reset() lands on. It is
            // only editable while the pane is pinned off, where the floating cover
            // is the arrangement and its size is genuinely the user's to set: under
            // "auto" the window picks the placement and the size that goes with it,
            // and pinned "on" the pane's own full height is what the toggle above
            // just wrote into this value, so offering the slider there would be
            // offering to undo the choice that was just made.
            dependsOn: function () { return store.coverBandMode === "off" },
            after: "coverBandMode",
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
            dependsOn: function () { return store.coverBandMode === "auto" },
            after: "coverBandMode",
            format: function (v) { return v + "%" }
        },

        // ---- Album view ----
        //
        // The now-playing surface's own choices: what its details say, how large
        // that line reads, where its titles and the lyrics sharing them sit,
        // whether those lyrics share it, and the preview of the album that follows.
        // They are not browser panes or a second lyric view, so they get a tab of
        // their own rather than sitting among the list and cover settings.
        {
            key: "albumInfo",
            section: "album",
            label: "Album details",
            hint: "Above the titles in album view: nothing, the album, the artist, both, or both with the year and running time",
            options: ["off", "title", "artist", "both", "full"],
            format: function (v) {
                return v === "both" ? "Title & artist"
                    : v === "full" ? "Full details" : root.titleText(v)
            }
        },
        {
            key: "fontCaption",
            section: "album",
            label: "Info text",
            hint: "Album details above the titles, the Up next label and the MPD status line, as an offset from the theme. Larger values also make the album details heavier, from muted label to small heading",
            // One control now owns both the size and the emphasis of the album
            // line. The positive ramp is deliberately longer than the other font
            // offsets: this is the line people want to push furthest when the
            // panel is read from across the room. Five steps up to the old top,
            // then wider rungs so +16 is reachable without a long walk.
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 14, 16],
            format: root.deltaText
        },
        {
            key: "trackAlign",
            section: "album",
            label: "Track alignment",
            hint: "In album view, align the titles left or centre them; the words have their own alignment under Lyrics",
            options: ["left", "center"],
        },
        {
            key: "albumFont",
            section: "album",
            label: "Track title size",
            hint: "Album view's track titles, as an offset from the theme; Alt+= / Alt+- changes this while album view is showing",
            options: [-4, -3, -2, -1, 0, 1, 2, 3, 4],
            format: root.deltaText
        },
        {
            key: "albumTrackSpacing",
            section: "album",
            label: "Track spacing",
            hint: "Extra space between album-view titles, in logical pixels; zero keeps the gap sized from the title font",
            options: [0, 2, 4, 6, 8, 10, 12],
            format: function (v) { return v + " px" }
        },
        {
            key: "albumLyrics",
            section: "album",
            label: "Lyrics beside tracks",
            hint: "Share album view with the playing track's lyrics; the cover keeps its own pane. The words' size, alignment, track info and highlight come from Lyrics view, their spacing and sharing from Lyrics",
            options: [true, false],
        },
        {
            key: "upNextCover",
            section: "album",
            label: "Up next cover",
            hint: "Preview the next album's art in the corner above the now-playing bar",
            options: [true, false],
        },
        {
            key: "upNextCoverSize",
            section: "album",
            label: "Up next cover size",
            hint: "Size of that preview beside the now-playing bar; 100% is the smallest tile, 150% the default and 200% the largest",
            options: [100, 125, 150, 175, 200],
            dependsOn: function () { return store.upNextCover },
            after: "upNextCover",
            format: function (v) { return v + "%" }
        },
        {
            key: "albumCoverScale",
            section: "album",
            label: "Cover size",
            hint: "Size of the artwork in album view, as a share of its natural fit; 100% is that fit, 50% the smallest, and larger values grow into the room the titles can spare",
            options: [50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150],
            format: function (v) { return v + "%" }
        },
        {
            key: "albumCoverRound",
            section: "album",
            label: "Rounder cover",
            hint: "Give album view's cover a fuller 20px corner radius instead of the global Artwork rounding",
            options: [true, false],
        },

        // ---- Lyrics ----
        //
        // Only the choices the words share wherever they appear: the reading
        // view, album view's companion column and karaoke. How each surface marks
        // its line, sizes it and sees the track above it is a view choice now and
        // lives under Lyrics view or Karaoke view.
        {
            key: "lyricsSpacing",
            section: "lyrics",
            label: "Line spacing",
            hint: "Gap between lyric lines in both views: tight, normal or airy",
            options: [4, 8, 12],
            format: function (v) { return v === 4 ? "Tight" : v === 8 ? "Normal" : "Airy" }
        },
        {
            key: "lyricsDim",
            section: "lyrics",
            label: "Dim other lines",
            hint: "How far the lines around a marked one fade back in both views",
            options: ["subtle", "medium", "strong"],
        },
        {
            key: "lyricsResume",
            section: "lyrics",
            label: "Resume after scroll",
            hint: "How long either view waits after a manual scroll before returning to the playing line",
            options: [5000, 15000, 0],
            format: function (v) { return v === 0 ? "Never" : (v / 1000) + " s" }
        },
        {
            key: "lyricsOffset",
            section: "lyrics",
            label: "Sync offset",
            hint: "Shift synced lyrics that run early or late in both views; positive delays the highlight",
            options: [-2000, -1500, -1000, -500, 0, 500, 1000, 1500, 2000],
            format: function (v) {
                return v === 0 ? "0 s" : (v > 0 ? "+" : "") + (v / 1000).toFixed(1) + " s"
            }
        },
        {
            key: "lyricsClickSeek",
            section: "lyrics",
            label: "Click to seek",
            hint: "Click a timed line in either view to jump to that point in the track",
            options: [true, false],
        },

        // ---- Lyrics view ----
        //
        // The reading view's own surface. The lines written above the words come
        // first, each with its own switch, so they read as one group rather than
        // as details of the text settings below. Then come the words themselves --
        // how they are marked, aligned and sized, how wide the column is -- and
        // finally what shares the space. These follow the words into album view
        // when lyrics sit beside the titles, but karaoke keeps its own highlight,
        // alignment, size, header and cover under Karaoke view.
        {
            key: "lyricsInfoTitle",
            section: "lyricsView",
            label: "Title above lyrics",
            hint: "Write the playing track's title on the line above the words",
            options: [true, false],
        },
        {
            key: "lyricsInfoArtist",
            section: "lyricsView",
            label: "Artist above lyrics",
            hint: "Write the playing track's artist on the line above the words",
            options: [true, false],
        },
        {
            key: "lyricsInfoAlbum",
            section: "lyricsView",
            label: "Album above lyrics",
            hint: "Write the playing track's album on the line above the words",
            options: [true, false],
        },
        {
            key: "lyricsFollow",
            section: "lyricsView",
            label: "Highlight",
            hint: "Mark the current lyric line in the lyrics view and album view's companion words; highlight and follow also scrolls to it, highlight only leaves the text where it is, and off marks nothing",
            options: ["follow", "highlight", "off"],
            format: function (v) {
                return v === "follow" ? "Highlight + follow"
                    : v === "highlight" ? "Highlight only" : "Off"
            }
        },
        {
            key: "lyricsAlign",
            section: "lyricsView",
            label: "Alignment",
            hint: "Align the words left or centre them, both in the lyrics view and when they share album view; karaoke has its own alignment",
            options: ["left", "center"],
        },
        {
            key: "lyricsFont",
            section: "lyricsView",
            label: "Text size",
            hint: "Lyrics view size as an offset from the theme; karaoke has its own",
            options: [0, 1, 2, 3, 4, 5, 6, 7, 8],
            format: root.deltaText
        },
        {
            key: "lyricsWidth",
            section: "lyricsView",
            label: "Text width",
            hint: "How wide the lyrics view's reading column may get; a narrower column keeps long lines readable",
            options: ["full", "wide", "narrow"],
        },
        {
            key: "lyricsCover",
            section: "lyricsView",
            label: "Cover beside lyrics",
            hint: "In the lyrics view, keep the artwork beside the lyrics or give the text the full width",
            options: ["show", "hide"],
        },
        {
            key: "lyricsTracks",
            section: "lyricsView",
            label: "Tracks beside lyrics",
            hint: "Show the playing album's titles beside the words; a narrow panel gives the lyrics the width instead",
            options: [true, false],
        },

        // ---- Karaoke view ----
        //
        // ---- Karaoke view ----
        //
        // Its own surface: larger text read from a distance, its own highlight
        // and alignment, and a cover that can share the view, sit behind it or
        // stay away. The lines written above the words come first, each with its
        // own switch, so they read as one group rather than as details of the
        // text settings below. These are separate choices from the reading
        // view's, so they have a tab of their own.
        {
            key: "karaokeInfoTitle",
            section: "karaoke",
            label: "Title above lyrics",
            hint: "Write the playing track's title on the line above the karaoke words",
            options: [true, false],
        },
        {
            key: "karaokeInfoArtist",
            section: "karaoke",
            label: "Artist above lyrics",
            hint: "Write the playing track's artist on the line above the karaoke words",
            options: [true, false],
        },
        {
            key: "karaokeInfoAlbum",
            section: "karaoke",
            label: "Album above lyrics",
            hint: "Write the playing track's album on the line above the karaoke words",
            options: [true, false],
        },
        {
            key: "karaokeFollow",
            section: "karaoke",
            label: "Highlight",
            hint: "Mark the current karaoke line; highlight and follow also scrolls to it, highlight only leaves the text where it is, and off marks nothing",
            options: ["follow", "highlight", "off"],
            format: function (v) {
                return v === "follow" ? "Highlight + follow"
                    : v === "highlight" ? "Highlight only" : "Off"
            }
        },
        {
            key: "karaokeFont",
            section: "karaoke",
            label: "Text size",
            hint: "Karaoke size as an offset from the theme; independent of the lyrics view",
            options: [0, 1, 2, 3, 4, 5, 6, 7, 8],
            format: root.deltaText
        },
        {
            key: "karaokeAlign",
            section: "karaoke",
            label: "Alignment",
            hint: "Align karaoke's words left or centre them; the reading view's words keep their own alignment",
            options: ["left", "center"],
        },
        {
            key: "karaokeCover",
            section: "karaoke",
            label: "Cover",
            hint: "Put the album cover beside the lyrics, behind them at low opacity, or away entirely",
            options: ["side", "background", "hide"],
            format: function (v) {
                return v === "side" ? "Beside" : v === "background" ? "Background" : "Hidden"
            }
        },
        {
            key: "karaokeCoverScale",
            section: "karaoke",
            label: "Cover size",
            hint: "Size of karaoke's framed cover beside the words, as a share of its natural fit; 100% is that fit, 50% the smallest, and 110% the largest the words can spare",
            options: [50, 60, 70, 80, 90, 100, 110],
            dependsOn: function () { return store.karaokeCover === "side" },
            after: "karaokeCover",
            format: function (v) { return v + "%" }
        },
        {
            key: "karaokeCoverRound",
            section: "karaoke",
            label: "Rounder cover",
            hint: "Give karaoke's side cover a fuller 20px corner radius instead of the global Artwork rounding; a background cover stays square",
            options: [true, false],
            dependsOn: function () { return store.karaokeCover === "side" },
            after: "karaokeCover"
        },
        {
            key: "karaokeBackgroundScale",
            section: "karaoke",
            label: "Background cover size",
            hint: "How much of the karaoke view the background cover fills; 100% covers it, smaller sizes stay centred",
            options: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100],
            dependsOn: function () { return store.karaokeCover === "background" },
            after: "karaokeCover",
            format: function (v) { return v + "%" }
        },
        {
            key: "karaokeCoverOpacity",
            section: "karaoke",
            label: "Cover opacity",
            hint: "How strongly the background cover shows through behind the lyrics",
            options: [0.1, 0.2, 0.3, 0.4],
            dependsOn: function () { return store.karaokeCover === "background" },
            after: "karaokeCover",
            format: function (v) { return Math.round(v * 100) + "%" }
        },
    ]

    // The stored value behind a row. Entries name a key rather than carrying a
    // pair of closures: store is a plain typed QtObject and both saveNow() and
    // applyStored() already reach it dynamically, so a per-entry getter would be
    // a second way to say the same thing. An entry may still override either
    // side, which is how coverBandMode also moves the artwork size when it is
    // pinned.
    function valueFor(entry) {
        return entry.get ? entry.get() : store[entry.key]
    }

    function assign(entry, value) {
        if (entry.set) entry.set(value)
        else store[entry.key] = value
        // Any value the settings machinery writes is a choice, so the music
        // folder stops following MPD's hint. resetEntry() and reset() undo this
        // deliberately when they restore the derived default.
        if (entry.key === "musicDir") root.musicDirSaved = true
    }

    // How a row prints its value. An entry only spells `format` out when the
    // answer is not the obvious one: switches read on/off, a named choice reads
    // as a capitalised word, and a number prints bare unless it has a unit.
    function textOf(entry) {
        var value = valueFor(entry)
        if (entry.format) return entry.format(value)
        var first = entry.options && entry.options[0]
        if (typeof first === "boolean") return root.boolText(value)
        if (typeof first === "string") return root.titleText(value)
        return String(value)
    }

    // A slider is anything numeric; everything else is a switch or a named
    // choice. The card and the panel's key handler both ask this rather than
    // repeating the shape test, so "numeric" has one definition.
    function isSlider(entry) {
        var o = entry ? entry.options : null
        return !!(o && o.length > 0 && typeof o[0] === "number")
    }

    // A free-text row, of which the music folder is currently the only one. It
    // has no rungs, so it is neither a switch nor a slider; the card and the
    // key handler ask this instead of testing for an empty options list.
    function isText(entry) {
        return !!(entry && entry.kind === "text")
    }

    // An action row runs something once when activated instead of holding a
    // value. The card renders it as a button; the config only declares it and
    // reports when the user fired it.
    function isAction(entry) {
        return !!(entry && entry.kind === "action")
    }

    signal actionTriggered(string action, var entry)

    function triggerAction(entry) {
        if (!isAction(entry)) return
        root.actionTriggered(String(entry.action || entry.key || ""), entry)
    }

    // ---- free-text editing ----
    //
    // A text row edits a draft and writes it only once the edit is accepted.
    // Writing on every keystroke would feed the service half-typed paths
    // ("/home/g") and do file work against them. The draft lives here so the
    // card, the panel's keys and saveSoon() all read one place.
    property string textEditKey: ""
    property string textEditDraft: ""
    // Index in the draft where the next keystroke lands. The native editor
    // mirrors its caret here, so the panel's fallback keymap edits at the same
    // place instead of guessing which character Backspace will take.
    property int textEditCaret: 0

    function beginTextEdit(entry) {
        if (!isText(entry)) return
        textEditKey = entry.key
        // Start at the end: most edits append or trim a tail. The arrow keys
        // walk back into the path when the change is somewhere in the middle.
        textEditDraft = String(valueFor(entry))
        textEditCaret = textEditDraft.length
    }

    // What the row draws: the draft while it is being edited, the stored value
    // otherwise. Action rows show their button label instead of a stored value.
    function displayText(entry) {
        if (isAction(entry)) return String(entry.buttonText || "Run")
        if (isText(entry) && textEditKey === entry.key) return textEditDraft
        return textOf(entry)
    }

    function textKeyStroke(text) {
        if (textEditKey === "") return
        var s = String(text)
        if (s === "") return
        textEditDraft = textEditDraft.substring(0, textEditCaret) + s
            + textEditDraft.substring(textEditCaret)
        textEditCaret += s.length
    }

    function textBackspace() {
        if (textEditKey === "" || textEditCaret === 0) return
        textEditDraft = textEditDraft.substring(0, textEditCaret - 1)
            + textEditDraft.substring(textEditCaret)
        textEditCaret--
    }

    function textDelete() {
        if (textEditKey === "" || textEditCaret >= textEditDraft.length) return
        textEditDraft = textEditDraft.substring(0, textEditCaret)
            + textEditDraft.substring(textEditCaret + 1)
    }

    function textMoveCaret(delta) {
        if (textEditKey === "") return
        textEditCaret = Math.max(0,
            Math.min(textEditDraft.length, textEditCaret + delta))
    }

    function textCaretToEdge(edge) {
        if (textEditKey === "") return
        textEditCaret = edge < 0 ? 0 : textEditDraft.length
    }

    function textClear() {
        if (textEditKey === "") return
        textEditDraft = ""
        textEditCaret = 0
    }

    // Accepts or discards the draft. `commit` is false for Esc, which leaves the
    // stored value untouched. Even a committed value has to pass the row's
    // normaliser: a relative path is dropped rather than saved, so a typo cannot
    // point the tag editor at a folder that is not the library.
    function endTextEdit(commit) {
        if (textEditKey === "") return
        var entry = entryFor(textEditKey)
        if (commit && entry) {
            var clean = entry.normalize ? entry.normalize(textEditDraft) : textEditDraft
            if (clean !== "" && clean !== undefined) {
                assign(entry, clean)
                saveSoon()
            }
        }
        textEditKey = ""
        textEditDraft = ""
        textEditCaret = 0
    }

    // Whether a dependent setting's parent is satisfied. Every entry is in the
    // card either way; this is what the row is greyed and made non-navigable on
    // while it is false.
    function isActive(entry) {
        return !entry || !entry.dependsOn || entry.dependsOn()
    }

    // Every entry the card draws, in table order. A dependent whose parent is off
    // stays in the list, greyed under the row it waits on, so a hunt for a setting
    // always finds it and the indent is the explanation. It is not navigable and
    // not editable in that state (see isActive, which the panel's movement and
    // the card's clicks both check), but its stored value is untouched and
    // reset() still restores it.
    readonly property var visibleEntries: entries

    // The sections the card draws, in tab order, each a name and the tag its
    // entries carry. A section is one topic -- the player-wide choices, the
    // now-playing strip, the cover art, the lyric choices both surfaces share,
    // the three-pane library browser, the album view, karaoke's own surface and
    // the reading view's own -- rather than one kind of control, so a slider and a
    // switch sit together wherever their subject says they should.
    readonly property var sections: [
        { tag: "general", name: "General" },
        { tag: "nowPlaying", name: "Now playing" },
        { tag: "artwork", name: "Artwork" },
        { tag: "lyrics", name: "Lyrics" },
        { tag: "library", name: "Library view" },
        { tag: "album", name: "Album view" },
        { tag: "karaoke", name: "Karaoke view" },
        { tag: "lyricsView", name: "Lyrics view" }
    ]

    // Each row carries its entry, that entry's index into the table, and whether
    // the entry is currently active. The index is the caret's currency: an object
    // identity does not survive the trip through a Repeater's model -- the
    // delegate's modelData hands back a copy, so comparing references never
    // matched and nothing ever read as selected -- while a plain integer does.
    //
    // The index is looked up in visibleEntries rather than taken from the row's
    // position in `list`: arranged() moves a dependent under its parent, so a
    // tab's order is not the table's order, and the caret indexes the table.
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

    // The table order, arranged so every entry that names a parent sits directly
    // under it. `after` marks a dependent child; `orderAfter` only pulls a row
    // beside its parent without the indent, for settings that belong there but
    // are not switched off with it. An entry naming neither keeps its table
    // position. The arrangement is done here rather than left to the table's
    // written order so that this is a property of the list the card draws, not
    // a thing a later edit to the table can quietly break -- and so a parent's
    // children keep their own order among themselves.
    //
    // Each parent is walked once, emitting the parent and then everything that
    // names it, in table order. Entries are only emitted once, so a table written
    // in any order comes out the same way. Children are indexed by parent key
    // to avoid re-scanning the whole list per parent.
    function arranged() {
        var out = []
        var used = {}
        var childrenByKey = {}
        for (var i = 0; i < visibleEntries.length; i++) {
            var d = visibleEntries[i]
            var parent = d.after || d.orderAfter
            if (!parent) continue
            if (!childrenByKey[parent]) childrenByKey[parent] = []
            childrenByKey[parent].push(d)
        }
        for (var k = 0; k < visibleEntries.length; k++) {
            var e = visibleEntries[k]
            if (used[e.key]) continue
            out.push(e)
            used[e.key] = true
            var list = childrenByKey[e.key]
            if (!list) continue
            for (var c = 0; c < list.length; c++) {
                if (used[list[c].key]) continue
                out.push(list[c])
                used[list[c].key] = true
            }
        }
        return out
    }

    // The entries behind each section, worked out once and read by the card, the
    // navigation and the caret's tab lookup alike. Filtering the table once per
    // section on every read would be a pass over every entry each time the caret
    // moves a row, for a table that is fixed while the shell runs.
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

    readonly property var tabs: sections.map(function (s) {
        return { name: s.name, items: indexed(sectionLists[s.tag] || []) }
    })

    // The entries behind a tab, for the panel's navigation.
    function tabEntries(tab) {
        var s = sections[tab]
        return s ? (sectionLists[s.tag] || []) : []
    }

    // Which tab an entry sits in, from its section tag. An entry with no tag
    // -- one added without reading the note above -- falls to the first section
    // rather than vanishing, so the card still shows it.
    function tabOf(index) {
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
        var list = tabEntries(tabOf(index))
        return Math.max(0, list.indexOf(e))
    }

    // The next live row from `row` in a tab, in either direction, wrapping at the
    // ends. Up/down uses this: a greyed dependent stays on the card so its parent
    // is discoverable, but it never holds the caret, because Enter there could
    // only refuse the change. -1 when the whole tab is inactive.
    function activeIndexNear(tab, row, step) {
        var list = tabEntries(tab)
        var n = list.length
        if (n === 0) return -1
        var idx = Math.max(0, Math.min(row, n - 1))
        var dir = step < 0 ? -1 : 1
        for (var s = 0; s < n; s++) {
            idx = (idx + dir + n) % n
            if (isActive(list[idx])) return visibleEntries.indexOf(list[idx])
        }
        return -1
    }

    // The visibleEntries index of the nearest navigable row at or after `row` in
    // a tab. Greyed rows stay on the card so the dependency is visible, but the
    // caret must never stop on one: search forward first, so a remembered row
    // that has since gone inactive moves on to the next live one, then wrap back
    // for the rows above it. -1 when the whole tab is inactive.
    function activeIndexAt(tab, row) {
        var list = tabEntries(tab)
        var n = list.length
        if (n === 0) return -1
        var start = Math.max(0, Math.min(row, n - 1))
        for (var d = 0; d < n; d++) {
            var e = list[(start + d) % n]
            if (isActive(e)) return visibleEntries.indexOf(e)
        }
        return -1
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
        if (!entry || !isActive(entry)) return
        var options = entry.options || []
        // A free-text row has nothing to cycle; the card opens its editor.
        if (options.length === 0) return
        var i = options.indexOf(valueFor(entry))
        if (i === -1) {
            assign(entry, options[0])
            saveSoon()
            return
        }
        assign(entry, options[(i + delta + options.length) % options.length])
        saveSoon()
    }

    // The value an entry rests at. Kept in one place so reset-all and the
    // per-row reset cannot disagree about what "default" means.
    function defaultOf(entry) {
        return entry ? root.codeDefaults[entry.key] : undefined
    }

    // Restore one row without touching the rest. Called from the card's
    // Backspace, and shared with reset() below so the two paths restore the
    // same value.
    function resetEntry(entry) {
        if (!entry) return
        var value = defaultOf(entry)
        if (value === undefined) return
        assign(entry, value)
        // Back at the derived default means back to "not chosen", so a hint that
        // arrives later (or is already here) can still replace the guess.
        if (entry.key === "musicDir") root.musicDirSaved = false
        saveSoon()
    }

    // Restores each entry's own default rather than options[0]. They are not the
    // same: a setting's natural resting point is often away from the low end of
    // its range -- the font offsets rest at the step the theme already draws at,
    // not at their floor.
    function reset() {
        for (var i = 0; i < entries.length; i++) {
            assign(entries[i], defaultOf(entries[i]))
        }
        // Every row is back at its derived default, the folder included, so the
        // "chosen" record this session held no longer applies.
        root.musicDirSaved = false
        saveSoon()
    }
}
