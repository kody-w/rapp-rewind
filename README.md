# RAPP Rewind

A local, searchable memory of everything that has been on your screen.

Captures the screen on an interval, reads the text with Apple's on-device Vision
OCR, and indexes it in SQLite FTS5 — so you can find that thing you saw on
Tuesday and cannot name. **Nothing leaves the machine.** There is no network call
anywhere in the capture, OCR, index or search path, and a test asserts that.

Built because the product that did this got acquired and switched off. This one
cannot be switched off, because it is a shell script, a SQLite file, and two
small binaries you compile yourself.

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

## Install

```bash
git clone https://github.com/kody-w/rapp-rewind.git
cd rapp-rewind
./install.sh
```

It compiles two tiny Swift shims (Vision OCR, and the frontmost-app/window
reader) with the Swift toolchain already on macOS. No Xcode project, no
dependencies, no package manager.

**Screen Recording permission** is required — macOS will prompt on the first
capture. If it does not, add your terminal under *System Settings → Privacy &
Security → Screen Recording*.

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

## Measured on an Apple M4

Reproduce with `rewind bench` — do not take these on faith.

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

## Running it continuously — and the wall you will hit

`rewind start` works from a terminal that has Screen Recording permission. That
is the supported path today, and it is what the numbers above were measured on.

**A launchd agent does not work, and you should know why before you try.** TCC
grants Screen Recording to the *responsible process*, and a background agent is
not your terminal — so every capture fails with `could not create image from
display`. Wrapping it in an unsigned `.app` bundle does not help either: macOS
has nothing to attribute the grant to, so it never prompts. Both were tried and
measured, not assumed.

`./install.sh --service` still installs the agent and warns you about exactly
this. To make it work you must grant Screen Recording to the `python3` binary the
agent runs — a one-click decision that is genuinely yours, not something a script
should do behind your back. A signed, notarised app bundle would fix it properly
and is the right next step.

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
- **It records whatever is on screen**, including passwords in plain view and
  other people's messages. There is no per-app exclusion list yet; that is the
  first thing to add if you share a screen for a living.

---

## Tests

```bash
./tools/dryrun.sh
```

27 assertions against a throwaway index in `/tmp`, so your real memory is never
touched. It takes real screenshots — the only honest way to test a screen
recorder — and deletes them. Deterministic behaviour is asserted; OCR output is
measured and printed, because a suite that asserts on model output goes red for
the wrong reason.

MIT.
