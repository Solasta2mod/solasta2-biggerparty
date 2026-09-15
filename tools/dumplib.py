import struct
class Dump:
    def __init__(self, path):
        d = self.d = open(path, 'rb').read()
        sig, ver, nstreams, dirrva = struct.unpack_from('<4sIII', d, 0)
        self.streams = {}
        for i in range(nstreams):
            stype, dsize, rva = struct.unpack_from('<III', d, dirrva + i * 12)
            self.streams.setdefault(stype, []).append((dsize, rva))
        self.ranges = []
        if 9 in self.streams:
            dsize, rva = self.streams[9][0]; n, baserva = struct.unpack_from('<QQ', d, rva); off = baserva
            for i in range(n):
                start, size = struct.unpack_from('<QQ', d, rva + 16 + i * 16); self.ranges.append((start, size, off)); off += size
        if 5 in self.streams:
            dsize, rva = self.streams[5][0]; n = struct.unpack_from('<I', d, rva)[0]
            for i in range(n):
                start, size, r = struct.unpack_from('<QII', d, rva + 4 + i * 16); self.ranges.append((start, size, r))
        self.ranges.sort()
        dsize, rva = self.streams[6][0]
        ctx_size, ctx_rva = struct.unpack_from('<II', d, rva + 160)
        self.regs = {}
        for nm, off in (('rax', 0x78), ('rcx', 0x80), ('rdx', 0x88), ('rbx', 0x90), ('rsp', 0x98), ('rbp', 0xA0), ('rsi', 0xA8), ('rdi', 0xB0), ('r8', 0xB8), ('r9', 0xC0), ('r10', 0xC8), ('r11', 0xD0), ('r12', 0xD8), ('r13', 0xE0), ('r14', 0xE8), ('r15', 0xF0), ('rip', 0xF8)):
            self.regs[nm] = struct.unpack_from('<Q', d, ctx_rva + off)[0]
    def read(self, addr, n):
        for start, size, off in self.ranges:
            if start <= addr < start + size:
                k = min(n, start + size - addr)
                return self.d[off + (addr - start): off + (addr - start) + k]
        return None
    def q(self, addr):
        b = self.read(addr, 8); return struct.unpack('<Q', b)[0] if b and len(b) == 8 else None
    def i32(self, addr):
        b = self.read(addr, 4); return struct.unpack('<i', b)[0] if b and len(b) == 4 else None
    def tstring(self, addr):
        b = self.read(addr + 0x18, 200)
        return b.split(b'\0', 1)[0].decode('utf-8', 'replace') if b else "<no mem %X>" % addr
    def describe(self, slot):
        tb = self.read(slot + 8, 1); val = self.q(slot)
        if tb is None: return "<no mem>"
        t = tb[0]; base = t & 0x3F
        if base == 0x00: return "nil"
        if base == 0x01: return "false"
        if base == 0x11: return "true"
        if base == 0x03: return "int %d" % struct.unpack('<q', struct.pack('<Q', val))[0]
        if base == 0x13: return "float %r" % struct.unpack('<d', struct.pack('<Q', val))[0]
        if base in (0x04, 0x14): return "string %r" % self.tstring(val)
        if base == 0x05: return "table %X" % val
        if base == 0x06: return "Lua closure %X" % val
        if base == 0x16: return "light C function %X" % val
        if base == 0x26: return "C closure %X" % val
        if base == 0x07:
            nb = self.read(val + 0xA, 2); nuv = struct.unpack('<H', nb)[0] if nb else -1
            block = val + 0x28 + 16 * nuv if nuv >= 0 else None
            first = self.q(block) if block else None
            return "userdata %X nuvalue=%d first-qword=%s" % (val, nuv, ("%X" % first) if first is not None else "?")
        if base == 0x02: return "light userdata %X" % val
        return "tt=%02X val=%X" % (t, val or 0)
