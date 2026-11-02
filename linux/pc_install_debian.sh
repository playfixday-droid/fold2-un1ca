#!/usr/bin/env bash
# fold2: установка Debian 13 + XFCE/Docker/Vulkan/llama.cpp и пакета NPU на Fold2 с ПК (Linux/macOS/WSL/Git Bash).
# Нужно: прошивка f2q с root (Magisk), USB-отладка, интернет на ПК и телефоне (adb нет - скачает platform-tools Google сам).
#   bash pc_install_debian.sh [пользователь]   - всё сразу, по порядку:
#     1) копия EFS (IMEI, ключи; разделы только читаются) на ПК в ~/fold2-backup - один раз;
#     2) уровень отладки: если не LOW - предложит перезагрузить телефон в LOW (иначе падение ядра/DSP = зависание);
#     3) Debian (повторный запуск не переустанавливает, а обновляет скрипты и автозапуск; если прошлая установка
#        оборвалась - продолжает её), Termux:X11;
#     4) NPU, модель, проверка NPU; 5) проверка телефона (phone/check_phone.sh: связь, Wi-Fi, камеры, ядро...);
#     6) файл-отчёт fold2-report-<время>.txt рядом со скриптом (без IMEI).
#   SKIP_BACKUP=1 / SKIP_DEBIAN=1 / SKIP_NPU=1 / SKIP_MODEL=1 / SKIP_CHECK=1 - пропустить часть
#   Только проверить телефон после прошивки (root не нужен): bash pc_check_phone.sh
#   BATT_LIMIT=80 (по умолчанию) - предел заряда для телефона, который всегда на зарядке; BATT_LIMIT= - не ставить;
#   предел, уже заданный в debian.conf на телефоне, без явного BATT_LIMIT=N не меняется
# При первом "su" на внешнем экране телефона появится запрос Magisk - разреши Shell.
set -euo pipefail
# Git Bash (Windows) переделывает аргументы вида /data/... в C:/Program Files/Git/data/... - для путей телефона не надо
export MSYS2_ARG_CONV_EXCL="/data/;/sdcard/"
U=${1:-fold2}
# имя попадает в команды на телефоне - как NAME_REGEX Debian по умолчанию
[[ "$U" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "ОШИБКА: имя пользователя '$U': латиница в нижнем регистре, цифры, _ и -, с буквы или _, до 32 символов" >&2; exit 1; }
REPO=playfixday-droid/fold2-un1ca
LXC=https://images.linuxcontainers.org/images/debian/trixie/arm64/default
NPU_MODEL_URL=${NPU_MODEL_URL:-https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_0.gguf}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$HERE/fold2-dl}
T=/data/local/tmp/fold2
BK=${BACKUP_DIR:-$HOME/fold2-backup}
REPORT=$HERE/fold2-report-$(date +%Y%m%d-%H%M%S).txt
BL=${BATT_LIMIT-80}
BL_ENV=${BATT_LIMIT+set} # BATT_LIMIT задан явно - он важнее предела в debian.conf
case "$BL" in ""|[5-9][0-9]) ;; *) echo "ОШИБКА: BATT_LIMIT=$BL - нужно число 50-99 или пусто (не ставить предел)" >&2; exit 1 ;; esac
mkdir -p "$W"
say() { echo "== $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
asu() { adb shell "su -mm -c '$*'"; }
yes_on_phone() { [ "$(asu "$* && echo yes" 2>/dev/null | tr -d '\r')" = yes ]; } # yes_on_phone <условие>
# || true: телефон может пропасть из adb (перезагрузка) - X=$(one ...) не должен обрывать скрипт под set -e
one() { adb shell "$*" 2>/dev/null | tr -d '\r' || true; } # одна строка вывода без \r (старые adb)
ask() { # ask "вопрос" - Enter = да; без терминала (запуск из скрипта) - нет
  local A
  [ -t 0 ] || return 1
  read -r -p "$1 [Д/н] " A || return 1
  case "$A" in ""|Д*|д*|Y*|y*) return 0 ;; *) return 1 ;; esac # не [Дд]: в локали C это байты, "н" совпало бы
}
bootid() { asu "cat /proc/sys/kernel/random/boot_id" 2>/dev/null | tr -d '\r' || true; } # у каждой загрузки свой
wait_boot() { # wait_boot <boot_id до перезагрузки>: ждём adb и конца новой загрузки, до 5 минут
  local I=0 B H=""
  while :; do
    # sys.boot_completed=1 есть и у старой загрузки, пока телефон выключается, - нужен ещё другой boot_id
    if [ "$(one getprop sys.boot_completed)" = 1 ]; then
      [ -z "$1" ] && return 0
      B=$(bootid); [ -n "$B" ] && [ "$B" != "$1" ] && return 0
    fi
    if [ -z "$H" ] && adb devices 2>/dev/null | grep -q unauthorized; then
      H=1; say "разблокируй телефон и разреши на нём отладку по USB для этого ПК (с галочкой «Всегда»)"
    fi
    I=$((I + 1)); [ $I -gt 60 ] && die "телефон не загрузился за 5 минут (если на экране синий Upload mode - зажми питание и громкость вниз на 10 с)"
    sleep 5
  done
}
reboot_low() { # перезагрузка с уровнем отладки LOW; 1 - телефон так и не начал перезагружаться
  local B0 I=0
  B0=$(bootid)
  asu "reboot debug0x4f4c" >/dev/null 2>&1 || true
  # выключение занимает секунды: пока телефон в adb и boot_id прежний - это ещё старая загрузка
  while [ "$(adb get-state 2>/dev/null)" = device ] && [ "$(bootid)" = "$B0" ]; do
    I=$((I + 1)); [ $I -gt 12 ] && return 1
    sleep 5
  done
  wait_boot "$B0"
}
is_root() { case "$(asu id 2>/dev/null)" in *uid=0*) return 0 ;; esac; return 1; } # без "| grep -q": с pipefail grep мог оборвать adb
wait_unlock() { # /sdcard зашифрован, пока телефон не разблокируют после включения
  local I=0
  until adb shell "test -d /sdcard/Android" 2>/dev/null; do
    [ $I = 0 ] && say "разблокируй телефон (PIN/узор) - жду до 10 минут"
    I=$((I + 1)); [ $I -gt 120 ] && die "телефон так и не разблокировали"
    sleep 5
  done
}
dbg_level() {
  local L; L=$(one getprop ro.boot.debug_level)
  [ -n "$L" ] || L=$(asu "cat /proc/cmdline" 2>/dev/null | tr ' ' '\n' | sed -n 's/^androidboot.debug_level=//p' | tr -d '\r' | head -n 1)
  case "$L" in 0x4f4c|0x4F4C) echo LOW ;; 0x494d|0x494D) echo MID ;; 0x4948) echo HIGH ;; *) echo "?" ;; esac
}

case "$(uname -s)" in Linux) OS=linux ;; Darwin) OS=darwin ;; MINGW*|MSYS*|CYGWIN*) OS=windows ;; *) OS="" ;; esac
get_adb() { # adb нет в PATH - официальные platform-tools Google в $W/platform-tools (один раз)
  local Z=$W/platform-tools-$OS.zip
  [ -n "$OS" ] || return 1
  if [ ! -f "$W/platform-tools/adb" ] && [ ! -f "$W/platform-tools/adb.exe" ]; then
    say "нет adb - скачиваю platform-tools ($OS) с dl.google.com"
    curl -fL --retry 3 -o "$Z.part" "https://dl.google.com/android/repository/platform-tools-latest-$OS.zip" || return 1
    mv "$Z.part" "$Z"; rm -rf "$W/platform-tools"
    if command -v unzip >/dev/null; then unzip -q "$Z" -d "$W"
    elif command -v python3 >/dev/null; then python3 -m zipfile -e "$Z" "$W"
    elif command -v powershell.exe >/dev/null; then
      powershell.exe -NoProfile -Command "Expand-Archive -Force '$(cygpath -w "$Z")' '$(cygpath -w "$W")'"
    else echo "нечем распаковать zip (нужен unzip или python3)" >&2; return 1; fi || return 1
    rm -f "$Z"; chmod +x "$W/platform-tools/adb" 2>/dev/null || true
  fi
  export PATH="$W/platform-tools:$PATH"
}
command -v curl >/dev/null || die "нет curl"
command -v adb >/dev/null || get_adb || die "нет adb: поставь Android platform-tools (https://developer.android.com/tools/releases/platform-tools)"
# adb старше 1.0.39 не передаёт код выхода команд на телефоне - проверки «получилось или нет» врали бы
AV=$(adb version 2>/dev/null | sed -n 's/^Android Debug Bridge version 1[.]0[.]\([0-9][0-9]*\).*/\1/p' | head -n 1) || AV=""
if [ -n "$AV" ] && [ "$AV" -lt 39 ]; then
  say "adb в системе старый (1.0.$AV) - беру свежий platform-tools Google"
  get_adb || die "adb 1.0.$AV слишком старый, а свежий не скачался: поставь Android platform-tools (https://developer.android.com/tools/releases/platform-tools)"
fi
if ! adb get-state >/dev/null 2>&1; then
  DEVS=$(adb devices 2>/dev/null | tail -n +2 | tr -d '\r') || DEVS="" # под set -e сбой adb иначе молча обрывал скрипт
  case "$DEVS" in
    *unauthorized*) die "телефон не разрешил отладку этому ПК: на внешнем экране нажми «Разрешить» (с галочкой «Всегда»)" ;;
    *"no permissions"*) die "нет прав на USB-устройство (Linux): поставь правила udev (пакет android-udev-rules или android-sdk-platform-tools-common) и переподключи кабель" ;;
    *offline*) die "телефон в adb «offline»: переподключи кабель (или adb kill-server) и разреши отладку на внешнем экране" ;;
  esac
  ND=$(echo "$DEVS" | grep -c "$(printf '\t')device\$" || true)
  [ "$ND" -gt 1 ] && die "подключено несколько устройств ($ND, см. adb devices): оставь один телефон или укажи ANDROID_SERIAL=<серийник> перед командой"
  W_DRV=""; [ "$OS" = windows ] && W_DRV="; в Windows нужен драйвер Samsung USB Driver for Mobile Phones"
  die "телефон не виден в adb: включи «Отладка по USB» (Настройки -> Параметры разработчика), подключи кабель с данными$W_DRV"
fi
say "проверка root (подтверди запрос Magisk на телефоне)"
is_root || die "su не дал root: открой Magisk -> Суперпользователь -> разреши Shell"

say "релиз tools-N в $REPO"
REL=""
for PG in 1 2 3 4 5; do # по 100 на страницу; релизов может быть больше
  R=$(curl -fsSL --retry 3 "https://api.github.com/repos/$REPO/releases?per_page=100&page=$PG") \
    || die "не получил список релизов $REPO с GitHub (нет интернета или исчерпан часовой лимит запросов к API GitHub - попробуй позже)"
  REL="$REL$R"
  [ "$(echo "$R" | grep -o '"tag_name"' | grep -c .)" -lt 100 ] && break
done
# API GitHub отдаёт релизы не по дате, а по имени (tools-9 раньше tools-21) - берём наибольший номер
asset() { echo "$REL" | grep -o "https://[^\"]*/tools-[0-9]*/$1\"" | tr -d '"' | sed 's|.*/tools-\([0-9]*\)/.*|\1 &|' | sort -k1,1nr | head -n 1 | cut -d' ' -f2; }
TOOLS=$({ asset f2qdsp-android-arm64.tar.xz; asset llama-debian-arm64.tar.xz; } | grep -o 'tools-[0-9]*' | head -n 1 || true) # для отчёта
get() { # get <url> <файл> [sha256] - с sha256: файл из кэша проверяется (устаревший качается заново)
  if [ -s "$W/$2" ]; then
    [ -z "${3:-}" ] && return 0
    [ "$(sha "$W/$2")" = "$3" ] && return 0
    say "$2 в кэше устарел или битый - качаю заново"; rm -f "$W/$2"
  fi
  say "скачиваю $2"; curl -fL --retry 3 -o "$W/$2.part" "$1" || die "не скачался $2 ($1)"
  mv "$W/$2.part" "$W/$2"
  if [ -n "${3:-}" ] && [ "$(sha "$W/$2")" != "$3" ]; then rm -f "$W/$2"; die "sha256 $2 не совпал после скачивания"; fi
}
get_asset() { # get_asset <имя> - из последнего релиза tools-N, sha256 из его SHA256SUMS; 1 - такого файла нет
  local URL SUM
  URL=$(asset "$1"); [ -n "$URL" ] || return 1
  SUM=$(curl -fsSL --retry 3 "${URL%/*}/SHA256SUMS" | awk -v f="$1" '$2==f || $2=="*"f {print $1}') || SUM=""
  [ -n "$SUM" ] || say "нет SHA256SUMS для $1 - без проверки"
  get "$URL" "$1" "$SUM"
}
adb shell "mkdir -p $T"
# скрипты для телефона - без \r: если репозиторий скачан в Windows с CRLF, sh на телефоне их не выполнит
PH=$W/phone; mkdir -p "$PH"
for F in "$HERE"/phone/*.sh; do tr -d '\r' <"$F" >"$PH/${F##*/}"; done

# 1) копия EFS - до всего остального. Разделы только читаются; архив - на ПК, с телефона удаляется
EFS_ST="пропущена (SKIP_BACKUP=1)"
if [ "${SKIP_BACKUP:-0}" != 1 ]; then
  if ls "$BK"/fold2-efs-*.tar.gz >/dev/null 2>&1; then
    say "копия EFS уже есть в $BK - новую не делаю"; EFS_ST="уже была"
  else
    say "копия EFS (IMEI, ключи, калибровки радио) -> $BK"
    mkdir -p "$BK"; chmod 700 "$BK" 2>/dev/null || true
    adb push "$PH/backup_efs.sh" "$T/" >/dev/null
    BOUT=$(asu "sh $T/backup_efs.sh" 2>&1) && BRC=0 || BRC=$?
    echo "$BOUT"
    BF=$(echo "$BOUT" | grep -o '/data/local/tmp/fold2-efs-[0-9-]*[.]tar[.]gz' | head -n 1 || true)
    if [ -n "$BF" ] && adb pull "$BF" "$BK/" >/dev/null; then
      PS=$(asu "sha256sum $BF" | tr -d '\r' | cut -d' ' -f1) || PS=""
      if [ -n "$PS" ] && [ "$PS" = "$(sha "$BK/${BF##*/}")" ]; then
        asu "rm -f $BF"; EFS_ST="сделана, sha256 совпал"
        say "копия EFS на ПК: $BK/${BF##*/} (sha256 совпал). Храни её и НИКОМУ не отправляй - в ней IMEI"
      else
        rm -f "$BK/${BF##*/}"; EFS_ST="ОШИБКА: скопировалась с ошибкой, осталась на телефоне"
        say "ВНИМАНИЕ: копия EFS скопировалась с ошибкой - на телефоне осталась $BF, запусти скрипт ещё раз"
      fi
    else
      say "ВНИМАНИЕ: копию EFS сделать не удалось (вывод выше) - продолжаю, Debian и NPU разделы не трогают"; EFS_ST="ОШИБКА: не сделана"
    fi
    [ "$BRC" = 0 ] || { say "ВНИМАНИЕ: часть разделов не прочиталась (вывод выше)"; EFS_ST="$EFS_ST; часть разделов не прочиталась"; }
  fi
fi

# 2) уровень отладки: при MID/HIGH паника ядра или падение cDSP оставляют телефон висеть в Upload mode до кнопок
LV=$(dbg_level); NPU_OK=1; NT_ST="пропущена"
if [ "$LV" = LOW ]; then
  say "уровень отладки LOW - при сбое телефон просто перезагрузится"
elif [ "$LV" = "?" ]; then
  say "уровень отладки не удалось узнать. Если при проверке NPU телефон зависнет на синем экране - зажми питание и"
  say "громкость вниз на 10 секунд, он перезагрузится"
else
  say "уровень отладки: $LV. Если не LOW, при сбое ядра или DSP телефон зависает (синий экран Upload mode) и ждёт кнопок."
  if ask "Перезагрузить телефон и включить LOW (безопасно, данные не трогает)?"; then
    say "перезагрузка в LOW (1-3 минуты)"
    if reboot_low; then
      is_root || die "после перезагрузки su не дал root"
      LV=$(dbg_level); say "уровень отладки после перезагрузки: $LV"
    else
      say "телефон не перезагрузился (команда reboot не сработала) - уровень остаётся $LV"
    fi
  fi
  if [ "$LV" = MID ] || [ "$LV" = HIGH ]; then
    NPU_OK=0; NT_ST="пропущена: уровень отладки $LV"; say "проверку NPU пропускаю (при уровне $LV сбой DSP повесил бы телефон)"
  fi
fi

wait_unlock # Debian монтирует /sdcard, модель кладётся в /sdcard - нужен разблокированный телефон
FD=/data/local/fold2
DEB_ST="пропущен (SKIP_DEBIAN=1)"; DEB_FAIL=0
if [ "${SKIP_DEBIAN:-0}" != 1 ]; then
  if yes_on_phone "test -f $FD/debian/etc/fold2-setup.done"; then
    # 3) Debian уже стоит (настройка закончена): обновляем скрипты и автозапуск, rootfs не трогаем
    say "Debian уже установлен - обновляю debian.sh, setup_in_chroot.sh и автозапуск"
    adb push "$PH/debian.sh" "$PH/setup_in_chroot.sh" "$T/" >/dev/null
    asu "cp $T/debian.sh $T/setup_in_chroot.sh $FD/ && sh $FD/debian.sh ssh; sh $FD/debian.sh autostart on" || say "обновление скриптов: ошибка (вывод выше)"
    DEB_ST="уже был, скрипты обновлены"
  else
    # rootfs распакован, а отметки об окончании настройки нет - прошлая установка оборвалась (сеть, кабель): продолжаем
    RESUME=0; yes_on_phone "test -x $FD/debian/bin/sh && test -f $FD/debian/root/setup_in_chroot.sh" && RESUME=1
    if [ "$RESUME" = 1 ]; then
      say "Debian распакован, но его настройка не закончена (прошлая установка оборвалась?) - продолжаю её"
    else
      D=$(curl -fsSL --retry 3 "$LXC/" | grep -o 'href="[0-9]\{8\}_[^"/]*/"' | tail -n1 | cut -d'"' -f2) || D=""
      [ -n "$D" ] || die "не нашёл образ Debian trixie arm64 на images.linuxcontainers.org (нет интернета?)"
      WANT=$(curl -fsSL --retry 3 "$LXC/${D}SHA256SUMS" | awk '$2=="rootfs.tar.xz"{print $1}') || WANT=""
      [ -n "$WANT" ] || say "нет SHA256SUMS для rootfs - без проверки"
      get "$LXC/${D}rootfs.tar.xz" rootfs.tar.xz "$WANT"
    fi
    for A in turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz; do
      get_asset "$A" || say "нет $A в релизах (setup соберёт/скачает сам)"
    done
    XURL=$(curl -fsSL --retry 3 "https://api.github.com/repos/termux/termux-x11/releases/tags/nightly" | grep -o 'https://[^"]*termux-x11-universal-debug.apk' | head -n1) || XURL=""
    if [ -n "$XURL" ]; then get "$XURL" termux-x11.apk
    else say "не нашёл Termux:X11 на GitHub - для XFCE поставь его apk сам (github.com/termux/termux-x11, релиз nightly)"; fi
    say "копирую на телефон"
    adb push "$PH/debian.sh" "$PH/setup_in_chroot.sh" "$T/" >/dev/null
    for F in rootfs.tar.xz turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz; do
      [ "$F" = rootfs.tar.xz ] && [ "$RESUME" = 1 ] && continue
      [ -f "$W/$F" ] && adb push "$W/$F" "$T/"
    done
    [ -f "$W/termux-x11.apk" ] && { say "ставлю Termux:X11"; adb install -r "$W/termux-x11.apk" || say "Termux:X11 не встал - поставь apk вручную"; }
    asu "mkdir -p $FD && cp $T/debian.sh $T/setup_in_chroot.sh $FD/ && for f in $T/*.tar.xz; do [ -f \$f ] && mv \$f $FD/; done; true"
    say "установка Debian на телефоне (лог: $FD/install.log), 10-30 минут"
    # pipefail: иначе код возврата - от tee, и ошибка установки прошла бы незамеченной
    if asu "set -o pipefail; sh $FD/debian.sh install $FD/rootfs.tar.xz $U 2>&1 | tee $FD/install.log"; then
      asu "rm -f $FD/*.tar.xz; sh $FD/debian.sh ssh; sh $FD/debian.sh autostart on"
      DEB_ST="установлен"; [ "$RESUME" = 1 ] && DEB_ST="установка продолжена и закончена"
    else
      DEB_FAIL=1; DEB_ST="ОШИБКА установки (конец install.log - в отчёте)"
      say "ОШИБКА: установка Debian не удалась (лог на телефоне: $FD/install.log). Запусти этот скрипт ещё раз -"
      say "установка продолжится с места остановки. NPU и отчёт делаю дальше"
    fi
  fi
fi
BL_ST="не ставился"
if [ "${SKIP_DEBIAN:-0}" != 1 ] && [ -n "$BL" ] && yes_on_phone "test -f $FD/debian.conf"; then
  # предел заряда: в debian.conf (автозапуск ставит его при каждой загрузке) и сразу. Заданный там (вручную или
  # прошлым запуском) без явного BATT_LIMIT=N не меняем. debian.conf читается как sh: действует последняя строка,
  # значение может быть в кавычках
  CL=$(asu "grep ^BATT_LIMIT= $FD/debian.conf" 2>/dev/null | tr -d '\r' | tail -n 1 |
    sed -n "s/^BATT_LIMIT=[\"']*\([0-9][0-9]*\).*/\1/p") || CL=""
  if [ -n "$CL" ] && [ "$BL_ENV" != set ]; then
    [ "$CL" = "$BL" ] || say "в debian.conf уже задан предел заряда $CL% - оставляю его (другой: BATT_LIMIT=N bash $0)"
    BL=$CL
  elif [ "$CL" != "$BL" ]; then
    [ -z "$CL" ] || say "в debian.conf был предел заряда $CL% - ставлю $BL% (BATT_LIMIT=$BL)"
    asu "sed -i /^BATT_LIMIT=/d $FD/debian.conf; echo BATT_LIMIT=$BL >> $FD/debian.conf"
  fi
  if asu "sh $FD/debian.sh battery $BL"; then BL_ST="$BL%"
  else BL_ST="$BL% - не поставился"; say "предел заряда не поставился (вывод выше) - не страшно"; fi
fi

NPU_ST="пропущен (SKIP_NPU=1)"
if [ "${SKIP_NPU:-0}" != 1 ]; then
  NPU_ST="нет пакета в релизах"
  if get_asset f2qdsp-android-arm64.tar.xz; then
    adb push "$W/f2qdsp-android-arm64.tar.xz" "$T/"
    # запущенный llama-server из старой версии мешал бы заменить файлы
    asu "test -f /data/local/tmp/fold2-npu/npu.sh && sh /data/local/tmp/fold2-npu/npu.sh stop" >/dev/null 2>&1 || true
    if asu "mkdir -p /data/local/tmp/fold2-npu && /data/adb/magisk/busybox tar -xJf $T/f2qdsp-android-arm64.tar.xz -C /data/local/tmp/fold2-npu && rm $T/f2qdsp-android-arm64.tar.xz"; then
      NPU_ST="установлен"
    else
      NPU_ST="ОШИБКА: не распаковался"; NPU_OK=0; say "ВНИМАНИЕ: пакет NPU не распаковался на телефоне (вывод выше)"
    fi
    if [ "${SKIP_MODEL:-0}" != 1 ]; then
      MF=$(basename "$NPU_MODEL_URL")
      # модель (1 ГБ) нужна только для npu.sh server - если не скачалась, остальное всё равно доделываем
      if ! (get "$NPU_MODEL_URL" "$MF"); then
        say "ВНИМАНИЕ: модель $MF не скачалась - запусти скрипт ещё раз (или положи .gguf в /sdcard/models сам)"
      # уже на телефоне с тем же размером - не копируем 1 ГБ заново
      elif [ "$(one "stat -c %s /sdcard/models/$MF")" = "$(wc -c <"$W/$MF" | tr -d ' ')" ]; then
        say "модель $MF уже на телефоне"
      else
        { adb shell "mkdir -p /sdcard/models" && adb push "$W/$MF" /sdcard/models/; } \
          || say "ВНИМАНИЕ: модель не скопировалась на телефон (мало места?)"
      fi
    fi
    if [ "$NPU_OK" = 1 ]; then
      say "проверка NPU (cDSP):"
      B1=$(bootid); NRC=0
      asu "sh /data/local/tmp/fold2-npu/npu.sh test" 2>&1 | tee "$W/npu-test.txt" || NRC=$?
      case "$NRC" in 0) NT_ST="DSP работает" ;; 3) NT_ST="DSP не открылся, llama.cpp считает на CPU" ;; *) NT_ST="НЕ пройдена" ;; esac
      if [ -n "$B1" ] && [ "$(bootid)" != "$B1" ]; then
        # нет ответа или другая загрузка: сбой DSP/ядра перезагрузил телефон (или отошёл кабель) - ждём, потом отчёт
        say "ВНИМАНИЕ: телефон пропал из adb во время проверки NPU - похоже, перезагрузился. Жду до 5 минут"
        NT_ST="телефон пропал из adb во время проверки"; I=0
        while [ $I -lt 60 ]; do
          B2=$(bootid)
          if [ -n "$B2" ]; then
            [ "$B2" = "$B1" ] && { NT_ST="$NT_ST (не перезагружался, связь вернулась)"; break; }
            [ "$(one getprop sys.boot_completed)" = 1 ] && { NT_ST="телефон ПЕРЕЗАГРУЗИЛСЯ во время проверки (сбой DSP или ядра)"; break; }
          fi
          I=$((I + 1)); sleep 5
        done
        [ $I -ge 60 ] && say "телефон не вернулся за 5 минут (синий экран Upload mode? - зажми питание и громкость вниз на 10 с) - отчёт пишу без него"
        say "проверка NPU: $NT_ST"
      elif [ "$NRC" != 0 ] && [ "$NRC" != 3 ]; then
        say "тест NPU не прошёл - не страшно: тогда llama.cpp считает на CPU (пришли отчёт)"
      fi
    fi
  else
    say "нет f2qdsp-android-arm64.tar.xz в релизах"
  fi
fi

# 5) проверка телефона: что работает в прошивке (связь, Wi-Fi, камеры, ядро для Docker, cDSP...) - итог в отчёт
CHK_ST="пропущена (SKIP_CHECK=1)"; : >"$W/check.txt"
if [ "${SKIP_CHECK:-0}" != 1 ]; then
  say "проверка телефона (связь, Wi-Fi, камеры, ядро...)"
  { adb push "$PH/check_phone.sh" "$T/" >/dev/null && asu "sh $T/check_phone.sh"; } 2>&1 | tr -d '\r' >"$W/check.txt" || true
  CHK_ST=$(sed -n 's/^ИТОГ: //p' "$W/check.txt" | head -n 1)
  if [ -n "$CHK_ST" ]; then grep -E '^(НЕТ|ВНИМАНИЕ) ' "$W/check.txt" | sed 's/^/   /' || true
  else CHK_ST="не прошла (вывод - в отчёте)"; fi
fi
IP=$(adb shell "ip -4 addr show wlan0" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
# 6) отчёт для разработчика: версии, уровень отладки, состояние Debian, тест NPU. IMEI и серийного номера в нём нет
# (/proc/cmdline целиком не берём - в нём androidboot.serialno)
{ echo "fold2 отчёт $(date)"
  echo "установщик: релиз ${TOOLS:-?}; копия EFS: $EFS_ST; уровень отладки: $LV; Debian: $DEB_ST; предел заряда: $BL_ST; NPU: $NPU_ST; проверка NPU: $NT_ST; проверка телефона: $CHK_ST"
  for P in ro.product.model ro.boot.bootloader ro.build.display.id ro.boot.debug_level ro.build.version.release; do echo "$P=$(one getprop $P)"; done
  echo "--- uname"; asu "uname -a" 2>&1 || true
  echo "--- система"; asu "getenforce; magisk -c; df -h /data | tail -n 1; head -n 3 /proc/meminfo; uptime" 2>&1 || true
  echo "--- debian.sh status"; asu "test -f $FD/debian.sh && sh $FD/debian.sh status" 2>&1 || true
  echo "--- прошлые перезагрузки (debian.sh bootlog ls)"; asu "test -f $FD/debian.sh && sh $FD/debian.sh bootlog ls" 2>&1 || true
  echo "--- npu.sh test"; if [ -f "$W/npu-test.txt" ] && [ "$NPU_OK" = 1 ]; then cat "$W/npu-test.txt"; else echo "(не запускался)"; fi
  if [ -s "$W/check.txt" ]; then echo "--- проверка телефона (check_phone.sh)"; cat "$W/check.txt"; fi
  if [ "$DEB_FAIL" = 1 ]; then echo "--- install.log (конец)"; asu "tail -n 80 $FD/install.log" 2>&1 || true; fi
} 2>&1 | tr -d '\r' >"$REPORT"
rm -f "$W/npu-test.txt" "$W/check.txt"
if [ "$DEB_FAIL" = 1 ]; then
  echo "НЕ ВСЁ: установка Debian оборвалась (причина - в конце отчёта). Запусти скрипт ещё раз - она продолжится."
  echo "Отчёт: $REPORT - его можно прислать разработчику (IMEI в нём нет)."
  exit 1
fi
cat <<M
Готово. Проверка NPU: $NT_ST. Проверка телефона: $CHK_ST.
Отчёт: $REPORT - его можно прислать разработчику (IMEI в нём нет).
Копия EFS: $BK - храни, никому не отправляй.
  Войти:        adb shell  ->  su -mm -c "sh /data/local/fold2/debian.sh shell"
  Пароль:       su -mm -c "sh /data/local/fold2/debian.sh run passwd $U"   (потом ssh -p 2222 $U@${IP:-<IP>})
  XFCE:         su -mm -c "sh /data/local/fold2/debian.sh x11"
  Docker:       su -mm -c "sh /data/local/fold2/debian.sh docker"
  llama.cpp:    su -mm -c "sh /data/local/fold2/debian.sh llama"     -> http://${IP:-<IP>}:8080
  NPU llama:    su -mm -c "sh /data/local/tmp/fold2-npu/npu.sh server" -> http://${IP:-<IP>}:8081
M
