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
        var valued = 0
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            // An action row is fired rather than stored, so it has neither.
            if (config.isAction(e)) continue
            valued++
            verify(config.valueFor(e) !== undefined,
                "no stored value behind the row " + e.key)
            verify(config.codeDefaults[e.key] !== undefined,
                "no captured default for the row " + e.key)
        }
        // The store may hold values with no row (the repeat and shuffle modes),
        // but never the other way round: a resolved default per value row, and
        // no entry left without one.
        compare(Object.keys(config.codeDefaults).length, valued)
    }

    function test_action_rows_fire_without_holding_a_value() {
        var e = entryFor("rescanLibrary")
        verify(e !== null, "the rescan action should exist")
        verify(config.isAction(e), "rescan should be an action row")
        verify(config.valueFor(e) === undefined, "an action holds no stored value")
        verify(config.codeDefaults.rescanLibrary === undefined,
            "an action has no captured default")

        var fired = ""
        var firedKey = ""
        config.actionTriggered.connect(function (action, entry) {
            fired = action
            firedKey = entry.key
        })
        config.assign(e, "anything")
        config.triggerAction(e)
        compare(fired, "rescanLibrary")
        compare(firedKey, "rescanLibrary")
        // A value row must stay a value row: it does not fire the action signal.
        fired = ""
        config.triggerAction(entryFor("musicDir"))
        compare(fired, "")
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
            verify((e.options && e.options.length > 0)
                    || config.isText(e) || config.isAction(e),
                e.key + " has no options and is not a text or action row")
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
            if (config.isText(e) || config.isAction(e)) continue
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
            if (config.isAction(e)) continue
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
    // strip in Now playing, the browser in Library view, the info text in
    // Album view.
    function test_tabs_group_settings_by_subject() {
        var order = ["general", "nowPlaying", "artwork", "lyrics",
            "library", "album", "karaoke", "lyricsView"]
        var names = ["General", "Now playing", "Artwork", "Lyrics", "Library view",
            "Album view", "Karaoke view", "Lyrics view"]
        compare(config.sections.length, order.length)
        for (var s = 0; s < order.length; s++) {
            compare(config.sections[s].tag, order[s])
            compare(config.sections[s].name, names[s])
        }

        var homes = {
            musicDir: "general", keyboardStyle: "general", findPlace: "general",
            findScale: "general", uiScale: "general", settingsOpacity: "general",
            adaptiveColors: "general", fetchCovers: "general", lyricsDownloads: "general",
            wrapAround: "general", playingMarker: "library",
            fontSubtitle: "library", albumYears: "library",
            seekThickness: "nowPlaying", stripTopGap: "nowPlaying",
            iconSize: "nowPlaying", fontTitle: "nowPlaying",
            fontBody: "nowPlaying", stripSeparator: "nowPlaying", stripSeekEdge: "nowPlaying",
            progressInline: "nowPlaying", quietTime: "nowPlaying",
            coverRoundness: "artwork",
            albumCoverRound: "album", karaokeCoverRound: "karaoke",
            albumCoverScale: "album", karaokeCoverScale: "karaoke",
            fontCaption: "album",
            albumFont: "album", albumTrackSpacing: "album",
            lyricsFollow: "lyricsView", lyricsAlign: "lyricsView",
            lyricsFont: "lyricsView", lyricsWidth: "lyricsView",
            lyricsInfoTitle: "lyricsView", lyricsInfoArtist: "lyricsView",
            lyricsInfoAlbum: "lyricsView",
            karaokeFollow: "karaoke", karaokeInfoTitle: "karaoke",
            karaokeInfoArtist: "karaoke", karaokeInfoAlbum: "karaoke",
            karaokeBackgroundScale: "karaoke"
        }
        for (var key in homes) {
            var e = entryFor(key)
            verify(e !== null, "the row " + key + " is missing")
            compare(e.section, homes[key], key + " drifted out of its tab")
        }
    }

    // The card used to be opaque with no way to soften it over the panel. It
    // still starts that way, and a stored percentage has to survive validation.
    function test_settings_opacity_starts_opaque_and_round_trips() {
        var e = entryFor("settingsOpacity")
        compare(e.label, "Settings opacity")
        compare(config.codeDefaults.settingsOpacity, 1.0)
        compare(config.settingsOpacity, 1.0)
        config.applyStored({ settingsOpacity: 0.7 })
        compare(config.settingsOpacity, 0.7)
        config.applyStored({ settingsOpacity: "nope" })
        compare(config.settingsOpacity, 0.7, "an invalid value should be ignored")
    }

    // The strip rule shares the pane rules' width but has its own switch, so it
    // starts on for an immediate edge and survives a file written by the card.
    function test_strip_separator_starts_on_and_round_trips() {
        var e = entryFor("stripSeparator")
        compare(e.label, "Strip separator")
        compare(config.codeDefaults.stripSeparator, true)
        compare(config.stripSeparator, true)
        config.applyStored({ stripSeparator: false })
        compare(config.stripSeparator, false)
        config.applyStored({ stripSeparator: "nope" })
        compare(config.stripSeparator, false, "an invalid value should be ignored")
    }

    // The two remaining strip refinements share the separator's treatment: each
    // starts on, each can be switched off, and each ignores a stored value the
    // row does not offer. The time one is a plain size choice now.
    function test_strip_refinements_start_on_and_round_trip() {
        compare(entryFor("quietTime").label, "Time size")
        var keys = ["progressInline", "quietTime"]
        for (var i = 0; i < keys.length; i++) {
            var key = keys[i]
            compare(config.codeDefaults[key], true, key + " does not start on")
            compare(config.valueFor(entryFor(key)), true, key + " is not on")
            var off = {}
            off[key] = false
            config.applyStored(off)
            compare(config.valueFor(entryFor(key)), false, key + " did not switch off")
            var bad = {}
            bad[key] = "nope"
            config.applyStored(bad)
            compare(config.valueFor(entryFor(key)), false,
                key + " accepted a value it does not offer")
        }
    }

    // With the seek as the edge there is no in-strip bar to stack, so the row
    // reads On and stops taking edits. The stored choice survives underneath.
    function test_inline_progress_is_held_on_by_the_seeker_edge() {
        var e = entryFor("progressInline")
        config.applyStored({ progressInline: false, stripSeekEdge: true })
        verify(!config.isActive(e), "inline progress should be disabled with the edge")
        compare(config.valueFor(e), true, "the row should read on")
        compare(config.progressInline, true, "the strip should use inline geometry")
        config.applyStored({ stripSeekEdge: false })
        verify(config.isActive(e))
        compare(config.valueFor(e), false, "the stored choice should come back")
    }

    // The bolder boundary starts off so the quiet strip is still the resting
    // look, but it persists like every other switch once chosen.
    function test_seek_edge_starts_off_and_round_trips() {
        var e = entryFor("stripSeekEdge")
        compare(e.label, "Seeker as edge")
        compare(config.codeDefaults.stripSeekEdge, false)
        compare(config.stripSeekEdge, false)
        config.applyStored({ stripSeekEdge: true })
        compare(config.stripSeekEdge, true)
        config.applyStored({ stripSeekEdge: "nope" })
        compare(config.stripSeekEdge, true, "an invalid value should be ignored")
    }

    // Line width still has a job with the pane rules off when the strip separator
    // is on; the seeker edge uses its own thickness instead of this width.
    function test_line_width_stays_live_for_the_strip_separator() {
        var e = entryFor("borderWidth")
        config.applyStored({ paneSeparators: false, paneHeadings: false,
            stripSeparator: true, stripSeekEdge: false })
        verify(config.isActive(e))
        config.applyStored({ stripSeekEdge: true })
        verify(!config.isActive(e), "the seeker edge replaces the hairline")
        config.applyStored({ stripSeekEdge: false, stripSeparator: false })
        verify(!config.isActive(e))
    }

    function test_reset_restores_the_captured_defaults() {
        for (var i = 0; i < config.entries.length; i++) {
            var e = config.entries[i]
            if (config.isAction(e)) continue
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
            if (config.isAction(row)) continue
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

    function test_strip_top_gap_starts_tight_and_survives_a_save() {
        var e = entryFor("stripTopGap")
        verify(e !== null, "the strip top gap row should exist")
        compare(config.stripTopGap, 2)
        compare(config.codeDefaults.stripTopGap, 2)
        compare(e.options[0], 0)
        compare(e.options[e.options.length - 1], 24)
        config.assign(e, 20)
        compare(config.stripTopGap, 20)
        config.reset()
        config.applyStored({ stripTopGap: 20 })
        compare(config.stripTopGap, 20)
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

    // Style and size were two rows over the album line; Info text is the only
    // control now, and its positive ramp reaches far enough for a distant seat.
    function test_album_details_have_one_info_text_control() {
        var details = entryFor("albumInfo")
        verify(details !== null, "the album details row should exist")
        compare(details.label, "Album details")
        verify(entryFor("albumInfoStyle") === null,
            "the separate caption style row should be gone")
        var info = entryFor("fontCaption")
        verify(info !== null, "the info text row should exist")
        compare(info.label, "Info text")
        verify(info.options[info.options.length - 1] >= 16,
            "Info text should reach +16")
    }

    // The retired style row folded into Info text, so a label or heading keeps
    // its emphasis instead of silently dropping back to the muted default.
    function test_the_old_caption_style_migrates_into_info_text() {
        config.reset()
        compare(config.fontCaption, config.codeDefaults.fontCaption)
        config.applyStored({ albumInfoStyle: "quiet" })
        compare(config.fontCaption, 0)
        config.reset()
        config.applyStored({ albumInfoStyle: "label" })
        compare(config.fontCaption, 1)
        config.reset()
        config.applyStored({ albumInfoStyle: "heading" })
        compare(config.fontCaption, 4)
        config.reset()
        config.applyStored({ albumInfoStyle: "heading", fontCaption: 6 })
        compare(config.fontCaption, 10)
        config.reset()
        config.applyStored({ albumInfoStyle: "heading", fontCaption: 16 })
        compare(config.fontCaption, 16)
    }

    // The two large framed covers start at the fuller radius and can fall back
    // to the global artwork radius with their own switches.
    function test_large_covers_start_at_the_fuller_radius() {
        verify(entryFor("albumCoverRound") !== null,
            "album view should have its own rounding switch")
        verify(entryFor("karaokeCoverRound") !== null,
            "karaoke should have its own rounding switch")
        compare(config.albumCoverRound, true)
        compare(config.karaokeCoverRound, true)
        compare(config.codeDefaults.albumCoverRound, true)
        compare(config.codeDefaults.karaokeCoverRound, true)
    }

    // The library keeps its cover size under Artwork; the two larger framed
    // covers now carry their own size rows in their own tabs.
    function test_large_covers_have_their_own_size_rows() {
        verify(entryFor("albumCoverScale") !== null,
            "album view should size its own cover")
        verify(entryFor("karaokeCoverScale") !== null,
            "karaoke should size its own side cover")
        compare(config.albumCoverScale, 100)
        compare(config.karaokeCoverScale, 100)
        var album = entryFor("albumCoverScale")
        var karaoke = entryFor("karaokeCoverScale")
        compare(album.label, "Cover size")
        compare(karaoke.label, "Cover size")
        compare(album.options[0], 50)
        compare(karaoke.options[0], 50)
        compare(album.options[album.options.length - 1], 150)
        compare(karaoke.options[karaoke.options.length - 1], 110)
        compare(entryFor("coverScale").section, "artwork",
            "the library cover size stays under Artwork")
    }

    // Corner rounding was a switch; it is a radius now. Square stays square,
    // round keeps the old 10px look, and an explicit radius still wins.
    function test_the_old_round_corners_switch_migrates_to_a_radius() {
        var e = entryFor("coverRoundness")
        verify(e !== null, "the artwork rounding row should exist")
        compare(e.options[0], 0)
        compare(e.options[e.options.length - 1], 24)
        config.reset()
        compare(config.coverRoundness, config.codeDefaults.coverRoundness)
        config.applyStored({ coverRounded: false })
        compare(config.coverRoundness, 0)
        config.reset()
        config.applyStored({ coverRounded: true })
        compare(config.coverRoundness, 10)
        config.reset()
        config.applyStored({ coverRounded: false, coverRoundness: 16 })
        compare(config.coverRoundness, 16)
    }

    // The playing tint lost its switch; the row that remains only picks the
    // accent bar. A file written before the split keeps its choice of sides.
    function test_the_playing_marker_migrates_and_the_tint_is_always_on() {
        var e = entryFor("playingMarker")
        verify(e !== null, "the playing marker row should exist")
        verify(entryFor("playingHighlight") === null, "the tint switch should be gone")
        compare(e.label, "Playing marker")
        config.reset()
        compare(config.playingMarker, "left", "the default marks the left edge")
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

    // The notice position and size moved with their setting's rename. The old
    // corner placement folds into the bottom band, which replaced it.
    function test_notice_settings_migrate_with_their_names() {
        var place = entryFor("findPlace")
        var scale = entryFor("findScale")
        verify(place !== null && scale !== null, "the renamed notice rows should exist")
        compare(place.label, "Notice position")
        compare(scale.label, "Notice size")
        verify(place.after === undefined, "notice position must not be an indented child")
        compare(place.orderAfter, "keyboardStyle")
        verify(config.sectionLists.general.indexOf(place)
            < config.sectionLists.general.indexOf(scale),
            "notice position should lead find size")
        config.reset()
        config.applyStored({ typeaheadPlace: "center", typeaheadScale: 9 })
        compare(config.findPlace, "center")
        compare(config.findScale, 9)
        compare(config.textOf(scale), "+3 px", "size is measured from the resting look")
        config.reset()
        config.applyStored({ typeaheadPlace: "corner", typeaheadScale: 3,
                             findPlace: "bottom", findScale: 4 })
        compare(config.findPlace, "bottom", "an explicit new key wins")
        compare(config.findScale, 4, "an explicit new key wins")
    }

    // Both notice rows are shared by the letters, the transport reply and the
    // error line, so neither waits on the keyboard style any more.
    function test_notice_rows_stay_live_in_every_keyboard_style() {
        var style = entryFor("keyboardStyle")
        var place = entryFor("findPlace")
        var scale = entryFor("findScale")
        var styles = ["find", "vim", "off"]
        for (var i = 0; i < styles.length; i++) {
            config.assign(style, styles[i])
            verify(config.isActive(place), "notice position should stay live in " + styles[i])
            verify(config.isActive(scale), "notice size should stay live in " + styles[i])
        }
    }

    // Highlighting is a view choice on each word surface, not one global: the
    // reading view's sits with its own rows and karaoke has its own. Following is
    // only a value of it.
    function test_each_word_surface_has_its_own_highlight() {
        var l = entryFor("lyricsFollow")
        compare(l.section, "lyricsView")
        compare(l.label, "Highlight")
        compare(l.options[0], "follow")
        verify(config.textOf(l).indexOf("Highlight") === 0,
            "the value should read as a kind of highlight")
        var k = entryFor("karaokeFollow")
        compare(k.section, "karaoke")
        compare(k.label, "Highlight")
        compare(k.options[0], "follow")
        verify(config.textOf(k).indexOf("Highlight") === 0,
            "the value should read as a kind of highlight")

        // Both open marking the line as they always did, and each stored value
        // survives validation on its own. An invalid value is ignored rather
        // than silently turning either surface's highlight off.
        compare(config.codeDefaults.lyricsFollow, "follow")
        compare(config.codeDefaults.karaokeFollow, "follow")
        config.applyStored({ lyricsFollow: "off", karaokeFollow: "highlight" })
        compare(config.lyricsFollow, "off")
        compare(config.karaokeFollow, "highlight")
        config.applyStored({ karaokeFollow: "bogus" })
        compare(config.karaokeFollow, "highlight")
    }

    // Each header piece is its own switch on both word surfaces. The old single
    // choice still folds into the switches on load, but an explicit switch wins
    // over the stale value however the two arrive in the file.
    function test_track_headers_are_independent_switches() {
        var rows = ["lyricsInfoTitle", "lyricsInfoArtist", "lyricsInfoAlbum",
            "karaokeInfoTitle", "karaokeInfoArtist", "karaokeInfoAlbum"]
        var expected = ["Title above lyrics", "Artist above lyrics", "Album above lyrics",
            "Title above lyrics", "Artist above lyrics", "Album above lyrics"]
        for (var i = 0; i < rows.length; i++) {
            var e = entryFor(rows[i])
            verify(e !== null, rows[i] + " is missing")
            compare(e.label, expected[i], rows[i] + " should say where the text goes")
            compare(e.options[0], true)
            compare(e.options[1], false)
            verify(e.after === undefined, rows[i] + " must be a top-level row")
        }
        verify(entryFor("lyricsInfo") === null, "the lyrics cycle should be gone")
        verify(entryFor("karaokeInfo") === null, "the karaoke cycle should be gone")
        // The header group leads each tab; the text settings below it are not
        // its children, so none of them should read as an indented subcategory.
        var order = ["lyricsInfoTitle", "lyricsFollow", "karaokeInfoTitle", "karaokeFollow"]
        for (var o = 0; o + 1 < order.length; o += 2) {
            verify(config.visibleEntries.indexOf(entryFor(order[o]))
                < config.visibleEntries.indexOf(entryFor(order[o + 1])),
                order[o] + " should lead its tab")
        }
        var plain = ["lyricsFollow", "lyricsAlign", "lyricsFont", "karaokeFollow",
            "karaokeFont", "karaokeAlign"]
        for (var p = 0; p < plain.length; p++)
            verify(entryFor(plain[p]).after === undefined, plain[p] + " must not indent")

        compare(config.codeDefaults.lyricsInfoTitle, true)
        compare(config.codeDefaults.lyricsInfoArtist, true)
        compare(config.codeDefaults.lyricsInfoAlbum, false)
        compare(config.codeDefaults.karaokeInfoTitle, true)
        compare(config.codeDefaults.karaokeInfoArtist, true)
        compare(config.codeDefaults.karaokeInfoAlbum, false)

        config.reset()
        config.applyStored({ lyricsInfo: "off", karaokeInfo: "all" })
        compare(config.lyricsInfoTitle, false)
        compare(config.lyricsInfoArtist, false)
        compare(config.lyricsInfoAlbum, false, "the reading view never had an album line")
        compare(config.karaokeInfoTitle, true)
        compare(config.karaokeInfoArtist, true)
        compare(config.karaokeInfoAlbum, true)

        config.reset()
        config.applyStored({ lyricsInfo: "title", karaokeInfo: "track" })
        compare(config.lyricsInfoTitle, true)
        compare(config.lyricsInfoArtist, false)
        compare(config.karaokeInfoTitle, true)
        compare(config.karaokeInfoArtist, false)
        compare(config.karaokeInfoAlbum, false)

        config.reset()
        config.applyStored({ karaokeInfoAlbum: true, karaokeInfo: "off" })
        compare(config.karaokeInfoTitle, false)
        compare(config.karaokeInfoArtist, false)
        compare(config.karaokeInfoAlbum, true, "an explicit switch wins")
        config.applyStored({ karaokeInfo: "bogus" })
        compare(config.karaokeInfoAlbum, true, "a stale cycle is ignored")

        config.reset()
        config.applyStored({ lyricsInfoAlbum: true, lyricsInfo: "off" })
        compare(config.lyricsInfoTitle, false)
        compare(config.lyricsInfoAlbum, true, "an explicit album switch wins")
    }

    // The background wash had been sharing the side cover's size. It now has a
    // row of its own, greyed unless that placement is showing, and a file that
    // only knows the old size starts with the wash it already had.
    function test_karaoke_background_has_its_own_cover_size() {
        var e = entryFor("karaokeBackgroundScale")
        compare(e.section, "karaoke")
        compare(e.label, "Background cover size")
        compare(config.codeDefaults.karaokeBackgroundScale, 100)
        verify(!config.isActive(e), "the size waits for the background cover")

        config.applyStored({ karaokeCover: "background" })
        verify(config.isActive(e))
        config.applyStored({ karaokeBackgroundScale: 30 })
        compare(config.karaokeBackgroundScale, 30)
        config.applyStored({ karaokeBackgroundScale: "nope" })
        compare(config.karaokeBackgroundScale, 30, "an invalid value is ignored")

        config.reset()
        config.applyStored({ stageCoverScale: 40, karaokeBackgroundScale: 60 })
        compare(config.karaokeBackgroundScale, 60, "an explicit new size wins")
        config.reset()
        config.applyStored({ stageCoverScale: 40 })
        compare(config.karaokeBackgroundScale, 40, "an old file keeps its wash size")
        compare(config.albumCoverScale, 50, "a smaller old size lifts to the new floor")
        compare(config.karaokeCoverScale, 50, "karaoke lifts with it")
        config.reset()
        config.applyStored({ stageCoverScale: 40, albumCoverScale: 70 })
        compare(config.albumCoverScale, 70, "an explicit album size wins")
        compare(config.karaokeCoverScale, 50, "karaoke still takes the old size")
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

    function test_editing_a_text_row_appends_and_commits_only_on_accept() {
        var e = entryFor("musicDir")
        config.assign(e, "/srv/music")
        config.beginTextEdit(e)
        compare(config.textEditDraft, "/srv/music", "editing starts at the old value")
        config.textKeyStroke("x")
        compare(config.textEditDraft, "/srv/musicx", "typing appends")
        config.textBackspace()
        compare(config.textEditDraft, "/srv/music")
        config.textClear()
        compare(config.textEditDraft, "", "Ctrl+A clears for a fresh path")
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
        config.textKeyStroke("~")
        compare(config.textEditDraft, "/srv/music~", "tilde is a typed character")
        config.textClear()
        config.textKeyStroke("/")
        config.textKeyStroke("n")
        config.textKeyStroke("e")
        config.textKeyStroke("w")
        config.endTextEdit(true)
        compare(config.musicDir, "/new")
    }

    function test_text_caret_walks_and_edits_at_its_position() {
        var e = entryFor("musicDir")
        config.assign(e, "/srv/music")
        config.beginTextEdit(e)
        compare(config.textEditCaret, 10, "editing starts at the end")

        config.textMoveCaret(-4)
        compare(config.textEditCaret, 6)
        config.textKeyStroke("X")
        compare(config.textEditDraft, "/srv/mXusic", "typing goes at the caret")
        compare(config.textEditCaret, 7)

        config.textBackspace()
        compare(config.textEditDraft, "/srv/music", "Backspace takes the character before it")
        compare(config.textEditCaret, 6)

        config.textDelete()
        compare(config.textEditDraft, "/srv/msic", "Delete takes the character at it")
        compare(config.textEditCaret, 6, "Delete does not move the caret")

        config.textMoveCaret(-100)
        compare(config.textEditCaret, 0, "the caret stops at the start")
        config.textMoveCaret(100)
        compare(config.textEditCaret, 9, "the caret stops at the end")
        config.textCaretToEdge(-1)
        compare(config.textEditCaret, 0)
        config.textCaretToEdge(1)
        compare(config.textEditCaret, 9)

        config.textClear()
        compare(config.textEditDraft, "")
        compare(config.textEditCaret, 0, "clearing resets the caret")
        config.endTextEdit(false)
        compare(config.textEditCaret, 0, "leaving the editor resets the caret")
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
