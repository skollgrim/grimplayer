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
        var code = body.substring(1, body.indexOf("@"))
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
    function handleEvents() {
        root.armIdle()
        var touched = root.changed
        root.changed = []
        if (touched.length === 0) return
        if (touched.indexOf("database") >= 0) root.loadLibrary()
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
                else if (key === "ArtistSort") cur.artistSort = value
                else if (key === "Album") cur.album = value
                else if (key === "Date") cur.date = value
                else if (key === "Track") cur.track = leadingInt(value)
                else if (key === "Disc") cur.disc = leadingInt(value)
                else if (key === "duration") cur.duration = parseFloat(value)
                else if (key === "Time" && !cur.duration) cur.duration = parseFloat(value)
            }
        }
        if (cur !== null) songs.push(cur)

        // Grouping matches ncmpcpp: by each track's own Artist, falling back to
        // the album artist for the handful of tracks that omit it.
        var byArtist = {}
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
            var album = null
            for (var a = 0; a < artist.albums.length; a++) {
                if (artist.albums[a].name === albumName) { album = artist.albums[a]; break }
            }
            if (album === null) {
                album = { name: albumName, tracks: [] }
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

        root.artists = ordered
        root.libraryLoaded = true
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

    // Where the playing song sits in the tree, so a queue can be rebuilt around
    // it. The panel's own caret can point somewhere else entirely, so this
    // always works from what MPD is actually playing rather than from the
    // selection. Returns null when the song is not in the library at all, which
    // is the signal to leave the queue alone.
    function locateCurrent() {
        if (!root.current || root.current.file === undefined) return null
        var file = String(root.current.file)
        for (var a = 0; a < root.artists.length; a++) {
            var albums = root.artists[a].albums
            for (var b = 0; b < albums.length; b++) {
                var tracks = albums[b].tracks
                for (var t = 0; t < tracks.length; t++) {
                    if (tracks[t].file === file) return { artist: a, album: b, track: t }
                }
            }
        }
        return null
    }

    // ---- playback ----

    function quote(value) {
        return '"' + String(value).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
    }

    // Replaces the queue with everything below the activated track and starts
    // there. single and consume are cleared first: with single on, MPD stops
    // when a track ends, which is the opposite of what this player promises.
    // repeat and random are left alone -- they are the user's settings, and
    // both are visible in the now-playing strip.
    function playFiles(files) {
        if (!files.length) return
        var commands = ["clear", "single 0", "consume 0"]
        for (var i = 0; i < files.length; i++) commands.push("add " + quote(files[i]))
        commands.push("play 0")
        root.sendList(commands, function (lines, error) {
            if (error) root.setError("play: " + error)
            else root.refreshState()
        })
    }

    function playArtistAndBelow(artistIndex, albumIndex, trackIndex) {
        root.playFiles(root.filesFrom(artistIndex, albumIndex, trackIndex))
    }

    // Simple commands. The response is not interesting; the idle subscription
    // delivers the resulting state, so none of these read anything back.
    function command(name) {
        root.send(name, function (lines, error) {
            if (error) root.setError(name + ": " + error)
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

    // ---- repeat modes ----

    // MPD 0.24's repeat is a plain boolean and rejects "repeat 2" outright, so
    // there is no playlist-or-album repeat to ask for. Mode 1 is therefore just
    // MPD's flag, and mode 2 is a loop this player performs: the queue is narrowed
    // to the playing album, and when MPD runs out of it the panel starts the album
    // again. That leaves a fraction of a second of silence at the album boundary,
    // which is the cost of not having the feature server-side.
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
    // The restart point is repopulated separately, by the currentsong refresh that
    // follows, so its absence here is not a problem.
    function adoptStoredMode(mode) {
        if (mode === undefined || mode === null) return
        var m = Math.round(Number(mode))
        if (isNaN(m)) return
        root.repeatMode = Math.max(0, Math.min(2, m))
    }

    function applyRepeatMode(mode) {
        if (!root.status || root.status.state === undefined) return
        // Located from what MPD is playing, not from the panel's caret, which may be
        // pointing at a different album entirely. The resume point and the
        // paused/playing state are read from MPD inside replaceQueueResuming.
        var loc = root.locateCurrent()

        if (mode === 2) {
            if (loc) {
                root.albumLoopPoint = { artist: loc.artist, album: loc.album }
                root.replaceQueueResuming(root.albumFilesAfter(loc.artist, loc.album, loc.track), ["repeat 0"])
            }
            // MPD's own flag stays off: this mode is not MPD's to express.
            root.repeatMode = 2
            root.repeatModeSelected(2)
            root.command("repeat 0")
            return
        }

        // Leaving album mode puts the rest of the library back in the queue, so the
        // list keeps running past the album the way it does in every other mode.
        var trailing = ["repeat " + mode]
        if (root.repeatMode === 2 && loc) {
            root.replaceQueueResuming(root.filesFrom(loc.artist, loc.album, loc.track), trailing)
        } else {
            root.command("repeat " + mode)
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
        if (root.repeatMode !== 2 || !root.status || root.status.state === undefined) return
        if (root.status.state !== "stop") return
        var point = root.albumLoopPoint
        if (!point) return
        root.albumLoopPoint = null
        root.playFilesScoped(root.albumFilesAfter(point.artist, point.album, 0), 0, [])
    }

    // Keeps the stored mode honest if something else flips MPD's flag -- another
    // client, or the shell's own media panel. Album mode is exempt because it
    // leaves the flag off on purpose.
    function syncRepeatModeFromMpd() {
        if (root.repeatMode === 2 || !root.status || root.status.state === undefined) return
        if (root.status.repeat === undefined) return
        var flag = root.status.repeat ? 1 : 0
        if (flag !== root.repeatMode) {
            root.repeatMode = flag
            root.repeatModeSelected(flag)
        }
    }

    // Repopulates the restart point as the song changes, so it stays correct even
    // after a shell restart in the middle of an album.
    function rememberAlbumLoopPoint() {
        if (root.repeatMode !== 2) return
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
    }
}
