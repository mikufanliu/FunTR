#!/bin/bash
# Bake one operator Spine animation into a horizontal sprite-sheet PNG.
#
# Renders arkdock's Spine assets (pixi-spine) headlessly via system Chrome
# (SwiftShader WebGL), then quantizes the strip with pngquant. The resulting
# PNGs are base64-embedded into Sources/MacTR/Rendering/*Asset.swift.
#
# Requires: an arkdock checkout (for lib/ + model/), Google Chrome, pngquant,
#           python3. See README.md.
#
# Usage:
#   ARKDOCK_WEB=~/work/arkdock/web \
#   ./bake.sh <model-rel-path> <skel-name> <anim> <frames> <w> <h> <out.png>
# Example:
#   ./bake.sh model/skadi2/default_build build_char_1012_skadi2 Relax 24 200 240 /tmp/skadi_Relax.png
set -e
MODEL="$1"; SKEL="$2"; ANIM="${3:-Relax}"; FRAMES="${4:-24}"; W="${5:-200}"; H="${6:-240}"
OUT="${7:-/tmp/${SKEL}_${ANIM}.png}"
ARKDOCK_WEB="${ARKDOCK_WEB:-$HOME/work/arkdock/web}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PORT="${PORT:-9879}"

[ -d "$ARKDOCK_WEB" ] || { echo "arkdock web dir not found: $ARKDOCK_WEB"; exit 1; }
cp "$HERE/bake.html" "$ARKDOCK_WEB/_bake.html"
python3 -m http.server "$PORT" --directory "$ARKDOCK_WEB" >/dev/null 2>&1 &
SRV=$!
trap "kill $SRV 2>/dev/null; rm -f '$ARKDOCK_WEB/_bake.html'" EXIT
sleep 0.6

URL="http://127.0.0.1:${PORT}/_bake.html?model=${MODEL}&skel=${SKEL}&anim=${ANIM}&frames=${FRAMES}&w=${W}&h=${H}"
DOM=$("$CHROME" --headless=new --enable-unsafe-swiftshader --hide-scrollbars \
      --virtual-time-budget=20000 --dump-dom "$URL" 2>/dev/null)

PAYLOAD=$(printf '%s' "$DOM" | grep -oE 'DATA:data:image/png;base64,[A-Za-z0-9+/=]+' | head -1 \
          | sed 's/^DATA:data:image\/png;base64,//')
if [ -z "$PAYLOAD" ]; then
  echo "BAKE_FAIL $SKEL/$ANIM"
  printf '%s' "$DOM" | grep -oE '(NOANIM|ERR)[^<]*' | head -1
  exit 1
fi

RAW="${OUT%.png}_raw.png"
printf '%s' "$PAYLOAD" | base64 -d > "$RAW"
if command -v pngquant >/dev/null; then
  pngquant --quality=65-90 --force --output "$OUT" "$RAW" && rm -f "$RAW"
else
  mv "$RAW" "$OUT"
  echo "(pngquant not found — sprite sheet left uncompressed)"
fi
echo "BAKE_OK $OUT $(stat -f%z "$OUT") bytes"
