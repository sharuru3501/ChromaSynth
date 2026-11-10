// Waits (up to 10 minutes) for the first MIDI message of every MIDI input whose name contains the argument (default "ChromaSynth"),
// then listens for N seconds (default 15) from that message, and prints a summary: how many clocks, notes, start/stop. A way to see what a DAW would receive. swiftc -O tools/mac/midi_listen.swift
import CoreMIDI
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
let want = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ChromaSynth"
let secs = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 15 : 15
var client = MIDIClientRef(), port = MIDIPortRef()
var clocks = 0, notes = 0, starts = 0, stops = 0
var t0 = Date()
var started = false
var firstClocks: [Double] = []
var perChannel = [Int](repeating: 0, count: 16)
MIDIClientCreate("listen" as CFString, nil, nil, &client)
MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in
    let onlyStart = ProcessInfo.processInfo.environment["UNTIL_START"] != nil     // UNTIL_START=1: the counting begins at the first MIDI start ($FA)
    if !started && (!onlyStart || list.unsafeSequence().contains(where: { p in withUnsafeBytes(of: p.pointee.data) { Array($0.prefix(Int(p.pointee.length))) }.contains(0xFA) })) { started = true; t0 = Date(); print("first message: counting \(Int(secs)) s from now") }
    for pkt in list.unsafeSequence() {
        let n = Int(pkt.pointee.length)
        let b = withUnsafeBytes(of: pkt.pointee.data) { Array($0.prefix(n)) }
        for x in b {
            if x == 0xF8 { clocks += 1; if firstClocks.count < 40 { firstClocks.append(Date().timeIntervalSince(t0)) } }
            else if x == 0xFA { starts += 1; print(String(format: "%.3f START", Date().timeIntervalSince(t0))) } else if x == 0xFC { stops += 1; print(String(format: "%.3f STOP", Date().timeIntervalSince(t0))) }
        }
        if b.first.map({ $0 & 0xF0 == 0x90 || $0 & 0xF0 == 0x80 }) ?? false { notes += 1; perChannel[Int(b[0] & 0x0F)] += 1; print(String(format: "%.3f ", Date().timeIntervalSince(t0)) + b.map { String(format: "%02x", $0) }.joined(separator: " ")) }
    }
}
for i in 0..<MIDIGetNumberOfSources() {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &s)
    let name = (s?.takeRetainedValue() as String?) ?? "?"
    if name.contains(want) { MIDIPortConnectSource(port, MIDIGetSource(i), nil); print("listening to \(name)") }
}
let waitUntil = Date(timeIntervalSinceNow: 600)
while !started && Date() < waitUntil { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) }
if started { RunLoop.current.run(until: t0.addingTimeInterval(secs)) }
var gaps: [Double] = []
for i in 1..<max(1, firstClocks.count) { gaps.append(firstClocks[i] - firstClocks[i - 1]) }
let avg = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
print("note messages per MIDI channel (1-16): \(perChannel)")
print("in \(Int(secs)) s: clocks \(clocks), note messages \(notes), start \(starts), stop \(stops); average clock gap \(String(format: "%.1f", avg * 1000)) ms")
