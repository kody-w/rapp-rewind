# RAPP Rewind

A local, searchable memory of everything that has been on your screen. Captures on an interval, reads the text with Apple's on-device Vision OCR, and indexes it in SQLite FTS5 so you can search what you saw. Nothing leaves the machine: there is no network call anywhere in the capture, OCR, index or search path.

Version **1.2.0** includes the primary native macOS application and optional
`runtime: "twin"` integration. The existing twin uses port 7092 with its own agent;
the host reaches it over twin-chat. The protocol and port are unchanged.

## Install the released macOS app

Download the [live v1.2.0 release](https://github.com/kody-w/rapp-rewind/releases/tag/v1.2.0):
[Apple silicon / arm64](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.0/rapp_rewind-1.2.0-arm64.zip)
or [Intel / x86_64](https://github.com/kody-w/rapp-rewind/releases/download/v1.2.0/rapp_rewind-1.2.0-x86_64.zip).
Both apps are Developer ID signed, notarized, stapled, and Gatekeeper accepted.
Double-click the ZIP in Finder, drag **RAPPRewind.app** to **Applications**, then
launch it there. Review and save privacy exclusions before pressing **Start**.
Screen Recording belongs to this app; recording never starts at launch or login.

The manifest and index entry carry matching `rapp-desktop/1.0` descriptors with
the live archives' exact hashes, sizes, and evidence URLs. Their native-build
source is `34361996042c0548065dbd7e3ba5456b6cfffaee`; integration metadata may be
published in a later commit. The retired egg is preserved unchanged and is not
a native installer or a regenerated 1.2.0 cartridge.

## Actions

- `doctor`
- `search`
- `stats`
- `capture`
- `timeline`
- `prune`
- `bench`

## Native app or compatibility CLI

The agents can discover **RAPP Rewind.app** (`io.rapp.rewind`) in Applications
or through `REWIND_NATIVE_APP`. Native execution requires a successful macOS
Gatekeeper assessment. `REWIND_CLI` explicitly selects the original CLI backend;
that CLI and its on-device engines remain available. A Python-compatible RAPP
host is required only for this secondary integration. Dropping a `.py` file into
a host does not install the native application.

Native `capture` reveals visible Start/Pause/Stop controls and does **not** start
recording. Native `doctor` never takes a screenshot. `prune` remains a dry run
from either agent surface, regardless of model-supplied confirmation arguments.
Native `bench` uses generated pixels, not live capture. Other action names and the
RAPP twin/singleton protocol are unchanged; no server or port was added.

See the [native application documentation](../native/README.md) and
https://github.com/kody-w/rapp-rewind for installation and strict-local usage.

Capture, OCR, index, and search do not upload. The agent's separate host-LLM
conversation can include search text it returns; use the native app or CLI when
that conversation is not appropriate.

MIT.
