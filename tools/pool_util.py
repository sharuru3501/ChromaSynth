"""Reading and writing the pattern cells of the ROM from a PyBoy test (docs/M19_PATTERN_POOL.md).

A pattern's half (segment 0 / 1) is in a pool segment: wPatSeg[pattern * 2 + half] = its id, 0xFF = not lent (reads as zeros).
Segment id n: WRAM bank 1 + n // 4, the page of channel c is 0xD0 + (n % 4) * 4 + c, the cell of tick t is page * 256 + t.
"""
NO_SEG = 0xFF
POOL_SEGS = 27
SEG_TICKS = 192


class Pool:
    def __init__(self, mem, sym):
        self.mem, self.sym = mem, sym
        self.table = sym["wPatSeg"]

    def seg(self, p, g):
        return self.mem[self.table + p * 2 + g]

    def lent(self):
        return [self.seg(p, g) for p in range(16) for g in range(2) if self.seg(p, g) != NO_SEG]

    def _addr(self, sid, ch, tick):
        return 1 + sid // 4, ((0xD0 + (sid % 4) * 4 + ch) << 8) | tick

    def lend(self, p, g):
        """Give the half a segment (zeroed), as the ROM's EnsureSeg does. -> the id."""
        sid = self.seg(p, g)
        if sid != NO_SEG:
            return sid
        used = set(self.lent())
        sid = next(i for i in range(POOL_SEGS) if i not in used)
        self.mem[self.table + p * 2 + g] = sid
        for ch in range(4):
            for t in range(256):
                bank, a = self._addr(sid, ch, t)
                self.mem[bank, a] = 0
        return sid

    def get(self, p, ch, g, tick):
        sid = self.seg(p, g)
        if sid == NO_SEG:
            return 0
        bank, a = self._addr(sid, ch, tick)
        return self.mem[bank, a]

    def put(self, p, ch, g, tick, value):
        sid = self.lend(p, g)
        bank, a = self._addr(sid, ch, tick)
        self.mem[bank, a] = value

    def get_abs(self, p, ch, t):
        return self.get(p, ch, 0, t) if t < SEG_TICKS else self.get(p, ch, 1, t - SEG_TICKS)

    def put_abs(self, p, ch, t, value):
        if t < SEG_TICKS:
            self.put(p, ch, 0, t, value)
        else:
            self.put(p, ch, 1, t - SEG_TICKS, value)

    def clear_channel(self, p, ch):
        for g in range(2):
            if self.seg(p, g) != NO_SEG:
                for t in range(SEG_TICKS):
                    self.put(p, ch, g, t, 0)

    def clear_pattern(self, p):
        """All four channels zero; the halves are given back (the ROM counts the sizes again at the next edit)."""
        for g in range(2):
            sid = self.seg(p, g)
            if sid != NO_SEG:
                for ch in range(4):
                    for t in range(256):
                        bank, a = self._addr(sid, ch, t)
                        self.mem[bank, a] = 0
                self.mem[self.table + p * 2 + g] = NO_SEG

    def zero_segment_is_zero(self):
        for ch in range(4):
            for t in range(256):
                bank, a = self._addr(27, ch, t)
                if self.mem[bank, a] != 0:
                    return False
        return True


# ---- the save format (version 10, src/sram.asm), as a second opinion on the ROM's coder
SAVE_HEADER = 12 + 8 + 160 + 16 + 2 + 3 * 16 + 1 + 64
RAW_MIN = 168


def decode_channel(buf, pos):
    """-> (192 cells, new position)"""
    mode = buf[pos]
    pos += 1
    if mode == 0:
        return [0] * 192, pos
    if mode == 2:
        return list(buf[pos:pos + 192]), pos + 192
    bits = buf[pos:pos + 24]
    pos += 24
    cells = []
    for t in range(192):
        if bits[t // 8] >> (t % 8) & 1:
            cells.append(buf[pos])
            pos += 1
        else:
            cells.append(0)
    return cells, pos


def encode_channel(cells):
    n = sum(1 for c in cells if c)
    if n == 0:
        return bytes([0])
    if n >= RAW_MIN:
        return bytes([2]) + bytes(cells)
    bits = bytearray(24)
    for t, c in enumerate(cells):
        if c:
            bits[t // 8] |= 1 << (t % 8)
    return bytes([1]) + bytes(bits) + bytes(c for c in cells if c)


def parse_v10(slot):
    """A slot (8192 bytes) of a version 10 save -> dict(length, mask, segments={(pattern, half): [4 channels x 192 cells]}, name, ts, ...) or None if the sum is wrong."""
    if slot[:5] != b"CSYN\x0a":
        return None
    length = slot[6] | slot[7] << 8
    if sum(slot[6:SAVE_HEADER + length]) & 0xFF ^ 0xA5 != slot[5]:
        return None
    mask = int.from_bytes(slot[8:12], "little")
    pos = SAVE_HEADER
    segs = {}
    for idx in range(32):
        if mask >> idx & 1:
            chans = []
            for _ in range(4):
                cells, pos = decode_channel(slot, pos)
                chans.append(cells)
            segs[(idx // 2, idx % 2)] = chans
    assert pos == SAVE_HEADER + length, (pos, SAVE_HEADER + length)
    return {"length": length, "mask": mask, "segments": segs, "name": list(slot[12:20])}


def to_v9(slot, zero_ts=False):
    """The same song as a version 9 slot (4 patterns x 2 halves, every channel 192 raw bytes), to test that the ROM still reads those."""
    parsed = parse_v10(slot)
    out = bytearray(8192)
    out[0:5] = b"CSYN\x09"
    out[5:165] = slot[20:180]            # the patches
    out[165:181] = slot[180:196]         # the chain
    out[181] = slot[196]                 # bpm
    out[182] = slot[197]                 # loop bars
    pos = 183
    for p in range(4):
        for ch in range(4):
            for g in range(2):
                seg = parsed["segments"].get((p, g))
                out[pos:pos + 192] = bytes(seg[ch]) if seg else bytes(192)
                pos += 192
    assert pos == 6327
    out[6327] = (sum(out[5:6327]) & 0xFF) ^ 0xA5
    out[6328:6336] = slot[12:20]         # the name
    tsn, tsd, bars = slot[198:214], slot[214:230], slot[230:246]
    if not zero_ts:
        out[6336:6340], out[6340:6344], out[6344:6348] = tsn[:4], tsd[:4], bars[:4]
    out[6348:6413] = slot[246:311]       # the waves
    return bytes(out)
