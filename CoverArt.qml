// Album art for the track currently playing.
//
// MPD has no image protocol and no albumart plugin is configured here, so the
// artwork is read straight off disk instead: MPD's `file` is a library-relative
// path, so the album's own directory is just its parent, and the cover is the
// conventional cover.jpg in that directory. That is the layout of the collection
// this was written against -- the covers sit next to the tracks rather than being
// tagged into them. Libraries whose artwork is embedded in the files get the
// placeholder instead.
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
// taggers use when one folder holds several releases.
//
// The walk is driven by the Image's own load status rather than by a separate
// existence check. Qt6 dropped QtQuick's FileIO entirely, and the alternative --
// probing with a throwaway loader and then handing the path to the Image -- reads
// every cover twice. Letting the Image that has to load the file anyway report
// back whether it worked costs nothing and needs no extra API.
import QtQuick
import QtQuick.Effects
import Quickshell
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

    // Always on screen. An album with no cover on disk used to hide the whole
    // frame, which read as a hole punched in the pane. The frame now falls back
    // to a placeholder instead, so "no artwork" looks deliberate.
    visible: true

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
        color: Qt.rgba(1, 1, 1, 0.30)
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
        color: Qt.rgba(1, 1, 1, 0.03)

        // Shown until real art is Ready, and permanently when the album has
        // none. Kept deliberately plain and very faint: the placeholder has to
        // sit back into the dark pane rather than read as a bright card, since
        // it covers a large area of the tracks list. Every tone here is a low
        // white overlay on the panel background, so lowering the alpha lowers
        // the whole thing without changing the hue it themes with.
        Rectangle {
            anchors.fill: parent
            visible: art.status !== Image.Ready

            gradient: Gradient {
                GradientStop { position: 0.0; color: Util.alpha(Color.foreground, 0.03) }
                GradientStop { position: 1.0; color: Util.alpha(Color.foreground, 0.01) }
            }

            Rectangle {
                anchors.centerIn: parent
                width: Math.round(parent.width * 0.60)
                height: width
                radius: width / 2
                color: Util.alpha(Color.foreground, 0.025)
                border.width: 1
                border.color: Util.alpha(Color.foreground, 0.06)

                // Label. The one hint of accent, held low so it themes the
                // placeholder without becoming the brightest thing on screen.
                Rectangle {
                    anchors.centerIn: parent
                    width: Math.round(parent.width * 0.28)
                    height: width
                    radius: width / 2
                    color: Util.alpha(Color.accent, 0.06)
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
                // This candidate is not on disk. Try the next name; once they are
                // all exhausted imageSource stays put on the last failure and the
                // placeholder below stays on screen, which is the right outcome
                // for an album with no art.
                var next = root.candidateIndex + 1
                if (next < root.candidates.length) {
                    root.candidateIndex = next
                    root.imageSource = "file://" + root.candidates[next]
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
