# RAPP Rewind for macOS

Native source version **1.2.1**, bundle ID **`io.rapp.rewind`**, macOS **14 or later**.
SwiftUI/AppKit provide the window and menu-bar controls; ScreenCaptureKit captures
the main display **inside the app process**. Vision OCR, grayscale fingerprints,
and system SQLite/FTS5 run locally. The installed native path needs no Python,
ffmpeg, Homebrew, helper server, Accessibility grant, microphone, or cloud account.

## Published 1.2.1 application

The [live v1.2.1 release](https://github.com/kody-w/rapp-rewind/releases/tag/v1.2.1)
provides Developer ID signed, notarized, stapled applications for both
architectures:

- [Apple silicon / arm64 ZIP](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.1/rapp_rewind-1.2.1-arm64.zip)
  · [evidence](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.1/rapp_rewind-1.2.1-arm64.zip.evidence.9d9436546d1620ec6c346b250523270e2e4340fcec762122f23711e428be2e28.json)
  · [provenance](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.1/rapp_rewind-1.2.1-arm64.release-result.json)
- [Intel / x86_64 ZIP](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.1/rapp_rewind-1.2.1-x86_64.zip)
  · [evidence](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.1/rapp_rewind-1.2.1-x86_64.zip.evidence.5fac5cc67ed4ab024eb61915703fa149faae8644cd6e24508dfff8f20d7209c4.json)
  · [provenance](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.1/rapp_rewind-1.2.1-x86_64.release-result.json)

In Finder, double-click the ZIP, drag **RAPPRewind.app** to **Applications**, and
launch it there. The native app requires no Python installation or security
bypass. Configure and save privacy exclusions before pressing Start; recording
and optional login/background operation remain explicit opt-ins.

Native source and tag remain pinned to
`461e54a49d2ed5422511f271a473bfa7e4112d77`. The
[successful matching-source CI run](https://github.com/kody-w/rapp-rewind/actions/runs/34767506975)
is the public build reference. Per-architecture release evidence is linked from
the release and the package's `desktop` metadata, whose exact byte counts and
SHA-256 values describe the live ZIPs and reports.
Later manifest/integration metadata commits do not replace that native-build
commit or move the released tag.

## Start, pause, stop

Launch the installed **RAPP Rewind.app** and press **Start**. This is the only
recording consent action. The app requests its own Screen Recording permission;
a grant to Terminal or Python does not apply. If macOS requests a restart after
changing the grant, quit and reopen Rewind, then press Start again.

The capture banner and menu-bar indicator show whether recording is active.
**Pause** discards pending capture/OCR work and schedules nothing further.
**Resume** is explicit. **Stop** ends the session. Neither launch nor login
starts recording. Sleep, session deactivation, and screen lock pause capture;
there is no automatic resume.

Closing the last window quits and stops recording by default. To keep capturing
with the window closed, explicitly enable and save **Keep running when the last
window closes**. The menu-bar Pause/Stop controls remain available. **Open at
Login (idle)** is a separate opt-in using `SMAppService.mainApp`; macOS can
require approval in Login Items. Quitting always stops capture.

## Search and privacy

- Search accepts the existing FTS5 grammar: `AND`, `OR`, `NOT`, `"exact phrase"`,
  and `prefix*`. Results are newest first, with bracketed snippets, app filtering,
  and relative/ISO date filtering. Blank query displays the native timeline.
- Select a moment to inspect its locally stored image and OCR text. **Open Image**
  opens only an image inside the history's `frames` directory. Pruned moments keep
  their searchable text.
- Add exact bundle identifiers and case-insensitive window-title fragments in
  **Privacy & Settings**, one per line. Saving a capture policy pauses recording.
  A visible excluded window, even behind another app, skips the **entire sample**
  before OCR. ScreenCaptureKit also filters the known excluded applications and
  title-matching windows. Rewind's own windows are always filtered.
- Title rules cannot predict titles a window has not yet exposed. Prefer excluding
  the entire application for sensitive work; pause before handling secrets.
  These controls apply to the native engine, not unrelated screen recorders or an
  explicitly selected legacy CLI backend.
- Diagnostics show permission/capture state, storage counters, paths, and bounded
  session events without logging OCR text, titles, or images. Diagnostics do not
  request permission or capture a screen.

Rewind does **not** encrypt its database or images. Protect your account and use
FileVault. It has no network capture/OCR/index/search client. A separate RAPP
agent's host LLM may receive text returned by that agent; that is not the native
local-only path.

## Existing history, defaults, and retention

The app uses **`~/.rapprewind`**, or your explicit **`REWIND_HOME`**, with the
unchanged `index.sqlite3`, `frames`, `frames_fts`, and `meta` layout. Existing IDs,
images, OCR text, counters, and timestamps are retained. The default interval,
longest image edge, JPEG quality, fingerprint size, and thresholds remain
4 seconds / 1280 px / 60 / 32×32 / mean `< 0.5` **and** max `< 12`.
Native grayscale resampling uses CoreGraphics instead of ffmpeg.

`REWIND_INTERVAL`, `REWIND_WIDTH`, `REWIND_QUALITY`, `REWIND_FP_GRID`,
`REWIND_SAME_MEAN`, `REWIND_SAME_MAX`, and `REWIND_MAX_ERRORS` seed the native
defaults if no saved native settings exist. Invalid values produce an error,
not silent replacements. New settings are written only after **Save** to
`native-settings.json` in the history directory; legacy configuration is not
rewritten. The app does not read or migrate launchd preferences.

Unchanged samples extend the previous moment without OCR, as in the CLI.
Unlike a continuous segment, a pause, exclusion, error, restart, or changed
policy resets the native deduplication candidate: unobserved intervals must not
look like time spent viewing the previous screen. Counters and storage
projections continue to use **shots taken**, not elapsed wall-clock time.

**Image Retention → Preview** is non-destructive. Removing previewed images
requires the app's confirmation button. The cutoff is the original capture
timestamp (`ts < cutoff`), matching `rewind prune`; pixels and byte counts are
removed, but all text, FTS rows, moment rows, and counters remain. Missing images
can be reconciled; paths outside the frame directory are rejected.

Automatic image retention is **off** until explicitly enabled and saved. If
enabled, it runs at most hourly during an explicitly started capture session,
not on app launch. There is no automatic text deletion or destructive migration.

An early **contentless** `frames_fts` index is rejected with an explanation and
left intact. Back up the entire history before considering the compatibility
CLI's existing rebuild/re-OCR migration. That CLI migration occurs when the old
index is opened; it can recover text only from images still present. Native Rewind
does not silently drop/rebuild that table or re-index old user screenshots.

The native app and updated CLI share a nonblocking capture lock. The app also
recognizes an active legacy `capture.pid`; it never kills the legacy process.
Stop the existing capture session yourself before switching engines.

## Build the actual application

SwiftPM and XcodeGen fetch `RAPPDesktopSupport` from
`https://github.com/kody-w/rapp-tools.git`, pinned to immutable revision
`f0bc616c2aed34f2a88888806ed056ec7bafba61`. The SwiftPM and generated Xcode
workspace lockfiles are committed; no sibling checkout is required.
Apple frameworks and SDK SQLite are the only native processing dependencies.

```bash
cd native
swift test -j 2
swift build -c release -j 2

xcodegen generate --spec project.yml
xcodebuild -project RAPPRewind.xcodeproj -scheme RAPPRewind \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/xcode -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

The XcodeGen specification has a true macOS application target, an embedded core
framework, and a core test target. The bundle is at
`.build/xcode/Build/Products/Release/RAPPRewind.app`. `Info.plist` declares the
product/version/URL scheme and Screen Recording explanation. Entitlements are
empty: no sandbox migration, network, microphone, unsigned-code exception, or
TCC bypass. Hardened runtime is enabled for signed builds.

`swift build` produces a development executable, **not** a distributable `.app`.
An unbundled executable is deliberately unable to request native recording
permission. Use the actual app target for recording. Release signing,
notarization, stapling, and catalog publication belong to the release pipeline;
a successful unsigned build is not evidence of those steps.

## Compatibility and bounded native actions

The original `rewind` command, `src/ocr.swift`, and `src/context.swift` are retained.
Singleton/twin actions are still `doctor`, `search`, `stats`, `capture`,
`timeline`, `prune`, and `bench`; no RAPP protocol, identity, port, or retired egg
is changed.

The agents discover native bundles in `/Applications` or `~/Applications`, or
through explicit `REWIND_NATIVE_APP=/path/RAPPRewind.app`. Discovery checks
`io.rapp.rewind` and executable containment. Before calling its allowlisted
native bridge, the agent requires a successful macOS Gatekeeper assessment; it
does not weaken Gatekeeper for an unsigned development bundle. An explicit
`REWIND_CLI` selects the compatibility backend instead.

```bash
RAPPRewind.app/Contents/MacOS/RAPPRewind --rewind-command doctor
RAPPRewind.app/Contents/MacOS/RAPPRewind --rewind-command search 'ledger' --since 2d
RAPPRewind.app/Contents/MacOS/RAPPRewind --rewind-command prune --days 30
RAPPRewind.app/Contents/MacOS/RAPPRewind --self-test
```

Native `doctor` performs a permission preflight and an in-memory FTS5 check, not
a screenshot. `capture` only reveals the app's controls; it does not press Start.
`prune` is always a preview and rejects `--yes`. Native `bench` measures generated
fixture pixels, explicitly **not** live screen-capture performance. Native
`timeline` prints locally queried moments; the original CLI's HTML timeline is
unchanged. Search returns exit 1 for no matches and exit 2 for errors.

The registered `rapp-rewind://` routes can reveal capture controls, search,
timeline, diagnostics, stats, image-by-ID, or a retention preview. They cannot
start recording, approve permissions, delete images, or run arbitrary commands.
There is no listener or public server.

## Safe validation

```bash
cd native
swift test -j 2
swift build -j 2
cd ..
./tools/dryrun.sh --native-binary native/.build/debug/RAPPRewind
```

Tests generate their own images, clocks, capture responses, and SQLite databases
under ignored `native/.build/test-fixtures` / `cli-fixtures`, then remove them.
They never use real screen history, live screen capture, or global scratch
directories. Coverage includes thresholds, OCR failures, FTS/snippets/query
errors, CLI schemas/counters, contentless refusal, image-only pruning,
exclusions, ownership, late permission/capture results, and start/pause/stop.
`--self-test` never opens history or requests permission.

Semantic automation can target identifiers such as:

- `rewind.capture.start`, `.pause`, `.stop`, `.state`
- `rewind.menu.start`, `.pause`, `.stop`, `.show`, `.quit`
- `rewind.search.query`, `.submit`, `.app`, `.since`
- `rewind.timeline.results`, `rewind.moment.<id>`, `rewind.moment.open`
- `rewind.exclusions.bundles`, `.titles`, `rewind.settings.save`
- `rewind.retention.preview`, `.confirm`, `.execute`
- `rewind.permissions.status`, `.openSettings`, `rewind.diagnostics.refresh`

Live-device release verification still requires a person to grant/deny the
signed app's Screen Recording request, inspect a deliberately prepared test
screen, verify excluded windows, and approve/test optional login behavior.
Automated fixture results are not substituted for that TCC/signing evidence.

## Public native CI and release source

The same-repository workflow [`.github/workflows/native-ci.yml`](../.github/workflows/native-ci.yml)
runs **arm64 on `macos-latest`** and **Intel on `macos-15-intel`**. It checks the
actual process and built-app architecture rather than assuming a runner label is
correct. It runs on main/release branch pushes, version tags, pull requests, and
manual dispatch. Checkout does not persist credentials, permissions are
`contents: read`, and there are no signing secrets or publication steps.

The exact entrypoints, from the repository root, are:

```bash
./tools/native-ci.sh arm64    # arm64 runner / local arm64 Mac
./tools/native-ci.sh x86_64   # Intel runner / local x86_64 process
```

The script runs these commands from `native` (`ARCH` is the requested architecture,
and `LOG_DIR` is a unique directory under `.build/ci-logs/$ARCH/`):

```bash
swift test --disable-swift-testing --arch "$ARCH" --scratch-path ".build/ci-swift-$ARCH" \
  --cache-path .build/ci-package-cache -j 2
swift build --arch "$ARCH" --scratch-path ".build/ci-swift-$ARCH" \
  --cache-path .build/ci-package-cache -c release -j 2
xcodegen generate --spec project.yml
xcodebuild -project RAPPRewind.xcodeproj -scheme RAPPRewind \
  -configuration Release -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath ".build/ci-xcode-$ARCH" \
  -clonedSourcePackagesDirPath ".build/ci-xcode-$ARCH/SourcePackages" \
  -resultBundlePath "$LOG_DIR/xcode-tests.xcresult" \
  -jobs 2 -parallel-testing-enabled NO ONLY_ACTIVE_ARCH=YES \
  "ARCHS=$ARCH" CODE_SIGNING_ALLOWED=NO build test
../tools/dryrun.sh --native-binary "$PWD/.build/ci-swift-$ARCH/debug/RAPPRewind"
".build/ci-xcode-$ARCH/Build/Products/Release/RAPPRewind.app/Contents/MacOS/RAPPRewind" --self-test
```

The test runner never launches the GUI, calls live capture/permission commands,
registers login items, edits TCC, imports signing credentials, or signs/notarizes.
These suites use XCTest; `--disable-swift-testing` avoids launching an unused
second test engine (including its Swift 6.3 Rosetta architecture mismatch).
Compatibility capture calls are fixture-backed mocks; the native benchmark in
the compatibility suite uses generated pixels. Only logs and fixture-test results
are uploaded, not unsigned application releases or user data. The script sets an
unused, project-local `REWIND_HOME` and asserts no command opened it. Process scratch
files remain under `native/.build`.

### Process-scoped Git cache compatibility

This machine's Git policy is `safe.bareRepository=explicit`. SwiftPM/Xcode invoke
Git from their generated bare dependency caches without an explicit `--git-dir`,
which otherwise makes immutable dependency resolution fail. For this trusted,
pinned repository, the runner applies **exactly** the following to its own process
tree:

```bash
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.bareRepository
export GIT_CONFIG_VALUE_0=all
```

Equivalently, prefix a single resolution/build command with
`GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all`.
These environment values do not write any Git configuration file and do not
change global Git policy or author identity. Do not use `git config --global` for
this workaround. It is build-time compatibility only, never a consumer-runtime
setting. Both committed lockfiles are checked against the immutable support SHA.

A successful public Actions run is a **build/verification reference**, not Apple
signing or notarization evidence. The parent must push/dispatch this workflow on
the actual final native-build commit and use a successful same-repository run
whose `head_sha` matches that commit. The release tag must resolve to that native
commit; a later catalog/manifest-only integration commit is separate. Signing,
notarization, and final artifact publication remain parent-owned.
