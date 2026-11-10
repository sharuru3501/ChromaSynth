// ChromaSynth Link: a small menu bar app that connects this Mac's MIDI to the Chromatic running ChromaSynth.
//
//   - It creates the MIDI output "ChromaSynth" (a DAW's "MIDI To"). Hardware MIDI keyboards are listened to only if switched on in the
//     menu (a DAW that routes the keyboard to "ChromaSynth" would play every note twice).
//   - Bluetooth: it finds the Chromatic by itself (BLE MIDI service of the ESP32, name "ChromaSynth"), connects, and reconnects.
//     Nothing to set up in Audio MIDI Setup (do not connect it there as well: the notes would play twice).
//   - USB-C: when the Chromatic's serial port (/dev/cu.usbmodem*) appears, it takes over: it switches the ESP32 to USB mode,
//     sends the notes as console lines and a heartbeat every 3 s (without it the ESP32 goes back to its saved mode after 10 s).
//   - The ChromaSynth ROM must be on its KEYBOARD screen: the ESP32 sends the notes only then.
//
//   build: tools/mac/build_app.sh        command line: ChromaSynthLink --selftest | --dry-run [--keyboards] | --list
import AppKit
import CoreBluetooth
import CoreMIDI
import Darwin
import Foundation
import ServiceManagement

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--latency") {
    let mode = i + 1 < args.count ? args[i + 1] : "down"
    let secs = i + 2 < args.count ? Double(args[i + 2]) ?? 20 : 20
    let dev: String? = args.firstIndex(of: "--device").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    runLatency(mode: mode, seconds: secs, device: dev)
}
if args.contains("--send-test") { runSendTest() }
if args.contains("--selftest") { exit(selftest() + selftestUplink() == 0 ? 0 : 1) }
let dry = args.contains("--dry-run")

func midiName(_ o: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}

func serialPorts() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
}

// --emit-test: a stand-in for the Chromatic. Creates the MIDI input "ChromaSynth" and plays notes on MIDI channels 1-4 (four
// notes each, a start at the beginning, a stop at the end), to see what a DAW does with them. Quit the app first.
if args.contains("--emit-test") {
    var client = MIDIClientRef()
    var src = MIDIEndpointRef()
    MIDIClientCreate("ChromaSynth emit test" as CFString, nil, nil, &client)
    MIDISourceCreate(client, "ChromaSynth" as CFString, &src)
    func emit(_ m: [UInt8]) {
        var buf = [UInt8](repeating: 0, count: 64)
        buf.withUnsafeMutableBytes { raw in
            let pl = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var p = MIDIPacketListInit(pl)
            var mm = m
            p = MIDIPacketListAdd(pl, 64, p, 0, mm.count, &mm)
            MIDIReceived(src, pl)
        }
    }
    print("emit test: the MIDI input \"ChromaSynth\" exists; the notes start in 6 s (channels 1-4, 4 notes each, one every 0.4 s)")
    DispatchQueue.global().async {
        sleep(6)
        emit([0xFA])
        for round in 0..<4 {
            for ch in 0..<4 {
                let note = UInt8(48 + ch * 7 + round * 2)
                emit([0x90 | UInt8(ch), note, 100])
                usleep(300_000)
                emit([0x80 | UInt8(ch), note, 0])
                usleep(100_000)
            }
        }
        emit([0xFC])
        print("emit test: done")
        exit(0)
    }
    RunLoop.main.run()
}

if args.contains("--list") {
    print("MIDI inputs:")
    for i in 0..<MIDIGetNumberOfSources() { print("  " + midiName(MIDIGetSource(i))) }
    print("serial ports:")
    for p in serialPorts() { print("  " + p) }
    exit(0)
}

// ---------------------------------------------------------------- the link
final class Link: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum Transport { case none, ble, usb }
    private(set) var transport = Transport.none { didSet { if oldValue != transport { onChange?() } } }
    var onChange: (() -> Void)?
    /// false after "Disconnect" in the menu: nothing is connected on its own until "Connect".
    private(set) var autoConnect = true
    /// Hardware MIDI keyboards are listened to only when asked for (menu, or --keyboards): a DAW that already routes the keyboard to
    /// "ChromaSynth" would play every note twice.
    private(set) var listenKeyboards = UserDefaults.standard.bool(forKey: "listenKeyboards") || args.contains("--keyboards")
    var statusText: String {
        switch transport {
        case .usb: return "Connected: USB"
        case .ble: return "Connected: Bluetooth"
        case .none:
            if !autoConnect { return "Disconnected" }
            if usbSuppressed, !chromaticMode.isEmpty { return "Chromatic MIDI mode: \(chromaticMode)" }
            return bleReady ? "Looking for the Chromatic…" : "Bluetooth is off or not allowed"
        }
    }

    // MIDI
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var dest = MIDIEndpointRef()
    private var upSource = MIDIEndpointRef()      // "ChromaSynth" as a MIDI input: what the Chromatic's sequencer plays (SYNC = OUT)
    private var clockDoubler = ClockDoubler()
    private var upCount = 0
    private var clockBpm = ClockBpm()
    private var running: UInt8 = 0
    private var guardState = FloodGuard()
    private var announcedTrip = 0
    private var connectedSources = Set<MIDIEndpointRef>()
    private let sendLock = NSLock()
    private(set) var sent = 0

    // Bluetooth
    private var central: CBCentralManager!   // nil in a dry run
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var bleReady = false
    static let midiService = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    static let midiCharacteristic = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

    // USB
    private var serialFD: Int32 = -1
    private var serialPath = ""
    private var usbConfirmed = false
    private var consoleUp = false
    private let usbQueue = DispatchQueue(label: "chromasynth.usb")
    private var usbBusy = false
    /// The Chromatic's MIDI mode was changed on the console itself (its menu): the USB link is not taken back until the cable is
    /// pulled and plugged in again, or "Connect" is chosen.
    private var usbSuppressed = false
    private var chromaticMode = ""
    private var lastModeReply = Date()
    private let ioQueue = DispatchQueue(label: "chromasynth.io")     // every serial write: the main thread never waits for the port
    /// true while the USB takeover is under way: the notes that arrive meanwhile are dropped (they have no path), so that none can
    /// start a note whose note-off would be lost.
    private var switching = false

    func start() {
        MIDIClientCreate("ChromaSynth Link" as CFString, nil, nil, &client)
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] list, ref in self?.handle(list, from: ref) }
        MIDIDestinationCreateWithBlock(client, "ChromaSynth" as CFString, &dest) { [weak self] list, _ in self?.handle(list, from: nil) }
        MIDISourceCreate(client, "ChromaSynth" as CFString, &upSource)
        if !dry { central = CBCentralManager(delegate: self, queue: nil) }   // (a dry run needs no Bluetooth permission)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t                              // (a dispatch source that is not kept stops)
    }

    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private func tick() {
        ticks += 1
        pollUSB()
        if transport == .usb {
            if ticks % 2 == 0 { send("hb") }                  // the heartbeat, twice a second: without it the ESP32 leaves USB mode after 2 s
            if ticks % 8 == 0 { send("mode"); send("up on") }                // every 2 s: which mode is the Chromatic in? (its menu may have changed it)
            if Date().timeIntervalSince(lastModeReply) > 8 { // no answer for 8 s: the console is gone or stuck
                print("USB: the ESP32 does not answer")
                usbSuppressed = true
                closeUSB()
            }
        }
        if ticks % 4 == 0 { connectKeyboards() }               // once a second
    }

    // ---- the ROM's MIDI out -> the DAW (the source "ChromaSynth")
    private func emitUp(_ msg: [UInt8]) {
        var buf = [UInt8](repeating: 0, count: 64)
        buf.withUnsafeMutableBytes { raw in
            let pl = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var p = MIDIPacketListInit(pl)
            var m = msg
            p = MIDIPacketListAdd(pl, 64, p, 0, m.count, &m)
            MIDIReceived(upSource, pl)
        }
    }

    /// A message from the ROM (BLE notification or USB console line). The ROM sends 12 clocks a beat: each gets a second one.
    private func fromChromatic(_ msg: [UInt8]) {
        if dry { print("up \(msg.map { String(format: "%02x", $0) }.joined(separator: " "))"); return }
        if msg.count == 1, msg[0] == 0xFA || msg[0] == 0xFB || msg[0] == 0xFC {
            print("Chromatic: MIDI \(msg[0] == 0xFA ? "start" : msg[0] == 0xFB ? "continue" : "stop")")
        }
        emitUp(msg)
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        if let d = clockDoubler.secondClock(after: msg, at: now) {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.emitUp([0xF8]) }
        }
    }

    // ---- MIDI in
    private func connectKeyboards() {
        if !listenKeyboards { return }
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            let n = midiName(src)
            if connectedSources.contains(src) || n.contains("ChromaSynth") || n.contains("IAC") { continue }
            MIDIPortConnectSource(inPort, src, nil)
            connectedSources.insert(src)
            print("listening to: \(n)")
        }
    }

    private func handle(_ list: UnsafePointer<MIDIPacketList>, from ref: UnsafeMutableRawPointer?) {
        for pkt in list.unsafeSequence() {
            let n = Int(pkt.pointee.length)
            let bytes = withUnsafeBytes(of: pkt.pointee.data) { Array($0.prefix(n)) }
            followDAW(bytes, stamp: pkt.pointee.timeStamp)
            for line in consoleLines(for: bytes, running: &running) {
                if !guardState.allow(at: Double(DispatchTime.now().uptimeNanoseconds) / 1e9) {
                    if guardState.trips != announcedTrip {
                        announcedTrip = guardState.trips
                        print("LOOP? More than \(guardState.limit) MIDI messages in a second: dropping until it is quiet for \(Int(guardState.quiet)) s.")
                        forward("m b0 7b 00")        // all notes off, so that nothing hangs
                    }
                    continue
                }
                forward(line)
            }
        }
    }

    /// The DAW's clock (Live: Preferences > Tempo & MIDI > the output port ChromaSynth, "Sync" on) gives the tempo; the ROM keeps its own
    /// clock (the link is too slow for 24 clocks a beat). A start forgets the tempo measured so far. The tempo goes as CC14 (the low
    /// part, BPM - 60 mod 128) and CC15 (the high part), on MIDI channel 1.
    private func followDAW(_ bytes: [UInt8], stamp: MIDITimeStamp) {
        var tbi = mach_timebase_info_data_t()
        mach_timebase_info(&tbi)
        // the packet's own time (host ticks) when the DAW gave one: the clocks arrive in bursts, so the arrival time is not their time
        let now = stamp != 0 ? Double(stamp) * Double(tbi.numer) / Double(tbi.denom) / 1e9 : Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        for b in bytes {
            if b == 0xFA { clockBpm.reset() }
            if b == 0xF8, let bpm = clockBpm.feed(at: now) {
                let v = bpm - 60
                print("DAW tempo: \(bpm) BPM")
                forward(String(format: "m b0 0e %02x", v % 128))
                forward(String(format: "m b0 0f %02x", v / 128))
            }
        }
    }

    private func forward(_ line: String) {
        sendLock.lock()
        defer { sendLock.unlock() }
        if switching { return }
        sent += 1
        if dry { print(line); return }
        switch transport {
        case .usb: send(line)
        case .ble:
            if let p = peripheral, let c = characteristic {
                let ts = UInt16(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds / 1_000_000) & 0x1FFF
                p.writeValue(Data(blePacketBytes(messageBytes(fromLine: line), timestamp: ts)), for: c, type: .withoutResponse)
            }
        case .none: break
        }
    }

    // ---- Bluetooth
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        bleReady = c.state == .poweredOn
        if bleReady { scan() } else { transport = transport == .usb ? .usb : .none }
        onChange?()
    }

    private func scan() {
        guard autoConnect, central != nil, bleReady, transport != .usb, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [Link.midiService], options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard autoConnect, peripheral == nil else { return }
        peripheral = p
        p.delegate = self
        c.stopScan()
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([Link.midiService])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == Link.midiService { p.discoverCharacteristics([Link.midiCharacteristic], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] where c.uuid == Link.midiCharacteristic {
            characteristic = c
            p.setNotifyValue(true, for: c)           // the ROM's MIDI out comes back as notifications (the ESP32 sends them once we subscribe)
            print("Bluetooth: subscribing to the MIDI notifications")
            if transport != .usb {
                transport = .ble
                p.writeValue(Data(blePacketBytes([0xB0, 123, 0], timestamp: 0)), for: c, type: .withoutResponse)   // all notes off: nothing may hang from before
            }
            print("Bluetooth: connected")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        print("Bluetooth: notifications \(c.isNotifying ? "on" : "off")\(error.map { " (\($0))" } ?? "")")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c.uuid == Link.midiCharacteristic, let d = c.value else { return }
        let msgs = parseBLEMIDI([UInt8](d))
        upCount += msgs.count
        if upCount <= 3 || upCount % 200 == 0 { print("Bluetooth: \(upCount) messages from the Chromatic (last packet \([UInt8](d).map { String(format: "%02x", $0) }.joined(separator: " ")))") }
        for m in msgs { fromChromatic(m) }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { bleLost() }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { bleLost() }

    private func bleLost() {
        peripheral = nil
        characteristic = nil
        if transport == .ble { transport = .none }
        print("Bluetooth: disconnected")
        if usbSuppressed, !serialPorts().isEmpty { usbSuppressed = false }   // BLE stopped while the cable is in: the menu was used to pick USB (or OFF)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    // ---- USB
    private func pollUSB() {
        if dry || !autoConnect || args.contains("--no-usb") { return }   // (--no-usb: leave the serial port to another program, e.g. a console test)
        let ports = serialPorts()
        if usbSuppressed {
            if ports.isEmpty { usbSuppressed = false; chromaticMode = "" }   // unplugged: the next plug-in is a new start
            return
        }
        if serialFD >= 0 {
            if !ports.contains(serialPath) { closeUSB() }
        } else if let p = ports.first, !usbBusy {
            usbBusy = true
            switching = true
            if transport == .ble, let per = peripheral, let c = characteristic {   // opening the port resets the ESP32: stop a held note first
                per.writeValue(Data(blePacketBytes([0xB0, 123, 0], timestamp: 0)), for: c, type: .withoutResponse)
            }
            usbQueue.async { [weak self] in self?.openUSB(p) }
        }
    }

    private func openUSB(_ path: String) {
        defer { usbBusy = false }
        usleep(200_000)                           // (the all-notes-off above leaves first)
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { DispatchQueue.main.async { [weak self] in self?.switching = false }; return }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, 115200)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        tcsetattr(fd, TCSANOW, &t)
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &bits)            // DTR and RTS off: they hold the ESP32 in reset
        serialFD = fd                              // (the port stays non-blocking: a write never hangs a thread)
        serialPath = path
        usbConfirmed = false
        consoleUp = false
        print("USB: opened \(path); the ESP32 resets once")
        lastModeReply = Date()
        DispatchQueue.global().async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            var tail = ""
            var lineBuf = ""
            let re = try! NSRegularExpression(pattern: "applied (USB|BLE|OFF)")
            while let me = self, me.serialFD == fd {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                    lineBuf += chunk
                    for line in takeLines(&lineBuf) {                                  // `u 90 3c 64`: the ROM's MIDI out
                        if let msg = uplinkMessage(fromLine: line) { DispatchQueue.main.async { me.fromChromatic(msg) } }
                    }
                    if lineBuf.count > 200 { lineBuf = "" }
                    let window = tail + chunk
                    if window.contains("mcu>") { me.consoleUp = true }
                    for m in re.matches(in: window, range: NSRange(window.startIndex..., in: window)) {
                        let mode = (window as NSString).substring(with: m.range(at: 1))
                        DispatchQueue.main.async { me.lastModeReply = Date() }
                        if mode == "USB" { me.usbConfirmed = true }
                        else if me.usbConfirmed {
                            me.usbConfirmed = false
                            DispatchQueue.main.async { me.mcuLeftUSB(fd, mode: mode) }
                        }
                    }
                    tail = String(window.suffix(10))     // (shorter than "applied USB": a match is never counted twice)
                } else { usleep(20000) }
            }
        }
        for _ in 0..<80 { if consoleUp { break }; usleep(100_000) }   // the ESP32 reset: wait for its console prompt (at most 8 s)
        for _ in 0..<12 {
            send("mode usb")
            for _ in 0..<15 { if usbConfirmed { break }; usleep(100_000) }
            if usbConfirmed { break }
        }
        DispatchQueue.main.async { [weak self] in
            guard let me = self, me.serialFD == fd else { return }
            me.switching = false
            if me.usbConfirmed {
                if let p = me.peripheral, let c = me.characteristic {        // a note that is held over BLE must not hang
                    p.writeValue(Data(blePacketBytes([0xB0, 123, 0], timestamp: 0)), for: c, type: .withoutResponse)
                }
                me.send("m b0 7b 00")                // all notes off on the new path
                me.send("up on")                     // and the ROM's MIDI out (the sequencer, SYNC = OUT) as `u ..` lines
                if let p = me.peripheral { me.central.cancelPeripheralConnection(p) }
                me.central.stopScan()
                me.transport = .usb
                print("USB: mode usb confirmed")
            } else {
                print("USB: the ESP32 did not confirm USB mode (is the console on?)")
            }
        }
    }

    private func closeUSB() {
        switching = false
        let fd = serialFD
        serialFD = -1
        if fd >= 0 { DispatchQueue.global().async { close(fd) } }
        print("USB: closed")
        if transport == .usb { transport = .none }
        scan()
    }

    /// The console says that the Chromatic is no longer in USB mode (its menu was used): give the port back, look for it over BLE.
    private func mcuLeftUSB(_ fd: Int32, mode: String) {
        guard serialFD == fd else { return }
        print("USB: the Chromatic is now in \(mode) mode")
        usbSuppressed = true
        chromaticMode = mode
        closeUSB()
    }

    private func send(_ line: String) {
        let fd = serialFD
        guard fd >= 0 else { return }
        let data = Array((line + "\r\n").utf8)
        ioQueue.async { Link.writeAll(fd, data) }
    }

    private static func writeAll(_ fd: Int32, _ data: [UInt8]) {
        var off = 0
        var waits = 0
        while off < data.count, waits < 20 {
            let n = data[off...].withUnsafeBytes { write(fd, $0.baseAddress, data.count - off) }
            if n > 0 { off += n }
            else if n < 0, errno == EAGAIN {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 50)
                waits += 1
            } else { return }
        }
    }

    func setListenKeyboards(_ on: Bool) {
        listenKeyboards = on
        UserDefaults.standard.set(on, forKey: "listenKeyboards")
        if !on {
            for src in connectedSources { MIDIPortDisconnectSource(inPort, src) }
            connectedSources.removeAll()
        }
        onChange?()
    }

    /// Menu: stop connecting by itself and drop the connection (the Chromatic goes back to its saved mode).
    func disconnect() {
        autoConnect = false
        central?.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        if serialFD >= 0 { send("mode saved"); ioQueue.sync {}; usleep(200_000); closeUSB() }
        transport = .none
        onChange?()
    }

    /// Menu: connect again (and keep connecting by itself).
    func connect() {
        autoConnect = true
        usbSuppressed = false
        scan()
        pollUSB()
        onChange?()
    }

    func shutdown() {
        if serialFD >= 0 { send("mode saved"); ioQueue.sync {}; usleep(300_000) }   // back to the mode that is saved on the Chromatic
    }
}

// ---------------------------------------------------------------- menu bar
final class AppDelegate: NSObject, NSApplicationDelegate {
    let link = Link()
    var item: NSStatusItem!
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
    let connectItem = NSMenuItem(title: "Disconnect", action: #selector(toggleConnect), keyEquivalent: "")
    let keysItem = NSMenuItem(title: "Play MIDI keyboards directly", action: #selector(toggleKeys), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(statusLine)
        connectItem.target = self
        menu.addItem(connectItem)
        keysItem.target = self
        menu.addItem(keysItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        let quit = NSMenuItem(title: "Quit ChromaSynth Link", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
        link.onChange = { [weak self] in self?.refresh() }
        link.start()
        refresh()
    }

    func refresh() {
        let on = link.transport != .none
        item.button?.title = on ? "♪●" : "♪○"
        statusLine.title = link.statusText
        connectItem.title = link.autoConnect ? "Disconnect" : "Connect"
        keysItem.state = link.listenKeyboards ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleKeys() {
        link.setListenKeyboards(!link.listenKeyboards)
        refresh()
    }

    @objc func toggleConnect() {
        if link.autoConnect { link.disconnect() } else { link.connect() }
        refresh()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { print("login item: \(error)") }
        refresh()
    }

    func applicationWillTerminate(_ n: Notification) { link.shutdown() }
}

if dry {
    let link = Link()
    link.start()
    print("dry run: MIDI output \"ChromaSynth\" created; lines are printed instead of being sent")
    RunLoop.main.run()
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
