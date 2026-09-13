"""vtable.py <seg> <offset-hex> <slot-byte-offset-hex>   : read a vtable entry given the PDB (segment, offset)
   vtable.py va <vtable-VA-hex> <slot-byte-offset-hex>    : same, given the vtable's absolute VA (image base 0x140000000)

Segments are 1-based PE section indices. The entry at vtable+slot is an absolute VA in the image (relocations
assume the preferred base), so it is mapped back to (segment, offset) for pdb_pub.py.
"""
import struct, sys

EXE = r"C:\Program Files (x86)\Steam\steamapps\common\Solasta 2\Brimstone\Binaries\Win64\Brimstone-Win64-Shipping.exe"


def sections():
    with open(EXE, "rb") as f:
        data = f.read(4096)
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    image_base = struct.unpack_from("<Q", data, pe + 24 + 24)[0]
    off = pe + 24 + opt_size
    out = []
    for i in range(nsec):
        name = data[off:off + 8].rstrip(b"\0").decode(errors="replace")
        vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        out.append((name, va, vsize, rawptr, rawsize))
        off += 40
    return image_base, out


def rva_to_file(secs, rva):
    for i, (n, sva, sv, rp, rs) in enumerate(secs, 1):
        if sva <= rva < sva + max(sv, rs):
            return rp + (rva - sva), i, n, rva - sva
    return None, None, None, None


def main():
    base, secs = sections()
    if sys.argv[1] == "va":
        vt_rva = int(sys.argv[2], 16) - base
        slot = int(sys.argv[3], 16)
        file_off, seg, name, off = rva_to_file(secs, vt_rva)
    else:
        seg, off, slot = int(sys.argv[1]), int(sys.argv[2], 16), int(sys.argv[3], 16)
        name, va, vsize, rawptr, rawsize = secs[seg - 1]
        file_off = rawptr + off
    with open(EXE, "rb") as f:
        f.seek(file_off + slot)
        ptr = struct.unpack("<Q", f.read(8))[0]
    rva = ptr - base
    _, tseg, tname, toff = rva_to_file(secs, rva)
    if tseg is None:
        print(f"VA {ptr:#x} not in any section")
    else:
        print(f"vtable seg {seg} ({name}) +{off:#x} slot {slot:#x} -> VA {ptr:#x} = segment {tseg} ({tname}) offset {toff:#x}")


if __name__ == "__main__":
    main()
