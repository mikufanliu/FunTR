// PinService.swift — "Dynamic Island" push channel for the LCD.
//
// Any AI agent / script can project a result onto the screen by dropping a JSON
// file at ~/.mactr/pin.json. MacTR watches that file (polled from the metrics
// loop) and overlays it as an animated island card over whatever is on screen.
//
// The message may carry a title, a markdown body (tables/lists/prose — laid out
// by the same renderer the AI-agents panel uses), an emoji icon, and/or a
// projected image (file path or inline base64). `big:true` takes over the whole
// screen; otherwise it's a floating banner. `{"clear":true}` dismisses at once.
//
// Schema (all fields optional except that something must be shown):
//   {
//     "title":  "构建通过",
//     "body":   "**42/42** 测试通过\n\n| 模块 | 状态 |\n|---|---|\n| auth | ✓ |",
//     "icon":   "✅",                 // emoji badge
//     "image":  "/abs/path/to.png",  // projected picture (or "imageData": base64)
//     "source": "Claude Code",
//     "accent": "green",             // cyan|green|orange|red|purple|blue|magenta|claude
//     "secs":   12,                   // how long to stay (2…120, default 10)
//     "big":    false                 // full-screen takeover vs floating banner
//   }

import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// One resolved push message, ready to render. A class so its decoded image can
/// cross threads (metrics loop parses it, the render thread draws it) safely.
final class PinMessage: @unchecked Sendable {
    let title: String?
    let body: String?
    let source: String?
    let iconEmoji: String?
    let image: CGImage?
    let accent: CGColor
    let big: Bool
    let createdAt: Date
    let expiresAt: Date

    init(title: String?, body: String?, source: String?, iconEmoji: String?,
         image: CGImage?, accent: CGColor, big: Bool, secs: Double) {
        self.title = title
        self.body = body
        self.source = source
        self.iconEmoji = iconEmoji
        self.image = image
        self.accent = accent
        self.big = big
        let now = Date()
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(max(2, min(120, secs)))
    }
}

final class PinService: @unchecked Sendable {

    private let fm = FileManager.default
    private let lock = NSLock()
    private var current: PinMessage?
    private var lastMTime: Date?

    /// ~/.mactr/pin.json — the file agents/scripts write to.
    static var pinPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mactr/pin.json"
    }

    /// Re-read the pin file if it changed since last poll. Cheap: a stat() plus a
    /// parse only on change. Call from the background metrics loop (~0.5s).
    func refresh() {
        let path = PinService.pinPath
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else { return }
        if let last = lastMTime, mtime == last { return }
        lastMTime = mtime

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        if obj["clear"] as? Bool == true {
            lock.lock(); current = nil; lock.unlock()
            return
        }
        let pin = build(from: obj)
        lock.lock(); current = pin; lock.unlock()
    }

    /// The active pin, or nil once it has expired (expiry clears it).
    func current(now: Date = Date()) -> PinMessage? {
        lock.lock(); defer { lock.unlock() }
        guard let p = current else { return nil }
        if now >= p.expiresAt { current = nil; return nil }
        return p
    }

    private func build(from obj: [String: Any]) -> PinMessage {
        let title = trimmed(obj["title"] as? String)
        let body = (obj["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed(obj["source"] as? String)
        let iconEmoji = trimmed(obj["icon"] as? String)
        let big = obj["big"] as? Bool ?? false
        let secs = (obj["secs"] as? NSNumber)?.doubleValue ?? 10
        let accent = PinService.accentColor(obj["accent"] as? String)

        var image: CGImage?
        if let path = obj["image"] as? String, !path.isEmpty {
            image = PinService.loadImage(path: expandPath(path))
        } else if let b64 = obj["imageData"] as? String, let d = Data(base64Encoded: b64) {
            image = PinService.decodeImage(d)
        }

        return PinMessage(title: title, body: (body?.isEmpty == true ? nil : body),
                          source: source, iconEmoji: iconEmoji, image: image,
                          accent: accent, big: big, secs: secs)
    }

    private func trimmed(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    private func expandPath(_ p: String) -> String {
        p.hasPrefix("~") ? (p as NSString).expandingTildeInPath : p
    }

    // MARK: - Static helpers (also used by the --pin CLI)

    static func accentColor(_ name: String?) -> CGColor {
        switch name?.lowercased() {
        case "green": return Color.green
        case "orange", "yellow": return Color.orange
        case "red": return Color.red
        case "purple": return Color.purple
        case "blue": return Color.blue
        case "magenta", "pink": return Color.magenta
        case "claude": return Color.claude
        default: return Color.cyan
        }
    }

    static func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    /// Write a raw JSON string to ~/.mactr/pin.json (used by `MacTR --pin`).
    /// Creates the directory if needed. Returns false on failure.
    @discardableResult
    static func write(json: String) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.path + "/.mactr"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        do {
            try json.write(toFile: pinPath, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
