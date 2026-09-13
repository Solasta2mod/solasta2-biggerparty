import struct, sys
utoc = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Content\Paks\Brimstone-Windows.utoc"
d = open(utoc, "rb").read()
assert d[:16] == b"-==--==--==--==-", d[:16]
ver = d[16]
(hdr_size, entry_count, cb_count, cb_size, cm_count, cm_len, block_size, dir_index_size, partition_count) = struct.unpack_from("<9I", d, 20)
container_id, = struct.unpack_from("<Q", d, 56)
enc_guid = d[64:80]; flags = d[80]
ph_seeds_count, = struct.unpack_from("<I", d, 84)
partition_size, = struct.unpack_from("<Q", d, 88)
no_ph_count, = struct.unpack_from("<I", d, 96)
print("utoc version", ver, "entries", entry_count, "blocks", cb_count, "dir index", dir_index_size, "flags", flags, "cm", cm_count, cm_len, "block", block_size)
p = hdr_size
p += entry_count * 12          # chunk ids
p += entry_count * 10          # offset+length
p += ph_seeds_count * 4
p += no_ph_count * 4
p += cb_count * cb_size        # compression blocks
methods = [d[p + i*cm_len: p + (i+1)*cm_len].split(b"\0")[0].decode() for i in range(cm_count)]
p += cm_count * cm_len
print("methods", methods)
if flags & 2:  # signed
    hash_size, = struct.unpack_from("<i", d, p); p += 4 + hash_size*2 + cb_count*20
di = d[p:p+dir_index_size]
def rd_fstring(b, q):
    n, = struct.unpack_from("<i", b, q); q += 4
    if n < 0: s = b[q:q-2*n].decode("utf-16le").rstrip("\0"); q += -2*n
    else: s = b[q:q+n].decode("latin-1").rstrip("\0"); q += n
    return s, q
q = 0
mount, q = rd_fstring(di, q)
nd, = struct.unpack_from("<I", di, q); q += 4
dirs = [struct.unpack_from("<4I", di, q + i*16) for i in range(nd)]; q += nd*16
nf, = struct.unpack_from("<I", di, q); q += 4
files = [struct.unpack_from("<3I", di, q + i*12) for i in range(nf)]; q += nf*12
ns, = struct.unpack_from("<I", di, q); q += 4
strings = []
for i in range(ns):
    s, q = rd_fstring(di, q); strings.append(s)
NONE = 0xFFFFFFFF
paths = {}
def walk(dir_idx, prefix):
    while dir_idx != NONE:
        name, child, sibling, first_file = dirs[dir_idx]
        path = prefix + (strings[name] + "/" if name != NONE else "")
        fi = first_file
        while fi != NONE:
            fname, nxt, user = files[fi]
            paths[path + strings[fname]] = user
            fi = nxt
        walk(child, path)
        dir_idx = sibling
walk(0, mount)
print("mount", mount, "files", len(paths))
if __name__ == "__main__":
    for pth in sorted(paths):
        if any(k.lower() in pth.lower() for k in sys.argv[1:]): print(pth)
