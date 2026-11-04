#!/usr/bin/env python3
"""Проверка таблиц частот GPU (kgsl) в собранных DTB f2q.

f2q-6 не загружался: в бинах 1/2/4 было 11 уровней, а kgsl принимает не больше
KGSL_MAX_PWRLEVELS (10) -> adreno_of_parse_pwrlevels "index out of range" -> GPU не стартует.

  check_gpu_dtb.py <каталог ядра> <fold2-gpu.rc> <dtb, dtbo.img или boot.img> [...]

Проверяет каждый бин qcom,gpu-pwrlevels-N во всех FDT из файлов:
  - уровней (вместе с 0 Гц) <= KGSL_MAX_PWRLEVELS (drivers/gpu/msm/kgsl_pwrctrl.h);
  - уровней с qcom,acd-level <= MAX_ACD_NUM_LEVELS * MAX_ACD_STRIDE (kgsl_hfi.h, массив acd_tbl_cmd.data);
  - qcom,initial-pwrlevel и qcom,throttle-pwrlevel внутри таблицы;
  - бины с разгоном (есть 800 МГц): уровень max_pwrlevel из fold2-gpu.rc (on boot) = 670 МГц (сток),
    BCL (vbat/vph_gpu0, vbat/vph_gpu1 - в dtbo) ограничивает до 525 и 441 МГц, как у стока (уровни 2 и 4 бина 670).
"""
import re
import struct
import sys

STOCK_MHZ = 670
BCL_MHZ = {'0': 525, '1': 441}


def fdt_props(b):
    off_st, off_str = struct.unpack('>II', b[8:16])
    sz_st = struct.unpack('>I', b[36:40])[0]
    i, end, path = off_st, off_st + sz_st, []
    while i < end:
        tok = struct.unpack('>I', b[i:i + 4])[0]
        i += 4
        if tok == 1:
            j = b.index(b'\0', i)
            path.append(b[i:j].decode(errors='replace'))
            i = (j + 4) & ~3
            yield tuple(path), None, None
        elif tok == 2:
            path.pop()
        elif tok == 3:
            ln, no = struct.unpack('>II', b[i:i + 8])
            i += 8
            v = b[i:i + ln]
            i = (i + ln + 3) & ~3
            k = b.index(b'\0', off_str + no)
            yield tuple(path), b[off_str + no:k].decode(), v
        elif tok == 9:
            break


def fdts(data):
    o = 0
    while True:
        o = data.find(b'\xd0\x0d\xfe\xed', o)
        if o < 0:
            return
        tot = struct.unpack('>I', data[o + 4:o + 8])[0]
        if 40 <= tot <= len(data) - o:
            yield data[o:o + tot]
            o += tot
        else:
            o += 4


def u32s(v):
    return list(struct.unpack('>%dI' % (len(v) // 4), v[:len(v) // 4 * 4]))


def define(path, name):
    m = re.search(r'#define\s+%s\s+(\d+)' % name, open(path).read())
    if not m:
        sys.exit('%s: нет #define %s' % (path, name))
    return int(m.group(1))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    kdir, rc = sys.argv[1], sys.argv[2]
    max_lv = define(kdir + '/drivers/gpu/msm/kgsl_pwrctrl.h', 'KGSL_MAX_PWRLEVELS')
    max_acd = (define(kdir + '/drivers/gpu/msm/kgsl_hfi.h', 'MAX_ACD_NUM_LEVELS') *
               define(kdir + '/drivers/gpu/msm/kgsl_hfi.h', 'MAX_ACD_STRIDE'))
    m = re.search(r'^\s*write /sys/class/kgsl/kgsl-3d0/max_pwrlevel (\d+)\s*$', open(rc).read(), re.M)
    if not m:
        sys.exit('%s: нет "write .../max_pwrlevel N" (предел при загрузке)' % rc)
    boot_lv = int(m.group(1))
    print('KGSL_MAX_PWRLEVELS=%d, ACD max=%d, max_pwrlevel при загрузке=%d' % (max_lv, max_acd, boot_lv))
    errs, nbins, oc_bins, bcl_all = [], 0, [], []
    for fn in sys.argv[3:]:
        for di, d in enumerate(fdts(open(fn, 'rb').read())):
            bins, bcl, phandles = {}, {}, {}
            for p, name, v in fdt_props(d):
                if name is None:
                    continue
                if name == 'phandle':
                    phandles[p] = u32s(v)[0]
                bi = [x for x in p if x.startswith('qcom,gpu-pwrlevels-')]
                if bi:
                    e = bins.setdefault(bi[0], {'lv': {}})
                    if p[-1] == bi[0] and name in ('qcom,speed-bin', 'qcom,initial-pwrlevel', 'qcom,throttle-pwrlevel'):
                        e[name] = u32s(v)[0]
                    elif p[-1].startswith('qcom,gpu-pwrlevel@'):
                        lv = e['lv'].setdefault(int(p[-1].split('@')[1]), {})
                        if name == 'qcom,gpu-freq':
                            lv['f'] = u32s(v)[0] // 1000000
                        elif name == 'qcom,acd-level':
                            lv['acd'] = True
                    continue
                mm = re.fullmatch(r'(vbat|vph)_gpu([01])', p[-1] if p else '')
                if mm and name == 'cooling-device':
                    bcl[p[-1]] = (mm.group(2), u32s(v))
            # BCL - обычно в оверлеях dtbo: там &msm_gpu ещё не разрешён (0xffffffff), берём все тройки
            gph = next((ph for pp, ph in phandles.items() if pp and pp[-1].startswith('qcom,kgsl-3d0@')), None)
            for node, (lvl, cd) in bcl.items():
                for j in range(0, len(cd) - 2, 3):
                    if gph is None or cd[j] == gph:
                        bcl_all.append((node, lvl, cd[j + 1], cd[j + 2]))
            where = '%s#%d' % (fn, di)
            for k, e in sorted(bins.items()):
                nbins += 1
                lv = e['lv']
                n = len(lv)
                fr = [lv[i].get('f') for i in sorted(lv)]
                tag = '%s bin=%s [%s]' % (k, e.get('qcom,speed-bin'), ' '.join(map(str, fr)))
                if sorted(lv) != list(range(n)):
                    errs.append('%s: номера уровней не 0..%d (%s)' % (tag, n - 1, where))
                if n > max_lv:
                    errs.append('%s: %d уровней > KGSL_MAX_PWRLEVELS %d - GPU не стартует' % (tag, n, max_lv))
                acd = sum(1 for x in lv.values() if x.get('acd'))
                if acd > max_acd:
                    errs.append('%s: %d уровней с ACD > %d' % (tag, acd, max_acd))
                for pk in ('qcom,initial-pwrlevel', 'qcom,throttle-pwrlevel'):
                    if pk in e and not 0 <= e[pk] < n:
                        errs.append('%s: %s=%d вне таблицы' % (tag, pk, e[pk]))
                if 800 not in fr:
                    continue
                oc_bins.append((tag, fr))
                if boot_lv >= n or fr[boot_lv] != STOCK_MHZ:
                    errs.append('%s: max_pwrlevel %d при загрузке - не %d МГц' % (tag, boot_lv, STOCK_MHZ))
    for tag, fr in oc_bins:
        for node, lvl, lo, hi in bcl_all:
            for s_ in (lo, hi):
                got = fr[s_] if s_ < len(fr) else None
                if got != BCL_MHZ[lvl]:
                    errs.append('%s: BCL %s уровень %d = %s МГц, нужно %d (как сток)' % (tag, node, s_, got, BCL_MHZ[lvl]))
    noc, nbcl = len(oc_bins), len(bcl_all)
    print('бинов GPU: %d, с разгоном 800 МГц: %d, узлов BCL GPU: %d' % (nbins, noc, nbcl))
    if not nbins:
        errs.append('не найдено ни одного qcom,gpu-pwrlevels-N')
    if errs:
        print('\n'.join(sorted(set(errs))))
        sys.exit(1)
    print('GPU DTB: OK')


if __name__ == '__main__':
    main()
