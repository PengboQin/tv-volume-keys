import AppKit

extension VolumeKeys {
    func choose(_ transport: ControlTransport) {
        connectionRevision += 1; probing = false; transportReady = false
        mode = transport; lastProbe = .distantPast; lastError = ""
        UserDefaults.standard.set(transport.rawValue, forKey: "controlTransport")
        refresh()
    }
    @objc func selectCEC() { choose(.cec) }
    @objc func selectADB() {
        if adbConfiguration == nil { configureADB() } else { choose(.adb) }
    }
    @objc func configureADB() {
        adbConfiguration = ADBConfiguration.load()
        let alert = NSAlert()
        alert.messageText = tr("ADB compatibility connection", "ADB 兼容连接")
        alert.informativeText = tr("Use your TV's private IPv4 address and network-debugging port. The TV must authorize this Mac. The connection is bound to that TV's identity.", "填写电视的局域网 IPv4 地址和网络调试端口，并在电视上允许这台 Mac。保存后会绑定电视身份。")
        alert.addButton(withTitle: tr("Verify and Use ADB", "验证并使用 ADB"))
        alert.addButton(withTitle: tr("Cancel", "取消"))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let addressLabel = NSTextField(labelWithString: tr("TV address and port", "电视地址与端口"))
        addressLabel.frame = NSRect(x: 0, y: 96, width: 420, height: 20)
        let address = NSTextField(string: adbConfiguration?.serial ?? "")
        address.placeholderString = "192.168.1.50:5555"; address.frame = NSRect(x: 0, y: 68, width: 420, height: 24)
        let pathLabel = NSTextField(labelWithString: tr("Official adb executable", "官方 adb 可执行文件路径"))
        pathLabel.frame = NSRect(x: 0, y: 35, width: 420, height: 20)
        let path = NSTextField(string: adbConfiguration?.executable ?? ADBConfiguration.suggestedExecutable())
        path.frame = NSRect(x: 0, y: 5, width: 420, height: 24)
        for child in [addressLabel, address, pathLabel, path] { view.addSubview(child) }
        alert.accessoryView = view; alert.window.initialFirstResponder = address
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let serial = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = path.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionRevision += 1
        let revision = connectionRevision
        probing = true; transportReady = false; connectionError = tr("Verifying ADB connection…", "正在验证 ADB 连接…")
        queue.async { [weak self] in
            var result: ADBConfiguration?, failure = ""
            do { result = try ADBTransport.configure(executable: executable, serial: serial) }
            catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self, self.connectionRevision == revision else { return }
                self.probing = false
                if let result {
                    do { try result.save(); self.adbConfiguration = result; self.choose(.adb) }
                    catch { self.showConnectionError(error.localizedDescription) }
                } else { self.showConnectionError(failure) }
            }
        }
    }
    private func showConnectionError(_ message: String) {
        lastError = message; lastProbe = .distantPast; refresh()
        let alert = NSAlert(); alert.messageText = tr("Connection not saved", "连接未保存")
        alert.informativeText = message; alert.runModal()
    }
}
