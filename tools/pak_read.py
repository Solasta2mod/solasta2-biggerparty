import sys, ctypes, os
sys.path.insert(0, os.path.dirname(__file__))
import pak_index as P
# Oodle decompressor: point OODLE_DLL at any oo2core_*_win64.dll (ships with many Unreal / Oodle games; 2.8+ decodes UE5 paks)
oodle = ctypes.WinDLL(os.environ.get("OODLE_DLL", r"oo2core_9_win64.dll"))
dec = oodle.OodleLZ_Decompress
dec.restype = ctypes.c_ssize_t
dec.argtypes = [ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int]

def oodle_decompress(comp, rawlen):
    out = ctypes.create_string_buffer(rawlen)
    n = dec(comp, len(comp), out, rawlen, 1, 0, 0, None, 0, None, None, None, 0, 3)
    if n != rawlen: raise RuntimeError("oodle failed: %d != %d" % (n, rawlen))
    return out.raw

def read(name):
    e = P.decode_entry(P.entries[name])
    if e["method"] == "None":
        P.f.seek(e["offset"] + e["hdr"]); return P.f.read(e["size"])
    out = b""; remaining = e["usize"]
    for (s, t) in e["blocks"]:
        P.f.seek(s); chunk = P.f.read(t - s)
        rawlen = min(e["blocksize"], remaining)
        if e["method"] == "Oodle": out += oodle_decompress(chunk, rawlen)
        else: import zlib; out += zlib.decompress(chunk)
        remaining -= rawlen
    return out

if __name__ == "__main__":
    outdir = sys.argv[1]; os.makedirs(outdir, exist_ok=True)
    for name in sys.argv[2:]:
        matches = [n for n in P.entries if name in n]
        for n in matches:
            data = read(n)
            dst = os.path.join(outdir, os.path.basename(n))
            open(dst, "wb").write(data)
            print("wrote", dst, len(data))
