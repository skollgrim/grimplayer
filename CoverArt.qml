pragma ComponentBehavior: Bound
// Album art for the track currently playing.
//
// Artwork is found on disk beside the tracks first: MPD's `file` is a
// library-relative path, so the album's own directory is just its parent, and the
// cover is the conventional cover.jpg in there. That is the layout of the
// collection this was written against.
//
// Failing that, the art is pulled out of the track itself. A tagged library keeps
// the image inside the file and writes nothing beside it, so those albums used to
// land on the placeholder. MPD can serve embedded art (`albumart` returns the
// picture as binary), but it cannot be used here: this plugin talks to MPD through
// Quickshell.Io.Socket, whose reads arrive as UTF-8 text, and a JPEG or PNG does
// not survive that decoding. So the file is handed to ffmpeg instead, which writes
// the picture out as a JPEG that is then cached per album and loaded like any
// other cover. ffmpeg is optional throughout -- absent, or failing on a track with
// no embedded art, and the album simply keeps the placeholder, exactly as before.
//
// Deliberately an overlay rather than a column in the now-playing strip. The
// strip already carries title, artist, seek bar, transport and volume, and adding
// a 168px square to that row would push the transport controls around and change
// the strip height. Bottom-right over the tracks pane keeps it out of the way of
// everything you interact with, and the pane behind it is a list, so the art
// lands on mostly-empty space.
//
// The probe walks a candidate list because cover.jpg is only a convention.
// Folder.jpg, cover.png, front.jpg and album.jpg all turn up in real collections,
// and guessing once would mean a silently blank square for those albums. The list
// also carries the capitalised spellings, because the filesystem is case
// sensitive, and the tag-derived "<artist> - <album>" and "<album>" names that
// taggers use when one folder holds several releases. The cached extraction is
// last, which is what makes a sidecar image win over the one inside the file: a
// re-tag that changes the embedded art leaves the old sidecar behind, and having
// the tag win would make the two disagree.
//
// The walk is driven by the Image's own load status rather than by a separate
// existence check. Qt6 dropped QtQuick's FileIO entirely, and the alternative --
// probing with a throwaway loader and then handing the path to the Image -- reads
// every cover twice. Letting the Image that has to load the file anyway report
// back whether it worked costs nothing and needs no extra API.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import "Covers.js" as Covers

Item {
    id: root

    // Declared explicitly rather than reaching for the panel's own `mpd`: a
    // sibling component file does not inherit the panel root's scope, so it has
    // to be handed the service.
    property var mpd: null

    // The panel shows the playing track's art; the tag editor shows the art for
    // its selection, which need not be what is playing. `subject` is that
    // selection's first song plus its library-relative file, and when it is set
    // it stands in for `mpd.current` everywhere the context is read. Null in the
    // panel, where the playing track is the answer.
    property var subject: null

    // Whether this instance is on screen and worth doing any work for. The tag
    // editor keeps a second instance for its selection preview, and that one has
    // no business probing the playing album while the editor is closed.
    property bool active: true

    // Whether an album with no artwork on disk or in the files may have one
    // fetched from the stores. On by default; off keeps the player entirely
    // offline and such albums on the placeholder. Injected from the settings,
    // with the code default here for a component placed on its own.
    property bool fetchCovers: true

    // The panel's colour tokens, injected the same way as the service. The
    // aliases below fall back to the shell theme so this file still draws
    // correctly if it is ever placed on its own.
    property var theme: null
    readonly property color colBackground: theme ? theme.background : Color.background
    readonly property color colForeground: theme ? theme.foreground : Color.foreground
    readonly property color colMuted: theme ? theme.muted : Color.muted

    // ---- cover palette ----
    //
    // The quantizer reads the URL the Image has actually settled on, not the one
    // it is currently loading: `imageSource` changes once per candidate, and
    // quantizing each of those runs the colour pass on every name the walk tries
    // -- most of which do not exist -- before the real cover is even reached.
    // `resolvedSource` is set when a picture reaches Ready, so the pass runs once
    // per resolved cover, including the ffmpeg extraction that lands in the cache
    // directory. depth 3 is eight colours, which is enough to find a vivid one
    // without giving the recursive split more work than it needs; rescaleSize is
    // the recommended shrink that keeps the pass cheap. The panel watches
    // `palette` and folds it into its theme.
    ColorQuantizer {
        id: quantizer
        source: root.resolvedSource
        depth: 3
        rescaleSize: 64
    }

    readonly property var palette: quantizer.colors

    // Real artwork, as opposed to the placeholder the CD is drawn for. The
    // panel only recolours on a Ready image, so the flash through Loading when
    // one album replaces another never reaches the UI.
    readonly property bool hasArt: art.status === Image.Ready

    // Whether a cover has been found for the current album at any point. Set as
    // soon as the Image reaches Ready and cleared only when the album changes
    // (see probe()). Unlike the Image's live status it does not fall back to
    // false when the surface is hidden and the image is unloaded, so the palette
    // is not thrown away and rebuilt just because the panel went away for a
    // moment.
    property bool foundArt: false

    // Whether the candidate walk has given up: every name has been tried, or
    // there was none to try. Set where the walk runs off its end (see the Image's
    // onStatusChanged) and, for an empty list, at once by probe().
    //
    // Kept apart from candidateIndex resting on the last name, which is also true
    // while that name is still loading. Reading that as "exhausted" declared no
    // art one name early -- the held cover was dropped to the placeholder in the
    // gap before the last candidate had even been given its chance.
    property bool walkDone: false

    // A picture is known to be in hand -- ffmpeg wrote it, or a tag editor set one
    // -- but the Image has not loaded it yet. Holds noArt false across that gap
    // (see noArt). Set by showCached, cleared when the Image reaches Ready or Error
    // and whenever a new album is probed. The download path needs no flag of its
    // own: onlineState stays non-empty from the probe until the picture is shown or
    // abandoned, and that already holds noArt false.
    property bool resolving: false

    // Definitively no artwork for this album: nothing was ever found, the
    // candidate walk has run off its end, and the embedded-picture fallback has
    // finished without producing one.
    //
    // This, not the Image's status, is what the panel falls back to the theme on.
    // The status is not a truthful "there is no cover" signal while the probe is
    // still working -- between candidates it sits in Error, and treating each of
    // those as "no art" reset the panel to the theme for a frame in the middle of
    // every album change, which is exactly the flash this replaces.
    //
    // `resolving` is the one gap the other terms miss: ffmpeg can exit having
    // written a picture, and the Image has yet to load it. Walk-done is already
    // true (the sidecars were all absent) and the extractor has stopped, so
    // without this the frame between the extraction landing and the Image
    // reaching Ready read as no art and flashed the theme.
    readonly property bool noArt: !foundArt
                                  && walkDone
                                  && !extractor.running
                                  && !extractingDir
                                  && !resolving
                                  && root.onlineState === ""

    // MPD reports paths relative to its music_directory, which mpd.conf sets to
    // $XDG_MUSIC_DIR with ~/Music as the fallback on the next line.
    readonly property string musicDir: Quickshell.env("XDG_MUSIC_DIR") || ((Quickshell.env("HOME") || "") + "/Music")

    // ---- embedded artwork cache ----
    //
    // Sits beside the settings file the panel already keeps, because it is the
    // same kind of thing: something derived from the library that should survive a
    // shell restart without being recomputed. Keyed by album rather than by track,
    // since every track on an album carries the same picture.
    readonly property string cacheDir: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/skollgrim.grimplayer/covers"

    // FNV-1a naming lives in Covers.js, shared with the service so a cover the
    // user clears there deletes the same cached file this loads. See that file.
    function cachedCover(dir) {
        return root.cacheDir + "/" + Covers.fileName(dir)
    }

    // The downloaded cover for an album with nothing anywhere, cached beside the
    // extraction. Never part of the candidate walk: the probe only reaches for
    // it once the sidecars and the embedded picture have both come up empty, so
    // the store's guess can never stand in for what the file actually holds.
    function onlineCover(dir) {
        return root.cacheDir + "/" + Covers.onlineFileName(dir)
    }

    // The library-relative path of the track being shown: the tag editor's
    // selection when there is one, otherwise what is playing. Empty when there
    // is nothing to show art for.
    function currentFile() {
        if (root.subject && root.subject.file) return String(root.subject.file)
        if (!mpd || !mpd.current || !mpd.current.file) return ""
        return String(mpd.current.file)
    }

    // The cue fold and the "." root key live in one shared implementation now,
    // Covers.albumDir; this component reads it through currentAlbumDir below.

    // Absolute paths ffmpeg should try for embedded artwork, in order.
    //
    // A normal track is one path. A cue album's audio is a single file beside
    // the cue whose name the cue does not have to share, so the cue's own stem
    // is combined with the audio extensions CD rips use and tried in turn. The
    // name is a guess because the cue's FILE line would have to be read to do
    // better, and a wrong guess costs nothing: ffmpeg fails on a missing file
    // exactly as it does on one with no picture, and the next candidate runs.
    function currentFileCandidates() {
        var f = root.currentFile()
        if (!f) return []
        var m = /\.cue\/track\d+$/i.exec(f)
        if (m) {
            var stem = f.substring(0, m.index)          // "<dir>/<album>"
            var exts = ["flac", "ape", "wav", "wv", "tta", "m4a", "mp3", "ogg"]
            var out = []
            for (var i = 0; i < exts.length; i++)
                out.push(root.musicDir + "/" + stem + "." + exts[i])
            return out
        }
        return [root.musicDir + "/" + f]
    }

    // Album directories already found to carry no embedded art. In memory rather
    // than as marker files on disk: ffmpeg runs again for them once per shell
    // session, which for a handful of albums is invisible, and it keeps the state
    // directory holding only things worth keeping.
    property var noEmbedded: ({})

    // Album directories the stores had nothing for, and the dirs a deliberate
    // cover removal has taken out of the fetch for this session. Keyed the same
    // way as noEmbedded and forgotten on a restart, which is fine: the search is
    // cheap, and a stale negative is worse than one extra lookup.
    property var noOnline: ({})

    // The online fallback's own little state machine. "" is idle; "probe" means
    // the Image is being pointed at a cached download to see whether one is
    // already there; "fetch" means the helper is being asked; "show" means the
    // download is being loaded. Non-empty also holds the panel off the
    // placeholder while the answer is still coming, so a first-time fetch does
    // not flash an empty frame before the cover lands.
    property string onlineState: ""
    property string onlineDir: ""
    property string queuedOnlineDir: ""

    property string extractingDir: ""
    property string queuedDir: ""
    property var queuedFiles: []

    // The audio paths the current extraction is walking, and how far it has got.
    // More than one only for a cue album, whose audio name is a guess (see
    // currentFileCandidates).
    property var extractFiles: []
    property int extractIndex: 0

    // Point the Image straight at a cached cover we know exists, rather than
    // walking the candidate list again for an answer already in hand.
    function showCached(dir) {
        var target = Covers.fileUrl(root.cachedCover(dir))
        // A picture is in hand as of now -- the extractor wrote it, or a tag editor
        // set one -- so noArt has to stay false while it loads rather than flashing
        // the theme in the gap (see the resolving property).
        root.resolving = true
        // The cover about to load may be a rewrite of the URL the quantizer has
        // already read -- an edit re-extracts to the same cache path. Clearing the
        // resolved source first is what makes the Ready assignment below a change
        // the quantizer notices, so the palette is read from the new picture rather
        // than kept from the one that was just replaced.
        root.resolvedSource = ""
        // The Image is sitting in Error on this exact URL, and assigning a property
        // the value it already holds does not re-evaluate it. Clearing it first is
        // what makes the next assignment a change the Image reacts to.
        root.imageSource = ""
        // Same re-check as showOnline: the deferred assignment must not resurrect
        // this album's cache if the selection has moved on in the meantime, or the
        // new album's cover would flash the old one for a tick.
        Qt.callLater(function () {
            if (dir === root.loadedDir) root.imageSource = target
        })
    }

    // Last resort for the sidecar-less: pull the picture out of the track itself.
    //
    // Re-encoding to mjpeg rather than copying the embedded stream, so the cached
    // file is always a real JPEG at a real extension. Copying would be faster and
    // lossless, but the source can be a PNG, and naming that .jpg leaves the cache
    // depending on the image loader sniffing past the extension. The cover is drawn
    // at most a share of the pane height, so nothing is lost by rescaling a 1200px
    // original down to something displayable.
    function requestEmbedded(dir, files) {
        if (!dir) return
        // Resolve the audio name now, not when the request is served. A queued
        // request is drained after the extractor exits, and by then the playing
        // track may have moved on -- reading the current file then would point
        // ffmpeg at the wrong album's audio and cache its picture under this
        // album's name.
        if (files === undefined) files = root.currentFileCandidates()
        if (extractor.running) {
            queuedDir = dir
            queuedFiles = files
            return
        }
        if (root.noEmbedded[dir] === true) {
            // Already established this session that the file holds no picture.
            // The stores are the only place left, and skipping straight there is
            // what keeps a second visit to the album from stalling on the disc.
            root.requestOnline(dir)
            return
        }
        if (files.length === 0) {
            root.requestOnline(dir)
            return
        }
        root.extractFiles = files
        root.extractIndex = 0
        root.extractingDir = dir
        root.runExtraction()
    }

    // Point ffmpeg at the current audio-name candidate. Split out so onExited can
    // advance to the next one without repeating the argument list.
    function runExtraction() {
        extractor.command = ["ffmpeg", "-v", "error", "-y",
                             "-i", root.extractFiles[root.extractIndex],
                             "-an", "-map", "0:v:0", "-frames:v", "1",
                             "-c:v", "mjpeg", "-q:v", "3",
                             root.cachedCover(root.extractingDir)]
        extractor.running = true
    }

    Process {
        id: extractor
        running: false
        command: []
        onExited: function (exitCode) {
            var dir = root.extractingDir
            if (exitCode !== 0) {
                // The audio was not under the name ffmpeg was given -- the usual
                // case for a cue album, where the name is only a guess. Try the
                // next spelling before concluding there is no picture at all.
                var next = root.extractIndex + 1
                if (next < root.extractFiles.length) {
                    root.extractIndex = next
                    root.runExtraction()
                    return
                }
                root.extractingDir = ""
                // ffmpeg exits non-zero on a track with no attached picture, which is
                // the common case and not an error worth surfacing -- it just means this
                // album keeps the placeholder, so remember it and stop asking.
                var missing = root.noEmbedded
                missing[dir] = true
                root.noEmbedded = missing
                // Nothing inside the file either, so the last place to look is the
                // stores -- for the album on screen, and only while it is still
                // the album on screen; requestOnline checks both.
                root.requestOnline(dir)
            } else {
                root.extractingDir = ""
                if (dir === root.loadedDir) root.showCached(dir)
            }
            if (root.queuedDir) {
                var queued = root.queuedDir
                var queuedFiles = root.queuedFiles
                root.queuedDir = ""
                root.queuedFiles = []
                root.requestEmbedded(queued, queuedFiles)
            }
        }
    }

    // ---- online fallback ----
    //
    // The last place art can come from. A cached download is loaded rather than
    // probed with a throwaway loader, the same trick the candidate walk uses: the
    // Image that has to load the file anyway is what reports whether it worked.
    // A miss is not an error, it just moves the state machine on to asking the
    // service, which runs the helper once and writes the result into the cache.
    function requestOnline(dir) {
        if (!root.fetchCovers) return
        // The album was deliberately cleared in the tag editor; the stores must
        // not quietly undo that.
        if (root.mpd && typeof root.mpd.coverOverrideFor === "function"
                && root.mpd.coverOverrideFor(dir) === "none") return
        // Only for the album actually on screen. A cue album's real directory is
        // already folded out (currentAlbumDir), so this is the same key the
        // candidate walk and the cache use.
        if (!dir || dir !== root.loadedDir) return
        if (root.noOnline[dir] === true) return
        if (!root.mpd || typeof root.mpd.fetchAlbumCover !== "function") return
        if (root.onlineState !== "") {
            // Something is already in flight. If it is another album, remember
            // this one and take it up when that finishes; the service serialises
            // the helper runs underneath either way.
            if (root.onlineDir !== dir) root.queuedOnlineDir = dir
            return
        }
        root.onlineDir = dir
        root.onlineState = "probe"
        root.imageSource = Covers.fileUrl(root.onlineCover(dir))
    }

    // The cached download is not there, so ask the service to fetch one. The
    // album's tags are what the stores are searched with; a folder the probe
    // reached knows its own Album tag or it would not have got this far.
    function startOnlineFetch() {
        var dir = root.onlineDir
        if (!dir || dir !== root.loadedDir || root.noOnline[dir] === true) {
            root.resetOnline()
            root.runQueuedOnline()
            return
        }
        // The album may have been cleared while the fetch was in flight; a
        // deliberate removal outranks a store's guess.
        if (root.mpd && typeof root.mpd.coverOverrideFor === "function"
                && root.mpd.coverOverrideFor(dir) === "none") {
            root.markNoOnline(dir)
            root.resetOnline()
            root.runQueuedOnline()
            return
        }
        var album = currentTag("Album")
        if (!album) {
            root.markNoOnline(dir)
            root.resetOnline()
            root.runQueuedOnline()
            return
        }
        root.onlineState = "fetch"
        var artist = currentTag("Artist") || currentTag("AlbumArtist")
        var year = String(currentTag("Date") || "").slice(0, 4)
        root.mpd.fetchAlbumCover({
            artist: artist,
            album: album,
            year: year,
            size: 600,
            out: root.onlineCover(dir)
        }, function (result) {
            // `dir` is the local captured above, not root.onlineDir: by the time
            // the helper answers the user may have moved to another album, and
            // the answer still belongs to the album that asked.
            var ok = result && result.status === "ok"
                && result.cover && result.cover !== ""
            if (!ok) {
                root.markNoOnline(dir)
                root.resetOnline()
                root.runQueuedOnline()
                return
            }
            // The album may have been cleared while the fetch was in flight; a
            // deliberate removal outranks a store's guess, the same as in
            // startOnlineFetch before the request went out.
            if (dir === root.loadedDir && root.mpd
                    && typeof root.mpd.coverOverrideFor === "function"
                    && root.mpd.coverOverrideFor(dir) === "none") {
                root.markNoOnline(dir)
                root.resetOnline()
                root.runQueuedOnline()
                return
            }
            if (dir === root.loadedDir) {
                root.onlineState = "show"
                root.showOnline(dir)
            } else {
                root.resetOnline()
                root.runQueuedOnline()
            }
        })
    }

    // Point the Image at a download that is now on disk. Same clearing trick as
    // showCached: the Image is sitting in Error on this exact URL from the probe,
    // and re-assigning the value it holds changes nothing until it is emptied.
    // The deferred assignment re-checks the album, so a change landing in the
    // same tick cannot be overwritten by a cover that is no longer current.
    function showOnline(dir) {
        var target = Covers.fileUrl(root.onlineCover(dir))
        root.imageSource = ""
        Qt.callLater(function () {
            if (root.onlineState === "show" && root.onlineDir === dir)
                root.imageSource = target
        })
    }

    function resetOnline() {
        root.onlineState = ""
        root.onlineDir = ""
    }

    function markNoOnline(dir) {
        if (!dir) return
        var missing = root.noOnline
        missing[dir] = true
        root.noOnline = missing
    }

    function runQueuedOnline() {
        if (!root.queuedOnlineDir) return
        var queued = root.queuedOnlineDir
        root.queuedOnlineDir = ""
        root.requestOnline(queued)
    }

    // The directory has to exist before ffmpeg can write into it, and Quickshell.Io
    // has no mkdir. This is the same trade the settings file makes, and the same
    // shape: one idempotent call at startup, argv rather than a shell so there is
    // nothing to quote.
    Process {
        id: cacheMkdir
        running: true
        command: ["mkdir", "-p", root.cacheDir]
    }

    property int candidateIndex: 0
    property var candidates: []
    property url imageSource: ""

    // The URL the Image last turned Ready on. The quantizer reads this rather
    // than imageSource, so the colour pass runs once per resolved cover instead of
    // once per candidate name the walk tries (see the quantizer above).
    property url resolvedSource: ""

    // The frame is sized by the parent (a share of the pane height); this only
    // carries the scale so the corner radius rides along with it.
    property real uiScale: 1.0

    // Device pixel ratio of the window's screen, so the cover Image decodes at
    // display size in physical pixels rather than at full source resolution. A
    // 1500px sidecar decoded into a ~9MB pixmap to be drawn at ~210px, and those
    // oversized pixmaps are what filled the pixmap cache while scrolling.
    property real pixelRatio: 1.0

    // Ring around the artwork. The toggle and its thickness are separate so the
    // ring can be dropped without losing the thickness it was set to.
    property bool coverBorder: true
    property int coverBorderWidth: 1

    // Whether the artwork carries rounded corners. Off draws it as a plain
    // square, corner to corner; the ring above follows this, so a square cover
    // gets a square ring.
    property bool rounded: true

    // The corner radius the frame and its ring share: the rounded look, or zero
    // when the artwork is drawn square.
    readonly property int cornerRadius: root.rounded ? Math.round(10 * root.uiScale) : 0

    // Whether an album with no artwork anywhere shows the disc at all. Off leaves
    // the corner empty rather than standing in a graphic for a cover that does
    // not exist -- which is what this used to do unconditionally, before the
    // disc was drawn at all. Real artwork always shows regardless: this is only
    // about the absence of a cover.
    property bool placeholder: true

    // When set, this image is shown directly instead of probing for one. The tag
    // editor uses it to preview a cover the user has chosen but not yet written.
    //
    // A plain string, not a `url`: a url-typed property never compares equal to
    // `""` (it is a QUrl, not the string), so the emptiness checks below would
    // read as "set" even when it is empty and the Image would be pointed at
    // nothing, blanking every cover.
    property string overrideSource: ""

    // Album directory whose cover is currently displayed. Used to skip redundant
    // probes; see refresh().
    property string loadedDir: ""

    // How long a cover takes to fade in over the previous one when the album
    // changes, in milliseconds. Zero is an instant swap. Holding the old cover is
    // what makes even zero flicker-free: the previous picture stays up until the
    // new one is ready, so a change is never a blink through the placeholder.
    property int transitionDuration: 0

    // The cover currently settled on screen, drawn under the incoming layer. Set
    // when a picture finishes fading in -- or immediately, when the duration is
    // zero -- so what a change reveals is the last picture rather than a hole.
    property string heldSource: ""

    // The picture the incoming layer settled on, remembered from the moment it
    // became Ready so the fade and the promotion to `held` agree on it even if the
    // probe moves on before the fade is done.
    property string pendingSource: ""

    // The incoming layer's opacity, animated by the fade below.
    property real incoming: 0

    // Whether the frame has anything to show: a settled cover, or one the incoming
    // Image is drawing right now. The disc is hidden whenever this is true, so it
    // never flashes between two covers during a change.
    readonly property bool showingArt: root.heldSource !== "" || art.status === Image.Ready

    // Parent directory of the current track, relative to the music root:
    // "Some Artist/2019 - Some Album [Live]/12 - Track.flac" -> "Some Artist/2019
    // - Some Album [Live]".
    //
    // A cue album's reported path is folded back onto the cue first, so the
    // probe looks beside the cue and its audio rather than inside a "<album>.cue"
    // directory that does not exist; that fold lives in Covers.albumDir, the one
    // implementation the service keys its own maps on too. Empty means "no
    // track"; a track sitting directly in the music root gets "." instead, so it
    // is still a real, distinguishable place to probe and refresh() can tell it
    // apart from having nothing to show.
    //
    // Computed imperatively rather than as a binding. The service is injected
    // after this component is created, and the handler that reacts to that
    // injection runs immediately -- before the albumDir binding has been
    // re-evaluated, so a bound property still read back as empty and the panel
    // never found the cover for a track that was already playing.
    function currentAlbumDir() {
        return Covers.albumDir(root.currentFile())
    }

    // Tag value for the current track, or "" when MPD has nothing loaded. Album
    // art is sometimes named after the tags rather than a fixed word, so the
    // candidate list needs them.
    function currentTag(key) {
        var src = root.subject && root.subject.song ? root.subject.song
                                                    : (mpd ? mpd.current : null)
        if (!src) return ""
        var v = src[key]
        return v === undefined || v === null ? "" : String(v).trim()
    }

    // "<artist> - <album>" and "<album>" are how artwork gets named when a
    // folder holds more than one release, so those names are probed too: a folder
    // can sit next to "Artist - Album.jpg" with nothing called cover.jpg anywhere
    // near it.
    //
    // Built from the tags rather than the folder name, since these folders are
    // "<artist>/<year> - <album>" and no tagger writes the year into an image
    // filename. A tag containing a character the filesystem cannot hold cannot
    // match either, so those albums keep the placeholder.
    function namedCandidates() {
        var artist = currentTag("Artist") || currentTag("AlbumArtist")
        var album = currentTag("Album")
        var out = []
        if (artist && album) {
            out.push(artist + " - " + album + ".jpg")
            out.push(artist + " - " + album + ".png")
        }
        if (album) {
            out.push(album + ".jpg")
            out.push(album + ".png")
        }
        return out
    }

    // Cover names for one directory. Pulled out so the album directory and, for
    // a multi-disc release, its parent share exactly the same list.
    //
    // cover.jpg is only a convention. folder.jpg, cover.png, front.jpg and
    // album.jpg all turn up in real collections, and stopping at the first name
    // would mean a silently blank square for those albums.
    //
    // The capitalised spellings are listed after the lowercase ones because the
    // filesystem is case sensitive: Cover.jpg and Folder.jpg are not found by a
    // request for cover.jpg, and capitalised names are common. The
    // tag-derived names come last so that a folder holding both cover.jpg and
    // "<album>.jpg" still resolves to cover.jpg, the way it did before.
    function dirCandidates(dir) {
        if (!dir) return []
        // "." is the music root itself, which a track sitting directly in it
        // calls home; there is no directory name to join on.
        var base = dir === "." ? root.musicDir : root.musicDir + "/" + dir
        var names = ["cover.jpg", "folder.jpg", "cover.png", "front.jpg", "album.jpg",
                     "Cover.jpg", "Folder.jpg", "Cover.png", "Front.jpg", "Album.jpg"]
        var named = namedCandidates()
        for (var n = 0; n < named.length; n++) names.push(named[n])
        var out = []
        for (var i = 0; i < names.length; i++) {
            out.push(base + "/" + names[i])
        }
        return out
    }

    function parentDir(dir) {
        if (!dir) return ""
        var i = dir.lastIndexOf("/")
        return i > 0 ? dir.substring(0, i) : ""
    }

    // Whether a directory name reads as one disc of a multi-disc release --
    // "Disc 1", "CD2", "side 1", "Vol. 3", or a bare small number. Only these look
    // one level up for the cover (see candidateList): a normal "Artist/Album"
    // wants the cover inside Album, and reaching into Artist unconditionally would
    // let an artist image stand in for the album art.
    //
    // A bare number is only a disc when it is small. A folder named for a year
    // ("1975") is an ordinary album directory -- often the only folder under the
    // artist -- and reaching up from it would probe the artist folder for a cover,
    // which is where an artist image sits. Discs are numbered in the low tens;
    // years are four digits, so the cap separates them without a whitelist.
    function isDiscDir(dir) {
        if (!dir) return false
        var base = dir.substring(dir.lastIndexOf("/") + 1)
        var bare = /^(\d+)$/.exec(base)
        if (bare && Number(bare[1]) <= 99) return true
        return /^(disc|disk|cd|side|vol|volume|part|book)[\s\-._]*\d*$/i.test(base)
    }

    // The probe order, most specific first.
    function candidateList(dir) {
        if (!dir) return []
        // A cover the user set or cleared in the tag editor is remembered on the
        // service, and wins over what the folder holds. The folder is never
        // written to, so without this a sidecar image beside the tracks would keep
        // showing after the editor embedded a new picture, and a cleared album
        // would be filled straight back in by the sidecar.
        var override = (root.mpd && typeof root.mpd.coverOverrideFor === "function")
            ? root.mpd.coverOverrideFor(dir) : ""
        if (override === "none") return []
        if (override === "embedded") {
            // Only the cached extraction: the sidecars are deliberately skipped,
            // and the picture is pulled out of the files by requestEmbedded when
            // the cache is not there yet.
            return [root.cachedCover(dir)]
        }
        var out = dirCandidates(dir)
        // A multi-disc release commonly keeps one cover at the album root and
        // splits the tracks into side/CD subfolders. The cover is one level up
        // from the disc, so probe the parent too -- only for a disc-shaped
        // directory, so a plain album never reaches past its own folder. One
        // level is enough: the standard "Artist/Album/Disc 1" puts the root at
        // the parent, and walking further would only find Artist again.
        if (isDiscDir(dir)) {
            var up = parentDir(dir)
            if (up) {
                var parents = dirCandidates(up)
                for (var p = 0; p < parents.length; p++) out.push(parents[p])
            }
        }
        // Last, so anything on disk wins. The cached extraction is a fallback for
        // albums a tagger left with no sidecar file at all, not a replacement for
        // one: where both exist the sidecar is what the user (or the tagger) put in
        // the folder, and re-tagging the file should not silently change the cover.
        out.push(root.cachedCover(dir))
        return out
    }

    function probe(force) {
        // A change mid-fade abandons the fade: the incoming layer is about to be
        // pointed at a different album, and letting the old fade finish would
        // promote a cover that is no longer the one being shown.
        if (fade.running) fade.stop()
        // The online state machine's probe and show phases are driven through the
        // Image, which is about to be repointed at the new album's candidates, so
        // they are abandoned with it. A fetch already running is left alone: the
        // service owns that subprocess, and its callback checks the album before
        // showing anything.
        if (root.onlineState === "probe" || root.onlineState === "show") root.resetOnline()
        root.incoming = 0
        // A new album's resolution starts from nothing: the previous album's
        // "picture in flight" answer does not apply to this one.
        root.resolving = false
        var dir = currentAlbumDir()
        candidates = candidateList(dir)
        candidateIndex = 0
        // An empty list has no name to walk, so it is exhausted from the start:
        // the cleared album (override "none") lands here and must read as no art.
        walkDone = candidates.length === 0
        foundArt = false
        var first = candidates.length > 0 ? Covers.fileUrl(candidates[0]) : ""
        // Assigning the URL the Image already holds is a no-op -- no statusChanged
        // fires -- and the incoming layer has just been dropped to opacity 0 with
        // nothing held, so returning to the same album (the tag editor reopening
        // on it, or the panel coming back) would show an empty frame. If the Image
        // is already Ready on exactly this source, take the ready path again
        // instead of assigning a value it will not react to. A forced probe skips
        // this: it is only ever forced by a cover edit, and there what the Image
        // holds Ready is the picture that edit just replaced.
        if (!force && first !== "" && art.status === Image.Ready
                && String(art.source) === first) {
            root.foundArt = true
            root.reveal()
            return
        }
        // Pointed at the same URL but not showing it -- the file was deleted by a
        // cover edit and ffmpeg has yet to rewrite it, or a previous walk left it
        // in Error on a name it has since re-tried. An assignment of the value it
        // holds changes nothing, so empty the source and re-point on the next tick
        // to force the Image to re-stat the file.
        if (first !== "" && String(art.source) === first) {
            root.imageSource = ""
            Qt.callLater(function () {
                if (root.loadedDir === dir) root.imageSource = first
            })
            return
        }
        imageSource = first
    }

    // The incoming layer has a real picture. Promote it: instantly, or by fading
    // it in over the held cover. Promotion to `held` happens only once the fade is
    // done, which is what makes this a crossfade rather than a swap -- moving the
    // held layer to the new picture while the incoming one is still transparent
    // would put the new cover up immediately and there would be nothing to fade.
    function reveal() {
        root.pendingSource = String(art.source)
        if (root.transitionDuration <= 0) {
            root.heldSource = root.pendingSource
            root.incoming = 0
            return
        }
        root.incoming = 0
        fade.restart()
    }

    NumberAnimation {
        id: fade
        target: root
        property: "incoming"
        from: 0
        to: 1
        duration: root.transitionDuration
        easing.type: Easing.InOutQuad
        onFinished: {
            root.heldSource = root.pendingSource
            root.incoming = 0
        }
    }

    // Probe only when the album directory actually changes.
    //
    // mpd.current is a plain map rebuilt from every `currentsong`, so it changes
    // identity on every status update -- including play and pause on the same
    // track. Reloading the cover on each of those made the Image drop back to
    // Null and flash the placeholder over artwork that had not changed at all.
    // The same applies to moving within one album: every track change fires
    // currentChanged, but the cover lives in the album directory and is already
    // on screen. Keying on the directory skips both cases.
    function refresh(force) {
        // An off-screen instance does nothing and leaves loadedDir alone, so the
        // first refresh after it comes back does the probe rather than being
        // skipped as unchanged.
        if (!root.active) return
        var dir = currentAlbumDir()
        // `force` is the cover-edit path: the album directory has not changed but
        // what is on disk has, so the same-directory skip must not apply.
        if (!force && dir === loadedDir) return
        loadedDir = dir
        probe(force)
    }

    // The selection being previewed changed -- the editor opened on a different
    // album -- so re-probe. The playing track's instance carries no subject and
    // never fires this.
    onSubjectChanged: refresh()

    // Coming back on screen re-probes. Going off it drops the held cover and the
    // memory of the loaded directory, so the editor's preview starts clean rather
    // than fading in from the album it happened to show when it was last open.
    onActiveChanged: {
        if (!root.active) {
            if (fade.running) fade.stop()
            root.incoming = 0
            root.heldSource = ""
            root.loadedDir = ""
            root.resolving = false
            // The instance is off screen. Whatever the online machine was doing
            // for it is moot; a running helper is left to finish and its callback
            // no-ops against the now-empty loadedDir.
            root.resetOnline()
            root.queuedOnlineDir = ""
            return
        }
        refresh()
    }

    // The album has been found to have no cover anywhere. Drop the held cover so
    // the placeholder takes over instead of the previous album's art lingering.
    onNoArtChanged: if (root.noArt) root.heldSource = ""

    Connections {
        target: root.mpd
        function onCurrentChanged() { root.refresh() }
        function onConnectedChanged() {
            if (root.mpd.connected) root.refresh()
        }
        // The service rewrote this album's cover (the tag editor set or cleared
        // it). The album directory has not changed, so refresh() would skip it,
        // but what is on disk has -- drop the memory of the loaded directory and
        // probe again. noEmbedded is cleared too, so an album whose embedded art
        // was just added or removed is asked afresh rather than trusting the
        // answer from before the edit.
        //
        // A removal is honoured in the other direction as well: an album the user
        // deliberately emptied should stay empty rather than have the stores fill
        // it straight back in, so that directory is marked as one not to fetch.
        // Setting a cover clears any such mark, since the album now has art of
        // its own and a later fallback is allowed again.
        function onCoversChanged() {
            // Only the albums this edit touched are re-armed: a set or a removal
            // can change whether a file now holds a picture worth extracting, but
            // every other album's answer still stands, and forgetting them all
            // would re-run ffmpeg on each one's next visit for nothing.
            var dirs = (root.mpd && root.mpd.lastCoverDirs) ? root.mpd.lastCoverDirs : []
            var action = root.mpd ? root.mpd.lastCoverAction : ""
            var embedded = {}
            for (var k in root.noEmbedded) embedded[k] = root.noEmbedded[k]
            var missing = {}
            for (var k2 in root.noOnline) missing[k2] = root.noOnline[k2]
            for (var i = 0; i < dirs.length; i++) {
                var d = String(dirs[i])
                if (embedded[d] !== undefined) delete embedded[d]
                if (action === "remove") missing[d] = true
                else if (missing[d] !== undefined) delete missing[d]
            }
            root.noEmbedded = embedded
            root.noOnline = missing
            // The edit rewrote what is on disk without the album's directory
            // changing, so the probe is forced rather than skipped, and the source
            // is emptied so a much-held Ready image of the file that was just
            // deleted does not survive as a stale picture (see probe()).
            root.imageSource = ""
            root.loadedDir = ""
            root.refresh(true)
        }
    }

    // The service is injected after this component finishes creating, so the
    // Connections above have no target yet and Component.onCompleted probes an
    // empty library. Without this the first track is never picked up: by the
    // time the service arrives its `current` is already populated, so no
    // currentChanged is left to fire.
    onMpdChanged: {
        if (mpd) refresh()
    }

    Component.onCompleted: refresh()

    // Sized against the pane it sits in rather than picked round: this is the
    // one large element on the screen. The size is the artwork-size setting -- a
    // share of the pane height, so it scales with the window -- and the panel
    // sets width and height from it.

    // On screen whenever there is something to show: real artwork, or the disc when
    // an album has none and the placeholder is left on. With the placeholder off
    // and no artwork, the whole frame goes -- empty corner rather than a graphic
    // standing in for a cover that does not exist, which is how this behaved
    // before the disc was drawn.
    visible: root.placeholder || root.showingArt

    // Outward border: a larger rounded rectangle behind the artwork, so the
    // visible ring sits on the dark pane background rather than on the image.
    // That keeps the border readable on bright covers and frames the cover
    // into the surrounding UI instead of letting it float above the panel.
    // The clipped image on top covers the centre, leaving only the ring.
    Rectangle {
        anchors.centerIn: parent
        width: parent.width + Math.max(2, Math.round(2 * root.coverBorderWidth * root.uiScale))
        height: parent.height + Math.max(2, Math.round(2 * root.coverBorderWidth * root.uiScale))
        radius: root.cornerRadius
        color: Util.alpha(root.colForeground, 0.24)
        visible: root.coverBorder
    }

    Rectangle {
        id: clipRect
        anchors.fill: parent
        radius: root.cornerRadius
        // Item.clip cuts to the bounding rectangle, not to the rounded shape, so
        // on its own it leaves the artwork's own square corners sticking out past
        // the radius and the frame reads as a rounded border drawn over a square
        // photo. The layer below masks the whole subtree by the rounded outline
        // instead, which is what actually has to happen to the corners. clip stays
        // on to catch any sub-pixel bleed at the straight edges.
        clip: true
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: artMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 0.02
        }
        // Opaque, and in the panel's own background colour, so the frame behind this
        // shows as nothing but its rim. The frame is a filled rectangle rather than
        // an outline -- the artwork is meant to cover its centre and leave only the
        // ring -- which meant that with no artwork its fill showed straight through
        // and the placeholder sat on a pale slab, which is what made it read as a
        // lit square rather than as a CD on the pane. It also gives the centre hole
        // something true to be a hole in.
        color: root.colBackground

        // Shown until real art is Ready, and permanently when the album has none.
        // A CD sitting on the pane, drawn as a circle and nothing else: the earlier
        // version washed the whole square with a gradient, and that square was the
        // problem -- it made the placeholder read as a lit tile with a faint circle
        // on it rather than as a disc. Only the disc is painted now, and nothing
        // behind it.
        //
        // Every tone is `muted`, which is the hue the panel already uses for
        // de-emphasised text. `foreground` is the theme's text colour, bright by
        // design, so anything drawn in it at a strength you can see pulls the eye
        // towards an empty shape -- and the placeholder is the one element here
        // never meant to be read.
        // An Item, not a Rectangle: this only exists to centre the disc, and a
        // Rectangle with no colour of its own falls back to opaque white. It was a
        // gradient until recently, which masked that default.
        Item {
            anchors.fill: parent
            visible: !root.showingArt

            Rectangle {
                anchors.centerIn: parent
                width: Math.round(parent.width * 0.76)
                height: width
                radius: width / 2
                color: Util.alpha(root.colMuted, 0.05)
                border.width: 1
                border.color: Util.alpha(root.colMuted, 0.16)

                // The spindle hole, which is what makes a circle read as a CD rather
                // than as a dot. Punched back out to the panel background rather
                // than tinted: a centre lighter than the disc looks like a spot
                // printed on it, which is what the old accent dot came across as.
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.round(parent.width * 0.15)
                    height: width
                    radius: width / 2
                    color: root.colBackground
                }
            }
        }

        // The cover currently on screen, held under the incoming layer so that an
        // album change crossfades instead of blinking through the placeholder while
        // the next picture is found and loaded. A source rather than a copy of the
        // pixels: both layers are the same kind of Image, and this one is simply
        // the picture the incoming one last settled on. Empty before any cover has
        // loaded, which is what leaves the disc showing through.
        Image {
            id: held
            anchors.fill: parent
            source: root.heldSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            smooth: true
            mipmap: true
            // Decode at display size in physical pixels rather than at the
            // source's full resolution, which is what keeps a large sidecar
            // from filling the pixmap cache while the lists scroll.
            sourceSize.width: width > 0 ? Math.round(width * (root.pixelRatio || 1)) : 0
            sourceSize.height: height > 0 ? Math.round(height * (root.pixelRatio || 1)) : 0
        }

        Image {
            id: art
            anchors.fill: parent
            source: root.overrideSource !== "" ? root.overrideSource : root.imageSource
            opacity: root.incoming
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            smooth: true
            mipmap: true
            sourceSize.width: width > 0 ? Math.round(width * (root.pixelRatio || 1)) : 0
            sourceSize.height: height > 0 ? Math.round(height * (root.pixelRatio || 1)) : 0

            onStatusChanged: {
                if (status === Image.Ready) {
                    root.resolving = false
                    root.foundArt = true
                    // The quantizer's cue to run: the picture it has to read is now
                    // the one on screen. Set here rather than left on imageSource so
                    // the colour pass is not run once per candidate the walk tries.
                    root.resolvedSource = String(art.source)
                    root.resetOnline()
                    root.reveal()
                    return
                }
                if (status !== Image.Error) return
                // An error settles whatever was in flight: no picture is coming.
                root.resolving = false
                // A previewed image is not part of the candidate walk: whatever it
                // did, there is no next name to try.
                if (root.overrideSource !== "") return
                // The cached download was being tested and is not there, so the
                // stores are the next question.
                if (root.onlineState === "probe") { root.startOnlineFetch(); return }
                // A download that was fetched but will not load is treated as a
                // miss: the album is remembered as having no online art and the
                // placeholder stays, rather than the probe looping.
                if (root.onlineState === "show") {
                    root.markNoOnline(root.onlineDir)
                    root.resetOnline()
                    root.runQueuedOnline()
                    return
                }
                // This candidate is not on disk. Try the next name; when they are
                // all exhausted the placeholder stays on screen, which is the right
                // outcome for an album with no art beside the tracks -- unless the
                // artwork is inside the file, which is the last thing worth asking.
                var next = root.candidateIndex + 1
                if (next < root.candidates.length) {
                    root.candidateIndex = next
                    root.imageSource = Covers.fileUrl(root.candidates[next])
                } else {
                    // Engage the embedded fallback before declaring the walk done,
                    // so noArt cannot read true in the gap between the two: the
                    // request is what puts the decision in the extractor's or the
                    // online machine's hands, and both keep noArt false.
                    root.requestEmbedded(root.loadedDir)
                    root.walkDone = true
                }
            }
        }
    }

    // Mask source for clipRect's layer. MultiEffect samples it as an alpha
    // silhouette, so the item itself must never be composited into the scene --
    // visible: false keeps it off screen, and layer.enabled is what still gets it
    // rendered into a texture for the effect to read.
    Item {
        id: artMask
        anchors.fill: parent
        visible: false
        layer.enabled: true

        Rectangle {
            anchors.fill: parent
            radius: clipRect.radius
            color: "white"
        }
    }

}