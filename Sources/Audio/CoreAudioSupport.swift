// Thin typed wrappers around the Core Audio HAL property API.
//
// Parts of this file (the property read patterns and the PID-translation and
// tap-format helpers) are adapted from AudioCap by Guilherme Rambo,
// https://github.com/insidegui/AudioCap, BSD-2-Clause. See LICENSE.

import Foundation
import CoreAudio
import AudioToolbox

struct CoreAudioError: Error, CustomStringConvertible {
    let message: String
    let status: OSStatus
    var description: String { "\(message) (OSStatus \(status))" }
}

enum CA {

    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: - Generic property reads

    /// Only ever used with plain-old-data property types (integers, Doubles,
    /// AudioStreamBasicDescription) — never reference types.
    static func read<T>(_ objectID: AudioObjectID,
                        _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        into value: inout T) -> OSStatus {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutableBytes(of: &value) { buf in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buf.baseAddress!)
        }
    }

    static func readArray<T>(_ objectID: AudioObjectID,
                             _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             of type: T.Type) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        var out = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        let err = out.withUnsafeMutableBytes { buf in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buf.baseAddress!)
        }
        guard err == noErr else { return [] }
        return Array(out.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func readString(_ objectID: AudioObjectID,
                           _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var value: CFString = "" as CFString
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr else { return nil }
        let s = value as String
        return s.isEmpty ? nil : s
    }

    // MARK: - Processes

    static func processObjectList() -> [AudioObjectID] {
        readArray(systemObject, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    static func translatePID(_ pid: pid_t) -> AudioObjectID? {
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var mutablePID = pid
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(systemObject, &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &mutablePID,
                                             &size, &objectID)
        guard err == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    static func processPID(_ objectID: AudioObjectID) -> pid_t? {
        var pid: pid_t = -1
        guard read(objectID, kAudioProcessPropertyPID, into: &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    static func processBundleID(_ objectID: AudioObjectID) -> String? {
        readString(objectID, kAudioProcessPropertyBundleID)
    }

    static func processIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        guard read(objectID, kAudioProcessPropertyIsRunningOutput, into: &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - Devices

    static func deviceList() -> [AudioDeviceID] {
        readArray(systemObject, kAudioHardwarePropertyDevices, of: AudioDeviceID.self)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        guard read(systemObject, kAudioHardwarePropertyDefaultOutputDevice, into: &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> OSStatus {
        var value = id
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioObjectSetPropertyData(systemObject, &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        readString(id, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        readString(id, kAudioObjectPropertyName)
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var t: UInt32 = 0
        _ = read(id, kAudioDevicePropertyTransportType, into: &t)
        return t
    }

    static func outputStreamCount(_ id: AudioDeviceID) -> Int {
        readArray(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioStreamID.self).count
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var rate: Double = 0
        _ = read(id, kAudioDevicePropertyNominalSampleRate, into: &rate)
        return rate
    }

    static func deviceIsAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        guard read(id, kAudioDevicePropertyDeviceIsAlive, into: &alive) == noErr else { return false }
        return alive != 0
    }

    /// Reported output latency in frames (device + safety offset). For Bluetooth
    /// this is a rough hint at best — the UI seeds the delay slider with it and
    /// lets the user trim by ear.
    static func reportedOutputLatencyFrames(_ id: AudioDeviceID) -> Int {
        var latency: UInt32 = 0
        _ = read(id, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, into: &latency)
        var safety: UInt32 = 0
        _ = read(id, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, into: &safety)
        return Int(latency + safety)
    }

    // MARK: - Taps

    static func tapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var asbd = AudioStreamBasicDescription()
        guard read(tapID, kAudioTapPropertyFormat, into: &asbd) == noErr, asbd.mSampleRate > 0 else { return nil }
        return asbd
    }
}

/// A registered HAL property listener that removes itself on deinit.
final class CAListener {
    private let objectID: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(objectID: AudioObjectID,
         selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue = .main,
         handler: @escaping () -> Void) {
        self.objectID = objectID
        self.addr = CA.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, block)
    }
}
