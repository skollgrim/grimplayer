# GrimPlayer

An MPD browser for the [Omarchy](https://omarchy.org) shell: artist, album and
track panes with cover art and a now-playing strip, written as a Quickshell
plugin. It talks to MPD over its Unix socket and stays in sync by push, so
nothing polls.

![GrimPlayer](preview.png)

## What it does

- **Three panes** — artists, albums for the selected artist, tracks for the
  selected album, with the playing track marked.
- **Now-playing strip** — artwork, title/artist, elapsed and total time, a seek
  bar, transport (previous, play/pause, next, shuffle, three-state repeat) and
  volume with click-to-mute.
- **The queue is derived, not managed.** Activating a track fills MPD's queue
  with that track *and everything below it in view order*, so playback runs on
  past the end of the album. There is no queue screen to keep in sync and no
  stored playlists.
- **Album repeat** is a third repeat mode. MPD's repeat flag repeats whatever
  the queue holds, so this mode narrows the queue to the playing album and
  restarts it when it runs out.
- **Cover art** is read from the album's own directory, with a probe list
  (`cover.jpg`, `folder.jpg`, `cover.png`, `front.jpg`, `album.jpg`, the
  capitalised spellings, and the tag-derived `<artist> - <album>` / `<album>`
  names).
- **Typeahead** — typing letters jumps the caret to the first matching row.
- **Settings card** (`?`) for sizes, fonts, borders, spacing and behaviour,
  persisted to `~/.local/state/grimplayer/settings.json`.
- Follows the active Omarchy theme; every colour and size comes from the shell's
  own `Style`/`Color` tokens.

## Requirements

- Omarchy 4.x, with third-party plugin support (`omarchy plugin add`).
- [MPD](https://www.musicpd.org/) with a Unix socket. The default location is
  `~/.mpd/socket`; set `GRIM_LIBRARY_MPD_SOCKET` to point somewhere else.

## Install

```bash
omarchy plugin add https://github.com/skollgrim/grimplayer.git
omarchy plugin enable skollgrim.grimplayer
```

`add` clones into `~/.config/omarchy/plugins/skollgrim.grimplayer/` and lands
the plugin disabled so you can read it first; `enable` records it in
`shell.json`. Both commands want a terminal — they print what they are about to
do — and `omarchy plugin add --yes` skips the prompts if you are scripting.

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

### Windowing

GrimPlayer asks for no placement and no size. The window is an ordinary one, and
nothing in the plugin overrides what the window manager decides to do with it.

What that costs is a fallback: the panel has no size of its own to offer. The
panes size themselves from the window width (0.26, 0.30, and the remainder for
tracks), and a purely proportional layout has no way to state how large it would
like to be. Given a size it fills it exactly.

One detail worth knowing if anything needs to tell this window apart from
others: Quickshell's `FloatingWindow` exposes no `appId`, so every Quickshell
window reports the same class. The window title is therefore fixed at
`"GrimPlayer"` and set in `GrimPlayer.qml`, because it is the most specific
handle anything can match on.

### Borderless

Optional, and not a plugin setting: the panel draws no border and asks for no
decorations or margins, so whatever surrounds the window comes from the window
manager — gaps and a border on an ordinary window, nothing at all on a full-bleed
one.

If you want it frameless, ask the window manager rather than the plugin. Borders
are usually droppable per window; gaps usually are not, and tend to be a
per-workspace setting instead. Since the panel requests no geometry, a rule of
that kind is free to fill the window or widen it without fighting anything here.

## Keys

| Key | Action |
| --- | --- |
| `↑` `↓`, `j` `k` | Move the caret |
| `←` `→`, `h` `l` | Change pane |
| `g` / `G` | First / last row *(with Vim keys on)* |
| `Enter` | Activate — play the artist, album or track under the caret |
| `Space` | Play / pause |
| `Shift` + `←` `→` | Seek ∓5s |
| any letter or digit | Typeahead |
| `?` | Settings card |

In the settings card: arrows or `hjkl` move, `Enter` toggles a switch or opens a
slider, `←` `→` (or `h` `l`) adjust the open slider, `g` / `G` jump to an end,
`R` resets everything, `Esc` steps back out and `Q` closes.

The mouse works too: click a row to select it and move the caret into the next
pane (playback still needs `Enter`), click a setting to change it, drag the seek
bar or the volume slider, click the volume icon to mute.

## Notes and limitations

- **Cover art has to be a file next to the tracks.** Embedded/tagged artwork is
  not read and MPD's `albumart` plugin is not used, so a library tagged by Picard
  or beets gets the placeholder. The music directory is assumed to be `~/Music`
  (honouring `XDG_MUSIC_DIR` when it is exported), which should match MPD's
  `music_directory`.
- **Typeahead accepts ASCII letters and digits plus `æøåÆØÅ`.** Widen the regex
  at the bottom of the key handler in `GrimPlayer.qml` for other scripts.
- **Album repeat is client-side**, so there is a fraction of a second of silence
  at the album boundary.
- **No stored playlists and no queue view**, by design: the queue is always the
  tail of the library from wherever you are.
- **Without a sizing rule of some kind the panel comes up 100x100.** Its own
  content is purely proportional, so it cannot state a size for itself; that is a
  property of a proportional layout rather than something this plugin can work
  around. See [Windowing](#windowing).

## Development

The plugin is two entry points: `GrimPlayerMpd.qml` (the service — socket,
protocol, library tree, queue policy) and `GrimPlayer.qml` (the panel). The
socket has to outlive the panel, hence `kinds: ["service", "panel"]` with
`keepLoaded`.

Edit the files under `~/.config/omarchy/plugins/skollgrim.grimplayer/` and the
shell reloads the panel on save. The service is `keepLoaded`, so changes to
`GrimPlayerMpd.qml` only take effect after a shell restart (`omarchy restart
shell`).

Check a manifest before pushing it out:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/skollgrim.grimplayer
```

There is no test harness — this is a UI plugin, so it is verified against a live
MPD: kill MPD underneath it, restart it, add an album and confirm the tree
follows.

## Licence

MIT. See [LICENSE](LICENSE).
