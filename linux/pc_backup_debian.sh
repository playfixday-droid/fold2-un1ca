#!/usr/bin/env bash
# fold2: копия Debian с телефона на ПК по USB и возврат её на телефон (Linux/macOS/WSL/Git Bash). Нужен root (Magisk).
#   bash pc_backup_debian.sh [models]         -> ~/fold2-backup/debian-<время>.tar.gz и .sha256 (BACKUP_DIR=каталог)
#     Debian на время копии останавливается, потом запускается снова то, что работало (ssh, рабочий стол...).
#     Не входят: Docker (образы, контейнеры, тома - /var/lib/docker), кэш apt, /tmp, модели llama (/var/lib/llama -
#     скачаются заново; models - вместе с ними)
#   bash pc_backup_debian.sh restore <файл>   -> вернуть Debian на телефон, в том числе после перепрошивки с очисткой
#     данных: это pc_install_debian.sh с RESTORE=<файл> - он доведёт root, поставит Termux:X11, NPU, автозапуск.
#     Debian на телефоне быть не должно (убрать: su -mm -c "sh /data/local/fold2/debian.sh remove yes")
# В копии пароли (/etc/shadow), ключи ssh и домашние каталоги - храни её у себя, никому не отправляй.
set -euo pipefail
export MSYS2_ARG_CONV_EXCL="/data/;/sdcard/" # Git Bash не должен переделывать пути телефона
HERE=$(cd "$(dirname "$0")" && pwd)
say() { echo "== $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }
if [ "${1:-}" = restore ]; then
  [ -n "${2:-}" ] || die "какую копию: bash $0 restore <debian-*.tar.gz>"
  [ -f "$2" ] || die "нет файла $2"
  F=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2
  RESTORE=$F exec bash "$HERE/pc_install_debian.sh" "$@"
fi
case "${1:-}" in ""|models) ;; *) die "непонятный аргумент '$1'. Копия: bash $0 [models]; вернуть: bash $0 restore <файл>" ;; esac
MODELS=${1:-}
FD=/data/local/fold2; T=/data/local/tmp/fold2
BK=${BACKUP_DIR:-$HOME/fold2-backup}
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
asu() { adb shell "su -mm -c '$*'"; }
if ! command -v adb >/dev/null; then
  if [ -f "$HERE/fold2-dl/platform-tools/adb" ] || [ -f "$HERE/fold2-dl/platform-tools/adb.exe" ]; then
    PATH="$HERE/fold2-dl/platform-tools:$PATH"
  else die "нет adb: поставь Android platform-tools (https://developer.android.com/tools/releases/platform-tools) или запусти pc_install_debian.sh - он скачает их сам"; fi
fi
if ! adb get-state >/dev/null 2>&1; then
  DEVS=$(adb devices 2>/dev/null | tail -n +2 | tr -d '\r') || DEVS=""
  case "$DEVS" in
    *unauthorized*) die "телефон не разрешил отладку этому ПК: на экране телефона нажми «Разрешить» (с галочкой «Всегда»)" ;;
    *offline*) die "телефон в adb «offline»: переподключи кабель и разреши отладку на телефоне" ;;
  esac
  ND=$(echo "$DEVS" | grep -c "$(printf '\t')device\$" || true)
  [ "$ND" -gt 1 ] && die "подключено несколько устройств ($ND): оставь один или укажи ANDROID_SERIAL=<серийник>"
  die "телефон не виден в adb: включи «Отладка по USB» (Настройки -> Параметры разработчика) и подключи кабель с данными"
fi
case "$(asu id 2>/dev/null | tr -d '\r' || true)" in
  *uid=0*) ;;
  *) die "нет root: подтверди запрос Magisk на телефоне (Magisk -> Суперпользователь -> Shell) или запусти pc_install_debian.sh - он доведёт root" ;;
esac
[ "$(asu "test -x $FD/debian/bin/sh && echo yes" 2>/dev/null | tr -d '\r' || true)" = yes ] || die "на телефоне нет Debian ($FD/debian) - копировать нечего"

# debian.sh - свежий (в старом на телефоне может не быть backup), без \r; запускается из временного каталога,
# установленные скрипты не меняются
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
tr -d '\r' <"$HERE/phone/debian.sh" >"$TMP/debian.sh"
{ adb shell "mkdir -p $T" >/dev/null && adb push "$TMP/debian.sh" "$T/" >/dev/null; } || die "не скопировался debian.sh на телефон"
mkdir -p "$BK"; chmod 700 "$BK" 2>/dev/null || true
OUT=$BK/debian-$(date +%Y%m%d-%H%M%S).tar.gz
say "копия Debian -> $OUT (Debian на время остановится; минуты - сколько займёт, зависит от размера)"
asu "rm -f $T/backup.rc $T/backup.log" >/dev/null 2>&1 || true
# архив - в stdout (exec-out не портит двоичные данные), сообщения - в файл на телефоне: stderr exec-out смешал бы с
# архивом. Код выхода exec-out не передаёт - он тоже в файле
umask 077
adb exec-out "su -mm -c 'sh $T/debian.sh backup -${MODELS:+ $MODELS} 2>$T/backup.log; echo \$? >$T/backup.rc'" >"$OUT.part" &
PID=$!
if [ -t 1 ]; then
  while kill -0 "$PID" 2>/dev/null; do printf '\r   получено %s МБ ' "$(($(wc -c <"$OUT.part") / 1048576))"; sleep 5; done; echo
fi
wait "$PID" || true
RC=$(asu "cat $T/backup.rc" 2>/dev/null | tr -d '\r' || true)
asu "cat $T/backup.log" 2>/dev/null | tr -d '\r' | sed 's/^/   /' || true
asu "rm -f $T/backup.rc $T/backup.log $T/debian.sh" >/dev/null 2>&1 || true
[ "$RC" = 0 ] || { rm -f "$OUT.part"; die "копия на телефоне не получилась (код ${RC:-?}, сообщения выше)"; }
say "проверяю копию"
tar -tzf "$OUT.part" >"$TMP/list" 2>"$TMP/err" || { rm -f "$OUT.part"; die "копия пришла битой ($(head -n 2 "$TMP/err" | tr '\n' ' ')) - запусти ещё раз"; }
grep -qx 'debian/etc/passwd' "$TMP/list" || { rm -f "$OUT.part"; die "в копии нет Debian (debian/etc/passwd)"; }
mv "$OUT.part" "$OUT"
echo "$(sha "$OUT")  ${OUT##*/}" >"$OUT.sha256"
say "готово: $OUT ($(($(wc -c <"$OUT") / 1048576)) МБ, файлов $(wc -l <"$TMP/list" | tr -d ' ')), sha256 - в ${OUT##*/}.sha256"
echo "Вернуть (и после перепрошивки с очисткой данных): bash $0 restore $OUT"
echo "В копии пароли, ключи ssh и домашние каталоги - храни её у себя, никому не отправляй."
