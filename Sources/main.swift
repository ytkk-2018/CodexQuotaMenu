import AppKit
import Foundation

private struct QuotaWindow {
    let used: Double
    let minutes: Int
    let resetsAt: Date

    var remaining: Int { max(0, min(100, Int((100 - used).rounded()))) }
}

private struct QuotaSnapshot {
    let short: QuotaWindow?
    let long: QuotaWindow?
    let updatedAt: Date
}

private enum RingIcon {
    static let size = NSSize(width: 28, height: 28)

    static func make(fiveHour: Int?, weekly: Int?, failed: Bool = false) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY + 0.5)
            let track = NSColor.labelColor.withAlphaComponent(0.18)
            func ring(radius: CGFloat, width: CGFloat, remaining: Int?, color: NSColor) {
                let base = NSBezierPath()
                base.appendArc(withCenter: center, radius: radius,
                               startAngle: 225, endAngle: -45, clockwise: true)
                base.lineWidth = width
                base.lineCapStyle = .round
                track.setStroke()
                base.stroke()

                guard let remaining, remaining > 0 else { return }
                let progress = NSBezierPath()
                progress.appendArc(withCenter: center, radius: radius,
                                   startAngle: 225,
                                   endAngle: 225 - 270 * CGFloat(remaining) / 100,
                                   clockwise: true)
                progress.lineWidth = width
                progress.lineCapStyle = .round
                color.setStroke()
                progress.stroke()
            }
            ring(radius: 12.1, width: 2.3, remaining: weekly,
                 color: NSColor.systemBlue)
            ring(radius: 8.7, width: 2.3, remaining: fiveHour,
                 color: NSColor.systemGreen)

            let label = fiveHour.map(String.init) ?? (failed ? "!" : "…")
            let font = NSFont.monospacedDigitSystemFont(ofSize: label.count >= 3 ? 6.7 : 7.3,
                                                         weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: failed ? NSColor.systemRed : NSColor.labelColor
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let bounds = text.size()
            text.draw(at: NSPoint(x: center.x - bounds.width / 2,
                                  y: center.y - bounds.height / 2 + 0.5))
            return true
        }
    }
}

private enum QuotaError: LocalizedError {
    case missingCLI
    case launch(String)
    case timeout
    case disconnected
    case response(String)
    case noLimits

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex CLI。请安装或更新 Codex 桌面应用。"
        case .launch(let detail): return "无法启动 Codex CLI：\(detail)"
        case .timeout: return "读取超时。请检查网络与 Codex 登录状态。"
        case .disconnected: return "Codex App Server 已断开。"
        case .response(let detail): return "读取额度失败：\(detail)"
        case .noLimits: return "此账号暂未返回 Codex 额度数据。"
        }
    }
}

private final class QuotaReader {
    static func read() throws -> QuotaSnapshot {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw QuotaError.missingCLI
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { throw QuotaError.launch(error.localizedDescription) }
        defer {
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
        }

        // A watchdog closes the pipes if the local server or network stalls.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel() }

        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            input.fileHandleForWriting.write(data + Data([10]))
        }
        var pending = Data()
        func nextMessage() throws -> [String: Any] {
            while true {
                if let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    if let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                        return object
                    }
                    continue
                }
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { throw process.isRunning ? QuotaError.timeout : QuotaError.disconnected }
                pending.append(data)
            }
        }

        try send(["method": "initialize", "id": 1, "params": [
            "clientInfo": ["name": "codex_quota_menu", "title": "Codex Quota Menu", "version": "1.0.0"]
        ]])
        while true {
            let message = try nextMessage()
            if (message["id"] as? Int) == 1 {
                if let error = message["error"] as? [String: Any] {
                    throw QuotaError.response(error["message"] as? String ?? "初始化失败")
                }
                break
            }
        }
        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 2, "params": [:]])
        while true {
            let message = try nextMessage()
            guard (message["id"] as? Int) == 2 else { continue }
            if let error = message["error"] as? [String: Any] {
                throw QuotaError.response(error["message"] as? String ?? "未知错误")
            }
            guard let result = message["result"] as? [String: Any] else { throw QuotaError.noLimits }
            let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
            let limit = buckets?["codex"] ?? result["rateLimits"] as? [String: Any]
            guard let limit else { throw QuotaError.noLimits }
            func window(_ key: String) -> QuotaWindow? {
                guard let value = limit[key] as? [String: Any],
                      let used = value["usedPercent"] as? Double,
                      let minutes = value["windowDurationMins"] as? Int,
                      let reset = value["resetsAt"] as? Double else { return nil }
                return QuotaWindow(used: used, minutes: minutes,
                                   resetsAt: Date(timeIntervalSince1970: reset))
            }
            let snapshot = QuotaSnapshot(short: window("primary"), long: window("secondary"), updatedAt: Date())
            guard snapshot.short != nil || snapshot.long != nil else { throw QuotaError.noLimits }
            return snapshot
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: RingIcon.size.width)
    private let menu = NSMenu()
    private var snapshot: QuotaSnapshot?
    private var lastError: String?
    private var refreshing = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateIcon()
        item.button?.toolTip = "Codex 额度"
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        if snapshot == nil { updateIcon() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try QuotaReader.read() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch result {
                case .success(let value):
                    self.snapshot = value
                    self.lastError = nil
                    self.updateIcon()
                case .failure(let error):
                    self.lastError = error.localizedDescription
                    if self.snapshot == nil { self.updateIcon() }
                }
                self.rebuildMenu()
            }
        }
    }

    private func updateIcon() {
        item.button?.title = ""
        item.button?.image = RingIcon.make(fiveHour: snapshot?.short?.remaining,
                                           weekly: snapshot?.long?.remaining,
                                           failed: lastError != nil)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        if let snapshot {
            item.button?.toolTip = "Codex：5 小时剩余 \(snapshot.short?.remaining ?? 0)% · 周剩余 \(snapshot.long?.remaining ?? 0)%"
        } else {
            item.button?.toolTip = lastError ?? "正在读取 Codex 额度"
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if let snapshot {
            addDisabled("外环：周额度  ·  内环：5 小时额度")
            menu.addItem(.separator())
            addWindow("短时额度", snapshot.short)
            addWindow("每周额度", snapshot.long)
            menu.addItem(.separator())
            let updated = DateFormatter.localizedString(from: snapshot.updatedAt, dateStyle: .none, timeStyle: .medium)
            addDisabled("更新于 \(updated)")
        } else {
            addDisabled(refreshing ? "正在读取额度…" : "暂无额度数据")
        }
        if let lastError { addDisabled("⚠ \(lastError)") }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !refreshing
        menu.addItem(refreshItem)
        let dashboard = NSMenuItem(title: "打开 Codex 用量页面", action: #selector(openDashboard), keyEquivalent: "")
        dashboard.target = self
        menu.addItem(dashboard)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addWindow(_ name: String, _ window: QuotaWindow?) {
        guard let window else { return }
        addDisabled("\(name)：剩余 \(window.remaining)%（已用 \(Int(window.used.rounded()))%）")
        let reset = DateFormatter.localizedString(from: window.resetsAt, dateStyle: .short, timeStyle: .short)
        addDisabled("    重置：\(reset)")
    }

    private func addDisabled(_ title: String) {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        menu.addItem(menuItem)
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!)
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--preview" {
    let image = RingIcon.make(fiveHour: 79, weekly: 81)
    let previewWidth = Int(RingIcon.size.width * 10)
    let previewHeight = Int(RingIcon.size.height * 10)
    let previewRect = NSRect(x: 0, y: 0, width: previewWidth, height: previewHeight)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: previewWidth, pixelsHigh: previewHeight,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    previewRect.fill()
    image.draw(in: previewRect)
    NSGraphicsContext.restoreGraphicsState()
    if let png = bitmap.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
