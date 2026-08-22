import Foundation
import CoreMIDI

/// A MIDI destination Echo can play into.
struct MIDIDestinationInfo: Identifiable, Hashable {
    var id: MIDIUniqueID
    var name: String
}

/// MIDI out. Echo always publishes a virtual source named "Echo Out" that any
/// app can subscribe to, and can additionally send straight to one chosen
/// destination — a hardware synth, a DAW input, the IAC bus.
final class MIDIOutput {
    var onDestinationsChanged: (() -> Void)?

    /// Endpoints belonging to Echo itself, so we never route into our own input.
    private(set) var ownUIDs: Set<MIDIUniqueID> = []
    /// Echo's own MIDI *input* endpoints, supplied by MIDIInput — sending to
    /// those would be an instant feedback loop.
    var excluded: Set<MIDIUniqueID> = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var selectedEndpoint: MIDIEndpointRef = 0

    private(set) var selected: MIDIUniqueID? {
        didSet { selectedEndpoint = selected.flatMap { endpoint(for: $0) } ?? 0 }
    }

    init() {
        var status = MIDIClientCreateWithBlock("Echo Out" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async {
                    // Re-resolve, in case our destination came or went.
                    self?.select(self?.selected)
                    self?.onDestinationsChanged?()
                }
            }
        }
        guard status == noErr else {
            NSLog("Echo: MIDI out client failed (\(status))")
            return
        }
        status = MIDIOutputPortCreate(client, "Echo Out Port" as CFString, &port)
        if status != noErr { NSLog("Echo: MIDIOutputPortCreate failed (\(status))") }

        status = MIDISourceCreateWithProtocol(client, "Echo Out" as CFString, ._1_0, &virtualSource)
        if status == noErr {
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, &uid)
            ownUIDs.insert(uid)
        } else {
            NSLog("Echo: MIDISourceCreateWithProtocol failed (\(status))")
        }
    }

    // MARK: - Destinations

    func destinations() -> [MIDIDestinationInfo] {
        var result: [MIDIDestinationInfo] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(i)
            guard endpoint != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            guard !ownUIDs.contains(uid), !excluded.contains(uid) else { continue }
            result.append(MIDIDestinationInfo(id: uid, name: displayName(endpoint)))
        }
        return result
    }

    func select(_ uid: MIDIUniqueID?) {
        selected = uid
    }

    private func endpoint(for uid: MIDIUniqueID) -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(i)
            var found: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &found)
            if found == uid { return endpoint }
        }
        return nil
    }

    private func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
           let string = value?.takeRetainedValue() {
            return string as String
        }
        return "MIDI destination"
    }

    // MARK: - Sending

    func noteOn(pitch: Int, velocity: Float, channel: UInt8) {
        let value = UInt8(max(8, min(127, Int((velocity * 127).rounded()))))
        send(status: 0x9, channel: channel, UInt8(clamping: pitch), value)
    }

    func noteOff(pitch: Int, channel: UInt8) {
        send(status: 0x8, channel: channel, UInt8(clamping: pitch), 0)
    }

    /// CC 123 on every channel we use, so nothing is left hanging on an
    /// external instrument.
    func allNotesOff() {
        for channel in UInt8(0)...UInt8(1) {
            send(status: 0xB, channel: channel, 123, 0)
        }
    }

    private func send(status: UInt8, channel: UInt8, _ data1: UInt8, _ data2: UInt8) {
        guard virtualSource != 0 || selectedEndpoint != 0 else { return }
        // UMP MIDI 1.0 channel voice: [mt:4][group:4][status:4][channel:4][d1:8][d2:8]
        let word = (UInt32(0x2) << 28)
            | (UInt32(status & 0xF) << 20)
            | (UInt32(channel & 0xF) << 16)
            | (UInt32(data1 & 0x7F) << 8)
            | UInt32(data2 & 0x7F)
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var words = [word]
        _ = MIDIEventListAdd(&list, 1024, packet, 0, 1, &words)

        // Publish to anyone subscribed to "Echo Out"...
        if virtualSource != 0 { MIDIReceivedEventList(virtualSource, &list) }
        // ...and to the chosen destination, if there is one.
        if selectedEndpoint != 0 { MIDISendEventList(port, selectedEndpoint, &list) }
    }
}
