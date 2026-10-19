import AppKit
import Foundation

private struct UsageWindow {
    let usedPercent: Int
    let resetAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }
}

private struct UsageSnapshot {
    let primary: UsageWindow
    let secondary: UsageWindow
    let resetCredits: Int
    let plan: String
}

private final class CodexUsageClient {
    enum ClientError: LocalizedError {
        case codexNotFound
        case processFailed(String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .codexNotFound:
                return "未找到 ChatGPT 内置的 Codex 程序"
            case .processFailed(let message):
                return message.isEmpty ? "Codex 状态服务启动失败" : message
            case .malformedResponse:
                return "额度数据格式无法识别"
            }
        }
    }

    var onSnapshot: ((UsageSnapshot) -> Void)?
    var onError: ((Error) -> Void)?

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 2
    private var initialized = false
    private let queue = DispatchQueue(label: "QuotaPet.CodexUsageClient")

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.initialized || self.process?.isRunning != true {
                self.stopLocked()
                self.startLocked()
                return
            }
            self.requestUsageLocked()
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func startLocked() {
        guard process?.isRunning != true else { return }
        guard let executable = Self.findCodexExecutable() else {
            report(ClientError.codexNotFound)
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeLocked(data) }
        }

        errors.fileHandleForReading.readabilityHandler = { _ in
            // The Codex service may emit harmless model/plugin warnings. A stopped
            // process is handled by the termination callback instead.
        }

        process.terminationHandler = { [weak self] process in
            guard process.terminationStatus != 0 else { return }
            self?.report(ClientError.processFailed("Codex 状态服务已停止（\(process.terminationStatus)）"))
        }

        do {
            try process.run()
            self.process = process
            self.inputHandle = input.fileHandleForWriting
            self.initialized = false
            self.outputBuffer.removeAll(keepingCapacity: true)
            sendLocked([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "quota-pet",
                        "title": "额度桌宠",
                        "version": "0.1.0"
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ])
        } catch {
            report(error)
        }
    }

    private func requestUsageLocked() {
        let requestID = nextRequestID
        nextRequestID += 1
        sendLocked([
            "id": requestID,
            "method": "account/rateLimits/read",
            "params": ["excludeResetCreditDetails": true]
        ])
    }

    private func sendLocked(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        do {
            try inputHandle?.write(contentsOf: data)
        } catch {
            report(error)
        }
    }

    private func consumeLocked(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handleLocked(object)
        }
    }

    private func handleLocked(_ object: [String: Any]) {
        if let id = object["id"] as? Int, id == 1, object["result"] != nil {
            initialized = true
            sendLocked(["method": "initialized"])
            requestUsageLocked()
            return
        }

        if object["result"] != nil {
            do {
                let snapshot = try Self.parseSnapshot(object)
                DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
            } catch {
                report(error)
            }
            return
        }

        if object["method"] as? String == "account/rateLimits/updated",
           let params = object["params"] as? [String: Any] {
            do {
                let snapshot = try Self.parseSnapshot(["result": params])
                DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snapshot) }
            } catch {
                // Rolling updates can be sparse. A regular refresh will obtain a full snapshot.
            }
        }
    }

    private static func parseSnapshot(_ envelope: [String: Any]) throws -> UsageSnapshot {
        guard let result = envelope["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any],
              let primary = parseWindow(limits["primary"]),
              let secondary = parseWindow(limits["secondary"]) else {
            throw ClientError.malformedResponse
        }

        let resetSummary = result["rateLimitResetCredits"] as? [String: Any]
        let resetCredits = number(resetSummary?["availableCount"]) ?? 0
        let plan = limits["planType"] as? String ?? ""
        return UsageSnapshot(primary: primary, secondary: secondary, resetCredits: resetCredits, plan: plan)
    }

    private static func parseWindow(_ value: Any?) -> UsageWindow? {
        guard let dictionary = value as? [String: Any],
              let used = number(dictionary["usedPercent"]) else { return nil }
        let reset = number(dictionary["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return UsageWindow(usedPercent: used, resetAt: reset)
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }

    private static func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func stopLocked() {
        inputHandle?.closeFile()
        inputHandle = nil
        process?.terminate()
        process = nil
        initialized = false
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}

private final class QuotaBubbleView: NSView {
    var snapshot: UsageSnapshot? { didSet { needsDisplay = true } }
    var statusText = "正在连接…" { didSet { needsDisplay = true } }
    var onDoubleClick: (() -> Void)?

    private var dragOrigin = NSPoint.zero
    private var windowOrigin = NSPoint.zero

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let panelRect = bounds.insetBy(dx: 1, dy: 1)
        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 20, yRadius: 20)
        NSColor(calibratedWhite: 0.10, alpha: 0.88).setFill()
        panel.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        guard let snapshot else {
            drawCentered(statusText, in: bounds, font: .systemFont(ofSize: 13, weight: .medium), color: .white.withAlphaComponent(0.82))
            return
        }

        drawRing(center: NSPoint(x: 43, y: bounds.midY + 1), radius: 25, remaining: snapshot.primary.remainingPercent, label: "5小时")
        drawRing(center: NSPoint(x: 108, y: bounds.midY + 1), radius: 25, remaining: snapshot.secondary.remainingPercent, label: "本周")
    }

    private func drawRing(center: NSPoint, radius: CGFloat, remaining: Int, label: String) {
        let color = quotaColor(remaining)
        let ringRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        let background = NSBezierPath(ovalIn: ringRect)
        NSColor.white.withAlphaComponent(0.14).setStroke()
        background.lineWidth = 5
        background.stroke()

        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - CGFloat(remaining) * 3.6, clockwise: true)
        arc.lineWidth = 5
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()

        let percentText = "\(remaining)%" as NSString
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let percentSize = percentText.size(withAttributes: percentAttributes)
        percentText.draw(at: NSPoint(x: center.x - percentSize.width / 2, y: center.y - 5), withAttributes: percentAttributes)

        let labelText = label as NSString
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.62)
        ]
        let labelSize = labelText.size(withAttributes: labelAttributes)
        labelText.draw(at: NSPoint(x: center.x - labelSize.width / 2, y: center.y - 17), withAttributes: labelAttributes)
    }

    private func quotaColor(_ remaining: Int) -> NSColor {
        if remaining <= 20 { return NSColor.systemRed }
        if remaining <= 45 { return NSColor.systemOrange }
        return NSColor.systemGreen
    }

    private func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let string = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        let delta = NSPoint(x: current.x - dragOrigin.x, y: current.y - dragOrigin.y)
        let origin = NSPoint(x: windowOrigin.x + delta.x, y: windowOrigin.y + delta.y)
        window?.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set(origin.x, forKey: "bubbleX")
        UserDefaults.standard.set(origin.y, forKey: "bubbleY")
        UserDefaults.standard.set(true, forKey: "hasBubblePosition")
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = CodexUsageClient()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var bubbleView: QuotaBubbleView!
    private var refreshTimer: Timer?
    private var snapshot: UsageSnapshot?
    private var lastError: String?
    private var isRefreshing = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        wireClient()
        client.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        client.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusItem.button?.title = "额度 …"
        statusItem.menu = buildMenu()
    }

    private func setupPanel() {
        let size = NSSize(width: 150, height: 76)
        let origin: NSPoint
        if UserDefaults.standard.bool(forKey: "hasBubblePosition") {
            origin = NSPoint(x: UserDefaults.standard.double(forKey: "bubbleX"), y: UserDefaults.standard.double(forKey: "bubbleY"))
        } else if let screen = NSScreen.main {
            origin = NSPoint(x: screen.visibleFrame.maxX - size.width - 22, y: screen.visibleFrame.minY + 88)
        } else {
            origin = NSPoint(x: 100, y: 100)
        }

        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false

        bubbleView = QuotaBubbleView(frame: NSRect(origin: .zero, size: size))
        bubbleView.onDoubleClick = { [weak self] in self?.refresh() }
        panel.contentView = bubbleView
        panel.orderFrontRegardless()
    }

    private func wireClient() {
        client.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
            self.lastError = nil
            self.isRefreshing = false
            self.updateUI()
        }
        client.onError = { [weak self] error in
            guard let self else { return }
            self.lastError = error.localizedDescription
            self.isRefreshing = false
            self.updateUI()
        }
    }

    private func refresh() {
        isRefreshing = true
        bubbleView.statusText = "正在刷新…"
        client.refresh()
    }

    private func updateUI() {
        bubbleView.snapshot = snapshot
        if let snapshot {
            statusItem.button?.title = "5h \(snapshot.primary.remainingPercent)% · 周 \(snapshot.secondary.remainingPercent)%"
            statusItem.button?.toolTip = "额度桌宠：点击查看详情"
        } else {
            statusItem.button?.title = "额度 --"
            bubbleView.statusText = lastError ?? "暂时无法读取"
        }
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let snapshot {
            menu.addItem(disabledItem("5 小时剩余：\(snapshot.primary.remainingPercent)%"))
            menu.addItem(disabledItem("重置时间：\(format(snapshot.primary.resetAt))"))
            menu.addItem(.separator())
            menu.addItem(disabledItem("每周剩余：\(snapshot.secondary.remainingPercent)%"))
            menu.addItem(disabledItem("重置时间：\(format(snapshot.secondary.resetAt))"))
            menu.addItem(disabledItem("可用完整重置券：\(snapshot.resetCredits)"))
        } else {
            menu.addItem(disabledItem(lastError ?? "正在读取额度…"))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshFromMenu), keyEquivalent: "r"))
        let toggleTitle = panel?.isVisible == true ? "隐藏桌面额度泡泡" : "显示桌面额度泡泡"
        menu.addItem(NSMenuItem(title: toggleTitle, action: #selector(togglePanel), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出额度桌宠", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func format(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "今天 HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    @objc private func refreshFromMenu() {
        refresh()
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
        statusItem.menu = buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
