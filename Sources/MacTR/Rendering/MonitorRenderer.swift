// MonitorRenderer.swift — the 1920x480 dashboard
//
// Layout: OPERATOR | AI AGENTS (triple width) | STATUS
// The AGENTS panel is the centre of the thing: one card per live Claude/Codex
// session, with the focused one expanded on the right. OPERATOR is the Skadi
// chibi reacting to that state; STATUS carries the clock, network and the
// CPU/memory/temp dials.

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()
    private let agentCollector = AgentUsageCollector()
    // "Dynamic Island" push channel — agents/scripts drop a message onto the LCD.
    private let pinService = PinService()

    // Background metrics collection — decoupled from frame loop for consistent refresh
    private let metricsQueue = DispatchQueue(label: "com.thermalvision.metrics")
    private var metricsRunning = false
    private let lock = NSLock()

    // Cached snapshots (written by metricsQueue, read by render thread)
    private var _cpu: CPUSnapshot?
    private var _mem: MemorySnapshot?
    private var _temp: TemperatureSnapshot?
    private var _agents: AgentsSnapshot?
    private var _sys: SystemSnapshot?
    private var _net: NetworkSnapshot?
    // Recent network throughput for the STATUS-panel sparkline (mutated only under renderMutex).
    private var netHistory: [(rx: Double, tx: Double)] = []
    // Event-reactive operator: edge-detect agent state to fire a brief reaction clip.
    private var prevWorkingCount = 0
    private var prevWaitingIDs: Set<String> = []
    private var reactionClip: [CGImage]?
    private var reactionUntil: TimeInterval = 0
    private var operatorPrimed = false  // skip reactions on the very first frame
    private var _audioPlaying = false   // system is outputting sound → dance + spectrum
    private var _screensaver = false    // screen locked → show the ambient saver
    private var _saverRoomMode = 0      // 0 = auto-rotate, else 1-based room index
    // Drifting stars for the screensaver (generated once).
    private lazy var stars: [(x: CGFloat, y: CGFloat, r: CGFloat, ph: Double)] = (0..<64).map { _ in
        (CGFloat.random(in: 0...CGFloat(Layout.width)),
         CGFloat.random(in: 0...CGFloat(Layout.height)),
         CGFloat.random(in: 0.6...1.9),
         Double.random(in: 0...6.283))
    }

    /// Toggle the screen-lock ambient screensaver (called from the lock notifications).
    func setScreensaver(_ on: Bool) {
        lock.lock(); _screensaver = on; lock.unlock()
    }

    /// Whether the saver is currently showing — the frame loop skips the brightness
    /// boost for it (wallpapers are already exposed; boosting blows them out).
    func isScreensaverActive() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _screensaver
    }

    /// Screensaver room: 0 = auto-rotate, else 1-based room index.
    func setSaverRoomMode(_ m: Int) {
        lock.lock(); _saverRoomMode = m; lock.unlock()
    }

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

    // Test mode (--test-flash): force both columns into the flashing state until
    // this deadline, to preview the alert visuals without waiting for a real event
    private var testFlashUntil: Date?

    func enableTestFlash(seconds: TimeInterval) {
        testFlashUntil = Date().addingTimeInterval(seconds)
        log("[Metrics] Test flash enabled for \(Int(seconds))s")
    }

    /// Force every entry into the attention (flash) state — for --test-flash preview.
    private func allFlashing(_ s: AgentsSnapshot) -> AgentsSnapshot {
        let flashed = s.entries.map { e in
            AgentEntry(kind: e.kind, id: e.id, project: e.project, message: e.message,
                       secondsSinceActive: e.secondsSinceActive, waiting: true, flash: true,
                       isWorking: false, stepCurrent: e.stepCurrent,
                       stepTotal: e.stepTotal, stepText: e.stepText,
                       waitingFor: e.waitingFor, model: e.model)
        }
        return AgentsSnapshot(entries: flashed,
                              claudeAvailable: s.claudeAvailable, codexAvailable: s.codexAvailable,
                              claudeTodayTokens: s.claudeTodayTokens,
                              codexTodayTokens: s.codexTodayTokens,
                              codexQuotaUsedPercent: s.codexQuotaUsedPercent,
                              codexQuotaResetsAt: s.codexQuotaResetsAt)
    }

    /// Start background metrics collection. Call before first render().
    /// Primes all metrics synchronously, then starts async collection loop.
    /// Safe to call multiple times — returns immediately if already running.
    func startMetrics() {
        lock.lock()
        guard !metricsRunning else { lock.unlock(); return }
        metricsRunning = true
        lock.unlock()
        log("[Metrics] Starting collection...")
        // First pass: prime CPU ticks (deltas will be zero)
        let cpu0 = collector.collectCPU()
        let mem = collector.collectMemory()
        let temp = collector.collectTemperature()
        let agents = agentCollector.collect()
        let sys = collector.collectSystem()
        let net = collector.collectNetwork()
        lock.lock()
        _cpu = cpu0; _mem = mem
        _temp = temp; _agents = agents; _sys = sys; _net = net
        lock.unlock()

        // Second pass: get real CPU deltas
        Thread.sleep(forTimeInterval: 0.3)
        let cpu1 = collector.collectCPU()
        lock.lock()
        _cpu = cpu1
        lock.unlock()

        // Start async collection loop
        metricsQueue.async { [weak self] in self?.metricsLoop() }
    }

    func stopMetrics() {
        log("[Metrics] Stopping collection")
        metricsRunning = false
    }

    /// True when a column has a live animation (breathing while working, or the
    /// done/waiting blink) — the frame loop uses this to raise the LCD frame rate
    /// only while something is actually moving, and idle low otherwise.
    func wantsHighFrameRate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // A pin is sliding in/out or counting down → animate smoothly.
        if pinService.current() != nil { return true }
        guard let a = _agents else { return false }
        return a.anyLive
    }

    private func metricsLoop() {
        log("[Metrics] Loop started on metricsQueue")
        var slowTick = 0
        while metricsRunning {
            // This loop is a single never-returning GCD work item, so its implicit
            // autorelease pool is never drained. Everything autoreleased below —
            // JSONSerialization's NSDictionary/CFString graphs, attributesOfItem
            // dictionaries, FileHandle's NSData buffers — would otherwise accumulate
            // for the life of this always-on app. The frame loop already drains per
            // frame for the same reason. Sleep stays outside so the pool is empty
            // while we idle.
            autoreleasepool {
                // Fast metrics every tick
                let cpu = collector.collectCPU()
                let mem = collector.collectMemory()
                let net = collector.collectNetwork()
                let audio = AudioService.isPlaying()
                pinService.refresh()
                lock.lock()
                _cpu = cpu; _mem = mem; _net = net; _audioPlaying = audio
                lock.unlock()

                // Slow metrics every 4th tick (~2s)
                slowTick += 1
                if slowTick >= 4 {
                    let temp = collector.collectTemperature()
                    let agents = agentCollector.collect()
                    let sys = collector.collectSystem()
                    lock.lock()
                    _temp = temp; _agents = agents; _sys = sys
                    lock.unlock()
                    slowTick = 0
                }
            }

            Thread.sleep(forTimeInterval: 0.5)
        }
        log("[Metrics] Loop exited (metricsRunning=false)")
    }

    // Demo mode: drive the display with polished fake data (for screenshots / photos
    // and open-source showcase). Set before render(); the frame loop keeps its normal
    // memory-safe path (reusable context + autoreleasepool) and animations stay live.
    var demoMode = false

    /// Deterministic showcase data. CPU cores gently wave over time so the demo looks
    /// alive on the LCD; everything else is fixed so it reads clearly in a photo.
    private func demoData() -> (CPUSnapshot, MemorySnapshot, TemperatureSnapshot,
                                SystemSnapshot, AgentsSnapshot) {
        let tt = Date().timeIntervalSince1970
        let cores: [Double] = (0..<10).map { i in
            let wave: Double = sin(tt * 1.3 + Double(i) * 0.9)
            return 25.0 + 55.0 * (0.5 + 0.5 * wave)
        }
        let total: Double = cores.reduce(0.0, +) / 10.0
        let cpu = CPUSnapshot(perCore: cores, total: total,
                              loadAvg: (3.5, 4.2, 3.8), pCoreCount: 8)
        let gb: UInt64 = 1024 * 1024 * 1024
        let mem = MemorySnapshot(
            total: 32 * gb, active: 9 * gb, wired: 3 * gb,
            compressed: 2 * gb, available: 18 * gb,
            swapUsed: 512 * 1024 * 1024, swapTotal: 4 * gb,
            swapInPerSec: 0, swapOutPerSec: 0, swapAvailable: true, pressure: 1)
        let temp = TemperatureSnapshot(cpuTemp: 52, gpuTemp: 45, thermalState: 0)
        let sys = SystemSnapshot(uptimeSeconds: 27 * 3600 + 3 * 60, processCount: 612)
        var agents = AgentsSnapshot(
            entries: [
                AgentEntry(kind: .codex, id: "codex:web-service", project: "web-service",
                           message: """
                           预发环境冒烟测试已通过，是否部署到生产？涉及四个服务：

                           | 服务 | 提交 | 文件 |
                           |---|---|---:|
                           | `api-gateway` | `a4872c56` | 24 |
                           | `auth-service` | `4d6934de` | 10 |
                           | `web-client` | `9b0e17aa` | 32 |
                           | `job-worker` | `ac02bea6` | 88 |
                           """,
                           secondsSinceActive: 4, waiting: true, flash: true, isWorking: false,
                           stepCurrent: 4, stepTotal: 6, stepText: "部署到预发环境并跑冒烟测试"),
                AgentEntry(kind: .claude, id: "claude:knight-server", project: "knight-server",
                           message: "已完成回流检测埋点，改动集中在 ReflowService 与登录处理。",
                           secondsSinceActive: 3, waiting: false, flash: false, isWorking: true,
                           stepCurrent: 3, stepTotal: 4, stepText: "渲染 Claude 消息表格"),
                AgentEntry(kind: .claude, id: "claude:MacTR", project: "MacTR",
                           message: "正在把 AI Agents 面板重构成控制塔布局。",
                           secondsSinceActive: 11, waiting: false, flash: false, isWorking: true,
                           stepCurrent: 2, stepTotal: 2, stepText: "列表 + 自动聚焦详情"),
                AgentEntry(kind: .claude, id: "claude:game_server", project: "game_server",
                           message: "活动配置已更新完毕。", secondsSinceActive: 12 * 60,
                           waiting: false, flash: false, isWorking: false,
                           stepCurrent: nil, stepTotal: nil, stepText: nil),
                AgentEntry(kind: .codex, id: "codex:scripts", project: "scripts",
                           message: "批处理脚本执行完成。", secondsSinceActive: 62 * 60,
                           waiting: false, flash: false, isWorking: false,
                           stepCurrent: nil, stepTotal: nil, stepText: nil),
            ],
            claudeAvailable: true, codexAvailable: true,
            claudeTodayTokens: 48_800_000, codexTodayTokens: 60_500_000,
            codexQuotaUsedPercent: 57,
            codexQuotaResetsAt: Date().addingTimeInterval(3600 * 24 * 6))
        agents.recentEvents = [
            AgentEvent(icon: "⏸", verb: "等你输入", project: "web-service", kind: .codex, atSecs: 0),
            AgentEvent(icon: "✓", verb: "完成一轮", project: "knight-server", kind: .claude, atSecs: 0),
            AgentEvent(icon: "▶", verb: "开始", project: "mac-tr", kind: .claude, atSecs: 0),
        ]
        return (cpu, mem, temp, sys, agents)
    }

    /// Render one demo frame with the showcase data (for --snapshot).
    func renderSimulated(coreCount: Int) -> CGImage? {
        let (cpu, mem, temp, sys, agents) = demoData()
        let w = Layout.width, h = Layout.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        Draw.gradientBackground(ctx)
        if CommandLine.arguments.contains("--saver") {
            renderScreensaver(ctx)
            return ctx.makeImage()
        }
        renderOperator(ctx, agents: agents, audioPlaying: true)
        renderAgents(ctx, agents: agents)
        renderInfoPanel(ctx, cpu: cpu, mem: mem, temp: temp, sys: sys,
                        net: NetworkSnapshot(rxBytesPerSec: 1_450_000, txBytesPerSec: 240_000))
        return ctx.makeImage()
    }

    // Serializes render() callers — the USB frame loop and the on-Mac preview
    // window can both render around a connect/disconnect transition, and they
    // share reusableCtx + sparkline history
    private let renderMutex = NSLock()

    func render() -> CGImage? {
        renderMutex.lock()
        defer { renderMutex.unlock() }

        let cpu: CPUSnapshot, mem: MemorySnapshot, temp: TemperatureSnapshot
        let sys: SystemSnapshot?
        let net: NetworkSnapshot?
        let audioPlaying: Bool
        var agents: AgentsSnapshot
        if demoMode {
            (cpu, mem, temp, sys, agents) = demoData()
            net = NetworkSnapshot(rxBytesPerSec: 1_450_000, txBytesPerSec: 240_000)
            audioPlaying = true
        } else {
            // Read cached metrics (never blocks — uses latest available values)
            lock.lock()
            guard let c = _cpu, let m = _mem, let tp = _temp, let a = _agents else {
                lock.unlock(); return nil
            }
            cpu = c; mem = m; temp = tp; agents = a; sys = _sys; net = _net
            audioPlaying = _audioPlaying
            lock.unlock()
        }

        if let until = testFlashUntil, Date() < until {
            agents = allFlashing(agents)
        }

        // Reuse CGContext to prevent CG raster data memory growth
        let w = Layout.width
        let h = Layout.height
        if reusableCtx == nil {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            reusableCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = reusableCtx else { return nil }

        // Reset transform and clear for new frame
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        Draw.gradientBackground(ctx)

        lock.lock(); let saver = _screensaver; lock.unlock()
        if saver {
            renderScreensaver(ctx)
        } else {
            renderOperator(ctx, agents: agents, audioPlaying: audioPlaying)
            renderAgents(ctx, agents: agents)
            renderInfoPanel(ctx, cpu: cpu, mem: mem, temp: temp, sys: sys, net: net)
        }

        // Dynamic-Island push overlay — drawn last so it floats over anything.
        if let pin = pinService.current() {
            renderPinIsland(ctx, pin: pin)
        }

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    // MARK: - Info Panel (right slot)

    /// Right-panel replacement: big clock + Gregorian date/weekday + lunar date (all
    /// local), live network up/down, and a compact system readout that re-homes the
    /// CPU/temp metrics displaced when Skadi took the CPU slot.
    private func renderInfoPanel(_ ctx: CGContext, cpu: CPUSnapshot, mem: MemorySnapshot,
                                 temp: TemperatureSnapshot, sys: SystemSnapshot?,
                                 net: NetworkSnapshot?) {
        let x = Layout.panelX(4)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight
        let accent = Color.cyan
        let cx = x + pw / 2
        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: accent)
        panelTitle(ctx, "STATUS", x: x + 20, y: py + 14,
                   font: Fonts.system(20, weight: .bold), color: accent)

        // ── Zone 1: time hero — HH:MM heavy, :SS smaller & accented ──
        let df = DateFormatter()
        df.dateFormat = "HH:mm"; let hhmm = df.string(from: Date())
        df.dateFormat = "ss";    let ss = df.string(from: Date())
        let hhmmF = Fonts.system(76, weight: .medium)
        let ssF = Fonts.system(30, weight: .semibold)
        let hhmmW = (hhmm as NSString).size(withAttributes: [.font: hhmmF]).width
        let ssW = (ss as NSString).size(withAttributes: [.font: ssF]).width
        let gap: CGFloat = 10
        let startX = CGFloat(cx) - (hhmmW + gap + ssW) / 2
        let clockTop = py + 38
        Draw.text(ctx, hhmm, x: Int(startX), y: clockTop, font: hhmmF, color: Color.textW)
        Draw.text(ctx, ss, x: Int(startX + hhmmW + gap), y: clockTop + 36, font: ssF, color: accent)

        let zh = DateFormatter(); zh.locale = Locale(identifier: "zh_CN")
        zh.dateFormat = "EEEE  M月d日"
        Draw.centeredText(ctx, zh.string(from: Date()), cx: cx, y: py + 132,
                          font: Fonts.system(18, weight: .medium), color: Color.textS)
        Draw.centeredText(ctx, lunarString(Date()), cx: cx, y: py + 158,
                          font: Fonts.system(18), color: Color.orange)

        // centered accent hairline as a section motif
        ctx.setStrokeColor(accent.copy(alpha: 0.5) ?? accent)
        ctx.setLineWidth(2); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: CGFloat(cx) - 26, y: CGFloat(py + 190)))
        ctx.addLine(to: CGPoint(x: CGFloat(cx) + 26, y: CGFloat(py + 190)))
        ctx.strokePath()

        // ── Zone 2: network sparkline ──
        netHistory.append((net?.rxBytesPerSec ?? 0, net?.txBytesPerSec ?? 0))
        if netHistory.count > 80 { netHistory.removeFirst(netHistory.count - 80) }
        let plotX = x + 20, plotW = pw - 40
        Draw.text(ctx, "网络", x: plotX, y: py + 206, font: Fonts.system(16), color: Color.textL)
        let dStr = "↓ " + Draw.formatBytesPerSec(net?.rxBytesPerSec ?? 0)
        let uStr = "↑ " + Draw.formatBytesPerSec(net?.txBytesPerSec ?? 0)
        let vF = Fonts.system(16, weight: .semibold)
        let uW = (uStr as NSString).size(withAttributes: [.font: vF]).width
        let dW = (dStr as NSString).size(withAttributes: [.font: vF]).width
        Draw.text(ctx, uStr, x: Int(CGFloat(plotX + plotW) - uW), y: py + 206, font: vF, color: Color.cyan)
        Draw.text(ctx, dStr, x: Int(CGFloat(plotX + plotW) - uW - dW - 14), y: py + 206, font: vF, color: Color.green)
        let maxV = max(1024.0, netHistory.flatMap { [$0.rx, $0.tx] }.max() ?? 1)
        drawSparkline(ctx, values: netHistory.map { $0.rx }, x: plotX, y: py + 232, w: plotW, h: 60,
                      maxV: maxV, color: Color.green, fill: true)
        drawSparkline(ctx, values: netHistory.map { $0.tx }, x: plotX, y: py + 232, w: plotW, h: 60,
                      maxV: maxV, color: Color.cyan, fill: false)

        // ── Zone 3: system mini rings — CPU / mem / temp ──
        let ringY = py + 358
        let rr = 30
        func ring(_ i: Int, _ label: String, _ pct: Double, _ valStr: String, _ c: CGColor) {
            let rcx = x + pw * (2 * i + 1) / 6
            Draw.arcGauge(ctx, cx: rcx, cy: ringY, radius: rr, percent: pct,
                          color: c, colorDark: Color.border, thickness: 7)
            Draw.centeredText(ctx, valStr, cx: rcx, y: ringY - 13,
                              font: Fonts.system(21, weight: .bold), color: Color.textW)
            Draw.centeredText(ctx, label, cx: rcx, y: ringY + rr + 10,
                              font: Fonts.system(14), color: Color.textL)
        }
        ring(0, "CPU", cpu.total, String(format: "%.0f", cpu.total), level(cpu.total, 60, 85))
        ring(1, "内存", mem.percent, String(format: "%.0f", mem.percent), level(mem.percent, 70, 90))
        if let t = temp.cpuTemp {
            ring(2, "温度", min(100, t / 90 * 100), String(format: "%.0f°", t), level(t, 65, 82))
        } else {
            ring(2, "温度", 0, "—", Color.textL)
        }

        if let sys {
            let h = sys.uptimeSeconds / 3600
            let up = h >= 24 ? "开机 \(h / 24)d \(h % 24)h" : "开机 \(h)h \((sys.uptimeSeconds % 3600) / 60)m"
            Draw.centeredText(ctx, up, cx: cx, y: py + ph - 22, font: Fonts.system(14), color: Color.textD)
        }
    }

    /// Level → color: green below `warn`, orange below `hot`, red above.
    private func level(_ v: Double, _ warn: Double, _ hot: Double) -> CGColor {
        v >= hot ? Color.red : (v >= warn ? Color.orange : Color.green)
    }

    /// Line sparkline of `values` scaled to [0, maxV] within the rect; optional area fill.
    private func drawSparkline(_ ctx: CGContext, values: [Double], x: Int, y: Int, w: Int, h: Int,
                               maxV: Double, color: CGColor, fill: Bool) {
        guard values.count >= 2 else { return }
        let n = values.count
        func px(_ i: Int) -> CGFloat { CGFloat(x) + CGFloat(w) * CGFloat(i) / CGFloat(n - 1) }
        func py(_ v: Double) -> CGFloat { CGFloat(y + h) - CGFloat(min(v, maxV) / maxV) * CGFloat(h) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: px(0), y: py(values[0])))
        for i in 1..<n { path.addLine(to: CGPoint(x: px(i), y: py(values[i]))) }
        if fill, let area = path.mutableCopy() {
            area.addLine(to: CGPoint(x: px(n - 1), y: CGFloat(y + h)))
            area.addLine(to: CGPoint(x: px(0), y: CGFloat(y + h)))
            area.closeSubpath()
            ctx.setFillColor(color.copy(alpha: 0.16) ?? color)
            ctx.addPath(area); ctx.fillPath()
        }
        ctx.setStrokeColor(color); ctx.setLineWidth(2); ctx.setLineJoin(.round)
        ctx.addPath(path); ctx.strokePath()
    }

    /// Local lunar (Chinese) calendar: ganzhi year + zodiac + month/day. No network.
    private func lunarString(_ date: Date) -> String {
        let cal = Calendar(identifier: .chinese)
        let c = cal.dateComponents([.year, .month, .day, .isLeapMonth], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return "" }
        let stems = ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"]
        let branches = ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
        let zodiac = ["鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪"]
        let months = ["正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊"]
        let days = ["", "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
                    "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
                    "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十"]
        let gz = stems[(y - 1) % 10] + branches[(y - 1) % 12]
        let zod = zodiac[(y - 1) % 12]
        let leap = (c.isLeapMonth ?? false) ? "闰" : ""
        let mon = leap + months[(m - 1) % 12] + "月"
        let day = (d >= 1 && d < days.count) ? days[d] : "\(d)"
        return "\(gz)\(zod)年 \(mon)\(day)"
    }

    /// Draw a CGImage upright inside `rect` within the flipped (y-down) context.
    /// `flipX` mirrors it horizontally (for facing left/right).
    private func drawImageUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect,
                                 flipX: Bool = false) {
        ctx.saveGState()
        if flipX {
            ctx.translateBy(x: rect.maxX, y: rect.minY + rect.height)
            ctx.scaleBy(x: -1, y: -1)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - Operator Panel (Skadi build-chibi, occupies the left / former CPU slot)

    /// Animated Skadi chibi in the left panel. She walks (Move) while any agent is
    /// working, and idles (Relax) otherwise.
    private func renderOperator(_ ctx: CGContext, agents: AgentsSnapshot, audioPlaying: Bool) {
        let x = Layout.panelX(0)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight
        let busy = agents.anyLive
        let accent = Color.cyan

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: accent)
        let opFont = Fonts.system(24, weight: .bold)
        panelTitle(ctx, "SKADI", x: x + 20, y: py + 14, font: opFont, color: accent)
        // Unit number after the name — 01 is what Miku wears on her arm, so the theme
        // spends it as an operator designation rather than as background texture.
        if let badge = Theme.current.decor.unitBadge {
            let nameW = ("SKADI" as NSString).size(withAttributes: [.font: opFont]).width
            let glyphW = Theme.current.decor.headerGlyph == nil ? 0 : opFont.pointSize + 7
            let bs: CGFloat = 15
            Draw.glyph(ctx, badge,
                       in: CGRect(x: CGFloat(x + 20) + glyphW + nameW + 9,
                                  y: CGFloat(py + 14) + 8, width: bs, height: bs),
                       color: accent.copy(alpha: 0.5) ?? accent)
        }
        let status: String
        let statusColor: CGColor
        if busy { status = "作战中"; statusColor = Color.green }
        else if audioPlaying { status = "♪ 随乐"; statusColor = accent }
        else { status = "驻扎"; statusColor = Color.textL }
        let sF = Fonts.system(16, weight: .medium)
        let sW = (status as NSString).size(withAttributes: [.font: sF]).width
        Draw.text(ctx, status, x: Int(CGFloat(x + pw - 20) - sW), y: py + 20,
                  font: sF, color: statusColor)

        let now = Date().timeIntervalSince1970

        // Event edge-detection → a brief reaction clip that overrides the normal cycle:
        //   a newly-waiting agent  → Interact (she turns to call you)
        //   an agent just finished → Skill_3 (a victory flourish)
        let workingNow = agents.entries.filter { $0.isWorking }.count
        let waitingNow = Set(agents.entries.filter { $0.waiting }.map { $0.id })
        if operatorPrimed {
            if !waitingNow.subtracting(prevWaitingIDs).isEmpty {
                reactionClip = SkadiAsset.interact; reactionUntil = now + 4
            } else if workingNow < prevWorkingCount {
                reactionClip = SkadiAsset.skill3; reactionUntil = now + 4
            }
        }
        prevWorkingCount = workingNow
        prevWaitingIDs = waitingNow
        operatorPrimed = true

        // Priority: event reaction > combat (agents working) > dance (music) > idle.
        let fps = SkadiAsset.fps
        let frames: [CGImage]
        func pick(_ clips: [[CGImage]], _ period: Double, _ fallback: [CGImage]) -> [CGImage] {
            let f = clips[Int(now / period) % clips.count]
            return f.isEmpty ? fallback : f
        }
        if now < reactionUntil, let rc = reactionClip, !rc.isEmpty {
            frames = rc
        } else if busy {
            frames = pick([SkadiAsset.skill2, SkadiAsset.skill3], 7.0, SkadiAsset.skill2)
        } else if audioPlaying {
            frames = pick([SkadiAsset.move, SkadiAsset.interact, SkadiAsset.skill2], 4.0, SkadiAsset.move)
        } else {
            frames = pick([SkadiAsset.relax, SkadiAsset.relax, SkadiAsset.interact,
                           SkadiAsset.move, SkadiAsset.relax, SkadiAsset.sleep], 7.0, SkadiAsset.relax)
        }
        guard !frames.isEmpty else { return }
        let img = frames[Int(now * fps) % frames.count]

        // Foot-level spectrum while audio plays (drawn under the sprite).
        if audioPlaying {
            drawEqualizer(ctx, x: x + 14, baseY: py + ph - 12, w: pw - 28, t: now)
        }

        // Fit into the panel body, feet near the bottom.
        let bodyTop = py + 48
        let bodyH = ph - 48 - 12
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        var dh = CGFloat(bodyH)
        var dw = dh * aspect
        let maxW = CGFloat(pw - 28)
        if dw > maxW { dw = maxW; dh = dw / aspect }
        let dx = CGFloat(x) + (CGFloat(pw) - dw) / 2
        let dy = CGFloat(bodyTop) + (CGFloat(bodyH) - dh)
        drawImageUpright(ctx, img, in: CGRect(x: dx, y: dy, width: dw, height: dh))
    }

    /// Decorative foot-level spectrum — synthesized bars (no audio tap), shown while
    /// the system is playing sound. Heights are a small sum of sines per bar.
    private func drawEqualizer(_ ctx: CGContext, x: Int, baseY: Int, w: Int, t: Double) {
        let bars = 15
        let gapW = 3
        let bw = (w - gapW * (bars - 1)) / bars
        guard bw > 0 else { return }
        let maxH: CGFloat = 42
        for i in 0..<bars {
            let p = Double(i)
            let v = abs(sin(t * 6.0 + p * 0.7)) * 0.6 + abs(sin(t * 3.3 + p * 1.9)) * 0.4
            let h = max(3, CGFloat(v) * maxH)
            let bx = CGFloat(x + i * (bw + gapW))
            let rect = CGRect(x: bx, y: CGFloat(baseY) - h, width: CGFloat(bw), height: h)
            let peak = v > 0.66
            let c = (peak ? Color.cyan : Color.green).copy(alpha: 0.8) ?? Color.cyan
            let path = CGPath(roundedRect: rect, cornerWidth: CGFloat(bw) / 2,
                              cornerHeight: CGFloat(bw) / 2, transform: nil)
            ctx.setFillColor(c); ctx.addPath(path); ctx.fillPath()
        }
    }

    // MARK: - Screensaver (shown while the screen is locked)

    /// Full-canvas ambient saver: a high-quality wallpaper filling the screen
    /// (selected or auto-rotating), with a clock card overlaid.
    private func renderScreensaver(_ ctx: CGContext) {
        let fw = CGFloat(Layout.width), fh = CGFloat(Layout.height)
        let now = Date().timeIntervalSince1970

        lock.lock(); let mode = _saverRoomMode; lock.unlock()
        let count = RoomAsset.count
        var idx = 0
        if count > 0 {
            idx = mode > 0 ? min(mode - 1, count - 1) : Int(now / 45) % count
            let wp = RoomAsset.images[idx]
            // Aspect-fill the whole canvas (wallpapers are pre-cropped to 1920x480).
            ctx.interpolationQuality = .high
            let scale = max(fw / CGFloat(wp.width), fh / CGFloat(wp.height))
            let sw = CGFloat(wp.width) * scale, sh = CGFloat(wp.height) * scale
            drawImageUpright(ctx, wp, in: CGRect(x: (fw - sw) / 2, y: (fh - sh) / 2,
                                                 width: sw, height: sh))
        } else {
            drawStars(ctx, now)
        }

        // Clock card, overlaid top-right on a soft scrim so it reads over any wallpaper.
        let boxW: CGFloat = 540, boxX = fw - boxW - 36, boxY: CGFloat = 40
        let boxH = fh - 80
        let scrim = CGPath(roundedRect: CGRect(x: boxX, y: boxY, width: boxW, height: boxH),
                           cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.38))
        ctx.addPath(scrim); ctx.fillPath()
        let cxr = Int(boxX + boxW / 2)
        let df = DateFormatter(); df.dateFormat = "HH:mm"
        Draw.centeredText(ctx, df.string(from: Date()), cx: cxr, y: Int(fh * 0.16),
                          font: Fonts.system(120, weight: .thin), color: Color.textW)
        let zh = DateFormatter(); zh.locale = Locale(identifier: "zh_CN")
        zh.dateFormat = "EEEE  M月d日"
        Draw.centeredText(ctx, zh.string(from: Date()), cx: cxr, y: Int(fh * 0.60),
                          font: Fonts.system(28, weight: .medium), color: Color.textS)
        Draw.centeredText(ctx, lunarString(Date()), cx: cxr, y: Int(fh * 0.60) + 40,
                          font: Fonts.system(24), color: Color.orange)
    }

    private func drawStars(_ ctx: CGContext, _ now: Double) {
        for s in stars {
            let a = 0.22 + 0.35 * (0.5 + 0.5 * sin(now * 0.7 + s.ph))
            ctx.setFillColor(Color.textW.copy(alpha: CGFloat(a)) ?? Color.textW)
            ctx.fillEllipse(in: CGRect(x: s.x - s.r, y: s.y - s.r, width: s.r * 2, height: s.r * 2))
        }
    }

    // MARK: - Dynamic-Island push overlay

    /// Draw the active push message as an animated card over the current screen.
    /// Floating banner by default (centered near the top); `big` takes the whole
    /// screen with the dashboard dimmed behind. Supports an emoji icon, a projected
    /// image, and a markdown body (reusing the agent-message layout).
    private func renderPinIsland(_ ctx: CGContext, pin: PinMessage) {
        let now = Date()
        let t = now.timeIntervalSince(pin.createdAt)
        let remaining = pin.expiresAt.timeIntervalSince(now)
        let total = pin.expiresAt.timeIntervalSince(pin.createdAt)
        // Ease in then out → alpha 0…1…0 over the message lifetime.
        func easeOut(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
        let appear = easeOut(t / 0.35) * easeOut(remaining / 0.4)
        guard appear > 0.01 else { return }

        let fw = CGFloat(Layout.width), fh = CGFloat(Layout.height)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(appear))          // fades the whole island as one unit

        // Card geometry
        let cardX: CGFloat, cardY: CGFloat, cardW: CGFloat, cardH: CGFloat
        if pin.big {
            // Dim the dashboard behind, then a near-full-screen card.
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
            ctx.fill(CGRect(x: 0, y: 0, width: fw, height: fh))
            (cardX, cardY, cardW, cardH) = (48, 30, fw - 96, fh - 60)
        } else {
            cardW = 1180; cardH = 232
            cardX = (fw - cardW) / 2
            cardY = 36 - CGFloat(1 - appear) * 16   // slides down from the top edge
        }

        // Card: rounded fill + accent border + a thin accent header strip.
        let card = CGRect(x: cardX, y: cardY, width: cardW, height: cardH)
        let cardPath = CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil)
        ctx.setShadow(offset: .zero, blur: 26,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.setFillColor(CGColor(red: 22/255, green: 25/255, blue: 36/255, alpha: 0.98))
        ctx.addPath(cardPath); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(pin.accent.copy(alpha: 0.85) ?? pin.accent)
        ctx.setLineWidth(2); ctx.addPath(cardPath); ctx.strokePath()

        let pad: CGFloat = pin.big ? 40 : 26
        var contentX = cardX + pad
        let contentR = cardX + cardW - pad
        let midY = cardY + cardH / 2

        // ── Projected image: right side (big) or right thumbnail (float) ──
        var imageLeftEdge = contentR
        if let img = pin.image {
            let maxW: CGFloat = pin.big ? min(760, cardW * 0.44) : 300
            let boxH = cardH - 2 * pad
            let aspect = CGFloat(img.width) / CGFloat(img.height)
            var dh = boxH, dw = boxH * aspect
            if dw > maxW { dw = maxW; dh = dw / aspect }
            let ix = contentR - dw
            let iy = midY - dh / 2
            // rounded clip so the picture matches the card's corners
            ctx.saveGState()
            let ip = CGPath(roundedRect: CGRect(x: ix, y: iy, width: dw, height: dh),
                            cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.addPath(ip); ctx.clip()
            drawImageUpright(ctx, img, in: CGRect(x: ix, y: iy, width: dw, height: dh))
            ctx.restoreGState()
            imageLeftEdge = ix - 22
        }

        // ── Icon chip: left, vertically centered ──
        if let emoji = pin.iconEmoji {
            let sz: CGFloat = pin.big ? 128 : 92
            let chip = CGRect(x: contentX, y: midY - sz / 2, width: sz, height: sz)
            let chipP = CGPath(roundedRect: chip, cornerWidth: 22, cornerHeight: 22, transform: nil)
            ctx.setFillColor(pin.accent.copy(alpha: 0.16) ?? pin.accent)
            ctx.addPath(chipP); ctx.fillPath()
            let ef = Fonts.system(sz * 0.62)
            Draw.centeredText(ctx, emoji, cx: Int(chip.midX), y: Int(chip.midY - sz * 0.42),
                              font: ef, color: Color.textW)
            contentX = chip.maxX + 24
        }

        // ── Text column: source tag → title → markdown body ──
        let textR = imageLeftEdge
        let textW = Int(textR - contentX)
        var ty = Int(cardY + pad)
        if textW > 40 {
            if let src = pin.source {
                let sF = Fonts.system(pin.big ? 18 : 16, weight: .semibold)
                Draw.text(ctx, truncate(src.uppercased(), font: sF, maxW: CGFloat(textW)),
                          x: Int(contentX), y: ty, font: sF, color: pin.accent)
                ty += pin.big ? 30 : 26
            }
            if let title = pin.title {
                let tF = Fonts.system(pin.big ? 46 : 34, weight: .bold)
                Draw.text(ctx, truncate(title, font: tF, maxW: CGFloat(textW)),
                          x: Int(contentX), y: ty, font: tF, color: Color.textW)
                ty += pin.big ? 60 : 46
            }
            let bodyBottom = Int(cardY + cardH - pad - 10)
            if let body = pin.body, ty < bodyBottom {
                renderMessage(ctx, text: body, x: Int(contentX), y: ty,
                              w: textW, bottom: bodyBottom, accent: pin.accent)
            }
        }

        // ── Countdown hairline along the bottom inner edge ──
        let frac = total > 0 ? CGFloat(max(0, remaining / total)) : 0
        let barY = cardY + cardH - pad + 2
        let barW = (cardW - 2 * pad) * frac
        if barW > 1 {
            ctx.setStrokeColor(pin.accent)
            ctx.setLineWidth(3); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: contentX, y: barY))
            ctx.addLine(to: CGPoint(x: contentX + barW, y: barY))
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    /// A session is "urgent" (pinned to the top, flashing red) only when it finished
    /// recently — a turn that ended long ago is just idle, not something you must act
    /// on now, so it must not hog the front of the list forever.
    private func isUrgent(_ e: AgentEntry) -> Bool {
        e.waiting && e.secondsSinceActive < 180
    }

    // MARK: - AI Agents Panel (triple width)

    private func renderAgents(_ ctx: CGContext, agents: AgentsSnapshot) {
        let x = Layout.panelX(1)
        let pw = Layout.panelWidth * 3 + Layout.gap * 2
        let py = Layout.panelY
        let ph = Layout.panelHeight

        // Whole-panel accent turns red only while an agent RECENTLY finished and
        // wants you now — not for every long-idle session sitting in a waiting state.
        let waiting = agents.entries.contains(where: isUrgent)
        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: waiting ? Color.red : Color.purple)

        // Priority sort: urgent (freshly waiting) > working > idle, ties by recency.
        func rank(_ e: AgentEntry) -> Int { isUrgent(e) ? 0 : (e.isWorking ? 1 : 2) }
        let sorted = agents.entries.sorted {
            rank($0) != rank($1) ? rank($0) < rank($1)
                : $0.secondsSinceActive < $1.secondsSinceActive
        }
        // Auto-focus = the top of that order: a waiting agent, else the freshest.
        let focus = sorted.first

        // Header + live count
        panelTitle(ctx, "AI AGENTS", x: x + 20, y: py + 14,
                   font: Fonts.system(24, weight: .bold),
                   color: waiting ? Color.red : Color.purple)
        let live = agents.entries.filter { $0.isWorking || $0.waiting }.count
        let sub = "\(agents.entries.count) 会话 · \(live) 活跃"
        let subF = Fonts.system(16, weight: .medium)
        let subW = (sub as NSString).size(withAttributes: [.font: subF]).width
        Draw.text(ctx, sub, x: Int(CGFloat(x + pw - 20) - subW), y: py + 20,
                  font: subF, color: Color.textL)

        // Layout: left list (~40%) | divider | right detail; token footer at the bottom.
        let contentTop = py + 52
        let footerH = 30
        let contentBottom = py + ph - footerH - 8
        let listW = Int(Double(pw) * 0.40)
        let detailX = x + listW + 20
        let detailW = pw - listW - 40

        Draw.rule(ctx, from: CGPoint(x: detailX - 12, y: contentTop),
                  to: CGPoint(x: detailX - 12, y: contentBottom), color: Color.border)

        renderAgentList(ctx, entries: sorted, focusID: focus?.id, x: x + 20,
                        w: listW - 24, top: contentTop, bottom: contentBottom)
        if let f = focus {
            renderAgentDetail(ctx, entry: f, x: detailX, w: detailW,
                              top: contentTop, bottom: contentBottom)
        } else {
            Draw.text(ctx, agents.entries.isEmpty ? "无活跃会话" : "—",
                      x: detailX, y: contentTop + 16,
                      font: Fonts.system(22), color: Color.textL)
        }

        renderAgentFooter(ctx, agents: agents, x: x + 20, w: pw - 40, y: py + ph - footerH + 6)
    }

    private func agentAccent(_ k: AgentKind) -> CGColor {
        k == .claude ? Color.claude : Color.cyan
    }

    private func statusColor(_ e: AgentEntry) -> CGColor {
        if isUrgent(e) { return Color.red }
        if e.isWorking { return Color.green }
        return Color.textL
    }

    private func firstLine(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let line = s.split(separator: "\n").first.map(String.init) ?? s
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func idleText(_ secs: Int) -> String {
        if secs < 60 { return "空闲 \(secs)s" }
        if secs < 3600 { return "空闲 \(secs / 60)m" }
        if secs < 86400 { return "空闲 \(secs / 3600)h" }
        return "空闲 \(secs / 86400)d"
    }

    private func agoText(_ s: Int) -> String {
        if s < 90 { return "刚刚" }
        if s < 3600 { return "\(s / 60)m 前" }
        if s < 86400 { return "\(s / 3600)h 前" }
        return "\(s / 86400)d 前"
    }

    /// Model id → a label that fits the panel:
    ///   claude-haiku-4-5-20251001  → Haiku 4.5
    ///   bapi_codex/gpt-5.6-sol     → GPT-5.6-sol
    /// Anything unrecognised falls through as-is (minus the provider prefix), so a
    /// new model shows up as its raw id rather than disappearing.
    private func shortModel(_ id: String) -> String {
        // Strip a provider prefix like "bapi_codex/"
        let bare = id.contains("/") ? String(id.split(separator: "/").last!) : id

        if bare.hasPrefix("claude-") {
            var parts = bare.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // Drop a trailing yyyymmdd snapshot stamp
            if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
            guard let family = parts.first else { return bare }
            let version = parts.dropFirst().joined(separator: ".")
            let name = family.prefix(1).uppercased() + family.dropFirst()
            return version.isEmpty ? name : "\(name) \(version)"
        }
        if bare.hasPrefix("gpt-") { return "GPT-" + bare.dropFirst(4) }
        return bare
    }

    /// Claude Code's `waitingFor` reason → a short label matching the panel's other
    /// Chinese captions. Unknown reasons pass through as-is.
    private func waitingLabel(_ reason: String) -> String {
        switch reason {
        case "permission prompt": return "待授权"
        case "input needed":      return "待输入"
        case "dialog open":       return "待确认"
        case "sandbox request":   return "沙箱授权"
        case "worker request":    return "子进程请求"
        default:                  return reason
        }
    }

    /// A panel title, preceded by the theme's header glyph when it has one. The title
    /// only shifts right if a glyph was actually drawn, so themes without one keep the
    /// original position exactly.
    private func panelTitle(_ ctx: CGContext, _ title: String, x: Int, y: Int,
                            font: NSFont, color: CGColor) {
        var tx = x
        if let g = Theme.current.decor.headerGlyph {
            let s = font.pointSize
            Draw.glyph(ctx, g, in: CGRect(x: CGFloat(x), y: CGFloat(y) + 3,
                                          width: s, height: s), color: color)
            tx += Int(s) + 7
        }
        Draw.text(ctx, title, x: tx, y: y, font: font, color: color)
    }

    /// Left column: one compact row per session, sorted, focus row highlighted.
    private func renderAgentList(_ ctx: CGContext, entries: [AgentEntry], focusID: String?,
                                 x: Int, w: Int, top: Int, bottom: Int) {
        let rowH = 60
        let maxRows = max(1, (bottom - top) / rowH)
        let t = Date().timeIntervalSince1970
        let blinkOn = Int(t * 2) % 2 == 0

        for (i, e) in entries.prefix(maxRows).enumerated() {
            let ry = top + i * rowH
            let accent = agentAccent(e.kind)

            if e.id == focusID {
                let r = CGRect(x: CGFloat(x - 10), y: CGFloat(ry - 2),
                               width: CGFloat(w + 20), height: CGFloat(rowH - 8))
                let p = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
                ctx.setFillColor(accent.copy(alpha: 0.13) ?? accent)
                ctx.addPath(p); ctx.fillPath()
                ctx.setFillColor(accent)
                ctx.fill(CGRect(x: CGFloat(x - 10), y: CGFloat(ry - 2),
                                width: 3, height: CGFloat(rowH - 8)))
            }

            // Status dot (waiting flashes)
            let sc = statusColor(e)
            let dotA: CGFloat = e.flash ? (blinkOn ? 1.0 : 0.22) : 1.0
            ctx.setFillColor(sc.copy(alpha: dotA) ?? sc)
            ctx.fillEllipse(in: CGRect(x: CGFloat(x + 2), y: CGFloat(ry + 9),
                                       width: 12, height: 12))

            // Title: "Codex · project"  (+ step badge right)
            let title = "\(e.kind.rawValue) · \(e.project ?? "—")"
            let tF = Fonts.system(21, weight: .semibold)
            var titleMaxW = CGFloat(w - 24)
            if let cur = e.stepCurrent, let tot = e.stepTotal {
                let badge = "\(cur)/\(tot)"
                let bF = Fonts.system(16, weight: .semibold)
                let bW = (badge as NSString).size(withAttributes: [.font: bF]).width
                Draw.text(ctx, badge, x: Int(CGFloat(x + w) - bW), y: ry + 4,
                          font: bF, color: accent)
                titleMaxW -= bW + 10
            }
            Draw.text(ctx, truncate(title, font: tF, maxW: titleMaxW),
                      x: x + 24, y: ry, font: tF, color: Color.textW)

            // Second line: status text
            let (statusText, statusCol): (String, CGColor)
            if isUrgent(e) {
                (statusText, statusCol) = (e.waitingFor.map(waitingLabel) ?? "等你输入", Color.red)
            } else if e.isWorking {
                (statusText, statusCol) = (e.stepText ?? firstLine(e.message) ?? "运行中…", Color.green)
            } else {
                (statusText, statusCol) = (idleText(e.secondsSinceActive), Color.textL)
            }
            let s2F = Fonts.system(16)
            Draw.text(ctx, truncate(statusText, font: s2F, maxW: CGFloat(w - 24)),
                      x: x + 24, y: ry + 28, font: s2F, color: statusCol)
        }

        if entries.count > maxRows {
            Draw.text(ctx, "+\(entries.count - maxRows) 更多", x: x + 24,
                      y: top + maxRows * rowH, font: Fonts.system(15), color: Color.textD)
        }
    }

    /// Right column: the auto-focused session, expanded — header, step, full message.
    private func renderAgentDetail(_ ctx: CGContext, entry e: AgentEntry,
                                   x: Int, w: Int, top: Int, bottom: Int) {
        let accent = agentAccent(e.kind)
        var y = top

        // Header: "Codex · project"  + ago (right)
        let ago = agoText(e.secondsSinceActive)
        let agoActive = e.secondsSinceActive < 90
        let agoF = Fonts.system(16, weight: .medium)
        let agoW = (ago as NSString).size(withAttributes: [.font: agoF]).width
        Draw.text(ctx, ago, x: Int(CGFloat(x + w) - agoW), y: y + 8,
                  font: agoF, color: agoActive ? Color.green : Color.textD)
        let title = "\(e.kind.rawValue) · \(e.project ?? "—")"
        let tF = Fonts.system(27, weight: .bold)
        let titleMaxW = CGFloat(w) - agoW - 16
        let shownTitle = truncate(title, font: tF, maxW: titleMaxW)
        Draw.text(ctx, shownTitle, x: x, y: y, font: tF, color: accent)
        // Model id trails the project name as dim metadata. It shares the title's
        // cursor and only draws in whatever the title left over, so a long project
        // name squeezes it out rather than overlapping the "N分钟前" on the right.
        if let m = e.model {
            let titleW = (shownTitle as NSString).size(withAttributes: [.font: tF]).width
            let mF = Fonts.system(17, weight: .medium)
            let avail = titleMaxW - titleW - 10
            if avail > 40 {
                Draw.text(ctx, truncate(shortModel(m), font: mF, maxW: avail),
                          x: x + Int(titleW) + 10, y: y + 9, font: mF, color: Color.textD)
            }
        }
        y += 42

        // Waiting badge (blinking) — the reason it was auto-focused
        if isUrgent(e) {
            let on = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
            let c = Color.red.copy(alpha: on ? 1 : 0.4) ?? Color.red
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y + 3), width: 13, height: 13))
            Draw.text(ctx, e.waitingFor.map(waitingLabel) ?? "等你输入 / 需确认",
                      x: x + 22, y: y,
                      font: Fonts.system(20, weight: .semibold), color: Color.red)
            y += 34
        }

        // Step: text (left) + "步骤 x/y" (right) + segmented bar
        if let cur = e.stepCurrent, let tot = e.stepTotal, tot > 0 {
            let badge = "步骤 \(cur)/\(tot)"
            let bF = Fonts.system(17, weight: .semibold)
            let bW = (badge as NSString).size(withAttributes: [.font: bF]).width
            Draw.text(ctx, badge, x: Int(CGFloat(x + w) - bW), y: y, font: bF, color: accent)
            if let st = e.stepText {
                Draw.text(ctx, truncate(st, font: Fonts.system(17), maxW: CGFloat(w) - bW - 16),
                          x: x, y: y, font: Fonts.system(17), color: Color.textS)
            }
            y += 26
            drawStepBar(ctx, x: x, y: y, w: w, current: cur, total: tot, accent: accent)
            y += 22
        }
        y += 6

        // Full message (markdown tables/lists laid out structurally)
        renderMessage(ctx, text: e.message ?? "—", x: x, y: y, w: w, bottom: bottom, accent: accent)
    }

    /// Slim footer: today's aggregate token + Codex quota (token intentionally demoted).
    private func renderAgentFooter(_ ctx: CGContext, agents: AgentsSnapshot,
                                   x: Int, w: Int, y: Int) {
        Draw.rule(ctx, from: CGPoint(x: x, y: y - 8),
                  to: CGPoint(x: x + w, y: y - 8), color: Color.border)

        // Right: today's token + quota summary (right-aligned).
        var parts: [String] = []
        if agents.claudeAvailable { parts.append("Claude \(formatTokensCN(agents.claudeTodayTokens))") }
        if agents.codexAvailable { parts.append("Codex \(formatTokensCN(agents.codexTodayTokens))") }
        var tok = "Token " + parts.joined(separator: " · ")
        if let used = agents.codexQuotaUsedPercent {
            tok += String(format: " · 额度%.0f%%", max(0, 100 - used))
        }
        let tokF = Fonts.system(16)
        let tokW = (tok as NSString).size(withAttributes: [.font: tokF]).width
        Draw.text(ctx, tok, x: Int(CGFloat(x + w) - tokW), y: y, font: tokF, color: Color.textL)

        // Left: live activity feed — newest first, one entry per project, with the verb
        // so it reads "✓ knight-server 完成一轮" instead of a cryptic repeated name.
        let feedMaxW = CGFloat(w) - tokW - 24
        if feedMaxW > 60 {
            var seen = Set<String>()
            var segs: [String] = []
            for e in agents.recentEvents {   // recentEvents is newest-first
                guard seen.insert(e.project).inserted else { continue }
                segs.append("\(e.icon) \(e.project) \(e.verb)")
                if segs.count >= 3 { break }
            }
            let feed = segs.joined(separator: "    ")
            if !feed.isEmpty {
                let fF = Fonts.system(16)
                Draw.text(ctx, truncate(feed, font: fF, maxW: feedMaxW),
                          x: x, y: y, font: fF, color: Color.textS)
            }
        }
    }

    /// Segmented plan-progress bar: completed steps solid, current bright, pending dim.
    private func drawStepBar(_ ctx: CGContext, x: Int, y: Int, w: Int,
                             current: Int, total: Int, accent: CGColor) {
        guard total > 0 else { return }
        let gap = 4
        let segW = (w - gap * (total - 1)) / total
        guard segW > 0 else { return }
        for i in 0..<total {
            let sx = x + i * (segW + gap)
            let color: CGColor
            if i < current - 1 {          // completed
                color = accent.copy(alpha: 0.5) ?? accent
            } else if i == current - 1 {  // current
                color = accent
            } else {                      // pending
                color = Color.barBG
            }
            let rect = CGRect(x: CGFloat(sx), y: CGFloat(y), width: CGFloat(segW), height: 7)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()

            // Mark the active step with a note head — a playhead on the sequencer.
            if i == current - 1, Theme.current.decor.segment == .noteHead {
                Draw.noteMarker(ctx, atX: rect.maxX, midY: rect.midY, scale: 11, color: accent)
            }
        }
    }

    /// 中文数量格式："33.99万"、"1.02亿"。1万以下显示原始数字。
    private func formatTokensCN(_ n: UInt64) -> String {
        let v = Double(n)
        if v >= 1e8 {
            let y = v / 1e8
            return String(format: y < 100 ? "%.2f亿" : "%.1f亿", y)
        }
        if v >= 1e4 {
            let w = v / 1e4
            return String(format: w < 100 ? "%.2f万" : (w < 1000 ? "%.1f万" : "%.0f万"), w)
        }
        return "\(n)"
    }

    // MARK: - Agent message layout (markdown-aware)

    /// Render an agent message top-down within [y, bottom): markdown tables become
    /// aligned grids, `- ` bullets and prose wrap. Stops when vertical space runs out.
    private func renderMessage(_ ctx: CGContext, text: String, x: Int, y: Int, w: Int,
                               bottom: Int, accent: CGColor) {
        let proseFont = Fonts.system(19)
        let lineH = 26
        var cy = y
        // Trim once up front: this runs every frame, and the loop below used to
        // re-trim the same lines several times over.
        let raw = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // reserve[j] = lines the blocks from j onward need at minimum, so a long
        // paragraph can be told how much room it must leave for its successors.
        // Table rows want one line each; anything else gets the 2-line floor every
        // prose block is guaranteed. Computed as a suffix sum so the layout stays
        // linear in the number of lines.
        var reserve = [Int](repeating: 0, count: raw.count + 1)
        for j in stride(from: raw.count - 1, through: 0, by: -1) {
            let cost = raw[j].isEmpty ? 0 : (isTableLine(raw[j]) ? 1 : 2)
            reserve[j] = reserve[j + 1] + cost
        }

        var i = 0
        while i < raw.count && cy + 20 <= bottom {
            let line = raw[i]
            if line.isEmpty { i += 1; continue }

            if isTableLine(line) {
                // Consume the contiguous run of table rows and render as a grid
                var block: [String] = []
                while i < raw.count && isTableLine(raw[i]) {
                    block.append(raw[i])
                    i += 1
                }
                cy = renderTable(ctx, rows: block, x: x, y: cy, w: w, bottom: bottom, accent: accent)
            } else {
                // Prose / bullet — wrap, capped so this block cannot crowd out what
                // follows (typically a markdown table). Budget against what actually
                // comes next rather than a flat 2 lines: an agent mid-turn usually
                // writes one long unbroken paragraph, and the flat cap rendered two
                // lines of it and left the rest of the column blank. With nothing
                // after it, a paragraph may use the whole panel.
                let remaining = (bottom - cy) / lineH
                guard remaining > 0 else { break }
                let cap = max(2, remaining - reserve[i + 1])
                let wrapped = wrap(stripMarkdown(line), font: proseFont,
                                   maxW: CGFloat(w), maxLines: min(cap, remaining))
                for wl in wrapped {
                    if cy + lineH > bottom { break }
                    Draw.text(ctx, wl, x: x, y: cy, font: proseFont, color: Color.textS)
                    cy += lineH
                }
                i += 1
            }
        }
    }

    private func isTableLine(_ s: String) -> Bool {
        s.hasPrefix("|") && s.filter { $0 == "|" }.count >= 2
    }

    /// A markdown separator cell like `---`, `:--`, `--:`, `:-:`.
    private func isSeparatorCell(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
    }

    private func stripMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
    }

    /// Render markdown table rows as an aligned grid. Returns the new y below it.
    private func renderTable(_ ctx: CGContext, rows rawRows: [String], x: Int, y: Int,
                             w: Int, bottom: Int, accent: CGColor) -> Int {
        // Parse into cell rows, dropping the separator row and empty edge cells
        var rows: [[String]] = []
        for line in rawRows {
            var cells = line.components(separatedBy: "|").map {
                stripMarkdown($0.trimmingCharacters(in: .whitespaces))
            }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            if cells.allSatisfy({ isSeparatorCell($0) }) { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return y }

        let cols = rows.map(\.count).max() ?? 1
        let rowH = 24
        let colGap = 8
        let colW = (w - colGap * (cols - 1)) / max(cols, 1)
        guard colW > 20 else { return y }
        let cellFont = Fonts.system(16)
        let headFont = Fonts.system(16, weight: .semibold)

        var cy = y + 2
        for (ri, row) in rows.enumerated() {
            if cy + rowH > bottom { break }
            for ci in 0..<cols {
                let cell = ci < row.count ? row[ci] : ""
                if cell.isEmpty { continue }
                let cx = x + ci * (colW + colGap)
                let font = ri == 0 ? headFont : cellFont
                let color = ri == 0 ? accent : Color.textS
                Draw.text(ctx, truncate(cell, font: font, maxW: CGFloat(colW)),
                          x: cx, y: cy, font: font, color: color)
            }
            cy += rowH
            if ri == 0 {  // underline under the header row
                Draw.line(ctx, from: CGPoint(x: x, y: cy - 4),
                          to: CGPoint(x: x + w, y: cy - 4), color: Color.border)
            }
        }
        return cy + 4
    }

    /// Truncate a single line with "…" to fit maxW.
    private func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= maxW { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            if ((t + "…") as NSString).size(withAttributes: attrs).width <= maxW {
                return t + "…"
            }
        }
        return "…"
    }

    /// Greedy character wrap (activity text may be CJK — no word boundaries).
    private func wrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        guard maxLines >= 1 else { return [] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [String] = []
        var current = ""
        for ch in s {
            let candidate = current + String(ch)
            if (candidate as NSString).size(withAttributes: attrs).width > maxW {
                // Reached the last allowed line → fold the whole remainder into it
                if lines.count == maxLines - 1 {
                    let rest = String(s[s.index(s.startIndex, offsetBy: lines.joined().count)...])
                    lines.append(truncate(rest, font: font, maxW: maxW))
                    return lines
                }
                lines.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

}
