"""callers.py <target VA hex>... : find direct E8 call sites in .text for the given targets, resolve containing functions."""
import sys, struct; sys.path.insert(0, ".")
import disasm as D, pdb_pub as P
targets = [int(a, 16) for a in sys.argv[1:]]
text = [s for s in D.secs if s[0] == ".text"][0]
name, va, vsize, rawptr, rawsize = text
D.f.seek(rawptr); code = D.f.read(rawsize)
base = D.image_base + va
found = {t: [] for t in targets}
i = code.find(b"\xe8")
import re
for m in re.finditer(rb"\xe8", code):
    pos = m.start()
    if pos + 5 > len(code): break
    rel, = struct.unpack_from("<i", code, pos + 1)
    tgt = base + pos + 5 + rel
    if tgt in found: found[tgt].append(base + pos)
for t, sites in found.items():
    print("target %x: %d call sites" % (t, len(sites)))
    for s in sites[:20]: print("   call @ %x" % s)
