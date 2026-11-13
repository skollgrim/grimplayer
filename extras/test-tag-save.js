#!/usr/bin/env node
// Exercises the tag editor's save decisions without a shell, a tagger or a file:
//   node extras/test-tag-save.js
"use strict"

const assert = require("node:assert/strict")
const TagSave = require("../TagSave.js")

let failed = 0
function check(name, fn) {
    try {
        fn()
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     " + String(err.message).replace(/\n/g, "\n     "))
    }
}

const FIELDS = ["title", "artist", "albumArtist", "album", "track", "disc",
                "date", "genre", "comment", "country"].map((key) => ({ key }))

const state = (over) => Object.assign({
    fields: FIELDS,
    touched: {},
    draft: {},
    perFileDraft: {},
    coverAction: "",
    coverPath: "",
    renamePending: false,
    renameItems: [],
    songs: [{ file: "Band/01.flac" }]
}, over)

// ---- what the drafts add up to ----

check("pending: an untouched editor has nothing to do", () => {
    assert.equal(TagSave.pending(state()), null)
})

check("pending: a touched field is written, trimmed", () => {
    const edit = TagSave.pending(state({
        touched: { title: true }, draft: { title: "  Song  " }
    }))
    assert.deepEqual(edit.tags, { title: "Song" })
    assert.equal(edit.writing, true)
    assert.equal(edit.status, "Writing…")
})

check("pending: an emptied field is written as empty, not skipped", () => {
    const edit = TagSave.pending(state({ touched: { genre: true }, draft: { genre: "" } }))
    assert.deepEqual(edit.tags, { genre: "" })
    assert.equal(edit.writing, true)
})

check("pending: an untouched draft value is not written", () => {
    const edit = TagSave.pending(state({ touched: { title: true }, draft: { title: "A", genre: "Rock" } }))
    assert.deepEqual(edit.tags, { title: "A" })
})

check("pending: a draft with no entry for a touched field writes empty", () => {
    const edit = TagSave.pending(state({ touched: { comment: true }, draft: {} }))
    assert.deepEqual(edit.tags, { comment: "" })
})

check("pending: per-file values make the edit a write on their own", () => {
    const edit = TagSave.pending(state({
        perFileDraft: { "Band/01.flac": { title: "One", track: "1" } }
    }))
    assert.equal(edit.hasPerFile, true)
    assert.equal(edit.writing, true)
    assert.equal(Object.keys(edit.tags).length, 0)
})

check("pending: a per-file map with no files in it is not an edit", () => {
    assert.equal(TagSave.pending(state({ perFileDraft: {} })), null)
})

// ---- the cover ----

check("pending: a chosen cover is carried", () => {
    const edit = TagSave.pending(state({ coverAction: "set", coverPath: "/tmp/a.jpg" }))
    assert.equal(edit.cover, "set")
    assert.equal(edit.coverPath, "/tmp/a.jpg")
    assert.equal(edit.writing, false)
    assert.equal(edit.status, "Writing…")
})

check("pending: 'set' with no path chosen is not an edit", () => {
    assert.equal(TagSave.pending(state({ coverAction: "set", coverPath: "" })), null)
})

check("pending: removing a cover needs no path", () => {
    const edit = TagSave.pending(state({ coverAction: "remove" }))
    assert.equal(edit.cover, "remove")
    assert.equal(edit.writing, false)
})

check("pending: the cover path is captured now, not at callback time", () => {
    const s = state({ coverAction: "set", coverPath: "/tmp/a.jpg" })
    const edit = TagSave.pending(s)
    s.coverPath = ""
    assert.equal(edit.coverPath, "/tmp/a.jpg")
})

// ---- renaming ----

check("pending: rename-only reads as renaming, not writing", () => {
    const edit = TagSave.pending(state({
        renamePending: true, renameItems: [{ from: "a", to: "b" }]
    }))
    assert.equal(edit.renaming, true)
    assert.equal(edit.writing, false)
    assert.equal(edit.status, "Renaming…")
})

check("pending: a planned rename with nothing in it is not an edit", () => {
    assert.equal(TagSave.pending(state({ renamePending: true, renameItems: [] })), null)
})

check("pending: an unplanned rename does not count", () => {
    assert.equal(TagSave.pending(state({ renameItems: [{ from: "a", to: "b" }] })), null)
})

check("pending: tags made alongside a rename still read as writing", () => {
    const edit = TagSave.pending(state({
        touched: { title: true }, draft: { title: "A" },
        renamePending: true, renameItems: [{ from: "a", to: "b" }]
    }))
    assert.equal(edit.status, "Writing…")
    assert.equal(edit.renaming, true)
})

check("pending: the songs are snapshotted, not aliased", () => {
    const s = state({ touched: { title: true }, draft: { title: "A" } })
    const edit = TagSave.pending(s)
    s.songs.push({ file: "Band/02.flac" })
    assert.equal(edit.songs.length, 1)
})

// ---- what the result says ----

check("summary: the plain cases", () => {
    assert.equal(TagSave.summary({ written: 3, failed: 0, skipped: 0 }, null, ""), "3 updated")
    assert.equal(TagSave.summary({ written: 0, failed: 2, skipped: 0 }, null, ""), "2 failed")
    assert.equal(TagSave.summary({ written: 0, failed: 0, skipped: 1 }, null, ""), "1 skipped")
})

check("summary: counts keep their order", () => {
    assert.equal(TagSave.summary({ written: 3, failed: 1, skipped: 2 }, null, ""),
        "3 updated · 1 failed · 2 skipped")
})

check("summary: a cover that landed names what happened to it", () => {
    assert.equal(TagSave.summary(null, { changed: true, failed: 0, skipped: 0 }, "set"),
        "cover set")
    assert.equal(TagSave.summary(null, { changed: true, failed: 0, skipped: 0 }, "remove"),
        "cover removed")
})

check("summary: an unchanged cover says nothing", () => {
    assert.equal(TagSave.summary(null, { changed: false, failed: 0, skipped: 0 }, "set"), "")
})

check("summary: a skipped cover is reported, not claimed", () => {
    assert.equal(TagSave.summary(null, { changed: false, failed: 0, skipped: 2 }, "set"),
        "2 skipped")
    // Both counts can be real at once in a mixed selection.
    assert.equal(TagSave.summary({ written: 1, failed: 0, skipped: 0 },
        { changed: true, failed: 0, skipped: 2 }, "set"), "1 updated · cover set · 2 skipped")
})

check("summary: a failed cover is named as such, not as changed", () => {
    assert.equal(TagSave.summary(null, { changed: false, failed: 1, skipped: 0 }, "set"),
        "cover failed")
})

check("summary: nothing to say", () => {
    assert.equal(TagSave.summary(null, null, ""), "")
    assert.equal(TagSave.summary({ written: 0, failed: 0, skipped: 0 }, null, ""), "")
})

check("failed: either half failing counts", () => {
    assert.equal(TagSave.failed(null, null), false)
    assert.equal(TagSave.failed({ failed: 0 }, { failed: 0 }), false)
    assert.equal(TagSave.failed({ failed: 1 }, null), true)
    assert.equal(TagSave.failed(null, { failed: 1 }), true)
})

// ---- the failure line ----

check("failureStatus: the counts, then the instruction", () => {
    assert.equal(TagSave.failureStatus({ written: 2, failed: 1, skipped: 0 }, null, "", false),
        "2 updated · 1 failed — press Save to retry")
})

check("failureStatus: a failure with no counts still says something", () => {
    assert.equal(TagSave.failureStatus(null, null, "", false),
        "Nothing changed — press Save to retry")
})

check("failureStatus: a dropped rename says the name did not change", () => {
    assert.equal(TagSave.failureStatus({ failed: 1, written: 0, skipped: 0 }, null, "", true),
        "1 failed — press Save to retry — name unchanged")
})

// ---- what the fields show afterwards ----

check("agreed: a written value lands in the field", () => {
    const out = TagSave.agreed(FIELDS, { title: "A" }, false, { title: "old", genre: "Rock" })
    assert.equal(out.title, "A")
    assert.equal(out.genre, "Rock")
})

check("agreed: per-track fields read as multiple again", () => {
    const out = TagSave.agreed(FIELDS, { album: "A" }, true, { album: "old", title: "old" })
    assert.equal(out.title, null)
    assert.equal(out.track, null)
    assert.equal(out.disc, null)
    // A shared field the user typed still shows what was written.
    assert.equal(out.album, "A")
})

check("agreed: per-file values only blank the fields they own", () => {
    const out = TagSave.agreed(FIELDS, { genre: "Rock" }, true, { genre: "old", artist: "Band" })
    assert.equal(out.genre, "Rock")
    assert.equal(out.artist, "Band")
})

// ---- bringing the selection up to date ----

check("absorb: written values land on the selection's own objects", () => {
    const songs = [{ file: "Band/01.flac", title: "old" }]
    const n = TagSave.absorb(songs, { title: "A", album: "X" }, {}, () => "/music/01.flac")
    assert.equal(n, 1)
    assert.deepEqual(songs[0], { file: "Band/01.flac", title: "A", album: "X" })
})

check("absorb: a per-file value beats the shared one for its own file", () => {
    const songs = [{ file: "Band/01.flac" }]
    TagSave.absorb(songs, { album: "X" }, { "Band/01.flac": { title: "One" } }, () => "/music/01.flac")
    assert.deepEqual(songs[0], { file: "Band/01.flac", album: "X", title: "One" })
})

check("absorb: cue tracks cannot be written and are left alone", () => {
    const songs = [{ file: "Band/Album.cue/track01", title: "old" }]
    const n = TagSave.absorb(songs, { title: "A" }, {}, (file) => file.indexOf(".cue/") < 0 ? "/x" : "")
    assert.equal(n, 0)
    assert.equal(songs[0].title, "old")
})

check("absorb: another album's per-file values do not leak in", () => {
    const songs = [{ file: "Band/01.flac" }]
    TagSave.absorb(songs, {}, { "Band/02.flac": { title: "Two" } }, () => "/music/01.flac")
    assert.equal(songs[0].title, undefined)
})

// ---- the rename's own counts ----

check("renameSummary: moved, skipped and failed", () => {
    assert.equal(TagSave.renameSummary({ moved: 2, skipped: 0, failed: 0 }), "2 renamed")
    assert.equal(TagSave.renameSummary({ moved: 2, skipped: 1, failed: 1 }),
        "2 renamed · 1 skipped · 1 failed")
    assert.equal(TagSave.renameSummary({ moved: 0, skipped: 0, failed: 0 }), "")
    assert.equal(TagSave.renameSummary(null), "")
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
