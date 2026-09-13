import struct, re
pdb = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.pdb"
targets = [b"Z_Construct_UFunction_UItemBuildingComponent_CreateItem_Statics@@2U",
           b"Z_Construct_UFunction_UCharacterInventoryComponent_GrantItem_Statics@@2U",
           b"Z_Construct_UFunction_UHeroInventoryComponent_FindSpellbookWithTag_Statics@@2U"]
enum_anchor = b"DefaultSkipRegistration\x00"
CH = 64 * 1024 * 1024
pubs = []   # (name, seg, off)
enums = []
with open(pdb, "rb") as f:
    prev = b""; base = 0
    while True:
        buf = f.read(CH)
        if not buf: break
        data = prev + buf
        for t in targets:
            start = 0
            while True:
                i = data.find(t, start)
                if i < 0: break
                # walk back to start of mangled name ('?NewProp_...')
                j = data.rfind(b"?NewProp_", max(0, i - 200), i)
                if j >= 0 and j >= 12:
                    kind, flags, off, seg = struct.unpack_from("<HIIH", data, j - 12)
                    if kind == 0x110E:
                        end = data.find(b"\x00", i)
                        pubs.append((data[j:end].decode("ascii", "replace"), seg, off))
                start = i + 1
        start = 0
        while True:
            i = data.find(enum_anchor, start)
            if i < 0: break
            # LF_ENUMERATE: kind(2)=0x1502 attr(2) value(2 if <0x8000) name
            if i >= 6:
                kind, attr, val = struct.unpack_from("<HHH", data, i - 6)
                if kind == 0x1502:
                    # parse the surrounding field list: go backwards and forwards over enumerate records
                    recs = []
                    # forward from this record
                    p = i - 6
                    while p < len(data) - 8:
                        k, a, v = struct.unpack_from("<HHH", data, p)
                        if k != 0x1502 or v >= 0x8000: break
                        e = data.find(b"\x00", p + 6)
                        name = data[p+6:e].decode("ascii", "replace")
                        recs.append((v, name))
                        p = e + 1
                        while p % 4 != 0 and data[p] >= 0xF0: p += 1  # LF_PAD bytes
                    # backward: scan back for preceding records (try stepping back by searching kind marker)
                    q = i - 6
                    back = []
                    while True:
                        # find previous 0x1502 within 64 bytes
                        found = None
                        for cand in range(q - 7, max(q - 80, 0), -1):
                            k, a, v = struct.unpack_from("<HHH", data, cand)
                            if k == 0x1502 and v < 0x8000:
                                e = data.find(b"\x00", cand + 6)
                                if e > 0 and e < q + 1 and all(32 <= c < 127 for c in data[cand+6:e]):
                                    found = (cand, v, data[cand+6:e].decode("ascii","replace")); break
                        if not found: break
                        back.append((found[1], found[2])); q = found[0]
                    enums.append((list(reversed(back)) + recs))
            start = i + 1
        prev = data[-4096:]
seen = set()
for name, seg, off in sorted(set(pubs), key=lambda x: (x[1], x[2])):
    print(seg, hex(off), name.split("@")[0], name.split("@")[1][:60])
print("---- enum candidates ----")
for e in enums[:5]:
    print(e)
