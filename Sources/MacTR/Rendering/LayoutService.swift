// LayoutService.swift — the user's widget arrangement, from ~/.mactr/layout.json.
//
// Same shape as PinService: a stat() per metrics tick, re-parse only when the file
// changes, so editing the JSON takes effect without restarting. A config that does
// not validate is refused and the built-in default is used instead — a hand-edited
// file should never be able to produce a scrambled frame.
//
// Example (this is also the default, written out):
//
//   {
//     "cols": 5, "rows": 2,
//     "placements": [
//       {"kind": "operator", "col": 0, "row": 0, "colSpan": 1, "rowSpan": 2},
//       {"kind": "agents",   "col": 1, "row": 0, "colSpan": 3, "rowSpan": 2},
//       {"kind": "status",   "col": 4, "row": 0, "colSpan": 1, "rowSpan": 2}
//     ]
//   }

import Foundation

final class LayoutService: @unchecked Sendable {

    private let fm = FileManager.default
    private let lock = NSLock()
    private var config = LayoutConfig.default
    private var lastMTime: Date?
    private var loggedMissing = false
    /// Last rejection reason, so the same broken file is not logged every tick.
    private var lastProblem: String?

    /// ~/.mactr/layout.json — hand-editable, and what Settings writes.
    static var configPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mactr/layout.json"
    }

    /// The arrangement to render. Always valid.
    func current() -> LayoutConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    /// Re-read the config if it changed since the last poll. Cheap: a stat(), then a
    /// parse only when the mtime moved.
    func refresh() {
        let path = LayoutService.configPath
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date
        else {
            // No file at all is the normal case — fall back silently, once.
            if !loggedMissing {
                loggedMissing = true
                lock.lock(); config = .default; lock.unlock()
            }
            return
        }
        if let last = lastMTime, mtime == last { return }
        lastMTime = mtime
        loggedMissing = false

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        let decoded: LayoutConfig
        do {
            decoded = try JSONDecoder().decode(LayoutConfig.self, from: data)
        } catch {
            fallBack("解析失败: \(error.localizedDescription)")
            return
        }
        if let problem = decoded.problem() {
            fallBack("\(problem)")
            return
        }
        lastProblem = nil
        lock.lock(); config = decoded; lock.unlock()
        log("[Layout] Loaded \(decoded.placements.count) widget(s) on \(decoded.cols)×\(decoded.rows)")
    }

    /// Keep rendering the default and say why, but only once per distinct problem —
    /// this runs every couple of seconds.
    private func fallBack(_ reason: String) {
        lock.lock(); config = .default; lock.unlock()
        guard lastProblem != reason else { return }
        lastProblem = reason
        logProblem("[Layout] layout.json 被拒绝,回退默认布局 —— \(reason)")
    }

    /// Write a config to disk (used by Settings). Refuses an invalid one.
    @discardableResult
    func save(_ cfg: LayoutConfig) -> LayoutConfig.Problem? {
        if let problem = cfg.problem() { return problem }
        let path = LayoutService.configPath
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(cfg) else { return nil }
        try? data.write(to: URL(fileURLWithPath: path))
        // Apply immediately rather than waiting for the next poll to notice.
        lastMTime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        lock.lock(); config = cfg; lock.unlock()
        return nil
    }
}
