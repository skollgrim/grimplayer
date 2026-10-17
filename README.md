# GrimPlayer

An MPD browser for the [Omarchy](https://omarchy.org) shell: artist, album and
track panes with cover art and a now-playing strip, written as a Quickshell
plugin. It talks to MPD over its Unix socket and stays in sync by push, so
nothing polls.

![GrimPlayer](preview.png)

With **Recolor from cover art** on, the panel follows the playing album's sleeve:

![GrimPlayer recoloured from the album art](preview2.png)

## What it does

- **Simple and minimal.** Three lists and a strip, nothing to import or index:
  point it at the library, press `Enter` and it plays.
- **Three panes** — artists, albums for the selected artist, tracks for the
  selected album, with the playing track marked by an accent bar on either or both
  sides of its row (a setting picks none, left, right or both). Each pane is topped
  by a heading — the pane's name over a rule — which a setting can turn off so the
  lists start at the very top of their panes, and the rules between the panes are a
  setting too.
- **The queue is derived, not managed.** Activating a track plays it and
  everything below it in view order: simply the next song in the album, and on
  into the next album when that album runs out. There is no queue screen to keep
  in sync and no stored playlists.
- **Album repeat** is a third repeat mode. MPD's repeat flag repeats whatever
  the queue holds, so this mode narrows the queue to the playing album and
  restarts it when it runs out.
- **Cover art** is looked for in the album's own directory first, with a probe
  list (`cover.jpg`, `folder.jpg`, `cover.png`, `front.jpg`, `album.jpg`, the
  capitalised spellings, and the tag-derived `<artist> - <album>` / `<album>`
  names). A single-file album played through a cue sheet resolves to the folder
  beside the cue, not to MPD's virtual `<album>.cue/track0001` path, so artwork
  sitting next to the rip is found. An album with nothing beside the tracks falls
  back to the artwork embedded in the file itself, extracted once with `ffmpeg`
  and cached under `~/.local/state/skollgrim.grimplayer/covers/`. An album with
  nothing anywhere can have a cover **looked up online** instead — iTunes,
  then Deezer — and cached the same way, so a clean online sleeve shows where a
  scan or a blank square would. This is on by default and turned off with
  **Fetch missing cover art** under *Optional features* in the settings; off,
  such albums keep the placeholder and the player stays entirely offline.
  Changing album keeps the current cover on screen until the next one is
  loaded, so the art never blinks through the placeholder; a setting can fade
  the new cover in over the old one (instant by default).
- **Recolor from cover art** — a setting that recolours the whole panel
  (background, text and accent) from the sleeve of the album that is playing,
  with the alert colour kept semantic. Off, it follows the shell theme.
- **Typeahead** — typing letters jumps the caret to the first matching row.
- **A settings card for all of it** (`Alt` + `S`) — row height and spacing,
  fonts and scale, borders and dividers, pane headings, the playing marker,
  cover art, and the optional extras, laid out as four columns and persisted to
  `~/.local/state/skollgrim.grimplayer/settings.json`.
- **Vim motions** — `j` `k` `h` `l` `g` `G` alongside the arrows (a setting);
  with them on, `Shift` + `h`/`l` seek like `Shift` + `←`/`→`.
- **Key reference** (`?`) — a cheat sheet of the browser keys, plus how to
  reach the settings card, the tag editor and the reference itself.

## Optional features

Everything here is optional, and so are the dependencies each one needs. With
none of it installed the player still browses, plays, and shows any cover art
that sits beside the tracks. What a missing dependency costs depends on the
feature: a cover that cannot be found falls back to the placeholder, while a row
with a job of its own reports the failure there. The table says which is which.

| Feature | Needs | Without it |
| --- | --- | --- |
| Embedded cover art | `ffmpeg` | Albums whose artwork is inside the file fall back to the placeholder; sidecar and fetched art are unaffected. |
| Tag and cover editing, country flags | `mid3v2` (MP3) or `metaflac` (FLAC), and `zenity` to pick a cover file | The tag editor opens and shows what the files hold, but saving writes nothing and Browse cannot choose a cover file. |
| Look up | `python3` with [`mutagen`](https://mutagen.readthedocs.io/) and [`musicbrainzngs`](https://python-musicbrainzngs.readthedocs.io/), and network access | The Match row reports the failure; editing by hand still works. |
| Fetch missing cover art | `python3` (standard library only) and network access | Albums with no artwork keep the placeholder. On by default; turned off under **Optional features** in the settings. |

## Requirements

- Omarchy 4.x, with third-party plugin support (`omarchy plugin add`).
- [MPD](https://www.musicpd.org/) with a Unix socket. The default location is
  `~/.mpd/socket`; set `GRIM_LIBRARY_MPD_SOCKET` to point somewhere else.

Nothing else is required. The features that need extra tools or a network
connection are listed in [Optional features](#optional-features).

## Install

```bash
omarchy plugin add https://github.com/skollgrim/grimplayer.git
omarchy plugin enable skollgrim.grimplayer
```

`add` clones into `~/.config/omarchy/plugins/skollgrim.grimplayer/` and lands
the plugin disabled so you can read it first; `enable` records it in
`shell.json`. `add` confirms in a terminal — it prints what it is about to do —
while `enable` does not prompt; `omarchy plugin add --yes` skips the prompts if
you are scripting.

Optional, to get GrimPlayer in the app launcher:

```bash
install -Dm644 extras/GrimPlayer.desktop ~/.local/share/applications/GrimPlayer.desktop
```

### Opening it

GrimPlayer ships no keybinding, because which key opens it is a matter of taste.
The shell exposes three verbs for it:

```bash
omarchy-shell -q shell summon skollgrim.grimplayer   # open, or do nothing if open
omarchy-shell -q shell toggle skollgrim.grimplayer   # open if closed, close if open
omarchy-shell -q shell hide   skollgrim.grimplayer   # close
```

`summon` is the one to reach for from a launcher or a script: it is idempotent, so
binding it to a key cannot accidentally toggle the panel shut. A keybinding is
then a one-liner around whichever of the three you prefer.

## Keys

| Key | Action |
| --- | --- |
| `↑` `↓` | Change row |
| `←` `→` | Change pane |
| any letter or digit | Typeahead |
| `Enter` | Play the artist, album or track under the caret |
| `Space` | Play / pause |
| `Shift` + `←` `→` | Seek ∓ 5 s |
| `j` `k` | Change row *(Vim keys on)* |
| `h` `l` | Change pane *(Vim keys on)* |
| `Shift` + `h` `l` | Seek ∓ 5 s *(Vim keys on)* |
| `g` / `G` | First / last row *(Vim keys on)* |
| `Alt` + `S` | Settings card |
| `Alt` + `T` | Tag editor |
| `?` | Key reference |

In the settings card: arrows or `hjkl` move — up/down moves within a column,
left/right crosses the four columns — `Enter` (or `Space`) toggles a switch or
opens a slider, `←` `→` (or `h` `l`) adjust the open slider, `g` / `G` jump to the
first or last setting, `R` resets everything, `?` switches to the key reference,
`Esc` steps back out and `Q` closes.

The card shows the switches and named choices in one column, the sizes and
sliders in the next, every artwork setting together in a third, and the optional
extras last, so a setting is always in the same place. A setting that only matters
while another is on — a cover border's width, the artwork pane's position — stays
hidden until its parent is switched on, and its value is kept for when it comes
back.

In the key reference: it lists the browser keys and how to reach each screen;
`Esc`, `Q` or `?` closes it.

In the tag editor: `Enter`, the **Save** button and **Close** all do the same
thing (see below); `Esc` or **Cancel** discards and closes at once, with no
confirmation, because nothing is written until Save; `Tab` / `↑` `↓` move
through the fields, the match row, the cover row and the two decision buttons,
wrapping at both ends. On the match row, `←` `→` move between Look up, Prev,
Next and Revert; on the cover row, `←` `→` move between Browse and Remove. `L`
runs a lookup from the card itself — a field that has focus just types the
letter.

### Tag editor

`Alt` + `T` edits the tags of whatever the caret is on: one track in the tracks
pane, the whole album in the albums pane, or everything by that artist in the
artists pane. It can also be opened without focusing the panel:

```sh
omarchy-shell skollgrim.grimplayer editTags
```

Each field shows what the selected tracks agree on. A field they disagree about
reads `multiple` and is **not written** — so retagging a genre across an album
cannot quietly flatten the track titles with it. Change it and that one value is
written to every selected track; clear it and the tag is removed. Opening the
editor and saving without touching anything writes nothing. Once a save lands,
the button reads **Close** until you edit again — so the same key finishes the
session rather than answering “Nothing changed”.

Fields: Title, Artist, Album artist, Album, Track, Disc, Year, Genre, Country.

Below them, reading as one more field, is a **Cover art** row: a small preview of
the selection's cover, a **Browse…** button that opens a file chooser in the album
folder (so the covers already beside the tracks are the first thing on offer), and
a **Remove** button. Saving a chosen image embeds it into every selected file;
removing strips the embedded picture back out. The album folder itself is left
alone either way — no `cover.jpg` is written and an existing one is not touched —
so the embedded copy is what travels with the files, and the cached extraction is
dropped so the player re-reads what the files now hold.

Because the folder is left alone, an album that already has a sidecar image would
otherwise keep showing it. The editor therefore remembers the decision per album
(in `~/.local/state/skollgrim.grimplayer/coveroverrides.json`): a set cover tells
the player to show the embedded picture and ignore the sidecar beside the tracks,
and a removal tells it to show no art at all rather than falling back to the
sidecar or the stores. The choice survives a restart and is undone by deleting
that album's entry from the file (or the file itself).

Above it, reading as one more field, is a **Match** row with a **Look up** button:
it searches [MusicBrainz](https://musicbrainz.org/) for the selected album and
pre-fills everything from the best match — Artist, Album artist, Album, Year and
Country, each track's own Title, Track and Disc, and a front cover. The cover is
not taken from MusicBrainz: the two stores that serve clean, square, high-res
sleeves (iTunes, then Deezer) are asked first, at up to 1200px, and the
[Cover Art Archive](https://coverartarchive.org/) is used only when neither has
a confident match. The status line says which source won and how big it is. It
writes nothing on its own: the match is shown so it can be reviewed, corrected
by hand, or stepped past with **Next** before Save commits it. Every field the
match moved shows a muted `was:` line with what it held before, so the change
can be judged rather than trusted, and a **Revert** button beside the match
buttons hands the selection back — every field and the cover — to what it held
before the first lookup. Revert keeps the candidates, so **Next** can still
re-apply a match afterwards.

The search uses the selection's own Artist and Album tags; for a folder that has
none, it falls back to the `Artist/Album` directory names. When several pressings
match, the folder's year and track count rank them, and **Prev** /
**Next** walk the candidates — each step re-fetches only that release, so a
wrong first guess costs one click rather than a retype. It is offered for a single
album only: a selection spanning several albums (an artist's whole shelf) is
refused rather than guessed at. Look up needs `python3` with `mutagen` and
`musicbrainzngs` (see Requirements); without them the row reports the failure and
the editor is otherwise unchanged.

Country takes a two-letter ISO code (`SE`, `FI`, `US`) rather than a name, and
the flag shown beside the field is the one the now-playing strip will show.
Releases tagged Worldwide (`XW`, which MusicBrainz uses when there is no single
territory) get a globe instead, since there is no flag to draw.

The UK home nations have no two-letter code of their own — ISO 3166-1 gives the
UK a single `GB` — so they are accepted as ISO 3166-2 subdivisions, which is what
the subdivision flag emoji are keyed on: `GB-ENG`, `GB-SCT` and `GB-WLS`.
Northern Ireland (`GB-NIR`) is left out, because the emoji font has no glyph for
it and it renders as an empty white flag.

MPD cannot write tags — it treats the library as read-only — so the files are
edited in place by `mid3v2` and `metaflac`, one file at a time. Both rewrite only
the tag block and leave the audio alone. Nothing else is discovered at runtime
and there is no re-encoding fallback.

Some things to know:

- **Cue sheets are skipped.** MPD presents a cue album as one virtual song per
  track, at a path (`<album>.cue/track0001`) that does not exist on disk. Their
  per-track tags live inside the cue sheet, which these tools cannot open, so
  they are reported as skipped rather than guessed at.
- **Country is not a tag MPD reports.** MPD's song model has no country field at
  all, so the value is read from the file directly — once per album, then kept in
  `~/.local/state/skollgrim.grimplayer/countries.json`, including when the answer is
  "no country here". Editing it through GrimPlayer updates that cache.
- The tag is Picard's, which is what most libraries are already tagged with:
  `MusicBrainz Album Release Country` on MP3, and both
  `MUSICBRAINZ_ALBUMRELEASECOUNTRY` and `RELEASECOUNTRY` on FLAC.

The mouse works too: click a row to select it and move the caret into the next
pane (playback still needs `Enter`), click a setting to change it, drag the seek
bar or the volume slider, click the volume icon to mute.

## Notes and limitations

- **Embedded artwork needs `ffmpeg`, and is always the second choice.** MPD can
  serve it (`albumart`), but this plugin talks to MPD over a text socket, and a
  JPEG does not survive that decoding, so the file is handed to `ffmpeg` instead.
  Without it, an album with no sidecar image keeps the placeholder exactly as
  before. Where both exist, the sidecar wins — see
  [`CoverArt.qml`](CoverArt.qml) for why. The one exception is an album whose
  cover was set or removed through the tag editor: that decision is remembered,
  and the embedded picture (or nothing) wins there until the entry is deleted. For a cue album the audio is a single
  file beside the cue whose name MPD never reports, so `ffmpeg` is pointed at
  the cue's own stem with the usual rip extensions tried in turn; a cue whose
  audio is named differently will not have its embedded art found.
- **Fetched covers are the last choice and are never written into the music.** A
  downloaded cover is cached as `covers/<hash>.online.jpg`, beside the
  `<hash>.jpg` the `ffmpeg` extraction writes, and is used only once the sidecars
  and the embedded picture have both come up empty — so a store's guess never
  stands in for what the file actually holds, and clearing the embedded art lets
  the download show again. Nothing is written to the album folder and no sidecar
  is created. Removing a cover by hand hides the download for that album, so a
  deliberate removal stays empty rather than being filled back in; the decision is
  remembered — see the tag editor's cover overrides above — so a shell restart
  keeps it empty too, until that album's entry is deleted from
  `coveroverrides.json`. Deleting the file under
  `~/.local/state/skollgrim.grimplayer/covers/` forces a fresh lookup. Asking the
  stores means telling them the artist and album name — the same query iTunes and
  Deezer's own search boxes send — so this is on by default but can be turned off
  for a library that should stay offline.
- **The music directory** is assumed to be `~/Music`, honouring `XDG_MUSIC_DIR`
  when it is exported, which should match MPD's `music_directory`.
- **Typeahead accepts ASCII letters and digits plus `æøåÆØÅ`.** Widen the regex
  at the bottom of the key handler in `GrimPlayer.qml` for other scripts.
- **Album repeat is client-side**, so there is a fraction of a second of silence
  at the album boundary.
- **No stored playlists and no queue view**, by design: the queue is always the
  tail of the library from wherever you are.

## Development

The plugin is two entry points: `GrimPlayerMpd.qml` (the service — socket,
protocol, library tree, queue policy) and `GrimPlayer.qml` (the panel). The
socket has to outlive the panel, hence `kinds: ["service", "panel"]` with
`keepLoaded`.

Adaptive colouring is two more files: [`GrimTheme.qml`](GrimTheme.qml) holds the
panel's own colour tokens and folds a cover's palette into them, and
[`Palette.js`](Palette.js) is the pure colour maths behind it. The shell's
`Color` singleton is global, so the panel never writes to it — it keeps this
copy instead. `CoverArt.qml`'s `ColorQuantizer` exposes the palette the panel
reads.

Edit the files under `~/.config/omarchy/plugins/skollgrim.grimplayer/` and the
shell reloads the panel on save. The service is `keepLoaded`, so changes to
`GrimPlayerMpd.qml` only take effect after a shell restart (`omarchy restart
shell`). `Palette.js` is a `.pragma library`, which the engine caches across
plugin reloads, so colour-maths changes also need a full shell restart rather
than just a save.

Check a manifest before pushing it out:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/skollgrim.grimplayer
```

There is no test harness — this is a UI plugin, so it is verified against a live
MPD: kill MPD underneath it, restart it, add an album and confirm the tree
follows.

## Licence

MIT. See [LICENSE](LICENSE).
