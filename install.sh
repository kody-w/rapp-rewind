#!/bin/bash
# RAPP Rewind installer — idempotent. Safe to re-run.
#   ./install.sh            install
#   ./install.sh --service  ...and start at login via launchd
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
RW="${REWIND_HOME:-$HOME/.rapprewind}"
say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok(){  printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '    \033[33m!\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mfatal:\033[0m %s\n' "$*" >&2; exit 1; }

say "Toolchain"
command -v swiftc >/dev/null || die "swiftc not found — install the Xcode Command Line Tools: xcode-select --install"
ok "swiftc $(swiftc --version 2>/dev/null | head -1 | sed 's/.*Swift version //;s/ .*//')"
command -v sips >/dev/null && ok "sips" || die "sips missing (ships with macOS)"
command -v screencapture >/dev/null && ok "screencapture" || die "screencapture missing"
if command -v ffmpeg >/dev/null || [ -x /opt/homebrew/bin/ffmpeg ]; then ok "ffmpeg"
else
  command -v brew >/dev/null || die "ffmpeg missing and no Homebrew to install it"
  say "installing ffmpeg"; brew install ffmpeg || die "brew install ffmpeg failed"
fi
python3 -c "import sqlite3;sqlite3.connect(':memory:').execute('CREATE VIRTUAL TABLE t USING fts5(x)')" 2>/dev/null \
  && ok "sqlite FTS5" || die "this python3's sqlite lacks FTS5 — search would not work"

say "Building the Swift shims"
for s in ocr context; do
  if [ -x "$SRC/src/$s" ] && [ "$SRC/src/$s" -nt "$SRC/src/$s.swift" ]; then
    ok "$s (up to date)"
  else
    ( cd "$SRC/src" && swiftc -O -o "$s" "$s.swift" ) || die "failed to build $s"
    ok "$s built"
  fi
done

say "Directories"
mkdir -p "$RW"/{frames,logs,.scratch}
ok "$RW"

say "CLI"
mkdir -p "$HOME/.local/bin"
ln -sfn "$SRC/rewind" "$HOME/.local/bin/rewind"
ok "$HOME/.local/bin/rewind -> $SRC/rewind"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "add ~/.local/bin to your PATH" ;; esac

if [ "${1:-}" = "--service" ]; then
  say "launchd agent"
  warn "a launchd agent does NOT inherit your terminal's Screen Recording grant."
  warn "macOS will refuse its captures until you grant Screen Recording to the"
  warn "python3 binary the agent runs. Until then, use: rewind start"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$HOME/Library/LaunchAgents/com.rapp.rewind.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.rapp.rewind</string>
  <key>ProgramArguments</key><array>
    <string>$(command -v python3)</string>
    <string>$SRC/rewind</string>
    <string>start</string><string>--foreground</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$RW/logs/service.log</string>
  <key>StandardErrorPath</key><string>$RW/logs/service.log</string>
</dict></plist>
PL
  launchctl bootout "gui/$(id -u)/com.rapp.rewind" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.rapp.rewind.plist" 2>/dev/null || true
  ok "com.rapp.rewind installed — capture starts at login"
fi

say "Checking it works"
"$SRC/rewind" doctor 2>&1 | sed 's/^/    /'

cat <<'NOTE'

============================================================
 RAPP Rewind installed.
============================================================
 PERMISSION
  Screen Recording — macOS prompts on the first capture. If it
  does not, add your terminal under System Settings >
  Privacy & Security > Screen Recording.

 TRY IT
  rewind start
  ... use your machine for a few minutes ...
  rewind search "something you saw"
  rewind timeline --open

 Everything stays in ~/.rapprewind. Nothing is uploaded, and
 tools/dryrun.sh asserts there is no network call in the path.
============================================================
NOTE
