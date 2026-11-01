#!/usr/bin/env python3
"""Разбор Samsung PIT: имя раздела, начало, размер (в блоках), файл прошивки."""
import struct, sys
d = open(sys.argv[1], 'rb').read()
magic, n = struct.unpack_from('<II', d, 0)
assert magic == 0x12349876, hex(magic)
print('project', d[16:24].rstrip(b'\0').decode(errors='replace'), 'entries', n)
for i in range(n):
    e = d[28 + i * 132: 28 + (i + 1) * 132]
    btype, dtype, ident, attr, uattr, start, cnt, foff, fsz = struct.unpack_from('<9I', e, 0)
    name = e[36:68].split(b'\0')[0].decode()
    fn = e[68:100].split(b'\0')[0].decode()
    print(f'{ident:3d} {name:16s} start={start:9d} blocks={cnt:9d} dev={dtype} file={fn}')
