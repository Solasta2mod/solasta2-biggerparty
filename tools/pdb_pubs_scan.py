"""One-off: collect every S_PUB32 (seg, off, name) from the game PDB into pubs.bin for address lookups."""
import struct, sys, time
PDB = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.pdb"
CH = 64 * 1024 * 1024
t0 = time.time(); recs = []; seen = set()
with open(PDB, "rb") as f:
    prev = b""; base = 0
    while True:
        buf = f.read(CH)
        if not buf: break
        data = prev + buf
        start = 0
        while True:
            i = data.find(b"\x0e\x11", start)
            if i < 0: break
            start = i + 2
            if i < 2 or i + 12 > len(data): continue
            ln = struct.unpack_from("<H", data, i - 2)[0]
            if ln < 14 or ln > 2200: continue
            flags, off, seg = struct.unpack_from("<IIH", data, i + 2)
            if flags > 0x3f or seg == 0 or seg > 64: continue
            end = data.find(b"\x00", i + 12, i + 12 + ln)
            if end < 0: continue
            name = data[i + 12:end]
            if len(name) < 2 or not all(0x21 <= c < 0x7f for c in name): continue
            key = (seg, off, name)
            if key in seen: continue
            seen.add(key); recs.append(key)
        prev = data[-4096:]
recs.sort()
with open("pubs.bin", "wb") as o:
    for seg, off, name in recs:
        o.write(struct.pack("<HIH", seg, off, len(name)) + name)
print("records:", len(recs), "in %.0fs" % (time.time() - t0))
