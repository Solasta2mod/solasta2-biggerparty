"""fnview.py <mangled-substring>... : disassemble matching functions, print calls resolved + interesting lines"""
import sys, re; sys.path.insert(0, ".")
import disasm as D, pdb_pub as P
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
md = Cs(CS_ARCH_X86, CS_MODE_64)
full = "--full" in sys.argv
subs = [a for a in sys.argv[1:] if not a.startswith("--")]
syms = [(n, seg, off) for (n, seg, off) in P.find_symbols(subs) if n.startswith("?") and not n.startswith("?exec")]
def body(seg, off, cap=0x4000):
    rva = D.seg_off_to_rva(seg, off); code = D.read_rva(rva, cap); out = []
    for ins in md.disasm(code, D.image_base + rva):
        if ins.mnemonic == "int3": break
        out.append(ins)
    return out
listing = {}; calls = set()
for n, seg, off in syms:
    ins = body(seg, off); listing[n] = ins
    for i in ins:
        if i.mnemonic == "call" and i.op_str.startswith("0x"): calls.add(int(i.op_str, 16))
pairs = {}
for va in calls:
    so = D.rva_to_seg_off(va - D.image_base)
    if so: pairs[so] = va
names = P.resolve(pairs.keys()); byva = {va: names.get(so, "?") for so, va in pairs.items()}
for n, ins in listing.items():
    print("=====", n[:110], "(%d ins)" % len(ins))
    for i in ins:
        s = "%x  %-7s %s" % (i.address, i.mnemonic, i.op_str)
        if i.mnemonic == "call" and i.op_str.startswith("0x"): s += "   ; " + byva.get(int(i.op_str, 16), "?")[:100]
        if full or re.search(r"call|cmp|imul|, 0x[0-9a-f]+$|, [0-9]$|jl|jg|jle|jge|jne|je ", s): print(s)
