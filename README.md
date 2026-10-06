# GrimPlayer

An MPD browser for the [Omarchy](https://omarchy.org) shell: artist, album and
track panes with cover art and a now-playing strip, written as a Quickshell
plugin. It talks to MPD over its Unix socket and stays in sync by push, so
nothing polls.

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
- **Full-bleed mode** hides the bar so the panes use the whole screen.
- **Settings card** (`?`) for sizes, fonts, borders, spacing and behaviour,
  persisted to `~/.local/state/grimplayer/settings.json`.
- Follows the active Omarchy theme; every colour and size comes from the shell's
  own `Style`/`Color` tokens.

## Requirements

- Omarchy 4.x, with third-party plugin support (`omarchy plugin add`).
- [MPD](https://www.musicpd.org/) with a Unix socket. The default location is
  `~/.mpd/socket`; set `GRIM_LIBRARY_MPD_SOCKET` to point somewhere else.
- Hyprland rules, so the panel floats on its own workspace without gaps. Omarchy
  ships Hyprland, so this is just config.

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

Give yourself a key. In `~/.config/hypr/bindings.lua`:

```lua
o.rebind("ALT + M", "GrimPlayer", function()
	hl.exec_cmd("omarchy-shell -q shell toggle skollgrim.grimplayer")
end)
```

Pick a binding that is free on your machine — `ALT + M` is only a suggestion.

### Hyprland rules

Quickshell windows all share one app-id and `FloatingWindow` has no `appId`
property to set, so the window title is the only handle these rules can match
on. In `~/.config/hypr/hyprland.lua`:

```lua
-- The window asks for fullscreen itself, so only placement belongs here: no
-- animation (the panes repaint on every MPD event), floating, and its own
-- special workspace so the toplevel does not land on whatever is active.
o.window({ title = "GrimPlayer" }, { no_anim = true })
o.window({ title = "GrimPlayer" }, { float = true })
o.window({ title = "GrimPlayer" }, { workspace = "special:grimplayer" })
```

And in `~/.config/hypr/dropdowns.lua`, so the workspace has no gaps or border
around it:

```lua
hl.workspace_rule({ workspace = "s[true]", gaps_in = 0, gaps_out = 0, no_border = true })
```

Do not park the workspace in `silent`: the shell drives visibility by calling
`open()`/`close()`, so the window has to be the surface that activates the
workspace when it is shown.

### Full-bleed

`ALT + F` style fullscreen does nothing visible, because the panel is already a
fullscreen toplevel and the bar still sits over the first row. Route the key to
the panel's own IPC instead — in `~/.config/hypr/bindings.lua`:

```lua
o.rebind("ALT + F", "Full screen", function()
	local window = hl.get_active_window()
	if window and window.title == "GrimPlayer" then
		hl.exec_cmd("omarchy-shell -q grimplayer toggleFullbleed")
	else
		hl.dispatch(hl.dsp.window.fullscreen({ mode = "fullscreen" }))
	end
end)
```

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

The mouse works too: click a row to activate it, click a setting to change it,
drag the seek bar or the volume slider, click the volume icon to mute.

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
- The panel assumes a top bar when it offsets its first row; a bottom bar will
  overlap the now-playing strip.

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
