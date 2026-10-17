pragma ComponentBehavior: Bound
// Tag editor, modal over the browser.
//
// Editing is per-selection: the panel hands over the songs the caret covers, and
// every field shows what those songs agree on. A field the selection disagrees
// about reads "multiple" and is left alone unless it is touched -- editing the
// title of a whole album sets the same title on every track, and leaving it
// alone keeps each track's own.
//
// The distinction between "agreed and empty" and "disagreed" is the whole reason
// this is not just a form. An album where every track has no genre should be
// offered an empty genre field to fill in, not one reading "multiple"; an album
// where every track has a different title should not be offered track one's
// title as if it were the album's.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import "Covers.js" as Covers

Item {
    id: root

    property var mpd: null
    // The panel owns the selection; this only reads it.
    property var songs: []
    property real uiScale: 1.0

    // Mirrors the panel's cover-change transition, so the preview here fades the
    // same way the player does when a cover is picked or the selection changes.
    property int coverTransition: 0

    // Mirrors the panel's missing-cover lookup, so a selection with no art shows
    // the same fetched cover the player would, and honours the same off switch.
    property bool fetchCovers: true

    // Mirrors the panel's artwork rounding, so the preview's corners match how
    // the cover is drawn in the player.
    property bool coverRounded: true

    // The panel's colour tokens, injected. The editor is modal over the panel,
    // so it follows the same palette as everything behind it.
    property var theme: null
    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted
    readonly property color colAccent: theme ? theme.accent : Color.accent

    signal dismissed()

    // ---- the fields ----
    //
    // The key is both the name on a song object and the tag this maps to; the
    // panel and the service agree on those names. Order is the reading order:
    // what a track is, then what it is on, then where it sits.
    readonly property var fields: [
        { key: "title", label: "Title" },
        { key: "artist", label: "Artist" },
        { key: "albumArtist", label: "Album artist" },
        { key: "album", label: "Album" },
        { key: "track", label: "Track" },
        { key: "disc", label: "Disc" },
        { key: "date", label: "Year" },
        { key: "genre", label: "Genre" },
        { key: "country", label: "Country" }
    ]

    // What the selection agrees on per field, or "" when they agree on nothing.
    // null means disagreement, which is a different answer from an empty value
    // and the reason this is a null check rather than a truthiness one.
    property var agreed: ({})

    // Fields the user has actually edited. A field left alone is not written, so
    // opening the editor on an album and changing one tag cannot quietly blank
    // the other seven.
    property var touched: ({})

    property int rowIndex: 0
    property string status: ""
    property bool busy: false

    // Identifies the current editing session. load() bumps it, and every async
    // result -- a lookup or a save -- is stamped with the value it was started
    // under and dropped when that no longer matches. Escape can close the editor
    // while a write or lookup is still running, and the panel can reopen it on a
    // different album before that result lands; without this the late callback
    // would paint the previous album's values and status onto the new session.
    property int session: 0

    // ---- cover art ----
    //
    // The cover is edited alongside the tags but not through them: it is stored in
    // the files themselves, embedded into each track (see GrimPlayerMpd.applyCover),
    // and no sidecar is written, so the album folder is left alone.

    // The selection's first song and its file, handed to the preview so it draws
    // the art for this album rather than whatever is playing.
    property var previewSubject: null

    // What this open wants done to the cover: "" leaves it alone, "set" embeds
    // coverPath into the tracks, "remove" strips the embedded picture. Reset by
    // load(), like the tag fields -- an edit not made this time is not carried
    // into the next open.
    property string coverAction: ""
    property string coverPath: ""

    // A chosen-but-unwritten image is what the preview should show, rather than
    // what is on disk.
    readonly property bool coverChosen: root.coverAction === "set" && root.coverPath !== ""

    // Whether there is a cover to remove: the pending choice wins over what is on
    // disk, so the buttons act on what the preview shows.
    readonly property bool coverShown: root.coverAction === "set" ? true
        : (root.coverAction === "remove" ? false : previewArt.foundArt)

    readonly property bool coverFocused: root.rowIndex === root.coverStop()

    // ---- lookup ----
    //
    // A MusicBrainz match held for review, not written: the candidates are what
    // the search returned and the index is which is on show. Per-track fields
    // (title, number, disc) live in lookupPerFile keyed by file, because the
    // editor's shared one-value-per-field model cannot hold a different title
    // for every track -- an album's shared fields hold only what is common.
    property var lookupCandidates: []
    property int lookupIndex: 0
    property var lookupPerFile: ({})
    property bool lookupBusy: false
    // Whether the pending cover came from a lookup rather than the user, so a
    // cycle to a candidate with no art can take it back instead of leaving the
    // previous candidate's cover looking like the new one's.
    property bool coverFromLookup: false

    // The state a lookup is about to overwrite, kept so the fields can show what
    // they held and so Revert can hand it back. Only the first lookup of an
    // editing session snapshots: cycling candidates compares every one of them
    // against the same "before" rather than against the previous candidate, and
    // Revert always returns what the selection had before any match was applied.
    property bool hasPreLookup: false
    property var preLookupDraft: ({})
    property var preLookupTouched: ({})
    property string preLookupCoverAction: ""
    property string preLookupCoverPath: ""
    property bool preLookupCoverFromLookup: false

    // Whether anything is staged for Save. A saved session with nothing staged
    // reads as done, so the button turns into a Close instead of offering a Save
    // that would only ever answer "Nothing changed".
    property bool wroteThisSession: false
    readonly property bool hasPendingEdits: Object.keys(root.touched).length > 0
        || root.coverAction !== ""
        || Object.keys(root.lookupPerFile).length > 0
    readonly property bool saveIsClose: root.wroteThisSession && !root.hasPendingEdits

    // How many fields are currently carrying a "was" line. A field grows by one
    // line when it has one (see the delegate), so the card has to grow with it:
    // the card's height is fixed, and a lookup that moves five fields would
    // otherwise squeeze every field to make room for the extra lines.
    readonly property int changedFieldCount: {
        var n = 0
        for (var i = 0; i < root.fields.length; i++) {
            if (root.fieldChanged(root.fields[i].key)) n++
        }
        return n
    }

    readonly property bool matchFocused: root.rowIndex === root.matchStop()

    readonly property string matchSummary: {
        if (root.lookupCandidates.length === 0) return ""
        var c = root.lookupCandidates[root.lookupIndex]
        if (!c) return ""
        var s = c.artist || ""
        if (c.album) s += (s !== "" ? " – " : "") + c.album
        if (c.date) s += " (" + c.date + ")"
        return (root.lookupIndex + 1) + "/" + root.lookupCandidates.length + "  " + s
    }

    function albumFolder() {
        if (root.songs.length === 0 || !root.mpd) return ""
        return root.mpd.musicDir + "/" + root.mpd.albumDirOf(root.songs[0].file)
    }

    // Every map here is rebuilt and reassigned rather than modified in place. A var
    // property holding a JS object does not report a change when a key is added to
    // it, so an in-place edit updates what a direct read returns while leaving
    // every binding that depends on it showing the values from before the edit.
    function load() {
        root.session++
        var agreed = {}
        for (var f = 0; f < root.fields.length; f++) {
            agreed[root.fields[f].key] = root.commonValue(root.fields[f].key)
        }
        root.agreed = agreed
        root.touched = {}
        root.draft = {}
        root.rowIndex = 0
        root.status = ""
        root.busy = false
        root.coverAction = ""
        root.coverPath = ""
        root.lookupCandidates = []
        root.lookupIndex = 0
        root.lookupPerFile = {}
        root.lookupBusy = false
        root.coverFromLookup = false
        root.hasPreLookup = false
        root.preLookupDraft = {}
        root.preLookupTouched = {}
        root.wroteThisSession = false
        root.previewSubject = root.songs.length > 0
            ? { file: String(root.songs[0].file), song: root.songs[0] } : null
        root.syncFields()
        Qt.callLater(function () { root.syncFields(); root.focusRow() })
    }

    // Pushes each field's resolved text back into its TextField. Needed because
    // the TextField does not keep a binding on `text` (see setFieldText), so a
    // reopened editor would otherwise still hold the last session's typing. Run
    // again from load()'s deferred callback in case the delegates did not exist
    // yet the first time.
    function syncFields() {
        var rows = fieldColumn.children
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].fieldKey !== undefined) rows[i].setFieldText()
        }
    }

    // Where a song's current value for a field comes from. Every tag but country is
    // something MPD reports and so is already on the song object. Country is not
    // in MPD's song model at all, so it is asked of the service, which keeps what
    // it found the last time it looked.
    function valueOf(song, key) {
        if (key === "country") {
            return root.mpd ? root.mpd.countryForDir(root.mpd.albumDirOf(song.file)) : ""
        }
        var raw = song[key]
        return raw === undefined || raw === null ? "" : String(raw).trim()
    }

    // Whitespace inside a subdivision code, as in "GB - SCT", is dropped before
    // it is stored so the flag and the tag agree on one spelling.
    function tidyCode(text) {
        return String(text === undefined || text === null ? "" : text)
            .trim().replace(/\s+/g, "").toUpperCase()
    }

    function commonValue(key) {
        var first = null
        for (var i = 0; i < root.songs.length; i++) {
            var value = root.valueOf(root.songs[i], key)
            if (i === 0) {
                first = value
                continue
            }
            if (value !== first) return null
        }
        return first === null ? "" : first
    }

    function isMixed(key) {
        return root.agreed[key] === null
    }

    // The flag for whatever the country field currently holds, agreed value or
    // fresh typing. Empty when what is in there is not a code.
    function flagPreview(key) {
        if (key !== "country") return ""
        return root.mpd ? root.mpd.flagEmoji(root.currentText(key)) : ""
    }

    function currentText(key) {
        // Untouched and mixed reads as empty, which is also what the user sees:
        // the "multiple" placeholder is the field saying so, not a value.
        if (root.touched[key]) return root.draft[key] === undefined ? "" : root.draft[key]
        var agreed = root.agreed[key]
        if (agreed === undefined) return ""
        return agreed === null ? "" : agreed
    }

    property var draft: ({})

    // Opening is what loads it, rather than the panel reaching in afterwards. The
    // two are set in the same tick, so `songs` is already in place by the time
    // this fires, and there is no window where the card is up showing fields that
    // have not been worked out yet.
    onVisibleChanged: if (visible && root.songs.length > 0) root.load()

    // Reopened on a new selection while already up: the panel reassigns `songs`
    // and `tagOpen` stays true, so `visible` never toggles and load() would not
    // otherwise run. Without this the scope pill counts the new selection while
    // every field still describes the old one, and a Save would write the old
    // drafts to the new songs' files.
    onSongsChanged: if (visible && root.songs.length > 0) root.load()

    Component.onCompleted: if (visible && root.songs.length > 0) root.load()

    function setText(key, text) {
        var d = {}
        for (var k in root.draft) d[k] = root.draft[k]
        d[key] = key === "country" ? root.tidyCode(text) : text
        root.draft = d
        var t = {}
        for (var k2 in root.touched) t[k2] = root.touched[k2]
        t[key] = true
        root.touched = t
    }

    // The Save button is the last stop in the focus cycle, past the final field,
    // so rowIndex counts one past the fields rather than being a second cursor.
    // That keeps the wrap arithmetic in one place: there are fields + 3 stops (the
    // match row, then the cover row, then Save), and every key that moves a row
    // just adds to the index and lets moveRow fold it.
    function matchStop() {
        return root.fields.length
    }

    function coverStop() {
        return root.fields.length + 1
    }

    function saveStop() {
        return root.fields.length + 2
    }

    // Focus goes to the text field inside the row rather than the row itself. The
    // row is a plain layout item, so focusing it takes the keyboard without a
    // caret in front of it -- which reads as "the fields are not editable" until
    // you click one.
    function focusRow() {
        if (root.rowIndex === root.saveStop()) {
            saveButton.forceActiveFocus()
            return
        }
        if (root.rowIndex === root.coverStop()) {
            browseButton.forceActiveFocus()
            return
        }
        if (root.rowIndex === root.matchStop()) {
            lookupButton.forceActiveFocus()
            return
        }
        var rows = fieldColumn.children
        for (var i = 0; i < rows.length; i++) {
            if (rows[i].fieldKey !== undefined && rows[i].fieldKey === root.fields[root.rowIndex].key) {
                rows[i].focusField()
                return
            }
        }
    }

    function moveRow(delta) {
        var n = root.saveStop() + 1
        root.rowIndex = ((root.rowIndex + delta) % n + n) % n
        root.focusRow()
    }

    // Opens a file chooser in the album folder, so the covers already beside the
    // tracks are the first thing on offer and one further afield is still a step
    // away. zenity is part of the desktop's own set of tools and returns the
    // chosen path on stdout; cancelling is an empty line and leaves the cover as
    // it was.
    function openBrowse() {
        if (root.busy) return
        var args = ["zenity", "--file-selection", "--title=Choose cover art",
                    "--file-filter=Images | *.jpg *.jpeg *.png *.webp *.gif *.bmp"]
        var folder = root.albumFolder()
        if (folder !== "") args.push("--filename=" + folder + "/")
        picker.command = args
        picker.running = true
    }

    // Landing back on the Browse button would make the next Enter reopen the
    // chooser rather than save the choice just made, so a picked image moves the
    // cursor on to Save; cancelling leaves the row where it was.
    function afterPicker() {
        if (root.coverChosen) root.rowIndex = root.saveStop()
        root.focusRow()
    }

    // A second press undoes a removal, so the decision is not one-way before Save.
    function clearCover() {
        if (root.busy) return
        if (root.coverAction === "remove") {
            root.coverAction = ""
        } else {
            root.coverAction = "remove"
            root.coverPath = ""
        }
        // The removal is the user's decision, not a lookup's: dropping this stops a
        // later candidate that has no front cover from taking the removal back
        // (see applyLookup).
        root.coverFromLookup = false
    }

    // ---- lookup ----

    // Search MusicBrainz with what the selection already says and pre-fill the
    // fields and the cover from the best match. Nothing is written: the point is
    // to show the match so it can be reviewed, corrected, or cycled past before
    // Save decides it.
    function lookUp() {
        if (root.busy || root.lookupBusy || !root.mpd) return
        // An artist's whole shelf disagrees about the album, and one search
        // cannot stand for several albums, so it is refused rather than guessed.
        if (root.isMixed("album")) {
            root.status = "Select a single album to look up"
            return
        }
        root.lookupBusy = true
        root.status = "Looking up…"
        var sess = root.session
        root.mpd.lookUpAlbum(root.songs, "", function (result) {
            root.lookupBusy = false
            // The editor was closed and possibly reopened on something else while
            // this ran; the answer belongs to the session that asked for it.
            if (sess !== root.session) return
            if (!result || result.status !== "ok") {
                root.status = "Look up failed" +
                    (result && result.message ? ": " + result.message : "")
                return
            }
            root.lookupCandidates = result.candidates ? result.candidates : []
            root.lookupIndex = 0
            root.applyLookup(result)
        })
    }

    // Walk to the next candidate and re-fetch it. The search is not repeated --
    // only the chosen release is detailed, so a cycle costs one round trip.
    function cycleMatch(delta) {
        if (root.busy || root.lookupBusy || !root.mpd) return
        var n = root.lookupCandidates.length
        if (n < 2) return
        var next = ((root.lookupIndex + delta) % n + n) % n
        var candidate = root.lookupCandidates[next]
        root.lookupBusy = true
        root.status = "Looking up…"
        var sess = root.session
        root.mpd.lookUpAlbum(root.songs, candidate.mbid, function (result) {
            root.lookupBusy = false
            if (sess !== root.session) return
            if (!result || result.status !== "ok") {
                root.status = "Look up failed" +
                    (result && result.message ? ": " + result.message : "")
                return
            }
            // Commit the move only once the fetch for it has landed, so a failed
            // step leaves the caret on the candidate still being shown rather
            // than skipping one and naming a release that was never applied.
            root.lookupIndex = next
            root.applyLookup(result)
        })
    }

    function applyLookup(result) {
        // Taken before anything is overwritten, so it is the selection's own
        // values, not the previous candidate's. A no-op after the first match.
        root.snapshotLookupBase()
        var d = {}
        for (var k in root.draft) d[k] = root.draft[k]
        var t = {}
        for (var k2 in root.touched) t[k2] = root.touched[k2]

        var put = function (key, value) {
            if (value === undefined || value === null || String(value) === "") return
            d[key] = key === "country" ? root.tidyCode(value) : String(value)
            t[key] = true
        }
        put("artist", result.artist)
        put("albumArtist", result.albumArtist)
        put("album", result.album)
        put("date", result.date)
        // Only a non-empty country is taken: MusicBrainz omits it for some
        // releases, and an empty answer must not blank a deliberate tag.
        if (result.country) {
            d["country"] = root.tidyCode(result.country)
            t["country"] = true
        }

        // Per-track fields go in lookupPerFile keyed by file, so only files in
        // the selection are ever covered. For a lone track they are also that
        // track's own facts, so they are copied into the shared fields and show
        // in the UI; for an album they differ per track and stay only in the map.
        var per = {}
        if (result.tracks) {
            for (var i = 0; i < result.tracks.length; i++) {
                var tr = result.tracks[i]
                if (!tr.file) continue
                var entry = {}
                if (tr.title) entry.title = String(tr.title)
                if (tr.track !== undefined && tr.track !== "") entry.track = String(tr.track)
                if (tr.disc !== undefined && tr.disc !== "") entry.disc = String(tr.disc)
                per[String(tr.file)] = entry
            }
        }
        root.lookupPerFile = per
        if (root.songs.length === 1) {
            // The lone track's own match, never the release's first track: a file
            // the helper could not match to a number has to keep its own title
            // and number rather than be handed another track's.
            var only = per[String(root.songs[0].file)]
            if (only) {
                put("title", only.title)
                put("track", only.track)
                put("disc", only.disc)
            }
        }
        root.draft = d
        root.touched = t
        // The fields no longer bind to currentText (see setFieldText), so a
        // lookup has to push the values it just drafted into the fields itself.
        root.syncFields()

        if (result.cover && result.cover !== "") {
            root.coverAction = "set"
            root.coverPath = result.cover
            root.coverFromLookup = true
        } else if (root.coverFromLookup) {
            // This candidate has no front cover, so the previous one's must go
            // rather than stand in for it.
            root.coverAction = ""
            root.coverPath = ""
            root.coverFromLookup = false
        }

        var parts = ["Match " + (root.lookupIndex + 1) + "/"
            + root.lookupCandidates.length + "  " + root.matchSummaryBody(result)]
        if (root.songs.length > 1 && result.tracks && result.tracks.length > 0) {
            parts.push(Math.min(root.songs.length, result.tracks.length) + " track titles")
        }
        if (root.coverAction === "set") {
            // Say where the cover came from and how big it is: a store cover and
            // an archive scan are not the same thing, and the size is what tells
            // a clean 1200px square from a smaller or cropped one.
            var w = result.coverWidth || 0
            var h = result.coverHeight || 0
            var desc = "cover"
            if (result.coverSource) desc += " from " + result.coverSource
            if (w > 0 && h > 0) desc += " (" + w + "×" + h + ")"
            parts.push(desc)
        }
        root.status = parts.join(" · ")
    }

    function matchSummaryBody(result) {
        var artist = result.artist || ""
        var where = artist
        if (result.album) where += (where !== "" ? " – " : "") + result.album
        if (result.date) where += " (" + result.date + ")"
        return where
    }

    // What a field held before the first match of the session, so the fields can
    // show what they held and Revert can hand it back. Mixed is null, the same
    // signal the fields already use, so it can read as "multiple" rather than
    // empty and a genuine empty can read as such.
    function snapshotLookupBase() {
        if (root.hasPreLookup) return
        var d = {}
        for (var k in root.draft) d[k] = root.draft[k]
        var t = {}
        for (var k2 in root.touched) t[k2] = root.touched[k2]
        root.preLookupDraft = d
        root.preLookupTouched = t
        root.preLookupCoverAction = root.coverAction
        root.preLookupCoverPath = root.coverPath
        root.preLookupCoverFromLookup = root.coverFromLookup
        root.hasPreLookup = true
    }

    function baseValue(key) {
        if (root.preLookupTouched[key]) {
            return root.preLookupDraft[key] === undefined ? "" : root.preLookupDraft[key]
        }
        var agreed = root.agreed[key]
        if (agreed === undefined) return ""
        return agreed
    }

    // Whether the match (or a later edit) moved this field off its before value,
    // which is what earns it a "was" line under the field.
    function fieldChanged(key) {
        if (!root.hasPreLookup) return false
        var was = root.baseValue(key)
        var now = root.currentText(key)
        if (was === null) return String(now) !== ""
        return String(was) !== String(now)
    }

    function baseLabel(key) {
        var was = root.baseValue(key)
        if (was === null) return "multiple"
        if (String(was) === "") return "empty"
        return String(was)
    }

    // Hands back what the selection had before the match, cover and all. Dropping
    // hasPreLookup makes the next lookup snapshot afresh from what is on screen
    // now; the candidates stay, so Next can still re-apply a match after a revert.
    function revertLookup() {
        if (root.busy || !root.hasPreLookup) return
        var d = {}
        for (var k in root.preLookupDraft) d[k] = root.preLookupDraft[k]
        var t = {}
        for (var k2 in root.preLookupTouched) t[k2] = root.preLookupTouched[k2]
        root.draft = d
        root.touched = t
        root.coverAction = root.preLookupCoverAction
        root.coverPath = root.preLookupCoverPath
        root.coverFromLookup = root.preLookupCoverFromLookup
        root.lookupPerFile = {}
        root.hasPreLookup = false
        root.syncFields()
        root.status = "Match reverted"
    }

    // The match buttons and the cover buttons each form one stop, and every key
    // that is not theirs falls through to here: Escape closes the editor,
    // Tab/Down/Up moves a row. Shared by both so the two paths cannot drift.
    function rowKey(event) {
        if (event.key === Qt.Key_Escape) {
            root.dismissed()
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down
                || event.key === Qt.Key_Up) {
            root.moveRow(event.key === Qt.Key_Up || (event.key === Qt.Key_Tab
                && (event.modifiers & Qt.ShiftModifier)) ? -1 : 1)
        }
        event.accepted = true
    }

    // The match row is one stop, and Left/Right walks its buttons in the order
    // they are shown -- which ones exist depends on whether a match has landed
    // and how many candidates there were, so the walk is built from what is
    // visible rather than from a fixed chain.
    function matchButtons() {
        var list = [lookupButton]
        if (prevButton.visible) list.push(prevButton)
        if (nextButton.visible) list.push(nextButton)
        if (revertButton.visible) list.push(revertButton)
        return list
    }

    function shiftMatchFocus(from, delta) {
        var list = root.matchButtons()
        if (list.length < 2) return false
        var i = list.indexOf(from)
        if (i < 0) return false
        list[(i + delta + list.length) % list.length].forceActiveFocus()
        return true
    }

    function matchKey(event, source, action) {
        // Escape must reach the row handler even mid-lookup: the busy guard below
        // is about not queueing more work or moving focus, and closing the editor
        // is neither. Swallowing it left Escape dead while a lookup ran.
        if ((root.busy || root.lookupBusy) && event.key !== Qt.Key_Escape) {
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            action()
            event.accepted = true
            return
        }
        if ((event.key === Qt.Key_Right || event.key === Qt.Key_Left)
                && root.shiftMatchFocus(source, event.key === Qt.Key_Right ? 1 : -1)) {
            event.accepted = true
            return
        }
        root.rowKey(event)
    }

    function onLookupKey(event) { root.matchKey(event, lookupButton, root.lookUp) }
    function onPrevKey(event) { root.matchKey(event, prevButton, function () { root.cycleMatch(-1) }) }
    function onNextKey(event) { root.matchKey(event, nextButton, function () { root.cycleMatch(1) }) }
    function onRevertKey(event) { root.matchKey(event, revertButton, root.revertLookup) }

    // The two cover buttons are one stop in the cycle, so Left/Right walks between
    // them and everything else moves a row, the same as a field.
    function onBrowseKey(event) {
        if (root.busy && event.key !== Qt.Key_Escape) { event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.openBrowse()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Right && removeButton.visible) {
            removeButton.forceActiveFocus()
            event.accepted = true
            return
        }
        root.rowKey(event)
    }

    function onRemoveKey(event) {
        if (root.busy && event.key !== Qt.Key_Escape) { event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.clearCover()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Left) {
            browseButton.forceActiveFocus()
            event.accepted = true
            return
        }
        root.rowKey(event)
    }

    Process {
        id: picker
        running: false
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                var path = this.text.trim()
                if (path === "") return
                root.coverPath = path
                root.coverAction = "set"
                root.coverFromLookup = false
            }
        }
        // The chooser is a window of its own and takes the keyboard with it; hand
        // focus back to the card so the editor keeps working afterwards.
        onExited: {
            card.forceActiveFocus()
            Qt.callLater(root.afterPicker)
        }
    }

    // Tab out of the modal would otherwise walk focus into the panel underneath,
    // so the cycle is ours and Tab joins the arrows rather than escaping it.
    function onSaveKey(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.saveOrClose()
            event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
            root.dismissed()
            event.accepted = true
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            // The two decision buttons are a ring of their own, so a Left off
            // Save lands on Cancel rather than nowhere.
            cancelButton.forceActiveFocus()
            event.accepted = true
        } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Down
                || event.key === Qt.Key_Up) {
            root.moveRow(event.key === Qt.Key_Up || (event.key === Qt.Key_Tab
                && (event.modifiers & Qt.ShiftModifier)) ? -1 : 1)
            event.accepted = true
        }
    }

    function onCancelKey(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.cancel()
            event.accepted = true
            return
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            saveButton.forceActiveFocus()
            event.accepted = true
            return
        }
        // Escape, Tab and the arrows are the editor's, not the button's.
        root.onSaveKey(event)
    }

    function scopeText() {
        if (root.songs.length === 0) return "Nothing selected"
        if (root.songs.length === 1) return "1 track"
        return root.songs.length + " tracks"
    }

    // Cancel and Esc do the same thing: close and throw the edits away. Nothing
    // is written until Save, so nothing here needs a warning.
    function cancel() {
        if (root.busy) return
        root.dismissed()
    }

    // The Save button becomes a Close once a save has landed and nothing new is
    // staged, so the same key finishes the session rather than answering
    // "Nothing changed".
    function saveOrClose() {
        if (root.busy) return
        if (root.saveIsClose) {
            root.dismissed()
            return
        }
        root.save()
    }

    function save() {
        if (root.busy) return
        var tags = {}
        var any = false
        for (var f = 0; f < root.fields.length; f++) {
            var key = root.fields[f].key
            if (!root.touched[key]) continue
            tags[key] = root.draft[key] === undefined ? "" : String(root.draft[key]).trim()
            any = true
        }
        // A matched album's per-track titles and numbers are not in the shared
        // fields; they ride alongside them and are written per file.
        var perFile = root.lookupPerFile ? root.lookupPerFile : {}
        var hasPerFile = Object.keys(perFile).length > 0
        // A "set" with nothing chosen is not an edit; treat it as untouched.
        var cover = (root.coverAction === "set" && root.coverPath === "") ? "" : root.coverAction
        // Captured, not read at callback time: the cover write runs after the tag
        // write, and an editor closed and reopened in between would have cleared
        // root.coverPath, silently dropping the cover that was chosen here.
        var coverPath = root.coverPath
        if (!any && !hasPerFile && cover === "") {
            root.status = "Nothing changed"
            return
        }
        var files = []
        for (var s = 0; s < root.songs.length; s++) files.push(root.songs[s])
        root.busy = true
        root.status = "Writing…"
        var sess = root.session

        var finish = function (tagResult, coverResult) {
            // The editor may have been closed and reopened while the taggers ran.
            // The files were still written -- that part is done -- but the UI
            // state below belongs to the session that asked for it, not to
            // whatever is on screen now.
            if (sess !== root.session) return
            root.busy = false
            var parts = []
            if (tagResult) {
                if (tagResult.written > 0) parts.push(tagResult.written + " updated")
                if (tagResult.failed > 0) parts.push(tagResult.failed + " failed")
                if (tagResult.skipped > 0) parts.push(tagResult.skipped + " skipped")
            }
            if (coverResult) {
                if (coverResult.failed > 0) parts.push("cover failed")
                // A cue album's tracks have no writable file, so the cover edit was
                // skipped for every one of them. Reporting "cover set" there claimed
                // work that never happened; the skip is the honest answer, and it is
                // the same wording the tag half uses.
                else if (!coverResult.changed && coverResult.skipped > 0)
                    parts.push(coverResult.skipped + " skipped")
                else parts.push(cover === "remove" ? "cover removed" : "cover set")
            }
            root.status = parts.length > 0 ? parts.join(" · ") : "Nothing changed"
            // Everything the user just asked for has been dealt with, so the draft
            // is no longer pending. Clearing `touched` is what stops the next open
            // from offering the previous edit's values as if they were agreed on.
            root.touched = {}
            root.draft = {}
            root.coverAction = ""
            root.coverPath = ""
            root.lookupCandidates = []
            root.lookupIndex = 0
            root.lookupPerFile = {}
            root.coverFromLookup = false
            root.hasPreLookup = false
            root.wroteThisSession = true
            // The values to show come from what was just written, not from a
            // re-read of the selection: `songs` is the snapshot the editor was
            // opened with and the panel replaces its own objects when the library
            // reloads, so commonValue() here would hand back the pre-edit values
            // and every field would visibly revert until the editor was reopened.
            root.settleAgreed(tags, hasPerFile)
        }

        // Tags first, then the cover: both rewrite the same files, and the two
        // taggers must not be open on one file at once.
        if (any || hasPerFile) {
            root.mpd.applyTagsSet(files, tags, perFile, function (tagResult) {
                if (cover === "") { finish(tagResult, null); return }
                root.mpd.applyCover(files, cover, coverPath, function (coverResult) {
                    finish(tagResult, coverResult)
                })
            })
        } else {
            root.mpd.applyCover(files, cover, coverPath, function (coverResult) {
                finish(null, coverResult)
            })
        }
    }

    // The agreed values after a save, built from what was written rather than from
    // the stale selection. A shared field the user touched now holds the value
    // that went to every file; a per-track field a lookup filled holds a different
    // value in each file, so it reads as "multiple" again; a field nobody touched
    // keeps what it showed before.
    function settleAgreed(tags, hasPerFile) {
        var a = {}
        for (var f = 0; f < root.fields.length; f++) {
            var key = root.fields[f].key
            if (tags[key] !== undefined) {
                a[key] = tags[key]
            } else if (hasPerFile
                    && (key === "title" || key === "track" || key === "disc")) {
                a[key] = null
            } else {
                a[key] = root.agreed[key]
            }
        }
        root.agreed = a
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        MouseArea {
            anchors.fill: parent
            onClicked: if (!root.busy) root.dismissed()
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.round(620 * root.uiScale)
        // Tall enough for the fields as they stand, and taller as "was" lines
        // appear; never taller than the room the panel gives it, so it stays on
        // screen. 560 is the height the fields alone need.
        readonly property real maxCardHeight: Math.max(
            Math.round(320 * root.uiScale),
            root.height - Math.round(32 * root.uiScale))
        height: Math.min(Math.round((560 + root.changedFieldCount * 18) * root.uiScale),
                         card.maxCardHeight)
        radius: Math.round(12 * root.uiScale)
        color: root.colBackground
        border.width: 1
        border.color: Util.alpha(root.colForeground, 0.10)

        // Keys reach the card rather than the browser underneath, and the panel's
        // own key catcher is stood down while this is up for the same reason: a
        // j typed into the genre field must not move the caret.
        focus: true
        Keys.onPressed: function (event) {
            if (root.busy) {
                if (event.key === Qt.Key_Escape) root.dismissed()
                event.accepted = true
                return
            }
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
                root.dismissed()
                event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                // Same decision as the button: after a save with nothing staged,
                // Enter closes rather than writing nothing a second time.
                root.saveOrClose()
                event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
                root.moveRow(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                root.moveRow(1)
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                root.moveRow(-1)
                event.accepted = true
            } else if (event.key === Qt.Key_G && (event.modifiers & Qt.ShiftModifier)) {
                // Jump to the last stop in the cycle, the way the settings card's
                // G does. The old form only worked from the first row and moved up
                // one step from anywhere else.
                root.rowIndex = root.saveStop()
                root.focusRow()
                event.accepted = true
            } else if (event.key === Qt.Key_L) {
                // Only reaches the card when no field has focus, so an "l" typed
                // into a tag never triggers a lookup.
                root.lookUp()
                event.accepted = true
            }
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Math.round(24 * root.uiScale)
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(10 * root.uiScale)

                Text {
                    text: "Edit tags"
                    color: root.colForeground
                    font.pixelSize: Math.round(Style.font.subtitle * root.uiScale)
                    font.weight: Font.DemiBold
                    font.family: Style.font.family
                }

                Rectangle {
                    width: scopeLabel.implicitWidth + Math.round(16 * root.uiScale)
                    height: Math.round(20 * root.uiScale)
                    radius: height / 2
                    color: Util.alpha(root.colAccent, 0.14)

                    Text {
                        id: scopeLabel
                        anchors.centerIn: parent
                        text: root.scopeText()
                        color: root.colAccent
                        font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                        font.family: Style.font.family
                    }
                }

                Item { Layout.fillWidth: true }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(14 * root.uiScale)
                Layout.bottomMargin: Math.round(10 * root.uiScale)
                Layout.preferredHeight: 1
                color: Util.alpha(root.colForeground, 0.08)
            }

            ColumnLayout {
                id: fieldColumn
                Layout.fillWidth: true
                spacing: 0

                Repeater {
                    model: root.fields

                    delegate: ColumnLayout {
                        id: row
                        required property var modelData
                        required property int index

                        readonly property string fieldKey: modelData.key
                        readonly property bool focused: root.rowIndex === index
                        // Whether a lookup (or a later edit) moved this field off
                        // what it held, which is what earns it a "was" line below.
                        readonly property bool changed: root.fieldChanged(row.fieldKey)

                        // Handed to the panel's focus walk, which only knows how to
                        // address a row and not what is inside it.
                        function focusField() { input.forceActiveFocus() }

                        // Field text is pushed in rather than bound: a TextField
                        // writes its own `text` from inside the control while the
                        // user types, which destroys a declarative binding on it.
                        // The delegates are never recreated, so a bound field kept
                        // showing whatever was last typed on the previous album.
                        // Setting it after every load is what keeps a reopened
                        // editor honest.
                        function setFieldText() { input.text = root.currentText(row.fieldKey) }

                        Layout.fillWidth: true
                        // A field carrying a "was" line needs the extra height, or
                        // the line would be drawn over the row below it.
                        Layout.preferredHeight: Math.round(34 * root.uiScale)
                            + (row.changed ? Math.round(18 * root.uiScale) : 0)
                        spacing: Math.round(2 * root.uiScale)

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.preferredHeight: Math.round(34 * root.uiScale)
                            spacing: Math.round(12 * root.uiScale)

                            Text {
                                Layout.preferredWidth: Math.round(130 * root.uiScale)
                                text: row.modelData.label
                                color: row.focused ? root.colForeground
                                                     : Util.alpha(root.colMuted, 1.0)
                                font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                font.family: Style.font.family
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.round(28 * root.uiScale)

                                TextField {
                                    id: input
                                    anchors.fill: parent
                                    // No `text` binding: the control writes this
                                    // property itself while typing, which drops a
                                    // binding and left the field showing the last
                                    // album's value. Text is pushed by setFieldText().
                                    // Only offered when the selection disagrees. A field
                                    // the tracks all left empty stays empty and reads as
                                    // empty, which is a different offer than "we differ".
                                    placeholderText: root.isMixed(row.modelData.key) ? "multiple" : ""
                                    placeholderTextColor: Util.alpha(root.colAccent, 0.75)
                                    color: root.colForeground
                                    font.pixelSize: Math.round(Style.font.body * root.uiScale)
                                    font.family: Style.font.family
                                    selectByMouse: true
                                    // The flag stands in for the field while typing so
                                    // there is room for it, rather than overlapping the
                                    // caret on whatever the user has typed.
                                    rightPadding: row.modelData.key === "country"
                                        ? Math.round(34 * root.uiScale) : 0

                                    background: Rectangle {
                                        radius: Math.round(6 * root.uiScale)
                                        color: Util.alpha(root.colForeground, row.focused ? 0.10 : 0.05)
                                        border.width: 1
                                        border.color: row.focused
                                            ? Util.alpha(root.colAccent, 0.7)
                                            : Util.alpha(root.colForeground, 0.12)
                                    }

                                    onTextEdited: root.setText(row.modelData.key, text)
                                    onActiveFocusChanged: {
                                        if (activeFocus) root.rowIndex = row.index
                                    }

                                    // A focused text field eats arrows for caret movement
                                    // and Tab for focus traversal, which would strand the
                                    // keyboard in whichever field you happened to click.
                                    // Taking them here is what makes the up/down and Tab
                                    // in the card's handler reachable once a field has
                                    // focus -- the card never sees an event its focused
                                    // child already accepted.
                                    Keys.onPressed: function (event) {
                                        if (event.key === Qt.Key_Up) {
                                            root.moveRow(-1)
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_Down) {
                                            root.moveRow(1)
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_Tab) {
                                            root.moveRow(event.modifiers & Qt.ShiftModifier ? -1 : 1)
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_Return
                                                || event.key === Qt.Key_Enter) {
                                            // A focused field would otherwise insert
                                            // nothing and swallow the save.
                                            root.saveOrClose()
                                            event.accepted = true
                                        } else if (event.key === Qt.Key_Escape) {
                                            root.dismissed()
                                            event.accepted = true
                                        }
                                    }
                                }

                                // The country tag holds an ISO 3166-1 alpha-2 code, and
                                // the flag in the now-playing strip is derived from
                                // exactly those two characters -- so the flag shown here
                                // is what that strip will show. Appearing as the code is
                                // typed is also the only hint that a code is wanted: a
                                // country name has no way back to a code.
                                Text {
                                    visible: row.modelData.key === "country"
                                        && root.flagPreview(row.modelData.key) !== ""
                                    anchors.right: parent.right
                                    anchors.rightMargin: Math.round(8 * root.uiScale)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.flagPreview(row.modelData.key)
                                    font.pixelSize: Math.round(16 * root.uiScale)
                                }
                            }
                        }

                        // What the field held before the match landed, so a lookup
                        // can be judged rather than simply trusted. Shown only when
                        // the match actually moved the field.
                        Text {
                            Layout.fillWidth: true
                            Layout.leftMargin: Math.round(142 * root.uiScale)
                            visible: row.changed
                            text: "was: " + root.baseLabel(row.fieldKey)
                            color: Util.alpha(root.colMuted, 0.85)
                            font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                            font.family: Style.font.family
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            // The match row: one button that searches MusicBrainz for this album
            // and, once there is an answer, one that walks to the next candidate.
            // It sits with the fields because what it does is fill them, and it
            // writes nothing -- Save is still what commits the result.
            RowLayout {
                id: matchRow
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(34 * root.uiScale)
                spacing: Math.round(12 * root.uiScale)

                Text {
                    Layout.preferredWidth: Math.round(130 * root.uiScale)
                    Layout.alignment: Qt.AlignVCenter
                    text: "Match"
                    color: root.matchFocused ? root.colForeground
                                             : Util.alpha(root.colMuted, 1.0)
                    font.pixelSize: Math.round(Style.font.body * root.uiScale)
                    font.family: Style.font.family
                }

                Rectangle {
                    id: lookupButton
                    Layout.alignment: Qt.AlignVCenter
                    width: lookupLabel.implicitWidth + Math.round(24 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: lookupMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colAccent, 0.26)
                        : Util.alpha(root.colAccent, 0.16)
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(root.colAccent, 0.7)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onLookupKey(event)

                    Text {
                        id: lookupLabel
                        anchors.centerIn: parent
                        text: root.lookupBusy ? "Looking…" : "Look up"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: lookupMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.lookUp()
                    }
                }

                Rectangle {
                    id: prevButton
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.lookupCandidates.length > 1
                    width: prevLabel.implicitWidth + Math.round(24 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: prevMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colForeground, 0.14)
                        : Util.alpha(root.colForeground, 0.06)
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(root.colForeground, 0.30)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onPrevKey(event)

                    Text {
                        id: prevLabel
                        anchors.centerIn: parent
                        text: "‹ Prev"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: prevMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.cycleMatch(-1)
                    }
                }

                Rectangle {
                    id: nextButton
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.lookupCandidates.length > 1
                    width: nextLabel.implicitWidth + Math.round(24 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: nextMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colForeground, 0.14)
                        : Util.alpha(root.colForeground, 0.06)
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(root.colForeground, 0.30)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onNextKey(event)

                    Text {
                        id: nextLabel
                        anchors.centerIn: parent
                        text: "Next ›"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: nextMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.cycleMatch(1)
                    }
                }

                Rectangle {
                    id: revertButton
                    Layout.alignment: Qt.AlignVCenter
                    // Only once a match has been applied: before that there is
                    // nothing to hand back.
                    visible: root.hasPreLookup
                    width: revertLabel.implicitWidth + Math.round(24 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: revertMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colForeground, 0.16)
                        : Util.alpha(root.colForeground, 0.07)
                    border.width: 1
                    border.color: Util.alpha(root.colForeground, 0.30)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onRevertKey(event)

                    Text {
                        id: revertLabel
                        anchors.centerIn: parent
                        text: "Revert"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: revertMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.revertLookup()
                    }
                }

                Text {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.matchSummary !== ""
                    text: root.matchSummary
                    color: Util.alpha(root.colMuted, 1.0)
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                    font.family: Style.font.family
                }
            }

            // The cover is an album-level fact like the fields above it, so it sits
            // with them, under the last one. It reads the same way -- a label, then
            // what it holds -- but its value lives in the files rather than in a
            // single tag MPD reports, so it is edited through buttons.
            RowLayout {
                id: coverRow
                Layout.fillWidth: true
                Layout.preferredHeight: Math.round(44 * root.uiScale)
                spacing: Math.round(12 * root.uiScale)

                Text {
                    Layout.preferredWidth: Math.round(130 * root.uiScale)
                    Layout.alignment: Qt.AlignVCenter
                    text: "Cover art"
                    color: root.coverFocused ? root.colForeground
                                             : Util.alpha(root.colMuted, 1.0)
                    font.pixelSize: Math.round(Style.font.body * root.uiScale)
                    font.family: Style.font.family
                }

                Item {
                    Layout.preferredWidth: Math.round(40 * root.uiScale)
                    Layout.preferredHeight: Math.round(40 * root.uiScale)
                    Layout.alignment: Qt.AlignVCenter

                    // Shown until the cover is marked for removal. The instance
                    // overrides CoverArt's own visibility because the editor always
                    // wants the disc when there is no art, and never wants disk art
                    // standing in for a cover the user has just cleared.
                    CoverArt {
                        id: previewArt
                        anchors.fill: parent
                        mpd: root.mpd
                        theme: root.theme
                        uiScale: root.uiScale
                        subject: root.previewSubject
                        // The editor's own instance, and only while the editor is up.
                        active: root.visible
                        coverBorder: false
                        placeholder: true
                        transitionDuration: root.coverTransition
                        fetchCovers: root.fetchCovers
                        rounded: root.coverRounded
                        visible: root.coverAction !== "remove"
                        overrideSource: root.coverChosen ? Covers.fileUrl(root.coverPath) : ""
                    }

                    Rectangle {
                        anchors.fill: parent
                        visible: root.coverAction === "remove"
                        radius: Math.round(6 * root.uiScale)
                        color: Util.alpha(root.colForeground, 0.05)
                        border.width: 1
                        border.color: Util.alpha(root.colForeground, 0.12)

                        Text {
                            anchors.centerIn: parent
                            text: "None"
                            color: Util.alpha(root.colMuted, 1.0)
                            font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                            font.family: Style.font.family
                        }
                    }
                }

                Rectangle {
                    id: browseButton
                    Layout.alignment: Qt.AlignVCenter
                    width: browseLabel.implicitWidth + Math.round(24 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: browseMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colAccent, 0.26)
                        : Util.alpha(root.colAccent, 0.16)
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(root.colAccent, 0.7)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onBrowseKey(event)

                    Text {
                        id: browseLabel
                        anchors.centerIn: parent
                        text: "Browse…"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: browseMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.openBrowse()
                    }
                }

                Rectangle {
                    id: removeButton
                    Layout.alignment: Qt.AlignVCenter
                    // Stays up while a removal is pending, so the documented
                    // second press can undo it. coverShown is false once the cover
                    // is marked removed, hence the extra term.
                    visible: root.coverShown || root.coverAction === "remove"
                    width: removeLabel.implicitWidth + Math.round(24 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: removeMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colForeground, 0.14)
                        : Util.alpha(root.colForeground, 0.06)
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(root.colForeground, 0.30)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onRemoveKey(event)

                    Text {
                        id: removeLabel
                        anchors.centerIn: parent
                        text: root.coverAction === "remove" ? "Undo" : "Remove"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: removeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.clearCover()
                    }
                }
            }

            Item { Layout.fillHeight: true }

            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: Math.round(10 * root.uiScale)
                Layout.bottomMargin: Math.round(8 * root.uiScale)
                Layout.preferredHeight: 1
                color: Util.alpha(root.colForeground, 0.08)
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Math.round(10 * root.uiScale)

                Text {
                    Layout.fillWidth: true
                    text: root.status !== "" ? root.status
                        : "Enter saves · Cancel discards · L looks up · ← → cycle matches · Tab moves"
                    color: root.status === "" ? Util.alpha(root.colMuted, 1.0)
                                               : Util.alpha(root.colAccent, 1.0)
                    elide: Text.ElideRight
                    font.pixelSize: Math.round(Style.font.caption * root.uiScale)
                    font.family: Style.font.family
                }

                Rectangle {
                    id: cancelButton
                    width: cancelLabel.implicitWidth + Math.round(28 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    // Muted next to Save: discarding is the quiet choice, and the
                    // accent belongs on the one that writes.
                    color: cancelMouse.containsMouse || activeFocus
                        ? Util.alpha(root.colForeground, 0.16)
                        : Util.alpha(root.colForeground, 0.06)
                    border.width: 1
                    border.color: Util.alpha(root.colForeground, 0.25)
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onCancelKey(event)

                    Text {
                        id: cancelLabel
                        anchors.centerIn: parent
                        text: "Cancel"
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: cancelMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.cancel()
                    }
                }

                Rectangle {
                    id: saveButton
                    width: saveLabel.implicitWidth + Math.round(28 * root.uiScale)
                    height: Math.round(28 * root.uiScale)
                    radius: Math.round(6 * root.uiScale)
                    color: saveMouse.containsMouse || root.busy || activeFocus
                        ? Util.alpha(root.colAccent, 0.26)
                        : Util.alpha(root.colAccent, 0.16)

                    // Same affordance the focused field rows use, so landing on the
                    // button from the last field reads as focus having moved rather
                    // than as the editor having lost the caret.
                    border.width: activeFocus ? 1 : 0
                    border.color: Util.alpha(root.colAccent, 0.7)

                    // Ours, not the focus traversal's: Tab past the last field must
                    // come here rather than leave the modal for the panel under it.
                    activeFocusOnTab: false
                    Keys.onPressed: (event) => root.onSaveKey(event)

                    Text {
                        id: saveLabel
                        anchors.centerIn: parent
                        text: root.busy ? "Writing…" : (root.saveIsClose ? "Close" : "Save")
                        color: root.colForeground
                        font.pixelSize: Math.round(Style.font.body * root.uiScale)
                        font.family: Style.font.family
                    }

                    MouseArea {
                        id: saveMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.saveOrClose()
                    }
                }
            }
        }
    }
}
