// MonitorRenderer.swift — System Monitor 3-panel dashboard
//
// Set 1: CPU | AI AGENTS (triple width) | MEMORY
// The AGENTS panel shows each agent's current activity (top) and today's
// token usage + quota (bottom), sourced from local session transcripts.

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()
    private let agentCollector = AgentUsageCollector()

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
                       stepTotal: e.stepTotal, stepText: e.stepText)
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
        // Heavy CPU → Pikachu crackles with electricity, worth animating smoothly
        if let c = _cpu, c.total > 55 { return true }
        guard let a = _agents else { return false }
        return a.anyLive
    }

    private func metricsLoop() {
        log("[Metrics] Loop started on metricsQueue")
        var slowTick = 0
        while metricsRunning {
            // Fast metrics every tick
            let cpu = collector.collectCPU()
            let mem = collector.collectMemory()
            let net = collector.collectNetwork()
            lock.lock()
            _cpu = cpu; _mem = mem; _net = net
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
        let agents = AgentsSnapshot(
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
        renderOperator(ctx, agents: agents)
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
        var agents: AgentsSnapshot
        if demoMode {
            (cpu, mem, temp, sys, agents) = demoData()
            net = NetworkSnapshot(rxBytesPerSec: 1_450_000, txBytesPerSec: 240_000)
        } else {
            // Read cached metrics (never blocks — uses latest available values)
            lock.lock()
            guard let c = _cpu, let m = _mem, let tp = _temp, let a = _agents else {
                lock.unlock(); return nil
            }
            cpu = c; mem = m; temp = tp; agents = a; sys = _sys; net = _net
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

        // Panels
        renderOperator(ctx, agents: agents)
        renderAgents(ctx, agents: agents)
        renderInfoPanel(ctx, cpu: cpu, mem: mem, temp: temp, sys: sys, net: net)

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    // MARK: - CPU Panel

    private func renderCPU(_ ctx: CGContext, cpu: CPUSnapshot, temp: TemperatureSnapshot,
                           agentsBusy: Bool) {
        let x = Layout.panelX(0)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.blue)
        Draw.text(ctx, "CPU", x: x + 20, y: py + 14, font: Fonts.system(24, weight: .bold), color: Color.blue)
        // Arc gauge
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: cpu.total,
                      color: Color.forPercent(cpu.total),
                      colorDark: Color.forPercentDark(cpu.total), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", cpu.total),
                          cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Per-core bars — E-cores first, then P-cores, shifted down half a row
        let barX = x + 194
        let barW = pw - 218
        let coreCount = cpu.perCore.count
        let bottomLimit = py + ph - 96
        let fontSize: CGFloat = coreCount > 16 ? 12 : (coreCount > 10 ? 14 : 16)
        let barH = coreCount > 16 ? 8 : (coreCount > 10 ? 10 : 10)
        let spacing = min(36, (bottomLimit - py - 18) / max(coreCount, 1))
        let startY = py + 18 + spacing / 2  // shifted down half a row

        let pCoreCount = cpu.pCoreCount
        let eCoreCount = coreCount - pCoreCount

        // Reorder: E-cores first, then P-cores
        for row in 0..<coreCount {
            let by = startY + row * spacing
            if by + Int(fontSize) > bottomLimit { break }

            let coreIndex: Int
            let isECore: Bool
            let label: String
            if row < eCoreCount {
                // E-core rows first
                coreIndex = pCoreCount + row
                isECore = true
                label = "E\(row + 1)"
            } else {
                // P-core rows after
                coreIndex = row - eCoreCount
                isECore = false
                label = "P\(row - eCoreCount + 1)"
            }

            let pct = coreIndex < cpu.perCore.count ? cpu.perCore[coreIndex] : 0
            let barColor = isECore ? Color.cyan : Color.forPercent(pct)

            Draw.text(ctx, label, x: barX, y: by,
                      font: Fonts.system(fontSize), color: isECore ? Color.cyan : Color.textD)
            Draw.bar(ctx, x: barX + 28, y: by + 4, w: barW - 78, h: barH,
                     percent: pct, color: barColor)
            Draw.text(ctx, String(format: "%.0f%%", pct),
                      x: barX + barW - 46, y: by,
                      font: Fonts.system(fontSize), color: Color.textS)
        }

        // Pikachu in the left space below the gauge — its electricity scales with
        // CPU load (the machine's "power draw"). While an AI agent is working it
        // hops and turns to face left/right, like it's cheering the machine on.
        if let pika = PikachuAsset.image {
            let t = Date().timeIntervalSince1970
            let size: CGFloat = 132
            var rect = CGRect(x: CGFloat(x + 100) - size / 2, y: CGFloat(py + 210),
                              width: size, height: size)
            var flip = false
            if agentsBusy {
                let hop = CGFloat(abs(sin(t * .pi * 2)) * 9)   // ~2 hops/sec
                rect.origin.y -= hop                            // up (flipped coords)
                flip = Int(t * 2) % 4 >= 2                       // turn every ~1s
            }
            drawElectricity(ctx, around: rect, intensity: cpu.total, t: t)
            drawImageUpright(ctx, pika, in: rect, flipX: flip)
        }

        // Temp + Load — large, spanning the full panel width at the bottom.
        // Label on the left, value right-aligned to the panel edge.
        let rightEdge = CGFloat(x + pw - 18)
        let tempY = py + ph - 78
        if let cpuTemp = temp.cpuTemp {
            let tempColor = cpuTemp > 65 ? Color.red : (cpuTemp > 50 ? Color.orange : Color.green)
            Draw.text(ctx, "Temp", x: x + 18, y: tempY + 8,
                      font: Fonts.system(26, weight: .medium), color: Color.textL)
            let vStr = String(format: "%.0f°C", cpuTemp)
            let vFont = Fonts.system(42, weight: .bold)
            let vW = (vStr as NSString).size(withAttributes: [.font: vFont]).width
            Draw.text(ctx, vStr, x: Int(rightEdge - vW), y: tempY,
                      font: vFont, color: tempColor)
        }
        let loadY = py + ph - 34
        let (l1, l5, l15) = cpu.loadAvg
        Draw.text(ctx, "Load", x: x + 18, y: loadY,
                  font: Fonts.system(22, weight: .medium), color: Color.textL)
        let lStr = String(format: "%.1f / %.1f / %.1f", l1, l5, l15)
        let lFont = Fonts.system(26, weight: .medium)
        let lW = (lStr as NSString).size(withAttributes: [.font: lFont]).width
        Draw.text(ctx, lStr, x: Int(rightEdge - lW), y: loadY,
                  font: lFont, color: Color.textS)
    }

    /// Yellow lightning crackling around Pikachu — more/brighter bolts as `intensity`
    /// (CPU %) rises. Flickers with `t` so it animates while the frame rate is high.
    private func drawElectricity(_ ctx: CGContext, around rect: CGRect,
                                 intensity: Double, t: Double) {
        let level = min(max(intensity / 100, 0), 1)
        let yellow = CGColor(red: 1.0, green: 0.9, blue: 0.15, alpha: 1)
        let bolts = 2 + Int(level * 6)             // 2…8 bolts
        ctx.setStrokeColor(yellow); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for i in 0..<bolts {
            // Twinkle: each bolt blinks on/off on its own phase
            if (Int(t * 14) + i * 5) % 3 == 0 { continue }
            let ang = Double(i) / Double(bolts) * 2 * .pi + t * 0.7
            let ax = rect.midX + CGFloat(cos(ang)) * rect.width * 0.44
            let ay = rect.midY + CGFloat(sin(ang)) * rect.height * 0.42
            // Jagged 3-segment bolt pointing outward from the anchor
            let len = CGFloat(9 + level * 15)
            let dx = CGFloat(cos(ang)), dy = CGFloat(sin(ang))
            let nx = -dy, ny = dx                  // perpendicular for the zigzag
            ctx.setLineWidth(1.6 + CGFloat(level) * 1.2)
            let jag = 4 + level * 3
            ctx.move(to: CGPoint(x: ax, y: ay))
            ctx.addLine(to: CGPoint(x: ax + dx * len * 0.4 + nx * CGFloat(jag),
                                    y: ay + dy * len * 0.4 + ny * CGFloat(jag)))
            ctx.addLine(to: CGPoint(x: ax + dx * len * 0.7 - nx * CGFloat(jag),
                                    y: ay + dy * len * 0.7 - ny * CGFloat(jag)))
            ctx.addLine(to: CGPoint(x: ax + dx * len, y: ay + dy * len))
            ctx.strokePath()
        }
    }

    // MARK: - Memory Panel

    private func renderMemory(_ ctx: CGContext, mem: MemorySnapshot, sys: SystemSnapshot?,
                              agentsBusy: Bool) {
        let x = Layout.panelX(4)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let totalGB = Double(mem.total) / (1024 * 1024 * 1024)
        let pct = mem.percent

        Draw.panel(ctx, x: x, y: py, w: pw, h: Layout.panelHeight, accent: Color.green)
        Draw.text(ctx, "MEMORY", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.green)
        Draw.text(ctx, String(format: "%.0f GB", totalGB), x: x + pw - 75, y: py + 16,
                  font: Fonts.system(18), color: Color.textD)

        // Arc gauge — length = used% (utilization gauge), COLOR = macOS memory pressure.
        // A Mac using RAM as cache (high used%, low pressure) is healthy → stays green.
        let gcx = x + 100, gcy = py + 138
        Draw.arcGauge(ctx, cx: gcx, cy: gcy, radius: 70,
                      percent: pct,
                      color: Color.forPressure(mem.pressure),
                      colorDark: Color.forPressureDark(mem.pressure), thickness: 13)
        Draw.centeredText(ctx, String(format: "%.0f", pct), cx: gcx, y: gcy - 28,
                          font: Fonts.system(50, weight: .bold), color: Color.textW)
        Draw.centeredText(ctx, "%", cx: gcx, y: gcy + 24,
                          font: Fonts.system(20), color: Color.textS)

        // Breakdown
        let rx = x + 194
        let rw = pw - 218
        var ry = py + 48

        Draw.text(ctx, "Breakdown", x: rx, y: ry,
                  font: Fonts.system(18), color: Color.textL)
        ry += 28

        let activeGB = Double(mem.active) / (1024 * 1024 * 1024)
        let wiredGB = Double(mem.wired) / (1024 * 1024 * 1024)
        let compressedGB = Double(mem.compressed) / (1024 * 1024 * 1024)
        let availGB = Double(mem.available) / (1024 * 1024 * 1024)

        let items: [(String, Double, CGColor)] = [
            ("Active", activeGB, Color.green),
            ("Wired", wiredGB, Color.orange),
            ("Compressed", compressedGB, Color.purple),
            ("Available", availGB, Color.cyan),
        ]
        for (label, val, color) in items {
            Draw.text(ctx, label, x: rx, y: ry,
                      font: Fonts.system(17), color: Color.textL)
            let valStr = String(format: "%.1fG", val)
            let valFont = Fonts.system(17)
            let valW = (valStr as NSString).size(withAttributes: [.font: valFont]).width
            Draw.text(ctx, valStr, x: Int(CGFloat(rx + rw) - valW), y: ry,
                      font: valFont, color: Color.textS)
            Draw.bar(ctx, x: rx, y: ry + 24, w: rw, h: 10,
                     percent: val / totalGB * 100, color: color)
            ry += 48
        }

        // Bottom: a Bongo Cat tapping the divider "table", then the clock below it.
        // (Swap monitoring removed — this space now shows the date/time.)
        let ph = Layout.panelHeight
        let dividerY = py + ph - 116
        let cx0 = x + 16
        let cw = pw - 32
        Draw.line(ctx, from: CGPoint(x: cx0, y: dividerY),
                  to: CGPoint(x: cx0 + cw, y: dividerY), color: Color.border)

        // Bongo cat sits on the left, tapping the divider when an agent is busy
        let t = Date().timeIntervalSince1970
        let tapPhase = Int(t * 5) % 2 == 0
        drawBongoCat(ctx, cx: x + 96, baseY: dividerY, tapping: agentsBusy, phase: tapPhase)

        // Right of the cat: date, weekday, uptime, processes
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let ix = x + 190
        formatter.dateFormat = "yyyy-MM-dd"
        Draw.text(ctx, formatter.string(from: Date()), x: ix, y: py + ph - 196,
                  font: Fonts.system(22, weight: .semibold), color: Color.textW)
        formatter.dateFormat = "EEEE"
        Draw.text(ctx, formatter.string(from: Date()), x: ix, y: py + ph - 170,
                  font: Fonts.system(16), color: Color.textS)

        let iw = pw - (ix - x) - 16
        func stat(_ label: String, _ value: String, _ sy: Int) {
            Draw.text(ctx, label, x: ix, y: sy, font: Fonts.system(15), color: Color.textL)
            let vf = Fonts.system(15, weight: .medium)
            let vw = (value as NSString).size(withAttributes: [.font: vf]).width
            Draw.text(ctx, value, x: Int(CGFloat(ix + iw) - vw), y: sy, font: vf, color: Color.textS)
        }
        if let sys {
            let h = sys.uptimeSeconds / 3600, m = (sys.uptimeSeconds % 3600) / 60
            let up = h >= 24 ? "\(h / 24)d \(h % 24)h" : "\(h)h \(m)m"
            stat("Uptime", up, py + ph - 142)
            stat("Procs", "\(sys.processCount)", py + ph - 120)
        }

        // Clock — big, centered across the full panel width, below the divider
        formatter.dateFormat = "HH:mm:ss"
        Draw.centeredText(ctx, formatter.string(from: Date()),
                          cx: x + pw / 2, y: dividerY + 30,
                          font: Fonts.system(66, weight: .medium), color: Color.textW)
    }

    // MARK: - Info Panel (replaces Memory in the current layout; renderMemory kept as a component)

    /// Right-panel replacement: big clock + Gregorian date/weekday + lunar date (all
    /// local), live network up/down, and a compact system readout that re-homes the
    /// CPU/temp metrics displaced when Skadi took the CPU slot. No Bongo Cat.
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
        Draw.text(ctx, "STATUS", x: x + 20, y: py + 14,
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

    // MARK: - Bongo Cat (real line-art sprite, kuroni/bongocat-osu)

    /// Draw the classic Bongo Cat: the real line-art head sprite peeking over a desk,
    /// with a keyboard and two pink paws that slap it (`baseY` is the desk line). When
    /// `tapping`, the paws alternate; otherwise they rest and a "z" floats up.
    private func drawBongoCat(_ ctx: CGContext, cx: Int, baseY: Int, tapping: Bool, phase: Bool) {
        let dark = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)
        let pink = CGColor(red: 244/255, green: 150/255, blue: 174/255, alpha: 1)
        let kbTop = CGColor(red: 210/255, green: 216/255, blue: 230/255, alpha: 1)
        let cxD = CGFloat(cx), b = CGFloat(baseY)

        // --- Keyboard on the desk ---
        let kbW: CGFloat = 152, kbH: CGFloat = 15
        let kbX = cxD - kbW / 2, kbY = b - kbH
        let kbPath = CGPath(roundedRect: CGRect(x: kbX, y: kbY, width: kbW, height: kbH),
                            cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.setFillColor(kbTop); ctx.addPath(kbPath); ctx.fillPath()
        ctx.setStrokeColor(dark); ctx.setLineWidth(1.5); ctx.addPath(kbPath); ctx.strokePath()
        ctx.setLineWidth(1)
        var kx = kbX + 13
        while kx < kbX + kbW - 6 {
            ctx.move(to: CGPoint(x: kx, y: kbY + 2)); ctx.addLine(to: CGPoint(x: kx, y: kbY + kbH - 2))
            kx += 13
        }
        ctx.strokePath()

        // --- Cat head sprite, chin just above the keyboard ---
        if let cat = BongoCatAsset.image {
            let cw: CGFloat = 148
            let ch = cw * CGFloat(cat.height) / CGFloat(cat.width)
            let rect = CGRect(x: cxD - cw / 2, y: kbY - 4 - ch, width: cw, height: ch)
            drawImageUpright(ctx, cat, in: rect)
        }

        // --- Pink paws resting on / slapping the keyboard, outlined to match line art ---
        let pawRX: CGFloat = 13, pawRY: CGFloat = 10
        let downY = kbY + 2, upY = kbY - 14         // down = on keys, up = lifted to tap
        let lY = tapping ? (phase ? upY : downY) : downY
        let rY = tapping ? (phase ? downY : upY) : downY
        for (px, py2) in [(cxD - 34, lY), (cxD + 34, rY)] {
            let r = CGRect(x: px - pawRX, y: py2 - pawRY, width: pawRX * 2, height: pawRY * 2)
            ctx.setFillColor(pink); ctx.fillEllipse(in: r)
            ctx.setStrokeColor(dark); ctx.setLineWidth(2); ctx.strokeEllipse(in: r)
        }

        // Zzz when dozing
        if !tapping {
            Draw.text(ctx, "z", x: Int(cxD) + 60, y: Int(kbY) - 74,
                      font: Fonts.system(16, weight: .bold), color: Color.textL)
            Draw.text(ctx, "z", x: Int(cxD) + 72, y: Int(kbY) - 88,
                      font: Fonts.system(12, weight: .bold), color: Color.textD)
        }
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
    /// working, and idles (Relax) otherwise. The old CPU panel (`renderCPU`) is kept
    /// intact as a component so a future layout preset can swap it back in.
    private func renderOperator(_ ctx: CGContext, agents: AgentsSnapshot) {
        let x = Layout.panelX(0)
        let pw = Layout.panelWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight
        let busy = agents.anyLive
        let accent = Color.cyan

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: accent)
        Draw.text(ctx, "SKADI", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: accent)
        let status = busy ? "作战中" : "驻扎"
        let sF = Fonts.system(16, weight: .medium)
        let sW = (status as NSString).size(withAttributes: [.font: sF]).width
        Draw.text(ctx, status, x: Int(CGFloat(x + pw - 20) - sW), y: py + 20,
                  font: sF, color: busy ? Color.green : Color.textL)

        // Behaviour state machine: while an agent works she cycles COMBAT behaviours
        // (skills, with a battle-idle beat between); while idle she cycles BASE
        // behaviours (mostly relax, occasional interact/move, and a nap). Each
        // behaviour holds for `dwell` seconds, chosen by wall-clock so it's stateless.
        let now = Date().timeIntervalSince1970
        let dwell = 7.0
        let combat: [[CGImage]] = [SkadiAsset.skill2, SkadiAsset.skill3]
        let base: [[CGImage]] = [SkadiAsset.relax, SkadiAsset.relax, SkadiAsset.interact,
                                 SkadiAsset.move, SkadiAsset.relax, SkadiAsset.sleep]
        let clips = busy ? combat : base
        // Clips were sampled at SkadiAsset.fps, so play back at that rate for real speed.
        let fps = SkadiAsset.fps
        var frames = clips[Int(now / dwell) % clips.count]
        if frames.isEmpty { frames = busy ? SkadiAsset.skill2 : SkadiAsset.relax }
        guard !frames.isEmpty else { return }
        let img = frames[Int(now * fps) % frames.count]

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
        Draw.text(ctx, "AI AGENTS", x: x + 20, y: py + 14,
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

        Draw.line(ctx, from: CGPoint(x: detailX - 12, y: contentTop),
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
                (statusText, statusCol) = ("等你输入", Color.red)
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
        Draw.text(ctx, truncate(title, font: tF, maxW: CGFloat(w) - agoW - 16),
                  x: x, y: y, font: tF, color: accent)
        y += 42

        // Waiting badge (blinking) — the reason it was auto-focused
        if isUrgent(e) {
            let on = Int(Date().timeIntervalSince1970 * 2) % 2 == 0
            let c = Color.red.copy(alpha: on ? 1 : 0.4) ?? Color.red
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: CGFloat(x), y: CGFloat(y + 3), width: 13, height: 13))
            Draw.text(ctx, "等你输入 / 需确认", x: x + 22, y: y,
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
        Draw.line(ctx, from: CGPoint(x: x, y: y - 8),
                  to: CGPoint(x: x + w, y: y - 8), color: Color.border)
        var parts: [String] = []
        if agents.claudeAvailable {
            parts.append("Claude \(formatTokensCN(agents.claudeTodayTokens))")
        }
        if agents.codexAvailable {
            parts.append("Codex \(formatTokensCN(agents.codexTodayTokens))")
        }
        var line = "今日 Token  " + parts.joined(separator: "  ·  ")
        if let used = agents.codexQuotaUsedPercent {
            line += String(format: "  ·  额度 %.0f%%", max(0, 100 - used))
            if let r = agents.codexQuotaResetsAt {
                let s = max(0, Int(r.timeIntervalSinceNow))
                let rs = s >= 86400 ? "\(s / 86400)天后"
                    : (s >= 3600 ? "\(s / 3600)时后" : "\(max(s / 60, 1))分后")
                line += "(\(rs))"
            }
        }
        Draw.text(ctx, line, x: x, y: y, font: Fonts.system(16), color: Color.textL)
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
        let raw = text.components(separatedBy: "\n")
        var i = 0
        while i < raw.count && cy + 20 <= bottom {
            let line = raw[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }

            if isTableLine(line) {
                // Consume the contiguous run of table rows and render as a grid
                var block: [String] = []
                while i < raw.count && isTableLine(raw[i].trimmingCharacters(in: .whitespaces)) {
                    block.append(raw[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                cy = renderTable(ctx, rows: block, x: x, y: cy, w: w, bottom: bottom, accent: accent)
            } else {
                // Prose / bullet — wrap, but cap each block so a table below still fits
                let remaining = (bottom - cy) / lineH
                guard remaining > 0 else { break }
                let wrapped = wrap(stripMarkdown(line), font: proseFont,
                                   maxW: CGFloat(w), maxLines: min(2, remaining))
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
