// Prints what a MIDI source is sending. Used to verify Echo's MIDI output.
//   swiftc -O -o midimonitor midimonitor.swift && ./midimonitor "Echo Out" 30
import Foundation
import CoreMIDI

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Echo Out"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 20 : 20

var client = MIDIClientRef()
guard MIDIClientCreate("midimonitor" as CFString, nil, nil, &client) == noErr else { exit(1) }

let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
var counts: [String: Int] = [:]
var channels: Set<Int> = []
var held: Set<Int> = []
var maxHeld = 0
var lines = 0
let start = Date()

var port = MIDIPortRef()
let status = MIDIInputPortCreateWithProtocol(client, "in" as CFString, ._1_0, &port) { eventList, _ in
    let list = UnsafeMutablePointer(mutating: eventList)
    let packets = Int(list.pointee.numPackets)
    withUnsafeMutablePointer(to: &list.pointee.packet) { first in
        var packet = first
        for _ in 0..<packets {
            let count = Int(packet.pointee.wordCount)
            withUnsafeMutablePointer(to: &packet.pointee.words) { tuple in
                let words = UnsafeRawPointer(tuple).assumingMemoryBound(to: UInt32.self)
                for i in 0..<count {
                    let w = words[i]
                    guard (w >> 28) & 0xF == 0x2 else { continue }
                    let st = (w >> 20) & 0xF, ch = Int((w >> 16) & 0xF)
                    let d1 = Int((w >> 8) & 0x7F), d2 = Int(w & 0x7F)
                    let name = "\(names[d1 % 12])\(d1 / 12 - 1)"
                    channels.insert(ch + 1)
                    switch st {
                    case 0x9 where d2 > 0:
                        counts["on", default: 0] += 1
                        held.insert(d1); maxHeld = max(maxHeld, held.count)
                        if lines < 24 {
                            lines += 1
                            print(String(format: "%6.2fs  ch%d  on  %-4@ vel %3d", Date().timeIntervalSince(start), ch + 1, name as NSString, d2))
                        }
                    case 0x9, 0x8:
                        counts["off", default: 0] += 1
                        held.remove(d1)
                        if lines < 24 {
                            lines += 1
                            print(String(format: "%6.2fs  ch%d  off %-4@", Date().timeIntervalSince(start), ch + 1, name as NSString))
                        }
                    case 0xB:
                        counts["cc\(d1)", default: 0] += 1
                    default: break
                    }
                }
            }
            packet = MIDIEventPacketNext(packet)
        }
    }
}
guard status == noErr else { fputs("port failed\n", stderr); exit(1) }

func name(_ e: MIDIEndpointRef) -> String {
    var v: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &v) == noErr,
          let s = v?.takeRetainedValue() else { return "" }
    return s as String
}

var found = false
for i in 0..<MIDIGetNumberOfSources() where name(MIDIGetSource(i)) == target {
    if MIDIPortConnectSource(port, MIDIGetSource(i), nil) == noErr { found = true }
}
guard found else { fputs("no source named \"\(target)\"\n", stderr); exit(1) }
print("listening to \"\(target)\" for \(Int(seconds))s")

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
print("--- summary ---")
print("note-ons \(counts["on"] ?? 0), note-offs \(counts["off"] ?? 0), still held \(held.count), max simultaneous \(maxHeld)")
print("channels seen: \(channels.sorted().map(String.init).joined(separator: ", "))")
for (k, v) in counts.sorted(by: { $0.key < $1.key }) where k.hasPrefix("cc") { print("\(k): \(v)") }
