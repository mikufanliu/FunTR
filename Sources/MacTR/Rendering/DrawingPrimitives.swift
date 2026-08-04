// DrawingPrimitives.swift — Core Graphics drawing utilities
//
// Ported from trcc_monitor.py drawing functions.
// All drawing uses CGContext directly for maximum control.

import AppKit
import CoreGraphics
import Foundation

enum Draw {

    // MARK: - Background

    /// Draw vertical gradient background.
    /// In flipped context: Y=0 is top, so bgTop at y=0, bgBot at y=height.
    static func gradientBackground(_ ctx: CGContext) {
        let colors = [Color.bgTop, Color.bgBot] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors, locations: [0, 1])
        else { return }

        ctx.saveGState()
        // Undo flip for gradient (drawLinearGradient uses native CG coords)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -CGFloat(Layout.height))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: CGFloat(Layout.height)),
            end: CGPoint(x: 0, y: 0),
            options: [])
        ctx.restoreGState()

        // Themed backdrop motifs (grid + scanlines) — very faint, for the sci-fi feel.
        let theme = Theme.current
        let w = CGFloat(Layout.width), h = CGFloat(Layout.height)
        if theme.gridBackground {
            ctx.setStrokeColor(Color.cyan.copy(alpha: 0.05) ?? Color.cyan)
            ctx.setLineWidth(1)
            var gx: CGFloat = 0
            while gx <= w { ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: h)); gx += 48 }
            var gy: CGFloat = 0
            while gy <= h { ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: w, y: gy)); gy += 48 }
            ctx.strokePath()
        }
        if theme.scanlines {
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.10))
            ctx.setLineWidth(1)
            var sy: CGFloat = 0
            while sy <= h { ctx.move(to: CGPoint(x: 0, y: sy)); ctx.addLine(to: CGPoint(x: w, y: sy)); sy += 3 }
            ctx.strokePath()
        }

        // Heavier themed motifs (piano roll + binary) come from a cached bitmap: they
        // are hundreds of lines and glyphs, and this runs up to 15x/second.
        if let motif = motifOverlay(for: theme) {
            ctx.draw(motif, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    // MARK: - Themed backdrop motifs (cached)

    /// Rendered-once overlay per theme. Drawing the piano-roll rules and the 01 text
    /// rows costs hundreds of path/glyph operations; at up to 15fps for an always-on
    /// app that is pure waste, so bake it into one bitmap and blit that instead.
    /// Keyed by `ThemeKind` — the palette is fixed per kind, so one entry each.
    nonisolated(unsafe) private static var motifCache: [ThemeKind: CGImage] = [:]

    private static func motifOverlay(for theme: Theme) -> CGImage? {
        let decor = theme.decor
        guard decor.backdrop != .plain || decor.binaryRain else { return nil }
        if let cached = motifCache[theme.kind] { return cached }

        let w = Layout.width, h = Layout.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Match the flipped convention every other draw call here uses.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        if decor.backdrop == .pianoRoll { pianoRoll(ctx, w: w, h: h) }
        if decor.binaryRain { binaryTexture(ctx, w: w, h: h) }

        let img = ctx.makeImage()
        if let img { motifCache[theme.kind] = img }
        return img
    }

    /// Piano-roll rules: beat lines with every 4th accented (4/4 bars) plus the
    /// horizontal note lanes. Vocaloid is a DAW, so the sequencer grid is the motif.
    private static func pianoRoll(_ ctx: CGContext, w: Int, h: Int) {
        let beat: CGFloat = 24          // one beat
        let lane: CGFloat = 30          // one note lane
        let fw = CGFloat(w), fh = CGFloat(h)

        // Note lanes (horizontal) — faintest layer.
        ctx.setStrokeColor(Color.cyan.copy(alpha: 0.030) ?? Color.cyan)
        ctx.setLineWidth(1)
        var y: CGFloat = 0
        while y <= fh {
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: fw, y: y))
            y += lane
        }
        ctx.strokePath()

        // Off-beat lines.
        ctx.setStrokeColor(Color.cyan.copy(alpha: 0.035) ?? Color.cyan)
        ctx.setLineWidth(1)
        var x: CGFloat = 0
        var i = 0
        while x <= fw {
            if i % 4 != 0 {
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: fh))
            }
            x += beat; i += 1
        }
        ctx.strokePath()

        // Bar lines (every 4th beat) — brighter, so the grid reads as 4/4 time.
        ctx.setStrokeColor(Color.cyan.copy(alpha: 0.065) ?? Color.cyan)
        ctx.setLineWidth(1)
        x = 0; i = 0
        while x <= fw {
            if i % 4 == 0 {
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: fh))
            }
            x += beat; i += 1
        }
        ctx.strokePath()
    }

    /// Faint `01` rows — her shoulder number, and the "digital diva" texture. Kept
    /// near-invisible: dense text under the dashboard's own text would hurt reading.
    private static func binaryTexture(_ ctx: CGContext, w: Int, h: Int) {
        let font = Fonts.mono(13)
        let color = Color.cyan.copy(alpha: 0.038) ?? Color.cyan
        // A fixed pattern, offset per row, so it reads as data rather than noise.
        let bits = "0100110101001011010101100011100101001101"
        let rowH = 30
        var row = 0
        var y = 4
        while y < h {
            // Rotate the pattern per row for variety without randomness (keeps the
            // bitmap deterministic, which matters for the cache and for snapshots).
            let shift = (row * 7) % bits.count
            let rotated = String(bits.dropFirst(shift) + bits.prefix(shift))
            text(ctx, rotated + rotated, x: (row % 3) * 40 - 40, y: y, font: font, color: color)
            y += rowH
            row += 1
        }
    }

    // MARK: - Themed glyphs

    /// Draw a themed glyph into `rect`, aspect-fit and centred. Prefers baked art from
    /// `MikuGlyphAsset`; falls back to a procedural path so a theme is complete before
    /// (or without) any generated assets.
    static func glyph(_ ctx: CGContext, _ glyph: MikuGlyph, in rect: CGRect, color: CGColor) {
        if let img = MikuGlyphAsset.image(for: glyph) {
            let aspect = CGFloat(img.width) / CGFloat(img.height)
            var w = rect.width, h = rect.height
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
            let fit = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
            ctx.saveGState()
            // Baked glyphs are drawn light-on-black and keyed to alpha, so tint by
            // clipping to the art and filling — keeps them on-palette per theme.
            ctx.clip(to: fit, mask: img)
            ctx.setFillColor(color)
            ctx.fill(fit)
            ctx.restoreGState()
            return
        }
        switch glyph {
        case .leek:       leekPath(ctx, in: rect, color: color)
        case .headphones: headphonesPath(ctx, in: rect, color: color)
        case .note:       notePath(ctx, in: rect, color: color)
        case .badge01:    badgePath(ctx, "01", in: rect, color: color)
        case .badge39:    badgePath(ctx, "39", in: rect, color: color)
        }
    }

    /// 大葱 — diagonal stalk with leaves splaying off the top.
    private static func leekPath(_ ctx: CGContext, in r: CGRect, color: CGColor) {
        let s = min(r.width, r.height)
        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.midY)
        ctx.rotate(by: 0.28)
        ctx.setStrokeColor(color)
        ctx.setLineCap(.round)
        // White stalk (lower, thicker).
        ctx.setLineWidth(max(1.6, s * 0.16))
        ctx.move(to: CGPoint(x: 0, y: s * 0.46))
        ctx.addLine(to: CGPoint(x: 0, y: -s * 0.04))
        ctx.strokePath()
        // Leaves (upper, thinner) — three splaying blades.
        ctx.setLineWidth(max(1.2, s * 0.10))
        for dx in [-s * 0.20, 0, s * 0.20] {
            ctx.move(to: CGPoint(x: 0, y: -s * 0.02))
            ctx.addLine(to: CGPoint(x: dx, y: -s * 0.46))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Headset — headband arc over two earcups.
    private static func headphonesPath(_ ctx: CGContext, in r: CGRect, color: CGColor) {
        let s = min(r.width, r.height)
        let cupW = s * 0.24, cupH = s * 0.40
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1.4, s * 0.11))
        ctx.setLineCap(.round)
        // Band: half circle over the top (flipped context → negative sin is up).
        ctx.addArc(center: CGPoint(x: r.midX, y: r.midY + s * 0.06), radius: s * 0.34,
                   startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        // Earcups.
        ctx.setFillColor(color)
        for dx in [-s * 0.34, s * 0.34] {
            let cup = CGRect(x: r.midX + dx - cupW / 2, y: r.midY + s * 0.02,
                             width: cupW, height: cupH)
            ctx.addPath(CGPath(roundedRect: cup, cornerWidth: cupW / 2.4,
                               cornerHeight: cupW / 2.4, transform: nil))
            ctx.fillPath()
        }
    }

    /// 8th note — reuses the bar's note head so the two motifs match.
    private static func notePath(_ ctx: CGContext, in r: CGRect, color: CGColor) {
        let s = min(r.width, r.height)
        // noteHead draws the stem upward from the head, so sit the head low in rect.
        noteHead(ctx, atX: r.midX - s * 0.10, midY: r.maxY - s * 0.22,
                 scale: s * 0.52, color: color)
        // Flag off the stem top.
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1.2, s * 0.08))
        ctx.setLineCap(.round)
        let stemX = r.midX - s * 0.10 + s * 0.52 * 0.42
        let stemTop = r.maxY - s * 0.22 - s * 0.52 * 1.15
        ctx.move(to: CGPoint(x: stemX, y: stemTop))
        ctx.addQuadCurve(to: CGPoint(x: stemX + s * 0.20, y: stemTop + s * 0.26),
                         control: CGPoint(x: stemX + s * 0.24, y: stemTop + s * 0.02))
        ctx.strokePath()
    }

    /// A small numeric badge — her shoulder `01`, or `39`.
    private static func badgePath(_ ctx: CGContext, _ label: String,
                                 in r: CGRect, color: CGColor) {
        let s = min(r.width, r.height)
        let box = CGRect(x: r.midX - s * 0.48, y: r.midY - s * 0.34,
                         width: s * 0.96, height: s * 0.68)
        ctx.setStrokeColor(color.copy(alpha: 0.75) ?? color)
        ctx.setLineWidth(max(1, s * 0.06))
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: s * 0.12,
                           cornerHeight: s * 0.12, transform: nil))
        ctx.strokePath()
        let font = Fonts.mono(max(7, s * 0.44))
        let tw = (label as NSString).size(withAttributes: [.font: font]).width
        text(ctx, label, x: Int(r.midX - tw / 2), y: Int(box.minY + s * 0.10),
             font: font, color: color)
    }


    /// A rule drawn as a small audio waveform instead of a straight line. Falls back
    /// to `line` for themes without the motif, so call sites stay single-path.
    static func rule(_ ctx: CGContext, from: CGPoint, to: CGPoint,
                     color: CGColor, width: CGFloat = 1) {
        guard Theme.current.decor.divider == .waveform else {
            line(ctx, from: from, to: to, color: color, width: width)
            return
        }
        let horizontal = abs(to.x - from.x) >= abs(to.y - from.y)
        let span = horizontal ? (to.x - from.x) : (to.y - from.y)
        guard abs(span) > 8 else {
            line(ctx, from: from, to: to, color: color, width: width)
            return
        }
        // Envelope: a decaying sine, so it reads as a waveform rather than a ripple.
        let amp: CGFloat = 3.0
        let cycles: CGFloat = abs(span) / 46
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineJoin(.round)
        let steps = max(24, Int(abs(span) / 3))
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            // Taper both ends to zero so the rule still lands exactly on from/to.
            let taper = sin(t * .pi)
            let off = sin(t * cycles * 2 * .pi) * amp * taper
            let p = horizontal
                ? CGPoint(x: from.x + span * t, y: from.y + off)
                : CGPoint(x: from.x + off, y: from.y + span * t)
            if s == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.strokePath()
    }

    // MARK: - Panel

    /// Draw a themed panel: rounded (classic/miku) or angular HUD (rhodes) frame
    /// with an accent header bar, optional under-header glow, and optional corner
    /// brackets. Assumes flipped context (Y=0 at top).
    static func panel(_ ctx: CGContext, x: Int, y: Int, w: Int, h: Int, accent: CGColor) {
        let theme = Theme.current
        let radius: CGFloat = theme.sharpCorners ? 3 : 16
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(Color.panelBG)
        ctx.addPath(path)
        ctx.fillPath()

        // The panels are ~96% opaque and cover nearly the whole screen, so a motif
        // painted only on the backdrop would survive as slivers in the margins. Blit
        // the cached overlay inside the panel too, clipped to its frame. It is the
        // same screen-aligned bitmap, so the sequencer grid stays continuous across
        // panels and reads as one surface the dashboard sits on.
        if let motif = motifOverlay(for: theme) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.draw(motif, in: CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
            ctx.restoreGState()
        }

        // Hairline border for the HUD themes (adds structure over the flat fill).
        if theme.cornerBrackets || theme.sharpCorners {
            ctx.setStrokeColor(Color.border)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        }

        // Accent bar at top (y is top in flipped coords)
        let barRect = CGRect(x: x + 2, y: y, width: w - 4, height: 3)
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor(accent)
        ctx.addPath(barPath)
        ctx.fillPath()

        // Subtle glow below accent
        if theme.accentGlow {
            for i in 0..<6 {
                let t = 1.0 - Double(i) / 6.0
                let alpha = 0.12 * t
                ctx.setStrokeColor(accent.copy(alpha: CGFloat(alpha)) ?? accent)
                ctx.setLineWidth(1)
                let lineY = CGFloat(y + 4 + i)
                ctx.move(to: CGPoint(x: CGFloat(x + 2), y: lineY))
                ctx.addLine(to: CGPoint(x: CGFloat(x + w - 2), y: lineY))
                ctx.strokePath()
            }
        }

        // Corner brackets — short L-shaped accent ticks at the four corners.
        if theme.cornerBrackets {
            let s: CGFloat = 16
            let inset: CGFloat = 6
            let l = CGFloat(x) + inset, r = CGFloat(x + w) - inset
            let tp = CGFloat(y) + inset, bt = CGFloat(y + h) - inset
            ctx.setStrokeColor(accent.copy(alpha: 0.9) ?? accent)
            ctx.setLineWidth(2); ctx.setLineCap(.round)
            // each corner: two strokes forming an L
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (l, tp, 1, 1), (r, tp, -1, 1), (l, bt, 1, -1), (r, bt, -1, -1),
            ]
            for (cx, cy, dx, dy) in corners {
                ctx.move(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx + s * dx, y: cy))
                ctx.move(to: CGPoint(x: cx, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy + s * dy))
            }
            ctx.strokePath()

            // Corner easter egg — one glyph, bottom-LEFT only. `panel` is shared by
            // every panel and knows nothing about their contents, so it has to pick
            // the corner least likely to be occupied: the agents panel right-aligns
            // its token footer and the status panel centres its uptime, both of which
            // collide bottom-right. Kept small and dim so it reads as a mark, not a
            // control.
            if let g = theme.decor.cornerGlyph {
                let gs: CGFloat = 15
                // Clear of the bracket's horizontal arm (length `s` from the corner),
                // or the two shapes overlap into an unreadable smudge.
                Draw.glyph(ctx, g, in: CGRect(x: l + s + 6, y: bt - gs - 1,
                                              width: gs, height: gs),
                           color: accent.copy(alpha: 0.45) ?? accent)
            }
        }
    }

    // MARK: - Arc Gauge

    /// Draw an arc gauge (like speedometer).
    /// Assumes flipped context (Y=0 at top, like PIL).
    /// PIL arc: start=135°, sweep=270° clockwise.
    /// In flipped CG: clockwise in screen space = clockwise:false in CG API.
    static func arcGauge(
        _ ctx: CGContext, cx: Int, cy: Int, radius: Int,
        percent: Double, color: CGColor, colorDark: CGColor, thickness: CGFloat = 12
    ) {
        let r = CGFloat(radius)
        let center = CGPoint(x: CGFloat(cx), y: CGFloat(cy))

        // In flipped context, Y is inverted so angles go clockwise visually
        // PIL: start=135, end=135+270=405. CG flipped: use positive angles, clockwise=false
        let startAngle = CGFloat(135) * .pi / 180
        let fullEndAngle = CGFloat(135 + 270) * .pi / 180

        // Background arc
        ctx.setStrokeColor(colorDark)
        ctx.setLineWidth(thickness)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: r, startAngle: startAngle,
                   endAngle: fullEndAngle, clockwise: false)
        ctx.strokePath()

        // Foreground arc (percentage)
        if percent > 0 {
            let pct = min(percent, 100)
            let sweepAngle = startAngle + (fullEndAngle - startAngle) * CGFloat(pct / 100)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(thickness)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: r, startAngle: startAngle,
                       endAngle: sweepAngle, clockwise: false)
            ctx.strokePath()

            // End dot — in flipped context, sin goes downward (+Y)
            let dotR = thickness / 2
            let ex = CGFloat(cx) + r * cos(sweepAngle)
            let ey = CGFloat(cy) + r * sin(sweepAngle)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: CGRect(x: ex - dotR, y: ey - dotR,
                                       width: dotR * 2, height: dotR * 2))
        }

        // Headphone shell around the dial — her headset, and it frames the gauge
        // without touching the readout in the middle.
        if Theme.current.decor.gauge == .headphone {
            headphoneShell(ctx, cx: cx, cy: cy, radius: radius,
                           thickness: thickness, color: color)
        }
    }

    /// Earcups + headband arcs outside an arc gauge. Drawn dim so the live value arc
    /// stays the brightest thing in the panel.
    private static func headphoneShell(
        _ ctx: CGContext, cx: Int, cy: Int, radius: Int,
        thickness: CGFloat, color: CGColor
    ) {
        let r = CGFloat(radius)
        let center = CGPoint(x: CGFloat(cx), y: CGFloat(cy))
        let shell = color.copy(alpha: 0.30) ?? color
        let band = color.copy(alpha: 0.22) ?? color

        // Headband: an arc over the top, outside the dial.
        let bandR = r + thickness / 2 + 9
        ctx.setStrokeColor(band)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        // In the flipped context, the top of the circle is the negative-sin side, so
        // sweep from 200° to 340° to arc over the top.
        ctx.addArc(center: center, radius: bandR,
                   startAngle: CGFloat(200) * .pi / 180,
                   endAngle: CGFloat(340) * .pi / 180, clockwise: false)
        ctx.strokePath()

        // Earcups: short thick arcs on each side, at the headband's ends.
        ctx.setStrokeColor(shell)
        ctx.setLineWidth(7)
        for (from, to) in [(CGFloat(168), CGFloat(212)), (CGFloat(328), CGFloat(372))] {
            ctx.addArc(center: center, radius: bandR,
                       startAngle: from * .pi / 180,
                       endAngle: to * .pi / 180, clockwise: false)
            ctx.strokePath()
        }
    }

    // MARK: - Bar

    /// Draw a rounded progress bar
    static func bar(
        _ ctx: CGContext, x: Int, y: Int, w: Int, h: Int,
        percent: Double, color: CGColor, bg: CGColor = Color.barBG
    ) {
        let radius = CGFloat(h) / 2

        // Background
        let bgRect = CGRect(x: x, y: y, width: w, height: h)
        ctx.setFillColor(bg)
        ctx.addPath(CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        // Fill
        if percent > 0 {
            let pct = min(percent, 100)
            let fw = max(h, Int(Double(w) * pct / 100))
            let fillRect = CGRect(x: x, y: y, width: fw, height: h)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()

            // Note head at the fill's leading edge — the bar reads as a note with a
            // stem. Only when the bar is tall enough for the head to be legible.
            if Theme.current.decor.segment == .noteHead, h >= 8 {
                noteHead(ctx, atX: CGFloat(x + fw), midY: CGFloat(y) + CGFloat(h) / 2,
                         scale: CGFloat(h), color: color)
            }
        }
    }

    /// A filled slanted note head with a short stem, centred on the bar's end.
    /// `noteMarker` is the public entry — callers that place their own progress
    /// geometry (the agent plan bar) use it to mark a position.
    static func noteMarker(_ ctx: CGContext, atX x: CGFloat, midY: CGFloat,
                           scale: CGFloat, color: CGColor) {
        noteHead(ctx, atX: x, midY: midY, scale: scale, color: color)
    }

    private static func noteHead(
        _ ctx: CGContext, atX x: CGFloat, midY: CGFloat, scale: CGFloat, color: CGColor
    ) {
        let hw = scale * 0.62      // head width
        let hh = scale * 0.46      // head height
        ctx.saveGState()
        // Stem rises from the head's right side.
        ctx.setStrokeColor(color)
        ctx.setLineWidth(max(1.4, scale * 0.13))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: x + hw * 0.42, y: midY - hh * 0.2))
        ctx.addLine(to: CGPoint(x: x + hw * 0.42, y: midY - scale * 1.15))
        ctx.strokePath()
        // Head, tilted like engraved notation.
        ctx.translateBy(x: x, y: midY)
        ctx.rotate(by: -0.35)
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: -hw / 2, y: -hh / 2, width: hw, height: hh))
        ctx.restoreGState()
    }

    // MARK: - Text

    /// Draw text at position. Assumes context is already flipped (Y=0 at top).
    static func text(
        _ ctx: CGContext, _ string: String, x: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let nsStr = string as NSString

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        nsStr.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draw centered text
    static func centeredText(
        _ ctx: CGContext, _ string: String, cx: Int, y: Int,
        font: NSFont, color: CGColor
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .white,
        ]
        let size = (string as NSString).size(withAttributes: attrs)
        let x = CGFloat(cx) - size.width / 2
        text(ctx, string, x: Int(x), y: y, font: font, color: color)
    }

    // MARK: - Line

    static func line(
        _ ctx: CGContext, from: CGPoint, to: CGPoint, color: CGColor, width: CGFloat = 1
    ) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }

    // MARK: - Sparkline (trend graph)

    /// Draw a mirrored bar chart with labels above and below.
    /// Layout:  [topLabel topValue]
    ///          [====chart area====]
    ///          [botLabel botValue]
    /// Total height = labelH + chartH + labelH
    static func mirrorBarChart(
        _ ctx: CGContext,
        topValues: [Double], bottomValues: [Double],
        x: Int, y: Int, w: Int, h: Int,
        topColor: CGColor, bottomColor: CGColor,
        topLabel: String, bottomLabel: String,
        topCurrent: String, bottomCurrent: String
    ) {
        let labelH = 16
        let chartY = y + labelH + 2
        let chartH = h - (labelH + 2) * 2
        guard chartH > 4 else { return }

        let midY = CGFloat(chartY + chartH / 2)
        let halfH = CGFloat(chartH / 2)
        let count = max(topValues.count, bottomValues.count)
        guard count > 0 else { return }

        let barW = max(1, CGFloat(w) / CGFloat(count))
        let topMax = topValues.max() ?? 1
        let botMax = bottomValues.max() ?? 1
        let maxVal = max(topMax, botMax, 1)

        // Top label line
        text(ctx, "\(topLabel) \(topCurrent)", x: x, y: y,
             font: Fonts.system(15), color: topColor)

        // Center axis
        ctx.setStrokeColor(Color.border)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: CGFloat(x), y: midY))
        ctx.addLine(to: CGPoint(x: CGFloat(x + w), y: midY))
        ctx.strokePath()

        // Top bars (grow upward)
        for (i, val) in topValues.enumerated() {
            let barH = CGFloat(val / maxVal) * (halfH - 1)
            if barH < 0.5 { continue }
            let bx = CGFloat(x) + CGFloat(i) * barW
            ctx.setFillColor(topColor.copy(alpha: 0.8) ?? topColor)
            ctx.fill(CGRect(x: bx, y: midY - barH, width: max(barW - 1, 1), height: barH))
        }

        // Bottom bars (grow downward)
        for (i, val) in bottomValues.enumerated() {
            let barH = CGFloat(val / maxVal) * (halfH - 1)
            if barH < 0.5 { continue }
            let bx = CGFloat(x) + CGFloat(i) * barW
            ctx.setFillColor(bottomColor.copy(alpha: 0.8) ?? bottomColor)
            ctx.fill(CGRect(x: bx, y: midY, width: max(barW - 1, 1), height: barH))
        }

        // Bottom label line
        text(ctx, "\(bottomLabel) \(bottomCurrent)", x: x, y: y + h - labelH,
             font: Fonts.system(15), color: bottomColor)
    }

    /// Format bytes per second to human-readable string
    static func formatBytesPerSec(_ bps: Double) -> String {
        if bps >= 1_000_000_000 { return String(format: "%.1f GB/s", bps / 1e9) }
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1e6) }
        if bps >= 1_000 { return String(format: "%.1f KB/s", bps / 1e3) }
        return String(format: "%.0f B/s", bps)
    }
}
