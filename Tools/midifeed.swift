// Sends a short improvisation to a MIDI destination, so Echo can be exercised
// without a controller plugged in.
//   swiftc -O -o midifeed midifeed.swift && ./midifeed [destination-name]
import Foundation
import CoreMIDI

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Echo"

var client = MIDIClientRef()
guard MIDIClientCreate("midifeed" as CFString, nil, nil, &client) == noErr else {
    fputs("could not create MIDI client\n", stderr); exit(1)
}
var port = MIDIPortRef()
guard MIDIOutputPortCreate(client, "out" as CFString, &port) == noErr else {
    fputs("could not create output port\n", stderr); exit(1)
}

func name(_ endpoint: MIDIEndpointRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
          let string = value?.takeRetainedValue() else { return "" }
    return string as String
}

var destination: MIDIEndpointRef = 0
print("destinations:")
for i in 0..<MIDIGetNumberOfDestinations() {
    let endpoint = MIDIGetDestination(i)
    print("  \(name(endpoint))")
    if name(endpoint) == target { destination = endpoint }
}
guard destination != 0 else {
    fputs("no destination named \"\(target)\"\n", stderr); exit(1)
}
print("sending to \(target)")

func send(status: UInt8, _ data1: UInt8, _ data2: UInt8) {
    let word = (UInt32(0x2) << 28) | (UInt32(status) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    var list = MIDIEventList()
    let packet = MIDIEventListInit(&list, ._1_0)
    var words = [word]
    _ = MIDIEventListAdd(&list, 1024, packet, 0, 1, &words)
    MIDISendEventList(port, destination, &list)
}

func noteOn(_ pitch: UInt8, _ velocity: UInt8 = 80) { send(status: 0x90, pitch, velocity) }
func noteOff(_ pitch: UInt8) { send(status: 0x80, pitch, 0) }

func chord(_ pitches: [UInt8], hold: Double, velocity: UInt8 = 78) {
    for p in pitches { noteOn(p, velocity) }
    Thread.sleep(forTimeInterval: hold)
    for p in pitches { noteOff(p) }
}

func line(_ pitches: [UInt8], step: Double, velocity: UInt8 = 70) {
    for p in pitches {
        noteOn(p, velocity)
        Thread.sleep(forTimeInterval: step * 0.85)
        noteOff(p)
        Thread.sleep(forTimeInterval: step * 0.15)
    }
}

/// Rest long enough for Echo's listener to commit the phrase.
func rest(_ seconds: Double = 2.0) { Thread.sleep(forTimeInterval: seconds) }

// C major / A minor material, then a step around the wheel to G.
chord([60, 64, 67], hold: 1.6);            rest()
chord([57, 60, 64, 67], hold: 1.6);        rest()
line([72, 71, 69, 67, 69], step: 0.35);    rest()
chord([53, 57, 60, 64], hold: 1.8);        rest()
line([64, 67, 69, 72, 74, 72], step: 0.3); rest()
chord([55, 59, 62, 66], hold: 1.6);        rest()   // G major seventh, one slot over
line([79, 78, 76, 74], step: 0.4);         rest()
chord([48, 55, 60, 64], hold: 2.2);        rest(2.5)
print("done")
