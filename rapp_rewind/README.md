# RAPP Rewind

A local, searchable memory of everything that has been on your screen. Captures on an interval, reads the text with Apple's on-device Vision OCR, and indexes it in SQLite FTS5 so you can search what you saw. Nothing leaves the machine: there is no network call anywhere in the capture, OCR, index or search path.

A `runtime: "twin"` rapplication: it hatches into its own brainstem on port 7092 carrying only its own agent, and the host brainstem reaches it over twin-chat.

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
that CLI and its on-device engines remain available.

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
