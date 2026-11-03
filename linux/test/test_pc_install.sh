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
         termux-x11-universal-debug.apk Qwen3-1.7B-Q4_0.gguf Magisk-v31.1.apk; do head -c 2048 /dev/urandom >"$SRV/$F"; done
MSIZE=$(wc -c <"$SRV/Qwen3-1.7B-Q4_0.gguf" | tr -d ' ')
EFS=fold2-efs-20261101-120000.tar.gz
SSHKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFold2TestKey0123456789abcdefghijklmnopq"

fresh() { # новый ПК и телефон: копия скрипта (отчёт пишется рядом с ним), пустой кэш и ~/fold2-backup
  P=$WORK/pc; rm -rf "$P"; mkdir -p "$P/lx/phone" "$P/st" "$P/home"
  cp "$REPO/linux/pc_install_debian.sh" "$REPO/linux/pc_check_phone.sh" "$REPO/linux/pc_backup_debian.sh" "$P/lx/"; cp "$REPO"/linux/phone/*.sh "$P/lx/phone/"
  head -c 4096 /dev/urandom >"$P/st/efs.tgz"; : >"$P/st/log"; : >"$P/st/curl.log"
  mkdir -p "$P/home/.ssh"; echo "$SSHKEY fold2@pc" >"$P/home/.ssh/id_ed25519.pub" # ключ ssh этого ПК
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
has "$(LOG)" "rm -f /data/local/fold2-efs/$EFS" "копия удалена с телефона после сверки"
has "$(LOG)" "su -mm -c 'cat /data/local/fold2-efs/$EFS'" "копия EFS - через su из каталога root"; hasnt "$(LOG)" "ADB pull" "без adb pull из /data/local/tmp"
has "$(LOG)" "debian.sh ssh key $SSHKEY" "ключ ssh ПК - пользователю Debian (аргументами, не файлом)"
has "$(LOG)" "sh /data/local/fold2-npu/npu.sh test" "NPU - в /data/local/fold2-npu"; hasnt "$(LOG)" "sh /data/local/tmp/fold2-npu/npu.sh" "старый npu.sh из /data/local/tmp не запускается"
has "$(LOG)" "sha256sum -c -s" "пакет NPU сверяется на телефоне перед распаковкой"; hasnt "$P/st/curl.log" "HDR " "без GITHUB_TOKEN - без заголовка"
has "$O" "уровень отладки LOW" "LOW"; hasnt "$(LOG)" "REBOOTED" "без перезагрузки"
has "$(LOG)" "debian.sh install-bg /data/local/fold2/rootfs.tar.xz fold2" "установка Debian - отдельно от adb (install-bg)"
has "$(LOG)" "debian.sh install-log 0" "ход установки - из install.log"; eq "$(grep -c "распаковка rootfs" "$O")" 1 "строка лога показана один раз"
has "$O" "[fold2] готово." "конец лога установки"
has "$P/st/curl.log" "20261029_05%3A24/rootfs.tar.xz" "свежий образ Debian"
has "$(LOG)" "echo BATT_LIMIT=80 >>" "BATT_LIMIT=80 в debian.conf"; has "$(LOG)" "debian.sh battery 80" "предел заряда 80"
has "$(LOG)" "autostart on" "автозапуск"; has "$(LOG)" "npu.sh test" "тест NPU"
has "$(LOG)" "push $P/lx/fold2-dl/Qwen3-1.7B-Q4_0.gguf /sdcard/models/" "модель на телефон"
grep -l $'\r' "$P"/st/pushed/*.sh >/dev/null 2>&1 && bad "на телефон ушли скрипты с CRLF" || ok "скрипты на телефон без CRLF"
has "$(LOG)" "echo AUTO_X11=1 >>" "рабочий стол при загрузке (AUTO_X11=1)"; has "$(LOG)" "debian.sh x11" "рабочий стол запущен сразу"
R=$(report); [ -f "$R" ] && ok "отчёт создан" || bad "нет отчёта" "$O"
has "$R" "рабочий стол: при загрузке, запущен" "отчёт: рабочий стол"
has "$R" "ИТОГ: OK" "отчёт: тест NPU"; has "$R" "ro.product.model=fake-ro.product.model" "отчёт: модель"
has "$R" "Linux localhost" "отчёт: uname"
has "$R" "установщик: релиз tools-10; копия EFS: сделана, sha256 совпал; уровень отладки: LOW; Debian: установлен; предел заряда: 80%; рабочий стол: при загрузке, запущен; ssh: по ключу id_ed25519.pub; NPU: установлен; проверка NPU: DSP работает" "отчёт: итог установщика"
has "$R" "31.1:MAGISK" "отчёт: система"; has "$R" "1a2b3c4d: KP" "отчёт: прошлые перезагрузки"; hasnt "$R" "serialno" "отчёт без серийника"; hasnt "$R" $'\r' "отчёт без \\r"
has "$O" "http://192.168.1.5:8080 и :8081 - только с ключом" "адрес по Wi-Fi в конце - с ключом"; [ -e "$P/lx/fold2-dl/npu-test.txt" ] && bad "npu-test.txt не удалён" || ok "временный файл удалён"
# API GitHub отдаёт tools-9 раньше tools-10 - брать надо наибольший номер
hasnt "$P/st/curl.log" "tools-9/" "из старого релиза tools-9 ничего не качалось"
has "$P/st/curl.log" "tools-10/llama-debian-arm64.tar.xz" "llama из нового релиза tools-10"
for F in turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz f2qdsp-android-arm64.tar.xz; do
  cmp -s "$P/lx/fold2-dl/$F" "$SRV/$F" && ok "$F - файл нового релиза" || bad "$F не тот"
done
has "$(LOG)" "rm -f /data/local/fold2/*.tar.xz" "архивы после установки удалены с телефона"
NPUSUM=$(grep -c "f2qdsp-android-arm64.tar.xz$" "$P/st/curl.log")

sleep 1 # имя отчёта - с точностью до секунды
echo "-- повторный запуск: ничего лишнего"
pc "$O" FAKE_INSTALLED=1 FAKE_MSIZE="$MSIZE"; eq "$?" 0 "код 0" "$O"
has "$O" "копия EFS уже есть" "копия EFS не повторяется"; has "$(report)" "копия EFS: уже была" "в отчёте - уже была"; hasnt "$(LOG)" "backup_efs.sh" "backup_efs.sh не запускался"
has "$O" "Debian уже установлен" "Debian не переустанавливается"; hasnt "$(LOG)" "debian.sh install" "без install"
has "$(report)" "Debian: уже был, скрипты обновлены" "в отчёте - Debian уже был"
hasnt "$P/st/curl.log" "rootfs.tar.xz" "образ Debian не качается"
has "$O" "модель Qwen3-1.7B-Q4_0.gguf уже на телефоне" "модель не копируется заново"
has "$(LOG)" "npu.sh stop" "старый npu server останавливается"
eq "$(grep -c 'f2qdsp-android-arm64.tar.xz$' "$P/st/curl.log")" 0 "NPU из кэша (sha256 совпал)"
eq "$NPUSUM" 1 "в первый раз NPU качался один раз"
eq "$(ls "$P"/lx/fold2-report-*.txt | grep -c .)" 2 "второй отчёт"
hasnt "$(LOG)" "termux-x11.apk" "Termux:X11 стоит - не ставится заново"
pc "$O" FAKE_INSTALLED=1 FAKE_MSIZE="$MSIZE" FAKE_NOX11APP=1; eq "$?" 0 "Termux:X11 удалён: код 0" "$O"
has "$O" "Termux:X11 (окно рабочего стола) на телефоне нет - ставлю" "Termux:X11 удалён - сообщение"
has "$(LOG)" "install -r $P/lx/fold2-dl/termux-x11.apk" "Termux:X11 ставится снова"

echo "-- Debian от старого setup_in_chroot.sh: доустановка программ (debian.sh install-bg update)"
pc "$O" FAKE_INSTALLED=1 FAKE_OLD_SETUP=1 FAKE_MSIZE="$MSIZE"; eq "$?" 0 "старый Debian: код 0" "$O"
has "$(LOG)" "debian.sh install-bg update" "доустановка - отдельно от adb (install-bg update)"; has "$O" "[fold2] готово." "лог доустановки показан"
hasnt "$(LOG)" "install-bg /data/local/fold2/rootfs.tar.xz" "Debian не переустанавливается"
has "$(report)" "Debian: уже был, программы обновлены" "в отчёте - программы обновлены"
pc "$O" FAKE_INSTALLED=1 FAKE_OLD_SETUP=1 FAKE_INSTALL_RC=1 FAKE_MSIZE="$MSIZE"; eq "$?" 0 "доустановка не удалась: код 0" "$O"
has "$O" "программы в Debian не обновились" "доустановка не удалась - сообщение"; has "$(report)" "Debian: уже был; ОШИБКА обновления программ" "в отчёте - ошибка доустановки"
has "$(LOG)" "npu.sh test" "доустановка не удалась - NPU дальше"
pc "$O" FAKE_INSTALLED=1 FAKE_OLD_SETUP=1 SKIP_UPDATE=1 FAKE_MSIZE="$MSIZE"; hasnt "$(LOG)" "install-bg update" "SKIP_UPDATE=1 - без доустановки"

echo "-- копия EFS повредилась при копировании"
fresh; pc "$O" FAKE_BADSHA=1; eq "$?" 0 "код 0" "$O"
[ -e "$P/home/fold2-backup/$EFS" ] && bad "битая копия осталась на ПК" || ok "битая копия удалена с ПК"
hasnt "$(LOG)" "rm -f /data/local/fold2-efs/$EFS" "с телефона не удалена"; has "$O" "скопировалась с ошибкой" "предупреждение"
has "$(report)" "копия EFS: ОШИБКА: скопировалась с ошибкой" "в отчёте - ошибка копии"

fresh; pc "$O" FAKE_EFS_CUT=1; eq "$?" 0 "поток exec-out оборвался: код 0" "$O"
[ -e "$P/home/fold2-backup/$EFS" ] && bad "обрезанная копия осталась на ПК" || ok "обрезанная копия удалена с ПК"
has "$(report)" "копия EFS: ОШИБКА: скопировалась с ошибкой" "обрыв потока - ошибка копии"

echo "-- ssh: нет ключа ПК, ключ не добавился, GITHUB_TOKEN"
fresh; rm -rf "$P/home/.ssh"; pc "$O"; eq "$?" 0 "нет ключа ssh: код 0" "$O"
hasnt "$(LOG)" "debian.sh ssh key" "без ключа - ssh key не вызывается"; has "$O" "на ПК нет ключа ssh" "сообщение про ssh-keygen"
has "$(report)" "ssh: нет ключа ПК" "в отчёте - нет ключа"
fresh; echo "ssh-ed25519 AAAA'; reboot; ' x" >"$P/home/.ssh/id_ed25519.pub"; pc "$O"; eq "$?" 0 "кривой ключ: код 0" "$O"
hasnt "$(LOG)" "debian.sh ssh key" "кривой ключ не уходит в su -c"
fresh; pc "$O" FAKE_SSH_RC=1; eq "$?" 0 "ключ не добавился: код 0" "$O"
has "$(report)" "ssh: ОШИБКА: ключ id_ed25519.pub не добавился" "в отчёте - ошибка ключа"
fresh; pc "$O" GITHUB_TOKEN=tok123; eq "$?" 0 "с GITHUB_TOKEN: код 0" "$O"
has "$P/st/curl.log" "HDR Authorization: Bearer tok123" "GITHUB_TOKEN - в запросах к API"

echo "-- копия EFS не сделалась"
fresh; pc "$O" FAKE_NOBACKUP=1 FAKE_BRC=1; eq "$?" 0 "код 0 (установка продолжается)" "$O"
has "$O" "копию EFS сделать не удалось" "предупреждение"; has "$O" "часть разделов не прочиталась" "про ошибки чтения"
has "$(report)" "копия EFS: ОШИБКА: не сделана; часть разделов не прочиталась" "в отчёте - копия не сделана"
has "$(LOG)" "debian.sh install" "Debian ставится дальше"

echo "-- проверка NPU: итог в отчёте и в конце"
fresh; pc "$O" FAKE_NPU_RC=3; eq "$?" 0 "DSP не открылся: код 0" "$O"
has "$(report)" "проверка NPU: DSP не открылся, llama.cpp считает на CPU" "в отчёте - DSP не открылся"
has "$O" "Готово. Проверка NPU: DSP не открылся, llama.cpp считает на CPU." "в конце - итог NPU"
fresh; pc "$O" FAKE_NPU_RC=1; eq "$?" 0 "тест NPU не прошёл: код 0" "$O"
has "$O" "тест NPU не прошёл - не страшно" "тест NPU не прошёл - сообщение"; has "$(report)" "проверка NPU: НЕ пройдена" "в отчёте - НЕ пройдена"
fresh; pc "$O" FAKE_NPU_REBOOT=1; eq "$?" 0 "перезагрузка во время теста NPU: код 0" "$O"
has "$O" "телефон пропал из adb во время проверки NPU" "перезагрузка во время теста NPU - сообщение"; has "$(LOG)" "BOOTED" "телефон загрузился заново"
has "$(report)" "проверка NPU: телефон ПЕРЕЗАГРУЗИЛСЯ во время проверки (сбой DSP или ядра)" "в отчёте - перезагрузка во время теста"
has "$(report)" "ro.product.model=fake-ro.product.model" "отчёт после перезагрузки полный"; has "$(report)" "f2q-bench 2048 2048" "в отчёте - вывод теста до сбоя"
fresh; pc "$O" FAKE_NPU_REBOOT=1 FAKE_DOWN=1000; eq "$?" 0 "телефон не вернулся после сбоя NPU: код 0 (отчёт всё равно)" "$O"
has "$O" "телефон не вернулся за 5 минут" "телефон не вернулся - подсказка про Upload mode"; [ -f "$(report)" ] && ok "телефон не вернулся - отчёт есть" || bad "телефон не вернулся - нет отчёта" "$O"
has "$(report)" "проверка NPU: телефон пропал из adb во время проверки" "телефон не вернулся - в отчёте"
fresh; pc "$O" FAKE_NPU_FLAP=2; eq "$?" 0 "связь пропадала без перезагрузки: код 0" "$O"
has "$(report)" "проверка NPU: телефон пропал из adb во время проверки (не перезагружался, связь вернулась)" "в отчёте - связь вернулась"
hasnt "$(LOG)" "BOOTED" "связь пропадала - без перезагрузки"

echo "-- уровень отладки"
fresh; pc "$O" FAKE_DL=0x494d; eq "$?" 0 "MID без терминала: код 0" "$O"
hasnt "$(LOG)" REBOOTED "без терминала не перезагружает"; has "$O" "проверку NPU пропускаю" "NPU пропущен"
hasnt "$(LOG)" "npu.sh test" "npu.sh test не запускался"; has "$(report)" "(не запускался)" "в отчёте: не запускался"
has "$(report)" "уровень отладки: MID; Debian: установлен; предел заряда: 80%; рабочий стол: при загрузке, запущен; ssh: по ключу id_ed25519.pub; NPU: установлен; проверка NPU: пропущена: уровень отладки MID" "в отчёте - MID, проверка пропущена"
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
# телефон выключается не сразу: несколько вызовов adb ещё отвечает старая загрузка (sys.boot_completed=1, HIGH)
fresh; ANSWER="" pc "$O" FAKE_DL=0x4948 FAKE_SLOW=4 FAKE_DOWN=3; RC=$?; unset ANSWER
eq "$RC" 0 "медленное выключение: код 0" "$O"
grep -qF "после перезагрузки: LOW" "$O" && grep -qF "npu.sh test" "$(LOG)" && ok "медленное выключение: ждёт новую загрузку, уровень LOW" || bad "медленное выключение" "$O"
eq "$(sed -n '/REBOOTED/,/BOOTED/p' "$(LOG)" | grep -c 'getprop ro.boot.debug_level')" 0 "уровень не читается со старой загрузки"
fresh; ANSWER="" pc "$O" FAKE_DL=0x4948 FAKE_NOREBOOT=1; RC=$?; unset ANSWER
eq "$RC" 0 "reboot не сработал: код 0" "$O"
grep -qF "телефон не перезагрузился" "$O" && grep -qF "проверку NPU пропускаю" "$O" && ok "reboot не сработал: сообщение, NPU пропущен" || bad "reboot не сработал" "$O"
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
fresh; pc "$O" FAKE_STATE=1 FAKE_DEVICES_FAIL=1; RC=$?
[ "$RC" != 0 ] && grep -qF "телефон не виден" "$O" && ok "adb devices с ошибкой - понятное сообщение" || bad "adb devices с ошибкой (rc=$RC)" "$O"
fresh; pc "$O" FAKE_STATE=1 FAKE_DEVICES=2; RC=$?
[ "$RC" != 0 ] && grep -qF "несколько устройств (2" "$O" && ok "два устройства - подсказка ANDROID_SERIAL" || bad "два устройства (rc=$RC)" "$O"
for D in unauthorized "no permissions (user in plugdev group)" offline; do
  fresh; pc "$O" FAKE_STATE=1 FAKE_DEVSTATE="$D"; RC=$?
  case "$D" in unauthorized) M="нажми «Разрешить»" ;; no*) M="правила udev" ;; *) M="«offline»" ;; esac
  [ "$RC" != 0 ] && grep -qF "$M" "$O" && ok "adb devices: $D - подсказка" || bad "adb devices: $D (rc=$RC)" "$O"
done
fresh; pc "$O" FAKE_NOROOT=1; RC=$?; [ "$RC" != 0 ] && grep -qF "root так и не появился" "$O" && ok "нет root" || bad "нет root (rc=$RC)" "$O"
hasnt "$(LOG)" "debian.sh install" "без root Debian не ставится"; has "$(LOG)" "MAGISK_OPENED" "без root - открыт Magisk"

echo "-- рабочий стол (AUTO_X11)"
fresh; pc "$O" AUTO_X11=0; eq "$?" 0 "AUTO_X11=0: код 0" "$O"; has "$(LOG)" "echo AUTO_X11=0 >>" "AUTO_X11=0 в debian.conf"
hasnt "$(LOG)" "debian.sh x11" "AUTO_X11=0 - рабочий стол не запускается"
fresh; pc "$O" FAKE_CONF_X11=AUTO_X11=0; hasnt "$(LOG)" "AUTO_X11=1 >>" "AUTO_X11=0 из debian.conf не меняется"; hasnt "$(LOG)" "debian.sh x11" "и рабочий стол не запускается"
fresh; pc "$O" FAKE_CONF_X11=AUTO_X11=0 AUTO_X11=1; has "$(LOG)" "echo AUTO_X11=1 >>" "явный AUTO_X11=1 важнее debian.conf"
fresh; pc "$O" FAKE_X11_RC=1; eq "$?" 0 "рабочий стол не запустился - установка всё равно код 0" "$O"; has "$(report)" "сейчас НЕ запустился" "отчёт: рабочий стол не запустился"
fresh; pc "$O" AUTO_X11=yes; RC=$?; [ "$RC" != 0 ] && grep -qF "AUTO_X11=yes" "$O" && ok "неверный AUTO_X11 - ошибка" || bad "неверный AUTO_X11 (rc=$RC)" "$O"
fresh; pc "$O" FAKE_INSTALL_RC=1; hasnt "$(LOG)" "debian.sh x11" "Debian не встал - рабочий стол не запускается"
fresh; pc "$O" SKIP_DEBIAN=1; hasnt "$(LOG)" "debian.sh x11" "SKIP_DEBIAN=1 - рабочий стол не трогается"

echo "-- root: Magisk в boot есть, приложение, доп. настройка, разрешение для Shell"
fresh; pc "$O" FAKE_NOAPP=1; eq "$?" 0 "нет приложения Magisk: код 0" "$O"
has "$P/st/curl.log" "f2q-3/Magisk-v31.1.apk" "Magisk той же версии, что в boot, - из релиза f2q"
has "$(LOG)" "install -r $P/lx/fold2-dl/Magisk-v31.1.apk" "приложение Magisk поставлено"; has "$(LOG)" "MAGISK_OPENED" "Magisk открыт"
has "$(LOG)" "debian.sh install" "после root установка идёт дальше"
fresh; pc "$O" FAKE_NOAPP=1 FAKE_NO_F2Q=1; eq "$?" 0 "нет релиза f2q: код 0" "$O"
has "$P/st/curl.log" "topjohnwu/Magisk/releases/download/v31.1/Magisk-v31.1.apk" "нет в релизах f2q - официальный Magisk"
has "$(LOG)" "install -r $P/lx/fold2-dl/Magisk-v31.1.apk" "официальный Magisk поставлен (sha256 из digest)"
fresh; pc "$O" FAKE_NOAPP=1 FAKE_NO_F2Q=1 FAKE_NO_DIGEST=1; RC=$?
[ "$RC" != 0 ] && grep -qF "с проверенной sha256" "$O" && ok "без проверенной суммы Magisk не ставится" || bad "Magisk без суммы (rc=$RC)" "$O"
hasnt "$(LOG)" "install -r $P/lx/fold2-dl/Magisk" "непроверенный APK не ставится"
fresh; pc "$O" FAKE_NOAPP=1 FAKE_BADMSUM=1; RC=$?
[ "$RC" != 0 ] && grep -qF "sha256 Magisk-v31.1.apk не совпал" "$O" && ok "неверная sha256 Magisk - ошибка" || bad "неверная sha256 Magisk (rc=$RC)" "$O"
hasnt "$(LOG)" "install -r $P/lx/fold2-dl/Magisk" "APK с неверной суммой не ставится"
fresh; pc "$O" FAKE_NOENV=1; eq "$?" 0 "доп. настройка Magisk: код 0" "$O"
has "$O" "Требуется дополнительная настройка" "подсказка про доп. настройку"; has "$(LOG)" "BOOTED" "после доп. настройки - перезагрузка"
has "$(LOG)" "debian.sh install" "после доп. настройки установка идёт дальше"
fresh; pc "$O" FAKE_ROOT_AFTER=4; eq "$?" 0 "Shell разрешили не сразу: код 0" "$O"; has "$O" "root есть, Magisk настроен" "root дождались"
fresh; pc "$O" FAKE_NOSU=1; RC=$?
[ "$RC" != 0 ] && grep -qF "в boot нет Magisk" "$O" && ok "boot без Magisk - понятная ошибка" || bad "boot без Magisk (rc=$RC)" "$O"
hasnt "$(LOG)" "install -r $P/lx/fold2-dl/Magisk" "без Magisk в boot приложение не ставится"
fresh; pc "$O"; hasnt "$(LOG)" "MAGISK_OPENED" "root уже есть - Magisk не открывается"; hasnt "$(LOG)" "pm list packages" "root уже есть - приложение не ищется"
fresh; pc "$O" FAKE_INSTALL_RC=1; RC=$?
[ "$RC" = 1 ] && grep -qF "установка Debian не удалась" "$O" && ok "ошибка установки Debian - код 1" || bad "ошибка установки (rc=$RC)" "$O"
has "$O" "Запусти скрипт ещё раз - она продолжится" "подсказка запустить ещё раз"; hasnt "$(LOG)" "autostart on" "без автозапуска"
has "$(LOG)" "npu.sh test" "NPU ставится и проверяется дальше"
has "$(report)" "Debian: ОШИБКА установки" "в отчёте - ошибка Debian"; has "$(report)" "E: Unable to fetch some archives" "в отчёте - конец install.log"
echo "-- прошлая установка оборвалась: продолжение"
fresh; pc "$O" FAKE_INSTALLED=partial; eq "$?" 0 "продолжение: код 0" "$O"
has "$O" "настройка не закончена" "сообщение о продолжении"; has "$(LOG)" "debian.sh install-bg /data/local/fold2/rootfs.tar.xz fold2" "install запускается снова"
hasnt "$P/st/curl.log" "rootfs.tar.xz" "образ Debian заново не качается"; [ -e "$P/st/pushed/rootfs.tar.xz" ] && bad "rootfs скопирован на телефон" || ok "rootfs на телефон не копируется"
has "$(LOG)" "autostart on" "после продолжения - автозапуск"; has "$(report)" "Debian: установка продолжена и закончена" "в отчёте - продолжена"
echo "-- установка идёт на телефоне сама: обрыв связи, перезагрузка, повторный запуск во время установки"
fresh; pc "$O" FAKE_INSTALL_DROP=3; eq "$?" 0 "кабель выдернут во время установки: код 0" "$O"
has "$O" "телефон не отвечает (кабель?) - установка на нём идёт дальше" "обрыв связи - сообщение"; has "$O" "телефон снова на связи" "связь вернулась - сообщение"
eq "$(grep -c "телефон не отвечает" "$O")" 1 "сообщение об обрыве - один раз"; eq "$(grep -c "apt-get install" "$O")" 1 "лог после обрыва не повторяется"
has "$(report)" "Debian: установлен" "после обрыва - установлен"; has "$(LOG)" "autostart on" "после обрыва - автозапуск"
fresh; pc "$O" FAKE_INSTALL_DEAD=1; eq "$?" 1 "установка оборвалась на телефоне: код 1" "$O"
has "$O" "установка Debian оборвалась на телефоне" "оборвалась - сообщение"; has "$(report)" "Debian: ОШИБКА: установка оборвалась" "в отчёте - оборвалась"
hasnt "$(LOG)" "autostart on" "оборвалась - без автозапуска"; has "$(LOG)" "npu.sh test" "оборвалась - NPU дальше"
fresh; pc "$O" FAKE_INSTALLED=partial FAKE_INSTALL_RUNNING=1; eq "$?" 0 "установка уже идёт: код 0" "$O"
has "$O" "на телефоне уже идёт установка Debian (запущена раньше) - жду её конца" "уже идёт - сообщение"
hasnt "$(LOG)" "debian.sh install-bg" "вторая установка не запускается"; hasnt "$(LOG)" "cp /data/local/tmp/fold2/debian.sh" "идущий debian.sh не заменяется"
has "$(LOG)" "autostart on" "дождались - автозапуск"; has "$(report)" "Debian: установка продолжена и закончена" "в отчёте - продолжена"
fresh; pc "$O" FAKE_INSTALL_BG_RC=1; eq "$?" 1 "install-bg с ошибкой: код 1" "$O"
has "$O" "установка Debian не запустилась" "не запустилась - сообщение"; hasnt "$(LOG)" "install-log 0" "не запустилась - лог не ждём"
has "$(report)" "Debian: ОШИБКА: установка не запустилась" "в отчёте - не запустилась"
echo "-- предел заряда, уже заданный в debian.conf"
fresh; pc "$O" FAKE_CONF_BL=BATT_LIMIT=90; eq "$?" 0 "код 0" "$O"
has "$O" "уже задан предел заряда 90%" "сообщение"; has "$(LOG)" "debian.sh battery 90" "ставится 90 из debian.conf"
hasnt "$(LOG)" "echo BATT_LIMIT=80" "debian.conf не переписан"; has "$(report)" "предел заряда: 90%" "в отчёте - 90%"
fresh; pc "$O" FAKE_CONF_BL=BATT_LIMIT=90 BATT_LIMIT=70; eq "$?" 0 "явный BATT_LIMIT=70: код 0" "$O"
has "$O" "был предел заряда 90% - ставлю 70%" "явный BATT_LIMIT важнее debian.conf - сообщение"
has "$(LOG)" "echo BATT_LIMIT=70 >>" "debian.conf: 70"; has "$(LOG)" "debian.sh battery 70" "ставится 70"
has "$(report)" "предел заряда: 70%" "в отчёте - 70%"
fresh; pc "$O" "FAKE_CONF_BL=BATT_LIMIT=\"75\"  # вручную"; eq "$?" 0 "значение в кавычках: код 0" "$O"
has "$(LOG)" "debian.sh battery 75" "BATT_LIMIT=\"75\" в debian.conf понят"; hasnt "$(LOG)" "echo BATT_LIMIT=80" "кавычки: debian.conf не переписан"
fresh; pc "$O" "FAKE_CONF_BL=BATT_LIMIT=       # пусто"; has "$(LOG)" "echo BATT_LIMIT=80 >>" "пустой BATT_LIMIT в debian.conf - ставится 80"
echo "-- сбои сети и пакета"
fresh; pc "$O" FAKE_RELS_FAIL=1; RC=$?
[ "$RC" != 0 ] && grep -qF "не получил список релизов" "$O" && ok "API GitHub не ответил - понятная ошибка" || bad "API GitHub (rc=$RC)" "$O"
fresh; pc "$O" FAKE_NO_X11=1; eq "$?" 0 "нет Termux:X11: код 0" "$O"; has "$O" "не нашёл Termux:X11" "сообщение про Termux:X11"
fresh; pc "$O" FAKE_NO_MODEL=1; eq "$?" 0 "модель не скачалась: код 0" "$O"
has "$O" "модель Qwen3-1.7B-Q4_0.gguf не скачалась" "сообщение про модель"; has "$(LOG)" "npu.sh test" "тест NPU всё равно идёт"
fresh; pc "$O" FAKE_NPU_TAR_RC=1; eq "$?" 0 "пакет NPU не распаковался: код 0" "$O"
has "$O" "пакет NPU не распаковался" "сообщение"; hasnt "$(LOG)" "npu.sh test" "тест NPU не запускается"
has "$(report)" "NPU: ОШИБКА: не распаковался" "в отчёте - NPU не распаковался"
fresh; pc "$O" FAKE_BADSUM=1; RC=$?
[ "$RC" != 0 ] && grep -qF "sha256 f2qdsp-android-arm64.tar.xz не совпал" "$O" && ok "неверная sha256 - стоп" || bad "неверная sha256 (rc=$RC)" "$O"
[ -e "$P/lx/fold2-dl/f2qdsp-android-arm64.tar.xz" ] && bad "файл с неверной sha256 остался" || ok "файл с неверной sha256 удалён"
fresh; mkdir -p "$P/lx/fold2-dl"; echo old >"$P/lx/fold2-dl/f2qdsp-android-arm64.tar.xz"; pc "$O"; eq "$?" 0 "устаревший кэш: код 0" "$O"
has "$O" "f2qdsp-android-arm64.tar.xz в кэше устарел" "устаревший кэш качается заново"
cmp -s "$P/lx/fold2-dl/f2qdsp-android-arm64.tar.xz" "$SRV/f2qdsp-android-arm64.tar.xz" && ok "в кэше новый файл" || bad "в кэше старый файл"
fresh; pc "$O" FAKE_NO_NPU=1; eq "$?" 0 "нет NPU в релизе: код 0" "$O"; has "$O" "нет f2qdsp-android-arm64.tar.xz в релизах" "сообщение"
fresh; pc "$O" FAKE_NO_SUMS=1; eq "$?" 0 "нет SHA256SUMS у релиза: код 0" "$O"
has "$O" "нет sha256 f2qdsp-android-arm64.tar.xz в SHA256SUMS релиза" "без суммы - сообщение"
for F in turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz f2qdsp-android-arm64.tar.xz; do
  grep -q "tools-10/$F$" "$P/st/curl.log" && bad "без суммы скачан $F" || ok "без суммы $F не качается"
done
has "$(report)" "NPU: ОШИБКА: нет его sha256 в релизе" "в отчёте - NPU без суммы"; hasnt "$(LOG)" "npu.sh test" "без пакета NPU тест не идёт"
fresh; pc "$O" FAKE_NO_LXCSUM=1; RC=$?
[ "$RC" != 0 ] && grep -qF "нет SHA256SUMS образа Debian" "$O" && ok "нет суммы образа Debian - стоп" || bad "нет суммы образа Debian (rc=$RC)" "$O"
grep -q "rootfs.tar.xz$" "$P/st/curl.log" && bad "образ без суммы скачан" || ok "образ без суммы не качается"
fresh; pc "$O" FAKE_PAGED=1 SKIP_BACKUP=1; eq "$?" 0 "релизов больше 100: код 0" "$O"
has "$P/st/curl.log" "page=2" "релизов больше 100: читается 2-я страница"; hasnt "$P/st/curl.log" "tools-9/" "релизов больше 100: tools-9 не трогается"
has "$P/st/curl.log" "tools-10/f2qdsp-android-arm64.tar.xz" "релизов больше 100: NPU из tools-10 со 2-й страницы"
has "$(report)" "установщик: релиз tools-10" "релизов больше 100: в отчёте tools-10"
fresh; pc "$O" SKIP_BACKUP=1 SKIP_DEBIAN=1 SKIP_NPU=1; eq "$?" 0 "всё пропущено: код 0" "$O"
hasnt "$(LOG)" "backup_efs" "SKIP_BACKUP"; hasnt "$(LOG)" "debian.sh install" "SKIP_DEBIAN"; hasnt "$(LOG)" "npu" "SKIP_NPU"
[ -f "$(report)" ] && ok "отчёт и при пропусках" || bad "нет отчёта"
echo "-- setup_in_chroot.sh: fetch (артефакты из последнего релиза, sha256)"
fresh; FT=$WORK/fetch; rm -rf "$FT"; mkdir -p "$FT"
# функция fetch из setup_in_chroot.sh, /root/ -> временный каталог
FETCH=$(sed -n '/^fetch() {/,/^}/p' "$REPO/linux/phone/setup_in_chroot.sh" | sed "s#/root/#$FT/#g")
ft() { # ft <ассет> [ПЕРЕМЕННАЯ=значение...] - fetch из setup_in_chroot.sh с заглушкой curl
  local A=$1; shift
  env PATH="$FK/pc:$PATH" FAKE_ST="$P/st" FAKE_SRV="$SRV" "$@" bash -c "REPO=o/r; say() { echo \"\$*\"; }; $FETCH
fetch $A" >"$O" 2>&1
}
: >"$P/st/curl.log"; ft llama-debian-arm64.tar.xz; eq "$?" 0 "fetch: код 0" "$O"
cmp -s "$FT/llama-debian-arm64.tar.xz" "$SRV/llama-debian-arm64.tar.xz" && ok "fetch: файл из tools-10" || bad "fetch: не тот файл" "$O"
hasnt "$P/st/curl.log" "tools-9/" "fetch: tools-9 не трогается"; [ -e "$FT/llama-debian-arm64.tar.xz.part" ] && bad "fetch: остался .part" || ok "fetch: без .part"
: >"$P/st/curl.log"; ft llama-debian-arm64.tar.xz; eq "$(grep -c . "$P/st/curl.log")" 0 "fetch: уже скачанный файл не качается"
rm -f "$FT"/*; ft f2qdsp-android-arm64.tar.xz FAKE_BADSUM=1; RC=$?
[ "$RC" = 1 ] && grep -qF "sha256 f2qdsp-android-arm64.tar.xz не совпал" "$O" && ok "fetch: неверная sha256 - отказ" || bad "fetch: неверная sha256 (rc=$RC)" "$O"
[ -z "$(ls "$FT")" ] && ok "fetch: после отказа файлов нет" || bad "fetch: остались файлы: $(ls "$FT")"
rm -f "$FT"/*; ft f2qdsp-android-arm64.tar.xz FAKE_NO_SUMS=1; RC=$?
[ "$RC" = 1 ] && grep -qF "нет sha256 f2qdsp-android-arm64.tar.xz" "$O" && [ -z "$(ls "$FT")" ] && ok "fetch: без суммы - отказ, файлов нет" || bad "fetch: без суммы (rc=$RC)" "$O"
ft f2qdsp-android-arm64.tar.xz FAKE_NO_NPU=1; RC=$?
[ "$RC" = 1 ] && grep -qF "не нашёл f2qdsp-android-arm64.tar.xz" "$O" && ok "fetch: нет в релизах - код 1" || bad "fetch: нет в релизах (rc=$RC)" "$O"
rm -f "$FT"/*; : >"$P/st/curl.log"; ft llama-debian-arm64.tar.xz FAKE_PAGED=1; eq "$?" 0 "fetch: релизов больше 100 - код 0" "$O"
cmp -s "$FT/llama-debian-arm64.tar.xz" "$SRV/llama-debian-arm64.tar.xz" && ok "fetch: релизов больше 100 - файл из tools-10 со 2-й страницы" || bad "fetch: релизов больше 100 - не тот файл" "$O"
has "$P/st/curl.log" "page=2" "fetch: читает 2-ю страницу"; hasnt "$P/st/curl.log" "page=3" "fetch: 3-я не нужна"
rm -f "$FT"/*; ft llama-debian-arm64.tar.xz FAKE_RELS_FAIL=1; RC=$?
[ "$RC" = 1 ] && grep -qF "не получил список релизов" "$O" && ok "fetch: API GitHub не ответил - понятное сообщение, код 1" || bad "fetch: API не ответил (rc=$RC)" "$O"
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
echo "-- старый adb (1.0.32 не передаёт коды выхода) - берётся свежий platform-tools"
fresh; NA=$WORK/oldadb; rm -rf "$NA"; mkdir -p "$NA/pt/platform-tools"
cp "$FK/pc/adb" "$NA/pt/platform-tools/adb"; (cd "$NA/pt" && python3 -m zipfile -c "$SRV/platform-tools-latest-linux.zip" platform-tools)
pc "$O" FAKE_ADB_VER=32 SKIP_DEBIAN=1 SKIP_NPU=1; eq "$?" 0 "старый adb: код 0" "$O"
has "$O" "adb в системе старый (1.0.32)" "старый adb - сообщение"; has "$P/st/curl.log" "platform-tools-latest-linux.zip" "старый adb - скачан свежий"
[ -x "$P/lx/fold2-dl/platform-tools/adb" ] && ok "старый adb - свежий распакован" || bad "старый adb - нет platform-tools/adb" "$O"
rm -f "$SRV/platform-tools-latest-linux.zip"
fresh; pc "$O" FAKE_ADB_VER=39 SKIP_DEBIAN=1 SKIP_NPU=1; hasnt "$O" "adb в системе старый" "adb 1.0.39 - свой, без скачивания"

echo "-- проверка телефона в установщике (check_phone.sh)"
fresh; pc "$O" SKIP_DEBIAN=1 SKIP_NPU=1; eq "$?" 0 "код 0" "$O"
has "$(LOG)" "sh /data/local/tmp/fold2/check_phone.sh" "check_phone.sh запущен через su"
[ -f "$P/st/pushed/check_phone.sh" ] && ok "check_phone.sh скопирован на телефон" || bad "check_phone.sh не скопирован"
has "$O" "   ВНИМАНИЕ  SIM: ABSENT,ABSENT" "проблемы проверки - на экране"; hasnt "$O" "OK        модем" "строки OK на экран не идут"
has "$(report)" "проверка телефона: OK 20, ВНИМАНИЕ 1, НЕТ 0" "отчёт: итог проверки в шапке"
has "$(report)" "--- проверка телефона (check_phone.sh)" "отчёт: раздел проверки"; has "$(report)" "OK        модем: F916BXXS7KXH1" "отчёт: полный вывод"
has "$O" "Проверка телефона: OK 20" "итог в конце"
fresh; pc "$O" SKIP_DEBIAN=1 SKIP_NPU=1 FAKE_CHECK_FAIL=1; eq "$?" 0 "проверка оборвалась - установщик не падает" "$O"
has "$(report)" "проверка телефона: не прошла" "отчёт: проверка не прошла"; has "$(report)" "syntax error" "отчёт: вывод оборвавшейся проверки"
fresh; pc "$O" SKIP_DEBIAN=1 SKIP_NPU=1 SKIP_CHECK=1; hasnt "$(LOG)" "check_phone.sh" "SKIP_CHECK=1 - без проверки"
has "$(report)" "проверка телефона: пропущена (SKIP_CHECK=1)" "SKIP_CHECK=1 - в отчёте"

echo "-- pc_backup_debian.sh: копия Debian на ПК"
bk() { # bk <вывод> [ПЕРЕМЕННАЯ=значение...] [-- аргументы]
  local O=$1; shift; local E=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do E+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  : >"$P/st/log"; : >"$P/st/curl.log"
  env PATH="$FK/pc:$FK:$PATH" HOME="$P/home" FAKE_ST="$P/st" FAKE_SRV="$SRV" FAKE_ROOT="$P/st" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    ${E[@]+"${E[@]}"} bash "$P/lx/pc_backup_debian.sh" "$@" >"$O" 2>&1 </dev/null
}
BKD=$WORK/bk # копии - вне $P: fresh() его стирает
fresh; for F in "$P"/lx/phone/*.sh; do sed -i 's/$/\r/' "$F"; done
bk "$O" FAKE_INSTALLED=1; eq "$?" 0 "копия: код 0" "$O"
BKF=$(ls "$P"/home/fold2-backup/debian-*.tar.gz 2>/dev/null | tail -n 1)
[ -n "$BKF" ] && tar -tzf "$BKF" 2>/dev/null | grep -x debian/etc/passwd >/dev/null && ok "копия на ПК - tar.gz с Debian" || bad "нет копии на ПК" "$O"
[ -n "$BKF" ] && (cd "$P/home/fold2-backup" && sha256sum -c "${BKF##*/}.sha256" >/dev/null 2>&1) && ok "рядом .sha256, сходится" || bad "нет .sha256 или не сходится"
eq "$(stat -c %a "$BKF" 2>/dev/null)" 600 "копия 0600"; eq "$(stat -c %a "$P/home/fold2-backup")" 700 "каталог копий 0700"
ls "$P"/home/fold2-backup/*.part >/dev/null 2>&1 && bad "остался .part" || ok "без .part"
has "$(LOG)" "exec-out su -mm -c 'sh /data/local/tmp/fold2/debian.sh backup - 2>/data/local/tmp/fold2/backup.log; echo \$? >/data/local/tmp/fold2/backup.rc'" "архив - через exec-out, сообщения и код - в файлы на телефоне"
has "$O" "   [fold2] копия готова" "сообщения с телефона на экране"; has "$O" "pc_backup_debian.sh restore $BKF" "подсказка: как вернуть"
grep -q $'\r' "$P/st/pushed/debian.sh" && bad "debian.sh ушёл на телефон с CRLF" || ok "debian.sh на телефон без \\r"
hasnt "$(LOG)" "cp /data/local/tmp/fold2/debian.sh" "установленные скрипты на телефоне не меняются"
has "$(LOG)" "rm -f /data/local/tmp/fold2/backup.rc /data/local/tmp/fold2/backup.log /data/local/tmp/fold2/debian.sh" "за собой убирает"
mkdir -p "$BKD"; cp "$BKF" "$BKF.sha256" "$BKD/"; BKF=$BKD/${BKF##*/}
bk "$O" FAKE_INSTALLED=1 -- models; eq "$?" 0 "копия с моделями: код 0" "$O"; has "$(LOG)" "debian.sh backup - models 2>" "models уходит в debian.sh"
fresh; bk "$O" FAKE_INSTALLED=1 FAKE_BACKUP_RC=1; RC=$?
[ "$RC" != 0 ] && grep -qF "копия на телефоне не получилась" "$O" && grep -qF "не копирую" "$O" && ! ls "$P"/home/fold2-backup/debian-* >/dev/null 2>&1 \
  && ok "ошибка на телефоне - понятная ошибка, файлов на ПК нет" || bad "ошибка backup на телефоне (rc=$RC)" "$O"
fresh; bk "$O" FAKE_INSTALLED=1 FAKE_BACKUP_BROKEN=1; RC=$?
[ "$RC" != 0 ] && grep -qF "копия пришла битой" "$O" && ! ls "$P"/home/fold2-backup/debian-* >/dev/null 2>&1 \
  && ok "оборванный поток - ошибка, битый файл удалён" || bad "оборванный поток (rc=$RC)" "$O"
# Ctrl+C (здесь SIGTERM: фоновому скрипту SIGINT не доставить) - фоновый adb убит, недокачанного файла нет
fresh; bk "$O" FAKE_INSTALLED=1 FAKE_BACKUP_HANG=1 & BKP=$!
for _ in $(seq 1 100); do ls "$P"/home/fold2-backup/*.part >/dev/null 2>&1 && grep -q exec-out "$P/st/log" && break; sleep 0.1; done
sleep 0.3; pkill -TERM -f "$P/lx/pc_backup_debian.sh"; wait "$BKP"; RC=$?
[ "$RC" != 0 ] && grep -qF "прервано - копия не сохранена" "$O" && ! ls "$P"/home/fold2-backup/debian-* >/dev/null 2>&1 \
  && ok "прерванная копия: понятное сообщение, файлов на ПК нет" || bad "прерванная копия (rc=$RC)" "$O"
pgrep -f '^/bin/sleep 61$' >/dev/null && { bad "после прерывания adb остался работать"; pkill -f '^/bin/sleep 61$'; } || ok "после прерывания adb не остался"
fresh; bk "$O"; RC=$?
[ "$RC" != 0 ] && grep -qF "на телефоне нет Debian" "$O" && ok "нет Debian - ошибка" || bad "без Debian (rc=$RC)" "$O"
fresh; bk "$O" FAKE_INSTALLED=1 FAKE_NOROOT=1; RC=$?
[ "$RC" != 0 ] && grep -qF "нет root" "$O" && hasnt "$(LOG)" "exec-out" "без root - не копирует" || bad "без root (rc=$RC)" "$O"
bk "$O" FAKE_INSTALLED=1 -- all; RC=$?
[ "$RC" != 0 ] && grep -qF "непонятный аргумент 'all'" "$O" && ok "неизвестный аргумент - ошибка" || bad "аргумент all (rc=$RC)" "$O"

echo "-- восстановление из копии: pc_backup_debian.sh restore = pc_install_debian.sh с RESTORE"
fresh; bk "$O" FAKE_CONF_USER=bob -- restore "$BKF"; eq "$?" 0 "restore на чистый телефон: код 0" "$O"
has "$(LOG)" "push $BKF /data/local/tmp/fold2/debian-restore.tar.gz" "копия - на телефон"
has "$(LOG)" "sh /data/local/fold2/debian.sh restore /data/local/tmp/fold2/debian-restore.tar.gz; R=\$?; rm -f /data/local/tmp/fold2/debian-restore.tar.gz" "debian.sh restore и копия убирается с телефона"
hasnt "$(LOG)" "debian.sh install" "Debian не ставится заново"; hasnt "$P/st/curl.log" "rootfs.tar.xz" "образ Debian не качается"
hasnt "$P/st/curl.log" "llama-debian-arm64.tar.xz" "пакеты llama/turnip не качаются"
has "$(LOG)" "install -r $P/lx/fold2-dl/termux-x11.apk" "Termux:X11 ставится"; has "$(LOG)" "debian.sh ssh; sh /data/local/fold2/debian.sh autostart on" "ssh и автозапуск"
has "$(LOG)" "npu.sh test" "дальше - как установка (NPU)"; has "$(report)" "Debian: восстановлен из копии ${BKF##*/}" "отчёт: восстановлен"
has "$O" "run passwd bob" "подсказки - для пользователя из копии"
fresh; pc "$O" FAKE_INSTALLED=1 RESTORE="$BKF"; RC=$?
[ "$RC" != 0 ] && grep -qF "на телефоне уже есть Debian" "$O" && hasnt "$(LOG)" "debian-restore.tar.gz" "Debian уже есть - отказ, копия не копируется" || bad "restore поверх (rc=$RC)" "$O"
fresh; pc "$O" FAKE_FREE_KB=1000 RESTORE="$BKF"; RC=$?
[ "$RC" != 0 ] && grep -qF "на телефоне мало места" "$O" && hasnt "$(LOG)" "debian-restore.tar.gz" "мало места - отказ до копирования" || bad "мало места (rc=$RC)" "$O"
fresh; pc "$O" FAKE_RESTORE_RC=1 RESTORE="$BKF"; RC=$?
[ "$RC" != 0 ] && grep -qF "Debian из копии не восстановился" "$O" && ok "restore на телефоне не удался - ошибка" || bad "сбой restore (rc=$RC)" "$O"
cp "$BKF" "$BKD/bad.tar.gz"; echo "0000  bad.tar.gz" >"$BKD/bad.tar.gz.sha256"
fresh; pc "$O" RESTORE="$BKD/bad.tar.gz"; RC=$?
[ "$RC" != 0 ] && grep -qF "sha256 не совпадает" "$O" && eq "$(grep -c . "$(LOG)")" 0 "копия не сошлась с .sha256 - отказ до телефона" || bad "sha256 копии (rc=$RC)" "$O"
mkdir -p "$BKD/x/stuff"; echo x >"$BKD/x/stuff/a"; tar -czf "$BKD/other.tar.gz" -C "$BKD/x" stuff
fresh; pc "$O" RESTORE="$BKD/other.tar.gz"; RC=$?
[ "$RC" != 0 ] && grep -qF "не копия Debian" "$O" && ok "не копия Debian - отказ" || bad "чужой архив (rc=$RC)" "$O"
head -c 100 "$BKF" >"$BKD/cut.tar.gz"; fresh; pc "$O" RESTORE="$BKD/cut.tar.gz"; RC=$?
[ "$RC" != 0 ] && grep -qF "битая" "$O" && ok "обрезанная копия - отказ" || bad "обрезанная копия (rc=$RC)" "$O"
fresh; pc "$O" RESTORE="$BKD/nope.tar.gz"; RC=$?
[ "$RC" != 0 ] && grep -qF "нет такого файла" "$O" && ok "нет файла копии - ошибка" || bad "нет файла копии (rc=$RC)" "$O"
fresh; bk "$O" -- restore; RC=$?
[ "$RC" != 0 ] && grep -qF "какую копию" "$O" && ok "restore без файла - подсказка" || bad "restore без файла (rc=$RC)" "$O"

echo "-- pc_check_phone.sh: только проверка, root не обязателен"
chk() { # chk <вывод> [ПЕРЕМЕННАЯ=значение...]
  local O=$1; shift; : >"$P/st/log"
  env PATH="$FK/pc:$FK:$PATH" HOME="$P/home" FAKE_ST="$P/st" FAKE_ROOT="$P/st" LANG=C.UTF-8 "$@" bash "$P/lx/pc_check_phone.sh" >"$O" 2>&1 </dev/null
}
fresh; for F in "$P"/lx/phone/*.sh; do sed -i 's/$/\r/' "$F"; done
chk "$O"; eq "$?" 0 "код 0" "$O"; has "$O" "ИТОГ: OK 20, ВНИМАНИЕ 1, НЕТ 0" "итог на экране"
has "$O" "ВНИМАНИЕ  SIM: ABSENT,ABSENT" "строки итога на экране"; hasnt "$O" "ПОДРОБНОСТИ" "подробности - только в файле"
has "$(LOG)" "su -c 'sh /data/local/tmp/check_phone.sh'" "с root - через su"; has "$(LOG)" "rm -f /data/local/tmp/check_phone.sh" "скрипт убран с телефона"
CF=$(ls "$P"/lx/fold2-check-*.txt 2>/dev/null | tail -n 1)
[ -n "$CF" ] && grep -qF -- "--- связь" "$CF" && ok "отчёт fold2-check-*.txt рядом со скриптом" || bad "нет отчёта fold2-check" "$O"
[ -n "$CF" ] && ! grep -q $'\r' "$CF" && ok "отчёт без \\r" || bad "в отчёте \\r"
grep -q $'\r' "$P/st/pushed/check_phone.sh" && bad "check_phone.sh ушёл на телефон с CRLF" || ok "check_phone.sh на телефон без \\r"
fresh; chk "$O" FAKE_NOROOT=1; eq "$?" 0 "без root: код 0" "$O"; has "$O" "root нет" "без root: предупреждение"
has "$(LOG)" "shell sh /data/local/tmp/check_phone.sh" "без root - обычным sh"; hasnt "$(LOG)" "su -c 'sh" "без root - не через su"
fresh; chk "$O" FAKE_CHECK_FAIL=1; RC=$?
[ "$RC" != 0 ] && grep -qF "проверка не дошла до конца" "$O" && ok "оборвавшаяся проверка - понятная ошибка" || bad "оборвавшаяся проверка (rc=$RC)" "$O"
fresh; chk "$O" FAKE_STATE=1 FAKE_DEVSTATE=unauthorized; RC=$?
[ "$RC" != 0 ] && grep -qF "не разрешил отладку" "$O" && ok "unauthorized - понятная ошибка" || bad "unauthorized (rc=$RC)" "$O"
fresh; chk "$O" FAKE_STATE=1 FAKE_DEVICES=0; RC=$?
[ "$RC" != 0 ] && grep -qF "телефон не виден в adb" "$O" && ok "нет телефона - понятная ошибка" || bad "нет телефона (rc=$RC)" "$O"
finish "установщик с ПК"
