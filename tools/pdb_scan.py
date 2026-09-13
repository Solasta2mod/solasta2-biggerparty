import re, sys
pdb = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.pdb"
keys = [b"MagicUseComponent_h__Script", b"IsMissingRequiredSpellbook_Statics", b"HasAuthority_Statics"]
pat = re.compile(rb"[\x20-\x7e]{4,}")
found = set()
CH = 64 * 1024 * 1024
with open(pdb, "rb") as f:
    prev = b""
    while True:
        buf = f.read(CH)
        if not buf:
            break
        data = prev + buf
        for m in pat.finditer(data):
            s = m.group()
            if any(k in s for k in keys):
                found.add(s)
        prev = data[-4096:]
out = open(sys.argv[1], "w", encoding="utf-8", errors="replace")
for s in sorted(found):
    out.write(s.decode("ascii", "replace") + "\n")
out.close()
print(len(found), file=sys.stderr)
