import QtQuick
import QtTest
import "../../" as Plugin
import "../../PaletteSync.js" as PaletteSync

// Covers the two things the Node tests cannot reach: the QML glue that owns the
// palette file and the theme's delegation to it, and the cover race guard as it
// runs in QML's own JS engine. The components under test are the real
// GrimPaletteStore.qml, GrimTheme.qml and PaletteSync.js; only Quickshell's
// FileView/Process and the shell's qs.Commons tokens are stood in for (see
// stubs/).
TestCase {
    id: test
    name: "PaletteCache"

    // One store and one theme for the whole suite; init() puts both back to a
    // blank slate, so each test can assume an empty cache.
    Plugin.GrimPaletteStore { id: palettes }
    Plugin.GrimTheme { id: theme; store: palettes }

    Component {
        id: bareThemeComponent
        Plugin.GrimTheme {}
    }

    readonly property var paletteA: {
        "background": "#231512",
        "foreground": "#eae4e3",
        "muted": "#8a7a76",
        "accent": "#b84a2f"
    }

    readonly property var paletteB: {
        "background": "#28250f",
        "foreground": "#e7e6de",
        "muted": "#8d8a6b",
        "accent": "#d1be00"
    }

    function init() {
        palettes.cache = ({})
        palettes.stateDirReady = true
        theme.reset()
    }

    // ---- store: hit, miss, validation --------------------------------------

    function test_empty_cache_misses() {
        compare(palettes.get("file:///never.jpg"), null)
        compare(palettes.has("file:///never.jpg"), false)
        compare(Object.keys(palettes.cache).length, 0)
    }

    function test_put_then_get_keeps_only_the_four_tokens() {
        var extra = {
            "background": "#041644",
            "foreground": "#e1e6ef",
            "muted": "#8092b4",
            "accent": "#036be3",
            "urgent": "#ff0000"
        }
        palettes.put("file:///a.jpg", extra)
        var got = palettes.get("file:///a.jpg")
        verify(got !== null)
        compare(got.background, "#041644")
        compare(got.foreground, "#e1e6ef")
        compare(got.muted, "#8092b4")
        compare(got.accent, "#036be3")
        verify(got.urgent === undefined, "urgent is semantic and must not be cached")
        compare(Object.keys(got).length, 4)
        verify(palettes.has("file:///a.jpg"))
    }

    function test_put_rejects_a_palette_with_a_bad_colour() {
        palettes.put("file:///bad.jpg", {
            "background": "red",
            "foreground": "#ffffff",
            "muted": "#000000",
            "accent": "#ffffff"
        })
        verify(!palettes.has("file:///bad.jpg"))
        compare(Object.keys(palettes.cache).length, 0)
    }

    function test_put_rejects_a_palette_missing_a_token() {
        palettes.put("file:///short.jpg", {
            "background": "#000000",
            "foreground": "#ffffff",
            "muted": "#808080"
        })
        verify(!palettes.has("file:///short.jpg"))
    }

    function test_put_without_a_source_is_ignored() {
        palettes.put("", paletteA)
        palettes.put(null, paletteA)
        compare(Object.keys(palettes.cache).length, 0)
    }

    // ---- store: file round trip --------------------------------------------

    function test_serialize_writes_a_versioned_file() {
        palettes.put("file:///a.jpg", paletteA)
        palettes.put("file:///b.jpg", paletteB)
        var parsed = JSON.parse(palettes.serialize())
        compare(parsed.version, 1)
        compare(Object.keys(parsed.entries).length, 2)
        compare(parsed.entries["file:///a.jpg"].palette.background, "#231512")
        compare(Object.keys(parsed.entries["file:///a.jpg"].palette).length, 4)
        verify(parsed.entries["file:///a.jpg"].at > 0, "entries carry a timestamp")
    }

    function test_load_restores_what_serialize_wrote() {
        palettes.put("file:///a.jpg", paletteA)
        palettes.put("file:///b.jpg", paletteB)
        var json = palettes.serialize()

        palettes.cache = ({})
        palettes.load(json)

        compare(palettes.get("file:///a.jpg").accent, "#b84a2f")
        compare(palettes.get("file:///b.jpg").background, "#28250f")
        compare(Object.keys(palettes.cache).length, 2)
    }

    function test_load_of_malformed_json_starts_empty() {
        // The cache is only replaced by a parse that succeeds, so a broken file
        // leaves it alone rather than throwing. On startup the map is empty and
        // this is the whole result: a cache miss for every cover.
        palettes.load("{ \"version\": 1, \"entries\": {")
        compare(Object.keys(palettes.cache).length, 0)

        // A good file still loads after a bad one.
        palettes.load('{"version": 1, "entries": {"file:///a.jpg": {"at": 1, "palette": {'
            + '"background": "#000000", "foreground": "#ffffff",'
            + '"muted": "#808080", "accent": "#ff0000"}}}}')
        verify(palettes.has("file:///a.jpg"))
    }

    function test_load_of_an_unknown_version_starts_empty() {
        palettes.load('{"version": 2, "entries": {"file:///a.jpg": {"at": 1, "palette": {'
            + '"background": "#000000", "foreground": "#ffffff",'
            + '"muted": "#808080", "accent": "#ff0000"}}}}')
        compare(Object.keys(palettes.cache).length, 0)
    }

    function test_load_drops_a_bad_entry_but_keeps_the_good_one() {
        palettes.load('{"version": 1, "entries": {'
            + '"file:///good.jpg": {"at": 1, "palette": {'
            + '"background": "#000000", "foreground": "#ffffff",'
            + '"muted": "#808080", "accent": "#ff0000"}},'
            + '"file:///bad.jpg": {"at": 2, "palette": {'
            + '"background": "nope", "foreground": "#ffffff",'
            + '"muted": "#808080", "accent": "#ff0000"}}}}')
        verify(palettes.has("file:///good.jpg"))
        verify(!palettes.has("file:///bad.jpg"))
        compare(Object.keys(palettes.cache).length, 1)
    }

    function test_clear_empties_the_map_and_the_serialized_file() {
        palettes.put("file:///a.jpg", paletteA)
        palettes.clear()
        compare(Object.keys(palettes.cache).length, 0)
        compare(Object.keys(JSON.parse(palettes.serialize()).entries).length, 0)
    }

    function test_trim_drops_the_oldest_entries_beyond_the_limit() {
        var map = ({})
        var palette = paletteA
        for (var i = 0; i < 60; i++) {
            map["file:///cover-" + i + ".jpg"] = { "palette": palette, "at": i + 1 }
        }
        var trimmed = palettes.trim(map)
        compare(Object.keys(trimmed).length, 48)
        // 60 entries, 12 over the limit, oldest first: 1..12 go, 13..60 stay.
        verify(trimmed["file:///cover-0.jpg"] === undefined)
        verify(trimmed["file:///cover-11.jpg"] === undefined)
        verify(trimmed["file:///cover-12.jpg"] !== undefined)
        verify(trimmed["file:///cover-59.jpg"] !== undefined)
    }

    // ---- theme delegation ---------------------------------------------------

    function test_theme_reads_the_cache_through_the_store() {
        palettes.put("file:///a.jpg", paletteA)
        compare(theme.cachedPalette("file:///a.jpg").background, "#231512")
        verify(theme.hasPalette("file:///a.jpg"))
        verify(!theme.hasPalette("file:///other.jpg"))
        compare(Object.keys(theme.paletteCache).length, 1)
    }

    function test_theme_clears_the_cache_through_the_store() {
        palettes.put("file:///a.jpg", paletteA)
        theme.clearPaletteCache()
        compare(Object.keys(palettes.cache).length, 0)
        verify(!theme.hasPalette("file:///a.jpg"))
    }

    function test_apply_uses_a_cached_palette_on_a_hit() {
        palettes.put("file:///hit.jpg", paletteB)
        // Colours that belong to some other cover: the cache must win.
        theme.apply(["#e91792", "#ee038e"], "file:///hit.jpg")
        compare(theme.override.background, "#28250f")
        compare(theme.override.accent, "#d1be00")
    }

    function test_apply_derives_and_caches_on_a_miss() {
        theme.apply(["#e91792", "#ee038e", "#efe7de"], "file:///miss.jpg")
        verify(theme.override !== null)
        verify(theme.hasPalette("file:///miss.jpg"))
        compare(palettes.get("file:///miss.jpg").background, theme.override.background)
        verify(String(theme.override.background).match(/^#[0-9a-f]{6}$/i),
            "derived background is a hex colour: " + theme.override.background)
    }

    function test_apply_with_no_colours_resets_to_the_theme() {
        palettes.put("file:///a.jpg", paletteA)
        theme.applyDerived(paletteA)
        theme.apply([], "file:///a.jpg")
        compare(theme.override, null)
    }

    function test_theme_without_a_store_still_derives() {
        var bare = bareThemeComponent.createObject(test)
        verify(bare !== null)
        compare(bare.cachedPalette("file:///a.jpg"), null)
        compare(bare.hasPalette("file:///a.jpg"), false)
        compare(Object.keys(bare.paletteCache).length, 0)
        // Neither call may throw when no store is wired.
        bare.storePalette("file:///a.jpg", paletteA)
        bare.clearPaletteCache()
        bare.apply(["#e91792"], "file:///a.jpg")
        verify(bare.override !== null)
        verify(String(bare.override.background).match(/^#[0-9a-f]{6}$/i))
        bare.destroy()
    }

    // ---- the cover race guard, in QML's JS engine ---------------------------

    function test_race_guard_holds_a_palette_from_another_cover() {
        // The quantizer still holds the old album's colours while the new cover
        // loads: applying them would paint the wrong ground and cache it under
        // the new source.
        var stale = {
            "adaptive": true,
            "hasArt": true,
            "paletteSource": "file:///old.jpg",
            "paletteSize": 8,
            "noArt": false
        }
        compare(PaletteSync.pick(stale, "file:///new.jpg", null).action, PaletteSync.HOLD)
    }

    function test_race_guard_applies_colours_claimed_by_this_cover() {
        var current = {
            "adaptive": true,
            "hasArt": true,
            "paletteSource": "file:///new.jpg",
            "paletteSize": 8,
            "noArt": false
        }
        compare(PaletteSync.pick(current, "file:///new.jpg", null).action, PaletteSync.APPLY)
    }

    function test_cache_hit_beats_the_race_guard() {
        var stale = {
            "adaptive": true,
            "hasArt": true,
            "paletteSource": "file:///old.jpg",
            "paletteSize": 8,
            "noArt": false
        }
        compare(PaletteSync.pick(stale, "file:///new.jpg", paletteA).action,
            PaletteSync.DERIVED)
        compare(PaletteSync.pick(stale, "file:///new.jpg", paletteA).palette.background,
            "#231512")
    }

    function test_adaptive_off_resets_even_with_a_cache_hit() {
        var off = {
            "adaptive": false,
            "hasArt": true,
            "paletteSource": "file:///new.jpg",
            "paletteSize": 8,
            "noArt": false
        }
        compare(PaletteSync.pick(off, "file:///new.jpg", paletteA).action, PaletteSync.RESET)
    }

    function test_no_art_resets_but_a_probe_in_flight_holds() {
        var nothing = {
            "adaptive": true,
            "hasArt": false,
            "paletteSource": "",
            "paletteSize": 0,
            "noArt": true
        }
        compare(PaletteSync.pick(nothing, "file:///new.jpg", null).action, PaletteSync.RESET)

        var probing = {
            "adaptive": true,
            "hasArt": false,
            "paletteSource": "",
            "paletteSize": 0,
            "noArt": false
        }
        compare(PaletteSync.pick(probing, "file:///new.jpg", null).action, PaletteSync.HOLD)
    }
}
