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
// matches no section (the row would be in the table and on no tab).
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

    function test_every_row_offers_options_or_is_free_text() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            verify((e.options && e.options.length > 0) || config.isText(e),
                e.key + " has no options and is not a text row")
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
            if (config.isText(e)) continue
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
            var value = config.codeDefaults[e.key]
            if (config.isText(e)) {
                compare(typeof value, "string", e.key + " does not rest at a string")
                compare(value.charAt(0), "/", e.key + " does not rest at an absolute path")
                continue
            }
            verify(e.options.indexOf(value) >= 0,
                e.key + " rests at " + value
                    + ", which it does not offer")
        }
    }

    function test_every_row_lands_in_a_tab() {
        var tags = []
        for (var s = 0; s < config.sections.length; s++) tags.push(config.sections[s].tag)
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            verify(tags.indexOf(e.section) >= 0,
                e.key + " names the section " + e.section + ", which matches no section")
        }
    }

    // The tabs promise a home for every setting. Pin both the order and the
    // rows whose place is easiest to drift: the folder and keys in General, the
    // strip in Now playing, the browser in Library view, the shared captions in
    // Album view.
    function test_tabs_group_settings_by_subject() {
        var order = ["general", "nowPlaying", "artwork", "lyrics",
            "library", "album", "lyricsView", "karaoke"]
        var names = ["General", "Now playing", "Artwork", "Lyrics", "Library view",
            "Album view", "Lyrics view", "Karaoke view"]
        compare(config.sections.length, order.length)
        for (var s = 0; s < order.length; s++) {
            compare(config.sections[s].tag, order[s])
            compare(config.sections[s].name, names[s])
        }

        var homes = {
            musicDir: "general", keyboardStyle: "general", findPlace: "general",
            findScale: "general", uiScale: "general", wrapAround: "library",
            playingMarker: "library", fontSubtitle: "library", albumYears: "library",
            seekThickness: "nowPlaying", iconSize: "nowPlaying", fontTitle: "nowPlaying",
            fontBody: "nowPlaying", noticeScale: "nowPlaying", fontCaption: "album",
            albumFont: "album", albumTrackSpacing: "album"
        }
        for (var key in homes) {
            var e = entryFor(key)
            verify(e !== null, "the row " + key + " is missing")
            compare(e.section, homes[key], key + " drifted out of its tab")
        }
    }

    function test_reset_restores_the_captured_defaults() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            if (config.isText(e)) {
                config.assign(e, "/tmp/somewhere-else")
                continue
            }
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

    // Up/down must step over a greyed dependent in both directions, and once its
    // parent is back on, the dependent is the very next row down.
    function test_row_movement_skips_greyed_rows() {
        var mode = entryFor("coverBandMode")
        var align = entryFor("coverBandAlign")
        var row = config.rowOf(config.visibleEntries.indexOf(align))
        config.assign(mode, "off")
        var next = config.activeIndexNear(2, row, 1)
        var prev = config.activeIndexNear(2, row, -1)
        verify(next >= 0 && config.isActive(config.visibleEntries[next]))
        verify(prev >= 0 && config.isActive(config.visibleEntries[prev]))
        config.assign(mode, "auto")
        compare(config.activeIndexNear(2,
            config.rowOf(config.visibleEntries.indexOf(mode)), 1),
            config.visibleEntries.indexOf(align))
    }

    // A tab's remembered row can go grey while the caret is away. Crossing back
    // must land on the next live row, never on the greyed one that refuses keys.
    function test_crossing_tabs_skips_inactive_rows() {
        var mode = entryFor("coverBandMode")
        var align = entryFor("coverBandAlign")
        var row = config.rowOf(config.visibleEntries.indexOf(align))
        config.assign(mode, "off")
        verify(!config.isActive(align))
        var target = config.activeIndexAt(2, row)
        verify(target >= 0, "the artwork tab should still have a live row")
        verify(config.isActive(config.visibleEntries[target]),
            "the caret landed on a greyed row")
        config.assign(mode, "auto")
        compare(config.activeIndexAt(2, row), config.visibleEntries.indexOf(align))
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

    // The old album-alignment key seeded the new track-alignment key, so a file
    // written before the split keeps the title alignment it chose. An explicit
    // trackAlign always wins over a stale albumAlign.
    function test_the_old_album_alignment_migrates_to_track_alignment() {
        config.reset()
        compare(config.trackAlign, config.codeDefaults.trackAlign)
        config.applyStored({ albumAlign: "left" })
        compare(config.trackAlign, "left")
        config.reset()
        config.applyStored({ albumAlign: "left", trackAlign: "center" })
        compare(config.trackAlign, "center")
    }

    // The album caption was a switch before it became a choice about which
    // pieces of metadata to show. A file that chose on keeps the full caption;
    // one that chose off still shows none. An explicit albumInfo wins.
    function test_the_old_album_caption_migrates_to_album_info() {
        config.reset()
        compare(config.albumInfo, config.codeDefaults.albumInfo)
        config.applyStored({ albumCaption: true })
        compare(config.albumInfo, "full")
        config.reset()
        config.applyStored({ albumCaption: false })
        compare(config.albumInfo, "off")
        config.reset()
        config.applyStored({ albumCaption: false, albumInfo: "artist" })
        compare(config.albumInfo, "artist")
    }

    // The playing tint lost its switch; the row that remains only picks the
    // accent bar. A file written before the split keeps its choice of sides.
    function test_the_playing_marker_migrates_and_the_tint_is_always_on() {
        var e = entryFor("playingMarker")
        verify(e !== null, "the playing marker row should exist")
        verify(entryFor("playingHighlight") === null, "the tint switch should be gone")
        compare(e.label, "Playing marker")
        config.reset()
        config.applyStored({ playingMarkerSides: "both" })
        compare(config.playingMarker, "both")
        config.reset()
        config.applyStored({ playingMarkerSides: "left", playingMarker: "right" })
        compare(config.playingMarker, "right", "an explicit new key wins")
    }

    // Vim keys and type-to-find were two switches over the same letter keys, so
    // a stored file is folded into one choice. Vim wins when both were on; with
    // both off the letters stay inert. An explicit new key always wins.
    function test_keyboard_style_migrates_from_the_two_switches() {
        var e = entryFor("keyboardStyle")
        verify(e !== null, "the keyboard style row should exist")
        verify(entryFor("vimKeys") === null, "the vim switch should be gone")
        verify(entryFor("typeaheadSearch") === null, "the find switch should be gone")
        compare(e.options[0], "find")
        config.reset()
        config.applyStored({ vimKeys: true, typeaheadSearch: true })
        compare(config.keyboardStyle, "vim")
        config.reset()
        config.applyStored({ vimKeys: false, typeaheadSearch: false })
        compare(config.keyboardStyle, "off")
        config.reset()
        config.applyStored({ vimKeys: true, typeaheadSearch: false })
        compare(config.keyboardStyle, "vim")
        config.reset()
        config.applyStored({ vimKeys: false, typeaheadSearch: true })
        compare(config.keyboardStyle, "find")
        config.reset()
        config.applyStored({ keyboardStyle: "off", vimKeys: true })
        compare(config.keyboardStyle, "off", "an explicit new key wins")
    }

    // The find readout's position and size moved with their setting's rename.
    // The old corner placement folds into the bottom band, which replaced it.
    function test_find_readout_settings_migrate_with_their_names() {
        var place = entryFor("findPlace")
        var scale = entryFor("findScale")
        verify(place !== null && scale !== null, "the renamed find rows should exist")
        compare(place.label, "Find position")
        compare(scale.label, "Find size")
        config.reset()
        config.applyStored({ typeaheadPlace: "center", typeaheadScale: 9 })
        compare(config.findPlace, "center")
        compare(config.findScale, 9)
        config.reset()
        config.applyStored({ typeaheadPlace: "corner", typeaheadScale: 3,
                             findPlace: "bottom", findScale: 4 })
        compare(config.findPlace, "bottom", "an explicit new key wins")
        compare(config.findScale, 4, "an explicit new key wins")
    }

    // Position and size describe the find readout, so they only count as live
    // while the find style is selected.
    function test_find_rows_wait_on_the_find_style() {
        var style = entryFor("keyboardStyle")
        var place = entryFor("findPlace")
        config.assign(style, "vim")
        verify(!config.isActive(place), "find position should be greyed out in Vim style")
        config.assign(style, "off")
        verify(!config.isActive(place), "find position should be greyed out when letters are off")
        config.assign(style, "find")
        verify(config.isActive(place), "find position should come back in Find style")
    }

    // Highlighting is the primary word setting, so it belongs with the rest of
    // the words and is named for what it does; following is only a value of it.
    function test_highlight_lives_with_the_words() {
        var e = entryFor("lyricsFollow")
        compare(e.section, "lyrics")
        compare(e.label, "Highlight")
        compare(e.options[0], "follow")
        verify(config.textOf(e).indexOf("Highlight") === 0,
            "the value should read as a kind of highlight")
    }

    // Karaoke lines the words up on its own setting, so the reading view's choice
    // cannot move a view meant to be read from across the room.
    function test_karaoke_has_its_own_alignment() {
        var e = entryFor("karaokeAlign")
        compare(e.section, "karaoke")
        compare(config.codeDefaults.karaokeAlign, "center")
        verify(e.options.indexOf("left") >= 0 && e.options.indexOf("center") >= 0)
    }

    // The music folder is the one free-text row. Its value survives a load only
    // when it can be a real root: absolute, with ~ expanded and a trailing slash
    // dropped; a relative path is refused so it cannot point the tag editor at a
    // folder that is not the library.
    function test_the_music_folder_is_free_text_and_validated() {
        var e = entryFor("musicDir")
        verify(config.isText(e), "the music folder should be a text row")
        verify(!config.isSlider(e), "the music folder is not a slider")

        config.applyStored({ musicDir: "/srv/music/" })
        compare(config.musicDir, "/srv/music")

        config.applyStored({ musicDir: "relative/music" })
        compare(config.musicDir, "/srv/music", "a relative path must not replace a good one")

        config.applyStored({ musicDir: 42 })
        compare(config.musicDir, "/srv/music", "a non-string must not replace a good one")
    }

    function test_editing_a_text_row_commits_only_on_accept() {
        var e = entryFor("musicDir")
        config.assign(e, "/srv/music")
        config.beginTextEdit(e)
        config.textKeyStroke("x")
        compare(config.textEditDraft, "x", "the first keystroke replaces the value")
        config.textBackspace()
        compare(config.textEditDraft, "")
        config.textKeyStroke("/")
        config.textKeyStroke("l")
        config.textKeyStroke("i")
        config.textKeyStroke("b")
        compare(config.displayText(e), "/lib")
        compare(config.musicDir, "/srv/music", "the store waits for acceptance")
        config.endTextEdit(false)
        compare(config.musicDir, "/srv/music", "Esc leaves the stored value alone")
        compare(config.displayText(e), "/srv/music")

        config.beginTextEdit(e)
        config.textKeyStroke("/")
        config.textKeyStroke("n")
        config.textKeyStroke("e")
        config.textKeyStroke("w")
        config.endTextEdit(true)
        compare(config.musicDir, "/new")
    }

    // MPD reports its own music_directory, which is the folder every path it
    // serves is relative to -- a better default than the XDG guess. It may only
    // stand in while nothing has ever been saved; after that the setting wins.
    function test_the_mpd_hint_is_adopted_once() {
        config.reset()
        compare(config.musicDirSaved, false, "a fresh config should not be saved yet")
        compare(config.adoptMusicDir("/srv/from-mpd"), true)
        compare(config.musicDir, "/srv/from-mpd")
        compare(config.musicDirSaved, true)
        // A later hint must not move a library that is now an explicit setting.
        compare(config.adoptMusicDir("/elsewhere"), false)
        compare(config.musicDir, "/srv/from-mpd")
    }

    function test_the_mpd_hint_is_validated() {
        config.reset()
        compare(config.adoptMusicDir("relative/music"), false)
        compare(config.musicDir, config.codeDefaults.musicDir)
        compare(config.musicDirSaved, false, "a refused hint settles nothing")
    }

    function test_a_stored_folder_beats_the_mpd_hint() {
        config.reset()
        config.applyStored({ musicDir: "/mine" })
        compare(config.musicDirSaved, true)
        compare(config.adoptMusicDir("/srv/from-mpd"), false)
        compare(config.musicDir, "/mine")
    }

    function test_resetting_the_folder_lets_the_hint_back_in() {
        config.applyStored({ musicDir: "/mine" })
        config.resetEntry(entryFor("musicDir"))
        compare(config.musicDir, config.codeDefaults.musicDir)
        compare(config.musicDirSaved, false)
        compare(config.adoptMusicDir("/srv/from-mpd"), true)
        compare(config.musicDir, "/srv/from-mpd")
    }
}
