import QtQuick
import QtTest
import "../../" as Plugin

// Guards the settings schema itself, now that a row is a key plus a list of
// rungs rather than a pair of closures.
//
// The three things this catches are the ones that fail silently: a key with no
// store property behind it (the row would never read or write anything), an
// option whose type does not match the property (applyStored drops it, so the
// setting looks changeable but never survives a restart), and a section tag that
// names no column (the row would be in the table and on no tab).
//
// It runs against the real GrimPlayerConfig.qml with the stub FileView, so the
// user's own settings.json is neither read nor written.
TestCase {
    id: test
    name: "SettingsSchema"

    Plugin.GrimPlayerConfig { id: config }

    // Every test starts from the code defaults, which is also the state the
    // captured codeDefaults describe.
    function init() {
        config.reset()
    }

    function entryFor(key) {
        for (var i = 0; i < config.entries.length; i++) {
            if (config.entries[i].key === key) return config.entries[i]
        }
        return null
    }

    function test_every_row_names_a_store_property() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            verify(config.valueFor(e) !== undefined,
                "no stored value behind the row " + e.key)
            verify(config.codeDefaults[e.key] !== undefined,
                "no captured default for the row " + e.key)
        }
        // The store may hold values with no row (the repeat and shuffle modes),
        // but never the other way round: a resolved default per row, and no
        // entry left without one.
        compare(Object.keys(config.codeDefaults).length, config.entries.length)
    }

    function test_keys_are_unique() {
        var seen = {}
        for (var i = 0; i < config.entries.length; i++) {
            var key = config.entries[i].key
            verify(!seen[key], "the row " + key + " appears twice")
            seen[key] = true
        }
    }

    function test_every_row_offers_options() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            verify(e.options && e.options.length > 0, e.key + " has no options")
            verify(e.label && e.label.length > 0, e.key + " has no label")
            verify(e.hint && e.hint.length > 0, e.key + " has no hint")
        }
    }

    // applyStored accepts a stored value only when its type matches the current
    // one, so an option of the wrong type would make that row forget itself on
    // the next start.
    function test_option_types_match_their_property() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            var current = config.valueFor(e)
            for (var o = 0; o < e.options.length; o++) {
                compare(typeof e.options[o], typeof current,
                    e.key + " offers " + JSON.stringify(e.options[o])
                        + " against a " + typeof current)
            }
        }
    }

    // A file the card wrote must always be able to load back, which is only true
    // while the resting value is one of the rungs on offer.
    function test_every_default_is_an_offered_option() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            verify(e.options.indexOf(config.codeDefaults[e.key]) >= 0,
                e.key + " rests at " + config.codeDefaults[e.key]
                    + ", which it does not offer")
        }
    }

    function test_every_row_lands_in_a_column() {
        var tags = []
        for (var s = 0; s < config.sections.length; s++) tags.push(config.sections[s].tag)
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            verify(tags.indexOf(e.section) >= 0,
                e.key + " names the section " + e.section + ", which is not a column")
        }
    }

    function test_reset_restores_the_captured_defaults() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            var moved = e.options[(e.options.indexOf(config.valueFor(e)) + 1) % e.options.length]
            config.assign(e, moved)
        }
        config.reset()
        for (var j = 0; j < config.entries.length; j++) {
            var row = config.entries[j]
            compare(config.valueFor(row), config.codeDefaults[row.key],
                row.key + " did not come back to its default")
        }
    }

    function test_cycle_steps_and_wraps() {
        var e = entryFor("seekThickness")
        // resting at 9 in [3, 5, 7, 9, 11, 13, 15]
        config.cycle(e, 1)
        compare(config.seekThickness, 11)
        config.cycle(e, -1)
        compare(config.seekThickness, 9)
        // From the first rung, a step back lands on the last.
        config.assign(e, 3)
        config.cycle(e, -1)
        compare(config.seekThickness, 15)
    }

    // A hand-edited or older file can hold a value the row does not offer. The
    // first step must land on a real option, whichever way it went: the bare
    // arithmetic wraps -1 past the end and would land second-to-last.
    function test_a_stale_value_steps_to_the_first_option() {
        var e = entryFor("seekThickness")
        config.assign(e, 4)
        config.cycle(e, -1)
        compare(config.seekThickness, 3)
        config.assign(e, 4)
        config.cycle(e, 1)
        compare(config.seekThickness, 3)
    }

    function test_an_inactive_row_refuses_to_change() {
        var mode = entryFor("coverBandMode")
        var align = entryFor("coverBandAlign")
        config.assign(mode, "off")
        verify(!config.isActive(align), "the position row should wait on the mode")
        var before = config.valueFor(align)
        config.cycle(align, 1)
        compare(config.valueFor(align), before)
        // Kept rather than discarded: switching the parent back on restores it.
        config.assign(mode, "auto")
        compare(config.valueFor(align), before)
        verify(config.isActive(align))
    }

    // The one row that moves a second property, and the reason assign() has an
    // override: pinning the placement picks the artwork size that suits it.
    function test_pinning_the_cover_moves_the_artwork_size() {
        var mode = entryFor("coverBandMode")
        config.assign(mode, "on")
        compare(config.coverScale, 100)
        config.assign(mode, "off")
        compare(config.coverScale, 30)
        config.assign(mode, "auto")
    }

    function test_a_stored_file_is_validated_on_load() {
        // Unknown keys are ignored, a wrong type is dropped, and a value outside
        // the row's rungs is dropped rather than clamped.
        config.applyStored({
            seekThickness: 7,
            rowSpacing: "huge",
            coverBandMode: "elsewhere",
            noSuchSetting: 1
        })
        compare(config.seekThickness, 7)
        compare(config.rowSpacing, config.codeDefaults.rowSpacing)
        compare(config.coverBandMode, config.codeDefaults.coverBandMode)
    }
}
