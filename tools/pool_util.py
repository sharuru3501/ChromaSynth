"""Reading and writing the pattern cells of the ROM from a PyBoy test (docs/M19_PATTERN_POOL.md, docs/M20_PER_CHANNEL_CHAINS.md).

A pattern's channel half (channel 0-3, half 0 / 1 = 4 bars each) is in a pool page: wPatPage[pattern * 8 + channel * 2 + half] = the page id,
0xFF = not lent (reads as zeros). Page id n: WRAM bank 1 + n // 16, page 0xD0 + n % 16, the cell of tick t is page * 256 + t.
wPageMap has a bit for every page id that is lent (the ROM looks there for a free one), so a test that lends a page must set it too.
"""
NO_PAGE = 0xFF
POOL_PAGES = 111
ZERO_PAGE = 111
SEG_TICKS = 192
NUM_PATS = 16


class Pool:
    def __init__(self, mem, sym):
        self.mem, self.sym = mem, sym
        self.table = sym["wPatPage"]
        self.map = sym["wPageMap"]

    def page(self, p, ch, g):
        return self.mem[self.table + p * 8 + ch * 2 + g]

    def lent(self):
        return [self.page(p, ch, g) for p in range(NUM_PATS) for ch in range(4) for g in range(2) if self.page(p, ch, g) != NO_PAGE]

    def half_lent(self, p, g):
        return any(self.page(p, ch, g) != NO_PAGE for ch in range(4))

    def _addr(self, pid, tick):
        return 1 + pid // 16, ((0xD0 + pid % 16) << 8) | tick

    def _setmap(self, pid, on):
        a = self.map + pid // 8
        bit = 1 << (pid % 8)
        self.mem[a] = (self.mem[a] | bit) if on else (self.mem[a] & ~bit & 0xFF)

    def lend(self, p, ch, g):
        """Give the channel half a page (zeroed), as the ROM's EnsurePage does. -> the id."""
        pid = self.page(p, ch, g)
        if pid != NO_PAGE:
            return pid
        used = set(self.lent())
        pid = next(i for i in range(POOL_PAGES) if i not in used)
        self.mem[self.table + p * 8 + ch * 2 + g] = pid
        self._setmap(pid, True)
        for t in range(256):
            bank, a = self._addr(pid, t)
            self.mem[bank, a] = 0
        return pid

    def release(self, p, ch, g):
        pid = self.page(p, ch, g)
        if pid != NO_PAGE:
            self.mem[self.table + p * 8 + ch * 2 + g] = NO_PAGE
            self._setmap(pid, False)

    def get(self, p, ch, g, tick):
        pid = self.page(p, ch, g)
        if pid == NO_PAGE:
            return 0
        bank, a = self._addr(pid, tick)
        return self.mem[bank, a]

    def put(self, p, ch, g, tick, value):
        pid = self.lend(p, ch, g)
        bank, a = self._addr(pid, tick)
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
            self.release(p, ch, g)

    def clear_pattern(self, p):
        """All channels empty; the pages are given back (the ROM counts the sizes again at the next edit)."""
        for ch in range(4):
            self.clear_channel(p, ch)

    def zero_page_is_zero(self):
        return all(self.mem[self._addr(ZERO_PAGE, t)[0], self._addr(ZERO_PAGE, t)[1]] == 0 for t in range(256))

    zero_segment_is_zero = zero_page_is_zero


# ---- the save format, as a second opinion on the ROM's coder (src/sram.asm)
SAVE_NAME = 24
FIXED_LEN = 8 + 160 + 16 + 2 + 3 * 16 + 1 + 64
SAVE_HEADER = SAVE_NAME + FIXED_LEN            # 323
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


def parse_save(slot):
    """A version 11 slot (8192 bytes) -> dict(length, mask, pages={(pattern, channel, half): 192 cells}, name) or None if it is not one / the sum is wrong."""
    if slot[:5] != b"CSYN\x0b":
        return None
    length = slot[6] | slot[7] << 8
    if (sum(slot[6:SAVE_HEADER + length]) & 0xFF) ^ 0xA5 != slot[5]:
        return None
    mask = int.from_bytes(slot[8:24], "little")
    pos = SAVE_HEADER
    pages = {}
    for idx in range(128):
        if mask >> idx & 1:
            cells, pos = decode_channel(slot, pos)
            pages[(idx // 8, idx // 2 % 4, idx % 2)] = cells
    assert pos == SAVE_HEADER + length, (pos, SAVE_HEADER + length)
    return {"length": length, "mask": mask, "pages": pages, "name": list(slot[24:32])}


parse_v10 = parse_save   # (the older tests' name)


def _fixed(slot):
    """The name .. waves block of a version 11 slot."""
    return slot[SAVE_NAME:SAVE_NAME + FIXED_LEN]


def to_v10(slot):
    """The same song as a version 10 slot (whole segments of 4 coded channels, a 4-byte mask), for the ROM's migration."""
    parsed = parse_save(slot)
    segs = {}
    for (p, ch, g), cells in parsed["pages"].items():
        segs.setdefault((p, g), [[0] * 192 for _ in range(4)])[ch] = cells
    out = bytearray(8192)
    out[0:5] = b"CSYN\x0a"
    fixed = _fixed(slot)
    mask = 0
    region = bytearray()
    for idx in range(32):
        p, g = idx // 2, idx % 2
        if (p, g) in segs:
            mask |= 1 << idx
            for ch in range(4):
                region += encode_channel(segs[(p, g)][ch])
    out[8:12] = mask.to_bytes(4, "little")
    out[12:12 + FIXED_LEN] = fixed
    hdr = 12 + FIXED_LEN
    out[hdr:hdr + len(region)] = region
    out[6:8] = len(region).to_bytes(2, "little")
    out[5] = (sum(out[6:hdr + len(region)]) & 0xFF) ^ 0xA5
    return bytes(out)


def to_v9(slot, zero_ts=False):
    """The same song as a version 9 slot (4 patterns x 2 halves, every channel 192 raw bytes), to test that the ROM still reads those."""
    parsed = parse_save(slot)
    out = bytearray(8192)
    out[0:5] = b"CSYN\x09"
    f = _fixed(slot)                      # name 8, patch 160, chain 16, bpm, bars, tsn 16, tsd 16, bars 16, waves 65
    out[5:165] = f[8:168]
    out[165:181] = f[168:184]
    out[181] = f[184]
    out[182] = f[185]
    pos = 183
    for p in range(4):
        for ch in range(4):
            for g in range(2):
                cells = parsed["pages"].get((p, ch, g))
                out[pos:pos + 192] = bytes(cells) if cells else bytes(192)
                pos += 192
    assert pos == 6327
    out[6327] = (sum(out[5:6327]) & 0xFF) ^ 0xA5
    out[6328:6336] = f[0:8]
    tsn, tsd, bars = f[186:202], f[202:218], f[218:234]
    if not zero_ts:
        out[6336:6340], out[6340:6344], out[6344:6348] = tsn[:4], tsd[:4], bars[:4]
    out[6348:6413] = f[234:299]
    return bytes(out)
