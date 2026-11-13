#!/usr/bin/env node
// Exercises the tag-write argv and the country reader without a shell or MPD:
//   node extras/test-tag-frames.js
"use strict"

const assert = require("node:assert/strict")
const TagFrames = require("../TagFrames.js")

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
const mp3 = (tags) => TagFrames.command({ path: "/music/Band/01.mp3", tags: tags })
const flac = (tags) => TagFrames.command({ path: "/music/Band/01.flac", tags: tags })

// ---- ID3 ----

check("command: an MP3 text frame is written", () => {
    assert.deepEqual(mp3({ title: "Song" }),
        ["mid3v2", "--TIT2", "Song", "/music/Band/01.mp3"])
})

check("command: an empty MP3 frame is deleted, not written blank", () => {
    assert.deepEqual(mp3({ title: "" }),
        ["mid3v2", "--delete-frames=TIT2", "/music/Band/01.mp3"])
    assert.deepEqual(mp3({ title: "   " }),
        ["mid3v2", "--delete-frames=TIT2", "/music/Band/01.mp3"])
})

check("command: MP3 comment keeps the description/language slots", () => {
    assert.deepEqual(mp3({ comment: "hello" }),
        ["mid3v2", "--COMM", ":hello:eng", "/music/Band/01.mp3"])
})

check("command: a colon inside a comment is the value, not a separator", () => {
    assert.deepEqual(mp3({ comment: "a:b" }),
        ["mid3v2", "--COMM", ":a:b:eng", "/music/Band/01.mp3"])
})

check("command: an empty comment still writes the frame", () => {
    assert.deepEqual(mp3({ comment: "" }),
        ["mid3v2", "--COMM", "::eng", "/music/Band/01.mp3"])
})

check("command: country is addressed as a TXXX description", () => {
    assert.deepEqual(mp3({ country: "SE" }),
        ["mid3v2", "--TXXX", "MusicBrainz Album Release Country:SE", "/music/Band/01.mp3"])
})

check("command: clearing the country writes an empty TXXX", () => {
    assert.deepEqual(mp3({ country: "" }),
        ["mid3v2", "--TXXX", "MusicBrainz Album Release Country:", "/music/Band/01.mp3"])
})

check("command: several fields keep their order", () => {
    assert.deepEqual(mp3({ title: "Song", artist: "Band", track: "3" }),
        ["mid3v2", "--TIT2", "Song", "--TPE1", "Band", "--TRCK", "3",
         "/music/Band/01.mp3"])
})

check("command: a key no tagger here knows is ignored", () => {
    assert.equal(mp3({ bogus: "x" }), undefined)
})

check("command: unknown keys alongside known ones are skipped", () => {
    assert.deepEqual(mp3({ bogus: "x", title: "Song" }),
        ["mid3v2", "--TIT2", "Song", "/music/Band/01.mp3"])
})

// ---- Vorbis ----

check("command: a Vorbis field is removed before it is set", () => {
    assert.deepEqual(flac({ title: "Song" }),
        ["metaflac", "--remove-tag=TITLE", "--set-tag=TITLE=Song",
         "/music/Band/01.flac"])
})

check("command: clearing a Vorbis field removes without setting", () => {
    assert.deepEqual(flac({ title: "" }),
        ["metaflac", "--remove-tag=TITLE", "/music/Band/01.flac"])
})

check("command: a Vorbis comment is an ordinary field", () => {
    assert.deepEqual(flac({ comment: "hello" }),
        ["metaflac", "--remove-tag=COMMENT", "--set-tag=COMMENT=hello",
         "/music/Band/01.flac"])
})

check("command: both release-country spellings are written", () => {
    assert.deepEqual(flac({ country: "SE" }),
        ["metaflac",
         "--remove-tag=MUSICBRAINZ_ALBUMRELEASECOUNTRY",
         "--set-tag=MUSICBRAINZ_ALBUMRELEASECOUNTRY=SE",
         "--remove-tag=RELEASECOUNTRY",
         "--set-tag=RELEASECOUNTRY=SE",
         "/music/Band/01.flac"])
})

check("command: clearing the country removes every accepted spelling", () => {
    assert.deepEqual(flac({ country: "" }),
        ["metaflac",
         "--remove-tag=MUSICBRAINZ_ALBUMRELEASECOUNTRY",
         "--remove-tag=RELEASECOUNTRY",
         "/music/Band/01.flac"])
})

check("command: unset and null values count as empty", () => {
    assert.deepEqual(flac({ title: undefined, genre: null }),
        ["metaflac", "--remove-tag=TITLE", "--remove-tag=GENRE",
         "/music/Band/01.flac"])
})

check("command: values are trimmed and stringified", () => {
    assert.deepEqual(mp3({ title: "  Song  ", track: 3 }),
        ["mid3v2", "--TIT2", "Song", "--TRCK", "3", "/music/Band/01.mp3"])
})

// ---- format dispatch ----

check("command: only MP3 and FLAC are writable", () => {
    assert.equal(TagFrames.command({ path: "/music/a.ogg", tags: { title: "x" } }), null)
    assert.equal(TagFrames.command({ path: "/music/a.wav", tags: { title: "x" } }), null)
    assert.equal(TagFrames.command({ path: "", tags: { title: "x" } }), null)
    assert.equal(TagFrames.command(null), null)
})

check("command: the extension test ignores case", () => {
    assert.deepEqual(TagFrames.command({ path: "/music/A.MP3", tags: { title: "x" } }),
        ["mid3v2", "--TIT2", "x", "/music/A.MP3"])
    assert.deepEqual(TagFrames.command({ path: "/music/A.FLAC", tags: { title: "x" } }),
        ["metaflac", "--remove-tag=TITLE", "--set-tag=TITLE=x", "/music/A.FLAC"])
})

check("command: nothing to write and an empty tag map", () => {
    assert.equal(mp3({}), undefined)
    assert.equal(flac(undefined), undefined)
})

// ---- merge order ----

check("mergeTags: per-file values land first", () => {
    assert.deepEqual(TagFrames.mergeTags({ album: "A" }, { "a.mp3": { track: "2" } }, "a.mp3"),
        { track: "2", album: "A" })
})

check("mergeTags: a typed shared value beats the matched one", () => {
    assert.deepEqual(TagFrames.mergeTags({ track: "9" }, { "a.mp3": { track: "2" } }, "a.mp3"),
        { track: "9" })
})

check("mergeTags: another file's values do not leak in", () => {
    assert.deepEqual(TagFrames.mergeTags({ album: "A" }, { "b.mp3": { track: "2" } }, "a.mp3"),
        { album: "A" })
})

check("mergeTags: missing maps", () => {
    assert.deepEqual(TagFrames.mergeTags({ album: "A" }, null, "a.mp3"), { album: "A" })
    assert.deepEqual(TagFrames.mergeTags(undefined, undefined, "a.mp3"), {})
})

// ---- field names ----

check("vorbisFieldsFor: country accepts three spellings, writes two", () => {
    assert.deepEqual(TagFrames.vorbisFieldsFor("country"),
        ["MUSICBRAINZ_ALBUMRELEASECOUNTRY", "RELEASECOUNTRY"])
    assert.deepEqual(TagFrames.vorbisFieldsFor("title"), ["TITLE"])
    assert.deepEqual(TagFrames.vorbisFieldsFor("bogus"), [])
})

// ---- country reader ----

check("parseCountry: a Vorbis field", () => {
    assert.equal(TagFrames.parseCountry("TITLE=Song\nCOUNTRY=SE\n"), "SE")
    assert.equal(TagFrames.parseCountry("MUSICBRAINZ_ALBUMRELEASECOUNTRY=se\n"), "se")
})

check("parseCountry: the Picard words, squeezed", () => {
    assert.equal(TagFrames.parseCountry("MusicBrainz Album Release Country=SE\n"), "SE")
})

check("parseCountry: a TXXX line names its description", () => {
    assert.equal(TagFrames.parseCountry("TXXX=MusicBrainz Album Release Country=SE\n"), "SE")
    assert.equal(TagFrames.parseCountry("TXXX=COUNTRY=SE\n"), "SE")
})

check("parseCountry: an unrelated TXXX is not taken", () => {
    assert.equal(TagFrames.parseCountry("TXXX=iTunNORM=0000\nTXXX=MusicBrainz Album Release Country=SE\n"),
        "SE")
    assert.equal(TagFrames.parseCountry("TXXX=iTunNORM=0000\n"), "")
})

check("parseCountry: a TXXX without a value separator is skipped", () => {
    assert.equal(TagFrames.parseCountry("TXXX=MusicBrainz Album Release Country\n"), "")
})

check("parseCountry: an empty value does not end the search", () => {
    assert.equal(TagFrames.parseCountry("COUNTRY=\nRELEASECOUNTRY=NO\n"), "NO")
})

check("parseCountry: nothing found", () => {
    assert.equal(TagFrames.parseCountry("TITLE=Song\n"), "")
    assert.equal(TagFrames.parseCountry(""), "")
    assert.equal(TagFrames.parseCountry(undefined), "")
    assert.equal(TagFrames.parseCountry("no equals sign here\n"), "")
})

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
