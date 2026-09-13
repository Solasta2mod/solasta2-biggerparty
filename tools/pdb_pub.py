"""Find S_PUB32 public-symbol records in the raw PDB for given mangled-name substrings,
returning (name, segment, offset). Also resolve (segment, offset) pairs back to names."""
import struct, sys
PDB = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.pdb"
CH = 64 * 1024 * 1024

def find_symbols(substrings):
    out = []
    subs = [s.encode() if isinstance(s, str) else s for s in substrings]
    with open(PDB, "rb") as f:
        prev = b""
        while True:
            buf = f.read(CH)
            if not buf: break
            data = prev + buf
            for sub in subs:
                start = 0
                while True:
                    i = data.find(sub, start)
                    if i < 0: break
                    j = data.rfind(b"?", max(0, i - 300), i + 1)
                    if j > 0 and data[j - 1:j] == b"?": j -= 1      # names like ??_7Class@@6B@ (vtables) start with two '?'
                    if j >= 12:
                        kind, flags, off, seg = struct.unpack_from("<HIIH", data, j - 12)
                        if kind == 0x110E:
                            end = data.find(b"\x00", j)
                            out.append((data[j:end].decode("ascii", "replace"), seg, off))
                    start = i + 1
            prev = data[-4096:]
    return sorted(set(out))

def resolve(pairs):
    """pairs: iterable of (seg, off) -> dict[(seg,off)] = name"""
    pats = {struct.pack("<IH", off, seg): (seg, off) for (seg, off) in pairs}
    found = {}
    with open(PDB, "rb") as f:
        prev = b""
        while True:
            buf = f.read(CH)
            if not buf: break
            data = prev + buf
            for pat, key in pats.items():
                if key in found: continue
                start = 0
                while True:
                    i = data.find(pat, start)
                    if i < 0: break
                    if i >= 6:
                        kind, flags = struct.unpack_from("<HI", data, i - 6)
                        if kind == 0x110E:
                            end = data.find(b"\x00", i + 6)
                            name = data[i + 6:end]
                            if name and all(0x21 <= c < 0x7f for c in name):
                                found[key] = name.decode("ascii"); break
                    start = i + 1
            prev = data[-4096:]
    return found

if __name__ == "__main__":
    for name, seg, off in find_symbols(sys.argv[1:]):
        print(seg, hex(off), name)
