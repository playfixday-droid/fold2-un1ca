#!/usr/bin/env bash
# fold2: проверка телефона после прошивки f2q - с ПК по USB (Linux/macOS/WSL/Git Bash). Root не обязателен: сразу после
# первой загрузки, ещё до Magisk, тоже можно (с root - подробнее). Ничего на телефоне не меняет.
#   bash pc_check_phone.sh   -> ИТОГ на экране и отчёт fold2-check-<время>.txt рядом со скриптом
# Что проверяется - в начале phone/check_phone.sh. IMEI, серийных номеров, MAC и имени сети Wi-Fi в отчёте нет - его можно
# присылать. adb: из PATH или скачанный pc_install_debian.sh (fold2-dl/platform-tools).
set -euo pipefail
export MSYS2_ARG_CONV_EXCL="/data/;/sdcard/" # Git Bash не должен переделывать пути телефона
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/fold2-check-$(date +%Y%m%d-%H%M%S).txt
PT=/data/local/tmp/check_phone.sh
die() { echo "ОШИБКА: $*" >&2; exit 1; }
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
# без \r: если репозиторий скачан в Windows с CRLF, sh на телефоне скрипт не выполнит
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
tr -d '\r' <"$HERE/phone/check_phone.sh" >"$TMP/check_phone.sh"
adb push "$TMP/check_phone.sh" "$PT" >/dev/null || die "не скопировался check_phone.sh на телефон"
RUN="sh $PT"
case "$(adb shell "su -c id" 2>/dev/null | tr -d '\r' || true)" in
  *uid=0*) RUN="su -c 'sh $PT'" ;;
  *) echo "== root нет (Magisk не стоит или не разрешил Shell) - проверка без root, неполная" ;;
esac
echo "== проверка телефона (до минуты)"
adb shell "$RUN" 2>&1 | tr -d '\r' >"$OUT" || true
adb shell "rm -f $PT" >/dev/null 2>&1 || true
grep -q '^ИТОГ:' "$OUT" || { cat "$OUT"; die "проверка не дошла до конца (вывод выше, он же в $OUT)"; }
sed -n '1,/^$/p' "$OUT"
echo "Отчёт: $OUT - его можно прислать разработчику (IMEI, серийных номеров и MAC в нём нет)."
