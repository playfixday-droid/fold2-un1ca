#!/bin/bash
# Root: патчит boot.img Magisk'ом на ПК/в сборке (Linux x86_64) ровно тем же скриптом,
# что и приложение Magisk на телефоне (assets/boot_patch.sh из APK).
# Использование: magisk_patch_boot.sh <boot.img> <Magisk-vXX.apk> <out-boot.img>
# Настройки как у приложения для Fold2 на нашей прошивке: verity выключен (vbmeta flags=3),
# шифрование данных (FBE) сохраняется, ramdisk в boot (не recovery). Плюс bootfix/ (overlay.d), см. ниже.
set -euo pipefail
B=$(readlink -f "${1:?boot.img}"); A=$(readlink -f "${2:?Magisk.apk}"); OUT=$(readlink -m "${3:?out.img}")
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(uname -m)" = x86_64 ] || { echo "Нужен Linux x86_64 (magiskboot из APK)"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W"
unzip -q -o "$A" assets/boot_patch.sh assets/util_functions.sh \
  lib/x86_64/libmagiskboot.so lib/x86_64/libbusybox.so lib/arm64-v8a/libmagiskinit.so lib/arm64-v8a/libmagisk.so lib/arm64-v8a/libinit-ld.so \
  || { echo "В APK нет нужных файлов (нужен Magisk v28+)"; exit 1; }
mv assets/boot_patch.sh assets/util_functions.sh .
mv lib/x86_64/libmagiskboot.so magiskboot
mv lib/x86_64/libbusybox.so busybox
mv lib/arm64-v8a/libmagiskinit.so magiskinit
mv lib/arm64-v8a/libmagisk.so magisk
mv lib/arm64-v8a/libinit-ld.so init-ld
chmod 755 magiskboot busybox magiskinit magisk init-ld
cp "$B" boot.img
# Запуск в busybox ash из того же APK — как на телефоне. BOOTMODE=false: скрипт не пытается запускать arm64-бинарники; ui_print пишет в OUTFD=1
BOOTMODE=false OUTFD=1 KEEPVERITY=false KEEPFORCEENCRYPT=true PATCHVBMETAFLAG=false \
  RECOVERYMODE=false LEGACYSAR=false ./busybox sh ./boot_patch.sh boot.img >> patch.log 2>&1 || { sed -E -e '/^(-e )?ui_print$/d' -e 's/^(-e )?ui_print //' patch.log; exit 1; }
sed -n -E 's/^(-e )?ui_print (- .*)/\2/p' patch.log
[ -s new-boot.img ] || { echo "Magisk не создал new-boot.img"; exit 1; }
# Помощник загрузки f2q (bootfix/): overlay.d/fold2.rc Magisk допишет к init.rc, overlay.d/sbin/fold2boot.sh
# окажется в ${MAGISKTMP}. Он чинит /data перед первым монтированием и пишет логи загрузки в /cache/fold2log.
BF=$HERE/bootfix
mkdir ovl && cd ovl
../magiskboot unpack ../new-boot.img > /dev/null 2>&1
../magiskboot cpio ramdisk.cpio "mkdir 0750 overlay.d" "mkdir 0750 overlay.d/sbin" \
  "add 0644 overlay.d/fold2.rc $BF/fold2.rc" "add 0755 overlay.d/sbin/fold2boot.sh $BF/fold2boot.sh" > /dev/null 2>&1
../magiskboot repack ../new-boot.img ../new-boot-bf.img > /dev/null 2>&1
cd .. && mv -f new-boot-bf.img new-boot.img && echo "- bootfix: overlay.d/fold2.rc, overlay.d/sbin/fold2boot.sh"
# проверка: ramdisk помечен как пропатченный Magisk (статус 1), файлы bootfix на месте и совпадают
mkdir chk && cd chk
../magiskboot unpack ../new-boot.img > /dev/null 2>&1
set +e; ../magiskboot cpio ramdisk.cpio test > /dev/null 2>&1; S=$?; set -e
[ "$S" = 1 ] || { echo "Проверка не прошла: ramdisk status=$S"; exit 1; }
../magiskboot cpio ramdisk.cpio "extract overlay.d/fold2.rc fold2.rc" "extract overlay.d/sbin/fold2boot.sh fold2boot.sh" > /dev/null 2>&1
cmp -s fold2.rc "$BF/fold2.rc" && cmp -s fold2boot.sh "$BF/fold2boot.sh" || { echo "Проверка не прошла: нет bootfix в ramdisk"; exit 1; }
cd ..
cp new-boot.img "$OUT"
echo "- Magisk $(unzip -p "$A" assets/util_functions.sh | sed -n 's/^MAGISK_VER=.\([^"'\'']*\).*/\1/p' | head -1): $(basename "$OUT") ($(stat -c %s "$OUT") байт)"
