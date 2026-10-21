import AppKit
import ServiceManagement

private let countdownPreferenceKey = "showResetCountdown"
private func isResetCountdownVisible() -> Bool {
    UserDefaults.standard.object(forKey: countdownPreferenceKey) as? Bool ?? true
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let client = CodexQuotaClient()
    private let login = LoginController()
    private var snapshot: QuotaSnapshot?
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var fetching = false
    private var sleeping = false
    private var refreshAfterCurrent = false
    private var lastError: String?
    private var failures = 0
    private var observers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    private let work = DispatchQueue(label: "codexquota.query", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.angeV587.CodexQuota").contains(where: { $0.processIdentifier < ownPID }) {
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: 42)
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.setAccessibilityLabel("Codex 剩余额度")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateGraphic() }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sleeping = true
                self.refreshTimer?.invalidate()
                self.displayTimer?.invalidate()
                self.client.cancel()
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sleeping = false
                self.startDisplayTimer()
                self.lastError = "正在更新唤醒前的数据"
                self.updateGraphic()
                self.refresh()
            }
        })
        // New installations opt into login launch from the menu. Existing registration stays intact.
        updateGraphic()
        startDisplayTimer()
        refresh()
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        // Refresh only the local countdown, without an additional network request.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.sleeping else { return }
                self.updateGraphic()
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func updateGraphic() {
        guard let button = item?.button else { return }
        let fresh = snapshot?.isFresh(at: Date()) == true
        let stale = snapshot != nil && (!fresh || lastError != nil)
        let remaining = fresh ? snapshot?.selected?.remaining : nil
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            button.image = StatusGraphic.image(remaining: remaining,
                                               resetAt: fresh ? snapshot?.selected?.resetsAt : nil,
                                               stale: stale, height: button.bounds.height,
                                               showResetCountdown: isResetCountdownVisible())
        }
        item.length = (button.image?.size.width ?? 90) + 4
        if let window = snapshot?.selected {
            let state = stale ? "（上次记录，非实时）" : ""
            button.toolTip = "Codex \(window.label)剩余 \(Int(window.remaining.rounded(.down)))%\(state)\n\(lastError ?? "每 5 分钟更新")"
            button.setAccessibilityValue("\(Int(window.remaining.rounded(.down)))%\(state)")
        } else {
            button.toolTip = lastError ?? "正在查询 Codex 额度"
            button.setAccessibilityValue(lastError ?? "正在查询")
        }
    }

    @objc private func refresh() {
        guard !sleeping else { return }
        if fetching { refreshAfterCurrent = true; return }
        refreshTimer?.invalidate()
        updateGraphic()
        fetching = true
        writeStatus()
        work.async { [weak self, client] in
            let result = Result { try client.fetch() }
            DispatchQueue.main.async { self?.completed(result) }
        }
    }

    private func completed(_ result: Result<QuotaSnapshot, Error>) {
        fetching = false
        guard !sleeping else { return }
        switch result {
        case .success(let newSnapshot): snapshot = newSnapshot; lastError = nil; failures = 0
        case .failure(let error): lastError = (error as? QuotaError)?.errorDescription ?? "额度查询失败，稍后重试"; failures += 1
        }
        updateGraphic()
        if refreshAfterCurrent { refreshAfterCurrent = false; refresh(); return }
        let retry = min(900.0, 60.0 * pow(2.0, Double(min(failures - 1, 4))))
        var delay = failures == 0 ? 300.0 : retry
        var scheduledForReset = false
        if let reset = snapshot?.windows.compactMap(\.resetsAt).filter({ $0 > Date().timeIntervalSince1970 }).min() {
            scheduledForReset = reset - Date().timeIntervalSince1970 + 1 < delay
            delay = min(delay, max(2, reset - Date().timeIntervalSince1970 + 1))
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        timer.tolerance = scheduledForReset ? 0 : min(20, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        writeStatus()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateGraphic()
        menu.removeAllItems()
        add(menu, "Codex 剩余额度", enabled: false)
        if let snapshot {
            for window in snapshot.windows {
                add(menu, "\(window.label)：剩余 \(Int(window.remaining.rounded(.down)))%", enabled: false)
                if let reset = window.resetsAt {
                    add(menu, "重置：\(Self.dateString(Date(timeIntervalSince1970: reset)))", enabled: false)
                }
            }
            add(menu, "账户：\(snapshot.accountLabel)", enabled: false)
            add(menu, "更新：\(Self.dateString(snapshot.fetchedAt))", enabled: false)
        }
        if snapshot != nil {
            if let lastError { add(menu, "\(lastError) · 显示非实时记录", enabled: false) }
            else if snapshot?.isFresh(at: Date()) != true { add(menu, "数据已过期，等待更新", enabled: false) }
        }
        if snapshot == nil { add(menu, lastError ?? "正在查询…", enabled: false) }
        add(menu, "来源：官方 Codex 登录 · 每 5 分钟查询", enabled: false)
        menu.addItem(.separator())
        add(menu, fetching ? "正在刷新…" : "立即刷新", action: #selector(refresh), enabled: !fetching)
        let countdownItem = add(menu, "显示重置倒计时", action: #selector(toggleResetCountdown))
        countdownItem.state = isResetCountdownVisible() ? .on : .off
        let loginItem = add(menu, "开机自动启动", action: #selector(toggleLogin))
        loginItem.state = login.status == .enabled ? .on : .off
        add(menu, login.statusDescription, enabled: false)
        if let issue = UserDefaults.standard.string(forKey: "loginRegistrationIssue") { add(menu, issue, enabled: false) }
        if login.status == .requiresApproval || login.status == .notFound {
            add(menu, "打开系统登录项设置…", action: #selector(openLoginSettings))
        }
        menu.addItem(.separator())
        add(menu, "退出", action: #selector(quit), key: "q")
        writeStatus()
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, action: Selector? = nil, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        entry.isEnabled = enabled
        menu.addItem(entry)
        return entry
    }

    @objc private func toggleResetCountdown() {
        UserDefaults.standard.set(!isResetCountdownVisible(), forKey: countdownPreferenceKey)
        updateGraphic()
        writeStatus()
    }

    @objc private func toggleLogin() {
        do {
            // A registered-but-unapproved service can also be turned off here.
            try login.setEnabled(login.status == .notRegistered || login.status == .notFound)
            UserDefaults.standard.removeObject(forKey: "loginRegistrationIssue")
        } catch {
            UserDefaults.standard.set("自启注册失败，请在菜单中重试", forKey: "loginRegistrationIssue")
        }
        writeStatus()
    }
    @objc private func openLoginSettings() { login.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        displayTimer?.invalidate()
        client.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if item != nil { NSStatusBar.system.removeStatusItem(item) }
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // Local verification metadata only: no email, account IDs, raw RPC, or credentials.
    private func writeStatus() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexQuota", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "loginStatus": login.statusDescription, "refreshing": fetching, "fresh": snapshot?.isFresh(at: Date()) == true && lastError == nil, "statusItemHeight": item?.button?.bounds.height ?? 0, "statusItemWidth": item?.button?.bounds.width ?? 0, "showResetCountdown": isResetCountdownVisible()]
        if let snapshot {
            info["remaining"] = snapshot.selected?.remaining
            info["windowMinutes"] = snapshot.selected?.windowDurationMins
            info["fetchedAt"] = snapshot.fetchedAt.timeIntervalSince1970
            info["resetsAt"] = snapshot.selected?.resetsAt
        }
        if let lastError { info["error"] = lastError }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}

if let displayCommand = CommandLine.arguments.dropFirst().first, ["--countdown-status", "--countdown-on", "--countdown-off"].contains(displayCommand) {
    if displayCommand != "--countdown-status" {
        UserDefaults.standard.set(displayCommand == "--countdown-on", forKey: countdownPreferenceKey)
    }
    print(isResetCountdownVisible() ? "重置倒计时已显示" : "重置倒计时已隐藏")
} else if let loginCommand = CommandLine.arguments.dropFirst().first, ["--login-status", "--login-on", "--login-off"].contains(loginCommand) {
    MainActor.assumeIsolated {
        let login = LoginController()
        do {
            if loginCommand == "--login-on" { try login.setEnabled(true) }
            if loginCommand == "--login-off" { try login.setEnabled(false) }
            print(login.statusDescription)
        } catch {
            fputs("自启设置失败，请打开应用菜单检查\n", stderr)
            exit(1)
        }
    }
} else if CommandLine.arguments.contains("--probe") {
    do {
        let snapshot = try CodexQuotaClient().fetch()
        let result: [String: Any] = ["remaining": snapshot.selected!.remaining, "windowMinutes": snapshot.selected!.windowDurationMins as Any, "resetsAt": snapshot.selected!.resetsAt as Any, "fresh": snapshot.isFresh(at: Date()), "source": snapshot.clientPath]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fputs("\((error as? QuotaError)?.errorDescription ?? "查询失败")\n", stderr)
        exit(1)
    }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
