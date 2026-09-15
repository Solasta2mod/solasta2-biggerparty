"""Minimal minidump reader: exception record, crashing-thread context, module list, and a return-address scan of the stack."""
import struct, sys, bisect
path = sys.argv[1]
d = open(path, 'rb').read()
sig, ver, nstreams, dirrva = struct.unpack_from('<4sIII', d, 0)
assert sig == b'MDMP', sig
streams = {}
for i in range(nstreams):
    stype, dsize, rva = struct.unpack_from('<III', d, dirrva + i * 12)
    streams.setdefault(stype, []).append((dsize, rva))
def mstring(rva):
    n = struct.unpack_from('<I', d, rva)[0]
    return d[rva + 4:rva + 4 + n].decode('utf-16le', 'replace')
mods = []
dsize, rva = streams[4][0]
n = struct.unpack_from('<I', d, rva)[0]
for i in range(n):
    base, size, chk, ts, namerva = struct.unpack_from('<QIIII', d, rva + 4 + i * 108)
    mods.append((base, size, mstring(namerva)))
mods.sort()
def modof(a):
    for base, size, name in mods:
        if base <= a < base + size: return name.rsplit(chr(92), 1)[-1], a - base
    return None, None
ranges = []
if 9 in streams:
    dsize, rva = streams[9][0]
    n, baserva = struct.unpack_from('<QQ', d, rva)
    off = baserva
    for i in range(n):
        start, size = struct.unpack_from('<QQ', d, rva + 16 + i * 16)
        ranges.append((start, size, off)); off += size
if 5 in streams:
    dsize, rva = streams[5][0]
    n = struct.unpack_from('<I', d, rva)[0]
    for i in range(n):
        start, size, r = struct.unpack_from('<QII', d, rva + 4 + i * 16)
        ranges.append((start, size, r))
ranges.sort()
def read(addr, n):
    for start, size, off in ranges:
        if start <= addr < start + size:
            k = min(n, start + size - addr)
            return d[off + (addr - start): off + (addr - start) + k]
    return None
print("streams:", sorted(streams), " modules:", len(mods), " memory ranges:", len(ranges), " total mem: %.1f MB" % (sum(r[1] for r in ranges) / 1e6))
for base, size, name in mods:
    nm = name.rsplit(chr(92), 1)[-1]
    if nm.lower() in ('brimstone-win64-shipping.exe', 'ue4ss.dll', 'version.dll', 'ntdll.dll', 'kernelbase.dll', 'ucrtbase.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'd3d12.dll', 'dxgi.dll'):
        print("  module %-32s base=%016X size=%X" % (nm, base, size))
if 6 in streams:
    dsize, rva = streams[6][0]
    tid, _ = struct.unpack_from('<II', d, rva)
    code, eflags, erec, eaddr, nparams, _ = struct.unpack_from('<IIQQII', d, rva + 8)
    params = struct.unpack_from('<15Q', d, rva + 40)
    ctx_size, ctx_rva = struct.unpack_from('<II', d, rva + 160)
    m, o = modof(eaddr)
    print("exception: code=%08X flags=%X addr=%016X (%s+%X) thread=%d params=%s" % (code, eflags, eaddr, m, o or 0, tid, [hex(p) for p in params[:nparams]]))
    ctx = d[ctx_rva:ctx_rva + ctx_size]
    regs = {}
    for nm, off in (('rax', 0x78), ('rcx', 0x80), ('rdx', 0x88), ('rbx', 0x90), ('rsp', 0x98), ('rbp', 0xA0), ('rsi', 0xA8), ('rdi', 0xB0), ('r8', 0xB8), ('r9', 0xC0), ('r10', 0xC8), ('r11', 0xD0), ('r12', 0xD8), ('r13', 0xE0), ('r14', 0xE8), ('r15', 0xF0), ('rip', 0xF8)):
        regs[nm] = struct.unpack_from('<Q', ctx, off)[0]
    print("registers:")
    for nm in ('rip', 'rsp', 'rbp', 'rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'):
        m, o = modof(regs[nm])
        print("  %-3s %016X %s" % (nm, regs[nm], ("(%s+%X)" % (m, o)) if m else ""))
    m, o = modof(regs['rip'])
    code_bytes = read(regs['rip'] - 16, 48)
    if code_bytes: print("code around rip:", code_bytes[:16].hex(), "|", code_bytes[16:].hex())
    rsp = regs['rsp']
    stack = read(rsp, 0x8000)
    print("stack scan from rsp (%d bytes available):" % (len(stack) if stack else 0))
    if stack:
        hits = 0
        for i in range(0, len(stack) - 7, 8):
            v = struct.unpack_from('<Q', stack, i)[0]
            m, o = modof(v)
            if m and m.lower() not in ('ntdll.dll',) or (m and m.lower() == 'ntdll.dll' and i < 0x200):
                print("  [rsp+%05X] %016X %s+%X" % (i, v, m, o))
                hits += 1
                if hits >= int(sys.argv[2]) if len(sys.argv) > 2 else 150: break
# thread list: which threads are there (names not stored), count
if 3 in streams:
    dsize, rva = streams[3][0]
    n = struct.unpack_from('<I', d, rva)[0]
    print("threads:", n)
