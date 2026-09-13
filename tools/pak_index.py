import struct, sys, zlib, os
pak = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Content\Paks\Brimstone-Windows.pak"
f = open(pak, "rb")
f.seek(0, 2); fsize = f.tell()
f.seek(fsize - 221); info = f.read(221)
guid = info[:16]; enc_idx = info[16]; magic, ver, idx_off, idx_size = struct.unpack("<IiqQ", info[17:17+24]); idx_hash = info[41:61]
methods = [info[61+32*i:61+32*(i+1)].split(b"\0")[0].decode() for i in range(5)]
print("magic %x ver %d idx_off %d idx_size %d methods %s" % (magic, ver, idx_off, idx_size, methods))

def rd_fstring(b, p):
    n, = struct.unpack_from("<i", b, p); p += 4
    if n < 0:
        s = b[p:p-2*n].decode("utf-16le").rstrip("\0"); p += -2*n
    else:
        s = b[p:p+n].decode("latin-1").rstrip("\0"); p += n
    return s, p

f.seek(idx_off); idx = f.read(idx_size)
p = 0
mount, p = rd_fstring(idx, p)
num, = struct.unpack_from("<i", idx, p); p += 4
seed, = struct.unpack_from("<Q", idx, p); p += 8
has_ph, = struct.unpack_from("<i", idx, p); p += 4
if has_ph: ph_off, ph_size = struct.unpack_from("<qq", idx, p); p += 16 + 20
has_fd, = struct.unpack_from("<i", idx, p); p += 4
if has_fd: fd_off, fd_size = struct.unpack_from("<qq", idx, p); p += 16 + 20
n_enc, = struct.unpack_from("<i", idx, p); p += 4
encoded = idx[p:p+n_enc]; p += n_enc
n_files, = struct.unpack_from("<i", idx, p); p += 4
print("mount", mount, "entries", num, "encoded bytes", n_enc, "plain files", n_files, "fulldir", has_fd)

f.seek(fd_off); fd = f.read(fd_size)
p = 0
ndirs, = struct.unpack_from("<i", fd, p); p += 4
entries = {}
for _ in range(ndirs):
    d, p = rd_fstring(fd, p)
    nf, = struct.unpack_from("<i", fd, p); p += 4
    for _ in range(nf):
        fn, p = rd_fstring(fd, p)
        loc, = struct.unpack_from("<i", fd, p); p += 4
        entries[d + fn] = loc
print("files:", len(entries))

def decode_entry(off):
    b = encoded; q = off
    val, = struct.unpack_from("<I", b, q); q += 4
    cmi = (val >> 23) & 0x3f
    if val & (1 << 31): o, = struct.unpack_from("<I", b, q); q += 4
    else: o, = struct.unpack_from("<q", b, q); q += 8
    if val & (1 << 30): us, = struct.unpack_from("<I", b, q); q += 4
    else: us, = struct.unpack_from("<q", b, q); q += 8
    if cmi != 0:
        if val & (1 << 29): sz, = struct.unpack_from("<I", b, q); q += 4
        else: sz, = struct.unpack_from("<q", b, q); q += 8
    else: sz = us
    encrypted = (val >> 22) & 1
    nblocks = (val >> 6) & 0xffff
    if (val & 0x3f) == 0x3f: bs, = struct.unpack_from("<I", b, q); q += 4
    else: bs = (val & 0x3f) << 11
    if nblocks == 1: bs = us
    hdr = 8 + 8 + 8 + 20 + 4 + 1 + 4 + (4 + 16 * nblocks if cmi != 0 else 0)
    blocks = []
    if nblocks > 0:
        if nblocks == 1 and not encrypted:
            blocks.append((o + hdr, o + hdr + sz))
        else:
            cur = o + hdr
            for _ in range(nblocks):
                bsz, = struct.unpack_from("<I", b, q); q += 4
                blocks.append((cur, cur + bsz)); cur += (bsz + 15) & ~15 if encrypted else bsz
    return dict(offset=o, size=sz, usize=us, method=methods[cmi-1] if cmi else "None", encrypted=encrypted, blocks=blocks, blocksize=bs, hdr=hdr)

def read_file(name):
    e = decode_entry(entries[name])
    if e["method"] == "None":
        f.seek(e["offset"] + e["hdr"]); return f.read(e["size"]), e
    out = b""
    for (s, t) in e["blocks"]:
        f.seek(s); chunk = f.read(t - s)
        if e["method"] == "Zlib": out += zlib.decompress(chunk)
        else: raise RuntimeError("unsupported compression " + e["method"])
    return out, e

if __name__ == "__main__":
    # summary of methods
    from collections import Counter
    c = Counter()
    for n, loc in entries.items():
        c[decode_entry(loc)["method"]] += 1
    print("methods used:", c)
    for n in sorted(entries):
        if any(k in n for k in sys.argv[1:]): print(n, decode_entry(entries[n])["method"], decode_entry(entries[n])["usize"])
