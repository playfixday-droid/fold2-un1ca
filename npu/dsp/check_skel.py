#!/usr/bin/env python3
"""Проверяет, что skel устроен так, как его сможет загрузить rtld cDSP Fold2 (unsigned PD).

  check_skel.py lib.so [lib2.so ...]   - код 1, если что-то не так

- ровно 2 сегмента LOAD, оба с начала страницы и offset == vaddr (как у стоковых skel в /vendor/dsp/cdsp:
  0x0/0x0 и 0x16000/0x16000; раскладка lld по умолчанию 0x4070/0x5070 на других SoC давала
  "Cannot protect segment 1" - лечится -z separate-loadable-segments);
- нет PT_TLS, PT_INTERP, PT_GNU_RELRO, секций конструкторов/TLS и тегов DT_INIT_ARRAY/FINI_ARRAY/PREINIT_ARRAY
  (rtld из NetBSD читает теги только до 23 - конструкторы просто не вызвались бы);
- есть DT_HASH (sysv), релокации только R_HEX_GLOB_DAT / R_HEX_JMP_SLOT / R_HEX_RELATIVE.
"""
import struct
import sys

PT_LOAD, PT_DYNAMIC, PT_INTERP, PT_TLS, PT_GNU_RELRO = 1, 2, 3, 7, 0x6474E552
DT_RELA, DT_RELASZ, DT_HASH, DT_JMPREL, DT_PLTRELSZ = 7, 8, 4, 23, 2
BAD_TAGS = {25: "DT_INIT_ARRAY", 26: "DT_FINI_ARRAY", 32: "DT_PREINIT_ARRAY"}
BAD_SECT = (".init_array", ".fini_array", ".preinit_array", ".ctors", ".dtors", ".tdata", ".tbss")
RELOCS = {33: "R_HEX_GLOB_DAT", 34: "R_HEX_JMP_SLOT", 35: "R_HEX_RELATIVE"}
PAGE = 4096


def check(path):
    d = open(path, "rb").read()
    err = []
    if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 1 or struct.unpack_from("<H", d, 18)[0] != 164:
        return [f"{path}: не ELF32 Hexagon"]
    phoff, shoff = struct.unpack_from("<II", d, 28)
    phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from("<HHHHH", d, 42)
    loads, dyn = [], None
    for i in range(phnum):
        t, off, va, _, fsz, msz, _, _ = struct.unpack_from("<8I", d, phoff + i * phentsize)
        if t == PT_LOAD:
            loads.append((va, off, fsz))
            if off % PAGE or va != off:
                err.append(f"LOAD offset 0x{off:x} vaddr 0x{va:x}: нужно offset == vaddr, кратно 0x{PAGE:x}")
        elif t == PT_DYNAMIC:
            dyn = (off, fsz)
        elif t in (PT_INTERP, PT_TLS, PT_GNU_RELRO):
            err.append(f"лишний сегмент типа 0x{t:x}")
    if len(loads) != 2:
        err.append(f"сегментов LOAD {len(loads)}, нужно 2")

    def foff(va, n):
        for v, o, sz in loads:
            if v <= va and va + n <= v + sz:
                return o + va - v
        return None

    tags = {}
    if dyn is None:
        err.append("нет PT_DYNAMIC")
    else:
        for i in range(0, dyn[1], 8):
            t, v = struct.unpack_from("<II", d, dyn[0] + i)
            if t == 0:
                break
            tags[t] = v
    err += [f"есть {n}" for t, n in BAD_TAGS.items() if t in tags]
    if dyn is not None and DT_HASH not in tags:
        err.append("нет DT_HASH (нужен --hash-style=sysv)")
    for a, n in ((DT_RELA, DT_RELASZ), (DT_JMPREL, DT_PLTRELSZ)):
        if not tags.get(n):
            continue
        o = foff(tags.get(a, 0), tags[n])
        if o is None:
            err.append(f"таблица релокаций 0x{tags.get(a, 0):x} вне LOAD")
            continue
        for i in range(0, tags[n], 12):
            r = struct.unpack_from("<I", d, o + i + 4)[0] & 0xFF
            if r not in RELOCS:
                err.append(f"релокация типа {r} (rtld cDSP понимает только {', '.join(RELOCS.values())})")
                break
    if shoff and shstrndx < shnum:
        sh = [struct.unpack_from("<10I", d, shoff + i * shentsize) for i in range(shnum)]
        so = sh[shstrndx][4]
        names = [d[so + s[0]:d.index(b"\0", so + s[0])].decode() for s in sh]
        err += [f"есть секция {n}" for n in names if n.startswith(BAD_SECT)]
    return [f"{path}: {e}" for e in err]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    bad = [e for p in sys.argv[1:] for e in check(p)]
    for e in bad:
        print("ERROR:", e)
    if not bad:
        print("раскладка skel ок:", " ".join(sys.argv[1:]))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
