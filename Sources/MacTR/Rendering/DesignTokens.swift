// DesignTokens.swift — Colors, fonts, and layout constants
//
// Ported from trcc_monitor.py color/layout definitions.
// All values match the Python prototype for visual consistency.

import AppKit
import CoreGraphics

// MARK: - Colors

/// Convenience: 0-255 RGB(A) → CGColor (device RGB).
private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// A full color palette. Each theme supplies one; `Color` reads the active theme's.
struct Palette {
    let bgTop, bgBot, panelBG, border: CGColor
    let textW, textS, textL, textD: CGColor
    let blue, blueD, green, greenD, orange, orangeD, red, redD: CGColor
    let purple, purpleD, cyan, cyanD, magenta, magentaD, claude, barBG: CGColor

    /// Classic — the original dark-slate look.
    static let classic = Palette(
        bgTop: rgb(10, 12, 20), bgBot: rgb(16, 18, 28),
        panelBG: rgb(20, 23, 34), border: rgb(38, 42, 58),
        textW: rgb(230, 235, 245), textS: rgb(140, 148, 168),
        textL: rgb(100, 108, 130), textD: rgb(70, 76, 95),
        blue: rgb(66, 133, 244), blueD: rgb(30, 60, 120),
        green: rgb(52, 211, 153), greenD: rgb(24, 95, 70),
        orange: rgb(251, 191, 36), orangeD: rgb(110, 84, 16),
        red: rgb(239, 68, 68), redD: rgb(110, 30, 30),
        purple: rgb(167, 139, 250), purpleD: rgb(75, 62, 115),
        cyan: rgb(34, 211, 238), cyanD: rgb(15, 95, 108),
        magenta: rgb(217, 70, 239), magentaD: rgb(80, 28, 90),
        claude: rgb(217, 119, 87), barBG: rgb(30, 34, 48))

    /// 初音未来 — teal (#39C5BB) primary, magenta/pink secondary, digital-diva.
    static let miku = Palette(
        bgTop: rgb(6, 16, 18), bgBot: rgb(9, 24, 27),
        panelBG: rgb(12, 30, 33, 0.96), border: rgb(30, 74, 78),
        textW: rgb(228, 250, 249), textS: rgb(132, 190, 190),
        textL: rgb(92, 146, 148), textD: rgb(58, 100, 102),
        blue: rgb(74, 184, 232), blueD: rgb(20, 70, 96),
        green: rgb(61, 217, 192), greenD: rgb(16, 92, 84),
        orange: rgb(255, 196, 75), orangeD: rgb(110, 82, 20),
        red: rgb(255, 92, 122), redD: rgb(112, 30, 48),
        purple: rgb(255, 120, 180), purpleD: rgb(96, 40, 68),   // agents panel → Miku pink
        cyan: rgb(57, 197, 187), cyanD: rgb(16, 78, 74),        // signature teal
        magenta: rgb(255, 109, 168), magentaD: rgb(110, 34, 72),
        claude: rgb(230, 138, 108), barBG: rgb(15, 38, 41))

    /// 罗德岛 — near-black terminal, amber (#FFB13B) + cyan, Rhodes Island HUD.
    static let rhodes = Palette(
        bgTop: rgb(8, 9, 11), bgBot: rgb(13, 15, 18),
        panelBG: rgb(16, 18, 23, 0.96), border: rgb(38, 44, 52),
        textW: rgb(232, 236, 236), textS: rgb(140, 150, 156),
        textL: rgb(98, 108, 114), textD: rgb(64, 74, 80),
        blue: rgb(84, 170, 220), blueD: rgb(28, 66, 92),
        green: rgb(70, 208, 138), greenD: rgb(22, 92, 66),
        orange: rgb(255, 177, 59), orangeD: rgb(120, 82, 18),
        red: rgb(240, 71, 60), redD: rgb(112, 30, 26),
        purple: rgb(255, 177, 59), purpleD: rgb(120, 84, 24),   // agents panel → Rhodes amber
        cyan: rgb(47, 208, 218), cyanD: rgb(16, 84, 88),
        magenta: rgb(233, 120, 80), magentaD: rgb(96, 44, 30),
        claude: rgb(217, 119, 87), barBG: rgb(24, 28, 34))
}

/// Active-theme color accessors. Call sites (`Color.cyan`, …) are unchanged; the
/// values now resolve through `Theme.current`, so switching theme reskins the app.
enum Color {
    static var bgTop: CGColor { Theme.current.palette.bgTop }
    static var bgBot: CGColor { Theme.current.palette.bgBot }
    static var panelBG: CGColor { Theme.current.palette.panelBG }
    static var border: CGColor { Theme.current.palette.border }

    static var textW: CGColor { Theme.current.palette.textW }
    static var textS: CGColor { Theme.current.palette.textS }
    static var textL: CGColor { Theme.current.palette.textL }
    static var textD: CGColor { Theme.current.palette.textD }

    static var blue: CGColor { Theme.current.palette.blue }
    static var blueD: CGColor { Theme.current.palette.blueD }
    static var green: CGColor { Theme.current.palette.green }
    static var greenD: CGColor { Theme.current.palette.greenD }
    static var orange: CGColor { Theme.current.palette.orange }
    static var orangeD: CGColor { Theme.current.palette.orangeD }
    static var red: CGColor { Theme.current.palette.red }
    static var redD: CGColor { Theme.current.palette.redD }
    static var purple: CGColor { Theme.current.palette.purple }
    static var purpleD: CGColor { Theme.current.palette.purpleD }
    static var cyan: CGColor { Theme.current.palette.cyan }
    static var cyanD: CGColor { Theme.current.palette.cyanD }
    static var magenta: CGColor { Theme.current.palette.magenta }
    static var magentaD: CGColor { Theme.current.palette.magentaD }
    static var claude: CGColor { Theme.current.palette.claude }

    static var barBG: CGColor { Theme.current.palette.barBG }

    /// Color by percentage threshold: green < 50, orange < 75, red >= 75
    static func forPercent(_ pct: Double) -> CGColor {
        pct < 50 ? green : (pct < 75 ? orange : red)
    }

    static func forPercentDark(_ pct: Double) -> CGColor {
        pct < 50 ? greenD : (pct < 75 ? orangeD : redD)
    }

    /// Color by macOS memory pressure level (1=normal, 2=warn, 4=critical).
    /// Severity comes from pressure, not from used% — a Mac using RAM as cache is not "in danger".
    static func forPressure(_ level: Int) -> CGColor {
        level >= 4 ? red : (level >= 2 ? orange : green)
    }

    static func forPressureDark(_ level: Int) -> CGColor {
        level >= 4 ? redD : (level >= 2 ? orangeD : greenD)
    }
}

// MARK: - Theme

/// Selectable visual themes. `rawValue` is the user-facing name in Settings.
enum ThemeKind: String, CaseIterable, Sendable {
    case classic = "经典"
    case miku = "初音未来"
    case rhodes = "罗德岛"
}

/// A theme = a palette + style switches the drawing primitives read. Swapping
/// `Theme.current` reskins the whole dashboard (colors, panel frames, backdrop).
struct Theme {
    let kind: ThemeKind
    let palette: Palette
    let sharpCorners: Bool      // angular panels (HUD) vs rounded
    let cornerBrackets: Bool    // draw ⌐ ¬ L L accent ticks at panel corners
    let scanlines: Bool         // faint CRT scanline overlay on the backdrop
    let gridBackground: Bool    // faint grid on the backdrop
    let accentGlow: Bool        // glow under each panel's header bar

    static let classic = Theme(kind: .classic, palette: .classic, sharpCorners: false,
                               cornerBrackets: false, scanlines: false,
                               gridBackground: false, accentGlow: true)
    static let miku = Theme(kind: .miku, palette: .miku, sharpCorners: false,
                            cornerBrackets: true, scanlines: true,
                            gridBackground: false, accentGlow: true)
    static let rhodes = Theme(kind: .rhodes, palette: .rhodes, sharpCorners: true,
                              cornerBrackets: true, scanlines: true,
                              gridBackground: true, accentGlow: true)

    static func of(_ kind: ThemeKind) -> Theme {
        switch kind {
        case .classic: return .classic
        case .miku: return .miku
        case .rhodes: return .rhodes
        }
    }

    /// The active theme (read by the render thread, set from Settings).
    nonisolated(unsafe) static var current: Theme = .classic

    static func set(_ kind: ThemeKind) { current = of(kind) }
}


// MARK: - Layout

enum Layout {
    static let width = 1920
    static let height = 480
    static let margin = 14
    static let gap = 10
    static let panelCount = 5
    static let panelWidth = (width - 2 * margin - (panelCount - 1) * gap) / panelCount
    static let panelHeight = height - 2 * margin
    static let panelY = margin

    /// X position for panel at index (0-based)
    static func panelX(_ index: Int) -> Int {
        margin + index * (panelWidth + gap)
    }
}

// MARK: - Fonts

enum Fonts {
    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: NSFont.Weight
    }

    nonisolated(unsafe) private static var cache: [FontKey: NSFont] = [:]

    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = FontKey(size: size, weight: weight)
        if let cached = cache[key] {
            return cached
        }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    static func mono(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Brightness

enum Brightness {
    /// Brightness levels 1-10. Factor = 1.0 + (level-1) * 0.3
    static func factor(for level: Int) -> CGFloat {
        let clamped = max(1, min(10, level))
        return 1.0 + CGFloat(clamped - 1) * 0.3
    }
}
