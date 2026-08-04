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

    private static let leekB64 = [
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAAAM1BMVEX///////////9HcEz/////////////////////////////",
        "//////////////////////8E7TemAAAAEHRSTlMB/fwA+ASNvhHj0UCnc1cpFPP3uwAABGJJREFUaN7tWomSpCAMDYZ4YKv8/9du",
        "BDwI2OIxW7NVS1fN2C3wcidEAcUABAD+B7h85j/kb1LLY7mG5eb+A+l+RwAQLWr7of40puNhmk89Tm2gwf9xsz3iBYBtcfvprLLR",
        "6GryuwYiFphzAFgnr1fYaqvnUbnhLm0H8dyFpiIAP502FKOqZXgUrZqNCtoEWgwAXq+eLsLG6ioa2n6QNpppY7kQgABpNL1fSfhJ",
        "Aerl3mhGwpXdUwAM5MNorDUUNqlTgMEBELQdzxsDE1gGwNLpG8t6ncnE+ftwCDBja2ubKTBRIiJCqpXbUetpXsZiSAFGdHd6b1dW",
        "1+QQCwAIJ2O9sWjbhG0kQGWdfgiC+nU1M0ElAEyuXrcLhMJUyaHn7fassWfMcws8eQjke3N3emZPU/H+qptjBWtYLd7Hc1kvpwBE",
        "s9KkMpE6K1RgKGNdqk5YAPl1ktLu2tkphKc55RBM8Y/885TuKDiAWm7Fppp4mnPkzK+zWX8H2It1VWcqC+/Ik5ioTAtwpmQ2SZUS",
        "Kz3NqSZmgAVU9QkDWTNN4sIE0tM0uwFTkglPBaGCWhPxMLPAnibMdEKh+MWiSzxZCKlSPYs7IteyGwjv1qov8+TUvJ1N7h2B44KR",
        "OWKJ30X5gKQlMXEmUihD9kJAXVscTZPgNu8XWwyrRTLQu8hemNESF1LTEAMMk00z6AUAdjdhgWMMMMYUsIBCEVOYk2WKUXqo4q+R",
        "VS35rRxAFhKshb0Z2U7eXUoXKC280kCzJ1lpnWafi4WXdAYVB2aVK2HKatOlmCMySlcFQ3sNXwTIlhIHACFvX61NMVMw5vdvdvtf",
        "ApB6zu/P0fweQLZizDFQ7/cvrU3DiP05S7/WLdD+mFCsZMjWpCkDQ8QAXDvhnJrqzkQPzlCHHLizx6mp7k0Ur4toV9weMeDz8HLE",
        "vAGQZPssA8tZCy8DwFdvW6PoTg3XAUT1I6sjEguuAnxjYQsS+AjgWAsrAw8A8NiQEg3cAPCNlvEIYMSnAEFKRh34QGbyDYCDiJRG",
        "oTuOFoKqzrLQrt2K+6ECDloVUTfkkYh8W2fMAYzwkg6Yg4yMFEtoDUAPAZhSk/YqzNoPewiAXxtSCLIHd4uD44YUviOiXEPqxwF2",
        "boY/DIA/DfAsHxQBwH+Acx3gb+fgyJPxpwHgnwH41t7/nQACBzMJpylKyWUcIGQB4LGItr5CZ5Ocb14AWBe1CUDFORlf84P5MVfC",
        "QUcvAkxp2WK7dnsMiE/rokmlpa+eXgTInUFcEwoTId0F0PnjzS2AZFH2CKJjAHwGMGSL3xcB6hzA8KIOsueDOgDg42CXPSrfPoDs",
        "jkPrc+40mK7hNJHRFRGt12ms20W7WwB4GuvcCQT/JgA+SpnHOkhzxz0zVfqsnfl6LIp7RW+c0eJnWoIBvOFocYfWPeJ372741zbs",
        "h0i8FHKVA4xcjYYuevFkgFzUulW2LO/otGP9aRpjmuYz9G02H9+ti0KPNlqUlX8O4A9fLlxtFiB0qAAAAABJRU5ErkJggg==",
    ].joined()
    private static let headphonesB64 = [
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAAANlBMVEX///////////9HcEz/////////////////////////////",
        "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",
        "2fG0AAAAAElFTkSuQmCC",
    ].joined()
    private static let noteB64 = [
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAAAM1BMVEX///////9HcEz/////////////////////////////////",
        "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",
        "RY2G37YMAAAAAElFTkSuQmCC",
    ].joined()
    private static let badge01B64 = [
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAAAP1BMVEX///////////9HcEz/////////////////////////////",
        "//////////////////////////////////////+y82cgAAAAFHRSTlP8/gEAAgT59yHXpWsPyE7nLPI3iefliTsAAAT+SURBVGje",
        "7ZoJk6UoDICRAN7iwf//rZvghRoU35ve2artTFW/7ofykYMAYQT8sIhfwP8UoJTWWpHQh0zoRqqrrACJ4n8sovW5R6QE7fgwbL8t",
        "f6kIFkWEfeOTmhqKrp4qL1Pd9fRViDi+4ccEzXgRfM8Dzt3rbmoHF4gpq645Ii79963L3ElMAeoEwO6LqcS2zOQoxvgPgV/YqUeE",
        "ZLXAUXXWGYH/DP30H/iZIwAIAIGik0Vyju2hIAa/rfB5xfgBnVkLd3oFJdsAy3Dwwa50WX591EOEG2oAFQJgHpWcnGBeCgFL/5Nz",
        "ke5J8sxVzUZYAah15QzzllkAINb+Ff9giHDtRtjGX5QuZ1U+ApTG/nPxILkrZ8Iy/tW9CQANCf17HfTu6Zh7GYCGOqV/IlRbtOLs",
        "5d17AviJ3psH+++EDgm37j1GkddAqdal9Y8Dto03koLi/qVAA3RVav+kwkRGUnIs760aaKB0mSUDjBgKSSo89B8AXimwqgDqaVAe",
        "IAmgMEQNP1jDhodtUAVVOpOmAXpryPjsg0HIJQEfSE+APUxpDhiu+8xa45imPEMbwRtAdbWmycw0Nk1fM5nAuJLCKAngl0x97QRX",
        "mg5XVEzPhWUcYXp8NckHHtBzZkYr+E0FF2GzE9IB1y4w1pslp2m4zlePfwG45jmDKU2ty2ik+eADJtgWHwACroka55LUK2BkNGgP",
        "TvYBfQswrJGXnFzk2TWMmj1MDcZyNV0DcTcRZ+RxBzSXIDPO7gDccLQdt5zcAUTWrz5QoK/ezIZiAZjM2VqBugMwM2Zt8wAZacev",
        "0TrD1AC/IG7bltgItx0Qt670lE3ROpXf8L0FmEcAmhBfI+P7LesdAD7SgHxkba2XzeRXABXToC5gnyw/AFDBhv5nTBScF9h8soXp",
        "pxoczhUxAK+BeQSIVID8MEz/JOBTDb6PouAcwu4b/h2A/BYwU/7bgLsogh+dyQ+A5IkWB0ACQH6+HqigmvBVLkowEfw0QP4VgNg2",
        "Xh/7YC143WoAX2oATyb6DJCZPii7PJno/cZrG5y80WAH3Od7buu4+AgS1oMYIGXzewLc7K6ftu9DZq6nQAjqgqDvd9fTBZC7mmpx",
        "ED+AHFbMJ0DNALaqkJY1A8BmCKqbDyZiDoHO6u0QWEUOgUmLvgdcz0jYRe03hniM7fNILWEpJfrDruQBkoYpuDO7EbagGjxA08aV",
        "32roMmYiaouUEpz19eqx5c7h7TpJmlVYDXpqIQBXLsKjo23bki2GLC6gmuYqA3cUp4a2ETiVBqa2RKdTF6npjitgK7lz9SAqquOU",
        "FNGaqeErkSYr9XKu6TKq0JtoxdLgsx4wZi9Kaj7CpEyqJdKRXcT2t9E6kK+oLSZKA3Dp4EEBSAMIAkBy5XpNdEotW940Dai0rBor",
        "knQwPoTmpSZVg82cKYSlaCrfOXnNhyah/734/koDenp6JmD/wfXBKw0ob9buoVApDv2nawDb8/ZGCZM7MYFUUn6mwXzhU7kIgjJT",
        "O1ICD6/d3vhguQjsWp/hzCklYU4raz1niBAgBn9XGBdxANCtD3SVpSwozJrG6K+hrZvZPHA00ZNkQwigOY2rVNNNrTXrI8K2VV34",
        "+1g43sMq6KtHmfThNlaC0rRfgaYYuxqlG/vG32DPGfqESLsRv9xEK7qxXu+z1fW+OryHvcr5OyniN+jzrbv8/V8Jv4C/DvgHLJBx",
        "BJMovEAAAAAASUVORK5CYII=",
    ].joined()
    private static let badge39B64 = [
        "iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAAAOVBMVEX///////////9HcEz/////////////////////////////",
        "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",
    ].joined()
}
