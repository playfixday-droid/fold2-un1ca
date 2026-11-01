#!/usr/bin/env python3
"""Потоковая распаковка Android sparse super.img -> отдельные образы разделов.
Не нужен полный super.img на диске: читает stdin (sparse или raw), пишет
только выбранные разделы, нули пропускает (sparse-файлы).
Пример: lz4 -dc super.img.lz4 | super_stream_extract.py outdir system vendor product odm
"""
import os, struct, sys

LP_GEOM_MAGIC = 0x616c4467
LP_META_MAGIC = 0x414C5030

def parse_lp(buf):
    g = buf[4096:4096 + 52]
    magic, ssz = struct.unpack_from('<II', g, 0)
    assert magic == LP_GEOM_MAGIC, 'нет LP geometry'
    meta_max, slots, lbs = struct.unpack_from('<III', g, 40)
    off = 4096 + 4096 * 2  # primary metadata, slot 0
    h = buf[off:off + 256]
    magic, major, minor, hsz = struct.unpack_from('<IHHI', h, 0)
    assert magic == LP_META_MAGIC, 'нет LP metadata'
    tables_size = struct.unpack_from('<I', h, 44)[0]
    def desc(i):
        return struct.unpack_from('<III', h, 80 + i * 12)
    t = off + hsz
    (po, pn, pe), (eo, en, ee), (go, gn, ge), (bo, bn, be) = desc(0), desc(1), desc(2), desc(3)
    groups = []
    for i in range(gn):
        name, flags, maxsz = struct.unpack_from('<36sIQ', buf, t + go + i * ge)
        groups.append((name.rstrip(b'\0').decode(), maxsz))
    bdev = struct.unpack_from('<QIIQ36sI', buf, t + bo)
    exts = [struct.unpack_from('<QIQI', buf, t + eo + i * ee) for i in range(en)]
    parts = {}
    for i in range(pn):
        name, attr, fe, ne, gi = struct.unpack_from('<36sIIII', buf, t + po + i * pe)
        name = name.rstrip(b'\0').decode()
        lst, logical = [], 0
        for e in exts[fe:fe + ne]:
            nsec, ttype, tdata, tsrc = e
            if ttype == 0:  # LINEAR
                lst.append((tdata * 512, nsec * 512, logical))
            logical += nsec * 512
        parts[name] = (lst, logical, groups[gi][0])
    info = dict(major=major, minor=minor, metadata_max=meta_max, slots=slots,
                block_size=lbs, super_size=bdev[3], groups=groups)
    return info, parts

def main():
    out, want = sys.argv[1], set(sys.argv[2:])
    os.makedirs(out, exist_ok=True)
    inp = sys.stdin.buffer
    hdr = inp.read(28)
    sparse = struct.unpack_from('<I', hdr, 0)[0] == 0xED26FF3A
    files, ranges = {}, []
    head = bytearray()
    info = parts = None
    pos = 0  # смещение в «сыром» super

    def emit(data, at):
        nonlocal head, info, parts
        if info is None:
            head += data
            if len(head) >= 1 << 20:
                info, parts = parse_lp(bytes(head))
                report()
                for n, (lst, size, g) in parts.items():
                    if n in want and size:
                        f = open(os.path.join(out, n + '.img'), 'wb'); f.truncate(size); files[n] = f
                        for (phys, ln, lo) in lst:
                            ranges.append((phys, phys + ln, lo, f))
                ranges.sort(key=lambda r: r[0])
                d, head = bytes(head), None
                write(d, 0)
            return
        write(data, at)

    def write(data, at):
        end = at + len(data)
        for (a, b, lo, f) in ranges:
            if b <= at or a >= end:
                continue
            s, e = max(a, at), min(b, end)
            chunk = data[s - at:e - at]
            if chunk.count(0) == len(chunk):
                continue
            f.seek(lo + (s - a)); f.write(chunk)

    def report():
        print('super_size=%d metadata_max=%d slots=%d' % (info['super_size'], info['metadata_max'], info['slots']), flush=True)
        for g, m in info['groups']:
            print('group %s max=%d' % (g, m), flush=True)
        for n, (lst, size, g) in parts.items():
            print('partition %s size=%d group=%s' % (n, size, g), flush=True)

    if not sparse:
        data = hdr
        while True:
            emit(data, pos); pos += len(data)
            data = inp.read(8 << 20)
            if not data: break
    else:
        magic, maj, mnr, fh, ch, bs, tb, tc, _ = struct.unpack('<IHHHHIIII', hdr)
        inp.read(fh - 28)
        for _ in range(tc):
            ctype, _, csz, tsz = struct.unpack('<HHII', inp.read(ch))
            inp.read(ch - 12) if ch > 12 else None
            n = csz * bs
            if ctype == 0xCAC1:
                left = n
                while left:
                    d = inp.read(min(left, 8 << 20)); emit(d, pos); pos += len(d); left -= len(d)
            elif ctype == 0xCAC2:
                pat = inp.read(4)
                if pat == b'\0\0\0\0' and info is not None:
                    pos += n
                else:
                    left = n
                    while left:
                        k = min(left, 8 << 20); emit(pat * (k // 4), pos); pos += k; left -= k
            elif ctype == 0xCAC3:
                if info is None:
                    emit(b'\0' * n, pos)
                pos += n
            elif ctype == 0xCAC4:
                inp.read(4)
    for f in files.values():
        f.close()
    print('done raw_bytes=%d' % pos)

main()
