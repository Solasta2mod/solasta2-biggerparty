"""Walk the Lua 5.4 CallInfo chain of the crashing thread from a minidump (Lua object pointer in a register)."""
import struct, sys
path = sys.argv[1]; reg = sys.argv[2] if len(sys.argv) > 2 else 'rdi'
d = open(path, 'rb').read()
sig, ver, nstreams, dirrva = struct.unpack_from('<4sIII', d, 0)
streams = {}
for i in range(nstreams):
    stype, dsize, rva = struct.unpack_from('<III', d, dirrva + i * 12)
    streams.setdefault(stype, []).append((dsize, rva))
ranges = []
if 9 in streams:
    dsize, rva = streams[9][0]
    n, baserva = struct.unpack_from('<QQ', d, rva); off = baserva
    for i in range(n):
        start, size = struct.unpack_from('<QQ', d, rva + 16 + i * 16); ranges.append((start, size, off)); off += size
if 5 in streams:
    dsize, rva = streams[5][0]
    n = struct.unpack_from('<I', d, rva)[0]
    for i in range(n):
        start, size, r = struct.unpack_from('<QII', d, rva + 4 + i * 16); ranges.append((start, size, r))
ranges.sort()
def read(addr, n):
    for start, size, off in ranges:
        if start <= addr < start + size:
            k = min(n, start + size - addr)
            return d[off + (addr - start): off + (addr - start) + k]
    return None
def q(addr):
    b = read(addr, 8)
    return struct.unpack('<Q', b)[0] if b and len(b) == 8 else None
def i32(addr):
    b = read(addr, 4)
    return struct.unpack('<i', b)[0] if b and len(b) == 4 else None
def tstring(addr):
    b = read(addr + 0x18, 200)
    if not b: return "<no mem %X>" % addr
    return b.split(b'\0', 1)[0].decode('utf-8', 'replace')
dsize, rva = streams[6][0]
ctx_size, ctx_rva = struct.unpack_from('<II', d, rva + 160)
regs = {}
for nm, off in (('rax', 0x78), ('rcx', 0x80), ('rdx', 0x88), ('rbx', 0x90), ('rsp', 0x98), ('rbp', 0xA0), ('rsi', 0xA8), ('rdi', 0xB0), ('r8', 0xB8), ('r9', 0xC0), ('r10', 0xC8), ('r11', 0xD0), ('r12', 0xD8), ('r13', 0xE0), ('r14', 0xE8), ('r15', 0xF0)):
    regs[nm] = struct.unpack_from('<Q', d, ctx_rva + off)[0]
luaobj = regs[reg]
L = q(luaobj)
print("Lua object at %X -> lua_State %s" % (luaobj, ("%X" % L) if L else None))
if L is None:
    # maybe the register is L itself
    L = luaobj
print("lua_State %X: mem present=%s" % (L, read(L, 8) is not None))
top, lG, ci, stack = q(L + 0x10), q(L + 0x18), q(L + 0x20), q(L + 0x30)
print("  top=%s l_G=%s ci=%s stack=%s" % tuple(("%X" % v) if v is not None else None for v in (top, lG, ci, stack)))
def describe(slot):
    tb = read(slot + 8, 1); val = q(slot)
    if tb is None: return "<no mem>"
    t = tb[0]; base = t & 0x3F
    if base == 0x00: return "nil"
    if base in (0x01, 0x11): return "bool"
    if base == 0x03: return "int %d" % (struct.unpack('<q', struct.pack('<Q', val))[0])
    if base == 0x13: return "float %r" % struct.unpack('<d', struct.pack('<Q', val))[0]
    if base in (0x04, 0x14): return "string %r" % tstring(val)
    if base == 0x05: return "table %X" % val
    if base == 0x06: return "Lua closure %X" % val
    if base in (0x16, 0x26): return "C function"
    if base == 0x07:
        # full userdata: Udata header (0x28 bytes + 16 per user value); nuvalue at +0xA
        nb = read(val + 0xA, 2); nuv = struct.unpack('<H', nb)[0] if nb else -1
        block = val + 0x28 + 16 * max(nuv, 0) if nuv >= 0 else None
        first = q(block) if block else None
        return "userdata %X nuvalue=%d first-qword=%s" % (val, nuv, ("%X" % first) if first is not None else "?")
    if base == 0x02: return "light userdata %X" % val
    return "tt=%02X val=%X" % (t, val or 0)
if top and stack:
    print("stack top-1 .. top-8:")
    for k in range(1, 9):
        slot = top - 16 * k
        if slot < stack: break
        print("  [top-%d] %s" % (k, describe(slot)))
n = 0
while ci and n < 40:
    func, citop, prev, nxt = q(ci), q(ci + 8), q(ci + 0x10), q(ci + 0x18)
    savedpc = q(ci + 0x20)
    cs = read(ci + 0x36, 2)
    callstatus = struct.unpack('<H', cs)[0] if cs else None
    line = "ci#%d @%X func=%s callstatus=%s" % (n, ci, ("%X" % func) if func else None, ("%04X" % callstatus) if callstatus is not None else None)
    if func:
        tt = read(func + 8, 1)
        val = q(func)
        if tt is not None:
            t = tt[0]
            line += " tt=%02X" % t
            if (t & 0x3F) == 0x06 and val:          # Lua closure
                proto = q(val + 0x18)
                if proto:
                    ld, lld = i32(proto + 0x2C), i32(proto + 0x30)
                    src = q(proto + 0x70); code = q(proto + 0x40)
                    where = tstring(src) if src else "?"
                    pc = ((savedpc - code) // 4 - 1) if (savedpc and code) else None
                    # current line from lineinfo (ls_byte deltas) + abslineinfo
                    cur = None
                    if pc is not None and ld is not None:
                        sizeli = i32(proto + 0x1C); li = q(proto + 0x58)
                        if li and sizeli and 0 <= pc < sizeli:
                            lb = read(li, pc + 1)
                            if lb and len(lb) == pc + 1:
                                if all(x != 0x80 for x in lb):      # no absolute-line markers before pc
                                    cur = ld + sum((x - 256) if x > 127 else x for x in lb)
                                else:
                                    cur = "(abs marker)"
                    line += " LUA proto=%X defined@%s-%s pc=%s line=%s source=%s" % (proto, ld, lld, pc, cur, where)
                else:
                    line += " LUA closure %X (proto mem missing)" % val
            elif (t & 0x3F) == 0x16 or (t & 0x3F) == 0x26:  # light C function / C closure
                f = val if (t & 0x3F) == 0x16 else (q(val + 0x18) if val else None)
                line += " C function %s" % (("%X" % f) if f else "?")
            else:
                line += " value=%X" % (val or 0)
    print(line)
    ci = prev; n += 1
