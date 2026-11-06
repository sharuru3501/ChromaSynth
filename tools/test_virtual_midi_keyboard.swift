import CoreMIDI
import Foundation
// A virtual MIDI keyboard "TestKbd": after 3 s sends C4 on/off, E4 on, a CC7 (not forwarded), all-notes-off, then exits.
setvbuf(stdout, nil, _IOLBF, 0)
var client = MIDIClientRef()
MIDIClientCreate("virtkbd" as CFString, nil, nil, &client)
var src = MIDIEndpointRef()
MIDISourceCreate(client, "TestKbd" as CFString, &src)
func send(_ b: [UInt8]) {
    var buf = [UInt8](repeating: 0, count: 256)
    buf.withUnsafeMutableBytes { raw in
        let pl = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
        var p = MIDIPacketListInit(pl)
        var m = b
        p = MIDIPacketListAdd(pl, 256, p, 0, b.count, &m)
        MIDIReceived(src, pl)
    }
}
sleep(4)
send([0x90, 60, 100]); usleep(100_000)
send([0x80, 60, 0]); usleep(100_000)
send([0x90, 64, 90, 0xB0, 7, 100]); usleep(100_000)   // a note-on and a CC7 in one packet
send([0xB0, 123, 0]); usleep(100_000)
send([0xC0, 5]); usleep(100_000)                        // program change: not forwarded
// and into the helper's own virtual MIDI output "ChromaSynth USB" (what Live does): a CC7 is not forwarded, a note-on is
var dest = MIDIEndpointRef()
for i in 0..<MIDIGetNumberOfDestinations() {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(MIDIGetDestination(i), kMIDIPropertyDisplayName, &name)
    if (name?.takeRetainedValue() as String?) == "ChromaSynth USB" { dest = MIDIGetDestination(i) }
}
if dest != 0 {
    var out = MIDIPortRef()
    MIDIOutputPortCreate(client, "out" as CFString, &out)
    for b in [[UInt8]([0x90, 67, 80]), [0xB0, 7, 90], [0x80, 67, 0]] {
        var buf = [UInt8](repeating: 0, count: 256)
        buf.withUnsafeMutableBytes { raw in
            let pl = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            var p = MIDIPacketListInit(pl)
            var m = b
            p = MIDIPacketListAdd(pl, 256, p, 0, b.count, &m)
            MIDISend(out, dest, pl)
        }
        usleep(100_000)
    }
} else { print("virtkbd: no ChromaSynth USB destination found") }
print("virtkbd done")
sleep(1)
