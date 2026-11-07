// Wired MIDI for the Chromatic: reads a MIDI keyboard on this Mac (CoreMIDI) and writes the notes to the Chromatic's
// USB-C serial port, where the ESP32's console takes them as `m 90 3c 64` (see docs/BLE_MIDI.md, "USB mode").
//
//   swiftc -O tools/chromasynth_usb_bridge.swift -o chromasynth_usb_bridge
//   ./chromasynth_usb_bridge                      all MIDI inputs (except the IAC buses and the Bluetooth ChromaSynth), first /dev/cu.usbmodem*
//   In Ableton Live: set a track's MIDI To to "ChromaSynth USB" (the helper creates that MIDI output itself; no IAC bus needed).
//   ./chromasynth_usb_bridge --input IAC          (alternative) listen to the IAC buses, if you route Live through an IAC bus
//   ./chromasynth_usb_bridge --list               list the MIDI inputs and serial ports, then exit
//   ./chromasynth_usb_bridge --input MPK          only inputs whose name contains "MPK"
//   ./chromasynth_usb_bridge --port /dev/cu.usbmodemXXXX
//   ./chromasynth_usb_bridge --dry-run            print the console lines instead of writing them (no hardware needed)
//   ./chromasynth_usb_bridge --verbose            also print every line that is sent
//   ./chromasynth_usb_bridge --selftest           check the MIDI -> console line conversion, then exit
//
// Opening the serial port resets the ESP32 (once), so after opening it waits for the boot, then sends `mode usb`
// (the ESP32 always boots in the OFF mode). On Ctrl-C it sends `mode off`, so that the ESP32 can light-sleep again.
// The ChromaSynth ROM must be on its KEYBOARD screen: the ESP32 sends only then.
import CoreMIDI
import Darwin
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

func selftest() -> Never {
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
    exit(fails == 0 ? 0 : 1)
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

// ---------------------------------------------------------------- serial port
var serialFD: Int32 = -1
var usbConfirmed = false
let writeLock = NSLock()

func openSerial(_ path: String) -> Int32 {
    let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    if fd < 0 { return -1 }
    var t = termios()
    tcgetattr(fd, &t)
    cfmakeraw(&t)
    cfsetspeed(&t, 115200)
    t.c_cflag |= tcflag_t(CLOCAL | CREAD)
    t.c_cflag &= ~tcflag_t(CRTSCTS)
    tcsetattr(fd, TCSANOW, &t)
    var bits: Int32 = TIOCM_DTR | TIOCM_RTS
    _ = ioctl(fd, TIOCMBIC, &bits)          // DTR and RTS off: they hold the ESP32 in reset (docs/CHROMATIC_INTERNALS.md section 6)
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    return fd
}

func send(_ line: String, dry: Bool) {
    if dry { print(line); return }
    writeLock.lock()
    defer { writeLock.unlock() }
    let data = Array((line + "\r\n").utf8)
    _ = data.withUnsafeBytes { write(serialFD, $0.baseAddress, data.count) }
}

func serialPorts() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
}

func name(_ o: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}

// ---------------------------------------------------------------- main
setvbuf(stdout, nil, _IOLBF, 0)   // lines appear at once, also when the output goes to a file or a pipe
let args = CommandLine.arguments
func option(_ flag: String) -> String? { if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }; return nil }
if args.contains("--selftest") { selftest() }
let dry = args.contains("--dry-run")
let verbose = args.contains("--verbose")
let inputFilter = option("--input")

if args.contains("--list") {
    print("MIDI inputs:")
    for i in 0..<MIDIGetNumberOfSources() { print("  " + name(MIDIGetSource(i))) }
    print("serial ports:")
    for p in serialPorts() { print("  " + p) }
    exit(0)
}

if !dry {
    guard let path = option("--port") ?? serialPorts().first else {
        print("No /dev/cu.usbmodem* port: connect the Chromatic with a USB-C data cable (a cartridge must be in it and the console on).")
        exit(1)
    }
    serialFD = openSerial(path)
    if serialFD < 0 { print("Cannot open \(path)"); exit(1) }
    print("opened \(path); the ESP32 resets once: waiting for it to boot...")
    // Read what the ESP32 prints (also so that its buffer never fills); `mode usb` is confirmed by "applied USB".
    DispatchQueue.global().async {
        var buf = [UInt8](repeating: 0, count: 512)
        var text = ""
        while true {
            let n = read(serialFD, &buf, buf.count)
            if n > 0 {
                text += String(decoding: buf[0..<n], as: UTF8.self)
                if text.count > 4000 { text = String(text.suffix(2000)) }
                if text.contains("applied USB") { usbConfirmed = true }
            } else { usleep(20000) }
        }
    }
    sleep(3)
    // The console may not be up yet (and a command sent too early is lost): ask until the ESP32 says it is in USB mode.
    for _ in 0..<12 {
        send("mode usb", dry: false)
        for _ in 0..<15 { if usbConfirmed { break }; usleep(100_000) }
        if usbConfirmed { break }
    }
    if !usbConfirmed { print("WARNING: the ESP32 did not confirm USB mode (is the console on? is this the right port?). Notes will be ignored.") }
}
if dry { send("mode usb", dry: true) }
print("USB mode on. Put the ChromaSynth ROM on its KEYBOARD screen and play. Ctrl-C to stop (sends `mode off`).")

var client = MIDIClientRef()
MIDIClientCreate("chromasynth_usb_bridge" as CFString, nil, nil, &client)
var port = MIDIPortRef()
var running: UInt8 = 0
var sent = 0
var guardState = FloodGuard()
var announcedTrip = 0
func handle(_ list: UnsafePointer<MIDIPacketList>) {
    for pkt in list.unsafeSequence() {
        let n = Int(pkt.pointee.length)
        let bytes = withUnsafeBytes(of: pkt.pointee.data) { Array($0.prefix(n)) }
        for line in consoleLines(for: bytes, running: &running) {
            if !guardState.allow(at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9) {
                if guardState.trips != announcedTrip {
                    announcedTrip = guardState.trips
                    print("\nLOOP? More than \(guardState.limit) MIDI messages in a second: dropping everything until it is quiet for \(Int(guardState.quiet)) s. "
                          + "In Live set the track's MIDI From to No Input (or untick Track for the IAC input ports in Settings > Tempo & MIDI).")
                    send("m b0 7b 00", dry: dry)    // all notes off, so that nothing hangs
                }
                continue
            }
            send(line, dry: dry)
            sent += 1
            if verbose && !dry { print("-> \(line)") }
        }
    }
}
MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in handle(list) }
// A virtual MIDI OUTPUT PORT of its own, "ChromaSynth USB": it shows up in Live's "MIDI To" list like "ChromaSynth Bluetooth", with
// no IAC bus and no feedback loop (it is a destination only: nothing in it can come back to Live as an input).
var virtualDest = MIDIEndpointRef()
MIDIDestinationCreateWithBlock(client, "ChromaSynth USB" as CFString, &virtualDest) { list, _ in handle(list) }
print("MIDI output \"ChromaSynth USB\" created: choose it as a Live track's MIDI To (no IAC needed)")

var connected = Set<MIDIEndpointRef>()
func connectSources() {
    for i in 0..<MIDIGetNumberOfSources() {
        let src = MIDIGetSource(i)
        let n = name(src)
        if connected.contains(src) { continue }
        if n.contains("ChromaSynth") { continue }                          // never the Bluetooth ChromaSynth (that is the BLE path)
        if let f = inputFilter { if !n.contains(f) { continue } }          // an explicit --input picks exactly what matches, IAC buses included
        else if n.contains("IAC") { continue }                            // by default not the virtual IAC buses: use --input IAC to play from Live
        MIDIPortConnectSource(port, src, nil)
        connected.insert(src)
        print("listening to: \(n)")
    }
}

signal(SIGINT) { _ in
    send("mode off", dry: dry)
    usleep(300_000)
    print("\nstopped; sent \(sent) MIDI messages")
    exit(0)
}
connectSources()
while true {
    // CoreMIDI only refreshes this process's list of devices while a run loop is running, so wait in the run loop (not sleep()).
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
    connectSources()      // a keyboard that is plugged in later
}
