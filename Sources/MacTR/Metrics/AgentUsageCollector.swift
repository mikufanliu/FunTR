// AgentUsageCollector.swift — Claude Code / Codex CLI usage collection
//
// Parses local session transcripts to report today's token usage and the
// agent's latest activity. No subprocess, no network:
//   Claude: ~/.claude/projects/<proj>/<session>.jsonl — per-message "usage"
//   Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — "token_count" events
//
// Files are read incrementally (per-file byte offsets) so the steady-state
// cost per tick is a stat() per candidate file plus any appended bytes —
// full parses happen only on first scan and day rollover.

import Darwin
import Foundation

// MARK: - Data Structures

enum AgentKind: String, Sendable {
    case claude = "Claude"
    case codex = "Codex"
}

/// One live/recent CLI session — a single card in the control-tower list.
struct AgentEntry: Sendable {
    let kind: AgentKind
    let id: String                  // stable key (kind + project) for flash edge tracking
    let project: String?            // cwd basename
    let message: String?            // last thing it said (markdown preserved)
    let secondsSinceActive: Int
    let waiting: Bool               // turn ended, waiting for the user (persistent while recent)
    let flash: Bool                 // 10s attention pulse after `waiting` first appears
    let isWorking: Bool             // actively running a turn
    let stepCurrent: Int?           // active plan step (1-based); nil = no plan
    let stepTotal: Int?
    let stepText: String?
    // Why it's blocked mid-turn, when the CLI tells us — "permission prompt",
    // "input needed", "dialog open". nil when it ended its turn normally.
    var waitingFor: String? = nil
    var model: String? = nil        // model id driving this session
}

/// One entry in the cross-session activity feed (a state transition).
struct AgentEvent: Sendable {
    let icon: String        // ▶ started · ✓ finished a turn · ⏸ now waiting on you
    let verb: String
    let project: String
    let kind: AgentKind
    let atSecs: Int         // wall-clock seconds, for "Ns ago"
}

/// All recent agent sessions + account-level aggregates. Token/quota are demoted
/// to a compact footer, so they live on the snapshot, not on each entry.
struct AgentsSnapshot: Sendable {
    let entries: [AgentEntry]
    let claudeAvailable: Bool
    let codexAvailable: Bool
    let claudeTodayTokens: UInt64
    let codexTodayTokens: UInt64
    let codexQuotaUsedPercent: Double?
    let codexQuotaResetsAt: Date?
    var recentEvents: [AgentEvent] = []

    /// Anything animating right now (working breathing or attention flash).
    var anyLive: Bool { entries.contains { $0.isWorking || $0.flash } }
    /// Anything waiting for the user (drives the whole-panel alert border).
    var anyWaiting: Bool { entries.contains { $0.waiting } }
}

// MARK: - Collector

final class AgentUsageCollector: @unchecked Sendable {

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    // Incremental state, reset on day rollover
    private var dayKey = ""
    private var todayStartISO = ""      // lexical threshold for ISO8601 "Z" timestamps
    private var claudeOffsets: [String: UInt64] = [:]
    private var claudeSeenIDs: Set<String> = []
    private var claudeInput: UInt64 = 0
    private var claudeOutput: UInt64 = 0
    private var codexOffsets: [String: UInt64] = [:]
    private var codexInput: UInt64 = 0
    private var codexOutput: UInt64 = 0

    // Attention edge tracking — flash only for the first N seconds after the
    // waiting/done state appears, tracked PER session id (multiple agents at once).
    private let flashDuration: TimeInterval = 10
    private var attentionSince: [String: Date] = [:]   // id → rising-edge time
    private var prevWaiting: Set<String> = []
    // Activity feed: last-seen state per session + a rolling event log.
    private var prevStates: [String: Int] = [:]        // id → 0 idle / 1 working / 2 waiting
    private var eventLog: [AgentEvent] = []

    // Control-tower list scope: a session is listed if it was active within this
    // window, capped per CLI so a busy history can't flood the list.
    private let liveWindow: TimeInterval = 6 * 3600
    private let activeWindow: TimeInterval = 20 * 60   // concurrent sessions in one project
    private let maxEntriesPerKind = 8

    // Last-known Codex quota (account-global). The full rate-limit block appears only
    // occasionally and the newest reading may be in a different file than the active
    // one, so we track the newest-by-timestamp across recent files and cache it.
    private var codexQuotaCache: (used: Double, resets: Date?)?
    private var codexQuotaTS = ""            // newest reading's timestamp seen so far
    private var codexQuotaLastScan: Date?

    func collect() -> AgentsSnapshot {
        rolloverIfNeeded()
        let (cEntries, cTokens, cAvail) = collectClaude()
        let (xEntries, xTokens, xAvail, qUsed, qResets) = collectCodex()
        let all = cEntries + xEntries
        let liveIDs = Set(all.map { $0.id })
        // Drop flash state for sessions that aged out of the list.
        attentionSince = attentionSince.filter { liveIDs.contains($0.key) }
        prevWaiting = prevWaiting.intersection(liveIDs)

        // Activity feed: emit an event whenever a session changes state.
        let nowSecs = Int(Date().timeIntervalSince1970)
        for e in all {
            let cur = e.isWorking ? 1 : (e.waiting ? 2 : 0)
            if let prev = prevStates[e.id], prev != cur, let proj = e.project {
                let ev: (icon: String, verb: String)?
                if cur == 1 { ev = ("▶", "开始") }
                else if prev == 1 { ev = ("✓", "完成一轮") }
                else if cur == 2 { ev = ("⏸", "等你输入") }
                else { ev = nil }
                if let ev = ev {
                    eventLog.append(AgentEvent(icon: ev.icon, verb: ev.verb,
                                               project: proj, kind: e.kind, atSecs: nowSecs))
                }
            }
            prevStates[e.id] = cur
        }
        prevStates = prevStates.filter { liveIDs.contains($0.key) }
        if eventLog.count > 24 { eventLog.removeFirst(eventLog.count - 24) }

        var snap = AgentsSnapshot(entries: all,
                                  claudeAvailable: cAvail, codexAvailable: xAvail,
                                  claudeTodayTokens: cTokens, codexTodayTokens: xTokens,
                                  codexQuotaUsedPercent: qUsed, codexQuotaResetsAt: qResets)
        snap.recentEvents = Array(eventLog.suffix(8).reversed())  // newest first
        return snap
    }

    /// Per-session attention state. `waiting` persists while the session is recent;
    /// `flash` pulses only for `flashDuration` after the rising edge.
    /// `persistent` is for states that are actionable rather than merely
    /// informational — a permission prompt keeps flashing until you answer it,
    /// where a finished turn only pulses for `flashDuration`.
    private func attentionState(id: String, rawWaiting: Bool, ago: Int,
                                persistent: Bool = false)
        -> (waiting: Bool, flash: Bool) {
        let waiting = persistent ? rawWaiting : (rawWaiting && ago < 900)
        let now = Date()
        if waiting && !prevWaiting.contains(id) { attentionSince[id] = now }
        if waiting { prevWaiting.insert(id) } else { prevWaiting.remove(id) }
        var flash = false
        if waiting, persistent {
            flash = true
        } else if waiting, let since = attentionSince[id],
                  now.timeIntervalSince(since) < flashDuration {
            flash = true
        }
        return (waiting, flash)
    }

    /// Reset accumulators at local midnight. Timestamps in both formats are
    /// UTC ISO8601 ("...Z"), so "today" = lexical compare against the local
    /// midnight rendered in UTC.
    private func rolloverIfNeeded() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let key = df.string(from: Date())
        guard key != dayKey else { return }
        dayKey = key

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        todayStartISO = iso.string(from: Calendar.current.startOfDay(for: Date()))

        claudeOffsets = [:]; claudeSeenIDs = []; claudeInput = 0; claudeOutput = 0
        codexOffsets = [:]; codexInput = 0; codexOutput = 0
    }

    // MARK: - Claude

    private func collectClaude() -> (entries: [AgentEntry], tokens: UInt64, available: Bool) {
        let root = home + "/.claude/projects"
        guard fm.fileExists(atPath: root) else { return ([], 0, false) }

        let todayStart = Calendar.current.startOfDay(for: Date())
        let now = Date()
        // Each recently-appended session file is its own card: concurrent sessions in
        // the SAME project (multiple Claude windows in one repo) all show, instead of
        // collapsing to one. An idle project falls back to just its newest file.
        var candidates: [(fallbackName: String, path: String, stem: String, mtime: Date)] = []

        for projDir in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let dirPath = root + "/" + projDir
            var dirFiles: [(path: String, stem: String, mtime: Date)] = []
            for file in (try? fm.contentsOfDirectory(atPath: dirPath)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = dirPath + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }

                // Token counting is scoped to today only, across ALL files
                if mtime >= todayStart {
                    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    consumeNewLines(path: path, size: size, offsets: &claudeOffsets,
                                    prefilter: "\"type\":\"assistant\"") { line in
                        self.accumulateClaudeLine(line)
                    }
                }
                if now.timeIntervalSince(mtime) <= liveWindow {
                    dirFiles.append((path, String(file.dropLast(6)), mtime))
                }
            }
            guard !dirFiles.isEmpty else { continue }
            dirFiles.sort { $0.mtime > $1.mtime }
            // Files touched within activeWindow are concurrently live → each its own
            // card; if none are, show a single idle representative (the newest).
            let active = dirFiles.filter { now.timeIntervalSince($0.mtime) < activeWindow }
            let chosen = active.isEmpty ? [dirFiles[0]] : Array(active.prefix(4))
            for f in chosen { candidates.append((projDir, f.path, f.stem, f.mtime)) }
        }

        candidates.sort { $0.mtime > $1.mtime }
        // Claude Code publishes the real UI state per session; a permission prompt and
        // a running tool are INDISTINGUISHABLE in the transcript (both end on an
        // assistant tool_use with no tool_result yet), so the tail heuristic below
        // reads "needs confirmation" as "still working" and never flashes.
        let liveStates = claudeSessionStates()
        var entries: [AgentEntry] = []
        var projSeen: [String: Int] = [:]
        for c in candidates.prefix(maxEntriesPerKind) {
            let ago = max(0, Int(now.timeIntervalSince(c.mtime)))
            let (proj, message, rawWaiting, step, model) = claudeActivity(path: c.path)
            let base = proj ?? c.fallbackName
            let n = (projSeen[base] ?? 0) + 1
            projSeen[base] = n
            let display = n > 1 ? "\(base) #\(n)" : base
            let id = "claude:" + c.stem            // unique & stable per session file
            // The file stem IS the session id, so live state maps straight onto this
            // card — no need to pick one "representative" session the way a
            // single-column layout would.
            let live = liveStates[c.stem]
            let waiting: Bool, flash: Bool, working: Bool
            var waitingFor: String?

            if live?.isBlocked == true {
                // Blocked on you mid-turn. Actionable, so it keeps flashing until
                // answered rather than pulsing for 10s and going quiet.
                working = false
                waitingFor = live?.waitingFor
                (waiting, flash) = attentionState(id: id, rawWaiting: true, ago: ago,
                                                  persistent: true)
            } else {
                switch live?.status {
                case "waiting":
                    // Blocked, but you've left it sitting past the staleness bound —
                    // show the state, stop nagging.
                    working = false
                    waitingFor = live?.waitingFor
                    waiting = attentionState(id: id, rawWaiting: true, ago: ago,
                                             persistent: true).waiting
                    flash = false
                case "busy", "shell":
                    working = true
                    (waiting, flash) = attentionState(id: id, rawWaiting: false, ago: ago)
                case "idle":
                    // Turn ended, Claude awaits your next prompt → the done-flash.
                    working = false
                    (waiting, flash) = attentionState(id: id, rawWaiting: true, ago: ago)
                default:
                    // No live record (CLI exited, or a build that doesn't publish one)
                    // — fall back to inferring from the transcript tail as before.
                    (waiting, flash) = attentionState(id: id, rawWaiting: rawWaiting, ago: ago)
                    working = !rawWaiting && ago < 90
                }
            }
            entries.append(AgentEntry(
                kind: .claude, id: id, project: display, message: message,
                secondsSinceActive: ago, waiting: waiting, flash: flash, isWorking: working,
                stepCurrent: step?.current, stepTotal: step?.total, stepText: step?.text,
                waitingFor: waitingFor, model: model))
        }
        return (entries, claudeInput + claudeOutput, true)
    }

    // MARK: - Claude live session state

    /// What Claude Code publishes about a running session in
    /// `~/.claude/sessions/<pid>.json`. `status` is one of busy / shell / idle /
    /// waiting; `waitingFor` explains a `waiting` — "permission prompt",
    /// "input needed", "dialog open", "sandbox request", "worker request".
    private struct ClaudeSessionState {
        let status: String
        let waitingFor: String?
        let statusUpdatedAt: Date?

        /// Blocked on the user, and recently enough to still be worth surfacing.
        /// The staleness bound matches the transcript path: a prompt you walked away
        /// from an hour ago must not pin a card or flash forever.
        var isBlocked: Bool {
            guard status == "waiting" else { return false }
            guard let at = statusUpdatedAt else { return true }
            return Date().timeIntervalSince(at) < 900
        }
    }

    /// sessionId → live state, for sessions whose CLI process is still alive.
    /// A handful of small JSON files, so this is re-read each tick rather than cached.
    private func claudeSessionStates() -> [String: ClaudeSessionState] {
        let dir = home + "/.claude/sessions"
        var out: [String: ClaudeSessionState] = [:]
        for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            guard file.hasSuffix(".json"),
                  let data = fm.contents(atPath: dir + "/" + file),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let status = obj["status"] as? String
            else { continue }
            // Ignore records orphaned by a crashed CLI — their last-written status
            // would otherwise pin the card to "working" or "waiting" forever.
            if let pid = (obj["pid"] as? NSNumber)?.int32Value,
               kill(pid, 0) != 0, errno == ESRCH { continue }
            // statusUpdatedAt is epoch milliseconds
            let updated = (obj["statusUpdatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            out[sid] = ClaudeSessionState(status: status,
                                          waitingFor: obj["waitingFor"] as? String,
                                          statusUpdatedAt: updated)
        }
        return out
    }

    private func accumulateClaudeLine(_ line: String) {        guard let obj = parseJSON(line),
              obj["type"] as? String == "assistant",
              let ts = obj["timestamp"] as? String, ts >= todayStartISO,
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any]
        else { return }
        // Dedupe: continued/forked sessions copy earlier entries into new files
        if let id = msg["id"] as? String {
            guard claudeSeenIDs.insert(id).inserted else { return }
        }
        claudeInput += uint(usage["input_tokens"])
            + uint(usage["cache_creation_input_tokens"])
            + uint(usage["cache_read_input_tokens"])
        claudeOutput += uint(usage["output_tokens"])
    }

    /// From the tail of the most recent session: project, the last thing Claude SAID
    /// (its latest text block, markdown preserved — never tool calls), the flash state,
    /// and TodoWrite plan progress.
    /// Attention heuristic: the LAST significant main-chain entry decides —
    ///   assistant text-only  → turn ended, Claude is waiting for the user → true
    ///   assistant tool_use   → still working → false
    ///   user-typed message   → user already responded → false
    private func claudeActivity(path: String)
        -> (project: String?, activity: String?, attention: Bool,
            step: (current: Int, total: Int, text: String)?, model: String?) {
        var project: String?
        var model: String?
        var message: String?
        var attention = false
        var stateDetermined = false
        var pendingSubagents = false  // sub-agents still running as the newest activity
        var crossedUserTurn = false   // scanned past a real user message → older todos are stale
        var step: (Int, Int, String)?
        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            let isAssistant = line.contains("\"type\":\"assistant\"")
            let isUser = line.contains("\"type\":\"user\"")
            guard isAssistant || isUser, let obj = parseJSON(line) else { continue }
            // Subagent side chains don't drive the message/step display, but if one is
            // among the NEWEST activity (seen before any main-chain decision), the main
            // agent is still waiting on its sub-agents → working, not waiting on you.
            if obj["isSidechain"] as? Bool == true {
                if !stateDetermined { pendingSubagents = true }
                continue
            }

            if isUser, obj["type"] as? String == "user" {
                // A real user message (not a tool_result) is a turn boundary: a
                // TodoWrite older than it belongs to a finished request → stale.
                if isRealUserMessage(obj) { crossedUserTurn = true }
                if !stateDetermined {
                    attention = false
                    stateDetermined = true
                }
                continue
            }

            guard obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any]
            else { continue }
            if project == nil, let cwd = obj["cwd"] as? String {
                project = (cwd as NSString).lastPathComponent
            }
            // Scanning newest-first, so the first hit is the current model and
            // reflects a mid-session /model switch. Free — this line is already parsed.
            if model == nil, let m = msg["model"] as? String { model = m }
            var sawToolUse = false
            if let content = msg["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "tool_use":
                        sawToolUse = true
                        // TodoWrite from the CURRENT turn only (before any user boundary)
                        if step == nil, !crossedUserTurn,
                           block["name"] as? String == "TodoWrite",
                           let input = block["input"] as? [String: Any],
                           let todos = input["todos"] as? [[String: Any]] {
                            step = parseClaudeTodos(todos)
                        }
                    case "text":
                        // The message Claude spoke — markdown preserved for table layout
                        if message == nil {
                            let t = cleanMultiline(block["text"] as? String ?? "")
                            if !t.isEmpty { message = t }
                        }
                    default:
                        break
                    }
                }
            }
            if !stateDetermined {
                // text-only final message → your turn, UNLESS sub-agents are still
                // running (their sidechain activity is newer than this message).
                attention = !sawToolUse && !pendingSubagents
                stateDetermined = true
            }
            // Stop once the message + state are known and the step is either found
            // or can no longer appear (we've passed the current user turn)
            if message != nil && stateDetermined && (step != nil || crossedUserTurn) { break }
        }
        return (project, message, attention, step, model)
    }

    /// A real user request, as opposed to a tool_result the harness feeds back mid-turn.
    private func isRealUserMessage(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any] else { return false }
        if msg["content"] is String { return true }
        if let content = msg["content"] as? [[String: Any]] {
            return content.contains { ($0["type"] as? String) != "tool_result" }
        }
        return false
    }

    /// Claude TodoWrite todos → (currentStep, totalSteps, text). Same rule as Codex.
    private func parseClaudeTodos(_ todos: [[String: Any]]) -> (Int, Int, String)? {
        let items = todos.compactMap { t -> (text: String, status: String)? in
            guard let content = t["content"] as? String,
                  let status = t["status"] as? String else { return nil }
            let active = t["activeForm"] as? String
            return (status == "in_progress" ? (active ?? content) : content, status)
        }
        guard !items.isEmpty else { return nil }
        let total = items.count
        if let i = items.firstIndex(where: { $0.status == "in_progress" }) {
            return (i + 1, total, clean(items[i].text))
        }
        if let i = items.firstIndex(where: { $0.status != "completed" }) {
            return (i + 1, total, clean(items[i].text))
        }
        return (total, total, clean(items.last?.text ?? ""))
    }

    // MARK: - Codex

    private func collectCodex()
        -> (entries: [AgentEntry], tokens: UInt64, available: Bool,
            quotaUsed: Double?, quotaResets: Date?) {
        let root = home + "/.codex/sessions"
        guard fm.fileExists(atPath: root) else { return ([], 0, false, nil, nil) }

        // Session dirs are keyed by START date; scan a rolling window of recent days.
        let todayStart = Calendar.current.startOfDay(for: Date())
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        var dirs: [String] = []
        for back in 0..<14 {
            if let d = Calendar.current.date(byAdding: .day, value: -back, to: now) {
                dirs.append(root + "/" + df.string(from: d))
            }
        }

        var recent: [(path: String, mtime: Date)] = []
        for dir in dirs {
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = dir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date
                else { continue }
                // Token counting is scoped to today only
                if mtime >= todayStart {
                    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                    consumeNewLines(path: path, size: size, offsets: &codexOffsets,
                                    prefilter: "\"token_count\"") { line in
                        self.accumulateCodexLine(line)
                    }
                }
                if now.timeIntervalSince(mtime) <= liveWindow { recent.append((path, mtime)) }
            }
        }

        // Quota is account-global (may live in a different file than the active one).
        updateCodexQuota()

        // Newest-first; dedup by project (one card per project). Cap the number of
        // files we fully parse so a day of short sessions stays cheap.
        recent.sort { $0.mtime > $1.mtime }
        var seenProjects = Set<String>()
        var entries: [AgentEntry] = []
        for f in recent.prefix(maxEntriesPerKind * 3) {
            if entries.count >= maxEntriesPerKind { break }
            let (proj, message, rawWaiting) = codexActivity(path: f.path)
            let name = proj ?? (f.path as NSString).lastPathComponent
            if let p = proj, !seenProjects.insert(p).inserted { continue }
            let ago = max(0, Int(now.timeIntervalSince(f.mtime)))
            let step = codexPlan(path: f.path)
            let id = "codex:" + name
            let (waiting, flash) = attentionState(id: id, rawWaiting: rawWaiting, ago: ago)
            let working = !rawWaiting && ago < 90
            entries.append(AgentEntry(
                kind: .codex, id: id, project: proj, message: message,
                secondsSinceActive: ago, waiting: waiting, flash: flash, isWorking: working,
                stepCurrent: step?.current, stepTotal: step?.total, stepText: step?.text,
                model: codexModel(path: f.path)))
        }
        let q = codexQuotaCache
        return (entries, codexInput + codexOutput, true, q?.used, q?.resets)
    }

    /// Last known model per session file. `codexActivity` stops as soon as it has the
    /// message and state, which is usually well short of the newest `turn_context`, so
    /// the model needs its own targeted lookup — and the cache keeps the label stable
    /// on a tick where that lookup comes up empty.
    private var codexModelCache: [String: String] = [:]

    /// Active model, from the newest `turn_context` record (written once per turn).
    /// Its discriminator lives at the top level, not inside `payload`.
    private func codexModel(path: String) -> String? {
        if let line = lastLine(path: path, containing: "\"turn_context\"",
                               maxScan: 512 * 1024),
           let obj = parseJSON(line),
           obj["type"] as? String == "turn_context",
           let payload = obj["payload"] as? [String: Any],
           let m = payload["model"] as? String {
            codexModelCache[path] = m
        }
        return codexModelCache[path]
    }

    /// Active `update_plan` → (currentStep, totalSteps, stepText), or nil.
    /// A plan only counts as CURRENT if it's newer than the last `task_complete`:
    /// once the planned task finished and a new turn began without its own plan, the
    /// stale plan must not linger on screen. Scanning newest-first, whichever comes
    /// first — a plan update or a task completion — decides.
    private func codexPlan(path: String) -> (current: Int, total: Int, text: String)? {
        for line in tailLines(path: path, maxBytes: 512 * 1024).reversed() {
            let maybePlan = line.contains("update_plan")
            let maybeDone = line.contains("\"task_complete\"")
            guard maybePlan || maybeDone,
                  let obj = parseJSON(line),
                  let payload = obj["payload"] as? [String: Any]
            else { continue }

            // Newest turn already ended → no active plan
            if payload["type"] as? String == "task_complete" { return nil }

            // Two plan encodings across Codex versions:
            //  · custom_tool_call → `input`: JS source `tools.update_plan({plan:[…]})`
            //  · function_call    → `arguments`: JSON `{"plan":[…]}` (name == update_plan)
            if let input = payload["input"] as? String, input.contains("update_plan") {
                return parseCodexPlan(input)
            }
            if payload["name"] as? String == "update_plan",
               let args = payload["arguments"] as? String {
                return parseCodexPlan(args)
            }
        }
        return nil
    }

    private func parseCodexPlan(_ input: String) -> (Int, Int, String)? {
        // Ordered [(step, status)] from the plan array. Key quoting is inconsistent
        // across Codex versions — `step:"…"` unquoted, `"status":"…"` quoted, or
        // vice-versa — so match each `{step, status}` pair with tolerant quoting.
        let pattern = "\"?step\"?\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*"
            + "\"?status\"?\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = input as NSString
        let matches = re.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        let steps: [(text: String, status: String)] = matches.map {
            (unescapeJS(ns.substring(with: $0.range(at: 1))),
             ns.substring(with: $0.range(at: 2)))
        }
        let total = steps.count
        // Current = the in_progress step; else the first not-yet-done step; else all done
        if let i = steps.firstIndex(where: { $0.status == "in_progress" }) {
            return (i + 1, total, clean(steps[i].text))
        }
        if let i = steps.firstIndex(where: { $0.status != "completed" }) {
            return (i + 1, total, clean(steps[i].text))
        }
        return (total, total, clean(steps.last?.text ?? ""))
    }

    private func unescapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Refresh the cached quota from the NEWEST full rate-limit reading across recent
    /// session files (by timestamp). Codex emits the populated `primary` block only
    /// occasionally and the freshest one can be in a different file than the active
    /// session, so a single-file tail scan is unreliable. Throttled since it changes
    /// slowly; lines without a populated primary don't contain "used_percent" and are
    /// rejected cheaply, so the reversed scan stops at each file's newest reading fast.
    private func updateCodexQuota() {
        if let last = codexQuotaLastScan, Date().timeIntervalSince(last) < 20,
           codexQuotaCache != nil { return }
        codexQuotaLastScan = Date()

        let root = home + "/.codex/sessions"
        let df = DateFormatter(); df.dateFormat = "yyyy/MM/dd"
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        for back in 0..<4 {
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: Date())
            else { continue }
            let dir = root + "/" + df.string(from: day)
            for file in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                guard file.hasSuffix(".jsonl") else { continue }
                let path = dir + "/" + file
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff
                else { continue }
                // Newest populated reading in this file; update global if newer.
                // The rate-limit record sits within a few hundred KB of EOF, so scan
                // backwards for it rather than materialising the whole transcript —
                // these files reach ~9 MB and this ran every 20s over four days of
                // them.
                if let line = lastLine(path: path, containing: "used_percent"),
                   let obj = parseJSON(line),
                   let ts = obj["timestamp"] as? String,
                   let payload = obj["payload"] as? [String: Any],
                   let limits = payload["rate_limits"] as? [String: Any],
                   let primary = limits["primary"] as? [String: Any],
                   let used = (primary["used_percent"] as? NSNumber)?.doubleValue,
                   ts > codexQuotaTS {
                    codexQuotaTS = ts
                    var resets: Date?
                    if let r = (primary["resets_at"] as? NSNumber)?.doubleValue {
                        resets = Date(timeIntervalSince1970: r)
                    }
                    codexQuotaCache = (used, resets)
                }
            }
        }
    }

    /// Sum per-request deltas (`last_token_usage`), NOT `total_token_usage`:
    /// forked/subagent sessions inherit the parent's cumulative totals, which
    /// would massively overcount today.
    private func accumulateCodexLine(_ line: String) {
        guard let obj = parseJSON(line),
              let ts = obj["timestamp"] as? String, ts >= todayStartISO,
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return }
        // input_tokens already includes cached_input_tokens; cache writes are separate
        codexInput += uint(last["input_tokens"]) + uint(last["cache_write_input_tokens"])
        codexOutput += uint(last["output_tokens"])
    }

    /// (project, activity, needsAttention). Attention: the last significant event is
    /// task_complete (done) or an approval request (waiting for the user); a newer
    /// user message or a running tool call cancels it.
    private func codexActivity(path: String) -> (String?, String?, Bool) {
        // cwd lives in the head session_meta line, but that line embeds the full
        // system prompt (tens of KB) so a JSON parse would need the whole line.
        // cwd appears before the prompt, so pull it by substring from a head chunk.
        var project: String?
        if let head = tailLines(path: path, maxBytes: 0, headBytes: 16 * 1024).first,
           let cwd = extractJSONString(head, key: "cwd") {
            project = (cwd as NSString).lastPathComponent
        }

        // Working signals (Codex is mid-turn) vs waiting signals (turn ended /
        // needs the user). Newest-first, the first of either decides — so an active
        // command after a prior task_complete correctly reads as "working", not "wait".
        // token_count is ignored for state: it fires after every response, including
        // the final one, and would mask the real last event.
        let workingTypes: Set<String> = [
            "custom_tool_call", "custom_tool_call_output", "function_call",
            "function_call_output", "agent_reasoning", "reasoning",
            "task_started", "user_message",
        ]
        // Activity = the last thing Codex SAID (agent_message / task_complete text),
        // never the shell commands it ran. If no message exists in the window (a long
        // command-only stretch), fall back to the latest reasoning title.
        var message: String?
        var reasoning: String?
        var attention = false
        var stateDetermined = false
        for line in tailLines(path: path, maxBytes: 256 * 1024).reversed() {
            guard let obj = parseJSON(line),
                  let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            if !stateDetermined {
                if type == "task_complete" || type.contains("approval_request") {
                    attention = true; stateDetermined = true
                } else if workingTypes.contains(type)
                            || (type == "message" && payload["role"] as? String == "user") {
                    attention = false; stateDetermined = true
                }
            }

            if message == nil {
                switch type {
                case "agent_message":
                    // Keep newlines/markdown so the renderer can lay out tables & lists
                    message = cleanMultiline(payload["message"] as? String ?? "")
                case "task_complete":
                    message = cleanMultiline(payload["last_agent_message"] as? String ?? "")
                default:
                    break
                }
                if message?.isEmpty == true { message = nil }
            }
            if reasoning == nil, type == "agent_reasoning" {
                let t = (payload["text"] as? String ?? "")
                    .replacingOccurrences(of: "**", with: "")
                let c = clean(t)
                if !c.isEmpty { reasoning = c }
            }

            if message != nil && stateDetermined { break }
        }
        let activity = message ?? reasoning
        return (project, activity, attention)
    }

    /// Pull a JSON string value by key via substring scan — cheaper than parsing,
    /// and works on a truncated head chunk or embedded JS source.
    private func extractJSONString(_ s: String, key: String) -> String? {
        guard let r = s.range(of: "\"\(key)\":\"") else { return nil }
        let out = readJSString(s, from: r.upperBound)
        return out.isEmpty ? nil : out
    }

    /// Read a double-quoted string value starting just after the opening quote.
    /// Resolves \" \\ \n \t and stops at the closing unescaped quote.
    private func readJSString(_ s: String, from start: String.Index) -> String {
        var out = ""
        var i = start
        var escaped = false
        while i < s.endIndex {
            let c = s[i]
            if escaped {
                switch c {
                case "n", "t": out.append(" ")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                break
            } else {
                out.append(c)
            }
            i = s.index(after: i)
        }
        return out
    }

    // MARK: - File Helpers

    /// Feed complete NEW lines (since the stored offset) matching `prefilter`
    /// to `handler`, then advance the offset past the last complete line.
    private func consumeNewLines(path: String, size: UInt64,
                                 offsets: inout [String: UInt64],
                                 prefilter: String,
                                 handler: (String) -> Void) {
        var offset = offsets[path] ?? 0
        if size < offset { offset = 0 }  // truncated/rotated — dedupe absorbs re-reads
        guard size > offset, let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return }

        // Only consume up to the last newline — the writer may be mid-line
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offsets[path] = offset + UInt64(lastNL) + 1

        let complete = data[data.startIndex...lastNL]
        for chunk in complete.split(separator: UInt8(ascii: "\n")) {
            guard let line = String(data: Data(chunk), encoding: .utf8),
                  line.contains(prefilter)
            else { continue }
            handler(line)
        }
    }

    /// Read complete lines from the tail (or head, if headBytes > 0) of a file.
    private func tailLines(path: String, maxBytes: Int, headBytes: Int = 0) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }

        let data: Data
        if headBytes > 0 {
            data = (try? fh.read(upToCount: headBytes)) ?? Data()
        } else {
            let size = (try? fh.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? fh.seek(toOffset: start)
            data = (try? fh.readToEnd()) ?? Data()
        }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }

    /// Newest line containing `needle`, found by scanning backwards from EOF in
    /// `chunk`-sized windows. For a needle that reliably sits near the end of a
    /// multi-megabyte transcript this beats reading the whole tail: it stops at the
    /// first window that has a hit instead of materialising every line first.
    private func lastLine(path: String, containing needle: String,
                          chunk: Int = 256 * 1024,
                          maxScan: Int = 4 * 1024 * 1024) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        var end = size                      // exclusive upper bound of the window
        var scanned = 0
        // Carry the partial line at the window's start into the next (earlier)
        // window, so a line straddling a chunk boundary is never split.
        var carry = Data()

        while end > 0 && scanned < maxScan {
            let start = end > UInt64(chunk) ? end - UInt64(chunk) : 0
            try? fh.seek(toOffset: start)
            guard var data = try? fh.read(upToCount: Int(end - start)), !data.isEmpty
            else { return nil }
            data.append(carry)
            scanned += Int(end - start)

            // Everything before the first newline is a partial line — defer it.
            let bodyStart: Data.Index
            if start == 0 {
                bodyStart = data.startIndex
                carry = Data()
            } else if let firstNL = data.firstIndex(of: UInt8(ascii: "\n")) {
                bodyStart = data.index(after: firstNL)
                carry = data[data.startIndex..<firstNL]
            } else {
                carry = data          // no newline at all — keep growing the carry
                end = start
                continue
            }

            for chunkLine in data[bodyStart...].split(separator: UInt8(ascii: "\n")).reversed() {
                guard let line = String(data: Data(chunkLine), encoding: .utf8),
                      line.contains(needle)
                else { continue }
                return line
            }
            end = start
        }
        return nil
    }

    private func parseJSON(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func uint(_ v: Any?) -> UInt64 {
        (v as? NSNumber)?.uint64Value ?? 0
    }

    /// Single line, capped length — display truncation happens at render time
    private func clean(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
    }

    /// Multi-line preserving — keeps newlines/markdown structure (tables, lists)
    /// for the renderer to lay out. Caps length so a huge message can't dominate.
    private func cleanMultiline(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 800 ? String(trimmed.prefix(800)) + "…" : trimmed
    }
}
