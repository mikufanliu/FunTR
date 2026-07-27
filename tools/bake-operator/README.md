# Operator sprite baker

The left panel shows an Arknights operator chibi (Skadi) as a looping animation.
Spine skeletal animation can't be drawn natively in the CoreGraphics frame loop,
so animations are **pre-baked offline** into horizontal sprite-sheet strips and
base64-embedded into `Sources/MacTR/Rendering/SkadiAsset.swift` — same convention
as `BongoCatAsset` / `PikachuAsset`, keeping the bare binary self-contained.

## Pipeline

1. **Render frames** — `bake.sh` serves an [arkdock](https://github.com/mikufanliu/arkdock)
   `web/` dir, loads a character's `.skel`/`.atlas`/`.png` with arkdock's own
   `pixi-spine`, plays one animation, and captures N frames into a strip PNG.
   Rendering is done by headless Google Chrome via SwiftShader WebGL (no GPU, no
   Chromium download).

2. **Quantize** — the strip is crushed with `pngquant` (these sprites have limited
   palettes + lots of transparency, so ~1.2 MB → ~300 KB with no visible loss).

3. **Embed** — base64 the quantized PNGs into a `*Asset.swift` that slices the strip
   into frames at load (`frameWidth`-wide crops). The renderer picks a frame by
   wall-clock time and animation fps.

## Regenerate / add an operator

```bash
# needs: an arkdock checkout, Google Chrome, pngquant, python3
ARKDOCK_WEB=~/work/arkdock/web ./bake.sh \
    model/skadi2/default_build build_char_1012_skadi2 Relax 24 200 240 /tmp/op_relax.png
ARKDOCK_WEB=~/work/arkdock/web ./bake.sh \
    model/skadi2/default_build build_char_1012_skadi2 Move  24 200 240 /tmp/op_move.png
```

Build-chibi animations are typically `Relax` (idle), `Move` (walk), `Interact`,
`Sleep`, `Default`. Then base64 the two PNGs into a `*Asset.swift` (see
`SkadiAsset.swift` for the exact structure) and point `renderOperator` at it.
