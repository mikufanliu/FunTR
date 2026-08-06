// LayoutEditorView.swift — drag widgets onto a preview of the actual screen.
//
// Steppers were the wrong tool: arranging a screen is a spatial task, so this shows a
// scaled 1920x480 canvas with the grid drawn on it, and you drag tiles around. Geometry
// lives in `LayoutEditorModel` — pure functions over cells, no SwiftUI — so the snapping
// and collision rules are testable without driving the UI.

import AppKit
import SwiftUI

// MARK: - Geometry model (pure, testable)

/// Cell arithmetic for the editor: point↔cell conversion, snapping, collision.
struct LayoutEditorModel {
    var config: LayoutConfig
    /// Size of the preview canvas in points (the 1920x480 aspect, scaled down).
    var canvas: CGSize

    var cellW: CGFloat { canvas.width / CGFloat(max(1, config.cols)) }
    var cellH: CGFloat { canvas.height / CGFloat(max(1, config.rows)) }

    /// Preview frame for a placement, inset slightly so neighbours read as separate.
    func frame(for p: Placement) -> CGRect {
        CGRect(x: CGFloat(p.col) * cellW + 1,
               y: CGFloat(p.row) * cellH + 1,
               width: CGFloat(p.colSpan) * cellW - 2,
               height: CGFloat(p.rowSpan) * cellH - 2)
    }

    /// Cell under a point, clamped to the grid.
    func cell(at point: CGPoint) -> (col: Int, row: Int) {
        let c = Int(floor(point.x / cellW))
        let r = Int(floor(point.y / cellH))
        return (max(0, min(c, config.cols - 1)), max(0, min(r, config.rows - 1)))
    }

    /// Topmost placement containing a point — last in the array wins, matching draw order.
    func placement(at point: CGPoint) -> WidgetKind? {
        let (c, r) = cell(at: point)
        for p in config.placements.reversed() where p.cells.contains(where: { $0 == (c, r) }) {
            return p.kind
        }
        return nil
    }

    /// Move a widget so its top-left lands on `target`, keeping its span and staying
    /// inside the grid. Returns nil if the widget is not placed.
    func moved(_ kind: WidgetKind, to target: (col: Int, row: Int)) -> Placement? {
        guard let p = config.placements.first(where: { $0.kind == kind }) else { return nil }
        var moved = p
        moved.col = max(0, min(target.col, config.cols - p.colSpan))
        moved.row = max(0, min(target.row, config.rows - p.rowSpan))
        return moved
    }

    /// Resize a widget so its bottom-right corner reaches `target`, honouring its
    /// minimum span and the grid edge.
    func resized(_ kind: WidgetKind, cornerAt target: (col: Int, row: Int)) -> Placement? {
        guard let p = config.placements.first(where: { $0.kind == kind }) else { return nil }
        let need = kind.minSpan
        var out = p
        out.colSpan = max(need.cols, min(target.col - p.col + 1, config.cols - p.col))
        out.rowSpan = max(need.rows, min(target.row - p.row + 1, config.rows - p.row))
        return out
    }

    /// Cells already taken by anything other than `ignoring`.
    func occupied(ignoring: WidgetKind?) -> Set<String> {
        var out = Set<String>()
        for p in config.placements where p.kind != ignoring {
            for (c, r) in p.cells { out.insert("\(c),\(r)") }
        }
        return out
    }

    /// Would this placement sit clear of everything else and inside the grid?
    func fits(_ p: Placement) -> Bool {
        guard p.col >= 0, p.row >= 0,
              p.col + p.colSpan <= config.cols, p.row + p.rowSpan <= config.rows
        else { return false }
        let taken = occupied(ignoring: p.kind)
        return !p.cells.contains { taken.contains("\($0.0),\($0.1)") }
    }

    /// Replace a placement if the new footprint fits; returns whether it was applied.
    @discardableResult
    mutating func apply(_ p: Placement) -> Bool {
        guard fits(p) else { return false }
        if let i = config.placements.firstIndex(where: { $0.kind == p.kind }) {
            config.placements[i] = p
        } else {
            config.placements.append(p)
        }
        return true
    }

    /// First free spot big enough for `kind`, scanning row-major. Nil if it won't fit.
    func firstFreeSpot(for kind: WidgetKind) -> Placement? {
        let need = kind.minSpan
        let taken = occupied(ignoring: kind)
        for r in 0...(max(0, config.rows - need.rows)) {
            for c in 0...(max(0, config.cols - need.cols)) {
                let candidate = Placement(kind: kind, col: c, row: r,
                                          colSpan: need.cols, rowSpan: need.rows)
                guard candidate.col + candidate.colSpan <= config.cols,
                      candidate.row + candidate.rowSpan <= config.rows else { continue }
                if !candidate.cells.contains(where: { taken.contains("\($0.0),\($0.1)") }) {
                    return candidate
                }
            }
        }
        return nil
    }
}

// MARK: - Editor

/// Cached widget thumbnails. Rendering one is a few milliseconds, but the gallery asks
/// for the same dozen every time the view refreshes, so they are built once.
@MainActor
final class WidgetPreviewCache {
    static let shared = WidgetPreviewCache()
    private let renderer = MonitorRenderer()
    private var cache: [String: CGImage] = [:]
    private var canvasCache: [String: CGImage] = [:]

    func thumbnail(_ kind: WidgetKind, cols: Int, rows: Int,
                   gridCols: Int, gridRows: Int) -> CGImage? {
        let key = "\(kind.rawValue)-\(cols)x\(rows)-\(gridCols)x\(gridRows)-\(Theme.current.kind.rawValue)"
        if let hit = cache[key] { return hit }
        let img = renderer.renderWidgetPreview(kind, colSpan: cols, rowSpan: rows,
                                               cols: gridCols, rows: gridRows)
        if let img { cache[key] = img }
        return img
    }

    /// Full-canvas preview of an arrangement. Keyed on the arrangement itself, so
    /// dragging a tile back to where it was is free.
    func canvas(_ config: LayoutConfig) -> CGImage? {
        let key = "\(config.cols)x\(config.rows)|" + config.placements
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map { "\($0.kind.rawValue):\($0.col),\($0.row),\($0.colSpan),\($0.rowSpan)" }
            .joined(separator: "|") + "|\(Theme.current.kind.rawValue)"
        if let hit = canvasCache[key] { return hit }
        let img = renderer.renderPreview(config: config)
        if let img {
            // Bound the cache: a long editing session would otherwise keep every
            // intermediate arrangement's 3.7MB bitmap alive.
            if canvasCache.count > 24 { canvasCache.removeAll() }
            canvasCache[key] = img
        }
        return img
    }
}

struct LayoutEditorView: View {
    @State private var model: LayoutEditorModel
    @State private var service = LayoutService()
    @State private var dragging: WidgetKind?
    @State private var dragTranslation: CGSize = .zero
    @State private var dropCandidate: (kind: WidgetKind, cols: Int, rows: Int)?
    @State private var status: String?
    @State private var statusIsError = false

    /// 4:1, same as the panel — the preview is the real frame scaled down.
    private static let canvasSize = CGSize(width: 900, height: 225)

    init() {
        let svc = LayoutService()
        svc.refresh()
        _model = State(initialValue: LayoutEditorModel(config: svc.current(),
                                                       canvas: LayoutEditorView.canvasSize))
        _service = State(initialValue: svc)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下面就是 LCD 的实际画面。从组件库拖到画面上摆放,拖出画面即移除。")
                .font(.caption).foregroundStyle(.secondary)

            canvas

            HStack(spacing: 10) {
                Stepper("列 \(model.config.cols)", value: colsBinding, in: 1...12)
                Stepper("行 \(model.config.rows)", value: rowsBinding, in: 1...6)
                Spacer()
                Button("保存并应用") { save() }.buttonStyle(.borderedProminent)
                Button("恢复默认") { model.config = .default; save() }
                if let status {
                    Label(status, systemImage: statusIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .orange : .green).font(.caption)
                }
            }
            .font(.caption)

            Divider()
            gallery
        }
        .padding(18)
        .frame(width: 940)
    }

    // MARK: Canvas — the actual rendered frame, with invisible drag targets over it

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            if let img = WidgetPreviewCache.shared.canvas(model.config) {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            } else {
                Rectangle().fill(SwiftUI.Color.black)
                    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            }

            // Grid guides, faint, only while arranging.
            if dragging != nil || dropCandidate != nil {
                Canvas { ctx, size in
                    let cw = size.width / CGFloat(model.config.cols)
                    let ch = size.height / CGFloat(model.config.rows)
                    var path = Path()
                    for c in 0...model.config.cols {
                        let x = CGFloat(c) * cw
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for r in 0...model.config.rows {
                        let y = CGFloat(r) * ch
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    ctx.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1)
                }
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                .allowsHitTesting(false)
            }

            // One transparent handle per placed widget: the visual IS the render
            // underneath, so these only carry the gesture and a selection outline.
            ForEach(model.config.placements, id: \.kind.rawValue) { p in
                handle(p)
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.5)))
    }

    private func handle(_ p: Placement) -> some View {
        let f = model.frame(for: p)
        let active = dragging == p.kind
        return RoundedRectangle(cornerRadius: 3)
            .fill(SwiftUI.Color.white.opacity(active ? 0.16 : 0.001))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(active ? SwiftUI.Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                if active {
                    Text("\(p.kind.title) \(p.colSpan)×\(p.rowSpan)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(SwiftUI.Color.accentColor)
                        .foregroundStyle(.white)
                        .padding(3)
                }
            }
            .frame(width: max(8, f.width), height: max(8, f.height))
            .offset(x: f.minX, y: f.minY)
            .gesture(moveGesture(p))
            .help("拖动摆放 · 拖出画面移除 · 在组件库里换尺寸")
    }

    /// Drag to move; drop outside the canvas to remove — the phone gesture.
    private func moveGesture(_ p: Placement) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                dragging = p.kind
                dragTranslation = value.translation
                let origin = model.frame(for: p)
                let point = CGPoint(x: origin.minX + value.translation.width + 2,
                                    y: origin.minY + value.translation.height + 2)
                let target = model.cell(at: point)
                if let moved = model.moved(p.kind, to: target),
                   moved.col != p.col || moved.row != p.row {
                    if model.apply(moved) { clearStatus() }
                }
            }
            .onEnded { value in
                let origin = model.frame(for: p)
                let end = CGPoint(x: origin.minX + value.translation.width,
                                  y: origin.minY + value.translation.height)
                let outside = end.x < -40 || end.y < -40
                    || end.x > Self.canvasSize.width + 40
                    || end.y > Self.canvasSize.height + 40
                if outside {
                    model.config.placements.removeAll { $0.kind == p.kind }
                    statusIsError = false
                    status = "已移除 \(p.kind.title)"
                }
                dragging = nil
                dragTranslation = .zero
            }
    }

    // MARK: Gallery — every widget at every offered size, rendered for real

    private var gallery: some View {
        let placed = Set(model.config.placements.map { $0.kind })
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(WidgetKind.allCases, id: \.rawValue) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(kind.title).font(.system(size: 12, weight: .semibold))
                            if placed.contains(kind) {
                                Text("已在画面上").font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(kind.sizePresets.indices, id: \.self) { i in
                                presetChip(kind, kind.sizePresets[i])
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 210)
    }

    private func presetChip(_ kind: WidgetKind, _ size: (cols: Int, rows: Int)) -> some View {
        let fits = size.cols <= model.config.cols && size.rows <= model.config.rows
        let current = model.config.placements.first { $0.kind == kind }
        let isCurrent = current?.colSpan == size.cols && current?.rowSpan == size.rows
        // Thumbnail width tracks the span so the presets read as different sizes.
        let w = 46.0 * Double(size.cols)
        let h = 46.0 * Double(size.rows) * 0.62
        return VStack(spacing: 3) {
            ZStack {
                if let img = WidgetPreviewCache.shared.thumbnail(
                    kind, cols: size.cols, rows: size.rows,
                    gridCols: max(size.cols, model.config.cols),
                    gridRows: max(size.rows, model.config.rows)) {
                    Image(decorative: img, scale: 1).resizable()
                } else {
                    Rectangle().fill(SwiftUI.Color.gray.opacity(0.3))
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(isCurrent ? SwiftUI.Color.accentColor : .secondary.opacity(0.4),
                        lineWidth: isCurrent ? 2 : 1))
            .opacity(fits ? 1 : 0.35)
            Text("\(size.cols)×\(size.rows)")
                .font(.system(size: 9))
                .foregroundStyle(isCurrent ? SwiftUI.Color.accentColor : .secondary)
        }
        .onTapGesture { place(kind, size) }
        .help(fits ? "点击放上画面(已在画面上则换成这个尺寸)" : "当前网格放不下这个尺寸")
    }

    // MARK: Actions

    /// Tapping a preset places the widget, or resizes it in place if it is already up.
    private func place(_ kind: WidgetKind, _ size: (cols: Int, rows: Int)) {
        guard size.cols <= model.config.cols, size.rows <= model.config.rows else {
            statusIsError = true
            status = "当前网格放不下 \(size.cols)×\(size.rows),先调大网格"
            return
        }
        if let existing = model.config.placements.first(where: { $0.kind == kind }) {
            var resized = existing
            resized.colSpan = size.cols
            resized.rowSpan = size.rows
            resized.col = min(existing.col, model.config.cols - size.cols)
            resized.row = min(existing.row, model.config.rows - size.rows)
            if model.apply(resized) {
                clearStatus()
            } else {
                statusIsError = true
                status = "\(kind.title) 改成 \(size.cols)×\(size.rows) 会和别的组件重叠"
            }
            return
        }
        // Not placed yet: find room at this size, scanning row-major.
        for r in 0...max(0, model.config.rows - size.rows) {
            for c in 0...max(0, model.config.cols - size.cols) {
                let candidate = Placement(kind: kind, col: c, row: r,
                                          colSpan: size.cols, rowSpan: size.rows)
                if model.apply(candidate) { clearStatus(); return }
            }
        }
        statusIsError = true
        status = "画面上没有 \(size.cols)×\(size.rows) 的空位"
    }

    private var colsBinding: Binding<Int> {
        Binding(get: { model.config.cols }, set: { model.config.cols = $0; reflow() })
    }
    private var rowsBinding: Binding<Int> {
        Binding(get: { model.config.rows }, set: { model.config.rows = $0; reflow() })
    }

    /// After a grid resize, pull anything now hanging off the edge back inside.
    private func reflow() {
        for i in model.config.placements.indices {
            var p = model.config.placements[i]
            p.colSpan = min(p.colSpan, model.config.cols)
            p.rowSpan = min(p.rowSpan, model.config.rows)
            p.col = min(p.col, model.config.cols - p.colSpan)
            p.row = min(p.row, model.config.rows - p.rowSpan)
            model.config.placements[i] = p
        }
        clearStatus()
    }

    private func clearStatus() { status = nil; statusIsError = false }

    private func save() {
        if let problem = service.save(model.config) {
            statusIsError = true
            status = "\(problem)"
        } else {
            statusIsError = false
            status = "已应用"
        }
    }
}
