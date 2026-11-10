// ChromaSynthLink --latency down|up [seconds] [--device Chromatic]: measures the delay between MIDI and the Chromatic's SOUND, with the Chromatic's sound coming
// into this Mac: over USB-C (the Chromatic shows up as the audio input "Chromatic - Player 01": --device Chromatic), or from its headphone
// output plugged into an audio input (then the default input).
//   down: this tool plays notes on MIDI channels 1-4 into the MIDI output "ChromaSynth" (the running ChromaSynth Link forwards them, like
//         a DAW would) and records the audio: the delay from the MIDI note to the sound, its spread, and how much of each channel
//         leaks to the left / right (set the channels' PAN in ChromaSynth to see the separation).
//   up:   waits for the Chromatic's sequencer (MIDI input "ChromaSynth", SYNC = OUT, keyboard screen), then listens for `seconds` (default 20)
//         from the first message: the offset between each MIDI note-on arriving and its sound (negative = the sound is first).
// Needs the microphone permission (the first run asks): run it with `open -n --stdout /tmp/latency.log build/ChromaSynthLink.app --args --latency down`.
import AudioToolbox
import AVFoundation
import CoreAudio
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

/// The id of the audio device whose name contains `name` and which has input channels (nil: not found).
func audioInputDevice(named name: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &sz, &cf)
        let n = (cf?.takeRetainedValue() as String?) ?? ""
        var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var csz: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &csz)
        guard n.contains(name), csz > 0 else { continue }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(csz), alignment: 16)
        defer { buf.deallocate() }
        AudioObjectGetPropertyData(id, &inAddr, 0, nil, &csz, buf)
        let list = buf.assumingMemoryBound(to: AudioBufferList.self)
        if UnsafeMutableAudioBufferListPointer(list).reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 { return id }
    }
    return nil
}

func runLatency(mode: String, seconds secs: Double, device: String?) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    let engine = AVAudioEngine()
    let input = engine.inputNode
    if let device = device {
        guard var id = audioInputDevice(named: device), let unit = input.audioUnit else { print("no audio input device with \"\(device)\" in its name"); exit(1) }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        print("audio input device: \(device)")
    }
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

    if mode == "start" {
        // start: the Chromatic's MIDI start ($FA) against the first sound that follows it (the sound must have been silent before: stop,
        // wait 2 s, start again, several times). Counts for `secs` from the first start.
        var starts: [Double] = []
        var first: Double? = nil
        var port = MIDIPortRef()
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in
            let now = hostNow()
            for pkt in list.unsafeSequence() {
                let n = Int(pkt.pointee.length)
                let b = withUnsafeBytes(of: pkt.pointee.data) { Array($0.prefix(n)) }
                if b.contains(0xFA) {
                    lock.lock()
                    if first == nil { first = now; print("first start: counting \(Int(secs)) s from now; stop, wait 2 s and start again a few times") }
                    starts.append(now)
                    lock.unlock()
                }
            }
        }
        for i in 0..<MIDIGetNumberOfSources() {
            var s: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyDisplayName, &s)
            if ((s?.takeRetainedValue() as String?) ?? "") == "ChromaSynth" { MIDIPortConnectSource(port, MIDIGetSource(i), nil); print("listening to the MIDI input ChromaSynth") }
        }
        let giveUp = Date(timeIntervalSinceNow: 900)
        while Date() < giveUp {
            lock.lock(); let f = first; lock.unlock()
            if let f = f, hostNow() - f > secs { break }
            usleep(100_000)
        }
        engine.stop()
        lock.lock()
        let w = windows, st = starts
        lock.unlock()
        var quiet: Float = 1
        var roll = 0
        for k in 0..<max(0, w.count - 500) {                     // the quietest half second of the capture
            if k % 100 == 0 { roll = k }
            _ = roll
            let m = w[k..<(k + 500)].map { max($0.l, $0.r) }.max() ?? 1
            if m < quiet { quiet = m }
            if quiet == 0 { break }
        }
        let thr = max(quiet * 4, 0.01)
        let ons = onsets(w, threshold: thr)
        var d: [Double] = []
        for a in st {
            if let o = ons.first(where: { $0 >= a - 0.05 && $0 < a + 1.0 }) { d.append(o - a); print(String(format: "  start -> first sound: %.0f ms", (o - a) * 1000)) }
        }
        print("MIDI start ($FA) arriving -> the first sound (\(st.count) starts, silence level \(String(format: "%.4f", quiet)), threshold \(String(format: "%.4f", thr))):")
        print("  " + stats(d))
        if !d.isEmpty {
            let mean = d.reduce(0, +) / Double(d.count)
            print(String(format: "The Chromatic's sound comes about %.0f ms after the MIDI start reaches this Mac (negative: before).", mean * 1000))
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
    // The sound of a dense pattern has no silences, so single onsets cannot be told apart. Instead: the audio's "attack strength" (how much
    // louder it got in the last few ms) is laid against the MIDI note-ons, and the shift that fits best is the offset.
    guard let t0 = w.first?.t, w.count > 2000, !arr.isEmpty else { print("not enough audio or MIDI"); exit(0) }
    let env = w.map { max($0.l, $0.r) }
    var attack = [Float](repeating: 0, count: env.count)
    for k in 14..<(env.count - 4) {
        let now = (env[k] + env[k + 1] + env[k + 2] + env[k + 3]) / 4
        let before = (env[k - 10] + env[k - 9] + env[k - 8] + env[k - 7] + env[k - 6] + env[k - 5] + env[k - 4]) / 7
        attack[k] = max(0, now - before)
    }
    let idx = arr.map { Int(($0 - t0) * 1000) }
    var best = (lag: 0, score: Float(-1))
    var sum: Float = 0, count = 0
    var scores: [Int: Float] = [:]
    for lag in -300...700 {
        var sc: Float = 0
        for a in idx where a + lag >= 0 && a + lag < attack.count { sc += attack[a + lag] }
        scores[lag] = sc
        sum += sc; count += 1
        if sc > best.score { best = (lag, sc) }
    }
    let mean = sum / Float(max(count, 1))
    print(String(format: "%d note-ons; the best fit: the sound comes %d ms after the MIDI note-on arrives (the fit is %.1f times the average: below 2 means no clear answer)", arr.count, best.lag, best.score / max(mean, 1e-9)))
    var spread: [Double] = []
    for a in idx {                                       // per note: the strongest attack near the best lag
        var bestK = -1, bestV: Float = 0.0
        for k in max(0, a + best.lag - 40)..<min(attack.count, a + best.lag + 40) where attack[k] > bestV { bestV = attack[k]; bestK = k }
        if bestK >= 0, bestV > 0.02 { spread.append(Double(bestK - a) / 1000) }
    }
    print("  per note (within 40 ms of the best fit): " + stats(spread))
    let off = [Double(best.lag) / 1000]
    if best.score / max(mean, 1e-9) >= 2 {
        print(String(format: "Live: the MIDI recorded from the Chromatic's sequencer arrives about %d ms BEFORE its sound reaches the audio input: move the recorded audio about %d ms earlier (or the MIDI later).", best.lag, best.lag))
    }
    _ = off
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
