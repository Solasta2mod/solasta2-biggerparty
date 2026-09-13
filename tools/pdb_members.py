"""Find LF_MEMBER records (class field offsets) by field name in the raw PDB."""
import struct, sys
PDB = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.pdb"
CH = 64 * 1024 * 1024
def find_members(names):
    pats = {(n.encode() + b"\x00"): n for n in names}
    out = {}
    with open(PDB, "rb") as f:
        prev = b""
        while True:
            buf = f.read(CH)
            if not buf: break
            data = prev + buf
            for pat, n in pats.items():
                start = 0
                while True:
                    i = data.find(pat, start)
                    if i < 0: break
                    # try 2-byte offset leaf then 6-byte (0x8004 + u32)
                    for lead, fmt in ((2, "<H"), (6, None)):
                        j = i - lead - 4 - 2 - 2
                        if j < 0: continue
                        kind, attr, tidx = struct.unpack_from("<HHI", data, j)
                        if kind != 0x150D: continue
                        if lead == 2:
                            off, = struct.unpack_from("<H", data, i - 2)
                            if off >= 0x8000: continue
                        else:
                            leaf, = struct.unpack_from("<H", data, i - 6)
                            if leaf != 0x8004: continue
                            off, = struct.unpack_from("<I", data, i - 4)
                        # previous byte before the name must be part of the offset, and next byte after name end is padding/next record
                        out.setdefault(n, set()).add((off, tidx))
                        break
                    start = i + 1
            prev = data[-4096:]
    return out
if __name__ == "__main__":
    res = find_members(sys.argv[1:])
    for n, s in res.items():
        print(n, sorted(s)[:12])
