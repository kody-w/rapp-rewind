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

## Requires

The `rapp-rewind` CLI and its on-device engines. See https://github.com/kody-w/rapp-rewind

Nothing is uploaded.

MIT.
