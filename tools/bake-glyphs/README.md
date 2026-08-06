# Themed glyph baker

The miku theme draws a few small icons — leek, headphones, eighth note, `01` and `39`
badges. They are **generated offline** and base64-embedded into
`Sources/MacTR/Rendering/MikuGlyphAsset.swift`, same convention as `SkadiAsset` /
`RoomAsset`, keeping the bare binary self-contained.

**The theme works without running this.** `Draw.glyph` falls back to a procedural
CGPath drawing for any glyph whose base64 slot is empty, so baked art is a drop-in
upgrade rather than a prerequisite. Nothing at the call sites changes either way.

## Pipeline

1. **Generate** — `python3 script-kit/skills/image2-generate/image2.py` at 1024×1024.
   That deployment exposes no `background: transparent` option, so each prompt pins a
   **pure black background** with flat near-white line art.

2. **Key** — luminance becomes alpha. For light-on-black art the luminance *is* the
   coverage mask, so this is exact and leaves no matte fringe; no thresholding, which
   would alias the antialiased strokes into stairsteps. Levels are normalised first
   because generations vary in exposure and a dim one would bake in semi-transparent.
   Then crop to content, square off, and downscale 1024 → 96px (generate big, ship
   small — keeps edges clean at the 24–48px actually drawn).

3. **Quantize** — `pngquant`. Flat line art with mostly-transparent pixels crushes
   hard with no visible loss.

4. **Embed** — base64 into the `*B64` slots, wrapped at 100 chars so the file stays
   diffable instead of one multi-KB line.

Art carries **shape only** — it is flattened to white and tinted at draw time through
a clip mask, so every glyph follows the active palette instead of a hardcoded teal.

## Run

```bash
# needs: image2 API key in env, python3 + Pillow, pngquant
export IMAGE2_API_KEY=...            # or AZURE_OPENAI_API_KEY for that endpoint
./tools/bake-glyphs/bake.sh          # all five
./tools/bake-glyphs/bake.sh leek     # just one, to iterate on a prompt
```

Then `swift build && ./.build/debug/FunTR --theme miku --snapshot /tmp/miku.png`.

Knobs: `SIZE` (default `1024x1024`), `FINAL_PX` (default `96`), `WORK` (default
`/tmp/mactr-glyphs` — intermediates are kept there so you can inspect the raw
generation and the keyed result when a prompt needs tuning).

## Adding a glyph

1. Add a case to `MikuGlyph` in `DesignTokens.swift`
2. Add a `<name>B64 = ""` slot to `MikuGlyphAsset.swift` and a `case` in `image(for:)`
3. Add a procedural fallback branch in `Draw.glyph` (`DrawingPrimitives.swift`)
4. Add a prompt to `prompt_for()` here, then run `./bake.sh <name>`
