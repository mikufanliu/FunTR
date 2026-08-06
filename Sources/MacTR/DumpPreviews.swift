// DumpPreviews.swift — write the layout editor's previews to PNGs.
//
// The editor's canvas and gallery are real renders, not mockups, so they can be checked
// headlessly: `FunTR --dump-previews [dir]` writes one PNG per widget size preset plus
// two whole-canvas arrangements. Useful for eyeballing a theme's widgets, and the only
// way to inspect the editor's imagery without opening the window.

import CoreGraphics
import Foundation
import ImageIO

func runDumpPreviews() {
    let args = CommandLine.arguments
    var dir = "/tmp"
    if let i = args.firstIndex(of: "--dump-previews"), i + 1 < args.count,
       !args[i + 1].hasPrefix("--") {
        dir = args[i + 1]
    }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    func save(_ img: CGImage, _ name: String) {
        let path = dir + "/" + name
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        print("  \(name)  \(img.width)x\(img.height)")
    }

    let renderer = MonitorRenderer()
    print("[Previews] theme=\(Theme.current.kind.rawValue) → \(dir)")

    print("gallery thumbnails:")
    for kind in WidgetKind.allCases {
        for (i, size) in kind.sizePresets.enumerated() {
            guard let img = renderer.renderWidgetPreview(
                kind, colSpan: size.cols, rowSpan: size.rows, cols: 5, rows: 2)
            else {
                print("  FAILED \(kind.rawValue) \(size.cols)x\(size.rows)")
                continue
            }
            save(img, "prev-\(kind.rawValue)-\(i)-\(size.cols)x\(size.rows).png")
        }
    }

    print("canvas previews:")
    if let img = renderer.renderPreview(config: .default) {
        save(img, "prev-canvas-default.png")
    }
    let custom = LayoutConfig(cols: 5, rows: 2, placements: [
        Placement(kind: .agents, col: 0, row: 0, colSpan: 3, rowSpan: 2),
        Placement(kind: .operatorPanel, col: 3, row: 0, colSpan: 1, rowSpan: 2),
        Placement(kind: .clock, col: 4, row: 0, colSpan: 1, rowSpan: 1),
        Placement(kind: .gauges, col: 4, row: 1, colSpan: 1, rowSpan: 1),
    ])
    if let img = renderer.renderPreview(config: custom) {
        save(img, "prev-canvas-custom.png")
    }
}
