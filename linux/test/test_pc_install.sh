#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2012,SC2010,SC1091  # A && ok || bad: ok/bad всегда успешны; ls - в своих временных каталогах
# Тесты pc_install_debian.sh без телефона и интернета: adb и curl - заглушки из fake/pc (телефон - каталог,
# релизы и образ Debian - маленькие файлы), sleep - без ожидания. Вопрос [Д/н] отвечается через псевдотерминал (python3 pty).
#   bash linux/test/test_pc_install.sh
set -uo pipefail
TD=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$TD/../.." && pwd)
. "$TD/lib.sh"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# заглушки - копией с правом запуска (через API GitHub файлы попадают в репозиторий без +x)
FK=$WORK/fake; cp -R "$TD/fake" "$FK"; chmod -R 755 "$FK"
SRV=$WORK/srv; mkdir -p "$SRV"
for F in rootfs.tar.xz turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz f2qdsp-android-arm64.tar.xz \
         termux-x11-universal-debug.apk Qwen3-1.7B-Q4_0.gguf; do head -c 2048 /dev/urandom >"$SRV/$F"; done
MSIZE=$(wc -c <"$SRV/Qwen3-1.7B-Q4_0.gguf" | tr -d ' ')
EFS=fold2-efs-20261101-120000.tar.gz

fresh() { # новый ПК и телефон: копия скрипта (отчёт пишется рядом с ним), пустой кэш и ~/fold2-backup
  P=$WORK/pc; rm -rf "$P"; mkdir -p "$P/lx/phone" "$P/st" "$P/home"
  cp "$REPO/linux/pc_install_debian.sh" "$P/lx/"; cp "$REPO"/linux/phone/*.sh "$P/lx/phone/"
  head -c 4096 /dev/urandom >"$P/st/efs.tgz"; : >"$P/st/log"; : >"$P/st/curl.log"
}
# pc <вывод> [ПЕРЕМЕННАЯ=значение...] [-- аргументы]; ANSWER=<ответ> - запуск в псевдотерминале с этим ответом на [Д/н]
pc() {
  local O=$1; shift; local E=() A=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do E+=("$1"); shift; done; [ "${1:-}" = -- ] && shift; A=("$@")
  : >"$P/st/log"; : >"$P/st/curl.log"
  local CMD=(env PATH="$FK/pc:$FK:$PATH" HOME="$P/home" FAKE_ST="$P/st" FAKE_SRV="$SRV" FAKE_ROOT="$P/st"
    LANG="${TLANG:-C.UTF-8}" LC_ALL="${TLANG:-C.UTF-8}" ${E[@]+"${E[@]}"} bash "$P/lx/pc_install_debian.sh" ${A[@]+"${A[@]}"})
  if [ -n "${ANSWER+x}" ]; then
    python3 - "$ANSWER" "${CMD[@]}" >"$O" 2>&1 <<'PY'
import os, pty, sys
ans, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out, sent = b"", False
while True:
    try:
        d = os.read(fd, 4096)
    except OSError:
        break
    if not d:
        break
    out += d
    if not sent and "[Д/н]".encode() in out:
        os.write(fd, (ans + "\n").encode()); sent = True
sys.stdout.buffer.write(out.replace(b"\r\n", b"\n"))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
PY
  else
    "${CMD[@]}" >"$O" 2>&1 </dev/null
  fi
}
LOG() { echo "$P/st/log"; }
report() { ls "$P"/lx/fold2-report-*.txt 2>/dev/null | tail -n 1; }
O=$WORK/out

echo "-- первая установка: копия EFS, LOW, Debian, предел заряда, NPU, отчёт"
fresh
# скрипты с CRLF (как после git clone в Windows без .gitattributes) - на телефон должны уйти без \r
for F in "$P"/lx/phone/*.sh; do sed -i 's/$/\r/' "$F"; done
pc "$O"; eq "$?" 0 "код 0" "$O"
cmp -s "$P/home/fold2-backup/$EFS" "$P/st/efs.tgz" && ok "копия EFS на ПК" || bad "копии EFS нет или не та" "$O"
eq "$(stat -c %a "$P/home/fold2-backup")" 700 "каталог копий 0700"
has "$(LOG)" "rm -f /data/local/tmp/$EFS" "копия удалена с телефона после сверки"
has "$O" "уровень отладки LOW" "LOW"; hasnt "$(LOG)" "REBOOTED" "без перезагрузки"
has "$(LOG)" "debian.sh install /data/local/fold2/rootfs.tar.xz fold2" "установка Debian"
has "$P/st/curl.log" "20261029_05%3A24/rootfs.tar.xz" "свежий образ Debian"
has "$(LOG)" "echo BATT_LIMIT=80 >>" "BATT_LIMIT=80 в debian.conf"; has "$(LOG)" "debian.sh battery 80" "предел заряда 80"
has "$(LOG)" "autostart on" "автозапуск"; has "$(LOG)" "npu.sh test" "тест NPU"
has "$(LOG)" "push $P/lx/fold2-dl/Qwen3-1.7B-Q4_0.gguf /sdcard/models/" "модель на телефон"
grep -l $'\r' "$P"/st/pushed/*.sh >/dev/null 2>&1 && bad "на телефон ушли скрипты с CRLF" || ok "скрипты на телефон без CRLF"
R=$(report); [ -f "$R" ] && ok "отчёт создан" || bad "нет отчёта" "$O"
has "$R" "ИТОГ: OK" "отчёт: тест NPU"; has "$R" "ro.product.model=fake-ro.product.model" "отчёт: модель"
has "$R" "Linux localhost" "отчёт: uname"; has "$R" "установщик: копия EFS: сделана, sha256 совпал; уровень отладки: LOW; предел заряда: 80; проверка NPU: да" "отчёт: итог установщика"
has "$R" "31.1:MAGISK" "отчёт: система"; has "$R" "1a2b3c4d: KP" "отчёт: прошлые перезагрузки"; hasnt "$R" "serialno" "отчёт без серийника"; hasnt "$R" $'\r' "отчёт без \\r"
has "$O" "http://192.168.1.5:8081" "адрес NPU в конце"; [ -e "$P/lx/fold2-dl/npu-test.txt" ] && bad "npu-test.txt не удалён" || ok "временный файл удалён"
NPUSUM=$(grep -c "f2qdsp-android-arm64.tar.xz$" "$P/st/curl.log")

sleep 1 # имя отчёта - с точностью до секунды
echo "-- повторный запуск: ничего лишнего"
pc "$O" FAKE_INSTALLED=1 FAKE_MSIZE="$MSIZE"; eq "$?" 0 "код 0" "$O"
has "$O" "копия EFS уже есть" "копия EFS не повторяется"; has "$(report)" "копия EFS: уже была" "в отчёте - уже была"; hasnt "$(LOG)" "backup_efs.sh" "backup_efs.sh не запускался"
has "$O" "Debian уже установлен" "Debian не переустанавливается"; hasnt "$(LOG)" "debian.sh install" "без install"
hasnt "$P/st/curl.log" "rootfs.tar.xz" "образ Debian не качается"
has "$O" "модель Qwen3-1.7B-Q4_0.gguf уже на телефоне" "модель не копируется заново"
has "$(LOG)" "npu.sh stop" "старый npu server останавливается"
eq "$(grep -c 'f2qdsp-android-arm64.tar.xz$' "$P/st/curl.log")" 0 "NPU из кэша (sha256 совпал)"
eq "$NPUSUM" 1 "в первый раз NPU качался один раз"
eq "$(ls "$P"/lx/fold2-report-*.txt | grep -c .)" 2 "второй отчёт"

echo "-- копия EFS повредилась при копировании"
fresh; pc "$O" FAKE_BADSHA=1; eq "$?" 0 "код 0" "$O"
[ -e "$P/home/fold2-backup/$EFS" ] && bad "битая копия осталась на ПК" || ok "битая копия удалена с ПК"
hasnt "$(LOG)" "rm -f /data/local/tmp/$EFS" "с телефона не удалена"; has "$O" "скопировалась с ошибкой" "предупреждение"
has "$(report)" "копия EFS: ОШИБКА: скопировалась с ошибкой" "в отчёте - ошибка копии"

echo "-- копия EFS не сделалась"
fresh; pc "$O" FAKE_NOBACKUP=1 FAKE_BRC=1; eq "$?" 0 "код 0 (установка продолжается)" "$O"
has "$O" "копию EFS сделать не удалось" "предупреждение"; has "$O" "часть разделов не прочиталась" "про ошибки чтения"
has "$(report)" "копия EFS: ОШИБКА: не сделана; часть разделов не прочиталась" "в отчёте - копия не сделана"
has "$(LOG)" "debian.sh install" "Debian ставится дальше"

echo "-- уровень отладки"
fresh; pc "$O" FAKE_DL=0x494d; eq "$?" 0 "MID без терминала: код 0" "$O"
hasnt "$(LOG)" REBOOTED "без терминала не перезагружает"; has "$O" "проверку NPU пропускаю" "NPU пропущен"
hasnt "$(LOG)" "npu.sh test" "npu.sh test не запускался"; has "$(report)" "(не запускался)" "в отчёте: не запускался"
has "$(report)" "уровень отладки: MID; предел заряда: 80; проверка NPU: пропущена" "в отчёте - MID, проверка пропущена"
for L in C C.UTF-8; do
  for A in "" д да Да y Y; do
    fresh; TLANG=$L ANSWER=$A pc "$O" FAKE_DL=0x4948
    if grep -q REBOOTED "$(LOG)" && grep -qF "после перезагрузки: LOW" "$O" && grep -qF "npu.sh test" "$(LOG)"; then ok "HIGH, ответ '$A' ($L): перезагрузка в LOW, тест NPU"
    else bad "HIGH, ответ '$A' ($L)" "$O"; fi
  done
  for A in н нет n N q; do
    fresh; TLANG=$L ANSWER=$A pc "$O" FAKE_DL=0x4948
    if ! grep -q REBOOTED "$(LOG)" && grep -qF "проверку NPU пропускаю" "$O"; then ok "HIGH, ответ '$A' ($L): без перезагрузки, NPU пропущен"
    else bad "HIGH, ответ '$A' ($L)" "$O"; fi
  done
done
fresh; ANSWER="" pc "$O" FAKE_DL=0x4948 FAKE_REBOOT_WORKS=0; unset ANSWER
grep -q REBOOTED "$(LOG)" && grep -qF "после перезагрузки: HIGH" "$O" && grep -qF "проверку NPU пропускаю" "$O" \
  && ok "перезагрузка не помогла - NPU пропущен" || bad "перезагрузка не помогла" "$O"
fresh; pc "$O" FAKE_DL= FAKE_CMDL=0x494d; has "$O" "уровень отладки: MID" "уровень из /proc/cmdline"
fresh; pc "$O" FAKE_DL= FAKE_CMDL=; has "$O" "уровень отладки не удалось узнать" "неизвестный уровень"
has "$(LOG)" "npu.sh test" "неизвестный уровень - тест NPU идёт"

echo "-- телефон заблокирован"
fresh; echo 2 >"$P/st/unlock"; pc "$O"; eq "$?" 0 "код 0" "$O"
eq "$(grep -c 'разблокируй телефон' "$O")" 1 "просьба разблокировать - один раз"
eq "$(grep -c 'test -d /sdcard/Android' "$(LOG)")" 3 "ждёт, пока не разблокируют"

echo "-- ошибки и настройки"
fresh; pc "$O" -- Bad; RC=$?; [ "$RC" = 1 ] && grep -qF "имя пользователя 'Bad'" "$O" && ok "неверное имя пользователя" || bad "неверное имя (rc=$RC)" "$O"
eq "$(grep -c . "$(LOG)")" 0 "до adb не дошло"
fresh; pc "$O" -- anna; has "$(LOG)" "rootfs.tar.xz anna" "своё имя пользователя"
fresh; pc "$O" BATT_LIMIT=; eq "$?" 0 "BATT_LIMIT= : код 0" "$O"; hasnt "$(LOG)" "battery" "BATT_LIMIT= - предел не ставится"
fresh; pc "$O" BATT_LIMIT=85; has "$(LOG)" "debian.sh battery 85" "BATT_LIMIT=85"
fresh; pc "$O" BATT_LIMIT=120; RC=$?; [ "$RC" != 0 ] && grep -qF "BATT_LIMIT=120" "$O" && ok "BATT_LIMIT=120 - отказ" || bad "BATT_LIMIT=120 (rc=$RC)" "$O"
fresh; pc "$O" FAKE_STATE=1; RC=$?; [ "$RC" != 0 ] && grep -qF "телефон не виден" "$O" && ok "нет телефона" || bad "нет телефона (rc=$RC)" "$O"
fresh; pc "$O" FAKE_STATE=1 FAKE_DEVICES=2; RC=$?
[ "$RC" != 0 ] && grep -qF "несколько устройств (2" "$O" && ok "два устройства - подсказка ANDROID_SERIAL" || bad "два устройства (rc=$RC)" "$O"
for D in unauthorized "no permissions (user in plugdev group)" offline; do
  fresh; pc "$O" FAKE_STATE=1 FAKE_DEVSTATE="$D"; RC=$?
  case "$D" in unauthorized) M="нажми «Разрешить»" ;; no*) M="правила udev" ;; *) M="«offline»" ;; esac
  [ "$RC" != 0 ] && grep -qF "$M" "$O" && ok "adb devices: $D - подсказка" || bad "adb devices: $D (rc=$RC)" "$O"
done
fresh; pc "$O" FAKE_NOROOT=1; RC=$?; [ "$RC" != 0 ] && grep -qF "su не дал root" "$O" && ok "нет root" || bad "нет root (rc=$RC)" "$O"
fresh; pc "$O" FAKE_INSTALL_RC=1; RC=$?
[ "$RC" != 0 ] && grep -qF "установка Debian не удалась" "$O" && ok "ошибка установки Debian - стоп" || bad "ошибка установки (rc=$RC)" "$O"
fresh; pc "$O" FAKE_BADSUM=1; RC=$?
[ "$RC" != 0 ] && grep -qF "sha256 f2qdsp-android-arm64.tar.xz не совпал" "$O" && ok "неверная sha256 - стоп" || bad "неверная sha256 (rc=$RC)" "$O"
[ -e "$P/lx/fold2-dl/f2qdsp-android-arm64.tar.xz" ] && bad "файл с неверной sha256 остался" || ok "файл с неверной sha256 удалён"
fresh; mkdir -p "$P/lx/fold2-dl"; echo old >"$P/lx/fold2-dl/f2qdsp-android-arm64.tar.xz"; pc "$O"; eq "$?" 0 "устаревший кэш: код 0" "$O"
has "$O" "f2qdsp-android-arm64.tar.xz в кэше устарел" "устаревший кэш качается заново"
cmp -s "$P/lx/fold2-dl/f2qdsp-android-arm64.tar.xz" "$SRV/f2qdsp-android-arm64.tar.xz" && ok "в кэше новый файл" || bad "в кэше старый файл"
fresh; pc "$O" FAKE_NO_NPU=1; eq "$?" 0 "нет NPU в релизе: код 0" "$O"; has "$O" "нет f2qdsp-android-arm64.tar.xz в релизах" "сообщение"
fresh; pc "$O" SKIP_BACKUP=1 SKIP_DEBIAN=1 SKIP_NPU=1; eq "$?" 0 "всё пропущено: код 0" "$O"
hasnt "$(LOG)" "backup_efs" "SKIP_BACKUP"; hasnt "$(LOG)" "debian.sh install" "SKIP_DEBIAN"; hasnt "$(LOG)" "npu" "SKIP_NPU"
[ -f "$(report)" ] && ok "отчёт и при пропусках" || bad "нет отчёта"
echo "-- нет adb: platform-tools скачиваются сами"
if command -v adb >/dev/null; then echo "  (пропуск: в системе есть свой adb)"; else
  fresh; NA=$WORK/noadb; rm -rf "$NA"; mkdir -p "$NA/pt/platform-tools"; ln -s "$FK/pc/curl" "$NA/curl"
  cp "$FK/pc/adb" "$NA/pt/platform-tools/adb"; (cd "$NA/pt" && python3 -m zipfile -c "$SRV/platform-tools-latest-linux.zip" platform-tools)
  O2=$WORK/out2; : >"$P/st/log"
  env PATH="$NA:$FK:$PATH" HOME="$P/home" FAKE_ST="$P/st" FAKE_SRV="$SRV" FAKE_ROOT="$P/st" SKIP_DEBIAN=1 SKIP_NPU=1 \
    bash "$P/lx/pc_install_debian.sh" >"$O2" 2>&1 </dev/null; RC=$?
  eq "$RC" 0 "без adb: код 0" "$O2"; has "$O2" "скачиваю platform-tools (linux)" "platform-tools скачаны"
  [ -x "$P/lx/fold2-dl/platform-tools/adb" ] && ok "adb распакован и исполняемый" || bad "нет platform-tools/adb" "$O2"
  has "$(LOG)" "ADB get-state" "дальше работает скачанный adb"
  env PATH="$NA:$FK:$PATH" HOME="$P/home" FAKE_ST="$P/st" FAKE_SRV="$SRV" FAKE_ROOT="$P/st" SKIP_DEBIAN=1 SKIP_NPU=1 \
    bash "$P/lx/pc_install_debian.sh" >"$O2" 2>&1 </dev/null
  hasnt "$O2" "скачиваю platform-tools" "второй раз не качает"
  rm -f "$SRV/platform-tools-latest-linux.zip"
fi
finish "установщик с ПК"
