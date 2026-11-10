// ChromaSynthLink --latency down|up [seconds]: measures the delay between MIDI and the Chromatic's SOUND, with the Chromatic's headphone
// output plugged into this Mac's audio input (line in).
//   down: this tool plays notes on MIDI channels 1-4 into the MIDI output "ChromaSynth" (the running ChromaSynth Link forwards them, like
//         a DAW would) and records the audio: the delay from the MIDI note to the sound, its spread, and how much of each channel
//         leaks to the left / right (set the channels' PAN in ChromaSynth to see the separation).
//   up:   waits for the Chromatic's sequencer (MIDI input "ChromaSynth", SYNC = OUT, keyboard screen), then listens for `seconds` (default 20)
//         from the first message: the offset between each MIDI note-on arriving and its sound (negative = the sound is first).
// Needs the microphone permission (the first run asks): run it with `open -n --stdout /tmp/latency.log build/ChromaSynthLink.app --args --latency down`.
import AVFoundation
import CoreMIDI
import Foundation

private let timebase: mach_timebase_info_data_t = {
    var t = mach_timebase_info_data_t()
    mach_timebase_info(&t)
    return t
}()

private func seconds(fromHost ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
}

private func hostNow() -> Double { seconds(fromHost: mach_absolute_time()) }

private struct Window { var t: Double; var l: Float; var r: Float }   // 1 ms of the input: its time (host seconds) and the peaks

func stats(_ v: [Double]) -> String {
    guard !v.isEmpty else { return "n 0" }
    let s = v.sorted()
    let mean = v.reduce(0, +) / Double(v.count)
    let sd = (v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)).squareRoot()
    return String(format: "n %d, min %.0f, median %.0f, mean %.0f, max %.0f, spread (std) %.1f ms", v.count, s.first! * 1000, s[s.count / 2] * 1000, mean * 1000, s.last! * 1000, sd * 1000)
}

/// Onsets: where the loudness rises above `threshold` after at least 30 ms below it.
private func onsets(_ w: [Window], threshold: Float) -> [Double] {
    var out: [Double] = []
    var quiet = 0
    for x in w {
        let m = max(x.l, x.r)
        if m > threshold {
            if quiet >= 30 { out.append(x.t) }
            quiet = 0
        } else { quiet += 1 }
    }
    return out
}

func runLatency(mode: String, seconds secs: Double) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { print("no audio input"); exit(1) }
    let lock = NSLock()
    var windows: [Window] = []
    let per = Int(format.sampleRate / 1000)
    var pending: [Float] = [], pendingR: [Float] = []
    var nextT = 0.0
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, when in
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        let t0 = seconds(fromHost: when.hostTime)
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty { nextT = t0 }
        for i in 0..<n {
            pending.append(abs(ch[0][i]))
            pendingR.append(abs(buf.format.channelCount > 1 ? ch[1][i] : ch[0][i]))
            if pending.count == per {
                windows.append(Window(t: nextT, l: pending.max() ?? 0, r: pendingR.max() ?? 0))
                nextT += 0.001
                pending.removeAll(keepingCapacity: true)
                pendingR.removeAll(keepingCapacity: true)
            }
        }
    }
    do { try engine.start() } catch { print("cannot start the audio input: \(error)"); exit(1) }
    print("audio input: \(Int(format.sampleRate)) Hz, \(format.channelCount) channel(s)")
    sleep(2)                                              // the room's noise
    lock.lock()
    let base = windows.suffix(1500).map { max($0.l, $0.r) }.sorted()
    lock.unlock()
    let noise = base.isEmpty ? 0 : base[Int(Double(base.count) * 0.95)]
    let threshold = max(noise * 4, 0.01)
    print(String(format: "noise (95%%) %.4f, threshold %.4f", noise, threshold))

    var client = MIDIClientRef()
    MIDIClientCreate("ChromaSynth latency" as CFString, nil, nil, &client)

    if mode == "down" {
        var dest = MIDIEndpointRef()
        for i in 0..<MIDIGetNumberOfDestinations() {
            var s: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyDisplayName, &s)
            if (s?.takeRetainedValue() as String?) == "ChromaSynth" { dest = MIDIGetDestination(i) }
        }
        guard dest != 0 else { print("no MIDI output \"ChromaSynth\": start ChromaSynth Link first"); exit(1) }
        var port = MIDIPortRef()
        MIDIOutputPortCreate(client, "out" as CFString, &port)
        func send(_ m: [UInt8]) {
            var buf = [UInt8](repeating: 0, count: 64)
            buf.withUnsafeMutableBytes { raw in
                let pl = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
                var p = MIDIPacketListInit(pl)
                var mm = m
                p = MIDIPacketListAdd(pl, 64, p, 0, mm.count, &mm)
                MIDISend(port, dest, pl)
            }
        }
        var sent: [(t: Double, ch: Int)] = []
        let rounds = 4
        for r in 0..<rounds {
            for ch in 0..<4 {
                let note = UInt8(60 + ch * 2 + r)
                sent.append((hostNow(), ch + 1))
                send([0x90 | UInt8(ch), note, 100])
                usleep(350_000)
                send([0x80 | UInt8(ch), note, 0])
                usleep(850_000)
            }
        }
        sleep(1)
        engine.stop()
        lock.lock()
        let w = windows
        lock.unlock()
        var lat: [Double] = [], miss = 0
        var perCh = [[Double]](repeating: [], count: 4)
        var lr = [[(Float, Float)]](repeating: [], count: 4)
        let ons = onsets(w, threshold: threshold)
        for s in sent {
            if let o = ons.first(where: { $0 >= s.t - 0.02 && $0 < s.t + 1.0 }) {
                lat.append(o - s.t)
                perCh[s.ch - 1].append(o - s.t)
                let seg = w.filter { $0.t >= o && $0.t < o + 0.15 }
                lr[s.ch - 1].append((seg.map { $0.l }.max() ?? 0, seg.map { $0.r }.max() ?? 0))
            } else { miss += 1 }
        }
        print("MIDI note -> sound, \(sent.count) notes, \(miss) without a sound:")
        print("  all: " + stats(lat))
        for c in 0..<4 where !perCh[c].isEmpty {
            let l = lr[c].map { $0.0 }.reduce(0, +) / Float(lr[c].count), r = lr[c].map { $0.1 }.reduce(0, +) / Float(lr[c].count)
            print(String(format: "  MIDI ch %d: ", c + 1) + stats(perCh[c]) + String(format: "; level left %.3f right %.3f (right - left %.1f dB)", l, r, 20 * log10(max(r, 1e-6) / max(l, 1e-6))))
        }
        if !lat.isEmpty {
            let mean = lat.reduce(0, +) / Double(lat.count)
            print(String(format: "Live: set the Track Delay of the tracks that play ChromaSynth to about -%.0f ms (it sends the notes that much earlier). The spread above is what stays.", mean * 1000))
        }
        exit(0)
    }

    // up: the Chromatic's sequencer
    var arrivals: [Double] = []
    var firstAt: Double? = nil
    var port = MIDIPortRef()
    MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in
        let now = hostNow()
        for pkt in list.unsafeSequence() {
            let n = Int(pkt.pointee.length)
            let b = withUnsafeBytes(of: pkt.pointee.data) { Array($0.prefix(n)) }
            lock.lock()
            if firstAt == nil { firstAt = now; print("first message: listening for \(Int(secs)) s from now") }
            if let s = b.first, s & 0xF0 == 0x90, b.count >= 3, b[2] > 0 { arrivals.append(now) }
            lock.unlock()
        }
    }
    for i in 0..<MIDIGetNumberOfSources() {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &s)
        if ((s?.takeRetainedValue() as String?) ?? "") == "ChromaSynth" { MIDIPortConnectSource(port, MIDIGetSource(i), nil); print("listening to the MIDI input ChromaSynth") }
    }
    let giveUp = Date(timeIntervalSinceNow: 600)
    while Date() < giveUp {
        lock.lock(); let f = firstAt; lock.unlock()
        if let f = f, hostNow() - f > secs { break }
        usleep(100_000)
    }
    engine.stop()
    lock.lock()
    let w = windows, arr = arrivals
    lock.unlock()
    let ons = onsets(w, threshold: threshold)
    var off: [Double] = []
    for a in arr {
        let isolated = !arr.contains { $0 != a && abs($0 - a) < 0.2 }
        if isolated, let o = ons.first(where: { $0 >= a - 0.3 && $0 < a + 0.6 }) { off.append(o - a) }
    }
    print("MIDI note-on arriving -> its sound (negative = the sound first), \(arr.count) note-ons, \(off.count) matched (notes closer than 0.2 s to another are skipped):")
    print("  " + stats(off))
    if !off.isEmpty {
        let mean = off.reduce(0, +) / Double(off.count)
        print(String(format: "Live: the recorded MIDI comes about %.0f ms %@ the audio: move the audio clips / set the track delay by that much.", abs(mean) * 1000, mean < 0 ? "after" : "before"))
    }
    exit(0)
}

/// ChromaSynthLink --send-test follow: what a DAW would send to follow along, one step at a time, with a pause between the steps (the link
/// is slow: every message takes about a third of a second). The running ChromaSynth Link forwards it. SYNC = 3 on the Chromatic.
func runSendTest() -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    var client = MIDIClientRef()
    MIDIClientCreate("ChromaSynth send test" as CFString, nil, nil, &client)
    var dest = MIDIEndpointRef()
    for i in 0..<MIDIGetNumberOfDestinations() {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyDisplayName, &s)
        if (s?.takeRetainedValue() as String?) == "ChromaSynth" { dest = MIDIGetDestination(i) }
    }
    guard dest != 0 else { print("no MIDI output \"ChromaSynth\": start ChromaSynth Link first"); exit(1) }
    var port = MIDIPortRef()
    MIDIOutputPortCreate(client, "out" as CFString, &port)
    func send(_ m: [UInt8], _ what: String, pause: UInt32 = 3) {
        var buf = [UInt8](repeating: 0, count: 64)
        buf.withUnsafeMutableBytes { raw in
            let pl = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var p = MIDIPacketListInit(pl)
            var mm = m
            p = MIDIPacketListAdd(pl, 64, p, 0, mm.count, &mm)
            MIDISend(port, dest, pl)
        }
        print(what)
        sleep(pause)
    }
    print("send test (SYNC = 3 on the Chromatic, the sequencer playing is best): each step has a 3 s pause; the pattern changes take effect at the next bar line")
    send([0xFA], "start (the sequencer starts)", pause: 6)
    send([0xC0, 1], "program change 2 -> pattern 2 (at the next bar)", pause: 6)
    send([0xC0, 2], "program change 3 -> pattern 3", pause: 6)
    send([0xC0, 0], "program change 1 -> pattern 1", pause: 6)
    for v in [0, 32, 64, 96] { send([0xB0, 20, UInt8(v)], "CC20 = \(v) on MIDI channel 1: CH1 duty \(v / 32)") }
    for v in [127, 64, 16, 127] { send([0xB0, 21, UInt8(v)], "CC21 = \(v) on MIDI channel 1: CH1 volume \(v / 8)") }
    for (v, w) in [(0, "left"), (64, "both"), (127, "right"), (64, "both")] { send([0xB0, 10, UInt8(v)], "CC10 = \(v) on MIDI channel 1: CH1 pan \(w)") }
    send([0xB0, 14, 20], "tempo CC14 = 20, CC15 = 0 -> BPM 80", pause: 1)
    send([0xB0, 15, 0], "(BPM 80 is set)", pause: 6)
    send([0xB0, 14, 60], "tempo CC14 = 60 -> BPM 120", pause: 1)
    send([0xB0, 15, 0], "(BPM 120 is set)", pause: 6)
    send([0xFC], "stop (the sequencer stops)", pause: 1)
    print("send test done")
    exit(0)
}
