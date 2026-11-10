// Pure parts of ChromaSynth Link (no hardware, no CoreMIDI): MIDI bytes -> console lines, the flood guard, BLE MIDI packets.
// Tested by `--selftest` (tools/mac/test.sh).
import Foundation

// ---------------------------------------------------------------- MIDI bytes -> console lines
/// Turns raw MIDI bytes into console lines ("m 90 3c 64"). Channel messages only; running status is kept per call.
func consoleLines(for raw: [UInt8], running: inout UInt8) -> [String] {
    let bytes = raw
    var out: [String] = []
    var i = 0
    while i < bytes.count {
        let b = bytes[i]
        if b >= 0xF8 {                     // real-time bytes (clock, active sensing) may appear anywhere, even inside a message
            if b == 0xFA || b == 0xFB || b == 0xFC { out.append(String(format: "m %02x 00 00", b)) }   // start / continue / stop go on; the clock does not
            i += 1
            continue
        }
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
        while data.count < need, i < bytes.count {
            let d = bytes[i]
            if d >= 0xF8 {                 // a real-time byte inside the message: handled, the message goes on
                if d == 0xFA || d == 0xFB || d == 0xFC { out.append(String(format: "m %02x 00 00", d)) }
                i += 1
                continue
            }
            if d & 0x80 != 0 { break }
            data.append(d)
            i += 1
        }
        if data.count == need {
            let hi = status & 0xF0
            // what ChromaSynth plays and follows: notes, all-notes-off, program change (the pattern) and the CCs 10 / 14 / 15 / 20 / 21
            // (pan, tempo, timbre; the ESP32 ignores the rest anyway, this saves link time)
            if hi == 0x80 || hi == 0x90 || hi == 0xC0 || (hi == 0xB0 && [123, 120, 10, 14, 15, 20, 21].contains(data[0])) {
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
    check("pitch bend is not forwarded, program change is", consoleLines(for: [0xC0, 5, 0xE0, 0, 64], running: &r), ["m c0 05 00"])
    r = 0
    check("real-time bytes between notes", consoleLines(for: [0x90, 60, 0xF8, 100], running: &r), ["m 90 3c 64"])
    r = 0
    check("MIDI start / stop go on, the clock does not", consoleLines(for: [0xFA, 0xF8, 0xF8, 0xFC], running: &r), ["m fa 00 00", "m fc 00 00"])
    r = 0
    check("the tempo, timbre and pan CCs go on, others not", consoleLines(for: [0xB0, 14, 60, 0xB0, 15, 1, 0xB1, 20, 100, 0xB2, 21, 64, 0xB3, 10, 0, 0xB0, 74, 5], running: &r), ["m b0 0e 3c", "m b0 0f 01", "m b1 14 64", "m b2 15 40", "m b3 0a 00"])
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
    let b = line.split(separator: " ").dropFirst().compactMap { UInt8($0, radix: 16) }
    guard let status = b.first else { return b }
    if status >= 0xF8 { return [status] }                                       // real-time: one byte
    if status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0 { return Array(b.prefix(2)) }   // program change: two
    return b
}

// ---------------------------------------------------------------- the ROM's MIDI out (Chromatic -> DAW)
/// BLE MIDI packet -> MIDI messages. Header (bit 7 + time high), then for each message a time-low byte (bit 7) and the message;
/// a message without a status byte continues the running status; real-time messages ($F8-$FF) are one byte; SysEx is skipped.
func parseBLEMIDI(_ d: [UInt8]) -> [[UInt8]] {
    guard d.count >= 3, d[0] & 0x80 != 0 else { return [] }
    var out: [[UInt8]] = []
    var i = 1
    var running: UInt8 = 0
    while i < d.count {
        if d[i] & 0x80 != 0, i + 1 < d.count, d[i + 1] & 0x80 != 0 || (d[i + 1] & 0x80 == 0 && running != 0) { i += 1 }   // the time-low byte
        guard i < d.count else { break }
        var status = d[i]
        if status & 0x80 != 0 {
            i += 1
            if status >= 0xF8 { out.append([status]); continue }
            if status >= 0xF0 { running = 0; while i < d.count, d[i] & 0x80 == 0 { i += 1 }; continue }   // sysex / system common: skipped
            running = status
        } else {
            status = running
            if status == 0 { i += 1; continue }
        }
        let need = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
        var msg = [status]
        while msg.count < need + 1, i < d.count, d[i] & 0x80 == 0 { msg.append(d[i]); i += 1 }
        if msg.count == need + 1 { out.append(msg) }
    }
    return out
}

/// "u 90 3c 64" (a console line of the USB mode) -> [0x90, 0x3c, 0x64]; anything else -> nil.
func uplinkMessage(fromLine line: String) -> [UInt8]? {
    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard parts.count >= 2, parts.count <= 4, parts[0] == "u" else { return nil }
    var out: [UInt8] = []
    for p in parts.dropFirst() {
        guard p.count == 2, let b = UInt8(p, radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

/// Complete lines of a growing text buffer (the console ends lines with \r\n, which Swift treats as ONE character: splitting on \n
/// alone never finds it). The incomplete rest stays in the buffer.
func takeLines(_ buf: inout String) -> [String] {
    let t = buf.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var parts = t.components(separatedBy: "\n")
    buf = parts.removeLast()
    return parts
}

/// The DAW's tempo from its MIDI clock (24 a beat): the average over the last beat, rounded to a whole BPM (the ROM's resolution),
/// reported only when it changes (by at least one BPM from the last one reported). Pure: the time is passed in.
struct ClockBpm {
    var stamps: [Double] = []
    var reported = 0
    mutating func reset() { stamps = []; reported = 0 }
    mutating func feed(at now: Double) -> Int? {
        stamps.append(now)
        if stamps.count > 25 { stamps.removeFirst(stamps.count - 25) }
        guard stamps.count == 25, let first = stamps.first else { return nil }
        let span = now - first                       // 24 clocks
        guard span > 0 else { return nil }
        let bpm = Int((60.0 / span).rounded())
        guard bpm >= 60, bpm <= 240, bpm != reported else { return nil }
        reported = bpm
        return bpm
    }
}

/// The ROM sends a clock every tick, 12 a beat; a DAW wants 24 a beat. Every clock is followed by a second one half an interval
/// later (the interval being the one between the last two clocks). Start / stop / continue forget the interval. Pure: the time is
/// passed in.
struct ClockDoubler {
    var last: Double? = nil
    /// -> the delay after which a second clock is due, or nil (not for this message, or no interval known yet)
    mutating func secondClock(after message: [UInt8], at now: Double) -> Double? {
        guard let b = message.first, message.count == 1 else { return nil }
        if b == 0xFA || b == 0xFB || b == 0xFC { last = nil; return nil }
        guard b == 0xF8 else { return nil }
        defer { last = now }
        if let l = last, now - l > 0.002, now - l < 0.5 { return (now - l) / 2 }
        return nil
    }
}

func selftestUplink() -> Int {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { if ok { print("PASS \(name)") } else { print("FAIL \(name)"); fails += 1 } }
    check("BLE MIDI note-on", parseBLEMIDI([0x80, 0x80, 0x90, 60, 100]) == [[0x90, 60, 100]])
    check("BLE MIDI clock (one byte)", parseBLEMIDI([0x81, 0x85, 0xF8]) == [[0xF8]])
    check("BLE MIDI two messages, the second with a time byte and running status", parseBLEMIDI([0x80, 0x80, 0x90, 60, 100, 0x81, 60, 0]) == [[0x90, 60, 100], [0x90, 60, 0]])
    check("BLE MIDI two messages, the second with its own status", parseBLEMIDI([0x80, 0x80, 0x90, 60, 100, 0x81, 0x80, 60, 0]) == [[0x90, 60, 100], [0x80, 60, 0]])
    check("BLE MIDI start", parseBLEMIDI([0x80, 0x80, 0xFA]) == [[0xFA]])
    check("BLE MIDI garbage", parseBLEMIDI([0x00, 0x01]) == [] && parseBLEMIDI([]) == [])
    check("console line, 3 bytes", uplinkMessage(fromLine: "u 90 3c 64\r\n") == [0x90, 0x3c, 0x64])
    check("console line, 1 byte", uplinkMessage(fromLine: "u f8") == [0xF8])
    check("console line: an echoed command is not a message", uplinkMessage(fromLine: "up on") == nil && uplinkMessage(fromLine: "mcu> hb") == nil)
    var lb = "u 90 3c 64\r\nu f8\r\nu 9"
    let got = takeLines(&lb)
    check("console lines end with \\r\\n: two complete lines, the rest is kept", got == ["u 90 3c 64", "u f8"] && lb == "u 9")
    lb += "0 3e 64\r\n"
    check("the rest completes with the next chunk", takeLines(&lb) == ["u 90 3e 64"] && lb == "")
    var cb = ClockBpm()
    var reportedBpm: [Int] = []
    for k in 0..<100 { if let b = cb.feed(at: Double(k) * 60.0 / 120.0 / 24.0) { reportedBpm.append(b) } }
    check("a clock of 120 BPM is reported once as 120", reportedBpm == [120])
    reportedBpm = []
    var tt = 100.0
    for _ in 0..<60 { tt += 60.0 / 90.0 / 24.0; if let b = cb.feed(at: tt) { reportedBpm.append(b) } }
    check("a change to 90 BPM is reported", reportedBpm.last == 90)
    cb.reset()
    var slow: [Int] = []
    for k in 0..<60 { if let b = cb.feed(at: Double(k) * 60.0 / 30.0 / 24.0) { slow.append(b) } }
    check("a tempo below 60 is not reported", slow.isEmpty)
    var c = ClockDoubler()
    check("the first clock: no interval yet", c.secondClock(after: [0xF8], at: 1.000) == nil)
    let d = c.secondClock(after: [0xF8], at: 1.040)
    check("the next clock: a second one half an interval later", d != nil && abs(d! - 0.020) < 1e-9)
    check("start forgets the interval", c.secondClock(after: [0xFA], at: 1.05) == nil && c.secondClock(after: [0xF8], at: 1.06) == nil)
    check("a note is not doubled", c.secondClock(after: [0x90, 60, 100], at: 1.1) == nil)
    return fails
}
