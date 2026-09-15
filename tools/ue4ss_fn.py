"""Function bounds (from .pdata) + string/call references for RVAs inside a PE (UE4SS.dll)."""
import struct, sys, bisect, re
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
pe = sys.argv[1]; d = open(pe, 'rb').read()
e_lfanew = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, e_lfanew + 6)[0]
optsz = struct.unpack_from('<H', d, e_lfanew + 20)[0]
opt = e_lfanew + 24
imgbase = struct.unpack_from('<Q', d, opt + 24)[0]
ddir = opt + 112
exc_rva, exc_sz = struct.unpack_from('<II', d, ddir + 3 * 8)
secs = []
for i in range(nsec):
    s = e_lfanew + 24 + optsz + i * 40
    name = d[s:s + 8].rstrip(b'\0').decode()
    vsize, va, rsize, roff = struct.unpack_from('<IIII', d, s + 8)
    secs.append((va, vsize, roff, rsize, name))
def rva2off(r):
    for va, vsize, roff, rsize, name in secs:
        if va <= r < va + max(vsize, rsize): return roff + (r - va)
    return None
def secname(r):
    for va, vsize, roff, rsize, name in secs:
        if va <= r < va + max(vsize, rsize): return name
    return '?'
n = exc_sz // 12
funcs = []
o = rva2off(exc_rva)
for i in range(n):
    b, e, u = struct.unpack_from('<III', d, o + i * 12)
    funcs.append((b, e))
funcs.sort()
begins = [f[0] for f in funcs]
def bounds(r):
    i = bisect.bisect_right(begins, r) - 1
    while i >= 0:
        b, e = funcs[i]
        if b <= r < e: return b, e
        i -= 1
    return None
md = Cs(CS_ARCH_X86, CS_MODE_64); md.detail = False
asc = re.compile(rb'[\x20-\x7e]{4,}')
uni = re.compile(rb'(?:[\x20-\x7e]\x00){4,}')
def strat(r):
    o = rva2off(r)
    if o is None: return None
    b = d[o:o + 120]
    m = asc.match(b)
    if m: return m.group().decode()
    m = uni.match(b)
    if m: return 'L' + m.group().decode('utf-16le')
    return None
for arg in sys.argv[2:]:
    r = int(arg, 16)
    bd = bounds(r)
    if not bd: print("RVA %X: no function bounds" % r); continue
    b, e = bd
    # chained unwind: walk back while the previous entry's unwind says it's a chain? keep simple
    print("==== RVA %X in function %X-%X (%d bytes) section %s" % (r, b, e, e - b, secname(r)))
    code = d[rva2off(b):rva2off(b) + (e - b)]
    lines = []
    for ins in md.disasm(code, imgbase + b):
        rv = ins.address - imgbase
        tag = ''
        if 'rip' in ins.op_str and '[rip' in ins.op_str:
            m = re.search(r'rip ([+-]) 0x([0-9a-f]+)', ins.op_str)
            if m:
                t = rv + ins.size + (int(m.group(2), 16) * (1 if m.group(1) == '+' else -1))
                s = strat(t)
                if s and ins.mnemonic == 'lea': tag = '   ; "%s"' % s[:80]
                elif ins.mnemonic in ('call', 'jmp'): tag = '   ; -> [%X]' % t
        if ins.mnemonic == 'call' and ins.op_str.startswith('0x'):
            t = int(ins.op_str, 16) - imgbase
            fb = bounds(t)
            tag = '   ; call fn %X' % (fb[0] if fb else t)
        mark = ' <<<' if rv == r else ''
        if tag or mark or abs(rv - r) < 40: lines.append("%6X  %-8s %s%s%s" % (rv, ins.mnemonic, ins.op_str, tag, mark))
    print("\n".join(lines[:70]))
