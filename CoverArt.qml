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

Item {
    id: root

    // Declared explicitly rather than reaching for the panel's own `mpd`: a
    // sibling component file does not inherit the panel root's scope, so it has
    // to be handed the service.
    property var mpd: null

    // MPD reports paths relative to its music_directory, which mpd.conf sets to
    // $XDG_MUSIC_DIR with ~/Music as the fallback on the next line.
    readonly property string musicDir: Quickshell.env("XDG_MUSIC_DIR") || (Quickshell.env("HOME") + "/Music")

    // ---- embedded artwork cache ----
    //
    // Sits beside the settings file the panel already keeps, because it is the
    // same kind of thing: something derived from the library that should survive a
    // shell restart without being recomputed. Keyed by album rather than by track,
    // since every track on an album carries the same picture.
    readonly property string cacheDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/skollgrim.grimplayer/covers"

    // FNV-1a. Only has to be stable and well spread, not cryptographic: a collision
    // would mean one album showing another's artwork, which is vanishingly unlikely
    // at this scale and no worse than the filename collisions the probe already
    // tolerates. A readable album-directory name would not do -- the names contain
    // slashes and characters the filesystem treats specially.
    //
    // Math.imul is not an optimisation, it is the only correct option here. The
    // naive `h * 16777619` multiplies a 32-bit value by a 24-bit one and lands
    // around 2^56, which is past Number.MAX_SAFE_INTEGER, so the double silently
    // drops low bits and two different albums can land on the same name. imul does
    // the multiply in 32-bit space where it cannot.
    function cacheStem(dir) {
        var h = 0x811c9dc5
        for (var i = 0; i < dir.length; i++) {
            h ^= dir.charCodeAt(i)
            h = Math.imul(h, 0x01000193)
        }
        return ("00000000" + (h >>> 0).toString(16)).slice(-8)
    }

    function cachedCover(dir) {
        return root.cacheDir + "/" + root.cacheStem(dir) + ".jpg"
    }

    // The track file itself, which is what ffmpeg is pointed at. Asking MPD for the
    // path beats searching the album directory for something audio-shaped: it is the
    // file that is actually playing, so there is no guessing about which one carries
    // the artwork.
    function currentFilePath() {
        if (!mpd || !mpd.current || !mpd.current.file) return ""
        return root.musicDir + "/" + String(mpd.current.file)
    }

    // Album directories already found to carry no embedded art. In memory rather
    // than as marker files on disk: ffmpeg runs again for them once per shell
    // session, which for a handful of albums is invisible, and it keeps the state
    // directory holding only things worth keeping.
    property var noEmbedded: ({})

    property string extractingDir: ""
    property string queuedDir: ""

    // Point the Image straight at a cached cover we know exists, rather than
    // walking the candidate list again for an answer already in hand.
    function showCached(dir) {
        var target = "file://" + root.cachedCover(dir)
        // The Image is sitting in Error on this exact URL, and assigning a property
        // the value it already holds does not re-evaluate it. Clearing it first is
        // what makes the next assignment a change the Image reacts to.
        root.imageSource = ""
        Qt.callLater(function () { root.imageSource = target })
    }

    // Last resort for the sidecar-less: pull the picture out of the track itself.
    //
    // Re-encoding to mjpeg rather than copying the embedded stream, so the cached
    // file is always a real JPEG at a real extension. Copying would be faster and
    // lossless, but the source can be a PNG, and naming that .jpg leaves the cache
    // depending on the image loader sniffing past the extension. The cover is drawn
    // at coverSize (210px by default), so nothing is lost by rescaling a 1200px
    // original down to something displayable.
    function requestEmbedded(dir) {
        if (!dir || extractor.running) {
            if (dir) queuedDir = dir
            return
        }
        if (root.noEmbedded[dir] === true) return
        var file = currentFilePath()
        if (!file) return
        extractor.command = ["ffmpeg", "-v", "error", "-y",
                             "-i", file,
                             "-an", "-map", "0:v:0", "-frames:v", "1",
                             "-c:v", "mjpeg", "-q:v", "3",
                             root.cachedCover(dir)]
        root.extractingDir = dir
        extractor.running = true
    }

    Process {
        id: extractor
        running: false
        command: []
        onExited: function (exitCode) {
            var dir = root.extractingDir
            root.extractingDir = ""
            // ffmpeg exits non-zero on a track with no attached picture, which is
            // the common case and not an error worth surfacing -- it just means this
            // album keeps the placeholder, so remember it and stop asking.
            if (exitCode !== 0) {
                var missing = root.noEmbedded
                missing[dir] = true
                root.noEmbedded = missing
            } else if (dir === root.loadedDir) {
                root.showCached(dir)
            }
            if (root.queuedDir) {
                var next = root.queuedDir
                root.queuedDir = ""
                root.requestEmbedded(next)
            }
        }
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

    // The frame is sized by the parent (coverSize * uiScale); this only carries
    // the scale so the corner radius rides along with it.
    property real uiScale: 1.0

    // Ring around the artwork. The toggle and its thickness are separate so the
    // ring can be dropped without losing the thickness it was set to.
    property bool coverBorder: true
    property int coverBorderWidth: 1

    // Whether an album with no artwork anywhere shows the disc at all. Off leaves
    // the corner empty rather than standing in a graphic for a cover that does
    // not exist -- which is what this used to do unconditionally, before the
    // disc was drawn at all. Real artwork always shows regardless: this is only
    // about the absence of a cover.
    property bool placeholder: true

    // Album directory whose cover is currently displayed. Used to skip redundant
    // probes; see refresh().
    property string loadedDir: ""

    // Parent directory of the current track:
    // "Some Artist/2019 - Some Album [Live]/12 - Track.flac" -> "Some Artist/2019
    // - Some Album [Live]".
    //
    // Computed imperatively rather than as a binding. The service is injected
    // after this component is created, and the handler that reacts to that
    // injection runs immediately -- before the albumDir binding has been
    // re-evaluated, so a bound property still read back as empty and the panel
    // never found the cover for a track that was already playing.
    function currentAlbumDir() {
        if (!mpd || !mpd.current || !mpd.current.file) return ""
        var f = String(mpd.current.file)
        var i = f.lastIndexOf("/")
        return i > 0 ? f.substring(0, i) : ""
    }

    // Tag value for the current track, or "" when MPD has nothing loaded. Album
    // art is sometimes named after the tags rather than a fixed word, so the
    // candidate list needs them.
    function currentTag(key) {
        if (!mpd || !mpd.current) return ""
        var v = mpd.current[key]
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

    // cover.jpg is only a convention. folder.jpg, cover.png, front.jpg and
    // album.jpg all turn up in real collections, and stopping at the first name
    // would mean a silently blank square for those albums.
    //
    // The capitalised spellings are listed after the lowercase ones because the
    // filesystem is case sensitive: Cover.jpg and Folder.jpg are not found by a
    // request for cover.jpg, and capitalised names are common. The
    // tag-derived names come last so that a folder holding both cover.jpg and
    // "<album>.jpg" still resolves to cover.jpg, the way it did before.
    function candidateList(dir) {
        if (!dir) return []
        var names = ["cover.jpg", "folder.jpg", "cover.png", "front.jpg", "album.jpg",
                     "Cover.jpg", "Folder.jpg", "Cover.png", "Front.jpg", "Album.jpg"]
        var named = namedCandidates()
        for (var n = 0; n < named.length; n++) names.push(named[n])
        var out = []
        for (var i = 0; i < names.length; i++) {
            out.push(root.musicDir + "/" + dir + "/" + names[i])
        }
        // Last, so anything on disk wins. The cached extraction is a fallback for
        // albums a tagger left with no sidecar file at all, not a replacement for
        // one: where both exist the sidecar is what the user (or the tagger) put in
        // the folder, and re-tagging the file should not silently change the cover.
        out.push(root.cachedCover(dir))
        return out
    }

    function probe() {
        candidates = candidateList(currentAlbumDir())
        candidateIndex = 0
        imageSource = candidates.length > 0 ? "file://" + candidates[0] : ""
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
    function refresh() {
        var dir = currentAlbumDir()
        if (dir === loadedDir) return
        loadedDir = dir
        probe()
    }

    Connections {
        target: root.mpd
        function onCurrentChanged() { root.refresh() }
        function onConnectedChanged() {
            if (root.mpd.connected) root.refresh()
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
    // one large element on the screen and it was reading as an afterthought at
    // 168px. The size comes from the coverSize setting (210 by default, which
    // keeps it a cover rather than a thumbnail while still leaving room for the
    // tracks list beside it); the panel sets width and height from it.

    // On screen whenever there is something to show: real artwork, or the disc when
    // an album has none and the placeholder is left on. With the placeholder off
    // and no artwork, the whole frame goes -- empty corner rather than a graphic
    // standing in for a cover that does not exist, which is how this behaved
    // before the disc was drawn.
    visible: root.placeholder || art.status === Image.Ready

    // Outward border: a larger rounded rectangle behind the artwork, so the
    // visible ring sits on the dark pane background rather than on the image.
    // That keeps the border readable on bright covers and frames the cover
    // into the surrounding UI instead of letting it float above the panel.
    // The clipped image on top covers the centre, leaving only the ring.
    Rectangle {
        anchors.centerIn: parent
        width: parent.width + Math.max(2, Math.round(2 * root.coverBorderWidth * root.uiScale))
        height: parent.height + Math.max(2, Math.round(2 * root.coverBorderWidth * root.uiScale))
        radius: Math.round(10 * root.uiScale)
        color: Util.alpha(Color.foreground, 0.24)
        visible: root.coverBorder
    }

    Rectangle {
        id: clipRect
        anchors.fill: parent
        radius: Math.round(10 * root.uiScale)
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
        color: Color.background

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
            visible: art.status !== Image.Ready

            Rectangle {
                anchors.centerIn: parent
                width: Math.round(parent.width * 0.76)
                height: width
                radius: width / 2
                color: Util.alpha(Color.muted, 0.05)
                border.width: 1
                border.color: Util.alpha(Color.muted, 0.16)

                // The spindle hole, which is what makes a circle read as a CD rather
                // than as a dot. Punched back out to the panel background rather
                // than tinted: a centre lighter than the disc looks like a spot
                // printed on it, which is what the old accent dot came across as.
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.round(parent.width * 0.15)
                    height: width
                    radius: width / 2
                    color: Color.background
                }
            }
        }

        Image {
            id: art
            anchors.fill: parent
            source: root.imageSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            smooth: true
            mipmap: true

            onStatusChanged: {
                if (status !== Image.Error) return
                // This candidate is not on disk. Try the next name; when they are
                // all exhausted the placeholder stays on screen, which is the right
                // outcome for an album with no art beside the tracks -- unless the
                // artwork is inside the file, which is the last thing worth asking.
                var next = root.candidateIndex + 1
                if (next < root.candidates.length) {
                    root.candidateIndex = next
                    root.imageSource = "file://" + root.candidates[next]
                } else {
                    root.requestEmbedded(root.loadedDir)
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
