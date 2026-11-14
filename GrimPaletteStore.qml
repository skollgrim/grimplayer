pragma ComponentBehavior: Bound
// Derived album palettes, kept across shell restarts.
//
// GrimTheme is a QtObject and cannot own a FileView, and the palette cache is
// derived data rather than a preference, so it lives here instead of in
// GrimPlayerConfig. The map is keyed by the cover URL the Image actually
// resolved -- a sidecar cover, an extracted one and a downloaded one are
// distinct entries -- and an entry carries the time it was last quantized only
// so the map can be bounded; it is not an expiry.
//
// Only the four cover-derived tokens are stored. `urgent` is semantic and read
// live from the theme, so it has no business in a palette cache.
//
// The file is versioned by the rules that derived it: 2 is the depth-4 palette
// whose mean keeps duplicate clusters (see Palette.sanitize). Version 1 entries
// were derived at depth 3 with repeats dropped, so they are discarded on load
// rather than served as if they were the same thing.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property var cache: ({})
    readonly property int limit: 48

    readonly property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state"))
        + "/skollgrim.grimplayer/palettes.json"
    readonly property string stateDir: statePath.substring(0, statePath.lastIndexOf("/"))

    // Quickshell.Io cannot make a directory, so the mkdir below has to run
    // before the first write. Writes are blocked until it reports back rather
    // than raced against it; a save into a missing directory is lost silently.
    property bool stateDirReady: false

    function get(source) {
        var key = source ? String(source) : ""
        if (!key) return null
        var entry = root.cache[key]
        return entry && entry.palette ? entry.palette : null
    }

    function has(source) {
        return root.get(source) !== null
    }

    // The four tokens worth keeping, or null when any of them is not a colour.
    // The same check runs on the way back in, so a hand-edited or truncated
    // file degrades to a cache miss rather than handing the theme a bad colour.
    function storedPalette(palette) {
        if (!palette) return null
        var tokens = ["background", "foreground", "muted", "accent"]
        var out = {}
        for (var i = 0; i < tokens.length; i++) {
            var value = palette[tokens[i]]
            if (typeof value !== "string" || !/^#[0-9a-fA-F]{6}$/.test(value)) return null
            out[tokens[i]] = value
        }
        return out
    }

    // Drop the oldest entries until the map is within the limit. Recency is the
    // entry's own timestamp, which is when its cover was last quantized, so a
    // cover played on every restart stays while a one-off falls out.
    function trim(map) {
        var keys = []
        for (var k in map) {
            if (map.hasOwnProperty(k)) keys.push(k)
        }
        if (keys.length <= root.limit) return map
        keys.sort(function (a, b) {
            var ta = map[a] ? map[a].at : 0
            var tb = map[b] ? map[b].at : 0
            return ta - tb
        })
        var drop = keys.length - root.limit
        for (var i = 0; i < drop; i++) delete map[keys[i]]
        return map
    }

    function put(source, derived) {
        var key = source ? String(source) : ""
        var palette = root.storedPalette(derived)
        if (!key || !palette) return
        root.cache[key] = { palette: palette, at: Date.now() }
        root.cache = root.trim(root.cache)
        saveSoon()
    }

    // A cover edit rewrites the picture behind an unchanged path, so the
    // palette cached against that path is stale. Clearing the whole map is
    // coarse but cheap: edits are rare and the cache refills on the next visit.
    // It is written out at once rather than after the debounce, because the
    // stale entry must not outlive the edit if the shell stops soon after.
    function clear() {
        root.cache = ({})
        saveNow()
    }

    function saveSoon() {
        saveTimer.restart()
    }

    // The whole file as a string. Kept separate from saveNow() so the JSON
    // round-trip can be checked without a FileView.
    function serialize() {
        var entries = {}
        for (var k in root.cache) {
            if (!root.cache.hasOwnProperty(k)) continue
            var entry = root.cache[k]
            if (!entry || !entry.palette) continue
            entries[k] = { at: Number(entry.at) || 0, palette: entry.palette }
        }
        return JSON.stringify({ version: 2, entries: entries }, null, 2)
    }

    function saveNow() {
        paletteFile.setText(root.serialize())
    }

    FileView {
        id: paletteFile
        path: root.statePath
        // Nothing else edits this file, so watching it would only bounce our own
        // writes back at us.
        watchChanges: false
        printErrors: false
        // Synchronous load: the cache should already hold the first cover by the
        // time its Image resolves, so the panel does not start from the theme and
        // jump to the album's colour a moment later.
        blockLoading: true
        blockWrites: !root.stateDirReady
        atomicWrites: true
    }

    // `mkdir -p` in argv form: no shell to quote for, and idempotent, so running
    // it on every start costs nothing once the directory exists.
    Process {
        id: mkdirProc
        running: true
        command: ["mkdir", "-p", root.stateDir]
        onExited: root.stateDirReady = true
    }

    // Album changes can arrive in a burst during a queue skip; one write after
    // the burst is enough, and the cache is an optimisation rather than a record
    // that must survive the very next frame.
    Timer {
        id: saveTimer
        interval: 1200
        repeat: false
        onTriggered: root.saveNow()
    }

    // Read the cache back. `raw` defaults to the file's contents; a test (or a
    // future import path) can hand in a string instead. Every entry is checked
    // again on the way in, so a hand-edited or truncated file degrades to a
    // cache miss rather than handing the theme a bad colour, and a version this
    // build does not understand is discarded rather than guessed at.
    function load(raw) {
        var text = raw === undefined ? paletteFile.text() : raw
        if (!text) return
        try {
            var parsed = JSON.parse(text)
            if (!parsed || parsed.version !== 2
                    || !parsed.entries || typeof parsed.entries !== "object") return
            var loaded = {}
            for (var key in parsed.entries) {
                if (!parsed.entries.hasOwnProperty(key)) continue
                var entry = parsed.entries[key]
                var palette = root.storedPalette(entry && entry.palette)
                if (!key || !palette) continue
                loaded[key] = { palette: palette, at: Number(entry.at) || 0 }
            }
            root.cache = root.trim(loaded)
        } catch (e) {
            // Malformed file: start empty rather than failing to start.
        }
    }

    Component.onCompleted: root.load()
}
