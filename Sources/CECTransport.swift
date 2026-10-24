import Foundation
import IOKit

// CEC AUX layout adapted from MacTV (MIT); see THIRD_PARTY_NOTICES.md.

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
