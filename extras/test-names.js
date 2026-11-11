#!/usr/bin/env node
// Exercises the tag editor's filename arithmetic without a running shell:
//   node extras/test-names.js
"use strict"

const assert = require("node:assert/strict")
const Names = require("../Names.js")

const passes = [
    // Names the library actually holds, so the rules are tested on what they
    // were written for rather than on tidy examples.
    ["01 - Kill It in the Morning Live in Antwerp 23.11.22.mp3",
        { track: "1", disc: "", title: "Kill It in the Morning Live in Antwerp 23.11.22" }],
    ["02. Shooting Dennis Hopper Shooting.flac",
        { track: "2", disc: "", title: "Shooting Dennis Hopper Shooting" }],
    ["01. [10 Good Reasons for Modern Drugs].flac",
        { track: "1", disc: "", title: "[10 Good Reasons for Modern Drugs]" }],
    ["04 - VTr.flac", { track: "4", disc: "", title: "VTr" }],
    ["The Twilight Sad - Live 2023 EP 1 - 01 That Summer, At Home.mp3",
        { track: "1", disc: "", title: "That Summer, At Home" }],
    ["The Twilight Sad - Stripped Back - 07 It Never Was the Same.mp3",
        { track: "7", disc: "", title: "It Never Was the Same" }],
    // Disc and track together.
    ["1-02 - Title.flac", { track: "2", disc: "1", title: "Title" }],
    ["1.02 Title.flac", { track: "2", disc: "1", title: "Title" }],
    ["2.03. Last Song.flac", { track: "3", disc: "2", title: "Last Song" }],
    // Numberless names.
    ["Song Name.flac", { track: "", disc: "", title: "Song Name" }],
    ["01.flac", { track: "1", disc: "", title: "" }],
    ["Épilogue.flac", { track: "", disc: "", title: "Épilogue" }],
    // Titles that contain the separator, and numbers that are part of a title.
    ["01 - Title - Part 2.mp3", { track: "1", disc: "", title: "Title - Part 2" }],
    ["01 - 10 Good Reasons for Modern Drugs.mp3",
        { track: "1", disc: "", title: "10 Good Reasons for Modern Drugs" }],
    // Nothing certain to read: an artist prefix is not a number and not a title.
    ["Crowbar - Odd Fellows Rest.flac", { track: "", disc: "", title: "" }],
    ["Artist - Title.flac", { track: "", disc: "", title: "" }],
    // A year is not a track: the track is capped at three digits, so this is an
    // ambiguous dashed name rather than track 2001.
    ["2001 - A Space Odyssey.flac", { track: "", disc: "", title: "" }]
]

let failed = 0
function check(name, actual, expected) {
    try {
        assert.deepEqual(actual, expected)
        console.log("ok   " + name)
    } catch (err) {
        failed++
        console.log("FAIL " + name + "\n     expected: " + JSON.stringify(expected)
            + "\n     actual:   " + JSON.stringify(actual))
    }
}

for (const [name, expected] of passes) {
    const p = Names.parse(name)
    check("parse " + name, { track: p.track, disc: p.disc, title: p.title }, expected)
}

// A path, not just a name: only the last component is read.
check("parse takes the basename of a path",
    Names.parse("The Twilight Sad/2019 - Album [24.44 FLAC]/06. I m Not Here [Missing Face].flac"),
    { title: "I m Not Here [Missing Face]", track: "6", disc: "", ext: ".flac" })

const builds = [
    ["build pads the track", Names.build("1", "Kill It in the Morning", ".mp3"),
        "01 - Kill It in the Morning.mp3"],
    ["build keeps two digits", Names.build("2", "Title", ".flac"), "02 - Title.flac"],
    ["build keeps three-digit tracks", Names.build("101", "Title", ".flac"), "101 - Title.flac"],
    ["build honours a wider album width", Names.build("1", "Title", ".flac", { trackWidth: 3 }),
        "001 - Title.flac"],
    ["build without a track drops the prefix", Names.build("", "Crowbar - Odd Fellows Rest", ".flac"),
        "Crowbar - Odd Fellows Rest.flac"],
    ["build without an extension", Names.build("1", "Title", ""), "01 - Title"],
    ["build replaces a slash", Names.build("1", "AC/DC", ""), "01 - AC-DC"],
    ["build collapses whitespace", Names.build("1", "  Spaced   Out  ", ""), "01 - Spaced Out"],
    ["build refuses an empty title", Names.build("1", "   ", ""), ""],
    ["build refuses a dot title", Names.build("1", "..", ""), ""],
    ["build ignores a non-numeric track", Names.build("A1", "Title", ""), "Title"]
]

for (const [name, actual, expected] of builds) check(name, actual, expected)

// The two directions agree for a name already in the canonical shape, and an
// artist/album prefix or a dotted separator is normalized by the build.
for (const name of ["01 - Title.mp3", "101 - Long Album.flac"]) {
    const p = Names.parse(name)
    check("round trip " + name, Names.build(p.track, p.title, p.ext), name)
}
{
    const p = Names.parse("07. Auge Maschine.flac")
    check("round trip normalizes the dotted separator",
        Names.build(p.track, p.title, p.ext), "07 - Auge Maschine.flac")
}
{
    const p = Names.parse("The Twilight Sad - Live 2023 EP 1 - 01 That Summer.mp3")
    check("round trip drops the artist prefix",
        Names.build(p.track, p.title, p.ext), "01 - That Summer.mp3")
}

// An extensionless name whose title has a dot is not split at that dot.
check("parse does not mistake a title dot for an extension",
    Names.parse("Mr. Brightside"), { title: "Mr. Brightside", track: "", disc: "", ext: "" })

if (failed > 0) {
    console.log("\n" + failed + " failed")
    process.exit(1)
}
console.log("\nall passed")
