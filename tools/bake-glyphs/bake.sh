#!/usr/bin/env bash
# bake.sh — generate themed glyphs and embed them into MikuGlyphAsset.swift.
#
#   ./tools/bake-glyphs/bake.sh            # all glyphs
#   ./tools/bake-glyphs/bake.sh leek note  # just these
#
# Needs: an image2 API key in the environment, python3 with Pillow, and pngquant.
# See README.md for why the pipeline looks like this.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE2="/Users/admin/work/script-kit/skills/image2-generate/image2.py"
WORK="${WORK:-/tmp/mactr-glyphs}"
OUT_SWIFT="$REPO_ROOT/Sources/MacTR/Rendering/MikuGlyphAsset.swift"
SIZE="${SIZE:-1024x1024}"
FINAL_PX="${FINAL_PX:-96}"

mkdir -p "$WORK"

# The model has no transparent-background option on this deployment, so every prompt
# pins a pure black background and flat single-colour line art. The bake step turns
# luminance into alpha, which is exact for light-on-black art and leaves no matte
# fringe. Colour is applied at draw time from the palette, so the art only needs to
# carry SHAPE — hence "single flat colour", not "teal".
common="STRICT: pure solid black background (#000000). Subject drawn ONLY as clean \
glowing thin line art in a single flat near-white colour. No other colours, no \
gradients, no shading, no background texture, no text labels, no watermark, no \
border. Uniform 3px stroke weight like a vector UI icon. Centred with generous empty \
margin on all four sides. Flat, geometric, crisp edges, symmetrical."

prompt_for() {
    case "$1" in
    leek)       echo "A minimalist icon of a Japanese leek (negi / spring onion) standing diagonally: one long straight stalk with three narrow leaves splaying from the top. $common" ;;
    headphones) echo "A minimalist icon of over-ear headphones seen from the front: a semicircular headband arc joining two rounded rectangular earcups. $common" ;;
    note)       echo "A minimalist icon of a single musical eighth note: an oval note head, a straight vertical stem on its right, and one curved flag off the stem top. $common" ;;
    badge01)    echo "A minimalist icon of the two digits 0 and 1 side by side inside a rounded-rectangle outline badge, like a stencilled unit number. $common" ;;
    badge39)    echo "A minimalist icon of the two digits 3 and 9 side by side inside a rounded-rectangle outline badge, like a stencilled unit number. $common" ;;
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

    echo "==> generating $g"
    python3 "$IMAGE2" --prompt "$(prompt_for "$g")" --out "$raw" \
        --size "$SIZE" --quality medium --format png --retries 5 --retry-delay 45

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
    body = "\n".join(f'        "{c}"' for c in chunks)
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
