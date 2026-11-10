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

/// "u 90 3c 64" (a console line of the USB mode) -> [0x90, 0x3c, 0x64]; anything else -> nil. The ESP32's prompt "mcu>  " has no line end, so
/// the first message printed after a command (the app sends `hb` twice a second) comes behind it on the same line: "mcu>  u fa". Such a
/// line counts too, or exactly the one-off messages (the start) would be lost.
func uplinkMessage(fromLine line: String) -> [UInt8]? {
    let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let re = try? NSRegularExpression(pattern: "(?:^|[\\s>])u((?: [0-9a-f]{2}){1,3})$"),
          let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
    let hex = (t as NSString).substring(with: m.range(at: 1))
    return hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
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
    var candidate = 0
    mutating func reset() { stamps = []; reported = 0; candidate = 0 }
    /// `now` should be the MIDI packet's own timestamp (when the DAW sent the clock), not the time this code ran: the clocks reach a
    /// process in bursts, and the arrival times of a burst would make the tempo look much faster. The tempo is reported when two beats
    /// in a row agree (a single odd beat is not believed), and then only if it differs from the last one reported.
    mutating func feed(at now: Double) -> Int? {
        stamps.append(now)
        if stamps.count > 25 { stamps.removeFirst(stamps.count - 25) }
        guard stamps.count == 25, let first = stamps.first else { return nil }
        let span = now - first                       // 24 clocks
        guard span > 0 else { return nil }
        let bpm = Int((60.0 / span).rounded())
        guard bpm >= 60, bpm <= 240 else { return nil }
        defer { candidate = bpm }
        guard bpm == candidate, bpm != reported else { return nil }
        reported = bpm
        return bpm
    }
}

/// The ROM sends a clock every tick (12 a beat); a DAW wants 24 a beat and gets nervous ("MIDI sync signal lost") when the clock stutters.
/// The ESP32 sometimes misses a message (it is busy sending a keep-alive packet for about 150 ms). So: every clock from the ROM is followed
/// by a second one half a period later, and when the next one does not come in time, the clock goes on by itself (at the period
/// measured from the last ticks) for up to 10 ticks, until the ROM's ticks are back or a stop arrives. Pure: the time is passed in.
struct ClockBridge {
    var lastTick: Double? = nil
    var period = 0.04                         // seconds per ROM tick (smoothed)
    var synthetic = 0
    /// A real clock arrived. -> the delay of the second clock of this tick.
    mutating func tick(at now: Double) -> Double {
        if let l = lastTick {
            let d = now - l                       // the time since the last REAL tick (bridged ticks in between count as ticks)
            let n = Double(synthetic + 1)
            let per = d / n
            if per > 0.004, per < 0.4 { period = period * 0.8 + per * 0.2 }
        }
        lastTick = now
        synthetic = 0
        return period / 2
    }
    /// Called often (every few ms): is a bridging tick due now? (then it counts as one)
    mutating func bridgeDue(at now: Double) -> Bool {
        guard let l = lastTick, synthetic < 10 else { return false }
        let expected = l + period * Double(synthetic + 1)
        if now >= expected + period * 0.5 { synthetic += 1; return true }
        return false
    }
    /// Start / stop / continue: no ticks to bridge.
    mutating func transport() { lastTick = nil; synthetic = 0 }
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
    check("console line: an echoed command is not a message", uplinkMessage(fromLine: "up on") == nil && uplinkMessage(fromLine: "mcu> hb") == nil && uplinkMessage(fromLine: "mode") == nil)
    check("console line behind the prompt: \"mcu>  u fa\" is the start", uplinkMessage(fromLine: "mcu>  u fa") == [0xFA] && uplinkMessage(fromLine: "mcu>  u 90 3c 64\r") == [0x90, 0x3c, 0x64])
    check("console line: a word that ends in u is not a message", uplinkMessage(fromLine: "menu 12") == nil && uplinkMessage(fromLine: "ubu fa") == nil)
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
    var burst: [Int] = []
    var tb = 0.0
    for k in 0..<120 {                               // 80 BPM, but the clocks arrive in bursts of 6 (timestamps stay right)
        tb += 60.0 / 80.0 / 24.0
        if let b = cb.feed(at: tb) { burst.append(b) }
        _ = k
    }
    check("80 BPM with exact timestamps is reported as 80 only", burst == [80])
    cb.reset()
    var slow: [Int] = []
    for k in 0..<60 { if let b = cb.feed(at: Double(k) * 60.0 / 30.0 / 24.0) { slow.append(b) } }
    check("a tempo below 60 is not reported", slow.isEmpty)
    var cbr = ClockBridge()
    check("the first clock: the second one half the default period later", abs(cbr.tick(at: 1.000) - 0.02) < 1e-9)
    let d1 = cbr.tick(at: 1.040)
    check("the next clock: a second one half the period later (the period learned)", d1 > 0.0185 && d1 < 0.0215)
    var emitted = 0
    var now = 1.040
    var cb2 = cbr
    while now < 1.040 + 0.5 { now += 0.002; if cb2.bridgeDue(at: now) { emitted += 1 } }
    check("a gap of 0.5 s is bridged by about 10 ticks, then it stops", emitted == 10)
    var cb3 = cbr
    var bridged = 0
    now = 1.040
    for k in 1...5 {                                     // ticks every 40 ms, the 3rd one is missing
        let end = 1.040 + Double(k) * 0.040
        while now < end - 0.001 { now += 0.002; if cb3.bridgeDue(at: now) { bridged += 1 } }
        if k != 3 { _ = cb3.tick(at: end); now = end }
    }
    check("one missing tick is bridged by exactly one", bridged == 1)
    cb3.transport()
    check("a stop forgets the ticks: nothing to bridge", !cb3.bridgeDue(at: 100))
    return fails
}
