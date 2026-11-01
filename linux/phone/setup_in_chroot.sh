#!/bin/bash
# fold2: настройка Debian 13 внутри chroot (запускает debian.sh install; можно повторять).
# XFCE (для Termux:X11), Docker, Vulkan (Turnip для Adreno 650 через KGSL), llama.cpp, ssh, сборочные пакеты.
set -euo pipefail
U=${1:-fold2}
REPO=playfixday-droid/fold2-un1ca
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
say() { echo "[fold2/debian] $*"; }

# Группы Android. aid_inet/aid_net_raw нужны ядрам с paranoid network (в ядре f2q 4.19 его нет: сокеты режет
# eBPF netd только для UID приложений) - оставлены на случай другого ядра. aid_sdcard_rw/aid_media_rw/
# aid_ext_data_rw/aid_everybody - доступ к /sdcard (/data/media/0: каталоги media_rw с правами rwxrws---).
AGROUPS=""
for G in aid_inet:3003 aid_net_raw:3004 aid_graphics:1003 aid_sdcard_rw:1015 aid_media_rw:1023 aid_ext_data_rw:1078 aid_everybody:9997; do
  N=${G%%:*}
  getent group "$N" >/dev/null || groupadd -g "${G##*:}" "$N" 2>/dev/null || { say "группа $N (GID ${G##*:}) не создалась"; continue; }
  AGROUPS="${AGROUPS:+$AGROUPS,}$N"
done
usermod -a -G aid_inet,aid_net_raw root
getent passwd _apt >/dev/null && usermod -a -G aid_inet,aid_net_raw _apt
# UID 1000 в Android - system (system_server и др.): пользователь Debian с UID 1000 считал бы их своими процессами
# (kill -1 или pkill -u уронили бы Android). Новые пользователи - с 8000: в AOSP 8000-9996 не занято, а UID < 10000
# eBPF netd не ограничивает (режим Doze, фоновые запреты сети действуют только на приложения).
sed -i -E 's/^#?[[:space:]]*(UID_MIN|GID_MIN)[[:space:]].*/\1 8000/' /etc/login.defs
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/01fold2-sandbox
# Wi-Fi телефона может моргнуть посреди скачивания 1-2 ГБ пакетов - повторы вместо ошибки установки
echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/01fold2-retries
# init в chroot нет: пакеты не должны пытаться запускать службы (docker, ssh) при установке
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d

say "apt update / upgrade"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
say "пакеты"
apt-get -y install --no-install-recommends \
  locales sudo ca-certificates curl wget xz-utils zstd unzip git nano less htop procps psmisc iproute2 iputils-ping \
  openssh-server bash-completion man-db util-linux e2fsprogs \
  dbus dbus-x11 xauth x11-xserver-utils xfce4 xfce4-terminal xfce4-taskmanager thunar-archive-plugin mousepad \
  elementary-xfce-icon-theme adwaita-icon-theme fonts-dejavu-core fonts-noto-core firefox-esr \
  mesa-utils libgl1-mesa-dri libglx-mesa0 libegl1 libgles2 libvulkan1 vulkan-tools \
  docker.io docker-cli iptables containerd runc tini \
  build-essential cmake ninja-build pkg-config python3 python3-pip python3-venv libssl3t64 libgomp1

{ sed -i 's/^# *\(ru_RU.UTF-8\)/\1/; s/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen >/dev/null; } || true
# В ядре Android iptables legacy (nft может не быть)
update-alternatives --set iptables /usr/sbin/iptables-legacy || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

if ! id "$U" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$U"
  say "создан пользователь $U (пароль: debian.sh run passwd $U)"
fi
UID_U=$(id -u "$U")
[ "$UID_U" -ge 8000 ] && [ "$UID_U" -lt 10000 ] || say "у $U UID $UID_U: в Android это системный UID или UID приложений (лучше 8000-9999, см. начало скрипта)"
getent group docker >/dev/null || groupadd docker
usermod -a -G "sudo,docker,video,audio${AGROUPS:+,$AGROUPS}" "$U"
echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/fold2 && chmod 440 /etc/sudoers.d/fold2

# Артефакты из релиза tools-N (pc_install_debian.sh кладёт их в /root, иначе качаем)
fetch() { # fetch <имя-ассета>: из релиза tools-N с наибольшим N, с проверкой по его SHA256SUMS
  [ -f "/root/$1" ] && return 0
  local URL SUM PG R REL=""
  # API GitHub отдаёт релизы не по дате, а по имени (tools-9 раньше tools-21), по 100 на страницу:
  # собираем все страницы и сортируем по номеру сами
  for PG in 1 2 3 4 5; do
    R=$(curl -fsSL --retry 3 "https://api.github.com/repos/$REPO/releases?per_page=100&page=$PG") || break
    REL="$REL$R"
    [ "$(printf '%s' "$R" | grep -o '"tag_name"' | grep -c .)" -lt 100 ] && break
  done
  [ -n "$REL" ] || { say "не получил список релизов $REPO с GitHub (нет интернета или лимит запросов к API) - $1 пропускаю"; return 1; }
  URL=$(printf '%s' "$REL" | grep -o "https://[^\"]*/tools-[0-9]*/$1\"" \
    | tr -d '"' | sed 's|.*/tools-\([0-9]*\)/.*|\1 &|' | sort -k1,1nr | head -n 1 | cut -d' ' -f2 || true)
  [ -n "$URL" ] || { say "не нашёл $1 в релизах $REPO"; return 1; }
  # .part: оборванное скачивание не должно выглядеть готовым файлом при следующем запуске
  curl -fL --retry 3 -o "/root/$1.part" "$URL" || { rm -f "/root/$1.part"; say "не скачался $1"; return 1; }
  SUM=$(curl -fsSL --retry 3 "${URL%/*}/SHA256SUMS" | awk -v f="$1" '$2==f || $2=="*"f {print $1}' || true)
  if [ -n "$SUM" ] && [ "$(sha256sum "/root/$1.part" | cut -d' ' -f1)" != "$SUM" ]; then
    rm -f "/root/$1.part"; say "sha256 $1 не совпал - не беру"; return 1
  fi
  mv "/root/$1.part" "/root/$1"
}

say "Turnip (Vulkan для Adreno 650, KGSL)"
if fetch turnip-kgsl-debian13-arm64.tar.xz; then
  rm -rf /opt/turnip && tar -xJf /root/turnip-kgsl-debian13-arm64.tar.xz -C /
  cat > /etc/profile.d/fold2-gpu.sh <<'G'
# fold2: Vulkan через Turnip (Mesa, драйвер freedreno с KGSL) на Adreno 650
export VK_ICD_FILENAMES=/opt/turnip/share/vulkan/icd.d/freedreno_icd.aarch64.json
# noconform: Turnip показывает возможности, которых у Adreno 650 нет "в железе" (multiview) - нужны для Vulkan 1.1+
export TU_DEBUG=${TU_DEBUG-noconform}
# показ кадров через CPU (надёжно в Termux:X11). Попробовать DRI3 без копирования: MESA_VK_WSI_DEBUG= (пусто)
export MESA_VK_WSI_DEBUG=${MESA_VK_WSI_DEBUG-sw}
G
  cat > /usr/local/bin/zink <<'Z'
#!/bin/sh
# OpenGL поверх Vulkan (Zink + Turnip): zink glxgears, zink glmark2 ...
. /etc/profile.d/fold2-gpu.sh
export LD_LIBRARY_PATH=/opt/turnip/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export LIBGL_DRIVERS_PATH=/opt/turnip/lib/dri __GLX_VENDOR_LIBRARY_NAME=mesa MESA_LOADER_DRIVER_OVERRIDE=zink
export __EGL_VENDOR_LIBRARY_FILENAMES=/opt/turnip/share/glvnd/egl_vendor.d/50_mesa.json
exec "$@"
Z
  chmod 755 /usr/local/bin/zink
fi

say "llama.cpp"
if fetch llama-debian-arm64.tar.xz; then
  rm -rf /opt/llama.cpp && mkdir -p /opt/llama.cpp && tar -xJf /root/llama-debian-arm64.tar.xz -C /opt/llama.cpp
else
  say "собираю llama.cpp на телефоне (15-30 минут)"
  rm -rf /root/llama.cpp-src && git clone --depth 1 -b v0.8.0 https://github.com/ggml-org/llama.cpp /root/llama.cpp-src
  cmake -S /root/llama.cpp-src -B /root/llama.cpp-src/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON \
    -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON -DLLAMA_BUILD_TESTS=OFF
  cmake --build /root/llama.cpp-src/build -j"$(nproc)"
  mkdir -p /opt/llama.cpp && cp -a /root/llama.cpp-src/build/bin /opt/llama.cpp/
fi
for B in /opt/llama.cpp/bin/llama-*; do [ -x "$B" ] && ln -sf "$B" /usr/local/bin/; done
/opt/llama.cpp/bin/llama-server --version || say "llama-server не запускается - смотри вывод выше"

say "проверки"
if command -v vulkaninfo >/dev/null && [ -f /etc/profile.d/fold2-gpu.sh ]; then
  # shellcheck source=/dev/null
  (. /etc/profile.d/fold2-gpu.sh; vulkaninfo --summary 2>&1 | grep -E "deviceName|driverName|apiVersion" | head -n 6) || true
fi
docker --version || true
# отметка для debian.sh/pc_install_debian.sh: настройка дошла до конца (без неё install продолжает прерванную)
date >/etc/fold2-setup.done
say "готово"
