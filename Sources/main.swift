import AppKit
import ApplicationServices
import CoreAudio
import IOKit
import ServiceManagement

// TV Volume Keys. AUX CEC layout cross-checked with MacTV (MIT); see THIRD_PARTY_NOTICES.
// No display-mode, audio-route, network, input-source, or power operations.
enum VolumeAction: String {
    case up, down, mute
    var cec: UInt8 { self == .up ? 0x41 : self == .down ? 0x42 : 0x43 }
    static func decode(subtype: Int, data: Int) -> (VolumeAction, Bool)? {
        guard subtype == 8 else { return nil }
        let key = (data >> 16) & 0xffff, state = (data >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        let action: VolumeAction
        switch key { case 0: action = .up; case 1: action = .down; case 7: action = .mute; default: return nil }
        return (action, state == 0x0a)
    }
}

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

func externalDisplayCount() -> Int {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 32 else { return -1 }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return -1 }
    return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
}

func tr(_ english: String, _ chinese: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}

func defaultOutputIsTV() -> Bool {
    // First preview supports one external screen; refuse ambiguous routing.
    guard externalDisplayCount() == 1 else { return false }
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &device) == noErr else { return false }
    var transport: UInt32 = 0
    a.mSelector = kAudioDevicePropertyTransportType
    size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &transport) == noErr,
          transport == kAudioDeviceTransportTypeHDMI else { return false }
    a.mSelector = kAudioObjectPropertyName
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &name) == noErr,
          let name else { return false }
    _ = name.takeRetainedValue()
    return true
}

final class CEC {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    typealias Read = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    typealias Write = @convention(c) (UnsafeMutableRawPointer, UInt32, UnsafeRawPointer, UInt32) -> Int32
    static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    let device: UnsafeMutableRawPointer
    let get: Read
    let put: Write
    let source: UInt8
    init() throws {
        guard let library = Self.library,
              let cp = dlsym(library, "IODPDeviceCreateWithService"),
              let rp = dlsym(library, "IODPDeviceReadDPCD"),
              let wp = dlsym(library, "IODPDeviceWriteDPCD") else { throw Failure.message(tr("CEC is unavailable on this system", "系统 CEC 接口不可用")) }
        let create = unsafeBitCast(cp, to: Create.self)
        get = unsafeBitCast(rp, to: Read.self)
        put = unsafeBitCast(wp, to: Write.self)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPDPDeviceProxy"), &iterator) == 0 else { throw Failure.message(tr("Unable to inspect HDMI", "无法读取 HDMI 连接")) }
        defer { IOObjectRelease(iterator) }
        var matches: [UnsafeMutableRawPointer] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let d = create(kCFAllocatorDefault, service) else { continue }
            var cap: UInt8 = 0
            if get(d, 0x3000, &cap, 1) == 0 && cap & 1 != 0 { matches.append(d) }
            else { Unmanaged<AnyObject>.fromOpaque(d).release() }
        }
        guard matches.count == 1 else {
            matches.forEach { Unmanaged<AnyObject>.fromOpaque($0).release() }
            throw Failure.message(tr("One compatible CEC connection is required", "需要唯一的 HDMI-CEC 连接"))
        }
        let d = matches[0]
        var control: UInt8 = 0, mask: UInt16 = 0
        guard get(d, 0x3001, &control, 1) == 0 && control & 1 != 0,
              get(d, 0x300e, &mask, 2) == 0,
              let address = [4, 8, 11].first(where: { mask & (1 << $0) != 0 }) else {
            Unmanaged<AnyObject>.fromOpaque(d).release()
            throw Failure.message(tr("Enable CEC on the TV and check the HDMI connection", "CEC 未启用或 Mac 尚无播放地址"))
        }
        device = d; source = UInt8(address)
    }
    deinit { Unmanaged<AnyObject>.fromOpaque(device).release() }
    func byte(_ address: UInt32) throws -> UInt8 {
        guard [UInt32(0x3003), 0x3004].contains(address) else { throw Failure.message(tr("Unsupported register read", "不允许的读取")) }
        var b: UInt8 = 0
        guard get(device, address, &b, 1) == 0 else { throw Failure.message(tr("CEC read failed", "CEC 读取失败")) }
        return b
    }
    func write(_ address: UInt32, _ data: [UInt8]) throws {
        guard ((address == 0x3003 || address == 0x3004) && data.count == 1) ||
                (address == 0x3020 && (2...3).contains(data.count)) else { throw Failure.message(tr("Unsupported register write", "不允许的写入")) }
        let result = data.withUnsafeBytes { put(device, address, $0.baseAddress!, UInt32(data.count)) }
        guard result == 0 else { throw Failure.message(tr("CEC write failed", "CEC 写入失败")) }
    }
    func send(_ payload: [UInt8]) throws {
        guard [[UInt8(0x44), 0x41], [0x44, 0x42], [0x44, 0x43], [0x45]].contains(payload) else { throw Failure.message(tr("Only volume commands are allowed", "只允许音量操作")) }
        let frame = [source << 4] + payload
        let deadline = Date().addingTimeInterval(1)
        while try byte(0x3003) & 0x80 != 0 {
            guard Date() < deadline else { throw Failure.message(tr("CEC is busy; command not sent", "CEC 正忙，本次未发送")) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        try write(0x3004, [0xf0])
        try write(0x3020, frame)
        let descriptor = UInt8(frame.count - 1)
        try write(0x3003, [descriptor | 0x90])
        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            let flags = try byte(0x3004)
            if flags & 0xe0 != 0 {
                try write(0x3004, [flags & 0xf0])
                throw Failure.message(tr("TV did not confirm the volume command", "电视未确认音量指令"))
            }
            if flags & 0x10 != 0 { try write(0x3004, [0x10]); return }
            if try byte(0x3003) == descriptor | 0x10 { return }
            Thread.sleep(forTimeInterval: 0.001)
        }
        throw Failure.message(tr("CEC timed out; no automatic retry", "CEC 超时，本次不自动重发"))
    }
    func press(_ action: VolumeAction) throws {
        do { try send([0x44, action.cec]) }
        catch { try? send([0x45]); throw error }
        Thread.sleep(forTimeInterval: 0.06)
        do { try send([0x45]) }
        catch { try? send([0x45]); throw error } // Release-only retry cannot raise volume.
    }
}

func shouldCaptureVolume(enabled: Bool, cec: Bool, hdmi: Bool, modifiers: CGEventFlags) -> Bool {
    enabled && cec && hdmi && modifiers.intersection([.maskAlternate, .maskCommand, .maskControl]).isEmpty
}

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
    guard shouldCaptureVolume(enabled: app.enabled, cec: app.cecReady,
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
    var actionItems: [NSMenuItem] = []
    let queue = DispatchQueue(label: "local.tv-volume-keys.cec", qos: .userInitiated)
    var timer: Timer?
    var heldKeys = Set<VolumeAction>()
    var enabled = true
    var cecReady = false
    var connectionError = ""
    var busy = false
    var lastAccepted = Date.distantPast
    var keyCount = 0, commandCount = 0
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
        cecReady = false
        connectionError = ""
        if defaultOutputIsTV() {
            do { _ = try CEC(); cecReady = true }
            catch { connectionError = error.localizedDescription }
        }
        if !AXIsProcessTrusted(), let old = tap {
            CGEvent.tapEnable(tap: old, enable: false)
            CFMachPortInvalidate(old); tap = nil
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            source = nil
        }
        if enabled && AXIsProcessTrusted() && tap == nil { installTap() }
        let active = tap != nil && AXIsProcessTrusted() && enabled && cecReady && defaultOutputIsTV()
        stateItem.title = !defaultOutputIsTV() ? tr("Select one HDMI display for sound", "请选择单个 HDMI 屏幕输出声音") : !cecReady ? connectionError : !enabled ? tr("Keyboard control is paused", "键盘控制已暂停") : !AXIsProcessTrusted() ? tr("Allow keyboard access", "等待键盘权限") : !defaultOutputIsTV() ? tr("Select the HDMI sound output", "声音输出未选择电视") : tap == nil ? tr("Keyboard access is not ready", "键盘连接未就绪") : lastError.isEmpty ? tr("Keyboard controls the TV", "键盘已连接电视") : lastError
        item.button?.toolTip = tr("TV Volume Keys · ", "电视音量键 · ") + stateItem.title
        permissionItem.isHidden = AXIsProcessTrusted() && tap != nil
        toggleItem.state = enabled ? .on : .off
        for entry in actionItems { entry.isEnabled = defaultOutputIsTV() && cecReady }
        var state: [String: Any] = ["accessibilityGranted": AXIsProcessTrusted(),
            "eventTapInstalled": tap != nil, "enabled": enabled, "activeForTV": active,
            "defaultOutputIsTV": defaultOutputIsTV(), "cecAvailable": cecReady, "keyPressesObserved": keyCount,
            "cecCommandsCompleted": commandCount, "lastAction": lastAction, "lastError": lastError]
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
        guard defaultOutputIsTV() else { return }
        if fromKey { keyCount += 1 }
        // Drop pending repeats instead of accumulating volume changes after release.
        guard !busy && Date().timeIntervalSince(lastAccepted) >= 0.10 else { return }
        busy = true; lastAccepted = Date()
        queue.async { [weak self] in
            var failure = ""
            do {
                guard defaultOutputIsTV() else { throw Failure.message(tr("Audio output changed; command skipped", "声音输出已切换，已跳过")) }
                try CEC().press(action)
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false; self.lastError = failure
                if failure.isEmpty { self.commandCount += 1; self.lastAction = action.rawValue }
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
        alert.messageText = "TV Volume Keys · 0.1.0 preview"
        alert.informativeText = tr("Free and open source. Control a compatible HDMI TV with your Mac volume keys.\n\nOne external display · Apple silicon · macOS 14+\nCompatibility depends on the HDMI connection. This preview is not notarized.", "免费开源，用 Mac 音量键控制兼容的 HDMI 电视。\n\n单个外接屏幕 · Apple 芯片 · macOS 14+\n兼容性取决于 HDMI 连接。本预览包尚未公证。")
        alert.addButton(withTitle: tr("Done", "完成"))
        alert.addButton(withTitle: tr("Licenses", "许可证"))
        if alert.runModal() == .alertSecondButtonReturn,
           let url = Bundle.main.url(forResource: "LICENSES", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ note: Notification) {
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
} else if CommandLine.arguments.contains("--diagnose") {
    var status: [String: Any] = ["processAccessibilityTrusted": AXIsProcessTrusted(), "defaultOutputIsTV": defaultOutputIsTV(), "externalDisplayCount": externalDisplayCount()]
    do { let cec = try CEC(); status["cecAvailable"] = true; status["sourceAddress"] = cec.source }
    catch { status["cecAvailable"] = false; status["error"] = error.localizedDescription }
    let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = VolumeKeys()
    app.delegate = delegate
    app.run()
}
