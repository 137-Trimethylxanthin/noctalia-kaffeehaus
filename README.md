# Kaffeehaus — Noctalia plugins for every Wayland compositor

A [Noctalia](https://noctalia.dev) **plugin source** — one room, a long menu.
Add it once and every plugin in here shows up in the Noctalia plugin store like
any other, updates included: a Win+P **display switcher**, a
**calendar** with month and day widgets, **picture-in-picture** for any
window or stream, a **Do Not Disturb** that actually keeps Discord quiet, and a
**cursor light** that flashes on your cursor when a message comes in, dims
everything else while you shake the mouse, or glows for as long as you like, and
a **lid keeper** that lets your AI agent go on coding with the laptop shut, and
shows in the bar what it is doing.

| [Vitrine](vitrine/README.md) | [Fiaker](fiaker/README.md) | [Häubchen](haeubchen/README.md) |
| --- | --- | --- |
| [![Vitrine: the four display layouts, extend active](vitrine/thumbnail.webp)](vitrine/README.md) | [![Fiaker: month grid and day timeline](fiaker/thumbnail.webp)](fiaker/README.md) | [![Häubchen: a stream in a picture-in-picture corner player](haeubchen/thumbnail.webp)](haeubchen/README.md) |
| [**Goschen**](goschen/README.md) | [**Kerzenlicht**](kerzenlicht/README.md) | [**Stammgast**](stammgast/README.md) |
| [![Goschen: Do Not Disturb mutes a chat ping while a call and music keep playing](goschen/thumbnail.webp)](goschen/README.md) | [![Kerzenlicht: a soft white glow around the mouse cursor](kerzenlicht/thumbnail.webp)](kerzenlicht/README.md) | [![Stammgast: with the lid closed, Claude Code keeps coding while the screen is locked and off](stammgast/thumbnail.webp)](stammgast/README.md) |

| Plugin | | What it does |
| --- | --- | --- |
| **[Vitrine](vitrine/README.md)** | `1.0.1` | A Win+P display switcher: extend, duplicate, external only and laptop only — from the launcher, a control-center tile, or one IPC call you can bind to your display key. Duplicate needs Hyprland. |
| **[Fiaker](fiaker/README.md)** | `0.2.0` | A calendar that keeps the month grid and the day timeline as separate, synchronized widgets, with a live now-line. Repeating events, exceptions and moved instances included. |
| **[Häubchen](haeubchen/README.md)** | `0.2.1` | Picture-in-picture for any window or stream: pick it with `/pip` or one key, or let it spot streams itself, and it follows you into a corner whenever you leave its workspace. Hyprland, sway, Scroll, niri and MangoWC. |
| **[Goschen](goschen/README.md)** | `0.1.1` | Do Not Disturb that really means it: while it is on, the pings Discord, Telegram and friends play themselves are muted too, and the call you are in and your music keep playing. PipeWire. |
| **[Kerzenlicht](kerzenlicht/README.md)** | `0.2.0` | Find your cursor: a message or a key lights it for a moment, shaking the mouse dims everything else, and a soft white glow can follow it for screen shares and talks. Click-through, every monitor. Any compositor with cursor sessions. |
| **[Stammgast](stammgast/README.md)** | `0.1.0` | Close the lid and keep coding: while Claude Code, Codex or another AI agent runs, closing the lid does not suspend the laptop; it locks and turns off the screen instead, and lets go when you quit the agent or the battery runs low. A bar icon (with Claude's mascot) and a desktop or lock-screen card show what each agent is doing, with usage limits. systemd-logind. |

## Install

Add the source once:

```sh
noctalia msg plugins source add kaffeehaus git https://github.com/137-Trimethylxanthin/noctalia-kaffeehaus
```

Then enable whichever plugins you want:

```sh
noctalia msg plugins enable 137-trimethylxanthin/vitrine
noctalia msg plugins enable 137-trimethylxanthin/fiaker
noctalia msg plugins enable 137-trimethylxanthin/haeubchen
noctalia msg plugins enable 137-trimethylxanthin/goschen
noctalia msg plugins enable 137-trimethylxanthin/kerzenlicht
noctalia msg plugins enable 137-trimethylxanthin/stammgast
```

`source add` clones the repo into Noctalia's plugin cache; `enable` exports a
plugin and starts it. Both are also available in **Settings → Plugins**, where
`https://github.com/137-Trimethylxanthin/noctalia-kaffeehaus` goes in under
*Sources → Add*.

To pick up new versions later:

```sh
noctalia msg plugins update kaffeehaus
```

One source carries every plugin, so a single `update` covers everything in
here.

## Where they work

Noctalia runs on many Wayland compositors, and so do these plugins, as far as
each compositor lets a plugin do its job:

| | Hyprland | niri | Sway | Scroll | MangoWC | Labwc | dwl | River / Triad | Umbriel |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: | :-: |
| **Vitrine** | ✅ | ☑️¹ | ☑️¹ | ☑️¹ | ☑️¹ | ☑️¹ | ☑️¹ | ☑️¹ | ☑️¹ |
| **Fiaker** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Häubchen** | ✅ | ☑️ | ☑️ | ☑️ | ☑️ | ❌² | ❌² | ❌² | ❌² |
| **Goschen** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Kerzenlicht** | ✅ | ☑️³ | ☑️⁴ | ☑️⁴ | ☑️⁴ | ☑️⁴ | ☑️⁴ | ☑️⁴ | ☑️⁴ |
| **Stammgast** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

✅ works (tested on Hyprland 0.56, or needs nothing from the compositor) ·
☑️ written against that compositor's IPC or protocol, not tested there yet ·
❌ not possible there

Vitrine and Häubchen 0.2 are new or reworked; on Hyprland their logic is
covered by the test suites, but the reworked versions have not yet been run in
a live Noctalia session.

1. Through the standard `wlr-output-management` protocol and `uv`. Everything
   but **Duplicate**: only Hyprland can mirror a screen.
2. These compositors give other programs no way to float, move or resize a
   window, which picture-in-picture needs. `/pip twitch …` still opens the
   player there, as a normal window, and Häubchen says so.
3. Needs a niri build newer than v26.04 (cursor sessions were merged on
   12 September 2026).
4. wlroots only reports the cursor while a monitor uses a hardware cursor; with
   a software cursor (`WLR_NO_HARDWARE_CURSORS=1`, nested sessions, some NVIDIA
   setups, a recording that paints the cursor in) the light goes out there.

Fiaker uses nothing but Noctalia's own widgets, Goschen talks to PipeWire and
Stammgast to systemd-logind, not to the compositor, which is why they work
everywhere.

## Before you rely on them

**Vitrine** needs `hyprctl` on Hyprland, and [`uv`](https://docs.astral.sh/uv/)
everywhere else (it fetches pywayland on first use), and plugin API 24.

**Fiaker** ships empty until it has a source of events. Noctalia's plugin API
does not expose the built-in calendar, so the working backend is a directory of
`.ics` files — the layout `vdirsyncer` produces. Set **vdir path** in
**Settings → Plugins → Fiaker** to that directory.

**Häubchen** needs `hyprctl` and `socat` on Hyprland, `swaymsg` on sway,
`scrollmsg` on Scroll, `niri` and `socat` on niri, or `mmsg` on MangoWC. Opening
a stream in its own player also needs one — mpv with `yt-dlp` by default.
Following a window you already have open does not.

**Goschen** needs PipeWire with WirePlumber, plus `pactl` and `pacat`
(`libpulse` / `pulseaudio-utils`). It mutes per app, not per sound, so an app
in a call keeps its pings along with the call.

**Kerzenlicht** needs `uv` (it fetches pywayland on first use), `pkill` and
`pgrep`, and a compositor with `ext-image-copy-capture-v1` cursor sessions;
`busctl` (systemd) for flashing on messages.

**Stammgast** needs systemd-logind handling the lid (the default almost
everywhere), `systemd-inhibit`, `busctl`, `ps`, `awk` and `pkill`. An agent
counts while it is open, busy or not, so quit it when you want the laptop to
sleep; a battery floor is the safety net. A closed laptop that keeps working
gets warm.

Each plugin's own README has the full documentation — every widget, setting and
caveat.

## Repository layout

```
vitrine/          a plugin; this is what Noctalia exports
fiaker/, …        the others
  plugin.toml     manifest: id, entries, metadata
  *.luau          entry scripts
  lib/            shared modules
  translations/   label_key / description_key strings
  README.md       the plugin's page in the store
  thumbnail.webp  its card image
  screenshots/    README images, where a plugin has more than the card
tests/            pure-logic tests, per plugin; not shipped to Noctalia
catalog.toml      source index; regenerated by CI on every push
```

Every plugin is one top-level directory holding a `plugin.toml`. Adding another
one is exactly that — a new directory; CI picks it up with no configuration.

`catalog.toml` is what makes the git route work: Noctalia reads it to render and
compat-check the source before cloning anything else. It is generated from every
`*/plugin.toml` by `.github/workflows/update-catalog.py` and committed, so
bumping `version` in a manifest is all a release takes. To regenerate it by hand:

```sh
uv run .github/workflows/update-catalog.py
```

## Developing

Point Noctalia at your checkout instead of at GitHub — a `path` source is read
from disk, and `.luau` edits hot-reload. It still lists only the plugins in
`catalog.toml`, so after adding a plugin directory, regenerate it (see above)
and run `noctalia msg plugins update dev`:

```sh
noctalia msg plugins source add dev path ~/Documents/code/noctalia-kaffeehaus
noctalia plugins lint vitrine
noctalia plugins lint fiaker
noctalia plugins lint haeubchen
noctalia plugins lint goschen
noctalia plugins lint kerzenlicht
noctalia plugins lint stammgast
./tests/vitrine/run.sh
./tests/fiaker/run.sh
./tests/haeubchen/run.sh
./tests/goschen/run.sh
./tests/kerzenlicht/run.sh
./tests/stammgast/run.sh
```

## License

MIT — see [LICENSE](LICENSE).
