#!/bin/bash
# Проверка fold2boot.sh (fix/check) на образах f2fs без root: свежая ФС стирается, ФС с данными - нет.
# Нужны mkfs.f2fs и sload.f2fs (f2fs-tools); оболочка - mksh, как /system/bin/sh на телефоне.
# Использование: bash test_fold2boot.sh [оболочка]     (CI: job kernel, шаг «bootfix test»)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SH=${1:-$(command -v mksh || command -v sh)}
MKFS=${MKFS:-mkfs.f2fs}; SLOAD=${SLOAD:-sload.f2fs}; BIG=${BIG:-240G}
TP=${TOOLS_PATH:-$PATH}   # PATH для fold2boot.sh (например, каталог с ссылками на toybox, как на телефоне)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAIL=0
h8k() { head -c 8192 "$1" | md5sum | cut -d' ' -f1; }
z8k() { [ "$(head -c 8192 "$1" | tr -d '\000' | wc -c)" -eq 0 ]; }
# t <название> <образ> <ожидаемое решение> <стереть суперблоки: yes|no> <ключ остаётся: yes|no> [in_progress]
t() {
  local name=$1 img=$2 want=$3 zero=$4 keep=$5 inprog=${6:-} before got z=no k=no
  rm -rf "$T/k" "$T/l"; mkdir -p "$T/k/key"; echo x > "$T/k/key/encrypted_key"
  [ -z "$inprog" ] || touch "$T/k/in_progress"
  before=$(h8k "$img")
  export FOLD2_TEST=1 FOLD2_USERDATA="$img" FOLD2_KEYDIR="$T/k" FOLD2_LOGDIR="$T/l"
  got=$(PATH=$TP "$SH" "$HERE/fold2boot.sh" check | sed -n 's/^decision: //p')
  PATH=$TP "$SH" "$HERE/fold2boot.sh" fix
  if [ "$before" != "$(h8k "$img")" ] && z8k "$img"; then z=yes; elif [ "$before" = "$(h8k "$img")" ]; then z=no; else z=bad; fi
  [ -e "$T/k" ] && k=yes
  if [ "$got" = "$want" ] && [ "$z" = "$zero" ] && [ "$k" = "$keep" ]; then
    echo "OK   $name: $got, стёрто=$z, ключ=$k"
  else
    echo "FAIL $name: решение $got (ждали $want), стёрто=$z ($zero), ключ=$k ($keep)"; sed 's/^/     /' "$T/l/fix.log"; FAIL=1
  fi
}
mk() { rm -f "$1"; truncate -s "$2" "$1"; "$MKFS" -q -f -O encrypt -O extra_attr "$1" > /dev/null; }
mk "$T/fresh.img" 4G;                t "свежая f2fs (как после сброса в recovery)" "$T/fresh.img" fresh yes no
mk "$T/big.img" "$BIG";              t "свежая f2fs $BIG (размер userdata)" "$T/big.img" fresh yes no
mk "$T/fsck.img" 4G; fsck.f2fs -f -a "$T/fsck.img" > /dev/null 2>&1 || true
                                     t "свежая f2fs после fsck" "$T/fsck.img" fresh yes no
mkdir -p "$T/files/d"; for i in $(seq 1 1500); do echo "$i" > "$T/files/d/f$i"; done
mk "$T/used.img" 4G; "$SLOAD" -f "$T/files" "$T/used.img" > /dev/null
                                     t "f2fs с данными (1500 файлов)" "$T/used.img" keep no yes
rm -rf "$T/files"; mkdir -p "$T/files"; head -c 1200M /dev/zero | tr '\000' 'a' > "$T/files/big"
mk "$T/used2.img" 4G; "$SLOAD" -f "$T/files" "$T/used2.img" > /dev/null; rm -rf "$T/files"
                                     t "f2fs с данными (файл 1,2 ГиБ)" "$T/used2.img" keep no yes
t "f2fs с данными + in_progress" "$T/used.img" interrupted yes no 1
truncate -s 64M "$T/zero.img";       t "стёртая (нули, NAND erase)" "$T/zero.img" wiped no no
head -c 64M /dev/zero | tr '\000' '\377' > "$T/ff.img"
                                     t "стёртая (0xFF)" "$T/ff.img" wiped no no
head -c 64M /dev/urandom > "$T/enc.img"
                                     t "зашифрованная (dm-default-key)" "$T/enc.img" keep no yes
t "зашифрованная + in_progress (прервано)" "$T/enc.img" interrupted yes no 1
exit $FAIL
