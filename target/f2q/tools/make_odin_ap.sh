#!/bin/bash
# ЧЕРНОВИК, на телефоне не проверялся.
# Превращает target-files zip UN1CA (f2q) в AP.tar.md5 для Odin (без TWRP).
# Использование (из дерева UN1CA после сборки, утилиты UN1CA в PATH):
#   source buildenv.sh f2q
#   bash make_odin_ap.sh out/<target-files>.zip out/odin
# Нужны: lpmake, simg2img, avbtool (собираются UN1CA: scripts/build_dependencies.sh), lz4
set -euo pipefail
Z=$(readlink -f "${1:?target-files zip}"); O=$(readlink -f "${2:?out dir}")
: "${TARGET_SUPER_PARTITION_SIZE:?source buildenv.sh f2q}"
G=${TARGET_SUPER_GROUP_NAME:-qti_dynamic_partitions}
GS=${TARGET_QTI_DYNAMIC_PARTITIONS_SIZE:?}
AVBTOOL=${AVBTOOL:-avbtool}
for t in lpmake simg2img lz4 unzip; do command -v "$t" >/dev/null || { echo "Нет $t (source buildenv.sh f2q)"; exit 1; }; done
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$O"
unzip -q -o "$Z" '*.img' -d "$T"
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
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/vbmeta-F916BXXS7KXH1-flags3.img" ]; then
  cp "$HERE/vbmeta-F916BXXS7KXH1-flags3.img" "$T/vbmeta.img"
else
  "$AVBTOOL" make_vbmeta_image --flags 2 --padding_size 4096 --output "$T/vbmeta.img"
fi
cd "$T"
FILES=()
for f in boot.img dtbo.img vbmeta.img super.img; do
  [ -f "$f" ] || { echo "Нет $f"; exit 1; }
  lz4 -B6 --content-size -q "$f" "$f.lz4" && rm -f "$f"; FILES+=("$f.lz4")
done
tar -H ustar -c -f AP_f2q_un1ca.tar "${FILES[@]}"
SUM=$(md5sum -t AP_f2q_un1ca.tar)
echo "$SUM" >> AP_f2q_un1ca.tar
mv AP_f2q_un1ca.tar "$O/AP_f2q_un1ca.tar.md5"
ls -la "$O"
echo "Odin: AP = этот файл, BL/CP/CSC = из стока F916BXXS7KXH1 (CSC, не HOME_CSC — сотрёт /data)."
