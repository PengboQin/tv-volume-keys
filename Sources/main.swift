import AppKit
import ApplicationServices
import ServiceManagement

let callback: CGEventTapCallBack = { _, type, event, pointer in
    guard let pointer else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<VolumeKeys>.fromOpaque(pointer).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.heldKeys.removeAll()
        if let tap = app.tap, app.enabled { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
          let (action, down) = VolumeAction.decode(subtype: Int(ns.subtype.rawValue), data: ns.data1) else {
        return Unmanaged.passUnretained(event)
    }
    if !down {
        return app.heldKeys.remove(action) != nil ? nil : Unmanaged.passUnretained(event)
    }
    guard shouldCaptureVolume(enabled: app.enabled, cec: app.transportReady,
                              hdmi: defaultOutputIsTV(), modifiers: event.flags) else {
        return Unmanaged.passUnretained(event)
    }
    let wasHeld = app.heldKeys.contains(action)
    app.heldKeys.insert(action)
    if action != .mute || (!wasHeld && ns.data1 & 1 == 0) { app.handle(action, fromKey: true) }
    return nil
}

final class VolumeKeys: NSObject, NSApplicationDelegate {
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var item: NSStatusItem!
    var stateItem: NSMenuItem!
    var permissionItem: NSMenuItem!
    var toggleItem: NSMenuItem!
    var cecItem: NSMenuItem!
    var adbItem: NSMenuItem!
    var actionItems: [NSMenuItem] = []
    let queue = DispatchQueue(label: "local.tv-volume-keys.transport", qos: .userInitiated)
    var timer: Timer?
    var heldKeys = Set<VolumeAction>()
    var enabled = true
    var transportReady = false
    var mode = ControlTransport(rawValue: UserDefaults.standard.string(forKey: "controlTransport") ?? "cec") ?? .cec
    var adbConfiguration = ADBConfiguration.load()
    var probing = false
    var lastProbe = Date.distantPast
    var connectionRevision = 0
    var connectionError = ""
    var busy = false
    var lastAccepted = Date.distantPast
    var keyCount = 0, commandCount = 0
    var cecCount = 0, adbCount = 0
    var lastAction = "", lastError = ""
    var lastSaved = Data()
    let statusURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TVVolumeKeysPreview/status.json")
    func applicationDidFinishLaunching(_ note: Notification) {
        let legacyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.linghe.tv-volume-keys").contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if legacyRunning {
            let alert = NSAlert()
            alert.messageText = tr("Another TV volume helper is running", "已有电视音量工具正在运行")
            alert.informativeText = tr("Quit the other helper before starting this preview. Your current working version is preserved.", "请先退出另一版本，再运行本预览版。现有可用版本保持不变。")
            alert.runModal(); NSApplication.shared.terminate(nil); return
        }
        enabled = !UserDefaults.standard.bool(forKey: "paused")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "TV"
        item.button?.imagePosition = .imageLeading
        item.button?.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: tr("TV Volume Keys", "电视音量键"))
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem = NSMenuItem(title: tr("TV Volume Keys", "电视音量键"), action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        permissionItem = NSMenuItem(title: tr("Allow Keyboard Control…", "允许键盘控制…"), action: #selector(permissions), keyEquivalent: "")
        permissionItem.target = self; menu.addItem(permissionItem)
        menu.addItem(.separator())
        for (title, selector) in [(tr("Volume Up", "调高音量"), #selector(up)), (tr("Volume Down", "调低音量"), #selector(down)), (tr("Mute / Unmute", "静音 / 取消静音"), #selector(mute))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self; actionItems.append(entry); menu.addItem(entry)
        }
        menu.addItem(.separator())
        cecItem = NSMenuItem(title: tr("HDMI-CEC (Default)", "HDMI-CEC（默认）"), action: #selector(selectCEC), keyEquivalent: "")
        cecItem.target = self; menu.addItem(cecItem)
        adbItem = NSMenuItem(title: tr("ADB Compatibility Mode", "ADB 兼容模式"), action: #selector(selectADB), keyEquivalent: "")
        adbItem.target = self; menu.addItem(adbItem)
        let configure = NSMenuItem(title: tr("Configure ADB Connection…", "配置 ADB 连接…"), action: #selector(configureADB), keyEquivalent: "")
        configure.target = self; menu.addItem(configure)
        menu.addItem(.separator())
        toggleItem = NSMenuItem(title: tr("Use Keyboard Volume Keys", "使用键盘音量键"), action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self; menu.addItem(toggleItem)
        let login = NSMenuItem(title: tr("Open at Login", "登录时启动"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let about = NSMenuItem(title: tr("About TV Volume Keys…", "关于电视音量键…"), action: #selector(about), keyEquivalent: "")
        about.target = self; menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: tr("Quit", "退出"), action: #selector(quitApp), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func refresh() {
        if mode == .cec {
            transportReady = false; connectionError = ""
            if defaultOutputIsTV() {
                do { _ = try CEC(); transportReady = true }
                catch { connectionError = error.localizedDescription }
            }
        } else if adbConfiguration == nil {
            transportReady = false; connectionError = tr("Configure the ADB connection", "请先配置 ADB 连接")
        } else if defaultOutputIsTV(), !probing, !busy, Date().timeIntervalSince(lastProbe) >= 8 {
            probing = true; lastProbe = Date()
            let revision = connectionRevision, config = adbConfiguration!
            if !transportReady { connectionError = tr("Checking ADB connection…", "正在检查 ADB 连接…") }
            queue.async { [weak self] in
                var probeError = ""
                do { try ADBTransport(config).probe() } catch { probeError = error.localizedDescription }
                DispatchQueue.main.async {
                    guard let self, self.connectionRevision == revision else { return }
                    self.probing = false; self.transportReady = probeError.isEmpty; self.connectionError = probeError
                    if probeError.isEmpty { self.lastError = "" }
                    self.refresh()
                }
            }
        }
        if !AXIsProcessTrusted(), let old = tap {
            CGEvent.tapEnable(tap: old, enable: false)
            CFMachPortInvalidate(old); tap = nil
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            source = nil
        }
        if enabled && AXIsProcessTrusted() && tap == nil { installTap() }
        let active = tap != nil && AXIsProcessTrusted() && enabled && transportReady && defaultOutputIsTV()
        stateItem.title = !defaultOutputIsTV() ? tr("Select one HDMI display for sound", "请选择单个 HDMI 屏幕输出声音") : !transportReady ? connectionError : !enabled ? tr("Keyboard control is paused", "键盘控制已暂停") : !AXIsProcessTrusted() ? tr("Allow keyboard access", "等待键盘权限") : tap == nil ? tr("Keyboard access is not ready", "键盘连接未就绪") : lastError.isEmpty ? (mode == .adb ? tr("Keyboard controls the TV via ADB", "键盘已通过 ADB 连接电视") : tr("Keyboard controls the TV via CEC", "键盘已通过 CEC 连接电视")) : lastError
        item.button?.toolTip = tr("TV Volume Keys · ", "电视音量键 · ") + stateItem.title
        permissionItem.isHidden = AXIsProcessTrusted() && tap != nil
        toggleItem.state = enabled ? .on : .off
        cecItem.state = mode == .cec ? .on : .off; adbItem.state = mode == .adb ? .on : .off
        for entry in actionItems { entry.isEnabled = defaultOutputIsTV() && transportReady }
        var state: [String: Any] = ["accessibilityGranted": AXIsProcessTrusted(),
            "eventTapInstalled": tap != nil, "enabled": enabled, "activeForTV": active,
            "defaultOutputIsTV": defaultOutputIsTV(), "transport": mode.rawValue, "transportReady": transportReady,
            "cecAvailable": mode == .cec && transportReady, "keyPressesObserved": keyCount,
            "volumeCommandsCompleted": commandCount, "cecCommandsCompleted": cecCount, "adbCommandsCompleted": adbCount,
            "version": AppVersion.full, "lastAction": lastAction, "lastError": lastError]
        if let stable = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), stable != lastSaved {
            lastSaved = stable; state["updatedAt"] = ISO8601DateFormatter().string(from: Date())
            try? FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: statusURL, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: statusURL.path)
            }
        }
    }
    func installTap() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1) << 14, callback: callback, userInfo: pointer) else {
            lastError = tr("Allow TV Volume Keys in Accessibility", "请在辅助功能中允许电视音量键"); return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lastError = ""
    }
    func handle(_ action: VolumeAction, fromKey: Bool = false) {
        guard defaultOutputIsTV(), transportReady else { return }
        if fromKey { keyCount += 1 }
        // Drop pending repeats instead of accumulating volume changes after release.
        guard !busy, !probing, Date().timeIntervalSince(lastAccepted) >= 0.10 else { return }
        busy = true; lastAccepted = Date()
        let selectedMode = mode, config = adbConfiguration, revision = connectionRevision
        queue.async { [weak self] in
            var failure = ""
            do {
                guard defaultOutputIsTV() else { throw Failure.message(tr("Audio output changed; command skipped", "声音输出已切换，已跳过")) }
                if selectedMode == .cec { try CEC().press(action) }
                else if let config { try ADBTransport(config).press(action) }
                else { throw Failure.message(tr("Configure the ADB connection", "请先配置 ADB 连接")) }
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                guard self.connectionRevision == revision else { self.refresh(); return }
                self.lastError = failure
                if failure.isEmpty {
                    self.commandCount += 1; self.lastAction = action.rawValue
                    if selectedMode == .adb { self.adbCount += 1 } else { self.cecCount += 1 }
                } else if selectedMode == .adb {
                    self.transportReady = false; self.connectionError = failure; self.lastProbe = .distantPast
                }
                self.refresh()
            }
        }
    }
    @objc func up() { handle(.up) }
    @objc func down() { handle(.down) }
    @objc func mute() { handle(.mute) }
    @objc func toggle() {
        enabled.toggle(); UserDefaults.standard.set(!enabled, forKey: "paused"); refresh()
    }
    @objc func permissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { try SMAppService.mainApp.register() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { lastError = error.localizedDescription; refresh() }
    }
    @objc func about() {
        let alert = NSAlert()
        alert.messageText = "TV Volume Keys · " + AppVersion.full
        alert.informativeText = tr("Free and open source. HDMI-CEC or an explicitly configured ADB connection.\n\nOne external HDMI display · Apple silicon · macOS 14+\nADB requires official Platform Tools and TV authorization.", "免费开源，支持 HDMI-CEC 或明确配置的 ADB 连接。\n\n单个外接 HDMI 屏幕 · Apple 芯片 · macOS 14+\nADB 需要官方 Platform Tools 和电视授权。")
        alert.addButton(withTitle: tr("Done", "完成"))
        alert.addButton(withTitle: tr("Licenses", "许可证"))
        if alert.runModal() == .alertSecondButtonReturn,
           let url = Bundle.main.url(forResource: "LICENSES", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ note: Notification) {
        ExecutableRunner.cancelAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
    }
}

if CommandLine.arguments.contains("--self-test") {
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
    check(VolumeAction.decode(subtype: 8, data: (0 << 16) | 0x0a00)?.0 == .up, "volume up")
    check(VolumeAction.decode(subtype: 8, data: (1 << 16) | 0x0a01)?.0 == .down, "held down")
    check(VolumeAction.decode(subtype: 8, data: (7 << 16) | 0x0b00)?.1 == false, "mute release")
    check(VolumeAction.decode(subtype: 8, data: (16 << 16) | 0x0a00) == nil, "play/pause must pass through")
    check(VolumeAction.decode(subtype: 1, data: 0x0a00) == nil, "unrelated events must pass through")
    check(VolumeAction.decode(subtype: 8, data: 0x0100) == nil, "invalid key state")
    check(VolumeAction.up.cec == 0x41 && VolumeAction.down.cec == 0x42 && VolumeAction.mute.cec == 0x43, "CEC mapping")
    check(shouldCaptureVolume(enabled: true, cec: true, hdmi: true, modifiers: []), "ready TV")
    check(!shouldCaptureVolume(enabled: true, cec: true, hdmi: false, modifiers: []), "headphones pass through")
    check(!shouldCaptureVolume(enabled: true, cec: false, hdmi: true, modifiers: []), "unsupported CEC passes through")
    check(!shouldCaptureVolume(enabled: false, cec: true, hdmi: true, modifiers: []), "paused passes through")
    check(!shouldCaptureVolume(enabled: true, cec: true, hdmi: true, modifiers: .maskAlternate), "Option-volume stays native")
    check(!shouldCaptureVolume(enabled: true, cec: true, hdmi: true, modifiers: .maskCommand), "Command-volume stays native")
    check(!shouldCaptureVolume(enabled: true, cec: true, hdmi: true, modifiers: .maskControl), "Control-volume stays native")
    print("14 event-routing checks passed; no CEC commands sent")
    try runTransportTests()
} else if let index = CommandLine.arguments.firstIndex(of: "--configure-adb") {
    guard index + 1 < CommandLine.arguments.count,
          let pathIndex = CommandLine.arguments.firstIndex(of: "--adb-path"), pathIndex + 1 < CommandLine.arguments.count else {
        fputs("Usage: --configure-adb PRIVATE_IP:PORT --adb-path /absolute/path/to/adb\n", stderr); exit(2)
    }
    do {
        let config = try ADBTransport.configure(executable: CommandLine.arguments[pathIndex + 1], serial: CommandLine.arguments[index + 1])
        try config.save(); UserDefaults.standard.set("adb", forKey: "controlTransport")
        print("ADB connection verified and saved for this user. Quit and reopen the app to apply CLI configuration. No volume command sent.")
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--use-cec") {
    UserDefaults.standard.set("cec", forKey: "controlTransport")
    print("CEC selected. No volume command sent.")
} else if let index = CommandLine.arguments.firstIndex(of: "--send") {
    guard index + 1 < CommandLine.arguments.count, let action = VolumeAction(rawValue: CommandLine.arguments[index + 1]) else { exit(2) }
    do {
        guard defaultOutputIsTV() else { throw Failure.message("Select a single HDMI output first") }
        if UserDefaults.standard.string(forKey: "controlTransport") == "adb" {
            guard let config = ADBConfiguration.load() else { throw Failure.message("Configure ADB before sending") }
            try ADBTransport(config).press(action)
        } else { try CEC().press(action) }
        print("Volume command completed.")
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if CommandLine.arguments.contains("--diagnose") {
    var status: [String: Any] = ["processAccessibilityTrusted": AXIsProcessTrusted(), "defaultOutputIsTV": defaultOutputIsTV(), "externalDisplayCount": externalDisplayCount()]
    do { let cec = try CEC(); status["cecAvailable"] = true; status["sourceAddress"] = cec.source }
    catch { status["cecAvailable"] = false; status["error"] = error.localizedDescription }
    let selected = UserDefaults.standard.string(forKey: "controlTransport") ?? "cec"
    status["selectedTransport"] = selected
    if selected == "adb", let config = ADBConfiguration.load() {
        do { try ADBTransport(config).probe(reconnect: false); status["adbAvailable"] = true }
        catch { status["adbAvailable"] = false; status["adbError"] = error.localizedDescription }
    }
    let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = VolumeKeys()
    app.delegate = delegate
    app.run()
}
