#!/system/bin/sh
# shellcheck disable=SC2016
# fold2: Debian 13 (trixie) в chroot на Galaxy Z Fold2 (UN1CA, Magisk root).
# Запуск (adb shell или терминал на телефоне):  su -mm -c "sh /data/local/fold2/debian.sh <команда>"
#   install <rootfs.tar.xz> [пользователь] - распаковать Debian и поставить XFCE, Docker, Vulkan, llama.cpp
#   start | stop | status        - смонтировать / остановить всё и размонтировать / состояние
#   shell [пользователь]         - войти (по умолчанию пользователь из debian.conf)
#   run <команда...>             - выполнить команду в Debian от root
#   x11                          - XFCE через Termux:X11 (окно приложения можно увести на монитор DeX)
#   ssh                          - sshd на порту SSH_PORT (по умолчанию 2222)
#   docker [stop]                - dockerd (сеть DOCKER_NET=host|bridge из debian.conf)
#   llama [stop|log]             - llama-server на 0.0.0.0:LLAMA_PORT (CPU или Vulkan/Turnip)
#   autostart on|off             - запуск start/ssh/docker/llama при загрузке (Magisk service.d)
# Настройки: /data/local/fold2/debian.conf (создаётся при install).

BASE=${FOLD2_BASE:-/data/local/fold2}
CONF=$BASE/debian.conf
R=$BASE/debian
DEB_USER=fold2
SSH_PORT=2222
DOCKER_NET=host
LLAMA_HF=unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_0
LLAMA_MODEL=
LLAMA_PORT=8080
LLAMA_THREADS=4
LLAMA_CPUS=4-7
LLAMA_CTX=8192
LLAMA_DEVICE=none
LLAMA_NGL=0
LLAMA_API_KEY=
LLAMA_ARGS=
X11_SELINUX_PERMISSIVE=1
AUTO_SSH=1
AUTO_DOCKER=0
AUTO_LLAMA=0
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

say() { echo "[fold2] $*"; }
die() { echo "[fold2] ОШИБКА: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root: su -mm -c \"sh $0 $*\""

# Работаем в глобальном mount namespace, иначе монтирования не видны другим процессам (и Termux:X11)
SELF=$(readlink -f "$0")
if [ -z "$FOLD2_NS" ] && [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
  export FOLD2_NS=1
  if command -v nsenter >/dev/null 2>&1; then exec nsenter -t 1 -m -- /system/bin/sh "$SELF" "$@"
  elif [ -x /data/adb/magisk/busybox ]; then exec /data/adb/magisk/busybox nsenter -t 1 -m -- /system/bin/sh "$SELF" "$@"
  fi
  say "nsenter не найден, остаюсь в текущем namespace (запускай через su -mm)"
fi

PATH_IN=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CG=$R/sys/fs/cgroup

ismnt() { grep -q " $1 " /proc/mounts; }
mnt() { # mnt <куда> <аргументы mount...>
  T=$1; shift
  ismnt "$T" && return 0
  mkdir -p "$T"
  mount "$@" "$T" 2>/dev/null || { say "не смонтировалось: $T ($*)"; return 1; }
}

in_chroot() { # от root, без окружения Android
  env -i HOME=/root USER=root LOGNAME=root TERM="${TERM:-xterm-256color}" PATH="$PATH_IN" LANG=C.UTF-8 TMPDIR=/tmp \
    chroot "$R" "$@"
}

need_rootfs() { [ -x "$R/bin/sh" ] || die "Debian не установлен в $R (команда install)"; }

write_net() {
  if [ ! -e "$R/etc/resolv.conf.keep" ]; then
    rm -f "$R/etc/resolv.conf"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' > "$R/etc/resolv.conf"
  fi
  grep -q fold2 "$R/etc/hosts" 2>/dev/null || printf '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n127.0.1.1 fold2\n' > "$R/etc/hosts"
  echo fold2 > "$R/etc/hostname"
}

mount_cgroups() {
  mnt "$CG" -t tmpfs -o mode=755,nosuid,nodev,noexec cgroup_root || return 0
  # уже смонтированные Android-ом иерархии v1 (/dev/cpuctl, /dev/cpuset, /dev/memcg, ...) - bind
  awk '$3=="cgroup" {print $2, $4}' /proc/mounts | while read -r SRC OPTS; do
    case "$SRC" in "$R"/*) continue ;; esac
    CS=""
    for O in $(echo "$OPTS" | tr ',' ' '); do
      case "$O" in rw|ro|nosuid|nodev|noexec|relatime|noatime|seclabel|nsdelegate|memory_recursiveprot|release_agent=*|clone_children|noprefix) ;;
        name=*) ;; *) CS="${CS:+$CS,}$O" ;; esac
    done
    [ -n "$CS" ] || continue
    [ -d "$CG/$CS" ] && continue
    mnt "$CG/$CS" -o bind "$SRC" || continue
    for C in $(echo "$CS" | tr ',' ' '); do [ "$C" = "$CS" ] || [ -e "$CG/$C" ] || ln -s "$CS" "$CG/$C"; done
  done
  # остальные включённые контроллеры (devices, pids, freezer, ...) - новые иерархии v1
  awk '!/^#/ && $4==1 {print $1}' /proc/cgroups | while read -r C; do
    [ -e "$CG/$C" ] && continue
    mkdir -p "$CG/$C"
    mount -t cgroup -o "$C" cgroup "$CG/$C" 2>/dev/null || rmdir "$CG/$C"
  done
  [ -e "$CG/systemd" ] || { mkdir -p "$CG/systemd"; mount -t cgroup -o none,name=systemd cgroup "$CG/systemd" 2>/dev/null || rmdir "$CG/systemd"; }
}

do_start() {
  need_rootfs
  mount -o remount,dev,suid /data 2>/dev/null || say "не удалось remount /data dev,suid (sudo внутри может не работать)"
  mnt "$R/proc" -t proc proc
  mnt "$R/sys" -t sysfs sysfs
  mnt "$R/dev" -o bind /dev
  mnt "$R/dev/pts" -o bind /dev/pts
  [ -d /dev/shm ] || mkdir -p /dev/shm
  mnt "$R/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev,size=2G tmpfs
  mnt "$R/run" -t tmpfs -o mode=755,nosuid,nodev,size=256M tmpfs
  mkdir -p "$R/run/lock" "$R/run/user" "$R/run/sshd" "$R/tmp"; chmod 1777 "$R/tmp" "$R/run/lock"
  [ -d /data/media/0 ] && mnt "$R/sdcard" -o bind /data/media/0
  mount_cgroups
  [ -e "$R/dev/fd" ] || ln -s /proc/self/fd "$R/dev/fd" 2>/dev/null
  write_net
  say "Debian смонтирован: $R"
}

chroot_pids() { # процессы, у которых корень внутри $R
  for P in /proc/[0-9]*; do
    RT=$(readlink "$P/root" 2>/dev/null) || continue
    case "$RT" in "$R"|"$R"/*) echo "${P#/proc/}" ;; esac
  done
}

do_stop() {
  pkill -f termux-x11 2>/dev/null
  for SIG in TERM KILL; do
    PIDS=$(chroot_pids); [ -n "$PIDS" ] || break
    # shellcheck disable=SC2086
    kill -s "$SIG" $PIDS 2>/dev/null; sleep 2
  done
  awk -v r="$R" '$2==r || index($2, r "/")==1 {print $2}' /proc/mounts | sort -r | while read -r M; do
    umount "$M" 2>/dev/null || umount -l "$M" 2>/dev/null || say "не размонтировалось: $M"
  done
  say "остановлено"
}

do_status() {
  echo "rootfs: $R $( [ -x "$R/bin/sh" ] && echo '(есть)' || echo '(нет)')"
  echo "монтирований: $(awk -v r="$R" 'index($2, r)==1' /proc/mounts | wc -l)"
  echo "процессов в chroot: $(chroot_pids | wc -l)"
  for N in sshd dockerd llama-server; do
    if chroot_pids | while read -r P; do [ "$(cat "/proc/$P/comm" 2>/dev/null)" = "$N" ] && echo y; done | grep -q y; then echo "$N: работает"; else echo "$N: нет"; fi
  done
  IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  [ -n "$IP" ] && echo "Wi-Fi IP: $IP  (ssh -p $SSH_PORT $DEB_USER@$IP, http://$IP:$LLAMA_PORT)"
}

do_install() {
  TARBALL=$1; [ -n "$2" ] && DEB_USER=$2
  [ -f "$TARBALL" ] || die "нет файла rootfs: $TARBALL"
  [ -x "$R/bin/sh" ] && die "уже установлено в $R (удалить: debian.sh stop && rm -rf $R)"
  BB=/data/adb/magisk/busybox; [ -x "$BB" ] || die "нет $BB (нужен Magisk)"
  mkdir -p "$R"
  say "распаковка $TARBALL ..."
  "$BB" tar -xJpf "$TARBALL" -C "$R" || { say "busybox tar -J не смог, пробую xzcat"; xzcat "$TARBALL" | "$BB" tar -xpf - -C "$R"; } || die "распаковка не удалась"
  HERE=$(dirname "$SELF")
  cp "$HERE/setup_in_chroot.sh" "$R/root/setup_in_chroot.sh" || die "нет setup_in_chroot.sh рядом с debian.sh"
  for F in "$HERE"/turnip-*.tar.xz "$HERE"/llama-debian-*.tar.xz; do [ -f "$F" ] && cp "$F" "$R/root/"; done
  if [ ! -f "$CONF" ]; then
    { echo "# настройки fold2 debian.sh"; echo "DEB_USER=$DEB_USER"; echo "SSH_PORT=$SSH_PORT"; echo "DOCKER_NET=$DOCKER_NET"
      echo "LLAMA_HF=$LLAMA_HF"; echo "LLAMA_MODEL=      # путь в Debian, например /sdcard/models/model.gguf (тогда LLAMA_HF не нужен)"
      echo "LLAMA_PORT=$LLAMA_PORT"; echo "LLAMA_THREADS=$LLAMA_THREADS"; echo "LLAMA_CPUS=$LLAMA_CPUS   # большие ядра SD865+"
      echo "LLAMA_CTX=$LLAMA_CTX"; echo "LLAMA_DEVICE=none # none = CPU; Vulkan0 = Adreno 650 через Turnip (экспериментально)"
      echo "LLAMA_NGL=$LLAMA_NGL"; echo "LLAMA_API_KEY=    # если задать, сервер требует ключ"; echo "LLAMA_ARGS="
      echo "X11_SELINUX_PERMISSIVE=$X11_SELINUX_PERMISSIVE"; echo "AUTO_SSH=$AUTO_SSH"; echo "AUTO_DOCKER=$AUTO_DOCKER"; echo "AUTO_LLAMA=$AUTO_LLAMA"; } > "$CONF"
  fi
  do_start
  say "установка пакетов (XFCE, Docker, Vulkan, сборочные) - 10-30 минут, нужен интернет"
  in_chroot /bin/bash /root/setup_in_chroot.sh "$DEB_USER" || die "setup_in_chroot.sh завершился с ошибкой (лог выше); можно повторить: debian.sh run bash /root/setup_in_chroot.sh $DEB_USER"
  say "готово. Пароль пользователя $DEB_USER задай: debian.sh run passwd $DEB_USER"
}

do_shell() {
  do_start >/dev/null
  U=${1:-$DEB_USER}
  if [ "$U" = root ]; then in_chroot /bin/bash -l; else in_chroot /bin/su -l "$U"; fi
}

do_ssh() {
  do_start >/dev/null
  in_chroot /bin/sh -c "mkdir -p /run/sshd && ssh-keygen -A >/dev/null 2>&1; /usr/sbin/sshd -p $SSH_PORT" && say "sshd на порту $SSH_PORT"
}

net_dev() { ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

do_docker() {
  if [ "$1" = stop ]; then in_chroot /bin/sh -c 'kill $(cat /run/docker.pid 2>/dev/null) 2>/dev/null; sleep 3; pkill containerd'; say "dockerd остановлен"; return; fi
  do_start >/dev/null
  mkdir -p "$R/etc/docker"
  if [ "$DOCKER_NET" = bridge ]; then
    printf '{\n  "dns": ["1.1.1.1", "8.8.8.8"]\n}\n' > "$R/etc/docker/daemon.json"
    echo 1 > /proc/sys/net/ipv4/ip_forward
  else
    printf '{\n  "bridge": "none",\n  "iptables": false,\n  "ip6tables": false,\n  "dns": ["1.1.1.1", "8.8.8.8"]\n}\n' > "$R/etc/docker/daemon.json"
  fi
  in_chroot /bin/sh -c 'pgrep -x dockerd >/dev/null || nohup dockerd >/var/log/dockerd.log 2>&1 &'
  N=0; while [ $N -lt 30 ] && ! in_chroot docker info >/dev/null 2>&1; do sleep 1; N=$((N+1)); done
  if [ "$DOCKER_NET" = bridge ]; then
    # Android маршрутизирует по своим таблицам: пускаем подсеть docker в таблицу текущей сети
    D=$(net_dev)
    ip rule del pref 5000 2>/dev/null; ip rule del pref 5001 2>/dev/null
    ip rule add pref 5000 from all lookup main
    [ -n "$D" ] && ip rule add pref 5001 from 172.16.0.0/12 lookup "$D"
    say "bridge: трафик контейнеров через $D (после смены Wi-Fi/мобильной сети снова: debian.sh docker)"
  fi
  if in_chroot docker info >/dev/null 2>&1; then
    say "dockerd работает (DOCKER_NET=$DOCKER_NET). Пример: debian.sh run docker run --rm $( [ "$DOCKER_NET" = host ] && echo '--network host ')hello-world"
  else
    say "dockerd не ответил, лог: $R/var/log/dockerd.log"; tail -n 20 "$R/var/log/dockerd.log"; return 1
  fi
}

do_llama() {
  case "$1" in
    stop) in_chroot pkill -x llama-server; say "llama-server остановлен"; return ;;
    log) tail -n 50 "$R/var/log/llama-server.log"; return ;;
  esac
  do_start >/dev/null
  [ -x "$R/opt/llama.cpp/bin/llama-server" ] || die "нет /opt/llama.cpp (setup_in_chroot.sh ставит его)"
  if [ -n "$LLAMA_MODEL" ]; then M="-m $LLAMA_MODEL"; else M="-hf $LLAMA_HF"; fi
  K=""; [ -n "$LLAMA_API_KEY" ] && K="--api-key $LLAMA_API_KEY"
  GPU=""; [ "$LLAMA_DEVICE" != none ] && GPU=". /etc/profile.d/fold2-gpu.sh;"
  in_chroot /bin/sh -c "$GPU export LLAMA_CACHE=/var/lib/llama LD_LIBRARY_PATH=/opt/llama.cpp/bin; mkdir -p /var/lib/llama;
    pgrep -x llama-server >/dev/null && { echo 'llama-server уже работает'; exit 0; }
    nohup taskset -c $LLAMA_CPUS /opt/llama.cpp/bin/llama-server $M --host 0.0.0.0 --port $LLAMA_PORT \
      -t $LLAMA_THREADS -c $LLAMA_CTX --device $LLAMA_DEVICE -ngl $LLAMA_NGL --jinja $K $LLAMA_ARGS \
      >/var/log/llama-server.log 2>&1 &"
  say "llama-server запускается (модель качается при первом запуске): http://<IP телефона>:$LLAMA_PORT  лог: debian.sh llama log"
}

do_x11() {
  do_start >/dev/null
  PKG=$(pm path com.termux.x11 2>/dev/null | head -n1 | cut -d: -f2)
  [ -n "$PKG" ] || die "не установлен Termux:X11 (pc_install_debian.sh ставит его)"
  if [ "$X11_SELINUX_PERMISSIVE" = 1 ] && [ "$(getenforce)" = Enforcing ]; then
    say "SELinux -> Permissive до перезагрузки (требование Termux:X11 для chroot; X11_SELINUX_PERMISSIVE=0 чтобы не трогать)"
    setenforce 0
  fi
  pkill -f termux-x11 2>/dev/null; sleep 1
  rm -rf "$R/tmp/.X11-unix" "$R/tmp/.X0-lock"
  (export TMPDIR="$R/tmp" XKB_CONFIG_ROOT="$R/usr/share/X11/xkb" CLASSPATH="$PKG"
   nohup /system/bin/app_process / --nice-name=termux-x11 com.termux.x11.CmdEntryPoint :0 >"$BASE/termux-x11.log" 2>&1 &)
  N=0; while [ $N -lt 15 ] && [ ! -S "$R/tmp/.X11-unix/X0" ]; do sleep 1; N=$((N+1)); done
  [ -S "$R/tmp/.X11-unix/X0" ] || { cat "$BASE/termux-x11.log"; die "X-сервер Termux:X11 не поднялся"; }
  am start -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1
  in_chroot /bin/su -l "$DEB_USER" -c 'export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-$USER; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR;
    [ -f /etc/profile.d/fold2-gpu.sh ] && . /etc/profile.d/fold2-gpu.sh; nohup dbus-launch --exit-with-session startxfce4 >/tmp/xfce.log 2>&1 &'
  say "XFCE запущен в Termux:X11 (в DeX окно можно перетащить на монитор и развернуть)"
}

do_autostart() {
  F=/data/adb/service.d/fold2-debian.sh
  case "$1" in
    on) mkdir -p /data/adb/service.d
        { echo '#!/system/bin/sh'; echo '# fold2: автозапуск Debian (debian.sh autostart off - убрать)'
          echo 'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done; sleep 20'
          echo "D=$BASE/debian.sh; . $CONF"
          echo 'sh "$D" start; [ "$AUTO_SSH" = 1 ] && sh "$D" ssh; [ "$AUTO_DOCKER" = 1 ] && sh "$D" docker; [ "$AUTO_LLAMA" = 1 ] && sh "$D" llama'
        } > "$F"; chmod 755 "$F"; [ "$SELF" = "$BASE/debian.sh" ] || cp "$SELF" "$BASE/debian.sh"
        say "автозапуск включён ($F; что именно - AUTO_* в $CONF)" ;;
    off) rm -f "$F"; say "автозапуск выключен" ;;
    *) die "autostart on|off" ;;
  esac
}

CMD=$1; [ $# -gt 0 ] && shift
case "$CMD" in
  install) do_install "$@" ;;
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  shell|login) do_shell "$@" ;;
  run) do_start >/dev/null; in_chroot "$@" ;;
  x11|xfce) do_x11 ;;
  ssh|sshd) do_ssh ;;
  docker) do_docker "$@" ;;
  llama) do_llama "$@" ;;
  autostart) do_autostart "$@" ;;
  *) sed -n '2,15p' "$SELF"; exit 1 ;;
esac
