#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1091,SC2016  # A && ok || bad: ok/bad всегда успешны
# Сквозная проверка debian.sh на настоящем arm64 Linux с root (CI: ubuntu-24.04-arm, не в контейнере): тот же образ
# Debian trixie, что ставит pc_install_debian.sh, тот же каталог /data/local/fold2, /system/bin/sh = mksh (как на
# Android), /data/adb/magisk/busybox = busybox. Проверяет: install (setup_in_chroot.sh с настоящим apt и пакетами
# turnip/llama из этой же сборки), вход по ssh (ключ, sudo), llama-server (крошечная модель, ключ API), status,
# stop (ничего не осталось смонтированным и запущенным), повторные start/stop, продолжение оборванной установки
# (install без rootfs), автозапуск так, как его выполняет Magisk (busybox ash standalone) - поднимает Debian и sshd,
# remove (удаляет Debian, только размонтировав всё внутри: смонтированные туда файлы целы).
# Ядро и SELinux здесь не телефонные: это проверка скриптов и пакетов, а не Android.
#   sudo bash linux/test/e2e_chroot.sh [каталог с turnip-*.tar.xz и llama-debian-*.tar.xz]   (MODEL_URL= - модель)
set -uo pipefail
TD=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$TD/../.." && pwd)
. "$TD/lib.sh"
[ "$(id -u)" = 0 ] || { echo "нужен root (sudo)"; exit 2; }
[ "$(uname -m)" = aarch64 ] || { echo "нужен arm64 (aarch64), здесь $(uname -m)"; exit 2; }
ART=${1:-}
MODEL_URL=${MODEL_URL:-https://huggingface.co/ggml-org/models/resolve/main/tinyllamas/stories15M-q4_0.gguf}
LXC=https://images.linuxcontainers.org/images/debian/trixie/arm64/default
B=/data/local/fold2; R=$B/debian; O=/tmp/e2e-out; U=fold2
MKSH=$(command -v mksh) || { echo "нужен mksh"; exit 2; }
BUSYBOX=$(command -v busybox) || { echo "нужен busybox"; exit 2; }
[ -e "$R" ] && { echo "$R уже есть - запускай на чистой машине"; exit 2; }
mkdir -p /data/adb/magisk "$B" /system/bin
cp "$BUSYBOX" /data/adb/magisk/busybox
[ -e /system/bin/sh ] || ln -s "$MKSH" /system/bin/sh
cp "$REPO/linux/phone/debian.sh" "$REPO/linux/phone/setup_in_chroot.sh" "$B/"
[ -n "$ART" ] && cp "$ART"/turnip-*.tar.xz "$ART"/llama-debian-*.tar.xz "$B/"
dsh() { /system/bin/sh "$B/debian.sh" "$@"; } # как на телефоне: sh (mksh) debian.sh
mounts() { awk -v r="$R" '$2==r || index($2, r "/")==1' /proc/mounts; }
procs() { for P in /proc/[0-9]*; do case "$(readlink "$P/root" 2>/dev/null)" in "$R"|"$R"/*) echo "${P#/proc/}" ;; esac; done; }
stopped() { # stopped <что> - после stop: ни монтирований, ни процессов в chroot
  [ -z "$(mounts)" ] && ok "$1: монтирований не осталось" || bad "$1: остались монтирования: $(mounts | awk '{print $2}' | tr '\n' ' ')"
  [ -z "$(procs)" ] && ok "$1: процессов не осталось" || bad "$1: остались процессы: $(procs | tr '\n' ' ')"
}
cleanup() { dsh stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "-- образ Debian (как pc_install_debian.sh)"
DIR=$(curl -fsSL "$LXC/" | grep -o 'href="[0-9]\{8\}_[^"/]*/"' | tail -n1 | cut -d'"' -f2)
[ -n "$DIR" ] || { echo "не нашёл образ на images.linuxcontainers.org"; exit 1; }
curl -fsSL --retry 3 -o /tmp/rootfs.tar.xz "$LXC/${DIR}rootfs.tar.xz" || { echo "не скачался rootfs"; exit 1; }
WANT=$(curl -fsSL "$LXC/${DIR}SHA256SUMS" | awk '$2=="rootfs.tar.xz"{print $1}')
echo "$WANT  /tmp/rootfs.tar.xz" | sha256sum -c - >/dev/null && ok "rootfs $DIR, sha256 совпал" || { bad "sha256 rootfs"; exit 1; }

echo "-- debian.sh install"
dsh install /tmp/rootfs.tar.xz "$U" >"$O" 2>&1; RC=$?; tail -n 25 "$O"
[ "$RC" = 0 ] && ok "install: код 0" || { bad "install: код $RC" "$O"; finish "e2e chroot"; exit 1; }
has "$O" "[fold2/debian] готово" "setup_in_chroot.sh дошёл до конца"
[ -f "$R/etc/fold2-setup.done" ] && ok "отметка: настройка закончена" || bad "нет $R/etc/fold2-setup.done"
eq "$(dsh run id -u "$U" 2>&1)" 8000 "UID пользователя 8000 (вне системных UID Android)"
eq "$(dsh run id -nG "$U" 2>&1 | tr ' ' '\n' | grep -cxE 'sudo|docker|aid_inet|aid_media_rw|aid_everybody')" 5 "группы sudo, docker, aid_*"
dsh run dpkg-query -W -f='${Status}\n' openssh-server xfce4 docker.io firefox-esr build-essential vulkan-tools >"$O" 2>&1
eq "$(grep -c 'install ok installed' "$O")" 6 "пакеты стоят" "$O"
dsh run /opt/llama.cpp/bin/llama-server --version >"$O" 2>&1 && ok "llama-server запускается в Debian" || bad "llama-server --version" "$O"
if [ -n "$ART" ]; then
  dsh run test -f /opt/turnip/share/vulkan/icd.d/freedreno_icd.aarch64.json && ok "Turnip распакован" || bad "нет Turnip"
  dsh run test -x /usr/local/bin/zink && ok "zink" || bad "нет /usr/local/bin/zink"
fi
has "$B/debian.conf" "BATT_LIMIT=" "debian.conf создан"
has "$R/etc/default/locale" "LANG=ru_RU.UTF-8" "язык рабочего стола - русский"
eq "$(dsh run su -l "$U" -c 'locale' 2>&1 | grep '^LANG=')" "LANG=ru_RU.UTF-8" "su -l (как x11) берёт LANG из /etc/default/locale"
dsh install /tmp/rootfs.tar.xz >"$O" 2>&1; RC=$?
[ "$RC" != 0 ] && grep -qF "уже установлено" "$O" && ok "повторный install отказывает" || bad "повторный install (rc=$RC)" "$O"

echo "-- ssh"
rm -f /tmp/e2e_key /tmp/e2e_key.pub; ssh-keygen -q -t ed25519 -N '' -f /tmp/e2e_key
install -d -m 700 -o 8000 -g 8000 "$R/home/$U/.ssh"; install -m 600 -o 8000 -g 8000 /tmp/e2e_key.pub "$R/home/$U/.ssh/authorized_keys"
dsh ssh >"$O" 2>&1; has "$O" "sshd на порту 2222" "sshd запущен"
S=""; for _ in $(seq 1 20); do
  S=$(ssh -p 2222 -i /tmp/e2e_key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$U@127.0.0.1" 'id -un; sudo -n true && echo sudo-ok' 2>/tmp/e2e-ssh.err) && break; sleep 1
done
eq "$(echo "$S" | tr '\n' ' ')" "$U sudo-ok " "вход по ssh по ключу, sudo без пароля" /tmp/e2e-ssh.err
dsh ssh >"$O" 2>&1; has "$O" "уже работает" "повторный ssh не запускает второй sshd"

echo "-- llama-server (крошечная модель, ключ API)"
curl -fsSL --retry 3 -o "$R/opt/e2e.gguf" "$MODEL_URL" || bad "модель не скачалась"
{ echo "LLAMA_MODEL=/opt/e2e.gguf"; echo "LLAMA_API_KEY=e2e-secret"; echo "LLAMA_THREADS=2"; echo "LLAMA_CTX=512"; echo "LLAMA_CPUS=0-1"; } >>"$B/debian.conf"
dsh llama >"$O" 2>&1; has "$O" "llama-server запускается" "llama запущен"
H=""; for _ in $(seq 1 90); do H=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health); [ "$H" = 200 ] && break; sleep 1; done
eq "$H" 200 "llama-server отвечает (/health)" "$R/var/log/llama-server.log"
REQ='{"prompt":"Once upon a time","n_predict":8}'
eq "$(curl -s -o /dev/null -w '%{http_code}' -d "$REQ" http://127.0.0.1:8080/completion)" 401 "без ключа - 401"
curl -s -H 'Authorization: Bearer e2e-secret' -d "$REQ" http://127.0.0.1:8080/completion >"$O"
has "$O" '"content"' "с ключом - ответ модели"
# shellcheck disable=SC2009
ps -eo args | grep -v grep | grep -q e2e-secret && bad "ключ виден в ps" || ok "ключа нет в командной строке (ps)"
eq "$(stat -c %a "$R/run/llama-api-key")" 600 "файл ключа 0600"
dsh status >"$O" 2>&1; eq "$?" 0 "status: код 0" "$O"
has "$O" "sshd: работает" "status: sshd"; has "$O" "llama-server: работает" "status: llama-server"
has "$O" "настройка Debian: закончена" "status: настройка закончена"
dsh llama stop >"$O" 2>&1; has "$O" "llama-server остановлен" "llama stop"

echo "-- stop / start"
dsh stop >"$O" 2>&1; has "$O" "остановлено" "stop"; stopped "stop"
dsh start >"$O" 2>&1; has "$O" "Debian смонтирован" "start"; dsh start >/dev/null 2>&1
eq "$(mounts | awk '{print $2}' | sort | uniq -d | grep -c .)" 0 "повторный start не монтирует второй раз"
dsh stop >/dev/null 2>&1; stopped "второй stop"

echo "-- оборванная установка: install без rootfs продолжает настройку (setup_in_chroot.sh можно повторять)"
rm -f "$R/etc/fold2-setup.done"
# обрыв посреди dpkg (телефон перезагрузился): пакет nano "half-configured" в журнале dpkg - apt-get без
# dpkg --configure -a отказался бы работать ("dpkg was interrupted")
awk -v RS= -v ORS='\n\n' '/^Package: nano\n/' "$R/var/lib/dpkg/status" |
  sed 's/^Status: .*/Status: install ok half-configured/' >"$R/var/lib/dpkg/updates/0000"
dsh status >"$O" 2>&1; has "$O" "настройка Debian: НЕ закончена" "status: настройка не закончена"
dsh install - "$U" >"$O" 2>&1; RC=$?; tail -n 5 "$O"
eq "$RC" 0 "продолжение установки: код 0" "$O"; has "$O" "настройка не закончена - продолжаю" "install продолжает, а не распаковывает"
[ -f "$R/etc/fold2-setup.done" ] && ok "после продолжения отметка снова есть" || bad "нет отметки после продолжения"
eq "$(dsh run dpkg-query -W -f='${Status}' nano 2>&1)" "install ok installed" "оборванный dpkg доделан (nano настроен)"
eq "$(find "$R/var/lib/dpkg/updates" -mindepth 1 | grep -c .)" 0 "журнал dpkg пуст"
eq "$(dsh run id -u "$U" 2>&1)" 8000 "пользователь тот же"
dsh stop >/dev/null 2>&1; stopped "stop после продолжения установки"

echo "-- autostart"
dsh autostart on >"$O" 2>&1; has "$O" "автозапуск включён" "autostart on"
[ -x /data/adb/modules/fold2/action.sh ] && ok "кнопка в Magisk: action.sh" || bad "нет /data/adb/modules/fold2/action.sh"
has /data/adb/modules/fold2/module.prop "id=fold2" "кнопка в Magisk: module.prop"
"$BUSYBOX" sh -n /data/adb/modules/fold2/action.sh && ok "action.sh без синтаксических ошибок" || bad "синтаксис action.sh"
"$MKSH" -n /data/adb/service.d/fold2-debian.sh && ok "скрипт автозапуска без синтаксических ошибок (mksh)" || bad "синтаксис автозапуска"
"$BUSYBOX" sh -n /data/adb/service.d/fold2-debian.sh && ok "то же в busybox ash" || bad "синтаксис автозапуска (ash)"
# как Magisk: service.d-скрипт выполняет busybox ash в режиме standalone (applets busybox вместо системных mount/chroot/...),
# busybox-static из Ubuntu собран так же. getprop - заглушка "загрузка завершена"
printf '#!/bin/sh\n[ "$1" = sys.boot_completed ] && echo 1\nexit 0\n' >/usr/local/bin/getprop; chmod 755 /usr/local/bin/getprop
timeout 180 /data/adb/magisk/busybox sh /data/adb/service.d/fold2-debian.sh; RC=$?
eq "$RC" 0 "автозапуск (busybox ash standalone, как Magisk): код 0" "$B/autostart.log"
has "$B/autostart.log" "sshd на порту 2222" "автозапуск поднял sshd"
S=$(ssh -p 2222 -i /tmp/e2e_key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$U@127.0.0.1" 'id -un' 2>/tmp/e2e-ssh.err)
eq "$S" "$U" "после автозапуска вход по ssh" /tmp/e2e-ssh.err
ls -d "$B"/bootlogs/*-* >/dev/null 2>&1 && ok "автозапуск собрал bootlog" || bad "нет bootlogs" "$B/autostart.log"
rm -f /usr/local/bin/getprop
dsh stop >/dev/null 2>&1; stopped "stop после автозапуска"
dsh autostart off >/dev/null 2>&1; [ ! -e /data/adb/service.d/fold2-debian.sh ] && ok "autostart off" || bad "autostart off"

echo "-- remove: Debian удаляется только после того, как внутри всё размонтировано"
dsh remove >"$O" 2>&1; eq "$?" 2 "remove без yes: код 2" "$O"; [ -x "$R/bin/sh" ] && ok "remove без yes: Debian на месте" || bad "remove без yes удалил Debian"
# «файлы телефона», смонтированные внутрь, как /sdcard (/data/media/0): rm -rf по ним прошёлся бы, если не размонтировать
mkdir -p /tmp/e2e-media "$R/sdcard"; echo keep >/tmp/e2e-media/photo.jpg
dsh autostart on >/dev/null 2>&1; dsh start >/dev/null 2>&1; mount --bind /tmp/e2e-media "$R/sdcard"
dsh remove yes >"$O" 2>&1; RC=$?; tail -n 5 "$O"
eq "$RC" 0 "remove yes: код 0" "$O"; [ ! -e "$R" ] && ok "remove yes: $R удалён" || bad "remove yes: $R остался"
eq "$(cat /tmp/e2e-media/photo.jpg 2>/dev/null)" keep "файлы, смонтированные внутрь (как /sdcard), целы"
[ ! -e /data/adb/service.d/fold2-debian.sh ] && ok "remove выключил автозапуск" || bad "remove: автозапуск остался"
[ ! -e /data/adb/modules/fold2 ] && ok "remove убрал кнопку в Magisk" || bad "remove: кнопка осталась"
[ -f "$B/debian.conf" ] && ok "remove: debian.conf остался" || bad "remove удалил debian.conf"
eq "$(mounts | grep -c .)" 0 "после remove монтирований нет"
finish "e2e chroot"
