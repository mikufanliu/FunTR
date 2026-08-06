// GridLayout.swift — where widgets sit on the 1920x480 canvas.
//
// Replaces the hardcoded "panel 0 / 1 / 4" slots with a fixed M×N grid that widgets
// occupy by cell span, the way a phone home screen works: a widget is 1×1, 2×2, 3×2 …
// Not free-form — cells only — which keeps the config small and impossible to
// misalign.
//
// The default is 5×2, chosen because the previous fixed layout maps onto it exactly
// (operator 1×2 | agents 3×2 | status 1×2), so shipping this changes nothing on
// screen until someone writes a config.

import CoreGraphics
import Foundation

// MARK: - Grid

/// Cell geometry over the LCD canvas. Outer margin and inter-cell gap come from
/// `Layout`, so grid cells line up with what the panels used to do by hand.
struct GridLayout {
    let cols: Int
    let rows: Int

    static let `default` = GridLayout(cols: 5, rows: 2)

    /// Frame for a widget spanning `colSpan × rowSpan` cells from (`col`, `row`).
    ///
    /// Integer arithmetic on purpose: the old fixed layout used
    /// `panelWidth = (width - 2*margin - gap*(count-1)) / count` with Int division and
    /// `panelX(i) = margin + i * (panelWidth + gap)`. Matching that exactly is what
    /// makes the 5×2 default reproduce the previous screen to the pixel — in CGFloat
    /// the cell comes out 370.4 and the right-hand panel lands 1.6px off.
    ///
    /// Spans are clamped to the grid so an over-wide widget bleeds to the edge rather
    /// than off-canvas; `LayoutConfig.problem()` rejects those before they get here.
    func rect(col: Int, row: Int, colSpan: Int, rowSpan: Int) -> CGRect {
        let m = Layout.margin, g = Layout.gap
        let cw = (Layout.width - 2 * m - g * (cols - 1)) / cols
        let ch = (Layout.height - 2 * m - g * (rows - 1)) / rows

        let c = max(0, min(col, cols - 1))
        let r = max(0, min(row, rows - 1))
        let cs = max(1, min(colSpan, cols - c))
        let rs = max(1, min(rowSpan, rows - r))

        return CGRect(
            x: m + c * (cw + g),
            y: m + r * (ch + g),
            width: cw * cs + g * (cs - 1),
            height: ch * rs + g * (rs - 1))
    }
}

// MARK: - Widgets

/// Everything that can be placed. The first three are the full panels; the rest are
/// the pieces the status panel is built from, exposed individually so a grid with
/// small cells has something to put in them.
enum WidgetKind: String, CaseIterable, Codable, Sendable {
    case operatorPanel = "operator"
    case agents
    case status
    case clock
    case network
    case gauges

    /// Smallest span that still renders legibly. The agents panel splits into a list
    /// plus a detail column, so it collapses below three columns; the dials need the
    /// width to sit side by side. Enforced by `LayoutConfig.validated()`.
    var minSpan: (cols: Int, rows: Int) {
        switch self {
        case .agents:       return (3, 1)
        case .status:       return (1, 2)
        case .operatorPanel: return (1, 1)
        case .clock:        return (1, 1)
        case .network:      return (1, 1)
        case .gauges:       return (1, 1)
        }
    }

    /// Menu/Settings label.
    var title: String {
        switch self {
        case .operatorPanel: return "干员"
        case .agents:        return "AI Agents"
        case .status:        return "状态(时钟+网络+仪表)"
        case .clock:         return "时钟"
        case .network:       return "网络"
        case .gauges:        return "仪表环"
        }
    }
}

/// One widget's cell footprint.
struct Placement: Codable, Sendable {
    var kind: WidgetKind
    var col: Int
    var row: Int
    var colSpan: Int
    var rowSpan: Int

    /// Cells covered, for overlap checks.
    var cells: [(Int, Int)] {
        (0..<max(1, rowSpan)).flatMap { dr in
            (0..<max(1, colSpan)).map { dc in (col + dc, row + dr) }
        }
    }
}

// MARK: - Config

/// The whole arrangement, as loaded from `~/.mactr/layout.json`.
struct LayoutConfig: Codable, Sendable {
    var cols: Int
    var rows: Int
    var placements: [Placement]

    var grid: GridLayout { GridLayout(cols: cols, rows: rows) }

    /// Reproduces the layout that was hardcoded before the grid existed, so an
    /// install with no config renders exactly as it did.
    static let `default` = LayoutConfig(
        cols: 5, rows: 2,
        placements: [
            Placement(kind: .operatorPanel, col: 0, row: 0, colSpan: 1, rowSpan: 2),
            Placement(kind: .agents, col: 1, row: 0, colSpan: 3, rowSpan: 2),
            Placement(kind: .status, col: 4, row: 0, colSpan: 1, rowSpan: 2),
        ])

    /// Why a config was refused, for the log and for Settings to show inline.
    enum Problem: CustomStringConvertible {
        case badGrid(cols: Int, rows: Int)
        case empty
        case span(WidgetKind)
        case outOfBounds(WidgetKind)
        case tooSmall(WidgetKind, need: (cols: Int, rows: Int))
        case overlap(WidgetKind, WidgetKind, at: (Int, Int))
        case duplicate(WidgetKind)

        var description: String {
            switch self {
            case let .badGrid(c, r):    return "网格尺寸非法 (\(c)×\(r))"
            case .empty:                return "没有任何组件"
            case let .span(k):          return "\(k.rawValue) 的跨度必须至少 1×1"
            case let .outOfBounds(k):   return "\(k.rawValue) 超出网格范围"
            case let .tooSmall(k, n):   return "\(k.rawValue) 至少需要 \(n.cols)×\(n.rows)"
            case let .overlap(a, b, p): return "\(a.rawValue) 与 \(b.rawValue) 在格子 (\(p.0),\(p.1)) 重叠"
            case let .duplicate(k):     return "\(k.rawValue) 出现了多次"
            }
        }
    }

    /// Nil when the config is sound. Checked before use so a hand-edited file can
    /// never produce a scrambled frame — callers fall back to `.default` instead.
    func problem() -> Problem? {
        guard cols >= 1, rows >= 1, cols <= 12, rows <= 6 else {
            return .badGrid(cols: cols, rows: rows)
        }
        guard !placements.isEmpty else { return .empty }

        var seenKinds = Set<WidgetKind>()
        var owner: [String: WidgetKind] = [:]

        for p in placements {
            guard seenKinds.insert(p.kind).inserted else { return .duplicate(p.kind) }
            guard p.colSpan >= 1, p.rowSpan >= 1 else { return .span(p.kind) }
            guard p.col >= 0, p.row >= 0,
                  p.col + p.colSpan <= cols, p.row + p.rowSpan <= rows
            else { return .outOfBounds(p.kind) }

            let need = p.kind.minSpan
            guard p.colSpan >= need.cols, p.rowSpan >= need.rows else {
                return .tooSmall(p.kind, need: need)
            }

            for (c, r) in p.cells {
                let key = "\(c),\(r)"
                if let other = owner[key] { return .overlap(p.kind, other, at: (c, r)) }
                owner[key] = p.kind
            }
        }
        return nil
    }
}
