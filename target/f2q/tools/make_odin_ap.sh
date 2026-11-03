#!/bin/bash
# ЧЕРНОВИК, на телефоне не проверялся.
# Превращает target-files zip UN1CA (f2q) в AP.tar.md5 для Odin (без TWRP).
# Использование (из дерева UN1CA после сборки, утилиты UN1CA в PATH):
#   source buildenv.sh f2q
#   bash make_odin_ap.sh out/<target-files>.zip out/odin
# Нужны: lpmake, simg2img, avbtool (собираются UN1CA: scripts/build_dependencies.sh), lz4
# Root: MAGISK_APK=/путь/Magisk-vXX.apk — boot.img в AP патчится Magisk (magisk_patch_boot.sh),
#       рядом кладутся BOOT_noroot_f2q.tar.md5 (вернуть boot без root через Odin) и сам APK.
# Режим экрана без пересборки: ALT_BOOT=<boot-f2q-cover.img или boot-f2q-dual.img из сборки ядра> - рядом кладутся
#       BOOT_dual_f2q.tar.md5 и BOOT_cover_f2q.tar.md5 (boot с тем же root, что в AP; режим - по cmdline ядра).
set -euo pipefail
Z=$(readlink -f "${1:?target-files zip}"); O=$(readlink -f "${2:?out dir}")
: "${TARGET_SUPER_PARTITION_SIZE:?source buildenv.sh f2q}"
G=${TARGET_SUPER_GROUP_NAME:-qti_dynamic_partitions}
GS=${TARGET_QTI_DYNAMIC_PARTITIONS_SIZE:?}
AVBTOOL=${AVBTOOL:-avbtool}
for t in lpmake simg2img lz4 unzip; do command -v "$t" >/dev/null || { echo "Нет $t (source buildenv.sh f2q)"; exit 1; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$O"
unzip -q -o "$Z" '*.img' -d "$T"
odin_tar() {  # odin_tar <имя.tar.md5> <файлы...> (в каталоге $T)
  local name=$1 sum; shift
  tar -H ustar -c -f "${name%.md5}" "$@"
  sum=$(md5sum -t "${name%.md5}")
  echo "$sum" >> "${name%.md5}"
  mv "${name%.md5}" "$O/$name"
}
# Защита от «кирпича». Download Mode (Odin) живёт в загрузчике (BL: sboot/xbl/abl...): пока его не трогают, телефон
# всегда можно перепрошить стоком. Поэтому в AP - только эти разделы, и ни один образ не больше своего раздела.
# Загрузчик, EFS/sec_efs (IMEI), param/up_param, модем, persist, keydata - сюда не попадают никогда.
AP_ALLOWED="boot.img.lz4 dtbo.img.lz4 super.img.lz4 vbmeta.img.lz4"
check_tar() {  # check_tar <файл.tar.md5> <разрешённые имена через пробел>: в архиве ровно они
  local got
  got=$(tar -tf "$1" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
  [ "$got" = "$2" ] || { echo "ОШИБКА: в $(basename "$1") файлы '$got', а можно только '$2' - не выпускаю"; exit 1; }
}
check_size() {  # check_size <образ> <размер раздела, байт>
  local s; s=$(stat -c %s "$1")
  [ -z "$2" ] || [ "$s" -le "$2" ] || { echo "ОШИБКА: $(basename "$1") $s байт больше раздела ($2) - Odin оборвал бы прошивку"; exit 1; }
}
boot_tar() {  # boot_tar <boot.img> <имя.tar.md5>: только boot для Odin (слот AP)
  local d; d=$(mktemp -d "$T/boot.XXXXXX")
  check_size "$1" "${TARGET_BOOT_PARTITION_SIZE:-}"
  lz4 -B6 --content-size -q "$1" "$d/boot.img.lz4"
  (cd "$d" && odin_tar "$2" boot.img.lz4) && rm -rf "$d"
  check_tar "$O/$2" "boot.img.lz4"
}
# режим экрана boot.img - по cmdline ядра в заголовке (make_boot.sh: cover = msm_drm.f2q_cover_only=1)
boot_mode() {
  local h; h=$(head -c 4096 "$1" | tr -d '\000')
  case "$h" in *msm_drm.f2q_cover_only=1*) echo cover ;; *) echo dual ;; esac
}
MODE=$(boot_mode "$T/boot.img")
echo "boot.img в AP: ядро $MODE"
if [ -n "${ALT_BOOT:-}" ]; then
  [ -f "$ALT_BOOT" ] || { echo "Нет ALT_BOOT=$ALT_BOOT"; exit 1; }
  ALT=$(boot_mode "$ALT_BOOT")
  [ "$ALT" != "$MODE" ] || { echo "ОШИБКА: ALT_BOOT того же режима ($ALT), что boot.img в AP"; exit 1; }
  cp "$ALT_BOOT" "$T/boot-alt.img"
fi
if [ -n "${MAGISK_APK:-}" ]; then
  echo "Root: Magisk -> boot.img"
  mv "$T/boot.img" "$T/boot-noroot.img"
  bash "$HERE/magisk_patch_boot.sh" "$T/boot-noroot.img" "$MAGISK_APK" "$T/boot.img"
  boot_tar "$T/boot-noroot.img" BOOT_noroot_f2q.tar.md5 && rm -f "$T/boot-noroot.img"
  cp "$MAGISK_APK" "$O/$(basename "$MAGISK_APK")"
  if [ -f "$T/boot-alt.img" ]; then
    mv "$T/boot-alt.img" "$T/boot-alt-noroot.img"
    bash "$HERE/magisk_patch_boot.sh" "$T/boot-alt-noroot.img" "$MAGISK_APK" "$T/boot-alt.img" && rm -f "$T/boot-alt-noroot.img"
  fi
fi
if [ -f "$T/boot-alt.img" ]; then
  echo "Режим экрана без пересборки: BOOT_${MODE}_f2q (как в AP) и BOOT_${ALT}_f2q"
  boot_tar "$T/boot.img" "BOOT_${MODE}_f2q.tar.md5"
  [ "$(boot_mode "$T/boot-alt.img")" = "$ALT" ] || { echo "ОШИБКА: после Magisk у boot другого режима сменилась cmdline"; exit 1; }
  boot_tar "$T/boot-alt.img" "BOOT_${ALT}_f2q.tar.md5" && rm -f "$T/boot-alt.img"
fi
ARGS=(--metadata-size 65536 --super-name super --metadata-slots 2
      --device "super:$TARGET_SUPER_PARTITION_SIZE" --group "$G:$GS")
TOTAL=0
for p in system vendor product system_ext odm vendor_dlkm odm_dlkm system_dlkm; do
  [ -f "$T/$p.img" ] || continue
  if [ "$(od -An -tx1 -N4 "$T/$p.img" | tr -d ' \n')" = "3aff26ed" ]; then   # sparse-образ
    simg2img "$T/$p.img" "$T/$p.raw"
  else
    mv "$T/$p.img" "$T/$p.raw"
  fi
  rm -f "$T/$p.img"
  S=$(stat -c %s "$T/$p.raw"); TOTAL=$((TOTAL+S))
  ARGS+=(--partition "$p:readonly:$S:$G" --image "$p=$T/$p.raw")
  echo "  $p: $((S/1048576)) MiB"
done
[ "$TOTAL" -le "$GS" ] || { echo "Не влезает в группу super: $TOTAL > $GS"; exit 1; }
lpmake "${ARGS[@]}" --sparse --output "$T/super.img"
rm -f "$T"/*.raw
# vbmeta: стоковый F916BXXS7KXH1 с flags=3 (ровно так патчит Magisk для Samsung);
# запасной вариант — пустой vbmeta с flags=2.
if [ -f "$HERE/vbmeta-F916BXXS7KXH1-flags3.img" ]; then
  cp "$HERE/vbmeta-F916BXXS7KXH1-flags3.img" "$T/vbmeta.img"
else
  "$AVBTOOL" make_vbmeta_image --flags 2 --padding_size 4096 --output "$T/vbmeta.img"
fi
cd "$T"
FILES=()
for f in boot.img dtbo.img vbmeta.img super.img; do
  [ -f "$f" ] || { echo "Нет $f"; exit 1; }
  case "$f" in  # super: размер проверил lpmake (--device super:...)
    boot.img) check_size "$f" "${TARGET_BOOT_PARTITION_SIZE:-}" ;;
    dtbo.img) check_size "$f" "${TARGET_DTBO_PARTITION_SIZE:-}" ;;
  esac
  lz4 -B6 --content-size -q "$f" "$f.lz4" && rm -f "$f"; FILES+=("$f.lz4")
done
odin_tar AP_f2q_un1ca.tar.md5 "${FILES[@]}"
check_tar "$O/AP_f2q_un1ca.tar.md5" "$AP_ALLOWED"
ls -la "$O"
echo "Odin: AP = этот файл, BL/CP/CSC = из стока F916BXXS7KXH1 (CSC, не HOME_CSC — сотрёт /data)."
