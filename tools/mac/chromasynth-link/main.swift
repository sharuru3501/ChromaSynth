// ChromaSynth Link: a small menu bar app that connects this Mac's MIDI to the Chromatic running ChromaSynth.
//
//   - It creates the MIDI output "ChromaSynth" (a DAW's "MIDI To") and also listens to hardware MIDI keyboards.
//   - Bluetooth: it finds the Chromatic by itself (BLE MIDI service of the ESP32, name "ChromaSynth"), connects, and reconnects.
//     Nothing to set up in Audio MIDI Setup (do not connect it there as well: the notes would play twice).
//   - USB-C: when the Chromatic's serial port (/dev/cu.usbmodem*) appears, it takes over: it switches the ESP32 to USB mode,
//     sends the notes as console lines and a heartbeat every 3 s (without it the ESP32 goes back to its saved mode after 10 s).
//   - The ChromaSynth ROM must be on its KEYBOARD screen: the ESP32 sends the notes only then.
//
//   build: tools/mac/build_app.sh        command line: ChromaSynthLink --selftest | --dry-run | --list
import AppKit
import CoreBluetooth
import CoreMIDI
import Darwin
import Foundation
import ServiceManagement

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest() == 0 ? 0 : 1) }
let dry = args.contains("--dry-run")

func midiName(_ o: MIDIObjectRef) -> String {
    var s: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &s)
    return (s?.takeRetainedValue() as String?) ?? "?"
}

func serialPorts() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
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
    var statusText: String {
        switch transport {
        case .usb: return "Connected: USB"
        case .ble: return "Connected: Bluetooth"
        case .none: return bleReady ? "Looking for the Chromatic…" : "Bluetooth is off or not allowed"
        }
    }

    // MIDI
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var dest = MIDIEndpointRef()
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
    private let usbQueue = DispatchQueue(label: "chromasynth.usb")
    private var usbBusy = false

    func start() {
        MIDIClientCreate("ChromaSynth Link" as CFString, nil, nil, &client)
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &inPort) { [weak self] list, ref in self?.handle(list, from: ref) }
        MIDIDestinationCreateWithBlock(client, "ChromaSynth" as CFString, &dest) { [weak self] list, _ in self?.handle(list, from: nil) }
        if !dry { central = CBCentralManager(delegate: self, queue: nil) }   // (a dry run needs no Bluetooth permission)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t                              // (a dispatch source that is not kept stops)
    }

    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private func tick() {
        ticks += 1
        connectKeyboards()
        pollUSB()
        if ticks % 3 == 0, transport == .usb { send("hb") }
    }

    // ---- MIDI in
    private func connectKeyboards() {
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

    private func forward(_ line: String) {
        sendLock.lock()
        defer { sendLock.unlock() }
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
        guard central != nil, bleReady, transport != .usb, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [Link.midiService], options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard peripheral == nil else { return }
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
            if transport != .usb { transport = .ble }
            print("Bluetooth: connected")
        }
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { bleLost() }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { bleLost() }

    private func bleLost() {
        peripheral = nil
        characteristic = nil
        if transport == .ble { transport = .none }
        print("Bluetooth: disconnected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    // ---- USB
    private func pollUSB() {
        if dry { return }
        let ports = serialPorts()
        if serialFD >= 0 {
            if !ports.contains(serialPath) { closeUSB() }
        } else if let p = ports.first, !usbBusy {
            usbBusy = true
            usbQueue.async { [weak self] in self?.openUSB(p) }
        }
    }

    private func openUSB(_ path: String) {
        defer { usbBusy = false }
        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if fd < 0 { return }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, 115200)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        tcsetattr(fd, TCSANOW, &t)
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &bits)            // DTR and RTS off: they hold the ESP32 in reset
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        serialFD = fd
        serialPath = path
        usbConfirmed = false
        print("USB: opened \(path); the ESP32 resets once")
        DispatchQueue.global().async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            var text = ""
            while let me = self, me.serialFD == fd {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    text += String(decoding: buf[0..<n], as: UTF8.self)
                    if text.count > 4000 { text = String(text.suffix(2000)) }
                    if text.contains("applied USB") { me.usbConfirmed = true }
                } else { usleep(20000) }
            }
        }
        sleep(3)                                  // the console may not be up yet; a command sent too early is lost
        for _ in 0..<12 {
            send("mode usb")
            for _ in 0..<15 { if usbConfirmed { break }; usleep(100_000) }
            if usbConfirmed { break }
        }
        DispatchQueue.main.async { [weak self] in
            guard let me = self, me.serialFD == fd else { return }
            if me.usbConfirmed {
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
        let fd = serialFD
        serialFD = -1
        if fd >= 0 { close(fd) }
        print("USB: unplugged")
        if transport == .usb { transport = .none }
        scan()
    }

    private func send(_ line: String) {
        guard serialFD >= 0 else { return }
        let data = Array((line + "\r\n").utf8)
        _ = data.withUnsafeBytes { write(serialFD, $0.baseAddress, data.count) }
    }

    func shutdown() {
        if serialFD >= 0 { send("mode saved"); usleep(300_000) }   // back to the mode that is saved on the Chromatic
    }
}

// ---------------------------------------------------------------- menu bar
final class AppDelegate: NSObject, NSApplicationDelegate {
    let link = Link()
    var item: NSStatusItem!
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(statusLine)
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
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
