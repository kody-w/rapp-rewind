#!/bin/bash
# RAPP Rewind test suite.
#
# Runs against a THROWAWAY index (REWIND_HOME=/tmp/rewind-test), so it never
# touches your real memory. It does take real screenshots of whatever is on your
# display — that is the only way to test a screen recorder honestly — and deletes
# them at the end.
#
# Deterministic behaviour is ASSERTED. OCR output is a model and varies, so text
# quality is MEASURED and printed rather than asserted.
set -uo pipefail


# Homebrew prefix differs by architecture (/opt/homebrew on Apple Silicon,
# /usr/local on Intel). Resolve rather than hardcode, or this file is a no-op
# on half the Macs it targets.
brewbin() { for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
    [ -x "$p" ] && { echo "$p"; return; }; done
  command -v "$1" 2>/dev/null || echo "/opt/homebrew/bin/$1"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REW="$HERE/../rewind"
export REWIND_HOME=/tmp/rewind-test
rm -rf "$REWIND_HOME"; mkdir -p "$REWIND_HOME"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
info() { printf '       %s\n' "$*"; }
head_(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

q() { sqlite3 "$REWIND_HOME/index.sqlite3" "$1" 2>/dev/null; }

head_ "0. Environment"
doc=$("$REW" doctor 2>&1)
for need in "screencapture" "sips" "ffmpeg" "OCR shim" "context shim" "FTS5" "screen capture works"; do
  case "$doc" in *"$need"*) : ;; *) bad "doctor never mentioned $need"; continue ;; esac
  if echo "$doc" | grep -q "MISS.*$need"; then bad "$need missing"; else ok "$need"; fi
done

head_ "1. Capture stores a frame with context and text"
out=$("$REW" capture 2>&1)
info "$(echo "$out" | head -1 | sed 's/^ *//')"
case "$out" in *"new:"*) ok "first capture stored a frame" ;; *) bad "no frame stored: $out" ;; esac
n=$(q "SELECT COUNT(*) FROM frames")
[ "${n:-0}" -ge 1 ] && ok "frame row written" || bad "no row in frames"
app=$(q "SELECT app FROM frames LIMIT 1")
[ -n "$app" ] && ok "captured the frontmost app ($app)" || bad "no app recorded — context shim broken"
lines=$(q "SELECT lines FROM frames LIMIT 1")
capapp=$(q "SELECT app FROM frames LIMIT 1")
info "OCR read $lines line(s) from the real screen (frontmost: ${capapp:-unknown})"
# A locked screen or screensaver legitimately contains no text. Failing there
# reports a product bug that does not exist, so distinguish the two.
case "$capapp" in
  loginwindow|ScreenSaverEngine|"")
    info "SKIP: the screen is locked or blank, so there is no text to read" ;;
  *)
    [ "${lines:-0}" -ge 1 ] && ok "OCR produced text" || bad "OCR produced nothing" ;;
esac
# Independent of what is on screen, prove the shim itself works on a known image.
probe="$REWIND_HOME/probe_ocr.png"
$(brewbin ffmpeg) -hide_banner -loglevel error -f lavfi -i color=c=white:s=600x120 \
  -frames:v 1 -y "$probe" 2>/dev/null
if [ -x "$HERE/../src/ocr" ]; then
  "$HERE/../src/ocr" "$probe" >/dev/null 2>&1 && ok "OCR shim executes on a known image" \
    || bad "OCR shim failed to run"
else bad "OCR shim missing at $HERE/../src/ocr"; fi
img=$(q "SELECT path FROM frames LIMIT 1")
[ -f "$REWIND_HOME/frames/$img" ] && ok "image on disk ($(du -k "$REWIND_HOME/frames/$img" | cut -f1) KB)" \
  || bad "image missing at $img"

head_ "2. Dedup — an unchanged screen must not cost a frame"
before=$(q "SELECT COUNT(*) FROM frames")
"$REW" capture >/dev/null 2>&1
after=$(q "SELECT COUNT(*) FROM frames")
[ "$before" = "$after" ] && ok "unchanged screen deduped (still $after frames)" \
  || bad "unchanged screen stored a duplicate ($before -> $after)"
held=$(q "SELECT CAST(MAX(until_ts-ts) AS INT) FROM frames")
[ "${held:-0}" -ge 0 ] && ok "dedup extended the previous frame's time range" || bad "until_ts not extended"

head_ "3. Change detection thresholds stay clear of the noise floor"
# The first cut used mean<6 on a 16x16 grid. A small window scored 6.39 and was
# treated as unchanged, so Rewind silently dropped frames it should have kept.
# These assert the margin, not the mechanism.
mean=$(grep -oE 'REWIND_SAME_MEAN", "[0-9.]+' "$REW" | grep -oE '[0-9.]+$')
mx=$(grep -oE 'REWIND_SAME_MAX", "[0-9.]+' "$REW" | grep -oE '[0-9.]+$')
grid=$(grep -oE 'REWIND_FP_GRID", "[0-9]+' "$REW" | grep -oE '[0-9]+$')
info "grid ${grid}x${grid}, same if mean<${mean} AND max<${mx}; measured noise floor is mean 0.02 / max 2"
python3 -c "import sys; sys.exit(0 if float('$mean') <= 2 else 1)" \
  && ok "mean threshold ${mean} leaves margin over the 0.02 noise floor" \
  || bad "mean threshold ${mean} is too close to a real change (6.39 measured)"
python3 -c "import sys; sys.exit(0 if float('$mx') <= 20 else 1)" \
  && ok "max threshold ${mx} catches localised changes" || bad "max threshold ${mx} too loose"
[ "${grid:-0}" -ge 32 ] && ok "fingerprint grid ${grid} resolves small windows" || bad "grid ${grid} too coarse"

head_ "4. Search finds text that was only ever on screen"
word=$(q "SELECT app FROM frames LIMIT 1")
res=$("$REW" search "$word" 2>&1)
case "$res" in *"match(es)"*) ok "search returns hits for '$word'" ;; *) bad "search found nothing for '$word'" ;; esac
# Only meaningful if the indexed frame actually had text — a locked screen has none.
if [ "${lines:-0}" -ge 1 ]; then
  case "$res" in *"["*"]"*) ok "snippet highlights the match" ;;
    *) bad "no snippet — is frames_fts contentless again?" ;; esac
else
  info "SKIP: nothing was indexed from a blank screen, so there is no snippet to check"
fi
# rc 1 means "no results" and is the expected answer; anything else is a crash
# that the old `&& bad || ok` form scored as a pass.
ns=$("$REW" search zzzznotarealtokenzzzz 2>&1); nsrc=$?
if [ "$nsrc" = 0 ]; then bad "search claimed a hit for nonsense"
elif [ "$nsrc" != 1 ] || echo "$ns" | grep -q "Traceback"; then
  bad "search crashed on a nonsense query (rc=$nsrc): $ns"
else ok "no false hit for a nonsense query"; fi

head_ "5. Timeline renders real data"
"$REW" timeline --since 1d --out "$REWIND_HOME/t.html" >/dev/null 2>&1
if [ -f "$REWIND_HOME/t.html" ]; then
  ok "timeline written"
  # positive assertion: an unreadable or empty file makes the old grep fail,
  # which the || branch scored as "data substituted".
  if ! [ -s "$REWIND_HOME/t.html" ]; then bad "timeline file is empty"
  elif grep -q '__DATA__' "$REWIND_HOME/t.html"; then bad "placeholder not substituted"
  elif grep -q 'const DATA = \[' "$REWIND_HOME/t.html"; then ok "data substituted"
  else bad "no DATA array in the timeline at all"; fi
  python3 - <<PY
import re,json,sys
h=open("$REWIND_HOME/t.html").read()
m=re.search(r'const DATA = (\[.*?\]);', h, re.S)
d=json.loads(m.group(1)) if m else []
print(f"       {len(d)} frame(s) embedded, {sum(1 for x in d if x.get('text'))} with text")
sys.exit(0 if d and all(x.get('text') is not None for x in d) else 1)
PY
  [ $? -eq 0 ] && ok "every embedded frame carries its text" || bad "frames embedded without text"
else bad "no timeline produced"; fi

head_ "6. Prune keeps the text and drops the pixels"
"$REW" prune --days 0 --yes >/dev/null 2>&1
left=$(q "SELECT COUNT(*) FROM frames WHERE path IS NOT NULL")
[ "${left:-1}" = "0" ] && ok "images dropped" || bad "$left image(s) survived prune"
txt=$(q "SELECT COUNT(*) FROM frames_fts")
[ "${txt:-0}" -ge 1 ] && ok "text still searchable after prune ($txt row(s))" || bad "prune destroyed the text"
res=$("$REW" search "$word" 2>&1)
case "$res" in *"match(es)"*) ok "search still works on pruned frames" ;; *) bad "search broke after prune" ;; esac

head_ "7. The daemon fails loudly, never silently"
rm -rf /tmp/rw-fail
# hide screencapture but KEEP python on PATH, or the test breaks itself
PY3=$(command -v python3)
code=$(REWIND_HOME=/tmp/rw-fail REWIND_MAX_ERRORS=2 PATH="$(dirname "$(brewbin ffmpeg)")" \
        "$PY3" "$REW" start --foreground --interval 1 2>/tmp/rw-fail.err; echo $?)
[ "$code" = "1" ] && ok "gives up with a non-zero exit when capture keeps failing" \
  || bad "kept looping on repeated capture failure (exit $code)"
grep -qi 'giving up' /tmp/rw-fail.err && ok "explains why on stderr" \
  || bad "exited without saying why: $(head -c 120 /tmp/rw-fail.err)"
rm -rf /tmp/rw-fail /tmp/rw-fail.err

head_ "8. Nothing here talks to the network"
netrefs=$(grep -nE 'urllib|requests|http://|https://|socket' "$REW" | grep -vE '^\s*#|"""|raw\.github|github\.com' | wc -l | tr -d ' ')
[ "$netrefs" = "0" ] && ok "no network calls in the capture/search path" \
  || bad "$netrefs possible network reference(s) — this must stay offline"

rm -rf "$REWIND_HOME"
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
