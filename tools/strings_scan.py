import re, sys, collections
exe = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.exe"
data = open(exe, "rb").read()
# ASCII strings
ascii_re = re.compile(rb"[\x20-\x7e]{5,}")
# UTF-16LE strings
utf16_re = re.compile(rb"(?:[\x20-\x7e]\x00){5,}")
strs = set()
for m in ascii_re.finditer(data):
    strs.add(m.group().decode("ascii"))
for m in utf16_re.finditer(data):
    strs.add(m.group().decode("utf-16le"))
print("total unique strings:", len(strs), file=sys.stderr)
out = open(sys.argv[1], "w", encoding="utf-8")
for s in sorted(strs):
    out.write(s + "\n")
out.close()
