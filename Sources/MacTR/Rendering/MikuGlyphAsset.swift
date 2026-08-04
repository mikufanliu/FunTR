// MikuGlyphAsset.swift — baked themed glyphs (leek / headphones / note / 01 / 39).
//
// Same convention as RoomAsset / SkadiAsset: art is generated offline, quantized and
// base64-embedded so the bare binary stays self-contained. See tools/bake-glyphs/.
//
// The table starts EMPTY on purpose. `Draw.glyph` falls back to a procedural path
// drawing for any glyph with no baked art, so the theme is complete without it and
// dropping bakes in here is a straight upgrade — no call site changes.

import CoreGraphics
import Foundation
import ImageIO

enum MikuGlyphAsset {

    /// Baked art per glyph, or nil to use the procedural fallback.
    static func image(for glyph: MikuGlyph) -> CGImage? {
        switch glyph {
        case .leek:       return cached(&leekCache, leekB64)
        case .headphones: return cached(&headphonesCache, headphonesB64)
        case .note:       return cached(&noteCache, noteB64)
        case .badge01:    return cached(&badge01Cache, badge01B64)
        case .badge39:    return cached(&badge39Cache, badge39B64)
        }
    }

    // Decoding is lazy and memoized: most themes never touch these, and a theme that
    // does asks for the same handful of glyphs on every frame.
    nonisolated(unsafe) private static var leekCache: CGImage??
    nonisolated(unsafe) private static var headphonesCache: CGImage??
    nonisolated(unsafe) private static var noteCache: CGImage??
    nonisolated(unsafe) private static var badge01Cache: CGImage??
    nonisolated(unsafe) private static var badge39Cache: CGImage??

    private static func cached(_ slot: inout CGImage??, _ b64: String) -> CGImage? {
        if let resolved = slot { return resolved }
        let decoded = decode(b64)
        slot = .some(decoded)
        return decoded
    }

    private static func decode(_ b64: String) -> CGImage? {
        guard !b64.isEmpty,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return img
    }

    // MARK: - Baked art
    //
    // Populated by tools/bake-glyphs/bake.sh. Empty = procedural fallback.

    private static let leekB64 = ""
    private static let headphonesB64 = ""
    private static let noteB64 = ""
    private static let badge01B64 = ""
    private static let badge39B64 = ""
}
