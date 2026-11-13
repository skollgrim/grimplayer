// What a Save is about to do, what its result means, and what the fields show
// afterwards.
//
// The tag editor's save is mostly choreography -- one write after another, a
// session guard, a rename that must wait for the tags -- but the decisions in it
// are ordinary arithmetic over the drafts, and they are the parts that were
// wrong before: a cover that was chosen and then lost, a save that reported
// "3 failed" and dropped the rest of the edit, a rename that would have spelled
// a name from a tag that never landed. They live here so
// extras/test-tag-save.js can put each of those through its paces without
// touching a file.
//
// Plain script rather than a `.pragma library`: a change here must be picked up
// with the component that imports it.
//
// MPD cannot write tags itself -- the taggers do, see TagFrames.js -- and a cue
// album's tracks are virtual, so `writable` answers with an empty string for a
// file that must be left alone.

// The edit the drafts describe, or null when there is nothing to do.
//
// state: fields, touched, draft, perFileDraft, coverAction, coverPath,
//        renamePending, renameItems, songs.
//
// A "set" cover with no path chosen is not an edit: the action says what the
// user meant, the missing path says they never got as far as picking the file.
function pending(state) {
    var s = state || {}
    var fields = s.fields || []
    var touched = s.touched || {}
    var draft = s.draft || {}

    var tags = {}
    var any = false
    for (var i = 0; i < fields.length; i++) {
        var key = fields[i].key
        if (!touched[key]) continue
        tags[key] = draft[key] === undefined ? "" : String(draft[key]).trim()
        any = true
    }

    // A matched album's per-track titles and numbers are not in the shared
    // fields; they ride alongside them and are written per file.
    var perFile = s.perFileDraft ? s.perFileDraft : {}
    var hasPerFile = Object.keys(perFile).length > 0

    var action = s.coverAction === undefined || s.coverAction === null
        ? "" : String(s.coverAction)
    var cover = (action === "set" && !s.coverPath) ? "" : action

    // A rename is the save's last step: the tags go to the files first, then
    // each file takes the name those tags spell.
    var items = s.renameItems || []
    var renaming = !!s.renamePending && items.length > 0

    if (!any && !hasPerFile && cover === "" && !renaming) return null

    return {
        tags: tags,
        perFile: perFile,
        hasPerFile: hasPerFile,
        // Whether the taggers have anything to write. False for a cover-only or
        // rename-only save, which skip straight to their own step.
        writing: any || hasPerFile,
        cover: cover,
        // Captured, not read at callback time: the cover write runs after the
        // tag write, and an editor closed and reopened in between would have
        // cleared the path, silently dropping the cover that was chosen here.
        coverPath: s.coverPath || "",
        renaming: renaming,
        // The selection as it stood when Save was pressed: the editor's own
        // objects are replaced when the library reloads.
        songs: (s.songs || []).slice(),
        // Renaming-only says so: there is no write to wait for, so "Writing…"
        // would name work that is not happening.
        status: (!any && !hasPerFile && cover === "") ? "Renaming…" : "Writing…"
    }
}

// The counts a result reports, as the phrases the status line shows. Empty when
// there is nothing to say, so a caller can fall back to "Nothing changed".
//
// A cue album's tracks have no writable file, and a format no tagger can open
// cannot take a picture either. Reporting "cover set" for those claimed work
// that never happened; the skip is the honest answer, and it is the same word
// the tag half uses. Both counts can be real at once in a mixed selection.
function summary(tagResult, coverResult, cover) {
    var parts = []
    if (tagResult) {
        if (tagResult.written > 0) parts.push(tagResult.written + " updated")
        if (tagResult.failed > 0) parts.push(tagResult.failed + " failed")
        if (tagResult.skipped > 0) parts.push(tagResult.skipped + " skipped")
    }
    if (coverResult) {
        if (coverResult.failed > 0) parts.push("cover failed")
        else if (coverResult.changed)
            parts.push(cover === "remove" ? "cover removed" : "cover set")
        if (coverResult.skipped > 0) parts.push(coverResult.skipped + " skipped")
    }
    return parts.join(" · ")
}

function failed(tagResult, coverResult) {
    return !!((tagResult && tagResult.failed > 0)
        || (coverResult && coverResult.failed > 0))
}

// Part of the edit did not land. The files that did are written, but the draft
// is kept: clearing it would silently drop what did not and say so with a bare
// "3 failed". The retry wording is what tells the user the edit is still staged,
// and a rename is dropped with the failed write -- naming a file after a tag
// that was not written would put a lie on disk.
function failureStatus(tagResult, coverResult, cover, renaming) {
    var text = summary(tagResult, coverResult, cover) || "Nothing changed"
    text += " — press Save to retry"
    if (renaming) text += " — name unchanged"
    return text
}

// What the fields show once a save has landed.
//
// A shared field the user touched now holds the value that went to every file; a
// per-track field a lookup filled holds a different value in each file, so it
// reads as "multiple" again (null); a field nobody touched keeps what it showed
// before.
function agreed(fields, tags, hasPerFile, current) {
    var out = {}
    var list = fields || []
    for (var i = 0; i < list.length; i++) {
        var key = list[i].key
        if (tags[key] !== undefined) out[key] = tags[key]
        else if (hasPerFile && (key === "title" || key === "track" || key === "disc"))
            out[key] = null
        else out[key] = current[key]
    }
    return out
}

// The selection's own objects still hold what the files said when the editor
// opened, and a rename is planned from them. Bring them up to what was just
// written, or pressing Rename after Save would name the file after the tag it
// used to have. Cue tracks cannot take a write and never enter a rename plan, so
// they are left as they were. Returns how many were brought up to date.
function absorb(songs, tags, perFile, writable) {
    var list = songs || []
    var count = 0
    for (var i = 0; i < list.length; i++) {
        var song = list[i]
        if (typeof writable === "function" && writable(String(song.file)) === "") continue
        for (var k in tags) song[k] = tags[k]
        var own = perFile ? perFile[String(song.file)] : undefined
        if (own) for (var p in own) song[p] = own[p]
        count++
    }
    return count
}

// How a rename's own counts read after the tags landed.
function renameSummary(result) {
    var bits = []
    if (!result) return ""
    if (result.moved > 0) bits.push(result.moved + " renamed")
    if (result.skipped > 0) bits.push(result.skipped + " skipped")
    if (result.failed > 0) bits.push(result.failed + " failed")
    return bits.join(" · ")
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        pending: pending,
        summary: summary,
        failed: failed,
        failureStatus: failureStatus,
        agreed: agreed,
        absorb: absorb,
        renameSummary: renameSummary
    }
}
