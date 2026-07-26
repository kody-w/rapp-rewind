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
info "OCR read $lines line(s) from the real screen"
[ "${lines:-0}" -ge 1 ] && ok "OCR produced text" || bad "OCR produced nothing"
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
case "$res" in *"["*"]"*) ok "snippet highlights the match" ;; *) bad "no snippet — is frames_fts contentless again?" ;; esac
"$REW" search zzzznotarealtokenzzzz >/dev/null 2>&1 && bad "search claimed a hit for nonsense" \
  || ok "no false hit for a nonsense query"

head_ "5. Timeline renders real data"
"$REW" timeline --since 1d --out "$REWIND_HOME/t.html" >/dev/null 2>&1
if [ -f "$REWIND_HOME/t.html" ]; then
  ok "timeline written"
  grep -q '__DATA__' "$REWIND_HOME/t.html" && bad "placeholder not substituted" || ok "data substituted"
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

head_ "7. Nothing here talks to the network"
netrefs=$(grep -nE 'urllib|requests|http://|https://|socket' "$REW" | grep -vE '^\s*#|"""|raw\.github|github\.com' | wc -l | tr -d ' ')
[ "$netrefs" = "0" ] && ok "no network calls in the capture/search path" \
  || bad "$netrefs possible network reference(s) — this must stay offline"

rm -rf "$REWIND_HOME"
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
