#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012,SC2010,SC1091,SC2016  # A && ok || bad: ok/bad всегда успешны; ls - в своих временных каталогах
# Тесты скриптов телефона без телефона: debian.sh (battery, status/температуры, bootlog, autostart, справка),
# backup_efs.sh, npu.sh (уровень отладки, поиск модели, test: итог и зависший f2q-bench, справка).
# /sys, /proc, /dev/block, /data/adb, /data/local/tmp в копиях скриптов заменены временным каталогом;
# getprop/id/logcat/blockdev/sleep - заглушки из fake/, остальные утилиты - busybox (как toybox на Android).
# Каждый тест идёт в двух оболочках: mksh под именем sh (это /system/bin/sh Android, им запускают через su)
# и busybox ash (им Magisk выполняет service.d - автозапуск).
#   bash linux/test/test_phone.sh        (BUSYBOX=, MKSH= - пути, если их нет в PATH; REQUIRE_ALL=1 - без пропусков)
set -uo pipefail
TD=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$TD/../.." && pwd)
. "$TD/lib.sh"
BUSYBOX=${BUSYBOX:-$(command -v busybox || true)}
MKSH=${MKSH:-$(command -v mksh || true)}
[ -x "$BUSYBOX" ] || { echo "нужен busybox (BUSYBOX=путь)"; exit 2; }
if [ ! -x "$MKSH" ]; then
  [ "${REQUIRE_ALL:-0}" = 1 ] && { echo "нужен mksh (MKSH=путь)"; exit 2; }
  echo "ВНИМАНИЕ: mksh не найден - только busybox ash"
fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# заглушки - копией с правом запуска (через API GitHub файлы попадают в репозиторий без +x)
FK=$WORK/fake; cp -R "$TD/fake" "$FK"; chmod -R 755 "$FK"
BB=$WORK/bb; mkdir -p "$BB"
ln -s "$BUSYBOX" "$BB/busybox"; BUSYBOX=$BB/busybox # busybox выбирает applet по имени файла - имя должно быть busybox
for A in $("$BUSYBOX" --list); do ln -s "$BUSYBOX" "$BB/$A"; done
# busybox с SH_STANDALONE (например, из Ubuntu/Debian) запускает свои applets мимо PATH - заглушки id/sleep/blockdev не сработают
if [ "$(env -i PATH="$FK" FAKE_UID=2000 "$BUSYBOX" sh -c 'id -u')" != 2000 ]; then
  echo "busybox $BUSYBOX собран с SH_STANDALONE: заглушки не работают. Нужна обычная сборка, например"
  echo "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"; exit 2
fi

rw() { # копия скрипта, где пути устройства ведут в $T
  # только пути от корня: /proc/sys/... не превращается в /proc$T/sys/..., $R/sys/ не трогается
  local B='\(^\|[^A-Za-z0-9_./}]\)'
  sed -e "s#$B/proc/#\\1$T/proc/#g" -e "s#$B/sys/#\\1$T/sys/#g" -e "s#$B/dev/block/#\\1$T/dev/block/#g" \
      -e "s#$B/data/adb/#\\1$T/data/adb/#g" -e "s#$B/data/local/tmp#\\1$T/tmp#g" "$1" >"$2"
}
# run <вывод> <скрипт> [аргументы] - в оболочке под тестом, PATH = заглушки + busybox; переменные - через ENVX
ENVX=()
run() {
  local O=$1; shift
  env -i HOME="$T" PATH="$T/sb:$FK:$BB" FAKE_ROOT="$T" FOLD2_BASE="$T/base" LANG=C.UTF-8 TZ=UTC \
    ${ENVX[@]+"${ENVX[@]}"} "$T/sb/sh" "$@" >"$O" 2>&1
}
zone() { mkdir -p "$T/sys/class/thermal/thermal_zone$1"; echo "$2" >"$T/sys/class/thermal/thermal_zone$1/type"; [ -n "${3:-}" ] && echo "$3" >"$T/sys/class/thermal/thermal_zone$1/temp"; }
prop() { echo "$1=$2" >>"$T/props"; }

setup() { # setup <оболочка>: новый каталог-"телефон"
  T=$WORK/$1; rm -rf "$T"; mkdir -p "$T/sb" "$T/base" "$T/tmp" "$T/data/adb"
  case "$1" in mksh) ln -s "$MKSH" "$T/sb/sh" ;; ash) ln -s "$BUSYBOX" "$T/sb/sh" ;; esac
  rw "$REPO/linux/phone/debian.sh" "$T/debian.sh"; rw "$REPO/linux/phone/backup_efs.sh" "$T/backup_efs.sh"
  rw "$REPO/npu/phone/npu.sh" "$T/npu.sh"
  BAT=$T/sys/class/power_supply/battery; mkdir -p "$BAT"
  echo 77 >"$BAT/capacity"; echo Charging >"$BAT/status"; echo 315 >"$BAT/temp"; echo 100 >"$BAT/batt_full_capacity"
  zone 0 cpu-1-0-usr 43000; zone 1 cpu-1-2-usr 45600; zone 2 gpuss-0-usr 50000; zone 3 q6-hvx-usr 40000
  zone 4 battery 30000; zone 5 cpuss-0-usr 41000; zone 6 npu-usr 39; zone 7 cpu-0-0-usr # без temp - пропуск
  mkdir -p "$T/proc/sys/kernel/random" "$T/sys/fs/pstore"
  echo 1a2b3c4d-1111-2222-3333-444455556666 >"$T/proc/sys/kernel/random/boot_id"
  echo "androidboot.debug_level=0x4f4c androidboot.force_upload=0x0 signoff=0x2377" >"$T/proc/cmdline"
  : >"$T/props"; prop ro.boot.debug_level 0x4f4c; prop sys.boot_completed 1
  ENVX=()
}

t_debian() {
  local O=$T/out D=$T/debian.sh F=$T/sys/class/power_supply/battery/batt_full_capacity RC
  echo "-- debian.sh: battery"
  run "$O" "$D" battery; RC=$?
  eq "$RC" 0 "battery без аргумента" "$O"; has "$O" "батарея: 77% Charging, 31.5°C" "строка батареи"; hasnt "$O" "предел" "без предела при 100"
  run "$O" "$D" battery 80; eq "$?" 0 "battery 80" "$O"; eq "$(cat "$F")" 80 "записано 80"; has "$O" "предел заряда 80%" "предел в выводе"
  run "$O" "$D" battery off; eq "$(cat "$F")" 100 "battery off = 100"
  for V in 49 100 8O -5 5x; do
    echo 90 >"$F"; run "$O" "$D" battery "$V"; RC=$?
    [ "$RC" != 0 ] && [ "$(cat "$F")" = 90 ] && ok "battery '$V' отклонён" || bad "battery '$V' принят (rc=$RC, файл $(cat "$F"))" "$O"
  done
  echo -5 >"$T/sys/class/power_supply/battery/temp"; run "$O" "$D" battery
  has "$O" "-0.5°C" "отрицательная температура батареи"; echo 315 >"$T/sys/class/power_supply/battery/temp"
  mv "$F" "$F.x"; run "$O" "$D" battery 80; RC=$?
  [ "$RC" != 0 ] && grep -qF "нет $F" "$O" && ok "нет batt_full_capacity - ошибка" || bad "нет batt_full_capacity (rc=$RC)" "$O"; mv "$F.x" "$F"

  echo "-- debian.sh: status"
  run "$O" "$D" status; eq "$?" 0 "status код 0" "$O"
  has "$O" "rootfs: $T/base/debian (нет)" "rootfs нет"
  has "$O" "температура: cpu 46°C, gpuss 50°C, q6-hvx 40°C, cpuss 41°C, npu 39°C" "температуры по группам"
  has "$O" "батарея: 77%" "батарея в status"; hasnt "$O" "настройка Debian" "без rootfs - про настройку молчит"

  echo "-- debian.sh: install - оборванная установка продолжается"
  local RD=$T/base/debian
  run "$O" "$D" install - fold2; RC=$?
  [ "$RC" != 0 ] && grep -qF "нет файла rootfs: -" "$O" && ok "без rootfs и без tar.xz - ошибка" || bad "install без rootfs (rc=$RC)" "$O"
  mkdir -p "$RD/bin" "$RD/root" "$RD/etc"; printf '#!/bin/sh\n' >"$RD/bin/sh"; chmod 755 "$RD/bin/sh"; : >"$RD/root/setup_in_chroot.sh"
  run "$O" "$D" status; has "$O" "настройка Debian: НЕ закончена" "status: настройка не закончена"
  # дальше install копирует setup_in_chroot.sh, которого рядом с копией debian.sh нет, - и останавливается до монтирований
  run "$O" "$D" install - fold2; RC=$?
  [ "$RC" != 0 ] && grep -qF "настройка не закончена - продолжаю" "$O" && grep -qF "нет setup_in_chroot.sh" "$O" \
    && ok "распакованный rootfs без отметки - install продолжает настройку" || bad "продолжение install (rc=$RC)" "$O"
  date >"$RD/etc/fold2-setup.done"
  run "$O" "$D" install - fold2; RC=$?
  [ "$RC" != 0 ] && grep -qF "уже установлено" "$O" && ok "с отметкой - уже установлено" || bad "install с отметкой (rc=$RC)" "$O"
  run "$O" "$D" status; has "$O" "настройка Debian: закончена" "status: настройка закончена"
  rm -rf "$RD"

  echo "-- debian.sh: bootlog"
  local L=$T/base/bootlogs
  echo "Kernel panic - test" >"$T/sys/fs/pstore/console-ramoops-0"; printf 'KP\nextra\n' >"$T/proc/reset_reason"
  echo kmsg >"$T/proc/last_kmsg"; : >"$T/proc/auto_comment"
  run "$O" "$D" bootlog; eq "$?" 0 "bootlog код 0" "$O"; has "$O" "(причина: KP)" "причина в выводе"
  local X; X=$(ls -d "$L"/*-1a2b3c4d 2>/dev/null)
  eq "$(echo "$X" | grep -c .)" 1 "один каталог на загрузку"
  for N in pstore-console-ramoops-0 reset_reason last_kmsg logcat-last.txt info.txt; do
    [ -s "$X/$N" ] && ok "собран $N" || bad "нет $N в $X"
  done
  [ -e "$X/auto_comment" ] && bad "пустой auto_comment не удалён" || ok "пустые файлы удалены"
  has "$X/info.txt" "ro.boot.debug_level=0x4f4c" "info.txt: уровень отладки"
  has "$X/logcat-last.txt" "-L -d" "logcat -L -d"
  sleep 1; run "$O" "$D" bootlog
  eq "$(ls -d "$L"/*-1a2b3c4d | grep -c .)" 1 "повтор в ту же загрузку перезаписывает"
  for I in 1 2 3 4 5 6; do mkdir -p "$L/2020010$I-000000-0000000$I"; echo "old$I" >"$L/2020010$I-000000-0000000$I/reset_reason"; done
  run "$O" "$D" bootlog; eq "$(ls "$L" | grep -c .)" 5 "хранится 5 (по умолчанию)"
  [ -d "$(ls -d "$L"/*-1a2b3c4d)" ] && [ -d "$L/20200106-000000-00000006" ] && [ ! -d "$L/20200102-000000-00000002" ] \
    && ok "удаляются самые старые" || bad "удалены не те: $(ls "$L" | tr '\n' ' ')"
  echo "BOOTLOG_KEEP=2" >"$T/base/debian.conf"; run "$O" "$D" bootlog; eq "$(ls "$L" | grep -c .)" 2 "BOOTLOG_KEEP=2"
  echo "BOOTLOG_KEEP=abc" >"$T/base/debian.conf"; for I in 1 2 3 4 5 6; do mkdir -p "$L/2020010$I-000000-0000000$I"; done
  run "$O" "$D" bootlog; eq "$(ls "$L" | grep -c .)" 5 "BOOTLOG_KEEP=abc -> 5"; rm -f "$T/base/debian.conf"
  run "$O" "$D" bootlog ls; has "$O" "-1a2b3c4d: KP" "bootlog ls"

  echo "-- debian.sh: autostart"
  local S=$T/data/adb/service.d/fold2-debian.sh
  run "$O" "$D" autostart on; eq "$?" 0 "autostart on" "$O"
  [ -x "$S" ] && ok "service.d скрипт исполняемый" || bad "нет $S" "$O"
  has "$S" "BASE='$T/base'" "BASE в автозапуске"
  [ -f "$T/base/debian.sh" ] && ok "debian.sh скопирован в BASE" || bad "debian.sh не скопирован в BASE"
  # вместо debian.sh - заглушка, пишущая команды; проверяем порядок и цикл предела заряда
  printf '#!/bin/sh\necho "$*" >>"$FAKE_ROOT/calls"\n' >"$T/base/debian.sh"
  printf 'BATT_LIMIT=85\nAUTO_SSH=1\nAUTO_DOCKER=0\nAUTO_LLAMA=0\nAUTO_BOOTLOG=1\n' >"$T/base/debian.conf"
  echo 100 >"$F"; echo 1 >"$T/sleep600"; : >"$T/calls"
  run "$O" "$S"; eq "$?" 0 "автозапуск отработал" "$O"
  local I=0; while [ "$(cat "$F")" != 85 ] && [ $I -lt 50 ]; do sleep 0.1; I=$((I + 1)); done
  eq "$(tr '\n' ',' <"$T/calls")" "bootlog,battery 85,start,ssh," "автозапуск: bootlog, battery, start, ssh"
  eq "$(cat "$F")" 85 "цикл вернул предел заряда"
  has "$T/base/autostart.log" "предел заряда снова 85%" "цикл пишет в autostart.log"
  printf 'BATT_LIMIT=\nAUTO_SSH=0\nAUTO_BOOTLOG=0\n' >"$T/base/debian.conf"; : >"$T/calls"
  run "$O" "$S"; eq "$(tr '\n' ',' <"$T/calls")" "start," "автозапуск без предела, bootlog и ssh"
  rm -f "$T/base/debian.conf"; : >"$T/calls"
  run "$O" "$S"; eq "$?" 0 "автозапуск без debian.conf: код 0" "$O"
  eq "$(tr '\n' ',' <"$T/calls")" "bootlog,start,ssh," "без debian.conf - как по умолчанию: bootlog, start, ssh"
  # AUTO_LLAMA без LLAMA_MODEL: модель с Hugging Face - сначала ждём сеть (ip route get не проходит 2 раза)
  printf '#!/bin/sh\nN=$(cat "$FAKE_ROOT/ipfail" 2>/dev/null || echo 0)\n[ "$N" -gt 0 ] && { echo $((N - 1)) >"$FAKE_ROOT/ipfail"; exit 2; }\nexit 0\n' >"$T/sb/ip"
  chmod 755 "$T/sb/ip"; echo 2 >"$T/ipfail"; : >"$T/sleep.log"
  printf 'AUTO_SSH=0\nAUTO_BOOTLOG=0\nAUTO_LLAMA=1\nLLAMA_MODEL=\n' >"$T/base/debian.conf"; : >"$T/calls"
  run "$O" "$S"; eq "$(tr '\n' ',' <"$T/calls")" "start,llama," "AUTO_LLAMA: start, llama"
  eq "$(grep -c '^sleep 15$' "$T/sleep.log")" 2 "перед llama -hf ждёт сеть"
  rm -f "$T/sb/ip" "$T/ipfail"
  run "$O" "$D" autostart off; [ ! -e "$S" ] && ok "autostart off" || bad "autostart off не удалил" "$O"
  rm -f "$T/base/debian.conf" "$T/base/debian.sh"

  echo "-- debian.sh: справка и root"
  run "$O" "$D" nonsense; eq "$?" 1 "неизвестная команда: код 1"
  eq "$(head -n 1 "$O")" "# fold2: Debian 13 (trixie) в chroot на Galaxy Z Fold2 (UN1CA, Magisk root)." "справка с первой строки"
  has "$O" "bootlog [ls]" "справка до последней команды"; has "$O" "debian.conf" "справка: настройки"
  hasnt "$O" "BASE=" "справка без кода"
  ENVX=(FAKE_UID=2000); run "$O" "$D" status; RC=$?; ENVX=()
  [ "$RC" != 0 ] && grep -qF "нужен root" "$O" && ok "без root - отказ" || bad "без root (rc=$RC)" "$O"
}

t_efs() {
  local O=$T/out B=$T/dev/block/by-name X RC
  echo "-- backup_efs.sh"
  mkdir -p "$B"
  head -c 3145733 /dev/urandom >"$B/EFS"; head -c 1048576 /dev/urandom >"$B/modemst1"; head -c 102400 /dev/urandom >"$B/persist"
  echo sys >"$B/system"
  run "$O" "$T/backup_efs.sh"; eq "$?" 0 "копия: код 0" "$O"
  has "$O" "(3 разделов)" "3 раздела"; has "$O" "нет раздела fsg - пропускаю" "нет раздела - пропуск"
  X=$(ls "$T"/tmp/fold2-efs-*.tar.gz 2>/dev/null | head -n 1)
  if [ -f "$X" ]; then
    eq "$("$BUSYBOX" stat -c %a "$X")" 600 "архив 0600"
    eq "$(ls -d "$T"/tmp/fold2-efs-* | grep -vc 'tar.gz$')" 0 "временный каталог удалён"
    mkdir -p "$T/x"; tar -xzf "$X" -C "$T/x"; local E; E=$(ls -d "$T"/x/fold2-efs-*)
    eq "$(cd "$E" && ls | tr '\n' ' ')" "SHA256SUMS efs.img info.txt modemst1.img persist.img " "состав архива (имена в нижнем регистре)"
    (cd "$E" && sha256sum -c SHA256SUMS >/dev/null 2>&1) && ok "SHA256SUMS сходится" || bad "SHA256SUMS не сходится"
    cmp -s "$E/efs.img" "$B/EFS" && ok "efs.img = раздел (не кратен 1 МиБ)" || bad "efs.img отличается"
  else bad "архива нет" "$O"; fi
  rm -rf "$T/tmp"/* "$T/x"
  mkdir -p "$T/blksize"; echo 204800 >"$T/blksize/persist"
  run "$O" "$T/backup_efs.sh"; RC=$?
  [ "$RC" = 1 ] && grep -qF "ОШИБКА: persist - прочитано 102400 из 204800 байт" "$O" && ok "недочитанный раздел - ошибка, код 1" || bad "недочитанный раздел (rc=$RC)" "$O"
  has "$O" "БЫЛИ ОШИБКИ" "итог с ошибками"; ls "$T"/tmp/fold2-efs-*.tar.gz >/dev/null 2>&1 && ok "архив всё равно сделан" || bad "архива нет"
  rm -rf "$T/tmp"/* "$T/blksize" "$B"; mkdir -p "$B"
  run "$O" "$T/backup_efs.sh"; RC=$?
  [ "$RC" != 0 ] && grep -qF "ни одного раздела" "$O" && ok "нет разделов - ошибка" || bad "нет разделов (rc=$RC)" "$O"
  eq "$(ls "$T/tmp" | grep -c .)" 0 "после ошибки мусора нет"
  ENVX=(FAKE_UID=2000); run "$O" "$T/backup_efs.sh"; RC=$?; ENVX=()
  [ "$RC" != 0 ] && grep -qF "нужен root" "$O" && ok "без root - отказ" || bad "без root (rc=$RC)" "$O"
}

t_npu() {
  local O=$T/out F=$T/ssr.sh
  echo "-- npu.sh: уровень отладки (ssr_info)"
  { echo 'say() { echo "[fold2-npu] $*"; }'; sed -n '/^ssr_info()/,/^}/p' "$T/npu.sh"; echo 'ssr_info "$@"'; } >"$F"
  mkdir -p "$T/sys/bus/msm_subsys/devices/subsys0" "$T/sys/bus/msm_subsys/devices/subsys3"
  echo adsp >"$T/sys/bus/msm_subsys/devices/subsys0/name"
  echo cdsp >"$T/sys/bus/msm_subsys/devices/subsys3/name"; echo ONLINE >"$T/sys/bus/msm_subsys/devices/subsys3/state"
  echo 2 >"$T/sys/bus/msm_subsys/devices/subsys3/crash_count"
  run "$O" "$F"; has "$O" "перезапустится только он (уровень отладки LOW) (cdsp: ONLINE, падений с загрузки: 2)" "LOW + состояние cdsp"
  run "$O" "$F" warn; eq "$(cat "$O")" "" "LOW в режиме warn - тихо"
  : >"$T/props"; prop ro.boot.debug_level 0x494d; run "$O" "$F" warn; has "$O" "ВНИМАНИЕ: уровень отладки MID (0x494d)" "MID - предупреждение"
  : >"$T/props"; echo "androidboot.debug_level=0x4948 x=y" >"$T/proc/cmdline"; run "$O" "$F"; has "$O" "уровень отладки HIGH (0x4948)" "HIGH из /proc/cmdline"
  prop ro.boot.debug_level 0x4F4C; echo "androidboot.force_upload=0x1" >"$T/proc/cmdline"; run "$O" "$F"
  has "$O" "LOW (0x4F4C), force_upload=0x1" "LOW + force_upload - предупреждение"
  : >"$T/props"; prop ro.boot.debug_level 0x1234; echo "" >"$T/proc/cmdline"; run "$O" "$F"; has "$O" "неизвестен ('0x1234')" "неизвестный уровень"
  run "$O" "$F" warn; eq "$(cat "$O")" "" "неизвестный в режиме warn - тихо"
  : >"$T/props"; prop ro.boot.debug_level 0x4f4c

  echo "-- npu.sh: поиск модели (find_model)"
  local M=$T/models C=$T/llama
  mkdir -p "$M/sub" "$C"; : >"$M/sub/Qwen3-1.7B-Q4_0.gguf"; : >"$C/x-mmproj-Q8_0.gguf"; : >"$C/Other-Q8_0.gguf"
  { echo "NPU_MODEL=Qwen3-1.7B-Q4_0.gguf; NPU_MODEL_DIRS='$T/nonexistent $M $C'"; sed -n '/^find_model()/,/^}/p' "$T/npu.sh"
    echo 'find_model "$@"'; } >"$F"
  run "$O" "$F"; eq "$(cat "$O")" "$M/sub/Qwen3-1.7B-Q4_0.gguf" "модель по умолчанию в подкаталоге"
  run "$O" "$F" Other-Q8_0.gguf; eq "$(cat "$O")" "$C/Other-Q8_0.gguf" "по имени во втором каталоге"
  run "$O" "$F" "$C/Other-Q8_0.gguf"; eq "$(cat "$O")" "$C/Other-Q8_0.gguf" "абсолютный путь"
  run "$O" "$F" нет.gguf; eq "$?" 1 "нет модели - код 1"
  rm "$M/sub/Qwen3-1.7B-Q4_0.gguf"; run "$O" "$F"; eq "$(cat "$O")" "$C/Other-Q8_0.gguf" "любая Q4_0/Q8_0 без mmproj"

  echo "-- npu.sh test: итог и зависший f2q-bench (снимается по NPU_BENCH_TIMEOUT)"
  local N=$T/npub S0 S1; mkdir -p "$N/bin" "$N/dsp/eld"; : >"$N/dsp/libf2qdsp_skel.so"; : >"$N/dsp/eld/libf2qdsp_skel.so"
  printf '%s\n' '#!/bin/sh' 'case "$FAKE_BENCH" in' '  nodsp) echo "f2qdsp: DSP недоступен"; echo "ИТОГ: OK" ;;' \
    '  hang) echo "f2qdsp: DSP ГОТОВ"; while :; do :; done ;;' '  *) echo "f2qdsp: DSP ГОТОВ"; echo "ИТОГ: OK" ;;' 'esac' >"$N/bin/f2q-bench"
  chmod 755 "$N/bin/f2q-bench"; echo "NPU_BENCH_TIMEOUT=2" >"$N/npu.conf"
  ENVX=(FOLD2_NPU_DIR="$N"); run "$O" "$T/npu.sh" test; eq "$?" 0 "test: DSP работает - код 0" "$O"
  has "$O" "тест пройден: DSP работает" "test: тест пройден"; eq "$(cat "$N/dsp.variant" 2>/dev/null)" lld "test: запомнен рабочий код DSP"
  ENVX=(FOLD2_NPU_DIR="$N" NPU_SKEL=lld FAKE_BENCH=nodsp); rm -f "$N/dsp.variant"
  run "$O" "$T/npu.sh" test; eq "$?" 3 "test: DSP не открылся - код 3" "$O"; has "$O" "CPU-часть в порядке, но DSP не открылся" "test: DSP не открылся - сообщение"
  if [ -e "$BB/timeout" ]; then
    ENVX=(FOLD2_NPU_DIR="$N" FAKE_BENCH=hang); S0=$(date +%s); run "$O" "$T/npu.sh" test; RC=$?; S1=$(date +%s)
    eq "$RC" 1 "test: f2q-bench завис - код 1" "$O"; has "$O" "f2q-bench не дошёл до конца (завис дольше 2 с" "test: зависание - сообщение"
    [ $((S1 - S0)) -lt 30 ] && ok "test: зависший f2q-bench снят по таймауту за $((S1 - S0)) с" || bad "test: зависание длилось $((S1 - S0)) с" "$O"
  else
    [ "${REQUIRE_ALL:-0}" = 1 ] && bad "test: зависший f2q-bench - в busybox нет timeout" || echo "  (пропуск: в busybox нет timeout)"
  fi
  ENVX=()

  echo "-- npu.sh: справка"
  mkdir -p "$T/npu/bin"; ENVX=(FOLD2_NPU_DIR="$T/npu"); run "$O" "$T/npu.sh"; RC=$?; ENVX=()
  eq "$RC" 2 "без команды: код 2" "$O"; has "$O" "test [M K]" "справка: команды"
  has "$O" "eld (dsp/eld/" "справка до конца шапки (NPU_SKEL)"; hasnt "$O" "HERE=" "справка без кода"
}

SH_LIST="ash"; [ -x "$MKSH" ] && SH_LIST="mksh ash"
for SHN in $SH_LIST; do
  echo "=== оболочка: $SHN"
  setup "$SHN"; t_debian
  setup "$SHN"; t_efs
  setup "$SHN"; t_npu
done
finish "скрипты телефона"
