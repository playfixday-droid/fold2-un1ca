#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012,SC2010,SC1091,SC2016  # A && ok || bad: ok/bad всегда успешны; ls - в своих временных каталогах
# Тесты скриптов телефона без телефона: debian.sh (battery, status/температуры, bootlog, autostart, remove, справка),
# backup_efs.sh, npu.sh (уровень отладки, поиск модели, test: итог и зависший f2q-bench, справка), check_phone.sh
# (проверка прошивки: всё работает / всё сломано / без root; IMEI, серийники, MAC, SSID не попадают в отчёт).
# /sys, /proc, /dev/block, /data/adb, /data/local/tmp в копиях скриптов заменены временным каталогом;
# getprop/id/logcat/blockdev/sleep - заглушки из fake/, остальные утилиты - busybox (как toybox на Android).
# Каждый тест идёт в трёх окружениях: mksh под именем sh (это /system/bin/sh Android, им запускают через su) с
# утилитами busybox; busybox ash (им Magisk выполняет service.d - автозапуск); "android" - mksh и toybox 0.8.12
# с набором команд Android 16 (как /system/bin телефона: только они + awk и ip, остальных нет).
#   bash linux/test/test_phone.sh   (BUSYBOX=, MKSH=, TOYBOX= - пути, если их нет в PATH; REQUIRE_ALL=1 - без пропусков)
set -uo pipefail
TD=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$TD/../.." && pwd)
. "$TD/lib.sh"
BUSYBOX=${BUSYBOX:-$(command -v busybox || true)}
MKSH=${MKSH:-$(command -v mksh || true)}
TOYBOX=${TOYBOX:-$(command -v toybox || true)}
[ -x "$BUSYBOX" ] || { echo "нужен busybox (BUSYBOX=путь)"; exit 2; }
if [ ! -x "$MKSH" ]; then
  [ "${REQUIRE_ALL:-0}" = 1 ] && { echo "нужен mksh (MKSH=путь)"; exit 2; }
  echo "ВНИМАНИЕ: mksh не найден - только busybox ash"
fi
if [ ! -x "$TOYBOX" ]; then
  [ "${REQUIRE_ALL:-0}" = 1 ] && { echo "нужен toybox (TOYBOX=путь): сборку как в Android 16 делает CI (tools.yml)"; exit 2; }
  echo "ВНИМАНИЕ: toybox не найден - без окружения android (toybox Android 16)"
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

# Команды toybox в /system/bin Android 16 (toybox_symlinks из external/toybox/Android.bp, ветка android16-release)
ANDROID_TOYS="[ acpi base64 basename blkdiscard blockdev brctl cal cat chattr chcon chgrp chmod chown chroot chrt cksum
clear comm cmp cp cpio cut date dd devmem df diff dirname dmesg dos2unix du echo egrep env expand expr fallocate false
fgrep file find flock fmt free fsync getconf getenforce getfattr getopt gpiodetect gpiofind gpioget gpioinfo gpioset grep
groups gunzip gzip head hostname hwclock i2cdetect i2cdump i2cget i2cset i2ctransfer iconv id ifconfig inotifyd insmod
install ionice iorenice kill killall load_policy ln log logger logname losetup ls lsattr lsmod lsof lspci lsusb md5sum
memeater mkdir mkfifo mknod mkswap mktemp microcom modinfo more mount mountpoint mv nc netcat netstat nice nl nohup nproc
nsenter od paste patch pgrep pidof pkill pmap printenv printf ps pwd readelf readlink realpath renice restorecon rm rmdir
rmmod rtcwake runcon sed sendevent seq setenforce setfattr setsid sha1sum sha224sum sha256sum sha384sum sha512sum sleep
sort split stat strings stty swapoff swapon sync sysctl tac tail tar taskset tee test time timeout top touch tr true
truncate tty uclampset ulimit umount uname uniq unix2dos unlink unshare uptime usleep uudecode uuencode uuidgen vi vmstat
watch wc which whoami xargs xxd yes zcat"
TB=$WORK/toybox
if [ -x "$TOYBOX" ]; then
  mkdir -p "$TB"; ln -s "$TOYBOX" "$TB/toybox"
  TBL=" $("$TB/toybox" | tr -s ' \n' '  ') "
  for A in $ANDROID_TOYS; do
    case "$TBL" in *" $A "*) ln -s "$TB/toybox" "$TB/$A" ;; esac # SELinux-команды (chcon...) toybox без libselinux не собирает
  done
  # не toybox, но есть в /system/bin: awk (one-true-awk), ip (iproute2) - их заменяет busybox
  for A in awk ip; do ln -s "$BUSYBOX" "$TB/$A"; done
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
  env -i HOME="$T" PATH="$T/sb:$FK:$UT" FAKE_ROOT="$T" FOLD2_BASE="$T/base" LANG=C.UTF-8 TZ=UTC \
    ${ENVX[@]+"${ENVX[@]}"} "$T/sb/sh" "$@" >"$O" 2>&1
}
zone() { mkdir -p "$T/sys/class/thermal/thermal_zone$1"; echo "$2" >"$T/sys/class/thermal/thermal_zone$1/type"; [ -n "${3:-}" ] && echo "$3" >"$T/sys/class/thermal/thermal_zone$1/temp"; }
prop() { echo "$1=$2" >>"$T/props"; }

setup() { # setup <оболочка>: новый каталог-"телефон"
  T=$WORK/$1; rm -rf "$T"; mkdir -p "$T/sb" "$T/base" "$T/tmp" "$T/data/adb"
  UT=$BB # утилиты: busybox, в окружении android - toybox
  case "$1" in mksh) ln -s "$MKSH" "$T/sb/sh" ;; ash) ln -s "$BUSYBOX" "$T/sb/sh" ;; android) ln -s "$MKSH" "$T/sb/sh"; UT=$TB ;; esac
  rw "$REPO/linux/phone/debian.sh" "$T/debian.sh"; rw "$REPO/linux/phone/backup_efs.sh" "$T/backup_efs.sh"
  rw "$REPO/npu/phone/npu.sh" "$T/npu.sh"
  rw "$REPO/linux/phone/check_phone.sh" "$T/check_phone.sh"; sed -i "s#/dev/adsprpc-smd#$T/dev/adsprpc-smd#g; s#/dev/fastrpc-cdsp#$T/dev/fastrpc-cdsp#g" "$T/check_phone.sh"
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
  local MD=$T/data/adb/modules/fold2
  has "$MD/module.prop" "id=fold2" "autostart on ставит и кнопку в Magisk (module.prop)"
  [ -x "$MD/action.sh" ] && [ -f "$MD/skip_mount" ] && ok "кнопка: action.sh исполняемый, skip_mount" || bad "кнопка в Magisk не та" "$O"
  has "$MD/action.sh" "export FOLD2_BASE='$T/base'" "кнопка: BASE"; has "$MD/action.sh" 'debian.sh" x11' "кнопка запускает рабочий стол"
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
  # AUTO_X11=1: рабочий стол при загрузке, если стоит Termux:X11
  printf '%s\n' '#!/bin/sh' '[ "$1 $2" = "path com.termux.x11" ] && [ "${FAKE_NOX11:-0}" != 1 ] && echo package:/data/app/x11/base.apk' >"$T/sb/pm"
  chmod 755 "$T/sb/pm"; printf 'AUTO_SSH=1\nAUTO_BOOTLOG=0\nAUTO_X11=1\n' >"$T/base/debian.conf"; : >"$T/calls"
  run "$O" "$S"; eq "$(tr '\n' ',' <"$T/calls")" "start,ssh,x11," "AUTO_X11=1: start, ssh, x11"
  ENVX=(FAKE_NOX11=1); : >"$T/calls"; run "$O" "$S"; ENVX=()
  eq "$(tr '\n' ',' <"$T/calls")" "start,ssh," "AUTO_X11=1 без Termux:X11 - рабочий стол не запускается"
  run "$O" "$D" autostart off; [ ! -e "$S" ] && ok "autostart off" || bad "autostart off не удалил" "$O"
  [ -d "$MD" ] && ok "autostart off оставляет кнопку в Magisk" || bad "autostart off убрал кнопку"
  rm -f "$T/base/debian.conf" "$T/base/debian.sh"
  run "$O" "$D" module off; [ ! -e "$MD" ] && ok "module off убрал кнопку" || bad "module off не убрал" "$O"
  run "$O" "$D" module on; eq "$?" 0 "module on" "$O"; has "$O" "«Действие»" "module on: где кнопка"; run "$O" "$D" module off

  echo "-- debian.sh: x11 (рабочий стол уже запущен - не перезапускать)"
  local XR=$T/base/debian SP
  mkdir -p "$XR/bin" "$XR/tmp/.X11-unix"; printf '#!/bin/sh\n' >"$XR/bin/sh"; chmod 755 "$XR/bin/sh"
  python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$XR/tmp/.X11-unix/X0"
  printf '%s\n' '#!/bin/sh' 'echo "am $*" >>"$FAKE_ROOT/am.log"' >"$T/sb/am"; chmod 755 "$T/sb/am"
  sleep 300 & SP=$!; mkdir -p "$T/proc/$SP"; ln -s "$XR" "$T/proc/$SP/root"; echo xfce4-session >"$T/proc/$SP/comm"
  run "$O" "$D" x11; eq "$?" 0 "x11 при запущенном: код 0" "$O"; has "$O" "рабочий стол уже запущен" "x11: уже запущен"
  has "$T/am.log" "com.termux.x11/com.termux.x11.MainActivity" "x11: открывает Termux:X11"; kill -0 "$SP" 2>/dev/null && ok "x11: сеанс XFCE не убит" || bad "x11 убил сеанс"
  run "$O" "$D" status; has "$O" "рабочий стол (XFCE): работает" "status: рабочий стол работает"
  run "$O" "$D" x11 stop; eq "$?" 0 "x11 stop: код 0" "$O"; sleep 0.2
  kill -0 "$SP" 2>/dev/null && { bad "x11 stop не остановил XFCE"; kill "$SP"; } || ok "x11 stop: сеанс XFCE остановлен"
  wait "$SP" 2>/dev/null; rm -rf "$T/proc/$SP"
  run "$O" "$D" status; has "$O" "рабочий стол (XFCE): нет" "status: рабочего стола нет"
  run "$O" "$D" x11 nonsense; eq "$?" 1 "x11 с неизвестным аргументом: код 1" "$O"
  rm -rf "$XR" "$T/sb/am" "$T/sb/pm" "$T/am.log"

  echo "-- debian.sh: remove (не удаляет, пока внутри что-то смонтировано)"
  local RR=$T/base/debian
  run "$O" "$D" remove yes; eq "$?" 0 "remove без Debian: код 0" "$O"; has "$O" "Debian не установлен" "remove: нечего удалять"
  mkdir -p "$RR/bin" "$RR/root" "$RR/sdcard/DCIM"; printf '#!/bin/sh\n' >"$RR/bin/sh"; chmod 755 "$RR/bin/sh"
  echo фото >"$RR/sdcard/DCIM/photo.jpg"; echo "BATT_LIMIT=80" >"$T/base/debian.conf"
  run "$O" "$D" remove; eq "$?" 2 "remove без yes: код 2" "$O"; has "$O" "debian.sh remove yes" "remove без yes: подсказка"
  [ -x "$RR/bin/sh" ] && ok "remove без yes ничего не удалил" || bad "remove без yes удалил" "$O"
  # /sdcard телефона смонтирован внутрь и не размонтировался
  echo "/dev/block/dm-5 $RR/sdcard f2fs rw,lazytime 0 0" >"$T/proc/mounts"
  run "$O" "$D" autostart on >/dev/null; run "$O" "$D" remove yes; RC=$?
  [ "$RC" != 0 ] && grep -qF "не удаляю: внутри" "$O" && ok "remove при смонтированном /sdcard - отказ" || bad "remove при монтировании (rc=$RC)" "$O"
  eq "$(cat "$RR/sdcard/DCIM/photo.jpg" 2>/dev/null)" фото "файлы /sdcard целы"; [ -x "$RR/bin/sh" ] && ok "Debian не тронут" || bad "Debian частично удалён"
  [ ! -e "$T/data/adb/service.d/fold2-debian.sh" ] && ok "remove выключил автозапуск (перезагрузка всё размонтирует)" || bad "автозапуск остался"
  [ ! -e "$T/data/adb/modules/fold2" ] && ok "remove убрал кнопку в Magisk" || bad "кнопка в Magisk осталась"
  has "$O" "остановлено НЕ до конца" "stop сообщает, что размонтировал не всё"
  : >"$T/proc/mounts"; rm -rf "$RR/sdcard"
  run "$O" "$D" remove yes; eq "$?" 0 "remove yes: код 0" "$O"
  [ ! -e "$RR" ] && ok "remove yes: Debian удалён" || bad "remove yes: $RR остался" "$O"
  eq "$(cat "$T/base/debian.conf" 2>/dev/null)" "BATT_LIMIT=80" "remove: debian.conf остался"
  mkdir -p "$RR"; echo важное >"$RR/notes.txt"; run "$O" "$D" remove yes; RC=$?
  [ "$RC" != 0 ] && [ -f "$RR/notes.txt" ] && ok "не похожее на Debian не удаляется" || bad "remove удалил не-Debian (rc=$RC)" "$O"
  rm -rf "$RR" "$T/base/debian.conf"

  echo "-- debian.sh: справка и root"
  run "$O" "$D" nonsense; eq "$?" 1 "неизвестная команда: код 1"
  eq "$(head -n 1 "$O")" "# fold2: Debian 13 (trixie) в chroot на Galaxy Z Fold2 (UN1CA, Magisk root)." "справка с первой строки"
  has "$O" "bootlog [ls]" "справка: bootlog"; has "$O" "module on|off" "справка: кнопка"; has "$O" "x11 [stop|restart]" "справка: x11"; has "$O" "remove [yes]" "справка до последней команды (remove)"; has "$O" "debian.conf" "справка: настройки"
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
    '  hang) echo "f2qdsp: DSP ГОТОВ"; while :; do :; done ;;' \
    '  hangterm) trap "" TERM; echo "f2qdsp: DSP ГОТОВ"; while :; do :; done ;;' '  *) echo "f2qdsp: DSP ГОТОВ"; echo "ИТОГ: OK" ;;' 'esac' >"$N/bin/f2q-bench"
  chmod 755 "$N/bin/f2q-bench"; echo "NPU_BENCH_TIMEOUT=2" >"$N/npu.conf"
  ENVX=(FOLD2_NPU_DIR="$N"); run "$O" "$T/npu.sh" test; eq "$?" 0 "test: DSP работает - код 0" "$O"
  has "$O" "тест пройден: DSP работает" "test: тест пройден"; eq "$(cat "$N/dsp.variant" 2>/dev/null)" lld "test: запомнен рабочий код DSP"
  ENVX=(FOLD2_NPU_DIR="$N" NPU_SKEL=lld FAKE_BENCH=nodsp); rm -f "$N/dsp.variant"
  run "$O" "$T/npu.sh" test; eq "$?" 3 "test: DSP не открылся - код 3" "$O"; has "$O" "CPU-часть в порядке, но DSP не открылся" "test: DSP не открылся - сообщение"
  if [ -e "$UT/timeout" ]; then
    ENVX=(FOLD2_NPU_DIR="$N" FAKE_BENCH=hang); S0=$(date +%s); run "$O" "$T/npu.sh" test; RC=$?; S1=$(date +%s)
    eq "$RC" 1 "test: f2q-bench завис - код 1" "$O"; has "$O" "f2q-bench не дошёл до конца (завис дольше 2 с" "test: зависание - сообщение"
    [ $((S1 - S0)) -lt 30 ] && ok "test: зависший f2q-bench снят по таймауту за $((S1 - S0)) с" || bad "test: зависание длилось $((S1 - S0)) с" "$O"
    # завис так, что SIGTERM не помогает - timeout -k добивает SIGKILL через 10 с
    ENVX=(FOLD2_NPU_DIR="$N" FAKE_BENCH=hangterm); S0=$(date +%s); run "$O" "$T/npu.sh" test; RC=$?; S1=$(date +%s)
    eq "$RC" 1 "test: f2q-bench не снимается SIGTERM - код 1" "$O"
    [ $((S1 - S0)) -lt 40 ] && ok "test: f2q-bench без реакции на SIGTERM снят SIGKILL за $((S1 - S0)) с" || bad "test: SIGTERM-зависание длилось $((S1 - S0)) с" "$O"
  else
    [ "${REQUIRE_ALL:-0}" = 1 ] && bad "test: зависший f2q-bench - в busybox нет timeout" || echo "  (пропуск: в busybox нет timeout)"
  fi
  ENVX=()

  echo "-- npu.sh: справка"
  mkdir -p "$T/npu/bin"; ENVX=(FOLD2_NPU_DIR="$T/npu"); run "$O" "$T/npu.sh"; RC=$?; ENVX=()
  eq "$RC" 2 "без команды: код 2" "$O"; has "$O" "test [M K]" "справка: команды"
  has "$O" "eld (dsp/eld/" "справка до конца шапки (NPU_SKEL)"; hasnt "$O" "HERE=" "справка без кода"
}

t_check() {
  local O=$T/out C=$T/check_phone.sh S=$T/sb K=$REPO/target/f2q/kernel-src/docker.config RC
  # заглушки только для этого теста (в $T/sb - раньше fake/ и утилит в PATH)
  cat >"$S/dumpsys" <<'F'
#!/bin/sh
case "$1" in
  bluetooth_manager) printf 'Bluetooth Status\n  enabled: %s\n  state: ON\n  address: 11:22:33:44:55:66\n  name: Max Fold\n' "${FAKE_BT:-true}" ;;
  media.camera) echo "Number of camera devices: ${FAKE_NCAM-5}" ;;
  display) echo 'DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4630946520432129409", 816 x 2260, modeId 1, supportedModes [{id=1, fps=60.0}, {id=2, fps=120.0}]}' ;;
  sensorservice) echo "Total 42 h/w sensors, 42 running" ;;
  battery) printf '  AC powered: true\n  level: 77\n  temperature: %s\n' "${FAKE_BTEMP:-315}" ;;
  device_state) echo "mCommittedState=CLOSED" ;;
esac
F
  cat >"$S/cmd" <<'F'
#!/bin/sh
[ "$1 $2" = "wifi status" ] || exit 1
echo "Wifi is ${FAKE_WIFI:-enabled}"; echo 'Wifi is connected to "HomeNet-5G"'
echo 'WifiInfo: SSID: "HomeNet-5G", BSSID: 12:34:56:78:9a:bc, MAC: 02:00:00:00:00:00'
F
  cat >"$S/wm" <<'F'
#!/bin/sh
case "$1" in size) echo "Physical size: ${FAKE_WM:-816x2260}" ;; density) echo "Physical density: 408" ;; esac
F
  cat >"$S/ip" <<'F'
#!/bin/sh
[ "$*" = "link show wlan0" ] && [ "${FAKE_NOWLAN:-0}" != 1 ] || exit 1
echo "3: wlan0: <UP> link/ether aa:bb:cc:dd:ee:01"
F
  cat >"$S/df" <<'F'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"; echo "/dev/block/dm-5 230000000 20000000 ${FAKE_FREE_KB:-200000000} 10% /data"
F
  printf '%s\n' '#!/bin/sh' 'exit "${FAKE_PING_RC:-0}"' >"$S/ping"
  printf '%s\n' '#!/bin/sh' 'echo Enforcing' >"$S/getenforce"
  printf '%s\n' '#!/bin/sh' '[ "$1" = -c ] && echo "31.1:MAGISK:R (31100)"' >"$S/magisk"
  printf '%s\n' '#!/bin/sh' '[ "${FAKE_NOSU:-0}" = 1 ] && exit 127; [ "$1" = -v ] && echo "31.1:MAGISK:R"' >"$S/su"
  printf '%s\n' '#!/bin/sh' '[ "${FAKE_NOAPP:-0}" = 1 ] || [ "$*" != "list packages com.topjohnwu.magisk" ] || echo package:com.topjohnwu.magisk' >"$S/pm"
  mkdir -p "$T/data/adb/magisk"; printf '%s\n' '#!/bin/sh' >"$T/data/adb/magisk/busybox"; chmod 755 "$T/data/adb/magisk/busybox"
  printf '%s\n' '#!/bin/sh' 'cat "$FAKE_ROOT/dmesg" 2>/dev/null' >"$S/dmesg"
  chmod 755 "$S"/*
  echo "12345.67 2345.00" >"$T/proc/uptime"; printf 'MemTotal: 11500000 kB\nMemAvailable: 6000000 kB\n' >"$T/proc/meminfo"
  mkdir -p "$T/sys/bus/msm_subsys/devices/subsys0" "$T/sys/bus/msm_subsys/devices/subsys1" "$T/dev"
  echo cdsp >"$T/sys/bus/msm_subsys/devices/subsys0/name"; echo ONLINE >"$T/sys/bus/msm_subsys/devices/subsys0/state"
  echo modem >"$T/sys/bus/msm_subsys/devices/subsys1/name"; echo ONLINE >"$T/sys/bus/msm_subsys/devices/subsys1/state"
  : >"$T/dev/adsprpc-smd"
  grep '^CONFIG_' "$K" | gzip >"$T/proc/config.gz"
  prop ro.product.model SM-F916B; prop ro.build.version.release 16; prop ro.build.display.id UN1CA-f2q-7; prop ro.boot.bootloader F916BXXS7KXH1
  prop ro.serialno R5CN12ABCDE; prop ril.serialnumber R5CN12ABCDE; prop ro.boot.wifimacaddr aa:bb:cc:dd:ee:01; prop ril.IMEI 356789012345678
  prop ro.boot.em.did 0x1a2b3c4d5e6f; prop gsm.version.baseband F916BXXS7KXH1; prop gsm.sim.state LOADED,ABSENT; prop gsm.network.type LTE
  prop gsm.operator.alpha TestNet; prop persist.radio.multisim.config dsds; prop init.svc.vendor.nfc_hal_service running
  prop init.svc.vendor.camera-provider running; prop sys.boot.reason reboot
  # в логах - то, что не должно попасть в отчёт: ICCID, IMSI, номер телефона, почта, серийник, IMEI
  printf '%s\n' "11-01 10:00:00.000 E RILJ: error SIM iccid=8970101234567890123 imsi=250011234567890 to +7 912 345-67-89" \
    "11-01 10:00:01.000 E RILJ: fail account user.name@example.com serial R5CN12ABCDE imei 356789012345678" >"$T/logcat-radio"

  echo "-- check_phone.sh: всё работает"
  run "$O" "$C"; RC=$?
  eq "$RC" 0 "всё работает: код 0" "$O"; has "$O" "ИТОГ: OK" "строка ИТОГ"; has "$O" "НЕТ 0" "ни одного НЕТ"
  for L in "прошивка: SM-F916B, Android 16, UN1CA-f2q-7; загрузчик F916BXXS7KXH1" "загрузка завершена, телефон работает 205 мин" \
      "уровень отладки LOW" "root: есть (Magisk 31.1" "SELinux: Enforcing" "службы init: ни одна" "модем: F916BXXS7KXH1" \
      "SIM: LOADED,ABSENT; сеть: TestNet LTE" "Wi-Fi: включён, подключён" "Bluetooth: включён" "NFC: служба работает" \
      "камеры: 5" "экран: Physical size: 816x2260, Physical density: 408" "датчики: 42" "батарея: 77%, 31°C" \
      "cDSP (NPU): $T/dev/adsprpc-smd, cdsp ONLINE" "ядро $(uname -r): все опции для Docker на месте" "место в /data: свободно 190 ГБ" \
      "интернет: github.com отвечает" "падения с загрузки: нет"; do
    has "$O" "OK        $L" "OK: ${L%%:*}"
  done
  has "$O" "fps=120.0" "подробности: частоты экрана"; has "$O" "persist.radio.multisim.config=dsds" "подробности: multisim"
  for L in R5CN12ABCDE 356789012345678 aa:bb:cc:dd:ee:01 11:22:33:44:55:66 12:34:56:78:9a:bc HomeNet 4630946520432129409 \
      8970101234567890123 250011234567890 "912 345" user.name@example.com 0x1a2b3c4d5e6f ro.serialno ril.IMEI; do
    hasnt "$O" "$L" "в отчёте нет $L"
  done
  has "$O" "iccid=***" "ICCID заменён на ***"

  echo "-- check_phone.sh: всё сломано"
  : >"$T/props"; prop sys.boot_completed 1; prop ro.boot.debug_level 0x494d; prop ro.product.model SM-G780F
  prop gsm.sim.state ABSENT,ABSENT; prop init.svc.vendor.camera-provider restarting; prop init.svc.vendor.nfc_hal_service restarting
  grep '^CONFIG_' "$K" | grep -v '^CONFIG_VETH=' | { cat; echo CONFIG_SECURITY_DEFEX=y; } | gzip >"$T/proc/config.gz"
  rm -f "$T/dev/adsprpc-smd"
  printf '%s\n' "--------- beginning of crash" "FATAL EXCEPTION: main" "Process: com.android.phone, PID: 1234" \
    "FATAL EXCEPTION: main" "Process: com.android.phone, PID: 1301" \
    "pid: 900, tid: 900, name: provider  >>> /vendor/bin/hw/android.hardware.camera.provider@2.4-service_64 <<<" >"$T/logcat-crash"
  printf '%s\n' "11-01 10:00:00.000 W cameraserver: type=1400 audit(0.0:1): avc:  denied  { read } for name=\"x\" scontext=u:r:hal_camera_default:s0 tcontext=u:object_r:vendor_file:s0 tclass=file permissive=0" >"$T/logcat-all"
  : >"$T/dmesg"; for I in 1 2 3; do echo "[  1$I.0] init: Service 'vendor.ril-daemon' (pid 7$I) exited with status 1" >>"$T/dmesg"; done
  echo "[  20.0] init: Service 'oneshot' (pid 80) exited with status 0" >>"$T/dmesg"
  ENVX=(FAKE_NCAM=0 FAKE_NOWLAN=1 FAKE_FREE_KB=2097152 FAKE_PING_RC=1 FAKE_BTEMP=471 FAKE_WM=1768x2208); run "$O" "$C"; RC=$?; ENVX=()
  eq "$RC" 0 "всё сломано: код 0 (это отчёт, а не ошибка)" "$O"
  for L in "НЕТ       модем: нет версии baseband" "ВНИМАНИЕ  SIM: ABSENT,ABSENT" "НЕТ       камеры: 0" \
      "НЕТ       Wi-Fi: нет интерфейса wlan0" "НЕТ       службы падают и перезапускаются: vendor.camera-provider vendor.nfc_hal_service" \
      "НЕТ       NFC: служба падает" "ВНИМАНИЕ  прошивка: модель 'SM-G780F'" "ВНИМАНИЕ  уровень отладки 0x494d" \
      "для Docker нет опций: VETH" "включены защиты Samsung (SECURITY_DEFEX" "ВНИМАНИЕ  cDSP (NPU): нет" \
      "свободно 2 ГБ" "интернет: нет ответа" "падения с загрузки: 3 (com.android.phone x2;" "батарея: 77%, 47°C - горячая" \
      "службы падали с загрузки (3 раза и больше): vendor.ril-daemon(3)" "похоже на внутренний экран" \
      "отказы SELinux (avc: denied): 1" "hal_camera_default -> vendor_file:file { read }"; do
    has "$O" "$L" "сломано: ${L:10:40}"
  done
  hasnt "$O" "oneshot" "служба, вышедшая с кодом 0, - не падение"

  echo "-- check_phone.sh: без root"
  ENVX=(FAKE_UID=2000); run "$O" "$C"; RC=$?; ENVX=()
  eq "$RC" 0 "без root: код 0" "$O"; has "$O" "root: нет" "без root: в шапке"
  has "$O" "ВНИМАНИЕ  проверка без root (Magisk 31.1 есть)" "без root: Magisk есть - разрешить Shell"
  hasnt "$O" "падения служб init с загрузки" "без root: dmesg не читается"
  ENVX=(FAKE_UID=2000 FAKE_NOAPP=1); run "$O" "$C"; ENVX=()
  has "$O" "ВНИМАНИЕ  Magisk 31.1 в boot есть, приложения нет: поставь Magisk-v31.1.apk" "без приложения Magisk - подсказка"
  # su нет совсем (как на Android без Magisk; в busybox su свой - тогда это «su не от Magisk»)
  mv "$S/su" "$T/su.off"; ENVX=(FAKE_UID=2000); run "$O" "$C"; ENVX=(); mv "$T/su.off" "$S/su"
  if [ -e "$UT/su" ]; then has "$O" "ВНИМАНИЕ  проверка без root; su не от Magisk" "su не от Magisk - подсказка"
  else has "$O" "ВНИМАНИЕ  root нет: в boot нет Magisk" "boot без Magisk - подсказка"; fi
  ENVX=(FAKE_UID=2000 FAKE_NOSU=1); run "$O" "$C"; ENVX=()
  has "$O" "ВНИМАНИЕ  проверка без root; su не от Magisk" "su без Magisk (su -v не отвечает) - подсказка"
  echo "-- check_phone.sh: Magisk без «доп. настройки»"
  rm -rf "$T/data/adb/magisk"; run "$O" "$C"
  has "$O" "НЕТ       Magisk 31.1 не настроен до конца" "нет /data/adb/magisk - НЕТ и что делать"; hasnt "$O" "OK        root:" "без доп. настройки root не OK"
  # опции Docker в check_phone.sh - те же, что в docker.config ядра
  local MISSK="" O2
  while read -r O2; do grep -qw "$O2" "$REPO/linux/phone/check_phone.sh" || MISSK="$MISSK $O2"; done \
    < <(sed -n 's/^CONFIG_\([A-Z0-9_]*\)=y$/\1/p' "$K")
  eq "$MISSK" "" "все опции docker.config ядра проверяются (KOPTS в check_phone.sh)"
}

SH_LIST="ash"; [ -x "$MKSH" ] && SH_LIST="mksh ash"; [ -x "$MKSH" ] && [ -x "$TOYBOX" ] && SH_LIST="$SH_LIST android"
for SHN in $SH_LIST; do
  echo "=== оболочка: $SHN"
  setup "$SHN"; t_debian
  setup "$SHN"; t_efs
  setup "$SHN"; t_npu
  setup "$SHN"; t_check
done
finish "скрипты телефона"
