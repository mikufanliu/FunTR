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

struct LayoutEditorView: View {
    @State private var model: LayoutEditorModel
    @State private var service = LayoutService()
    @State private var dragging: WidgetKind?
    @State private var dragOffset: CGSize = .zero
    @State private var resizing: WidgetKind?
    @State private var status: String?
    @State private var statusIsError = false

    /// 1920x480 is 4:1; this keeps the preview honest about how little height there is.
    private static let canvasSize = CGSize(width: 880, height: 220)

    init() {
        let svc = LayoutService()
        svc.refresh()
        _model = State(initialValue: LayoutEditorModel(config: svc.current(),
                                                       canvas: LayoutEditorView.canvasSize))
        _service = State(initialValue: svc)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("拖动组件摆放,拖右下角改大小。灰色的是未启用的组件,点一下加进来。")
                .font(.caption).foregroundStyle(.secondary)

            canvas

            HStack(spacing: 10) {
                Stepper("列 \(model.config.cols)", value: colsBinding, in: 1...12)
                Stepper("行 \(model.config.rows)", value: rowsBinding, in: 1...6)
            }
            .font(.caption)

            palette

            HStack {
                Button("保存并应用") { save() }
                    .buttonStyle(.borderedProminent)
                Button("恢复默认") {
                    model.config = .default
                    save()
                }
                Spacer()
                if let status {
                    Label(status, systemImage: statusIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .orange : .green)
                        .font(.caption)
                }
            }
        }
        .padding(18)
        .frame(width: 920)
    }

    // MARK: Canvas

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            // Grid cells
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
                ctx.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
            }

            ForEach(model.config.placements, id: \.kind.rawValue) { p in
                tile(p)
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .background(SwiftUI.Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.5)))
    }

    private func tile(_ p: Placement) -> some View {
        let f = model.frame(for: p)
        let isDragging = dragging == p.kind || resizing == p.kind
        return ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color(for: p.kind).opacity(isDragging ? 0.55 : 0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color(for: p.kind), lineWidth: isDragging ? 2 : 1))
                .overlay(
                    VStack(spacing: 2) {
                        Text(p.kind.title).font(.system(size: 11, weight: .semibold))
                        Text("\(p.colSpan)×\(p.rowSpan)")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    })
            // Resize handle, bottom-right.
            Rectangle()
                .fill(color(for: p.kind))
                .frame(width: 12, height: 12)
                .overlay(Image(systemName: "arrow.down.right")
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(.black))
                .gesture(resizeGesture(p))
        }
        .frame(width: max(8, f.width), height: max(8, f.height))
        .offset(x: f.minX, y: f.minY)
        .gesture(moveGesture(p))
        .onTapGesture(count: 2) { remove(p.kind) }
        .help("拖动移动 · 拖右下角改大小 · 双击移除")
    }

    /// Drag anywhere on a tile to move it; snapping happens per-frame so the tile
    /// visibly lands on cells rather than floating between them.
    private func moveGesture(_ p: Placement) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragging = p.kind
                let origin = model.frame(for: p)
                let target = model.cell(at: CGPoint(x: origin.minX + value.translation.width + 2,
                                                    y: origin.minY + value.translation.height + 2))
                if let moved = model.moved(p.kind, to: target), moved.col != p.col || moved.row != p.row {
                    if model.apply(moved) { clearStatus() }
                }
            }
            .onEnded { _ in dragging = nil }
    }

    private func resizeGesture(_ p: Placement) -> some Gesture {
        DragGesture()
            .onChanged { value in
                resizing = p.kind
                let origin = model.frame(for: p)
                let corner = CGPoint(x: origin.maxX + value.translation.width - 2,
                                     y: origin.maxY + value.translation.height - 2)
                let target = model.cell(at: corner)
                if let resized = model.resized(p.kind, cornerAt: target),
                   resized.colSpan != p.colSpan || resized.rowSpan != p.rowSpan {
                    if model.apply(resized) { clearStatus() }
                }
            }
            .onEnded { _ in resizing = nil }
    }

    // MARK: Palette

    private var palette: some View {
        let placed = Set(model.config.placements.map { $0.kind })
        let available = WidgetKind.allCases.filter { !placed.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            Text("未启用").font(.caption).foregroundStyle(.secondary)
            if available.isEmpty {
                Text("全部已放上画布").font(.caption2).foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    ForEach(available, id: \.rawValue) { kind in
                        Button {
                            add(kind)
                        } label: {
                            Text(kind.title)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(color(for: kind).opacity(0.22))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(color(for: kind).opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                        .help("点击加到画布第一个空位")
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var colsBinding: Binding<Int> {
        Binding(get: { model.config.cols },
                set: { model.config.cols = $0; reflow() })
    }
    private var rowsBinding: Binding<Int> {
        Binding(get: { model.config.rows },
                set: { model.config.rows = $0; reflow() })
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

    private func add(_ kind: WidgetKind) {
        if let spot = model.firstFreeSpot(for: kind) {
            model.apply(spot)
            clearStatus()
        } else {
            statusIsError = true
            status = "\(kind.title) 放不下,先腾出格子"
        }
    }

    private func remove(_ kind: WidgetKind) {
        model.config.placements.removeAll { $0.kind == kind }
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

    /// Stable per-widget colour so tiles are identifiable at a glance.
    private func color(for kind: WidgetKind) -> SwiftUI.Color {
        switch kind {
        case .operatorPanel: return .teal
        case .agents:        return .pink
        case .status:        return .cyan
        case .clock:         return .blue
        case .network:       return .green
        case .gauges:        return .orange
        }
    }
}
