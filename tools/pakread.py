"""Read files out of an unencrypted UE pak (index version 11, as Solasta II ships it). Importable: Pak(path).read(name).

    python pakread.py <pak> list [substring]
    python pakread.py <pak> extract <substring> <out dir>

Decompression: Zlib/Gzip through the standard library; Oodle through the game's oo2core DLL
(pass its folder in OODLE_DIR, or leave it to be found beside the game exe).
"""
import ctypes, glob, io, os, struct, sys, zlib

class Pak:
    def __init__(self, path):
        self.f = open(path, "rb"); self.f.seek(0, 2); self.size = self.f.tell()
        self.path = path
        self.read_footer(); self.read_index()

    def read_footer(self):
        self.f.seek(self.size - 221); b = self.f.read(221)
        magic, ver = struct.unpack_from("<II", b, 17)
        assert magic == 0x5A6F12E1 and ver == 11, (hex(magic), ver)
        self.encrypted = b[16]
        self.index_offset, self.index_size = struct.unpack_from("<qq", b, 25)
        self.methods = ["None"]
        for i in range(5):
            name = b[61 + 32 * i: 61 + 32 * (i + 1)].split(bytes([0]))[0].decode("ascii", "replace")
            self.methods.append(name)

    def read_index(self):
        assert not self.encrypted, "encrypted index"
        self.f.seek(self.index_offset); b = self.f.read(self.index_size)
        o = 0
        ln = struct.unpack_from("<i", b, o)[0]; o += 4
        self.mount = b[o:o + ln - 1].decode("utf-8"); o += ln
        self.count, self.seed = struct.unpack_from("<iQ", b, o); o += 12
        if struct.unpack_from("<i", b, o)[0]: o += 4 + 16 + 20
        else: o += 4
        has_dir = struct.unpack_from("<i", b, o)[0]; o += 4
        assert has_dir, "no full directory index"
        dir_off, dir_size = struct.unpack_from("<qq", b, o); o += 16 + 20
        enc_size = struct.unpack_from("<i", b, o)[0]; o += 4
        self.encoded = b[o:o + enc_size]
        self.f.seek(dir_off); d = self.f.read(dir_size)
        o = 0
        def fstr():
            nonlocal o
            ln = struct.unpack_from("<i", d, o)[0]; o += 4
            if ln < 0:
                s = d[o:o - 2 * ln - 2].decode("utf-16-le"); o += -2 * ln
            else:
                s = d[o:o + ln - 1].decode("utf-8", "replace"); o += ln
            return s
        self.files = {}
        nd = struct.unpack_from("<i", d, o)[0]; o += 4
        for _ in range(nd):
            dn = fstr()
            nf = struct.unpack_from("<i", d, o)[0]; o += 4
            for _ in range(nf):
                fn = fstr()
                self.files[dn + fn] = struct.unpack_from("<i", d, o)[0]; o += 4

    def entry(self, name):
        """Decode the entry: (data offset, compressed size, uncompressed size, method, [(start, end)...])."""
        p = self.files[name]; b = self.encoded
        bits = struct.unpack_from("<I", b, p)[0]; p += 4
        if (bits & 0x3f) == 0x3f: block_size = struct.unpack_from("<I", b, p)[0]; p += 4
        else: block_size = (bits & 0x3f) << 11
        method = (bits >> 23) & 0x3f
        if bits & (1 << 31): offset = struct.unpack_from("<I", b, p)[0]; p += 4
        else: offset = struct.unpack_from("<q", b, p)[0]; p += 8
        if bits & (1 << 30): usize = struct.unpack_from("<I", b, p)[0]; p += 4
        else: usize = struct.unpack_from("<q", b, p)[0]; p += 8
        if method:
            if bits & (1 << 29): size = struct.unpack_from("<I", b, p)[0]; p += 4
            else: size = struct.unpack_from("<q", b, p)[0]; p += 8
        else: size = usize
        assert not (bits & (1 << 22)), "encrypted entry " + name
        nblocks = (bits >> 6) & 0xffff
        header = 53 + (4 + 16 * nblocks if method else 0)
        blocks = []
        if nblocks == 1:
            blocks.append((offset + header, offset + header + size))
        elif nblocks > 1:
            rel = header
            for _ in range(nblocks):
                bs = struct.unpack_from("<I", b, p)[0]; p += 4
                blocks.append((offset + rel, offset + rel + bs)); rel += bs
        return offset, size, usize, self.methods[method], blocks, block_size

    def read(self, name):
        offset, size, usize, method, blocks, block_size = self.entry(name)
        if method == "None":
            self.f.seek(offset + 53); return self.f.read(usize)
        out = io.BytesIO(); left = usize
        for (s, e) in blocks:
            self.f.seek(s); raw = self.f.read(e - s)
            want = min(block_size or usize, left)
            if method == "Zlib": chunk = zlib.decompress(raw)
            elif method == "Gzip": chunk = zlib.decompress(raw, 31)
            elif method == "Oodle": chunk = oodle_decompress(raw, want, self.path)
            else: raise RuntimeError("unknown compression " + method)
            out.write(chunk); left -= len(chunk)
        data = out.getvalue()
        assert len(data) == usize, (name, len(data), usize)
        return data

_oodle = None
def oodle_decompress(raw, want, pak_path):
    global _oodle
    if _oodle is None:
        cands = []
        game_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(pak_path)))))
        for d in [os.environ.get("OODLE_DIR", ""), game_root]:
            if d: cands += glob.glob(os.path.join(d, "**", "oo2core*win64.dll"), recursive=True)
        if not cands: raise RuntimeError("no oo2core DLL found; set OODLE_DIR")
        _oodle = ctypes.CDLL(cands[0])
        _oodle.OodleLZ_Decompress.restype = ctypes.c_ssize_t
        _oodle.OodleLZ_Decompress.argtypes = [ctypes.c_char_p, ctypes.c_ssize_t, ctypes.c_char_p, ctypes.c_ssize_t, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                              ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ssize_t, ctypes.c_int]
    buf = ctypes.create_string_buffer(want)
    n = _oodle.OodleLZ_Decompress(raw, len(raw), buf, want, 1, 0, 0, None, 0, None, None, None, 0, 3)
    if n != want: raise RuntimeError("oodle: got %d of %d" % (n, want))
    return buf.raw

if __name__ == "__main__":
    pak = Pak(sys.argv[1]); cmd = sys.argv[2] if len(sys.argv) > 2 else "list"
    if cmd == "list":
        sub = sys.argv[3] if len(sys.argv) > 3 else ""
        for name in sorted(pak.files):
            if sub in name:
                offset, size, usize, method, blocks, bs = pak.entry(name)
                print("%9d %9d %-6s %s" % (size, usize, method, name))
    elif cmd == "extract":
        sub, outdir = sys.argv[3], sys.argv[4]
        for name in sorted(pak.files):
            if sub in name:
                data = pak.read(name)
                dest = os.path.join(outdir, name.replace("/", os.sep))
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                open(dest, "wb").write(data); print("%8d %s" % (len(data), name))
    print("methods:", pak.methods, file=sys.stderr)
