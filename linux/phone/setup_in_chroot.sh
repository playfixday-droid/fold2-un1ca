#!/bin/bash
# fold2: настройка Debian 13 внутри chroot (запускает debian.sh install; можно повторять).
# XFCE (для Termux:X11), Docker, Vulkan (Turnip для Adreno 650 через KGSL), llama.cpp, ssh, сборочные пакеты.
set -euo pipefail
U=${1:-fold2}
REPO=playfixday-droid/fold2-un1ca
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
say() { echo "[fold2/debian] $*"; }

# Android пускает в сеть только группы aid_inet/aid_net_raw (paranoid network) - нужны для не-root
getent group aid_inet >/dev/null || groupadd -g 3003 aid_inet
getent group aid_net_raw >/dev/null || groupadd -g 3004 aid_net_raw
getent group aid_graphics >/dev/null || groupadd -g 1003 aid_graphics
usermod -a -G aid_inet,aid_net_raw root
getent passwd _apt >/dev/null && usermod -a -G aid_inet,aid_net_raw _apt
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/01fold2-sandbox
# init в chroot нет: пакеты не должны пытаться запускать службы (docker, ssh) при установке
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 755 /usr/sbin/policy-rc.d

say "apt update / upgrade"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
say "пакеты"
apt-get -y install --no-install-recommends \
  locales sudo ca-certificates curl wget xz-utils zstd unzip git nano less htop procps psmisc iproute2 iputils-ping \
  openssh-server bash-completion man-db util-linux \
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
getent group docker >/dev/null || groupadd docker
usermod -a -G sudo,docker,aid_inet,aid_net_raw,aid_graphics,video,audio "$U"
echo "$U ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/fold2 && chmod 440 /etc/sudoers.d/fold2

# Артефакты из релиза tools-N (pc_install_debian.sh кладёт их в /root, иначе качаем)
fetch() { # fetch <имя-ассета>
  [ -f "/root/$1" ] && return 0
  URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" | grep -o "https://[^\"]*/tools-[0-9]*/$1" | head -n1 || true)
  [ -n "$URL" ] || { say "не нашёл $1 в релизах $REPO"; return 1; }
  curl -fL --retry 3 -o "/root/$1" "$URL"
}

say "Turnip (Vulkan для Adreno 650, KGSL)"
if fetch turnip-kgsl-debian13-arm64.tar.xz; then
  rm -rf /opt/turnip && tar -xJf /root/turnip-kgsl-debian13-arm64.tar.xz -C /
  cat > /etc/profile.d/fold2-gpu.sh <<'G'
# fold2: Vulkan через Turnip (Mesa, драйвер freedreno с KGSL) на Adreno 650
export VK_ICD_FILENAMES=/opt/turnip/share/vulkan/icd.d/freedreno_icd.aarch64.json
export TU_DEBUG=noconform
# Termux:X11 без DRI3 - показ кадров через CPU
export MESA_VK_WSI_DEBUG=sw
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
say "готово"
