# RAPP Rewind

A local, searchable memory of everything that has been on your screen.

**Native macOS app:** [`native/`](native/README.md) contains RAPP Rewind **1.2.0**
for macOS 14+, with a real SwiftUI/AppKit window and menu-bar controls, app-owned
ScreenCaptureKit capture, Vision OCR, system SQLite/FTS5, privacy exclusions,
image-only retention, and optional idle-at-login/background lifecycle. It never
starts recording at launch and needs no Python or ffmpeg for the native path.
The existing CLI and history format remain supported.

Captures the screen on an interval, reads the text with Apple's on-device Vision
OCR, and indexes it in SQLite FTS5 — so you can find that thing you saw on
Tuesday and cannot name. **The capture, OCR, index and search path makes no network call at all** — a test
asserts it. Driving the hatched twin over `/chat` is different: that conversation
goes through the host brainstem's LLM (GitHub Copilot by default), so anything the
agent quotes back has passed through it. The native app and direct CLI are the
strict-local paths.

Built because the product that did this got acquired and switched off. This one
cannot be switched off: both its native source and compatibility CLI operate
on your own SQLite database and image files.

```
screen ──► screencapture ──► downscale 1280px ──► fingerprint (dedup)
                                                       │
                                              unchanged? stop here
                                                       │ changed
                                              Vision OCR (on-device)
                                                       ▼
                                        SQLite FTS5  +  ~/.rapprewind/frames/
```

---

## Install the native app

**[RAPP Rewind 1.2.0 is available](https://github.com/kody-w/rapp-rewind/releases/tag/v1.2.0)**
for macOS 14+. Both architecture-specific apps are Developer ID signed,
notarized, stapled, and Gatekeeper accepted:

- **Apple silicon:** [arm64 ZIP](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.0/rapp_rewind-1.2.0-arm64.zip)
  · [release evidence](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.0/rapp_rewind-1.2.0-arm64.zip.evidence.json)
- **Intel:** [x86_64 ZIP](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.0/rapp_rewind-1.2.0-x86_64.zip)
  · [release evidence](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.0/rapp_rewind-1.2.0-x86_64.zip.evidence.json)

Double-click the downloaded ZIP in **Finder**, drag the extracted
**RAPPRewind.app** to **Applications**, and launch it there. No Terminal installer,
Python, Homebrew, signing credentials, or security bypass is required.
Review and save privacy exclusions, then press **Start** to request the app's own
Screen Recording grant. Terminal/Python permission is not inherited. Capture,
search, and retention remain local; launch and login never start recording.

The release is built from native source
[`34361996042c0548065dbd7e3ba5456b6cfffaee`](https://github.com/kody-w/rapp-rewind/tree/34361996042c0548065dbd7e3ba5456b6cfffaee),
with [matching-source CI](https://github.com/kody-w/rapp-rewind/actions/runs/34734085666).
Source builds remain available through the [native instructions](native/README.md);
an unsigned development build is not the published notarized application.

## Install the compatibility CLI

```bash
git clone https://github.com/kody-w/rapp-rewind.git
cd rapp-rewind
./install.sh
```

It compiles two tiny Swift shims (Vision OCR, and the frontmost-app/window
reader) with the Swift toolchain already on macOS. No Xcode project, no
dependencies, no package manager.

**Screen Recording permission** for this legacy terminal path is required —
macOS will prompt on the first capture. If it does not, add your terminal under
*System Settings → Privacy & Security → Screen Recording*. The native app
requests and owns a separate grant from its own app process.

---

## Use

```bash
rewind doctor                     # environment + permission check
rewind start                      # begin capturing (every 4s by default)
rewind stop

rewind search "quarterly ledger"  # what did I see?
rewind search invoice --app Mail --since 2d
rewind open 4821                  # open that moment's screenshot
rewind timeline --open            # scrubbable HTML timeline

rewind stats                      # frames, disk, dedup rate, GB/day
rewind prune --days 30 --yes      # drop old images, keep the text
rewind bench                      # reproduce the numbers below
```

Search is SQLite FTS5, so it takes `AND`, `OR`, `NOT`, `"exact phrase"` and
`prefix*`.

---

## Compatibility CLI measurements on an Apple M4

Reproduce explicitly with `rewind bench` — do not take these on faith. These
historical measurements are not native release benchmark evidence.

| Step | Cost |
|---|---|
| screen capture | 125 ms |
| downscale to 1280px | ~40 ms |
| Vision OCR | 1.4 s |
| stored frame | ~180 KB |

### Why 1280px, and not full resolution

Downscaling a Retina capture **recognises more text**, because it matches the
scale Vision expects:

| Width | Bytes | OCR lines |
|---|---|---|
| 3456 (native) | 1,656,968 | 228 |
| 1600 | 456,205 | 226 |
| **1280** | **259,374** | **243** |
| 1024 | 159,387 | 149 |

1280 is a measured floor — quality collapses below it. That single choice is
6.4× less disk *and* better text than capturing natively.

### Dedup is what makes all-day capture affordable

Most seconds look exactly like the second before. Every shot is fingerprinted on
a 32×32 grey thumbnail; if nothing moved, no image is stored and **no OCR runs** —
the previous frame's time range is simply extended.

`rewind stats` reports the real rate, measured against shots taken rather than
wall-clock, because dividing by elapsed time reports a dedup rate and a GB/day
that are simply wrong when capture is not running.

---

## The bug worth knowing about

The first change detector used a mean difference over a 16×16 thumbnail, treating
anything under 6 as unchanged. Measured on this machine:

| | mean | max |
|---|---|---|
| unchanged screen, 1s apart | 0.02 | 2 |
| a small preview window opens | **6.39** | 32 |

A window opening scored **6.39** against a threshold of 6 — it sat exactly on the
line. So Rewind flickered between noticing and silently discarding precisely the
kind of moment you would later search for. A memory that quietly forgets is worse
than no memory, because you trust it.

It now uses a 32×32 grid with **two** triggers — mean > 0.5 **or** max > 12 —
because a mean catches whole-screen changes while a max catches a small window in
one corner. Both sit an order of magnitude clear of the noise floor, and the test
suite asserts that margin rather than the mechanism.

---

## Storage, and getting it back

Roughly **180 KB per stored frame**. What that costs per day depends entirely on
how much your screen actually changes — `rewind stats` projects from your own
measured rate rather than a brochure number.

```bash
rewind prune --days 30        # dry run: shows what it would free
rewind prune --days 30 --yes  # drop the images, KEEP the text
```

Pruning is deliberately asymmetric: pixels are big and text is tiny, so old
screenshots go while the words stay searchable forever. A test asserts that
search still works on pruned frames.

---

## Native background capture and the legacy launchd limitation

The native app fixes process ownership in code: ScreenCaptureKit and the
permission request run inside `io.rapp.rewind`, not a Python/launchd child.
Background operation and **Open at Login (idle)** are separate, disabled-by-default
opt-ins. The menu bar keeps recording state and Pause/Stop visible. Login never
starts capture. See [native lifecycle and permission details](native/README.md).

`rewind start` works from a terminal that has Screen Recording permission. That
is the compatibility path, and it is what the numbers above were measured on.

**A launchd agent does not work, and you should know why before you try.** TCC
grants Screen Recording to the *responsible process*, and a background agent is
not your terminal — so every capture fails with `could not create image from
display`. Wrapping it in an unsigned `.app` bundle does not help either: macOS
has nothing to attribute the grant to, so it never prompts. Those were the
legacy wrapper experiments, not the new direct ScreenCaptureKit application
target; the original results are kept here to explain the CLI/service warning.

`./install.sh --service` still installs the agent and warns you about exactly
this. To make it work you must grant Screen Recording to the `python3` binary the
agent runs — a decision that is genuinely yours, not something a script should
do behind your back. Prefer the native app's app-owned capture and optional
login item instead; installing it does not silently modify an existing service.

What the daemon does *not* do any more is fail quietly. After five consecutive
failures it stops and says why:

```
giving up after 5 consecutive failures: screencapture wrote nothing: could not
create image from display. If this says 'could not create image from display',
the process that launched capture has no Screen Recording permission …
```

The first version logged that error every 4 seconds forever into a file nobody
reads, which is the same sin — a memory that quietly forgets — one layer down.

---

## Config

Environment variables, all optional:

| Var | Default | Meaning |
|---|---|---|
| `REWIND_HOME` | `~/.rapprewind` | index + frames |
| `REWIND_INTERVAL` | `4` | seconds between shots |
| `REWIND_WIDTH` | `1280` | downscale width — see the table above |
| `REWIND_QUALITY` | `60` | JPEG quality |
| `REWIND_FP_GRID` | `32` | fingerprint grid |
| `REWIND_SAME_MEAN` | `0.5` | below this mean diff, treated as unchanged |
| `REWIND_SAME_MAX` | `12` | …and below this max diff |

---

## What it does not do

- **No audio, no meetings.** That is [RAPP Crispy](https://github.com/kody-w/rapp-crispy).
- **No semantic search.** It is literal full-text; "the thing about pricing" will
  not find a slide that never said "pricing". Embeddings are the obvious next
  step and are not built.
- **No encryption at rest.** The index is a plain SQLite file and the frames are
  plain JPEGs. Anyone with your user account can read them. Use FileVault.
- **It can record sensitive visible content**, including passwords and other
  people's messages. The native app supports bundle-ID and window-title
  exclusions and explicit pause/stop; use whole-app exclusions for sensitive
  work. The compatibility CLI retains its original full-screen behavior.

---

## Tests

```bash
./tools/dryrun.sh
# Include native interoperability after building it:
./tools/dryrun.sh --native-binary native/.build/debug/RAPPRewind
```

The default dry run is now fixture-only: generated images and isolated databases
under ignored `native/.build`, removed afterward. It does not capture your screen,
read real history, or change permissions. Native `swift test -j 2` additionally
tests the local engines, capture state machine, retention, privacy, schema
compatibility, and late-result cancellation. Real-device TCC/signing checks remain
an explicit human release gate, not a fabricated automated pass.

MIT.
