#!/usr/bin/env bash
# bake.sh — generate themed glyphs and embed them into MikuGlyphAsset.swift.
#
#   ./tools/bake-glyphs/bake.sh            # all glyphs
#   ./tools/bake-glyphs/bake.sh leek note  # just these
#
# Needs: an OpenAI-compatible image endpoint, python3 with Pillow, and pngquant.
# See README.md for why the pipeline looks like this.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="${WORK:-/tmp/mactr-glyphs}"
OUT_SWIFT="$REPO_ROOT/Sources/MacTR/Rendering/MikuGlyphAsset.swift"
SIZE="${SIZE:-1024x1024}"
FINAL_PX="${FINAL_PX:-96}"

# Any OpenAI-compatible /v1/images/generations endpoint. Defaults to the same
# gateway this machine's Claude Code is pointed at, which proxies gpt-image-2 —
# no separate credential to manage.
API_BASE="${IMAGE_API_BASE:-${ANTHROPIC_BASE_URL:-}}"
API_KEY="${IMAGE_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
MODEL="${IMAGE_MODEL:-gpt-image-2}"

if [ -z "$API_BASE" ] || [ -z "$API_KEY" ]; then
    echo "error: set IMAGE_API_BASE + IMAGE_API_KEY (or ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN)" >&2
    exit 2
fi

mkdir -p "$WORK"

# The model has no transparent-background option, so every prompt pins a pure black
# background and a flat white subject. The bake step turns luminance into alpha, which
# is exact for light-on-black art and leaves no matte fringe. Colour is applied at draw
# time from the palette, so the art only needs to carry SHAPE.
#
# SOLID SILHOUETTES, not line art. These are drawn at 15-24px. A first pass asked for
# "thin 3px line art"; at 1024px that is 0.3px once downscaled to 96px and simply gone
# by 15px — the leek rendered as an illegible smudge, worse than the procedural
# fallback. Bold filled shapes are the only thing that survives the size.
common="STRICT: pure solid black background (#000000). The subject is a SOLID FILLED \
pure white (#FFFFFF) silhouette — completely filled in, like a stencil or a die-cut \
sticker. NO outlines, NO line art, NO interior detail lines, NO gradients, NO shading, \
NO texture, NO text labels, NO watermark, NO border, NO frame. Bold chunky simple \
shape that stays readable when shrunk to 16 pixels. High contrast: pure white subject, \
pure black everywhere else. Centred, filling most of the frame with a small even \
margin. Flat, geometric, symmetrical."

prompt_for() {
    case "$1" in
    leek)       echo "A bold solid-white silhouette icon of a Japanese leek (negi / spring onion) standing upright and slightly tilted: one thick straight stalk widening slightly at the bottom, with three broad leaves fanning out from the top. Thick chunky proportions. $common" ;;
    headphones) echo "A bold solid-white silhouette icon of over-ear headphones seen from the front: a thick semicircular headband arc joining two large filled rounded-rectangle earcups. Chunky proportions, earcups clearly large. $common" ;;
    note)       echo "A bold solid-white silhouette icon of a single musical eighth note: a large filled oval note head, a thick straight stem rising on its right, and one thick curved flag off the stem top. Classic chunky music-note shape. $common" ;;
    badge01)    echo "A bold solid-white silhouette of the two digits 0 and 1 side by side in a heavy geometric sans-serif, very thick strokes, no surrounding box or frame. $common" ;;
    badge39)    echo "A bold solid-white silhouette of the two digits 3 and 9 side by side in a heavy geometric sans-serif, very thick strokes, no surrounding box or frame. $common" ;;
    *) echo "unknown glyph: $1" >&2; exit 2 ;;
    esac
}

GLYPHS=("$@")
if [ ${#GLYPHS[@]} -eq 0 ]; then
    GLYPHS=(leek headphones note badge01 badge39)
fi

for g in "${GLYPHS[@]}"; do
    raw="$WORK/raw-$g.png"
    keyed="$WORK/keyed-$g.png"
    final="$WORK/$g.png"

    # SKIP_GENERATE=1 re-keys and re-embeds from whatever is already in $WORK —
    # useful when iterating on the keying or the Swift emitter without paying for
    # (or waiting on) another round of generations.
    if [ "${SKIP_GENERATE:-0}" = "1" ] && [ -f "$raw" ]; then
        echo "==> reusing $raw"
    else
    echo "==> generating $g"
    API_BASE="$API_BASE" API_KEY="$API_KEY" MODEL="$MODEL" SIZE="$SIZE" \
    PROMPT="$(prompt_for "$g")" OUT="$raw" python3 - <<'PY'
import base64, json, os, sys, urllib.request

base = os.environ["API_BASE"].rstrip("/")
req = urllib.request.Request(
    f"{base}/v1/images/generations",
    data=json.dumps({
        "model": os.environ["MODEL"],
        "prompt": os.environ["PROMPT"],
        "size": os.environ["SIZE"],
        "n": 1,
    }).encode(),
    headers={
        "Authorization": f"Bearer {os.environ['API_KEY']}",
        "Content-Type": "application/json",
    },
)
with urllib.request.urlopen(req, timeout=300) as r:
    payload = json.load(r)

if "error" in payload:
    sys.exit(f"    API error: {json.dumps(payload['error'], ensure_ascii=False)[:300]}")
item = payload["data"][0]
if "b64_json" in item:
    data = base64.b64decode(item["b64_json"])
elif "url" in item:
    with urllib.request.urlopen(item["url"], timeout=120) as r:
        data = r.read()
else:
    sys.exit(f"    unexpected response fields: {list(item)}")
open(os.environ["OUT"], "wb").write(data)
print(f"    {len(data) // 1024} KB raw")
PY
    fi

    echo "==> keying $g (luminance -> alpha, crop, downscale to ${FINAL_PX}px)"
    FINAL_PX="$FINAL_PX" python3 - "$raw" "$keyed" <<'PY'
import sys, os
from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
final_px = int(os.environ.get("FINAL_PX", "96"))

img = Image.open(src).convert("RGB")
# Light-on-black art: perceptual luminance IS the coverage mask, so use it directly
# as alpha. No thresholding — that would alias the antialiased strokes into stairsteps.
lum = img.convert("L")
# Normalize so the brightest stroke pixel becomes fully opaque; generations vary in
# exposure and a dim one would otherwise bake in as semi-transparent.
lo, hi = lum.getextrema()
if hi > lo:
    lum = lum.point(lambda v, lo=lo, hi=hi: int(255 * (v - lo) / (hi - lo)))
# Flatten to white RGB: the drawing code tints via a clip mask, so only alpha matters.
out = Image.new("RGBA", img.size, (255, 255, 255, 0))
out.putalpha(lum)

bbox = lum.point(lambda v: 255 if v > 12 else 0).getbbox()
if bbox:
    # Keep a little breathing room so strokes are not clipped flush to the edge.
    pad = max(2, min(img.size) // 100)
    x0, y0, x1, y1 = bbox
    bbox = (max(0, x0 - pad), max(0, y0 - pad),
            min(img.size[0], x1 + pad), min(img.size[1], y1 + pad))
    out = out.crop(bbox)

# Square it off so aspect-fit at draw time matches what the prompt composed.
side = max(out.size)
sq = Image.new("RGBA", (side, side), (255, 255, 255, 0))
sq.paste(out, ((side - out.size[0]) // 2, (side - out.size[1]) // 2))
# Generate big, ship small: downscaling a 1024px render keeps edges clean at the
# 24-48px the dashboard actually draws.
sq.resize((final_px, final_px), Image.LANCZOS).save(dst)
print(f"    {os.path.basename(dst)}: {final_px}x{final_px}")
PY

    if command -v pngquant >/dev/null 2>&1; then
        pngquant --force --quality 60-92 --output "$final" -- "$keyed"
    else
        echo "    pngquant not found — embedding uncrushed" >&2
        cp "$keyed" "$final"
    fi
done

echo "==> rewriting $(basename "$OUT_SWIFT") base64 tables"
WORK="$WORK" OUT_SWIFT="$OUT_SWIFT" python3 - "${GLYPHS[@]}" <<'PY'
import base64, os, re, sys

work, out_swift = os.environ["WORK"], os.environ["OUT_SWIFT"]
source = open(out_swift, encoding="utf-8").read()

for g in sys.argv[1:]:
    path = os.path.join(work, f"{g}.png")
    if not os.path.exists(path):
        print(f"    skip {g}: no baked png", file=sys.stderr)
        continue
    b64 = base64.b64encode(open(path, "rb").read()).decode("ascii")
    # Wrap so the file stays diffable rather than one multi-KB line.
    chunks = [b64[i:i + 100] for i in range(0, len(b64), 100)]
    body = "\n".join(f'        "{c}",' for c in chunks)
    replacement = f'    private static let {g}B64 = [\n{body}\n    ].joined()'
    pattern = rf'    private static let {g}B64 = (?:""|\[.*?\]\.joined\(\))'
    source, n = re.subn(pattern, replacement, source, count=1, flags=re.S)
    if n == 0:
        print(f"    WARN: no {g}B64 slot found — left unchanged", file=sys.stderr)
    else:
        print(f"    {g}: {len(b64) // 1024} KB base64")

open(out_swift, "w", encoding="utf-8").write(source)
PY

echo "==> done. Rebuild and check: swift build && ./.build/debug/MacTR --theme miku --snapshot /tmp/miku.png"
