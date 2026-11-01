#!/usr/bin/env python3
"""Заполняет слоты .got.plt адресом PLT0, как это делает компоновщик Hexagon SDK.

ld.lld оставляет слоты R_HEX_JMP_SLOT нулевыми. Загрузчик cDSP (rtld из NetBSD) при ленивом связывании делает
*слот += база_библиотеки, и первый вызов через PLT ушёл бы на начало файла. У стоковых skel Fold2 там адрес PLT0.

  fix_gotplt.py lib.so          - исправить файл
  fix_gotplt.py --check lib.so  - только проверить (код 1, если слоты не указывают на PLT0)
  --eflags=0x66                 - ещё и e_flags (версия Hexagon): ELD из SDK 6.x не знает v66 и пишет 0x68,
                                  хотя код собран clang -mv66; с --check - проверить e_flags
"""
import struct
import sys

R_HEX_JMP_SLOT = 34
DT_PLTRELSZ, DT_JMPREL = 2, 23
# PLT0 по Hexagon ABI (как в lld и в стоковых skel), после пары immext / r28 = add(pc, ##GOT0@PCREL)
PLT0 = bytes.fromhex("0e429ce24f409c913cc09c910e420e8c00c09c52")


def parse(d):
    if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 1:
        sys.exit("не ELF32 little-endian")
    if struct.unpack_from("<H", d, 18)[0] != 164:
        sys.exit("не Hexagon (e_machine 164)")
    phoff, = struct.unpack_from("<I", d, 28)
    phentsize, phnum = struct.unpack_from("<HH", d, 42)
    loads, dyn = [], None
    for i in range(phnum):
        p_type, p_off, p_vaddr, _, p_filesz, _, p_flags, _ = struct.unpack_from("<IIIIIIII", d, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_off, p_filesz, p_flags))
        elif p_type == 2:
            dyn = (p_off, p_filesz)

    def off(va, n=4):
        for v, o, sz, _ in loads:
            if v <= va and va + n <= v + sz:
                return o + va - v
        return None

    tags = {}
    if dyn:
        for i in range(0, dyn[1], 8):
            t, v = struct.unpack_from("<Ii", d, dyn[0] + i)
            if t == 0:
                break
            tags[t] = v
    return off, tags


def main():
    args = sys.argv[1:]
    check = "--check" in args
    ef = [int(a.split("=", 1)[1], 0) for a in args if a.startswith("--eflags=")]
    files = [a for a in args if not a.startswith("--")]
    if len(files) != 1 or len(ef) > 1:
        sys.exit(__doc__)
    path = files[0]
    d = bytearray(open(path, "rb").read())
    off, tags = parse(d)
    if ef:
        cur, = struct.unpack_from("<I", d, 36)
        if check and cur != ef[0]:
            print(f"{path}: e_flags 0x{cur:x}, нужен 0x{ef[0]:x}")
            return 1
        if cur != ef[0]:
            if not (0x60 <= cur <= 0x7F and 0x60 <= ef[0] <= 0x7F):
                sys.exit(f"{path}: e_flags 0x{cur:x} - не версия Hexagon v6x/v7x, не трогаю")
            struct.pack_into("<I", d, 36, ef[0])
            open(path, "wb").write(d)
            print(f"{path}: e_flags 0x{cur:x} -> 0x{ef[0]:x}")
    if DT_JMPREL not in tags or not tags.get(DT_PLTRELSZ):
        print(f"{path}: импортов через PLT нет, править нечего")
        return 0
    ro = off(tags[DT_JMPREL], tags[DT_PLTRELSZ])
    if ro is None:
        sys.exit(f"{path}: DT_JMPREL вне сегментов LOAD")
    slots = []
    for i in range(0, tags[DT_PLTRELSZ], 12):
        r_off, info, _ = struct.unpack_from("<IIi", d, ro + i)
        if info & 0xFF != R_HEX_JMP_SLOT:
            sys.exit(f"{path}: в DT_JMPREL релокация типа {info & 0xFF}, ожидался R_HEX_JMP_SLOT")
        fo = off(r_off)
        if fo is None:
            sys.exit(f"{path}: слот 0x{r_off:x} вне сегментов LOAD")
        slots.append((r_off, fo, struct.unpack_from("<I", d, fo)[0]))

    def is_plt0(va):
        o = off(va, 28)
        return o is not None and d[o + 8:o + 28] == PLT0

    if check:
        bad = [(a, v) for a, _, v in slots if not is_plt0(v)]
        for a, v in bad:
            print(f"{path}: слот 0x{a:x} = 0x{v:x} - там не PLT0")
        if bad:
            return 1
        print(f"{path}: слотов JMP_SLOT {len(slots)}, все указывают на PLT0 0x{slots[0][2]:x}")
        return 0
    # адрес PLT0: начало секции .plt (lld кладёт PLT0 первым)
    shoff, = struct.unpack_from("<I", d, 32)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 46)
    if not shoff or shstrndx >= shnum:
        sys.exit(f"{path}: нет таблицы секций - не знаю, где .plt")
    sh = [struct.unpack_from("<IIIIIIIIII", d, shoff + i * shentsize) for i in range(shnum)]
    so = sh[shstrndx][4]
    plt = [s[3] for s in sh if d[so + s[0]:d.index(b"\0", so + s[0])] == b".plt"]
    if len(plt) != 1 or not is_plt0(plt[0]):
        sys.exit(f"{path}: секция .plt не найдена или не начинается с PLT0 Hexagon ABI")
    fixed = 0
    for a, fo, v in slots:
        if v == plt[0]:
            continue
        if v != 0:
            sys.exit(f"{path}: слот 0x{a:x} = 0x{v:x} - не 0 и не PLT0, не трогаю")
        struct.pack_into("<I", d, fo, plt[0])
        fixed += 1
    if fixed:
        open(path, "wb").write(d)
    print(f"{path}: слотов JMP_SLOT {len(slots)}, исправлено {fixed}, все указывают на PLT0 0x{plt[0]:x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
