"""RVA -> nearest public symbol using pubs.bin (from pdb_pubs_scan.py) and the exe section table."""
import struct, sys, bisect
EXE = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.exe"
d = open(EXE, 'rb').read(4096)
e = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, e + 6)[0]; optsz = struct.unpack_from('<H', d, e + 20)[0]
secva = [struct.unpack_from('<I', d, e + 24 + optsz + i * 40 + 12)[0] for i in range(nsec)]
b = open('pubs.bin', 'rb').read()
rvas, names = [], []
i = 0
while i < len(b):
    seg, off, ln = struct.unpack_from('<HIH', b, i); i += 8
    name = b[i:i + ln]; i += ln
    if 1 <= seg <= nsec:
        rvas.append(secva[seg - 1] + off); names.append(name)
order = sorted(range(len(rvas)), key=lambda k: rvas[k])
rvas = [rvas[k] for k in order]; names = [names[k] for k in order]
def lookup(r):
    k = bisect.bisect_right(rvas, r) - 1
    if k < 0: return None, None
    return names[k].decode(), r - rvas[k]
for a in sys.argv[1:]:
    r = int(a, 16); n, delta = lookup(r)
    print("%9X  %s + %X" % (r, n, delta))
