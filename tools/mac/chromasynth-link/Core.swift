// Pure parts of ChromaSynth Link (no hardware, no CoreMIDI): MIDI bytes -> console lines, the flood guard, BLE MIDI packets.
// Tested by `--selftest` (tools/mac/test.sh).
import Foundation

// ---------------------------------------------------------------- MIDI bytes -> console lines
/// Turns raw MIDI bytes into console lines ("m 90 3c 64"). Channel messages only; running status is kept per call.
func consoleLines(for raw: [UInt8], running: inout UInt8) -> [String] {
    let bytes = raw.filter { $0 < 0xF8 }   // real-time bytes (clock, active sensing) may appear anywhere, even inside a message: skip them
    var out: [String] = []
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        var status = running
        var data: [UInt8] = []
        if b & 0x80 != 0 {
            if b >= 0xF0 {                 // system common (sysex ...): not forwarded; it cancels running status
                running = 0
                i += 1
                continue
            }
            status = b
            running = b
            i += 1
        } else if status == 0 {            // data with no status: skip
            i += 1
            continue
        }
        let need = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
        while data.count < need, i < bytes.count, bytes[i] & 0x80 == 0 {
            data.append(bytes[i])
            i += 1
        }
        if data.count == need {
            let hi = status & 0xF0
            // only what ChromaSynth plays: notes and all-notes-off (the ESP32 ignores the rest anyway; this saves serial traffic)
            if hi == 0x80 || hi == 0x90 || (hi == 0xB0 && (data[0] == 123 || data[0] == 120)) {
                out.append(String(format: "m %02x %02x %02x", status, data[0], need == 2 ? data[1] : 0))
            }
        }
    }
    return out
}

func selftest() -> Int {
    var fails = selftestFlood()
    func check(_ name: String, _ got: [String], _ want: [String]) {
        if got != want { print("FAIL \(name): \(got) != \(want)"); fails += 1 } else { print("PASS \(name)") }
    }
    var r: UInt8 = 0
    check("note on", consoleLines(for: [0x90, 60, 100], running: &r), ["m 90 3c 64"])
    r = 0
    check("note off", consoleLines(for: [0x80, 60, 0], running: &r), ["m 80 3c 00"])
    r = 0
    check("note on then off in one packet", consoleLines(for: [0x90, 60, 100, 0x80, 60, 0], running: &r), ["m 90 3c 64", "m 80 3c 00"])
    r = 0
    check("running status", consoleLines(for: [0x90, 60, 100, 62, 100], running: &r), ["m 90 3c 64", "m 90 3e 64"])
    r = 0
    check("another channel keeps its status", consoleLines(for: [0x93, 72, 1], running: &r), ["m 93 48 01"])
    r = 0
    check("all notes off", consoleLines(for: [0xB0, 123, 0], running: &r), ["m b0 7b 00"])
    r = 0
    check("a CC that is not forwarded", consoleLines(for: [0xB0, 7, 100], running: &r), [])
    r = 0
    check("program change and pitch bend are not forwarded", consoleLines(for: [0xC0, 5, 0xE0, 0, 64], running: &r), [])
    r = 0
    check("real-time bytes between notes", consoleLines(for: [0x90, 60, 0xF8, 100], running: &r), ["m 90 3c 64"])
    r = 0
    check("truncated message", consoleLines(for: [0x90, 60], running: &r), [])
    r = 0
    check("sysex is skipped", consoleLines(for: [0xF0, 1, 2, 0xF7, 0x90, 60, 100], running: &r), ["m 90 3c 64"])
    check("BLE MIDI packet", blePacket([0x90, 60, 100], timestamp: 0x1234), [String(0x80 | ((0x1234 >> 7) & 0x3F)), String(0x80 | (0x1234 & 0x7F)), "144", "60", "100"])
    return fails
}

// ---------------------------------------------------------------- flood guard
/// A person plays at most a few dozen note events a second. A MIDI loop (Live feeding its own IAC output back to itself) makes
/// thousands. Over `limit` messages in one second the guard trips: everything is dropped until the flow has been quiet for `quiet`
/// seconds. Pure (the clock is passed in), so it is tested without hardware.
struct FloodGuard {
    let limit: Int
    let quiet: Double
    var windowStart = 0.0
    var count = 0
    var tripped = false
    var lastSeen = 0.0
    var trips = 0
    init(limit: Int = 60, quiet: Double = 3.0) { self.limit = limit; self.quiet = quiet }
    /// true = forward this message
    mutating func allow(at now: Double) -> Bool {
        if tripped {
            if now - lastSeen >= quiet { tripped = false; count = 0; windowStart = now } else { lastSeen = now; return false }
        }
        if now - windowStart >= 1.0 { windowStart = now; count = 0 }
        count += 1
        lastSeen = now
        if count > limit { tripped = true; trips += 1; return false }
        return true
    }
}

func selftestFlood() -> Int {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { if ok { print("PASS \(name)") } else { print("FAIL \(name)"); fails += 1 } }
    var g = FloodGuard()
    var okAll = true
    for i in 0..<200 { if !g.allow(at: Double(i) * 0.05) { okAll = false } }      // 20 messages a second for 10 s: a fast player
    check("20 messages a second never trips", okAll && g.trips == 0)
    g = FloodGuard()
    var forwarded = 0
    for i in 0..<5000 { if g.allow(at: Double(i) * 0.0002) { forwarded += 1 } }    // 5000 messages a second: a loop
    check("a loop (5000 messages a second) trips, and only about one second's worth gets through", g.tripped && forwarded <= 61)
    check("it stays tripped while the flood goes on", !g.allow(at: 1.2))
    check("it resumes after 3 s of quiet", g.allow(at: 4.5) && !g.tripped)
    return fails
}


// ---------------------------------------------------------------- BLE MIDI packet
/// One MIDI message as a BLE MIDI packet: header (bit 7 + timestamp bits 12-7), timestamp low (bit 7 + bits 6-0), then the message.
/// Returns the bytes as decimal strings only so that the selftest can compare them in the same way as the other checks.
func blePacket(_ message: [UInt8], timestamp: UInt16) -> [String] {
    blePacketBytes(message, timestamp: timestamp).map { String($0) }
}

func blePacketBytes(_ message: [UInt8], timestamp: UInt16) -> [UInt8] {
    [0x80 | UInt8((timestamp >> 7) & 0x3F), 0x80 | UInt8(timestamp & 0x7F)] + message
}

/// "m 90 3c 64" -> [0x90, 0x3c, 0x64] (the console line is the one place that decides which messages are forwarded).
func messageBytes(fromLine line: String) -> [UInt8] {
    line.split(separator: " ").dropFirst().compactMap { UInt8($0, radix: 16) }
}
