import Foundation

func runTransportTests() throws {
    func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.message("Transport test failed: " + message) }
    }
    final class Fake: ADBCommandRunning {
        var identity = "0123456789abcdef"
        var transportResult = CommandResult(status: 0, output: "9")
        var calls: [[String]] = []
        func run(_ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
            calls.append(arguments)
            if arguments.last == "get-transport-id" { return transportResult }
            if arguments.last == "android_id" { return CommandResult(status: 0, output: identity) }
            return CommandResult(status: 0, output: "")
        }
    }
    try check(ADBConfiguration.validSerial("192.168.1.50:5555"), "private IPv4")
    try check(ADBConfiguration.validSerial("10.0.0.2:40000"), "explicit private port")
    for invalid in ["1.1.1.1:5555", "127.0.0.1:5555", "tv.local:5555", "192.168.1.2:0", "192.168.1.2:65536", "192.168.1.2:5555;touch", "192.168.01.2:5555"] {
        try check(!ADBConfiguration.validSerial(invalid), "reject invalid network target")
    }
    let fake = Fake()
    let config = ADBConfiguration(executable: "/test/adb", serial: "192.168.1.50:5555",
                                  identityHash: try ADBTransport.hashIdentity(fake.identity), model: "Test TV")
    let client = ADBTransport(config, runner: fake)
    try client.press(.down, outputCheck: { true })
    try check(fake.calls.last == ["-t", "9", "shell", "cmd", "media_session", "volume", "--stream", "3", "--adj", "lower", "--show"], "fast fixed volume command on verified transport")
    try client.press(.up, outputCheck: { true })
    try check(fake.calls.last?.contains("raise") == true, "volume up mapping")
    try client.press(.mute, outputCheck: { true })
    try check(fake.calls.last == ["-t", "9", "shell", "input", "keyevent", "164"], "speaker volume mute key")
    fake.calls.removeAll()
    do { try client.press(.down, outputCheck: { false }); throw Failure.message("Headphones were accepted") }
    catch { try check(!fake.calls.contains { $0.contains("media_session") || $0.contains("input") }, "headphones cannot send controls") }
    fake.calls.removeAll(); fake.identity = "fedcba9876543210"
    do { try client.press(.down, outputCheck: { true }); throw Failure.message("Changed identity was accepted") }
    catch { try check(!fake.calls.contains { $0.contains("media_session") || $0.contains("input") }, "changed TV cannot receive controls") }
    fake.calls.removeAll(); fake.identity = "0123456789abcdef"
    fake.transportResult = CommandResult(status: 1, output: "error: device unauthorized")
    do { try client.press(.down, outputCheck: { true }); throw Failure.message("Unauthorized TV was accepted") }
    catch {
        try check(error.localizedDescription.contains("debugging") || error.localizedDescription.contains("调试"), "actionable TV authorization error")
        try check(!fake.calls.contains { $0.contains("media_session") || $0.contains("input") }, "unauthorized TV receives no control")
    }
    let output = try ExecutableRunner("/usr/bin/printf").run(["fixture-output"], timeout: 1)
    try check(output.status == 0 && output.output == "fixture-output", "bounded process output")
    let start = Date()
    do { _ = try ExecutableRunner("/bin/sleep").run(["5"], timeout: 0.05); throw Failure.message("Timeout was not enforced") }
    catch { try check(Date().timeIntervalSince(start) < 2, "timed-out child is terminated") }
    print("ADB target, identity, transport pinning, action mapping, HDMI gating and process-timeout checks passed; no TV commands sent")
}
