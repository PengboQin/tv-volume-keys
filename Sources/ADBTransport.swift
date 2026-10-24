import Foundation
import CryptoKit
import Darwin

enum ControlTransport: String, Codable { case cec, adb }

struct ADBConfiguration: Codable {
    let executable: String
    let serial: String
    let identityHash: String
    let model: String

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TVVolumeKeysPreview/adb-connection.json")
    }
    static func validSerial(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        var bytes: [Int] = []
        for part in octets {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let byte = Int(part), (0...255).contains(byte), String(byte) == part else { return false }
            bytes.append(byte)
        }
        return bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 192 && bytes[1] == 168)
    }
    static func load() -> ADBConfiguration? {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Self.self, from: data),
              validSerial(value.serial), value.executable.hasPrefix("/"), value.identityHash.count == 64 else { return nil }
        return value
    }
    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let temporary = Self.file.deletingLastPathComponent().appendingPathComponent(".connection-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(self),
                            attributes: [.posixPermissions: 0o600]) else { throw Failure.message(tr("Unable to save connection", "无法保存连接")) }
        defer { try? fm.removeItem(at: temporary) }
        guard rename(temporary.path, Self.file.path) == 0 else { throw Failure.message(tr("Unable to save connection", "无法保存连接")) }
    }
    static func suggestedExecutable() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/tools/platform-tools/adb", home + "/.local/platform-tools/adb",
                home + "/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
}

struct CommandResult { let status: Int32; let output: String }
protocol ADBCommandRunning { func run(_ arguments: [String], timeout: TimeInterval) throws -> CommandResult }

// Anonymous, owner-only output file avoids pipe backpressure and inherited-pipe hangs.
final class ExecutableRunner: ADBCommandRunning {
    private static let lock = NSLock()
    private static var active: [ObjectIdentifier: Process] = [:]
    let executable: String
    init(_ executable: String) { self.executable = executable }
    static func cancelAll() {
        lock.lock(); let processes = Array(active.values); lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
    }
    func run(_ arguments: [String], timeout: TimeInterval = 3) throws -> CommandResult {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw Failure.message(tr("Choose the official adb executable", "请选择官方 adb 可执行文件"))
        }
        var pattern = Array((NSTemporaryDirectory() + "tv-volume-output.XXXXXX").utf8CString)
        let fd = mkstemp(&pattern)
        guard fd >= 0 else { throw Failure.message(tr("Unable to capture adb output", "无法读取 adb 结果")) }
        _ = unlink(pattern)
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { throw Failure.message(tr("Unable to launch adb", "无法启动 adb")) }
        Self.lock.lock(); Self.active[ObjectIdentifier(process)] = process; Self.lock.unlock()
        defer { Self.lock.lock(); Self.active.removeValue(forKey: ObjectIdentifier(process)); Self.lock.unlock() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.25) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw Failure.message(tr("ADB timed out; command was not retried", "ADB 超时，本次不自动重发"))
        }
        try output.seek(toOffset: 0)
        let data = try output.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384 else { throw Failure.message(tr("Unexpected adb response", "ADB 返回内容异常")) }
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

final class ADBTransport {
    let configuration: ADBConfiguration
    let runner: ADBCommandRunning
    init(_ configuration: ADBConfiguration, runner: ADBCommandRunning? = nil) {
        self.configuration = configuration
        self.runner = runner ?? ExecutableRunner(configuration.executable)
    }
    static func hashIdentity(_ value: String) throws -> String {
        guard (8...64).contains(value.count), value.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw Failure.message(tr("TV identity is unavailable", "无法读取电视身份"))
        }
        return SHA256.hash(data: Data(value.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func checked(_ args: [String], timeout: TimeInterval = 3) throws -> String {
        let result = try runner.run(args, timeout: timeout)
        guard result.status == 0 else {
            if result.output.lowercased().contains("unauthorized") || result.output.lowercased().contains("authentication") {
                throw Failure.message(tr("Allow this Mac's debugging request on the TV, then retry", "请在电视上允许这台 Mac 的调试请求，然后重试"))
            }
            throw Failure.message(tr("ADB is unavailable; check TV authorization and the network", "ADB 不可用，请检查电视授权与网络"))
        }
        return result.output
    }
    private func transportID() throws -> String {
        let id = try checked(["-s", configuration.serial, "get-transport-id"])
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(id) != nil else {
            throw Failure.message(tr("TV connection is not ready. Approve any debugging request on the TV", "电视连接未就绪；若有调试授权弹窗，请在电视上允许"))
        }
        return id
    }
    private func verifiedID() throws -> String {
        let id = try transportID()
        let identity = try checked(["-t", id, "shell", "settings", "get", "secure", "android_id"])
        guard try Self.hashIdentity(identity) == configuration.identityHash else {
            throw Failure.message(tr("TV identity changed; configure the connection again", "电视身份已变化，请重新配置连接"))
        }
        return id
    }
    static func configure(executable: String, serial: String) throws -> ADBConfiguration {
        guard ADBConfiguration.validSerial(serial) else {
            throw Failure.message(tr("Use a private IPv4 address and port, e.g. 192.168.1.50:5555", "请填写局域网 IPv4 和端口，例如 192.168.1.50:5555"))
        }
        let runner = ExecutableRunner(executable)
        let version = try runner.run(["version"], timeout: 3)
        guard version.status == 0, version.output.contains("Android Debug Bridge version") else {
            throw Failure.message(tr("This is not an adb executable", "所选文件不是 adb 可执行程序"))
        }
        let connected = try runner.run(["connect", serial], timeout: 6)
        guard connected.status == 0 else { throw Failure.message(tr("Unable to connect; check the TV and network", "无法连接，请检查电视与网络")) }
        let placeholder = ADBConfiguration(executable: executable, serial: serial, identityHash: "", model: "")
        let client = ADBTransport(placeholder, runner: runner), id = try client.transportID()
        let identity = try client.checked(["-t", id, "shell", "settings", "get", "secure", "android_id"])
        let model = try client.checked(["-t", id, "shell", "getprop", "ro.product.model"])
        let capability = try runner.run(["-t", id, "shell", "cmd", "media_session", "help"], timeout: 3)
        guard capability.output.contains("--adj"), capability.output.contains("--stream") else {
            throw Failure.message(tr("This TV does not expose the supported media-volume interface", "这台电视未提供支持的媒体音量接口"))
        }
        return ADBConfiguration(executable: executable, serial: serial,
                                identityHash: try hashIdentity(identity), model: String(model.filter { !$0.isNewline }.prefix(80)))
    }
    func probe(reconnect: Bool = true) throws {
        guard ADBConfiguration.validSerial(configuration.serial) else { throw Failure.message(tr("Invalid saved connection", "保存的连接无效")) }
        do { _ = try verifiedID(); return }
        catch {
            guard reconnect else { throw error }
            _ = try checked(["connect", configuration.serial], timeout: 4)
            _ = try verifiedID()
        }
    }
    func press(_ action: VolumeAction, outputCheck: () -> Bool = defaultOutputIsTV) throws {
        let id = try verifiedID()
        guard outputCheck() else { throw Failure.message(tr("Audio output changed; command skipped", "声音输出已切换，已跳过")) }
        // -t pins this verified live transport, not a potentially reassigned DHCP address.
        let args: [String]
        switch action {
        case .up, .down:
            args = ["-t", id, "shell", "cmd", "media_session", "volume", "--stream", "3", "--adj", action == .up ? "raise" : "lower", "--show"]
        case .mute:
            args = ["-t", id, "shell", "input", "keyevent", "164"]
        }
        _ = try checked(args)
    }
}
