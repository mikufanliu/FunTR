# FunTR — an AI agent cockpit on a Thermalright LCD

[中文](README.md) · [English](README.en.md)

Turns the 1920×480 LCD on a Thermalright CPU cooler into a live dashboard: your Mac's
system state, and — the point of this fork — **what your AI coding assistants are doing
right now**. Native macOS, no Windows required.

![On real hardware](img/photo.jpg)

<sub>Running on a Thermalright Trofeo Vision 9.16 cooler.</sub>

![Dashboard](img/dashboard.gif)

<sub>Live demo (fake data). **Note: both images predate the current build** — they show
the old CPU｜AGENTS｜MEMORY layout with Bongo Cat and Pikachu, both since removed. See
the layout below.</sub>

> A fork of [beret21/MacTR](https://github.com/beret21/MacTR). Upstream is a clean LCD
> driver and system monitor; this fork moves the centre of gravity to a live cockpit for
> [Claude Code](https://claude.com/claude-code) and [Codex](https://openai.com/codex)
> sessions, and adds a theme system, an operator sprite and a lock-screen screensaver.

## Layout

Three panels across 1920×480:

```
┌──────────────┬──────────────────────────────────────┬──────────────┐
│   OPERATOR   │            AI AGENTS                 │    STATUS    │
│              │       (triple width, the point)      │              │
│ Skadi chibi, │  left: session list                  │ clock / date │
│ reacting to  │  right: focused session detail       │ lunar / net  │
│ agent state  │  ────────────────────────────────    │ cpu/mem/temp │
│              │  footer: today's tokens · quota       │              │
└──────────────┴──────────────────────────────────────┴──────────────┘
```

## Highlights

### 🤖 The agents cockpit

Reads **local** Claude Code and Codex session records. Read-only, no network:

- **Concurrent sessions side by side** — one card per recently-active session. Several
  windows in the same repo each get their own card (`project #2`) instead of collapsing
  into one.
- **Auto-focused detail** — whichever session most needs you expands on the right with
  its full last message. Markdown tables in that message are laid out as real tables,
  not raw `| … |`.
- **Which model is running** — shown next to the card title (`Opus 5`, `GPT-5.6`, …),
  and it follows a mid-session `/model` switch.
- **Plan progress** — a `4/6` badge and a segmented bar, from Codex's `update_plan` and
  Claude's `TodoWrite`. A finished plan disappears rather than lingering. The active step
  is marked with a note head.
- **"Busy" vs "waiting on you"** — a permission prompt and a running tool look identical
  in the transcript, so the session-state files Claude Code publishes are read as well.
  That distinguishes **needs permission / needs input / dialog open**, and keeps flashing
  until you deal with it. Records whose process is gone are skipped, so a crashed CLI
  cannot pin a card forever.
- **Cross-session activity feed** — state transitions scroll along the footer (started /
  finished a turn / waiting on you).
- **Today's tokens and Codex quota** — the quota is the newest reading across all recent
  sessions.

### 🎨 Themes

Three skins, switchable from the menu bar: **Classic**, **Hatsune Miku**, **Rhodes
Island**.

A theme is not just a palette — it also decides what gets **drawn**. The Miku kit leans
on the one metaphor that is literally true, that Vocaloid is a DAW:

| Element | Treatment |
|---|---|
| Backdrop | piano roll — bar lines accented every 4 beats, black-key lanes shaded |
| Rules | dividers drawn as a tapered waveform instead of straight lines |
| Arc gauges | headband and earcup arcs around the dial — her headset |
| Progress | a note head marks the active plan step |
| Glyphs | eighth note before each panel title, a leek in the corner, `01` after the name |

Glyphs are generated offline and base64-embedded (see
[`tools/bake-glyphs/`](tools/bake-glyphs/)). Any glyph without baked art falls back to a
procedural CGPath drawing, so the theme is complete without running the generator.

### 🐧 The operator

The left panel is a Skadi action doll driven by real state: combat animations while an
agent is working, a greeting when a session starts waiting on you, a flourish when one
finishes, and idle pacing when everything is quiet. While the system is playing audio she
moves to it, over a foot-level spectrum.

Animations are baked offline from Spine skeletons into sprite strips (see
[`tools/bake-operator/`](tools/bake-operator/)); swapping in a different character is a
matter of replacing the asset.

### 🌙 Lock-screen screensaver

When the Mac locks, the LCD switches to an ambient scene (ultrawide wallpaper plus
drifting stars) and returns on unlock. Settings can pin one wallpaper or auto-rotate.

### 📌 Dynamic Island pushes

Any script or agent can drop a transient message onto the LCD:

```bash
tools/mactr-pin '{"title":"Deploy done","body":"prod is live","icon":"✅","secs":12}'
```

### ⚙️ Under the hood

- **Adaptive frame rate** — ~15fps only while something actually animates (an agent
  working, the screensaver, a push); 2fps otherwise to save power on an always-on app.
- **USB hotplug** — reconnects after replug and after sleep/wake.
- **On-Mac preview** — renders to a window when no LCD is attached, for development.
- **Menu-bar app** — background, no Dock icon.
- Brightness is gamma-based so bright wallpapers do not blow out to white; 180° rotation
  is supported.

## Hardware

| | |
|---|---|
| **Product** | [Thermalright Trofeo Vision 9.16 LCD](https://www.thermalright.com/product/trofeo-vision-9-16-lcd-black/) |
| **Panel** | 9.16" IPS, 1920 × 480 |
| **Interface** | USB Type-C (USB 2.0) |
| **Device** | `0416:5408` (LY Bulk protocol) |

## Requirements

- Apple Silicon Mac (M1–M5)
- macOS 15 (Sequoia) or newer

That is all you need for the packaged app — libusb is bundled, so no Homebrew. `libusb`
and a Swift 6.1+ toolchain are only needed to build from source.

## Install

Grab the `.dmg` from [Releases](https://github.com/mikufanliu/FunTR/releases), open it and
drag **FunTR** into Applications.

> **Gatekeeper will block the first launch.** This app has no Apple Developer certificate
> ($99/year), only an ad-hoc signature, so macOS reports an unverified developer.
> **Right-click the icon → Open** in Applications, then click Open again in the dialog.
> Once only.
>
> Command-line equivalent:
>
> ```bash
> xattr -dr com.apple.quarantine "/Applications/FunTR.app"
> ```

Launch at login is a switch in Settings, from the menu-bar icon.

## Build from source

```bash
brew install libusb pkg-config

git clone https://github.com/mikufanliu/FunTR.git
cd FunTR
swift build -c release

.build/release/FunTR          # menu-bar app; drives the LCD, or previews in a window
```

> If the system Command Line Tools are broken and `swift build` fails while parsing the
> manifest, install the Homebrew toolchain (`brew install swift`) and use
> `/opt/homebrew/opt/swift/bin/swift build -c release`, or pass
> `SWIFT=/opt/homebrew/opt/swift/bin/swift` to the packaging scripts below.

### Package it yourself

```bash
./packaging/build-app.sh      # → dist/FunTR.app (bundles libusb, ad-hoc signed)
./packaging/make-dmg.sh       # → dist/FunTR-<version>-arm64.dmg
```

`build-app.sh` vendors every non-system dylib the binary references into
`Contents/Frameworks`, rewrites the install names, and verifies no build-machine paths
leaked into the result.

The version comes from the git tag: pushing a `v*` tag triggers the
[release workflow](.github/workflows/release.yml), which builds and uploads the DMG.

### Launch at login

The in-app switch (backed by `SMAppService`) is the simple path.

For relaunch-on-crash as well, use the LaunchAgent instead:

```bash
cp packaging/com.mikufanliu.FunTR.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.mikufanliu.FunTR.plist
```

Pick one or the other — both at once starts two instances that fight over the USB device.

## Run modes

```bash
.build/release/FunTR                 # menu-bar app (LCD, or preview window if none)
.build/release/FunTR --preview       # force the on-Mac preview window
.build/release/FunTR --theme miku    # start on a given theme (persists to settings)
.build/release/FunTR --demo          # drive the LCD with polished fake data (for photos)
.build/release/FunTR --snapshot x.png            # render current real data to a PNG
.build/release/FunTR --snapshot x.png --cores 10 # render one frame simulating N cores
.build/release/FunTR --gif x.gif --frames 48 --fps 12 --scale 2   # animated demo GIF
.build/release/FunTR --benchmark 120 # measure achievable LCD frame rate
.build/release/FunTR --test-flash 30 # force every card into the alert state, to preview it
.build/release/FunTR --rotate        # rotate the output 180°
.build/release/FunTR --cli           # print metrics once to the terminal, no LCD
```

In an installed app the same entry point is
`/Applications/FunTR.app/Contents/MacOS/FunTR`.

Only one process can hold the USB device — stop a running instance before `--demo` or
`--benchmark`.

> After changing code, **restart the process**: a running instance holds the old
> binary's inode, so `swift build` alone changes nothing on the LCD.

## How agent data is read

FunTR never touches a network or an API. It reads records these CLIs already write to
local disk:

| Agent | Source | Parsed |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | assistant messages, `usage` tokens, `TodoWrite`, `message.model` |
| Claude Code | `~/.claude/sessions/*.json` | live session status (busy / waiting / idle) and the reason |
| Codex | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | agent messages, `token_count`, `rate_limits`, `update_plan`, `turn_context` |

Token totals are scoped to the local calendar day. An agent that has not run today still
shows the context of its last session. Transcripts are read from the tail on demand, never
loaded whole.

## Privacy

Everything is local and read-only. No telemetry, no network calls, nothing leaves your
Mac.

The one exception is `tools/bake-glyphs/bake.sh`, which **you** run deliberately and which
calls an image-generation endpoint. It is an optional development tool; the app itself
never does this.

## Credits

- [beret21/MacTR](https://github.com/beret21/MacTR) — the original macOS driver this is built on
- [thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux) — LY Bulk protocol reverse engineering
- [fermion-star/apple_sensors](https://github.com/fermion-star/apple_sensors) — IOHIDEventSystemClient temperature reads
- The operator sprite is from *Arknights*, © Hypergryph / Studio Montagne
- Hatsune Miku and related marks are © Crypton Future Media

> Embedded art is decorative and belongs to its respective owners. Check the relevant
> terms before distributing a build, or replace the contents of
> `Sources/MacTR/Rendering/*Asset.swift`.

## Licence

This repository does not currently carry a licence file. Upstream
[beret21/MacTR](https://github.com/beret21/MacTR) has no LICENSE either, so no explicit
redistribution grant exists — worth knowing before you fork or distribute.

---

Built with Swift + libusb. Developed with [Claude Code](https://claude.com/claude-code).
