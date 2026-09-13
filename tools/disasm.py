"""Disassemble a function from the shipping exe given its PDB (segment, offset)."""
import struct, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
EXE = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.exe"
f = open(EXE, "rb")
dos = f.read(0x40); e_lfanew, = struct.unpack_from("<I", dos, 0x3c)
f.seek(e_lfanew); sig = f.read(4); assert sig == b"PE\0\0"
coff = f.read(20); nsec, = struct.unpack_from("<H", coff, 2); opt_size, = struct.unpack_from("<H", coff, 16)
opt = f.read(opt_size); image_base, = struct.unpack_from("<Q", opt, 24)
secs = []
for i in range(nsec):
    s = f.read(40)
    name = s[:8].rstrip(b"\0").decode()
    vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", s, 8)
    secs.append((name, va, vsize, rawptr, rawsize))

def seg_off_to_rva(seg, off): return secs[seg - 1][1] + off
def rva_to_file(rva):
    for name, va, vsize, rawptr, rawsize in secs:
        if va <= rva < va + max(vsize, rawsize): return rawptr + (rva - va)
    raise ValueError(hex(rva))
def rva_to_seg_off(rva):
    for i, (name, va, vsize, rawptr, rawsize) in enumerate(secs):
        if va <= rva < va + max(vsize, rawsize): return (i + 1, rva - va)
    return None

def read_rva(rva, n):
    f.seek(rva_to_file(rva)); return f.read(n)

def disasm(seg, off, size=0x800, stop_at_ret=True):
    rva = seg_off_to_rva(seg, off)
    code = read_rva(rva, size)
    md = Cs(CS_ARCH_X86, CS_MODE_64); md.detail = True
    out = []
    depth_hint = 0
    for ins in md.disasm(code, image_base + rva):
        out.append(ins)
        if stop_at_ret and ins.mnemonic == "ret":
            # crude: stop at the first ret that is followed by padding (int3) — good enough for our function
            nxt = code[ins.address - (image_base + rva) + ins.size: ins.address - (image_base + rva) + ins.size + 2]
            if nxt[:1] == b"\xcc": break
    return out

if __name__ == "__main__":
    seg, off = int(sys.argv[1]), int(sys.argv[2], 16)
    for ins in disasm(seg, off, int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x800):
        print("%x  %-8s %s" % (ins.address, ins.mnemonic, ins.op_str))
