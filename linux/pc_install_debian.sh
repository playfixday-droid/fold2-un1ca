#!/usr/bin/env bash
# fold2: установка Debian 13 + XFCE/Docker/Vulkan/llama.cpp и пакета NPU на Fold2 с ПК (Linux/macOS/WSL/Git Bash).
# Нужно: прошивка f2q с root (Magisk), USB-отладка, adb в PATH, интернет на ПК и телефоне.
#   bash pc_install_debian.sh [пользователь]          - всё сразу (Debian, Termux:X11, NPU, модель для NPU)
#   SKIP_DEBIAN=1 / SKIP_NPU=1 / SKIP_MODEL=1          - пропустить часть
# При первом "su" на внешнем экране телефона появится запрос Magisk - разреши Shell.
set -euo pipefail
U=${1:-fold2}
REPO=playfixday-droid/fold2-un1ca
LXC=https://images.linuxcontainers.org/images/debian/trixie/arm64/default
NPU_MODEL_URL=${NPU_MODEL_URL:-https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_0.gguf}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${WORK:-$HERE/fold2-dl}
T=/data/local/tmp/fold2
mkdir -p "$W"
say() { echo "== $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
asu() { adb shell "su -mm -c '$*'"; }

command -v adb >/dev/null || die "нет adb (platform-tools)"
command -v curl >/dev/null || die "нет curl"
adb get-state >/dev/null 2>&1 || die "телефон не виден в adb (USB-отладка, разрешить ПК на внешнем экране)"
say "проверка root (подтверди запрос Magisk на телефоне)"
asu id | grep -q "uid=0" || die "su не дал root: открой Magisk -> Суперпользователь -> разреши Shell"

say "релиз tools-N в $REPO"
REL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30")
asset() { echo "$REL" | grep -o "https://[^\"]*/tools-[0-9]*/$1" | head -n1; }
get() { # get <url> <файл>
  [ -s "$W/$2" ] && return 0
  say "скачиваю $2"; curl -fL --retry 3 -o "$W/$2.part" "$1" && mv "$W/$2.part" "$W/$2"
}
adb shell "mkdir -p $T"

if [ "${SKIP_DEBIAN:-0}" != 1 ]; then
  D=$(curl -fsSL "$LXC/" | grep -o 'href="[0-9]\{8\}_[^"/]*/"' | tail -n1 | cut -d'"' -f2)
  [ -n "$D" ] || die "не нашёл образ Debian trixie arm64 на images.linuxcontainers.org"
  get "$LXC/${D}rootfs.tar.xz" rootfs.tar.xz
  WANT=$(curl -fsSL "$LXC/${D}SHA256SUMS" | awk '$2=="rootfs.tar.xz"{print $1}')
  if [ -n "$WANT" ] && [ "$(sha "$W/rootfs.tar.xz")" != "$WANT" ]; then rm -f "$W/rootfs.tar.xz"; die "sha256 rootfs не совпал, запусти ещё раз"; fi
  for A in turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz; do
    URL=$(asset "$A"); if [ -n "$URL" ]; then get "$URL" "$A"; else say "нет $A в релизах (setup соберёт/скачает сам)"; fi
  done
  XURL=$(curl -fsSL "https://api.github.com/repos/termux/termux-x11/releases/tags/nightly" | grep -o 'https://[^"]*termux-x11-universal-debug.apk' | head -n1)
  [ -n "$XURL" ] && get "$XURL" termux-x11.apk
  say "копирую на телефон"
  adb push "$HERE/phone/debian.sh" "$HERE/phone/setup_in_chroot.sh" "$T/"
  for F in rootfs.tar.xz turnip-kgsl-debian13-arm64.tar.xz llama-debian-arm64.tar.xz; do [ -f "$W/$F" ] && adb push "$W/$F" "$T/"; done
  [ -f "$W/termux-x11.apk" ] && { say "ставлю Termux:X11"; adb install -r "$W/termux-x11.apk" || say "Termux:X11 не встал - поставь apk вручную"; }
  asu "mkdir -p /data/local/fold2 && cp $T/debian.sh $T/setup_in_chroot.sh /data/local/fold2/ && for f in $T/*.tar.xz; do mv \$f /data/local/fold2/; done"
  say "установка Debian на телефоне (лог: /data/local/fold2/install.log), 10-30 минут"
  asu "sh /data/local/fold2/debian.sh install /data/local/fold2/rootfs.tar.xz $U 2>&1 | tee /data/local/fold2/install.log"
  asu "rm -f /data/local/fold2/rootfs.tar.xz; sh /data/local/fold2/debian.sh ssh; sh /data/local/fold2/debian.sh autostart on"
fi

if [ "${SKIP_NPU:-0}" != 1 ]; then
  URL=$(asset f2qdsp-android-arm64.tar.xz)
  if [ -n "$URL" ]; then
    get "$URL" f2qdsp-android-arm64.tar.xz
    adb push "$W/f2qdsp-android-arm64.tar.xz" "$T/"
    asu "mkdir -p /data/local/tmp/fold2-npu && /data/adb/magisk/busybox tar -xJf $T/f2qdsp-android-arm64.tar.xz -C /data/local/tmp/fold2-npu && rm $T/f2qdsp-android-arm64.tar.xz"
    if [ "${SKIP_MODEL:-0}" != 1 ]; then
      get "$NPU_MODEL_URL" "$(basename "$NPU_MODEL_URL")"
      adb shell "mkdir -p /sdcard/models" && adb push "$W/$(basename "$NPU_MODEL_URL")" /sdcard/models/
    fi
    say "проверка NPU (cDSP):"
    asu "sh /data/local/tmp/fold2-npu/npu.sh test" || say "тест NPU не прошёл - пришли вывод выше"
  else
    say "нет f2qdsp-android-arm64.tar.xz в релизах"
  fi
fi

IP=$(adb shell "ip -4 addr show wlan0" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)
cat <<M
Готово.
  Войти:        adb shell  ->  su -mm -c "sh /data/local/fold2/debian.sh shell"
  Пароль:       su -mm -c "sh /data/local/fold2/debian.sh run passwd $U"   (потом ssh -p 2222 $U@${IP:-<IP>})
  XFCE:         su -mm -c "sh /data/local/fold2/debian.sh x11"
  Docker:       su -mm -c "sh /data/local/fold2/debian.sh docker"
  llama.cpp:    su -mm -c "sh /data/local/fold2/debian.sh llama"     -> http://${IP:-<IP>}:8080
  NPU llama:    su -mm -c "sh /data/local/tmp/fold2-npu/npu.sh server" -> http://${IP:-<IP>}:8081
M
