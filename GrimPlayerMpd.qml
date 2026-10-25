pragma ComponentBehavior: Bound
// MPD client for GrimPlayer, exposed to the panel as the plugin's service.
//
// Talks to MPD over its Unix socket, so there is nothing to proxy and no reason
// to touch the MPD config. Two connections are used deliberately:
//
//   cmd - request/response, used for every command the player sends.
//   ev  - a dedicated `idle` subscription.
//
// The split matters: MPD's `idle` blocks the connection it runs on, so a
// command sent on that same connection while we are waiting for events would
// not be answered until the next state change. Keeping the subscription on its
// own socket is what makes the UI feel immediate.
//
// Both sockets live in a Loader and are recreated on retry. A failed connect
// emits only error() -- connectionStateChanged never fires -- and the instance
// wedges permanently, because the internal QLocalSocket is only torn down on a
// clean disconnect. There is no reconnect to perform on a live Socket, so the
// retry path throws the instance away and builds a new one.
import QtQuick
import Quickshell
import Quickshell.Io
import QtCore
import "Covers.js" as Covers

Item {
    id: root

    // ---- injected by shell.qml (_syncServices/ensureService) ----
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null

    // Quickshell.env() returns null for a variable that is not set, and null does
    // not equal "", so the override has to be tested for truthiness rather than
    // inequality. Checking `!== ""` returned the null through as the socket path,
    // which is why MPD never received a connection.
    readonly property string socketPath: {
        var override = Quickshell.env("GRIM_LIBRARY_MPD_SOCKET")
        if (override) return String(override)
        var home = Quickshell.env("HOME")
        if (home) return String(home) + "/.mpd/socket"
        // Last resort: the file URL form has to be stripped before it is usable
        // as a filesystem path.
        return String(StandardPaths.writableLocation(StandardPaths.HomeLocation)).replace(/^file:\/\//, "") + "/.mpd/socket"
    }

    // MPD reports every path relative to its music_directory, so writing tags
    // means turning one back into a filesystem path. Same derivation as the panel
    // side, kept here as well because this is the half that touches the disk.
    readonly property string musicDir: {
        var dir = Quickshell.env("XDG_MUSIC_DIR")
        if (dir) return String(dir)
        var home = Quickshell.env("HOME")
        return (home ? String(home) : "") + "/Music"
    }

    // Everything the plugin keeps on disk lives under one state directory:
    // XDG_STATE_HOME, or ~/.local/state. Quickshell.env() answers null for an
    // unset variable, and null + "/.local/state" would stringify to
    // "null/.local/state" rather than failing, so HOME is guarded -- an empty
    // HOME leaves the path rooted at "/" instead of prefixed with "null".
    readonly property string stateDir:
        (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state"))
        + "/skollgrim.grimplayer"

    property bool connected: false
    property bool everConnected: false
    property string serverVersion: ""
    property string lastError: ""
    property bool libraryLoaded: false

    // A successful read clears the banner, but a command MPD *refuses* changes
    // no state, so no event follows it and no read is triggered by it either --
    // the text would then sit there until some unrelated thing happened to fire.
    // The banner expires on its own instead, and a fresh error restarts the
    // clock rather than queueing behind the one already showing.
    readonly property int errorTimeout: 6000

    function setError(text) {
        if (text === undefined || text === null || text === "") return
        root.lastError = String(text)
        errorTimer.restart()
    }

    function clearError() {
        root.lastError = ""
        errorTimer.stop()
    }

    Timer {
        id: errorTimer
        interval: root.errorTimeout
        onTriggered: root.clearError()
    }

    // Raw `status` / `currentsong` maps, refreshed on every event burst. The
    // panel reads these; nothing here polls.
    property var status: ({})
    property var current: ({})

    // Artist -> album -> tracks, built once from a single listallinfo.
    property var artists: []

    // file path -> { artist, album, track } into the tree above. Rebuilt with it,
    // so locateCurrent does not walk the library on every event.
    property var trackLocations: ({})

    property int reconnectDelay: 1500

    // ---- commands ----

    // One entry per in-flight command. MPD is strictly request/response and
    // every response ends with a lone OK (or ACK), so a FIFO keyed on that
    // terminator is all the framing this protocol needs.
    property var pending: []

    function send(command, onDone) {
        if (!root.connected || !cmdLoader.item || !cmdLoader.item.connected) {
            if (onDone) onDone([], "not connected")
            return
        }
        root.pending.push({ lines: [], onDone: onDone })
        cmdLoader.item.write(command + "\n")
        cmdLoader.item.flush()
    }

    // Batches into one MPD transaction, so filling a queue of hundreds of
    // tracks costs a single round trip and can never be seen half-applied.
    // MPD emits no per-command response inside a list, only the final OK.
    function sendList(commands, onDone) {
        if (!root.connected || !cmdLoader.item || !cmdLoader.item.connected) {
            if (onDone) onDone([], "not connected")
            return
        }
        root.pending.push({ lines: [], onDone: onDone })
        cmdLoader.item.write("command_list_begin\n" + commands.join("\n") + "\ncommand_list_end\n")
        cmdLoader.item.flush()
    }

    function feedCommandLine(line) {
        var t = String(line === undefined || line === null ? "" : line).trim()

        // The greeting is an OK line, so it has to be recognised before the
        // pending-FIFO handling would treat it as the answer to a command.
        if (t.indexOf("OK MPD ") === 0) {
            root.serverVersion = t.substring(7).trim()
            if (!root.everConnected) {
                root.everConnected = true
                root.bootstrap()
            }
            return
        }
        if (t === "") return

        if (t === "OK") {
            var entry = root.pending.shift()
            if (entry && entry.onDone) entry.onDone(entry.lines, null)
            return
        }
        if (t.indexOf("ACK ") === 0) {
            var bad = root.pending.shift()
            // A null message means MPD declined for a reason that is not a fault,
            // so the command counts as handled and nothing is raised.
            if (bad && bad.onDone) bad.onDone(bad.lines, root.ackMessage(t))
            return
        }
        // Lines belong to the OLDEST outstanding command, not the newest.
        // MPD answers strictly in request order, so the response in flight is
        // the one at the head of the queue. Appending to the tail handed every
        // response to the last command queued: with status, currentsong and
        // listallinfo all in flight, the status and currentsong callbacks were
        // invoked with empty line arrays and set their properties to {}, while
        // listallinfo was handed the lot and shrugged it off because
        // buildLibrary only reads `file:` lines. So the library looked perfect
        // and status was permanently empty -- no duration, no state, so the
        // seek bar never advanced and play/pause always showed "play".
        if (root.pending.length > 0) root.pending[0].lines.push(t)
    }

    // MPD rejects a command with "ACK [50@0] {previous} No MPD song exists": an
    // error code, the position in the command list, the command that failed and
    // a sentence. Showing the line as it stands puts protocol punctuation in the
    // middle of the panel's one error banner, so only the sentence is kept.
    //
    // Code 50 (ACK_ERROR_NO_EXIST) is not an error at all here: it is what
    // previous/next return at the ends of the queue, which is a no-op rather than
    // a failure, so it is reported to the caller as a handled command and never
    // reaches the banner.
    function ackMessage(line) {
        var body = String(line).substring(4).trim()
        var open = body.indexOf("{")
        var close = body.indexOf("}", open + 1)
        if (close < 0) return body
        // A well-formed ACK reads "[<code>@<cmdnum>] ...", so the code sits
        // between the leading bracket and the at-sign. A line without an at-sign
        // has no code to read, and substring(1, -1) would silently swap its
        // arguments and hand back the bracket instead.
        var at = body.indexOf("@")
        var code = at > 0 ? body.substring(1, at) : ""
        var message = body.substring(close + 1).trim()
        if (code === "50") return null
        return message === "" ? body : message
    }

    // ---- events ----

    // Changed subsystem names: "player", "playlist", "mixer", "options". The
    // key/value lines that follow a name are detail about *what* changed; the
    // panel does not need them, because a full status read is one round trip
    // and keeps the event handler free of parsing rules.
    property var changed: []
    property bool refreshing: false
    property bool refreshQueued: false

    function feedEventLine(line) {
        var t = String(line === undefined || line === null ? "" : line).trim()
        if (t === "") return

        if (t.indexOf("OK MPD ") === 0) {
            root.armIdle()
            return
        }
        if (t === "OK") {
            root.handleEvents()
            return
        }
        // MPD's idle reply is one `changed: <subsystem>` line per subsystem and
        // nothing else. This used to look for a bare subsystem name and treat
        // every line containing a colon as uninteresting detail, so the
        // `changed:` lines were all discarded, `changed` stayed empty, and
        // handleEvents always found nothing to refresh. Status and elapsed then
        // froze at whatever bootstrap had read, for the life of the connection.
        if (t.indexOf("changed: ") === 0) {
            var sub = t.substring(9).trim()
            if (sub !== "" && root.changed.indexOf(sub) < 0) root.changed.push(sub)
        }
    }

    function armIdle() {
        if (!evLoader.item || !evLoader.item.connected) return
        // `database` is what reports an updated music directory -- an added
        // album, a deleted file, a retag. Without it the tree is whatever the
        // library held when the socket connected, for the life of the
        // connection.
        evLoader.item.write("idle player mixer options playlist database\n")
        evLoader.item.flush()
    }

    // Re-arm before refreshing. There is then no window in which a change can
    // slip through unnoticed between the event arriving and the next
    // subscription, even though the refresh itself happens on the other socket.
    property bool dbUpdatePending: false
    Timer {
        id: dbUpdateTimer
        interval: 250
        repeat: false
        onTriggered: {
            if (root.dbUpdatePending) {
                root.dbUpdatePending = false
                root.dbUpdateTimer.restart()
                return
            }
            root.loadLibrary()
        }
    }

    function handleEvents() {
        root.armIdle()
        var touched = root.changed
        root.changed = []
        if (touched.length === 0) return
        if (touched.indexOf("database") >= 0) {
            if (root.dbUpdateTimer.running) {
                root.dbUpdatePending = true
            } else {
                root.dbUpdateTimer.restart()
            }
        }
        root.refreshState()
    }

    // A burst of events while a read is still in flight collapses into one
    // extra read rather than a pile of queued commands.
    //
    // Both reads are queued before either answer comes back. Issuing the second
    // from inside the first one's callback would append it behind whatever was
    // already outstanding -- loadLibrary() has a listallinfo in flight at this
    // point -- and MPD answers strictly in request order, so that response would
    // be handed to the wrong callback and the library came back nearly empty.
    function refreshState() {
        if (root.refreshing) {
            root.refreshQueued = true
            return
        }
        root.refreshing = true
        root.send("status", function (lines, error) {
            if (error) root.setError("status: " + error)
            else {
                root.status = toMap(lines)
                // Both of these read the status just assigned above, so they run
                // only once it is known rather than on the event that prompted
                // the refresh. Looping before the read would re-check the state
                // the loop is trying to act on.
                root.syncRepeatModeFromMpd()
                root.maybeLoopAlbum()
                // A round trip that succeeded is proof the connection is healthy,
                // so it takes down whatever was last recorded rather than waiting
                // out the banner's own timer.
                root.clearError()
            }
        })
        root.send("currentsong", function (songLines, songError) {
            if (songError) root.setError("currentsong: " + songError)
            else {
                root.current = toMap(songLines)
                root.notePlayingSong(root.current.file)
                // The loop point is a function of the tree and the playing song,
                // so it is repopulated whenever the song changes rather than only
                // when the user leaves album mode.
                root.rememberAlbumLoopPoint()
            }
            root.refreshing = false
            if (root.refreshQueued) {
                root.refreshQueued = false
                root.refreshState()
            }
        })
    }

    function bootstrap() {
        root.clearError()
        root.connected = true
        // A connection that answers is the signal that the backoff has done its
        // job. Without resetting it here the delay only ever ratchets upwards,
        // so a handful of unrelated blips early in the session leave the panel
        // sitting disconnected for 30s at a time for the rest of it.
        root.reconnectDelay = 1500
        // A reconnect starts a fresh exchange. Anything left outstanding when
        // the socket dropped is never going to be answered, so the in-flight
        // guard and the pending FIFO have to be cleared here: left set, the
        // first refreshState() below sees `refreshing` still true, only queues
        // a retry that nothing will ever service, and status stays frozen for
        // the rest of the shell's life. Stale FIFO entries are worse still --
        // they would swallow the responses to the commands sent right after.
        root.refreshing = false
        root.refreshQueued = false
        root.pending = []
        root.refreshState()
        root.loadLibrary()
    }

    // ---- library ----

    function loadLibrary() {
        root.libraryLoaded = false
        // The loop point is a pair of indices into the tree this read is about to
        // replace, so it cannot survive the rebuild. The currentsong refresh that
        // follows repopulates it from whatever MPD is actually playing.
        root.albumLoopPoint = null
        root.send("listallinfo", function (lines, error) {
            if (error) {
                root.setError("listallinfo: " + error)
                return
            }
            root.buildLibrary(lines)
        })
    }

    // listallinfo on MPD 0.24 is not a clean record stream: there are no blank
    // separators, and `directory:` and `playlist:` entries are interleaved with
    // the songs. A record begins at each `file:` and runs until the next one.
    //
    // The `directory:` and `playlist:` lines have to be ignored rather than
    // treated as a record terminator. Dropping the in-progress song on them loses
    // every track that happened to sit between a directory header and the next
    // file, which shows up as albums quietly missing tracks. MPD also lists saved
    // playlists alongside the songs, so filtering them is not optional either.
    function buildLibrary(lines) {
        var songs = []
        var cur = null

        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            var sep = line.indexOf(": ")
            if (sep < 0) {
                cur = null
                continue
            }
            var key = line.substring(0, sep)
            var value = line.substring(sep + 2)

            if (key === "directory" || key === "playlist") {
                continue
            } else if (key === "file") {
                if (cur !== null) songs.push(cur)
                cur = { file: value, track: null, disc: null, duration: 0 }
            } else if (cur !== null) {
                if (key === "Title") cur.title = value
                else if (key === "Artist") cur.artist = value
                else if (key === "AlbumArtist") cur.albumArtist = value
                else if (key === "Album") cur.album = value
                else if (key === "Date") cur.date = value
                else if (key === "Track") cur.track = leadingInt(value)
                else if (key === "Disc") cur.disc = leadingInt(value)
                else if (key === "Genre") cur.genre = value
                else if (key === "duration") cur.duration = parseFloat(value)
                else if (key === "Time" && !cur.duration) cur.duration = parseFloat(value)
            }
        }
        if (cur !== null) songs.push(cur)

        // Grouping matches ncmpcpp: by each track's own Artist, falling back to
        // the album artist for the handful of tracks that omit it.
        var byArtist = {}
        // A per-artist album lookup rather than a linear scan of artist.albums:
        // an "Unknown artist" bucket in a partly-untagged library can hold
        // hundreds of albums, which made the scan quadratic.
        var albumByKey = {}
        var ordered = []

        for (var s = 0; s < songs.length; s++) {
            var song = songs[s]
            var artistName = song.artist || song.albumArtist || "Unknown artist"
            var albumName = song.album || "Unknown album"

            var artist = byArtist[artistName]
            if (artist === undefined) {
                artist = { name: artistName, albums: [] }
                byArtist[artistName] = artist
                ordered.push(artist)
            }
            var key = artistName + "\u0000" + albumName
            var album = albumByKey[key]
            if (album === undefined) {
                album = { name: albumName, tracks: [] }
                albumByKey[key] = album
                artist.albums.push(album)
            }
            album.tracks.push(song)
        }

        // The album year comes from the tracks' Date tags, not the file name, so
        // it is the release year the files were tagged with. Albums are ordered
        // oldest first within each artist.
        for (var o = 0; o < ordered.length; o++) {
            var entry = ordered[o]
            for (var al = 0; al < entry.albums.length; al++) {
                entry.albums[al].year = albumYear(entry.albums[al].tracks)
                entry.albums[al].tracks.sort(compareTracks)
            }
            entry.albums.sort(compareAlbums)
        }
        ordered.sort(byName)

        // A file -> tree position map, built once here so locateCurrent (which
        // runs on every currentsong refresh, including during album-repeat) is a
        // lookup rather than a walk of the whole library. The indices are taken
        // after sorting, so they match the order the panel sees.
        var locations = {}
        for (var la = 0; la < ordered.length; la++) {
            var lartist = ordered[la]
            for (var lb = 0; lb < lartist.albums.length; lb++) {
                var ltracks = lartist.albums[lb].tracks
                for (var lt = 0; lt < ltracks.length; lt++)
                    locations[ltracks[lt].file] = { artist: la, album: lb, track: lt }
            }
        }
        root.trackLocations = locations
        root.artists = ordered
        root.libraryLoaded = true
    }

    // ---- writing tags ----
    //
    // MPD cannot write tags: it has no command for it and treats the library as
    // read-only. So the files are edited in place by the tools that already ship
    // on the machine -- mid3v2 for ID3v2 and metaflac for Vorbis comments -- both
    // of which rewrite only the tag block and leave the audio stream alone. That
    // matters here: rewriting the file instead (ffmpeg, say) would touch the
    // audio itself, and a player that can quietly re-encode someone's library is
    // not a thing worth shipping.
    //
    // Nothing is discovered at runtime beyond the extension. There is no ffmpeg
    // fallback, because there is no safe way to try one: if it fails partway the
    // file is the thing that was at risk.
    readonly property var id3Frames: ({
        title: "TIT2", artist: "TPE1", albumArtist: "TPE2", album: "TALB",
        track: "TRCK", disc: "TPOS", date: "TDRC", genre: "TCON"
    })

    readonly property var vorbisFields: ({
        title: "TITLE", artist: "ARTIST", albumArtist: "ALBUMARTIST", album: "ALBUM",
        track: "TRACKNUMBER", disc: "DISCNUMBER", date: "DATE", genre: "GENRE"
    })

    // ---- country ----
    //
    // MPD has no country field at all: its song model exposes a fixed list of tags
    // (checked against this library, which is how these names were chosen) and
    // this is not on it, so nothing MPD reports can be trusted to carry one. The
    // tag itself is Picard's, which is what this library is already tagged with,
    // and it holds an ISO 3166-1 alpha-2 code rather than a name.
    //
    // MP3 carries it as a TXXX user frame, so it cannot go through id3Frames --
    // a TXXX is identified by its description, not by the frame name alone.
    readonly property var id3Txxx: ({
        country: "MusicBrainz Album Release Country"
    })

    // Vorbis comments are a flat list of named fields, and readers disagree about
    // which name a release country goes under, so both are written and either is
    // accepted on the way in.
    function vorbisFieldsFor(key) {
        if (key === "country") return ["MUSICBRAINZ_ALBUMRELEASECOUNTRY", "RELEASECOUNTRY"]
        var field = root.vorbisFields[key]
        return field ? [field] : []
    }

    // Country is an album-level fact, so it is remembered per directory. That
    // keeps the cache small, and means one probe covers a whole album rather than
    // one per track. MPD cannot be asked for this at all, which is why it is read
    // from the file directly -- but only ever once per album, then kept.
    readonly property string countryStatePath: root.stateDir + "/countries.json"
    property var countryCache: ({})
    property string playingCountryDir: ""
    property string playingCountry: ""
    property bool countriesDirty: false

    // The album directory a file belongs to, from the one shared implementation
    // in Covers.js: it folds a cue album's virtual track back onto the cue file's
    // own directory and keys a track in the music root on ".", so the country,
    // cover-override and cover-cache maps here use exactly the directory
    // CoverArt probes. Keeping a second copy of this arithmetic here is what let
    // the two drift, and a cover set or cleared on a cue album then wrote an
    // override the reader never looked up.
    function albumDirOf(file) {
        return Covers.albumDir(file)
    }

    // What the editor shows for a song's country: the cached value if the album
    // has one, otherwise empty. An album nobody has probed or tagged reads as
    // untagged rather than as an error.
    function countryForDir(dir) {
        if (!dir) return ""
        var value = root.countryCache[dir]
        return value === undefined || value === null ? "" : String(value)
    }

    // A two-letter code becomes a flag by offsetting each letter into the
    // regional indicator block, which is laid out as consecutive code points from
    // A, so the letters of a country and its indicator pair differ by a constant.
    // Written with fromCharCode rather than fromCodePoint so it does not depend on
    // how much of ES6 the QML engine happens to expose.
    function flagEmoji(code) {
        var c = String(code === undefined || code === null ? "" : code).trim().toUpperCase()
        // MusicBrainz spells "released worldwide" as the pseudo-country XW. There
        // is no territory behind it, so it gets a globe rather than a flag.
        if (c === "XW") return "\uD83C\uDF0D"

        // The UK home nations are not ISO 3166-1 countries: England, Scotland and
        // Wales have no two-letter code of their own, and MusicBrainz tags UK
        // releases as plain GB. So they are accepted as ISO 3166-2 subdivisions,
        // which is what the subdivision flag emoji are keyed on. Northern Ireland
        // is deliberately absent: Noto Color Emoji has no gb-nir glyph, so it would
        // render as an empty white flag, which is worse than falling back to GB.
        var subdivision = {
            "GB-ENG": "ENG", "GB-SCT": "SCT", "GB-WLS": "WLS"
        }
        if (subdivision[c] !== undefined) {
            return tagFlag("GB" + subdivision[c])
        }

        if (!/^[A-Z]{2}$/.test(c)) return ""
        if (c.charAt(0) === "X") return "\uD83C\uDF0D"
        return String.fromCharCode(
            0xD83C, 0xDDE6 + c.charCodeAt(0) - 65,
            0xD83C, 0xDDE6 + c.charCodeAt(1) - 65
        )
    }

    // A subdivision flag is a waving black flag followed by one tag character per
    // letter (a base of U+E0061) and a cancel tag to close the run.
    //
    // The hyphen is dropped deliberately. The spec includes it, as U+E002D, but
    // Noto Color Emoji has no glyph for it, so the hyphenated sequence fails to
    // compose and every one of these renders as a blank grey flag -- verified by
    // rendering both forms. Omitting it composes correctly and matches what the
    // emoji actually shows, at the cost of not being what the spec says.
    function tagFlag(letters) {
        var out = [0x1F3F4]
        for (var i = 0; i < letters.length; i++) {
            out.push(0xE0061 + letters.charCodeAt(i) - 65)
        }
        out.push(0xE007F)
        return String.fromCodePoint.apply(String, out)
    }

    function shellQuote(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // Called when the playing song changes. Country belongs to the album, so this
    // only does work when the album itself changed, and only if that album has
    // never been asked about before.
    function notePlayingSong(file) {
        var dir = root.albumDirOf(file)
        if (dir === "" || dir === root.playingCountryDir) return
        root.playingCountryDir = dir
        var known = root.countryCache[dir]
        if (known !== undefined && known !== null) {
            root.playingCountry = String(known)
            return
        }
        root.playingCountry = ""
        root.probeCountry(dir, root.writablePath(file))
    }

    // Reads the country off the file that is playing. It is an album-level tag, so
    // any track answers for the whole album and there is no need to go looking for
    // a better one.
    //
    // Only one probe runs at a time. The collector reports the answer through the
    // shared countryProbeDir, so starting a second probe before the first has been
    // read would attribute the first album's output to the second -- and cache it
    // that way. A request that arrives while one is running is queued instead.
    function probeCountry(dir, path) {
        if (path === "") return
        if (root.countryBusy) {
            root.countryQueue.push({ dir: dir, path: path })
            return
        }
        root.startCountryProbe(dir, path)
    }

    function startCountryProbe(dir, path) {
        var isFlac = path.toLowerCase().slice(-5) === ".flac"
        var cmd = isFlac
            ? "metaflac --export-tags-to=- " + root.shellQuote(path) + " 2>/dev/null"
            : "mid3v2 -l " + root.shellQuote(path) + " 2>/dev/null"
        root.countryBusy = true
        root.countryProbeDir = dir
        countryProbe.command = ["sh", "-c", cmd]
        countryProbe.running = true
    }

    function runQueuedCountry() {
        if (root.countryBusy || root.countryQueue.length === 0) return
        var job = root.countryQueue.shift()
        root.startCountryProbe(job.dir, job.path)
    }

    property string countryProbeDir: ""
    property bool countryBusy: false
    property var countryQueue: []

    // Pulls the country out of whichever reader produced the output. Returns ""
    // for "no country here", which is a legitimate answer and gets cached as one
    // so an untagged album is not probed again on every play.
    //
    // Both spellings are matched with the separators squeezed out, because the
    // Picard name is words ("MusicBrainz Album Release Country") while the Vorbis
    // field is one token (MUSICBRAINZ_ALBUMRELEASECOUNTRY). A TXXX is only
    // answered once its description has been checked: a library carries dozens of
    // them, and taking the first would return whatever frame happened to sort
    // first.
    function parseCountry(output) {
        var lines = String(output === undefined || output === null ? "" : output).split("\n")
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim()
            var eq = line.indexOf("=")
            if (eq < 0) continue
            var head = line.slice(0, eq).trim()
            var rest = line.slice(eq + 1)
            var candidate = ""

            if (head.toUpperCase() === "TXXX") {
                // "TXXX=<description>=<value>"
                var cut = rest.indexOf("=")
                if (cut < 0) continue
                var desc = rest.slice(0, cut).replace(/[\s_-]/g, "").toUpperCase()
                if (desc.indexOf("RELEASECOUNTRY") < 0) continue
                candidate = rest.slice(cut + 1).trim()
            } else if (head.replace(/[\s_-]/g, "").toUpperCase().indexOf("RELEASECOUNTRY") >= 0) {
                candidate = rest.trim()
            } else continue

            if (candidate !== "") return candidate
        }
        return ""
    }

    // MPD presents a cue sheet as one virtual song per track, under a path that
    // does not exist on disk: "<album>.cue/track0001". The audio is a single file
    // the cue points at, and per-track tags for it live inside the cue sheet, not
    // in a file mid3v2 or metaflac can open. Those are reported as skipped rather
    // than guessed at.
    function writablePath(file) {
        var rel = String(file === undefined || file === null ? "" : file)
        if (rel === "") return ""
        if (/\.cue\/track\d+$/i.test(rel)) return ""
        return root.musicDir + "/" + rel
    }

    property var tagQueue: []
    property var tagResult: null
    // Whole writes, queued: the editor can be dismissed mid-write (Escape is
    // allowed while busy) and reopened, and a second Save must not replace the
    // queue already in flight -- that dropped the remaining files and stranded
    // the first callback, so its editor stayed on "Writing...".
    property var tagRequestQueue: []
    property var tagCurrent: null

    // One song at a time. A whole-artist edit can be several hundred files, and
    // launching that many taggers at once would be a fork bomb with a music
    // library attached.
    // Carries the relative path as well as the absolute one: the write needs the
    // absolute path, but the country cache is keyed by the album directory MPD
    // calls the file, and losing that at the point of writing would mean guessing
    // it back out of an absolute path.
    //
    // `common` goes to every file. `perFile`, keyed by the relative path, supplies
    // a file's own values, but a shared (user-touched) value beats it -- see
    // mergeTags. That is how a whole-album lookup lands each track's own title and
    // number, which the editor's one-value-per-field model cannot express: the
    // album-level fields stay shared, the track-level ones differ.
    function applyTagsSet(entries, common, perFile, onDone) {
        var queue = []
        var skipped = 0
        for (var i = 0; i < entries.length; i++) {
            var rel = String(entries[i].file)
            var path = root.writablePath(rel)
            if (path === "") { skipped++; continue }
            queue.push({ file: rel, path: path, tags: root.mergeTags(common, perFile, rel) })
        }
        root.tagRequestQueue.push({
            queue: queue,
            skipped: skipped,
            onDone: typeof onDone === "function" ? onDone : null
        })
        root.runNextTagRequest()
    }

    function runNextTagRequest() {
        if (root.tagCurrent !== null || root.tagRequestQueue.length === 0) return
        var req = root.tagRequestQueue.shift()
        root.tagCurrent = req
        root.tagQueue = req.queue
        root.tagResult = { written: 0, failed: 0, skipped: req.skipped }
        if (root.tagQueue.length === 0) {
            root.finishTags()
            return
        }
        root.runNextTag()
    }

    // Per-file first, shared second: a value the user typed into a shared field
    // is a deliberate override and must beat a matched per-track one.
    function mergeTags(common, perFile, file) {
        var out = {}
        var extra = perFile ? perFile[file] : undefined
        if (extra) for (var e in extra) out[e] = extra[e]
        for (var k in common) out[k] = common[k]
        return out
    }

    // Returns an argument list, undefined when there was nothing to write, or null
    // when this file is not a format a tagger here can open. The two are different
    // answers: the first means the file already says what was asked of it, the
    // second means it was never touched.
    function tagCommand(item) {
        var path = item.path
        var tags = item.tags || {}
        var lower = path.toLowerCase()
        var isMp3 = lower.slice(-4) === ".mp3"
        var isFlac = lower.slice(-5) === ".flac"
        if (!isMp3 && !isFlac) return null

        var args = [isMp3 ? "mid3v2" : "metaflac"]
        var handled = 0
        var keys = Object.keys(tags)
        for (var k = 0; k < keys.length; k++) {
            var key = keys[k]
            var value = tags[key] === undefined || tags[key] === null
                ? "" : String(tags[key]).trim()

            if (isMp3) {
                var txxx = root.id3Txxx[key]
                if (txxx) {
                    // mid3v2 addresses a TXXX by description, so writing and
                    // clearing both name the frame and let the value be empty:
                    // `--delete-frames=TXXX` would have taken the ReplayGain and
                    // MusicBrainz frames on the way out.
                    args.push("--TXXX", txxx + ":" + value)
                    handled++
                    continue
                }
                var frame = root.id3Frames[key]
                if (!frame) continue
                if (value === "") args.push("--delete-frames=" + frame)
                else args.push("--" + frame, value)
                handled++
            } else {
                var fields = root.vorbisFieldsFor(key)
                for (var f = 0; f < fields.length; f++) {
                    // Vorbis comments allow a field to repeat, and metaflac's
                    // --set-tag appends rather than replaces: without the remove
                    // first, every edit left the old value behind as a second copy
                    // of the same tag and readers picked whichever they liked.
                    args.push("--remove-tag=" + fields[f])
                    if (value !== "") args.push("--set-tag=" + fields[f] + "=" + value)
                    handled++
                }
            }
        }
        if (handled === 0) return undefined
        args.push(path)
        return args
    }

    function runNextTag() {
        if (root.tagQueue.length === 0) {
            root.finishTags()
            return
        }
        var item = root.tagQueue.shift()
        var args = root.tagCommand(item)
        if (args === null) {
            // Nothing here can be tagged: report it rather than quietly counting
            // it as a success, which would claim files were rewritten that were
            // not even opened.
            root.tagResult.skipped++
            Qt.callLater(root.runNextTag)
            return
        }
        if (args === undefined) {
            root.tagResult.written++
            Qt.callLater(root.runNextTag)
            return
        }
        root.tagCurrentDir = root.albumDirOf(item.file)
        root.tagCurrentTags = item.tags
        tagger.command = args
        tagger.running = true
    }

    property string tagCurrentDir: ""
    property var tagCurrentTags: ({})

    // The cache is the only record MPD cannot keep for us, so it moves when the
    // file does. Keyed by album directory because that is the level country is
    // meaningful at.
    function rememberCountry(dir, value) {
        if (dir === "") return
        var code = value === undefined || value === null ? "" : String(value).trim().toUpperCase()
        // Copied rather than edited in place: a var property holding a JS object
        // reports no change when a key is added to it, so the flag in the panel and
        // the editor's country field would keep showing the previous value.
        var map = {}
        for (var key in root.countryCache) map[key] = root.countryCache[key]
        if (code === "") delete map[dir]
        else map[dir] = code
        root.countryCache = map
        root.countriesDirty = true
        if (dir === root.playingCountryDir) root.playingCountry = code
    }

    function finishTags() {
        if (root.countriesDirty) {
            root.countriesDirty = false
            root.saveCountries()
        }
        // Retagging changes mtimes, so MPD's database has to be told before the
        // tree can show the new values. The database idle event this provokes is
        // what reloads the library, so there is nothing to do here beyond asking.
        if (root.tagResult.written > 0) root.send("update")
        var req = root.tagCurrent
        root.tagCurrent = null
        var cb = req ? req.onDone : null
        if (cb) cb(root.tagResult)
        Qt.callLater(root.runNextTagRequest)
    }

    Process {
        id: tagger
        running: false
        command: []
        onExited: function (exitCode) {
            // A non-zero exit means the tool refused the file -- permissions, a
            // truncated tag, a file that is not really the format its name claims.
            // Counted and carried on with; one bad file must not abandon the rest
            // of the album.
            if (exitCode === 0) {
                root.tagResult.written++
                // Only once the write actually succeeded: recording a country for
                // a file the tagger refused would put a flag next to a track that
                // does not carry one.
                if (root.tagCurrentTags && root.tagCurrentTags.country !== undefined) {
                    root.rememberCountry(root.tagCurrentDir, root.tagCurrentTags.country)
                }
            } else root.tagResult.failed++
            Qt.callLater(root.runNextTag)
        }
    }

    // ---- lookup ----
    //
    // One album at a time is looked up on MusicBrainz by a bundled helper, which
    // hands back the matched release, each track's matched title and number, and
    // a downloaded front cover -- all as JSON, to the service, which passes it on
    // to the editor to pre-fill. Nothing is written here: the editor shows the
    // match, and Save takes the existing embed-only path.
    // One lookup subprocess at a time, queued, like the cover fetch below. A
    // second request while one runs would otherwise overwrite the single
    // on-done slot and hand the first request's JSON to the second caller --
    // and the editor would accept that result, because it is the current
    // session, so the wrong album's match would land in the fields.
    property var lookupQueue: []
    property var lookupCurrent: null

    // extras/lookup.py, resolved relative to this file so the plugin stays
    // portable. Quickshell serves its files under the qs:// scheme, so the
    // scheme is stripped to leave a plain path the taggers can open.
    readonly property string lookupScript: {
        var url = String(Qt.resolvedUrl("extras/lookup.py"))
        var path = url.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, "")
        try { path = decodeURIComponent(path) } catch (e) {}
        return path
    }

    // entries is the editor's selection; an optional mbid re-fetches one
    // candidate (cycling matches) instead of searching again.
    //
    // The argv is built here, at request time, and carried on the job: a queued
    // request must not be re-resolved against a selection that changed while it
    // waited.
    function lookUpAlbum(entries, mbid, onDone) {
        var job = {
            onDone: typeof onDone === "function" ? onDone : null,
            args: null,
            error: null
        }
        var files = []
        for (var i = 0; i < entries.length; i++) {
            var rel = String(entries[i].file)
            if (root.writablePath(rel) === "") continue
            files.push(rel)
        }
        if (files.length === 0) {
            job.error = { status: "error", message: "No taggable files here" }
        } else {
            var args = ["python3", root.lookupScript, "--music-dir", root.musicDir]
            if (mbid !== undefined && mbid !== null && String(mbid) !== "") {
                args.push("--release", String(mbid))
            }
            for (var f = 0; f < files.length; f++) {
                args.push("--file", files[f])
            }
            job.args = args
        }
        root.lookupQueue.push(job)
        root.runNextLookUp()
    }

    function runNextLookUp() {
        if (lookup.running || root.lookupQueue.length === 0) return
        var job = root.lookupQueue.shift()
        if (job.error) {
            if (job.onDone) job.onDone(job.error)
            Qt.callLater(root.runNextLookUp)
            return
        }
        root.lookupCurrent = job
        lookup.command = job.args
        lookup.running = true
    }

    function finishLookUp(result) {
        var job = root.lookupCurrent
        root.lookupCurrent = null
        var cb = job ? job.onDone : null
        if (cb) cb(result)
        // Deferred, like the cover and tagger queues: a callback can ask for the
        // next lookup synchronously while this process still reads as running,
        // and stepping the queue here would find it busy and stop.
        Qt.callLater(root.runNextLookUp)
    }

    Process {
        id: lookup
        running: false
        command: []
        stdout: StdioCollector { id: lookupOut }
        stderr: StdioCollector { id: lookupErr }
        onExited: function (exitCode) {
            var text = lookupOut.text || ""
            if (exitCode !== 0 || text.trim() === "") {
                var reason = (lookupErr.text || "").trim().split("\n")[0]
                root.finishLookUp({
                    status: "error",
                    message: reason !== "" ? reason : "Lookup failed"
                })
                return
            }
            var parsed = null
            try { parsed = JSON.parse(text) } catch (e) { parsed = null }
            if (!parsed || typeof parsed !== "object") {
                root.finishLookUp({ status: "error", message: "Unreadable lookup result" })
                return
            }
            root.finishLookUp(parsed)
        }
    }

    // ---- display cover fetch ----
    //
    // The playback path's own cover source, separate from the editor's lookup: an
    // album with nothing beside the tracks and nothing inside them asks here for
    // a display-sized cover from the stores. No MusicBrainz, so this runs even
    // where the tagging libraries are absent, and nothing is written into the
    // music -- the answer lands in the covers cache and is deleted like any other
    // derived file.
    //
    // One subprocess at a time, queued: the panel and the editor's preview can
    // both want a cover at once, and the helper is not built to be interrupted.
    property var coverFetchQueue: []
    property var coverFetchCurrent: null

    // opts: { artist, album, year, tracks, size, out }. onDone gets the helper's
    // parsed JSON: status ok with cover/coverSource/coverWidth/coverHeight, or
    // status error with a message.
    function fetchAlbumCover(opts, onDone) {
        root.coverFetchQueue.push({
            opts: opts,
            onDone: typeof onDone === "function" ? onDone : null
        })
        root.runNextCoverFetch()
    }

    function runNextCoverFetch() {
        if (coverFetch.running || root.coverFetchQueue.length === 0) return
        var job = root.coverFetchQueue.shift()
        root.coverFetchCurrent = job
        var opts = job.opts
        if (!opts || !opts.out) {
            root.finishCoverFetch({ status: "error", message: "No destination" })
            return
        }
        var args = ["python3", root.lookupScript, "--cover-only",
                    "--size", String(opts.size || 600),
                    "--cover-out", String(opts.out)]
        if (opts.artist) args.push("--artist", String(opts.artist))
        if (opts.album) args.push("--album", String(opts.album))
        if (opts.year) args.push("--year", String(opts.year))
        if (opts.tracks) args.push("--tracks", String(opts.tracks))
        coverFetch.command = args
        coverFetch.running = true
        // The helper reaches the stores over the network, and a black-holed
        // connection would leave this process running forever -- with it the whole
        // queue, so every later album's cover waits behind a fetch that will never
        // answer, and the album that asked is held off the placeholder for good.
        // Kill it and fail the job; that album keeps its placeholder and the queue
        // moves on to the next.
        coverFetchTimeout.restart()
    }

    function finishCoverFetch(result) {
        // A timeout kills the process and finishes the job; the process's own
        // onExited may still fire afterwards. The job being gone is what makes that
        // second call a no-op rather than stepping the queue twice.
        var job = root.coverFetchCurrent
        if (!job) return
        coverFetchTimeout.stop()
        root.coverFetchCurrent = null
        var cb = job.onDone
        if (cb) cb(result)
        // Deferred, like the tagger queue: a callback can ask for the next fetch
        // synchronously while this process still reads as running, and stepping
        // the queue here would then find it busy and stop. Handing it to the
        // event loop lets `running` settle first.
        Qt.callLater(root.runNextCoverFetch)
    }

    // Bounds a fetch that would otherwise run forever. A store that accepts the
    // connection and then never answers would leave the process alive and the
    // queue blocked behind it; this is the only thing that can end it. Generous
    // on purpose: a slow but honest fetch may make several requests in one run.
    Timer {
        id: coverFetchTimeout
        interval: 60000
        repeat: false
        onTriggered: {
            if (!root.coverFetchCurrent) return
            coverFetch.running = false
            root.finishCoverFetch({ status: "error", message: "Cover fetch timed out" })
        }
    }

    Process {
        id: coverFetch
        running: false
        command: []
        stdout: StdioCollector { id: coverFetchOut }
        stderr: StdioCollector { id: coverFetchErr }
        onExited: function (exitCode) {
            var text = coverFetchOut.text || ""
            var parsed = null
            try { parsed = JSON.parse(text) } catch (e) { parsed = null }
            if (exitCode !== 0 || !parsed || typeof parsed !== "object") {
                root.finishCoverFetch({ status: "error", message: "Cover fetch failed" })
                return
            }
            root.finishCoverFetch(parsed)
        }
    }

    // ---- cover art ----
    //
    // A cover lives in the files. Setting one embeds the image into every track
    // and leaves the album folder untouched; clearing strips the embedded picture
    // back out. The cached extraction of the old picture is dropped either way, so
    // the probe re-reads what the file now holds instead of what it held before.
    //
    // One queue of argv commands, no shell: a filename with a quote in it must not
    // be able to change what runs.
    signal coversChanged()

    // What the last cover edit did and to which albums, so the panel can tell a
    // deliberate removal from an album that never had art at all and leave the
    // cleared album empty rather than fetching a cover straight back into it.
    property string lastCoverAction: ""
    property var lastCoverDirs: []

    // The user's cover decision per album directory, remembered across restarts.
    // The album folder is never written to, so on an album that already has a
    // sidecar image the embedded picture the editor just set would otherwise be
    // hidden by it -- the editor's preview would show the new cover and Save
    // would flip straight back to the old one. "embedded" tells the probe to show
    // the picture inside the files and ignore the sidecar; "none" tells it to
    // show no art at all, so a deliberate removal is not filled back in by the
    // sidecar or by the stores. Kept beside the country cache for the same
    // reason: it is derived from a user action and should survive a restart.
    readonly property string coverOverridePath: root.stateDir + "/coveroverrides.json"
    property var coverOverrides: ({})
    property bool coverOverridesReady: false
    property bool coverOverridesDirty: false

    // "" when this album has no remembered decision and the probe should behave
    // as it always has.
    function coverOverrideFor(dir) {
        if (!dir) return ""
        var value = root.coverOverrides[dir]
        return value === undefined || value === null ? "" : String(value)
    }

    // Rebuilt rather than edited in place, for the same reason every other map
    // here is: adding a key to the object a var property holds reports no change,
    // so the probe would keep reading the value from before the edit.
    function rememberCoverOverride(dir, value) {
        if (dir === undefined || dir === null || dir === "") return
        var map = {}
        for (var key in root.coverOverrides) map[key] = root.coverOverrides[key]
        if (value === "") delete map[dir]
        else map[dir] = String(value)
        root.coverOverrides = map
        root.coverOverridesDirty = true
        root.saveCoverOverrides()
    }

    function loadCoverOverrides() {
        var raw = coverOverrideFile.text()
        if (raw === undefined || raw === null || raw === "") return
        try {
            var parsed = JSON.parse(raw)
            if (parsed && typeof parsed === "object") root.coverOverrides = parsed
        } catch (e) {
            // A malformed map is not worth failing over; the albums it held simply
            // fall back to the probe's normal order.
        }
    }

    function saveCoverOverrides() {
        // The state directory has to exist first; the mkdir process sets the flag
        // and flushes anything set before it finished.
        if (!root.coverOverridesReady) return
        root.coverOverridesDirty = false
        coverOverrideFile.setText(JSON.stringify(root.coverOverrides))
    }

    readonly property string coverCacheDir: root.stateDir + "/covers"

    // Shared with CoverArt.qml through Covers.js, so a cover cleared here deletes
    // the same cached file that component loads.
    function cachedCover(dir) {
        return root.coverCacheDir + "/" + Covers.fileName(dir)
    }

    // The downloaded counterpart of the extraction, named by the same shared stem
    // with its own suffix. A cover edit has to drop this too: the override that
    // says "show the embedded picture" (or "show nothing") makes the cached
    // download unreachable, and leaving it behind is a file no probe will ever
    // load again.
    function onlineCover(dir) {
        return root.coverCacheDir + "/" + Covers.onlineFileName(dir)
    }

    // The probe caches an extraction of a track's embedded picture and falls back
    // to it before extracting again, so a cover changed here would otherwise keep
    // showing the picture the file had before. Dropping the cache is what makes the
    // probe look again. Both derived files go: the extraction and the store
    // download, each a stale claim about artwork the edit has just replaced.
    function clearCachedCoverCommand(dir) {
        return ["rm", "-f", root.cachedCover(dir), root.onlineCover(dir)]
    }

    // The picture frames, per format: a list of commands, or null when the file is
    // a format no tagger here can open.
    function embeddedCoverCommands(path, image) {
        var lower = path.toLowerCase()
        if (lower.slice(-5) === ".flac") {
            // metaflac will not mix a major operation with shorthands, and
            // importing over an existing picture block leaves two -- so a replace
            // is a remove, then an import, as two calls in that order. The remove
            // is a no-op when there is no block, so it is always safe to run.
            var flac = [["metaflac", "--remove", "--block-type=PICTURE", path]]
            if (image !== "") {
                flac.push(["metaflac", "--import-picture-from=" + image, path])
            }
            return flac
        }
        if (lower.slice(-4) === ".mp3") {
            // mid3v2's -p replaces the APIC rather than appending, and
            // --delete-frames=APIC clears every one; neither needs a check first,
            // both being no-ops when no picture is present.
            if (image === "") return [["mid3v2", "--delete-frames=APIC", path]]
            return [["mid3v2", "-p", image, path]]
        }
        return null
    }

    property var coverQueue: []
    property var coverResult: null
    property var coverOnDone: null

    // action is "set" (with an image path) or "remove".
    function applyCover(entries, action, image, onDone) {
        var dirs = []
        var seen = {}
        var files = []
        var skipped = 0
        for (var i = 0; i < entries.length; i++) {
            var rel = String(entries[i].file)
            var path = root.writablePath(rel)
            if (path === "") { skipped++; continue }
            files.push(path)
            var dir = root.albumDirOf(rel)
            if (dir !== "" && seen[dir] === undefined) { seen[dir] = true; dirs.push(dir) }
        }

        var write = action === "set" && image !== "" && image !== undefined && image !== null
        var queue = []
        if (write || action === "remove") {
            // The decision is remembered per album before anything runs, so the
            // probe that follows `coversChanged` reads the new intent rather than
            // the sidecar it would otherwise settle on. A "set" says the embedded
            // picture is the one to show; a "remove" says show nothing. Neither
            // writes to the album folder.
            for (var od = 0; od < dirs.length; od++) {
                root.rememberCoverOverride(dirs[od], write ? "embedded" : "none")
            }
            // One cache per directory, since the extraction is an album-level fact;
            // dropping it lets the probe pick up the picture the files now hold.
            for (var d = 0; d < dirs.length; d++) {
                queue.push(root.clearCachedCoverCommand(dirs[d]))
            }
            for (var f = 0; f < files.length; f++) {
                var cmds = root.embeddedCoverCommands(files[f], write ? image : "")
                if (cmds === null) continue
                for (var c = 0; c < cmds.length; c++) queue.push(cmds[c])
            }
        }

        root.coverResult = { changed: queue.length > 0, failed: 0, skipped: skipped, dirs: dirs }
        root.coverOnDone = typeof onDone === "function" ? onDone : null
        // Remembered here, not in finishCover, so the panel reads the action that
        // goes with the albums in `dirs` even if another edit arrives first.
        root.lastCoverAction = write ? "set" : (action === "remove" ? "remove" : "")
        root.lastCoverDirs = dirs
        if (queue.length === 0) { root.finishCover(); return }
        root.coverQueue = queue
        root.runNextCover()
    }

    function runNextCover() {
        if (root.coverQueue.length === 0) { root.finishCover(); return }
        coverTagger.command = root.coverQueue.shift()
        coverTagger.running = true
    }

    function finishCover() {
        var result = root.coverResult
        // Changed files need an `update` before MPD's tree can show them, and the
        // panel needs telling regardless: its probe keys on the album directory,
        // which has not changed, so it would not otherwise notice the new cover.
        // A failure in one command still leaves the others done, so neither is
        // held back by it; the count is what the editor reports.
        if (result.changed) {
            root.send("update")
            root.coversChanged()
        }
        var cb = root.coverOnDone
        root.coverOnDone = null
        if (cb) cb(result)
    }

    Process {
        id: coverTagger
        running: false
        command: []
        onExited: function (exitCode) {
            // A refused file -- permissions, a truncated tag -- is counted and the
            // rest carried on with, the same as the tagger above.
            if (exitCode !== 0) root.coverResult.failed++
            Qt.callLater(root.runNextCover)
        }
    }

    // ---- country cache ----
    //
    // MPD cannot be asked for a country, so the values are read from the files
    // themselves with the same tools that write them. One probe per album, on the
    // album that starts playing, kept on disk afterwards -- including the
    // negative answer, so an album nobody tagged is not re-read on every play.
    FileView {
        id: countryFile
        path: root.countryStatePath
        // Only this file edits it, so watching it would just bounce our own
        // writes back at us.
        watchChanges: false
        printErrors: false
        // Blocking, so the synchronous read at startup sees anything already
        // there; atomic, so a reader never catches a half-written map and treats
        // the whole cache as unreadable.
        blockLoading: true
        blockWrites: !root.countriesDirReady
        atomicWrites: true
    }

    // The per-album cover decisions, kept the same way and for the same reason as
    // the country cache. Loading is blocking so the synchronous read at startup
    // has the map in hand before the first probe runs.
    FileView {
        id: coverOverrideFile
        path: root.coverOverridePath
        watchChanges: false
        printErrors: false
        blockLoading: true
        blockWrites: !root.coverOverridesReady
        atomicWrites: true
    }

    property bool countriesDirReady: false
    property bool countriesSavePending: false

    Process {
        id: countryMkdir
        command: ["mkdir", "-p", root.stateDir]
        onExited: {
            root.countriesDirReady = true
            root.coverOverridesReady = true
            // A decision taken before the directory existed is written now that
            // there is somewhere to put it.
            if (root.coverOverridesDirty) root.saveCoverOverrides()
            // A country probe that finished before the directory existed held its
            // write off; flush it now rather than losing the answer for the
            // session.
            if (root.countriesSavePending) root.saveCountries()
            // The state directory exists, so the covers directory under it is now
            // worth pruning (see coverPrune).
            coverPrune.running = true
        }
    }

    // Cached covers accumulate one file per album played -- an ffmpeg extraction,
    // a store download, or both -- and nothing removes one but a deliberate cover
    // edit, so an album played once and never revisited leaves its files behind
    // for good. Pruned here by age: an album unplayed for half a year regenerates
    // its cover in a moment if it comes back, and until then the directory stays
    // bounded. `find` in argv form and scoped to the plugin's own cache directory,
    // so there is nothing to quote and nowhere else it can reach. Best-effort: a
    // missing directory (nothing cached yet) just makes it a no-op.
    //
    // The extraction and the download share a stem and differ only by suffix, so
    // one age test drops both.
    Process {
        id: coverPrune
        running: false
        command: ["find", root.coverCacheDir, "-type", "f", "-mtime", "+180", "-delete"]
    }

    function loadCountries() {
        var raw = countryFile.text()
        if (raw === undefined || raw === null || raw === "") return
        try {
            var parsed = JSON.parse(raw)
            if (parsed && typeof parsed === "object") root.countryCache = parsed
        } catch (e) {
            // A malformed cache is not worth failing over: the alternative is
            // re-reading every album once, which is what it is for.
        }
    }

    function saveCountries() {
        // Held off until mkdir has made the directory, rather than written and
        // lost: FileView cannot create parents, and a write into a missing
        // directory fails under printErrors: false. The mkdir process flushes
        // this when it finishes.
        if (!root.countriesDirReady) {
            root.countriesSavePending = true
            return
        }
        root.countriesSavePending = false
        countryFile.setText(JSON.stringify(root.countryCache))
    }

    Process {
        id: countryProbe
        running: false
        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                var code = root.parseCountry(this.text)
                root.rememberCountry(root.countryProbeDir, code)
                // Saved here rather than left dirty for the next tag write: most
                // albums are read by a probe and never edited, so waiting for an
                // edit would mean re-reading every one of them on every start.
                root.saveCountries()
                // The output is read, so the slot is free; take up the next album
                // waiting its turn, if any.
                root.countryBusy = false
                root.runQueuedCountry()
            }
        }
    }

    // Track numbers arrive as "3" or "3/12"; discs as "1" or "1/2".
    function leadingInt(value) {
        var m = String(value).match(/^\s*(\d+)/)
        return m === null ? null : parseInt(m[1], 10)
    }

    function byName(x, y) {
        var a = String(x.name).toLowerCase()
        var b = String(y.name).toLowerCase()
        return a < b ? -1 : (a > b ? 1 : 0)
    }

    // A Date tag is "2011", "2011-09" or "2011-09-13"; anything past the year is
    // ignored. A tag without a four-digit year reads as unknown.
    function yearOf(value) {
        if (value === undefined || value === null) return null
        var m = String(value).match(/(\d{4})/)
        return m === null ? null : parseInt(m[1], 10)
    }

    // One year per album: the most common Date among its tracks, so a single
    // mistagged track cannot move the album. Ties go to the earlier year.
    function albumYear(tracks) {
        var counts = {}
        for (var i = 0; i < tracks.length; i++) {
            var y = yearOf(tracks[i].date)
            if (y === null) continue
            counts[y] = (counts[y] || 0) + 1
        }
        var best = null
        var bestCount = 0
        for (var key in counts) {
            var count = counts[key]
            var value = parseInt(key, 10)
            if (count > bestCount || (count === bestCount && (best === null || value < best))) {
                best = value
                bestCount = count
            }
        }
        return best
    }

    // Oldest first, undated albums after every dated one and then by name, so the
    // undated tail is still alphabetical rather than arbitrary.
    function compareAlbums(x, y) {
        var xy = (x.year === null || x.year === undefined) ? Number.MAX_SAFE_INTEGER : x.year
        var yy = (y.year === null || y.year === undefined) ? Number.MAX_SAFE_INTEGER : y.year
        if (xy !== yy) return xy - yy
        return byName(x, y)
    }

    function compareTracks(x, y) {
        var dx = x.disc === null ? 1 : x.disc
        var dy = y.disc === null ? 1 : y.disc
        if (dx !== dy) return dx - dy
        var tx = x.track === null ? Number.MAX_SAFE_INTEGER : x.track
        var ty = y.track === null ? Number.MAX_SAFE_INTEGER : y.track
        if (tx !== ty) return tx - ty
        var a = String(x.title || "").toLowerCase()
        var b = String(y.title || "").toLowerCase()
        return a < b ? -1 : (a > b ? 1 : 0)
    }

    // The tree flattened into the order the user sees it. Activating a track
    // enqueues this suffix, which is how playback continues past the end of an
    // album without this player keeping a queue of its own.
    function filesFrom(artistIndex, albumIndex, trackIndex) {
        var out = []
        for (var a = artistIndex; a < root.artists.length; a++) {
            var albums = root.artists[a].albums
            var firstAlbum = a === artistIndex ? albumIndex : 0
            for (var b = firstAlbum; b < albums.length; b++) {
                var tracks = albums[b].tracks
                var firstTrack = (a === artistIndex && b === albumIndex) ? trackIndex : 0
                for (var t = firstTrack; t < tracks.length; t++) out.push(tracks[t].file)
            }
        }
        return out
    }

    // The same suffix idea, but stopping at the end of the album. MPD's repeat
    // playlist repeats whatever the queue holds, and the queue is normally the
    // whole remaining library, so "repeat album" has to mean narrowing the queue,
    // not just raising MPD's repeat flag.
    function albumFilesAfter(artistIndex, albumIndex, trackIndex) {
        var out = []
        var artist = root.artists[artistIndex]
        if (!artist) return out
        var album = artist.albums[albumIndex]
        if (!album) return out
        var tracks = album.tracks
        for (var t = trackIndex; t < tracks.length; t++) out.push(tracks[t].file)
        return out
    }

    // The tracks that follow the playing album. Stepping out of album mode has to
    // put the rest of the library back on the queue, and this is the part that was
    // trimmed away: filesFrom starts at the playing track, so its first
    // albumFilesAfter entries are the album's own remainder -- already in the queue
    // -- and everything past them is what has to be appended.
    function filesAfterAlbum(artistIndex, albumIndex, trackIndex) {
        var all = root.filesFrom(artistIndex, albumIndex, trackIndex)
        return all.slice(root.albumFilesAfter(artistIndex, albumIndex, trackIndex).length)
    }

    // Where the playing song sits in the tree, so a queue can be rebuilt around
    // it. The panel's own caret can point somewhere else entirely, so this
    // always works from what MPD is actually playing rather than from the
    // selection. Returns null when the song is not in the library at all, which
    // is the signal to leave the queue alone.
    function locateCurrent() {
        if (!root.current || root.current.file === undefined) return null
        var loc = root.trackLocations[String(root.current.file)]
        return loc === undefined ? null : loc
    }

    // ---- playback ----

    function quote(value) {
        return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
    }

    // The flags a mode leaves on MPD. Album repeat (1) is not expressible by
    // either: MPD's repeat flag repeats the whole queue, and a queue has no
    // album in it, so album mode keeps both off and narrows the queue instead
    // (see applyRepeatMode). Mode 2 is the one MPD can say -- repeat with single
    // is documented as repeating the current song rather than the queue.
    function modeFlags(mode) {
        return mode === 2 ? ["repeat 1", "single 1"] : ["repeat 0", "single 0"]
    }

    // Replaces the queue with everything below the activated track and starts
    // there. playFilesScoped already builds the clear/single/consume + add +
    // play 0 list, so this is the same thing with no resume point -- but the
    // current mode's flags are appended, because the rebuild resets `single` and
    // repeat-song would otherwise come out of it as repeat-all.
    function playFiles(files) {
        root.playFilesScoped(files, 0, root.modeFlags(root.repeatMode))
    }

    function playArtistAndBelow(artistIndex, albumIndex, trackIndex) {
        // Album mode means the queue is the playing album and nothing past it, so
        // activating a track must narrow to the album too. Going through filesFrom
        // here would put the whole library back in the queue and quietly undo the
        // narrowing that makes the mode "album" rather than "everything".
        if (root.repeatMode === 1) {
            root.albumLoopPoint = { artist: artistIndex, album: albumIndex }
            root.playFilesScoped(root.albumFilesAfter(artistIndex, albumIndex, trackIndex), 0, root.modeFlags(1))
            return
        }
        root.playFiles(root.filesFrom(artistIndex, albumIndex, trackIndex))
    }

    // Simple commands. The response is not interesting; the idle subscription
    // delivers the resulting state, so none of these read anything back.
    function command(name) {
        root.send(name, function (lines, error) {
            if (error) root.setError(name + ": " + error)
        })
    }

    // As command, for a short run of them. repeat and single belong together in
    // one transaction, or a refresh between the two halves could read the flags
    // mid-change and announce the wrong mode.
    function commandList(commands) {
        root.sendList(commands, function (lines, error) {
            if (error) root.setError("queue: " + error)
        })
    }

    function togglePlay() {
        root.command(root.status.state === "play" ? "pause 1" : "play")
    }

    // Returns the absolute position sent, or -1 when nothing was sent. The panel
    // re-anchors its bar to this value, so a declined seek has to be visible to
    // the caller rather than a silent no-op.
    function seekFraction(fraction) {
        if (root.current.Id === undefined || !root.status.duration) return -1
        var target = Math.max(0, Math.round(fraction * root.status.duration))
        root.command("seekid " + root.current.Id + " " + target)
        return target
    }

    function setVolume(value) {
        root.command("setvol " + Math.max(0, Math.min(100, Math.round(value))))
    }

    function toggleRandom() {
        root.command("random " + (root.status.random ? 0 : 1))
    }

    // As playFilesScoped, but takes the resume point from MPD rather than from the
    // caller. The panel's own running estimate of the position is an
    // interpolation between status reads and can be well off -- it only gets
    // corrected when MPD happens to send an event -- so a rebuild that trusted
    // it would drop the listener back to the wrong place. Reading status first
    // costs one round trip and puts the song back where it actually was. The
    // same read tells us whether it was playing, so a paused player stays
    // paused instead of being kicked into playback by the rebuild.
    function replaceQueueResuming(files, trailing) {
        if (!files || files.length === 0) return false
        root.send("status", function (lines, error) {
            var at = 0
            var playing = true
            if (!error) {
                var st = root.toMap(lines)
                at = Number(st.elapsed) || 0
                playing = st.state === "play"
            }
            var tail = trailing ? trailing.slice(0) : []
            if (!playing) tail.push("pause 1")
            root.playFilesScoped(files, at, tail)
        })
        return true
    }

    // Replaces the queue and resumes resumeAt seconds into the first file, then runs
    // whatever trailing commands were appended. Repeat-album needs this rather
    // than playFiles: MPD's repeat flag repeats whatever the queue holds, so
    // narrowing the queue is the only way "repeat album" can mean album, and a
    // bare clear+add would drop the listener back to 0:00 mid-album.
    function playFilesScoped(files, resumeAt, trailing) {
        if (!files || files.length === 0) return false
        var commands = ["clear", "single 0", "consume 0"]
        for (var i = 0; i < files.length; i++) commands.push("add " + root.quote(files[i]))
        commands.push("play 0")
        // seekcur, not seek: `seek` takes a song id and a time, so `seek 90` is a
        // wrong-arity error -- and MPD aborts the rest of a command list on the
        // first failure, which silently ate the repeat command queued after it.
        if (resumeAt > 0) commands.push("seekcur " + Math.round(resumeAt))
        for (var j = 0; j < trailing.length; j++) commands.push(trailing[j])
        root.sendList(commands, function (lines, error) {
            if (error) root.setError("queue: " + error)
            else root.refreshState()
        })
        return true
    }

    // Adds files to the end of the queue, then runs whatever trailing commands
    // were appended, without rebuilding anything. Appending to a queue that is
    // playing does not interrupt the current song, which is what makes leaving
    // album mode silent; playFilesScoped's clear+add+play would restart it.
    function appendFiles(files, trailing) {
        var commands = []
        for (var i = 0; i < files.length; i++) commands.push("add " + root.quote(files[i]))
        for (var j = 0; j < trailing.length; j++) commands.push(trailing[j])
        root.sendList(commands, function (lines, error) {
            if (error) root.setError("queue: " + error)
            else root.refreshState()
        })
    }

    // Narrows the queue to the playing album in place, by deleting the entries
    // after it, and leaves the mode's flags behind in the same transaction.
    //
    // The delete works by queue position: the album's own remainder is expected to
    // occupy the entries from the playing song to the album's end, with the rest
    // of the library behind them. That is the shape playArtistAndBelow builds, but
    // it is not guaranteed -- another client's queue, or one rearranged since, can
    // differ, and deleting by position would then cut tracks that are not the
    // album's and leave the album's own behind the cut. So the shape is confirmed
    // against MPD's own `playlistinfo` first; when it does not hold, the album is
    // rebuilt around the playing song instead. delete only removes entries and
    // shifts the positions under the playing song -- playback itself carries on --
    // where the clear+add the fallback uses stops and restarts the track.
    function trimQueueToAlbum(loc) {
        var song = Number(root.status.song)
        var length = Number(root.status.playlistlength)
        var albumFiles = root.albumFilesAfter(loc.artist, loc.album, loc.track)
        if (isNaN(song) || isNaN(length) || song < 0 || length <= 0
                || albumFiles.length === 0 || song + albumFiles.length > length) {
            root.replaceQueueResuming(albumFiles, root.modeFlags(1))
            return
        }
        root.send("playlistinfo", function (lines, error) {
            if (error) {
                root.replaceQueueResuming(albumFiles, root.modeFlags(1))
                return
            }
            var files = []
            for (var i = 0; i < lines.length; i++) {
                if (lines[i].indexOf("file: ") === 0) files.push(lines[i].slice(6))
            }
            // The run of entries from the playing song must be exactly the album's
            // remainder. A shorter queue, or a mismatch anywhere in the run, is the
            // queue not being in library order from the playing track -- the
            // position this delete trusts -- so the rebuild takes over.
            var ok = files.length > song
            for (var j = 0; ok && j < albumFiles.length; j++) {
                if (files[song + j] !== albumFiles[j]) ok = false
            }
            if (!ok) {
                root.replaceQueueResuming(albumFiles, root.modeFlags(1))
                return
            }
            // MPD ranges are end-exclusive (START:END deletes up to but not
            // including END), so END is the queue length; when the album already
            // runs to the last entry there is nothing to take away. The flags go
            // in the same transaction as the delete so a refresh cannot read the
            // queue mid-change.
            var first = song + albumFiles.length
            var commands = root.modeFlags(1)
            if (first <= files.length - 1)
                commands = ["delete " + first + ":" + files.length].concat(commands)
            root.commandList(commands)
        })
    }

    // ---- repeat modes ----

    // Three states, cycled as off -> repeat album -> repeat song.
    //
    // Repeat album is not MPD's "repeat all" narrowed down: MPD 0.24's repeat is
    // a plain boolean over the whole queue and it rejects "repeat 2" outright,
    // because a queue has no album in it to repeat. So it is a loop this player
    // performs -- the queue is narrowed to the playing album and refilled when
    // MPD runs out of it -- which costs a fraction of a second of silence at the
    // album boundary. Repeat song is the one MPD can express: repeat plus single
    // is documented as repeating the current song rather than the queue.
    //
    // Narrowing and refilling are edits to the live queue -- delete the entries
    // past the album, append them back on the way out -- rather than a clear and
    // rebuild. A rebuild has to restart the playing song to put it back where it
    // was, which is audible as a hiccup when the button is pressed; a delete and
    // an append leave the song running.
    //
    // The mode is stored in the config rather than read back from MPD, because in
    // album mode MPD's flag is deliberately off and would read as "off".
    //
    // The policy lives here rather than in the panel because every step of it is
    // queue manipulation, which is what this file already owns: narrowing the
    // queue, rebuilding it around the playing song and detecting the end of it are
    // all in terms of commands sent to MPD. From the panel these were calls on
    // `mpd` that it made back into its own service; here they are local.

    // Emitted whenever the mode changes, so the panel can persist it. The service
    // deliberately holds no reference to the config: a service that reached into
    // the panel's settings would be reachable from anywhere and would have to know
    // about a UI concern it has no other business with.
    signal repeatModeSelected(int mode)

    property int repeatMode: 0

    // Where to restart from when album mode runs out. Null until we have seen a
    // song, and cleared before replaying so the replay cannot re-enter the handler.
    property var albumLoopPoint: null

    function cycleRepeatMode() {
        root.applyRepeatMode((root.repeatMode + 1) % 3)
    }

    // Adopts the mode persisted by the panel, so a shell restart in the middle of
    // an album comes back in album mode rather than silently reverting to off.
    // Nothing is sent to MPD: the queue was already narrowed by the session that
    // set the mode, and rebuilding it here would restart the album at the top.
    //
    // The restart point has to be rebuilt from the playing song, which only the
    // currentsong callback does. A refresh is requested here so that callback is
    // guaranteed to run: its status read happens to fire on bootstrap, but the
    // panel may adopt the mode after that, leaving albumLoopPoint unset and the
    // loop silently failing at the album's end.
    function adoptStoredMode(mode) {
        if (mode === undefined || mode === null) return
        var m = Math.round(Number(mode))
        if (isNaN(m)) return
        root.repeatMode = Math.max(0, Math.min(2, m))
        if (root.repeatMode === 1 && root.connected) root.refreshState()
    }

    function applyRepeatMode(mode) {
        if (!root.status || root.status.state === undefined) return
        // Located from what MPD is playing, not from the panel's caret, which may be
        // pointing at a different album entirely.
        var loc = root.locateCurrent()

        // Repeat album is not MPD's flag: narrow the queue to the playing album and
        // remember where to restart it once MPD runs off the end. The narrowing is a
        // delete of the entries past the album rather than a rebuild, so the song
        // now playing carries straight on; if the queue is not in the shape that
        // allows it, fall back to rebuilding around the song.
        if (mode === 1) {
            if (loc) {
                root.albumLoopPoint = { artist: loc.artist, album: loc.album }
                root.trimQueueToAlbum(loc)
            } else {
                root.albumLoopPoint = null
                root.commandList(root.modeFlags(1))
            }
            root.repeatMode = 1
            root.repeatModeSelected(1)
            return
        }

        // Off and repeat song are both just MPD's flags. Stepping out of album
        // mode has to put the rest of the library back on the queue first, or the
        // list would still stop at the album's end -- and that is an append, which
        // likewise leaves the playing song alone instead of restarting it.
        if (root.repeatMode === 1 && loc) {
            root.appendFiles(root.filesAfterAlbum(loc.artist, loc.album, loc.track),
                             root.modeFlags(mode))
        } else {
            root.commandList(root.modeFlags(mode))
        }
        root.repeatMode = mode
        root.repeatModeSelected(mode)
    }

    // Album mode's loop. MPD has run off the end of the queue, which in album mode
    // is the end of the album, so start it again.
    //
    // Deliberately albumFilesAfter rather than playArtistAndBelow: the latter
    // enqueues from the album onward to the end of the library, which is right when
    // a person activates a track but wrong here -- it would quietly undo the
    // narrowing that makes this mode "album" and leave the queue library-wide.
    function maybeLoopAlbum() {
        if (root.repeatMode !== 1 || !root.status || root.status.state === undefined) return
        if (root.status.state !== "stop") return
        // Only a natural end of the queue should replay the album. MPD leaves no
        // current song when the queue runs out -- status omits `song`/`songid`
        // and currentsong comes back empty -- but keeps the song it stopped on
        // for a deliberate stop (even when that stop lands on the last track).
        // Looping on a manual stop would restart the album from the top, which is
        // not what Stop means, so a present `song` means the user stopped it.
        if (root.status.song !== undefined) return
        var point = root.albumLoopPoint
        if (!point) return
        root.albumLoopPoint = null
        root.playFilesScoped(root.albumFilesAfter(point.artist, point.album, 0), 0, root.modeFlags(1))
    }

    // Keeps the stored mode honest if something else moves MPD's flags -- another
    // client, or the shell's own media panel. Album mode is exempt because it
    // leaves both flags off on purpose.
    //
    // Only the two unambiguous readings are adopted: repeat with single is
    // repeat-song, and both off is off. A bare repeat (the whole queue) has no
    // mode in this panel to name it, so it is left alone rather than relabelled
    // onto repeat-song and then fought over by the next flag change.
    function syncRepeatModeFromMpd() {
        if (root.repeatMode === 1 || !root.status || root.status.state === undefined) return
        if (root.status.repeat === undefined) return
        var repeatOn = root.status.repeat === 1
        // `single` is only ever set to 1 here; a string like "oneshot" from
        // another client parses as NaN and correctly does not match.
        var singleOn = root.status.single === 1
        if (repeatOn && singleOn) {
            if (root.repeatMode !== 2) {
                root.repeatMode = 2
                root.repeatModeSelected(2)
            }
        } else if (!repeatOn && root.repeatMode !== 0) {
            root.repeatMode = 0
            root.repeatModeSelected(0)
        }
    }

    // Repopulates the restart point as the song changes, so it stays correct even
    // after a shell restart in the middle of an album.
    function rememberAlbumLoopPoint() {
        if (root.repeatMode !== 1) return
        // Not while stopped. maybeLoopAlbum() clears the point and replays; this
        // runs from the currentsong half of the same refresh, so repopulating here
        // would immediately re-arm the loop. If the replay does not start playing
        // (its files were removed, or there is no usable output) MPD reports stop
        // again, the point is non-null again, and the pair loops forever. The next
        // refresh, taken while playing, repopulates it as usual.
        if (root.status && root.status.state === "stop") return
        var loc = root.locateCurrent()
        if (loc) root.albumLoopPoint = { artist: loc.artist, album: loc.album }
    }

    // ---- misc ----

    property var numericKeys: ({
        volume: 1, repeat: 1, random: 1, single: 1, consume: 1, mixrampdb: 1,
        song: 1, songid: 1, playlistlength: 1, elapsed: 1, duration: 1, bitrate: 1,
        nextsong: 1, nextsongid: 1, Pos: 1, Id: 1
    })

    function toMap(lines) {
        var map = {}
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i]
            var sep = line.indexOf(": ")
            if (sep < 0) continue
            var key = line.substring(0, sep)
            map[key] = root.numericKeys[key] ? parseFloat(line.substring(sep + 2)) : line.substring(sep + 2)
        }
        return map
    }

    // ---- sockets ----

    Loader {
        id: cmdLoader
        active: false
        sourceComponent: Socket {
            id: cmdSocket
            path: root.socketPath
            parser: SplitParser {
                onRead: function (line) { root.feedCommandLine(line) }
            }
            // A Socket starts out with connected === false and emits a state
            // change for that too, so treating "not connected" as a failure tears
            // the socket down before it finishes connecting and the greeting
            // never arrives. Only a drop after a real connection counts.
            property bool wasConnected: false
            onConnectionStateChanged: {
                if (cmdSocket.connected) {
                    cmdSocket.wasConnected = true
                    return
                }
                if (cmdSocket.wasConnected) {
                    cmdSocket.wasConnected = false
                    root.connected = false
                    root.scheduleReconnect()
                }
            }
            onError: function (err) {
                // Deliberately not surfaced as lastError. The socket enum arrives
                // here as a bare integer, so it reached the banner as the
                // meaningless "MPD: socket: 1" -- and because the banner is shown
                // when `!connected || lastError !== ""`, a startup miss or a
                // reconnect gap left it up even after MPD was reachable and
                // playing again. A socket that is not there is an expected state
                // for a client, not a fault: `connected` already reports it, and
                // the banner shows a readable "MPD not connected" for that.
                console.warn("mpd command socket error, reconnecting: " + err)
                root.scheduleReconnect()
            }
        }
        // A Socket built through Loader.sourceComponent is not connected just by
        // existing: the instance has to be told to connect once the Loader has
        // built it. Omitting this leaves the socket idle with no error, which is
        // why the panel reported "not connected" while MPD was perfectly
        // reachable.
        onLoaded: item.connected = true
    }

    Loader {
        id: evLoader
        active: false
        sourceComponent: Socket {
            id: evSocket
            path: root.socketPath
            parser: SplitParser {
                onRead: function (line) { root.feedEventLine(line) }
            }
            property bool wasConnected: false
            onConnectionStateChanged: {
                if (evSocket.connected) {
                    evSocket.wasConnected = true
                    return
                }
                if (evSocket.wasConnected) {
                    evSocket.wasConnected = false
                    // The command socket may still answer, but with no events the
                    // panel would sit frozen on stale state while claiming to be
                    // connected. Mark the service down so the banner is honest and
                    // the reconnect below is visible.
                    root.connected = false
                    root.scheduleReconnect()
                }
            }
            onError: function (err) {
                // Same reasoning as the command socket: the event socket failing
                // is a connection state, already covered by `connected` and the
                // banner's "MPD not connected" text.
                console.warn("mpd event socket error, reconnecting: " + err)
                root.scheduleReconnect()
            }
        }
        onLoaded: item.connected = true
    }

    // The greeting is what proves a connection is usable, so the first read
    // hangs off it rather than off connectionStateChanged, which also fires for
    // the failed attempts that wedge the socket.

    function scheduleReconnect() {
        if (reconnectTimer.running) return
        reconnectTimer.interval = root.reconnectDelay
        root.reconnectDelay = Math.min(root.reconnectDelay * 2, 30000)
        reconnectTimer.start()
    }

    // MPD closes any client that has sent it nothing for `connection_timeout`
    // seconds, and the default is 60. The event socket is exempt because it is
    // parked on a blocking `idle`, which suspends that timer -- but the command
    // socket goes quiet whenever playback is paused or simply nothing is
    // happening, and MPD drops it a minute later. That is what makes the panel
    // report MPD gone at random, roughly once a minute, while the event socket
    // that is still feeding it sits right there.
    //
    // A `ping` now and then is the cheap correction: MPD answers OK, the pending
    // FIFO consumes it like any other response, and the connection stays open.
    // 25s is well inside the timeout, so one delayed tick still lands in time.
    Timer {
        id: pingTimer
        interval: 25000
        repeat: true
        running: root.connected
        onTriggered: {
            // Checked against the socket rather than `connected`, which also goes
            // true for the event socket alone: pinging a closed command socket
            // would queue a response that can never arrive.
            if (cmdLoader.item && cmdLoader.item.connected) root.send("ping")
        }
    }

    Timer {
        id: reconnectTimer
        repeat: false
        onTriggered: {
            // Discard the wedged instances rather than reusing them. The
            // activation is deferred a tick so the old sockets are torn down
            // before the replacements are built.
            cmdLoader.active = false
            evLoader.active = false
            root.connected = false
            root.everConnected = false
            root.libraryLoaded = false
            root.pending = []
            root.changed = []
            Qt.callLater(function () {
                cmdLoader.active = true
                evLoader.active = true
            })
        }
    }

    Component.onCompleted: {
        cmdLoader.active = true
        evLoader.active = true
        root.loadCountries()
        root.loadCoverOverrides()
        countryMkdir.running = true
    }
}
