import AppKit
import ApplicationServices
import CoreAudio
import IOKit
import ServiceManagement

// TV Volume Keys. AUX CEC layout cross-checked with MacTV (MIT); see THIRD_PARTY_NOTICES.
// Shared volume decoding and HDMI routing; no output changes.
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


func shouldCaptureVolume(enabled: Bool, cec: Bool, hdmi: Bool, modifiers: CGEventFlags) -> Bool {
    enabled && cec && hdmi && modifiers.intersection([.maskAlternate, .maskCommand, .maskControl]).isEmpty
}
