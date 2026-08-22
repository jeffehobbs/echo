import CoreMIDI
import Foundation
import os.lock

/// A MIDI source Echo can listen to.
struct MIDISourceInfo: Identifiable, Hashable {
    var id: MIDIUniqueID
    var name: String
    var isConnected: Bool
}

/// CoreMIDI listener. Connects to any number of hardware or virtual sources
/// (Novation Play, the IAC bus, a keyboard) and also publishes its own
/// destination named "Echo", so any MIDI app can be pointed straight at it.
final class MIDIInput {
    /// Note events, already timestamped on `Clock`'s ruler.
    var onNoteOn: ((Int, Float, Double) -> Void)?
    var onNoteOff: ((Int, Double) -> Void)?
    var onSustain: ((Bool) -> Void)?
    var onAllNotesOff: (() -> Void)?
    var onSourcesChanged: (() -> Void)?

    /// Echo's own input endpoints, handed to MIDIOutput so it never routes
    /// back into us.
    private(set) var ownUIDs: Set<MIDIUniqueID> = []
    /// Echo's own *output* endpoints. Listening to those would mean learning
    /// our own output — the vocabulary would feed on itself.
    var excluded: Set<MIDIUniqueID> = []

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var virtualDestination = MIDIEndpointRef()
    private var connected: Set<MIDIUniqueID> = []
    /// Notes Echo just sent out, so a loopback route (an IAC bus wired both
    /// ways) does not get mistaken for playing. Written from the weaver queue
    /// and read on the CoreMIDI thread, so it takes a lock.
    private var recentlySent: [(pitch: Int, time: Double)] = []
    private let sentLock = OSAllocatedUnfairLock()

    init() {
        let name = "Echo" as CFString
        var status = MIDIClientCreateWithBlock(name, &client) { [weak self] notification in
            // Setup changes arrive on the CoreMIDI thread; the UI rescans.
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.onSourcesChanged?() }
            }
        }
        guard status == noErr else {
            NSLog("Echo: MIDIClientCreateWithBlock failed (\(status))")
            return
        }

        status = MIDIInputPortCreateWithProtocol(client, "Echo In" as CFString, ._1_0, &inputPort) {
            [weak self] eventList, _ in
            self?.handle(eventList)
        }
        if status != noErr { NSLog("Echo: MIDIInputPortCreateWithProtocol failed (\(status))") }

        // A destination of our own, so apps without a routable output can
        // simply select "Echo".
        status = MIDIDestinationCreateWithProtocol(client, "Echo" as CFString, ._1_0, &virtualDestination) {
            [weak self] eventList, _ in
            self?.handle(eventList)
        }
        if status == noErr {
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(virtualDestination, kMIDIPropertyUniqueID, &uid)
            ownUIDs.insert(uid)
        } else {
            NSLog("Echo: MIDIDestinationCreateWithProtocol failed (\(status))")
        }
    }

    // MARK: - Sources

    func availableSources() -> [MIDISourceInfo] {
        var result: [MIDISourceInfo] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid)
            guard !ownUIDs.contains(uid), !excluded.contains(uid) else { continue }
            result.append(MIDISourceInfo(id: uid, name: displayName(source), isConnected: connected.contains(uid)))
        }
        return result
    }

    /// Control-surface ports — Novation's "DAW Out", and the equivalent on
    /// most grid controllers — carry pad presses, knob moves and mode changes
    /// on their own channels rather than anything you played. Learning those as
    /// phrases is never what you want, so they are not connected
    /// automatically; they still appear in the menu if you do want them.
    private func isControlPort(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("DAW")
    }

    /// Listen to every source that is not one of our own endpoints.
    func connectAll() {
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid)
            guard !connected.contains(uid), !ownUIDs.contains(uid), !excluded.contains(uid) else { continue }
            guard !isControlPort(displayName(source)) else { continue }
            if MIDIPortConnectSource(inputPort, source, nil) == noErr { connected.insert(uid) }
        }
    }

    func setConnected(_ shouldConnect: Bool, uid: MIDIUniqueID) {
        guard let endpoint = endpoint(for: uid) else { return }
        if shouldConnect {
            if MIDIPortConnectSource(inputPort, endpoint, nil) == noErr { connected.insert(uid) }
        } else {
            MIDIPortDisconnectSource(inputPort, endpoint)
            connected.remove(uid)
        }
    }

    private func endpoint(for uid: MIDIUniqueID) -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            var found: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &found)
            if found == uid { return source }
        }
        return nil
    }

    private func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr,
           let value = name?.takeRetainedValue() {
            return value as String
        }
        return "MIDI source"
    }

    // MARK: - Parsing

    /// Universal MIDI Packet word layout for MIDI 1.0 channel voice messages:
    /// [mt:4][group:4][status:4][channel:4][data1:8][data2:8].
    private func handle(_ eventList: UnsafePointer<MIDIEventList>) {
        let time = Clock.now()
        let list = UnsafeMutablePointer(mutating: eventList)
        let packetCount = Int(list.pointee.numPackets)
        // Walk the packets in place: copying one out would leave
        // MIDIEventPacketNext advancing through detached memory.
        withUnsafeMutablePointer(to: &list.pointee.packet) { first in
            var packet = first
            for _ in 0..<packetCount {
                let wordCount = Int(packet.pointee.wordCount)
                withUnsafeMutablePointer(to: &packet.pointee.words) { tuple in
                    let words = UnsafeRawPointer(tuple).assumingMemoryBound(to: UInt32.self)
                    for i in 0..<wordCount { handle(word: words[i], at: time) }
                }
                packet = MIDIEventPacketNext(packet)
            }
        }
    }

    /// Called by the weaver whenever Echo emits a note, to arm the loopback
    /// guard below.
    func noteWasSent(pitch: Int, at time: Double) {
        sentLock.lock()
        recentlySent.append((pitch, time))
        if recentlySent.count > 64 { recentlySent.removeFirst(recentlySent.count - 64) }
        sentLock.unlock()
    }

    /// True if Echo sent this exact note a moment ago, in which case it is our
    /// own output arriving back through a loopback route rather than playing.
    private func isEcho(of pitch: Int, at time: Double) -> Bool {
        sentLock.lock()
        defer { sentLock.unlock() }
        return recentlySent.contains { $0.pitch == pitch && time - $0.time < 0.05 && time >= $0.time }
    }

    /// Set ECHO_MIDI_LOG=1 to log every message Echo accepts — the fastest way
    /// to tell a routing problem from a capture problem.
    private static let logging = ProcessInfo.processInfo.environment["ECHO_MIDI_LOG"] != nil

    private func handle(word: UInt32, at time: Double) {
        let messageType = (word >> 28) & 0xF
        guard messageType == 0x2 else { return }  // MIDI 1.0 channel voice
        let status = (word >> 20) & 0xF
        let data1 = Int((word >> 8) & 0x7F)
        let data2 = Int(word & 0x7F)
        if Self.logging {
            NSLog("echo-midi %.3f status %X ch %d d1 %d d2 %d", time, status, (word >> 16) & 0xF, data1, data2)
        }
        switch status {
        case 0x9 where data2 > 0:
            guard !isEcho(of: data1, at: time) else { return }
            onNoteOn?(data1, Float(data2) / 127.0, time)
        case 0x9, 0x8:
            onNoteOff?(data1, time)
        case 0xB where data1 == 64:
            onSustain?(data2 >= 64)
        case 0xB where data1 == 121 || data1 == 123:
            // Reset-all-controllers and all-notes-off: drop the pedal and let
            // go of everything, or a latched CC 64 blocks capture forever.
            onSustain?(false)
            onAllNotesOff?()
        default:
            break
        }
    }
}
