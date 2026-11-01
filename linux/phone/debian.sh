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
DOCKER_STORAGE=
DOCKER_IMG_GB=32
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

# Процессы su/adb Android может держать в урезанном cpuset (только малые ядра): тогда taskset -c 4-7 не работает,
# а всё в Debian (и Docker) делит пару малых ядер. Переносим этот shell и всё, что он запустит, в корневые группы.
for G in /dev/cpuset /dev/cpuctl /dev/stune; do
  for F in "$G/cgroup.procs" "$G/tasks"; do
    [ -f "$F" ] && echo $$ >"$F" 2>/dev/null && break
  done
done

PATH_IN=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CG=$R/sys/fs/cgroup

ismnt() { grep -q " $1 " /proc/mounts; }
propagation() { # propagation private|rslave <точка> - busybox Magisk, затем toybox/util-linux
  /data/adb/magisk/busybox mount "--make-$1" "$2" 2>/dev/null || mount "--make-$1" "$2" 2>/dev/null || mount -o "$1" "$2" 2>/dev/null
}
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
  # уже смонтированные Android-ом иерархии v1 (/dev/cpuctl, /dev/memcg, /acct, ...) - bind.
  # Кроме noprefix: cpuset у Android смонтирован с noprefix (файлы cpus вместо cpuset.cpus), runc такого не
  # понимает ("docker run: ... cpuset.cpus: no such file or directory"), а без cpuset Docker работает (нет --cpuset-cpus)
  awk '$3=="cgroup" {print $2, $4}' /proc/mounts | while read -r SRC OPTS; do
    case "$SRC" in "$R"/*) continue ;; esac
    case ",$OPTS," in *,noprefix,*) continue ;; esac
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
    # повторный mount такого контроллера вернул бы ту же иерархию с noprefix
    awk -v c=",$C," '$3=="cgroup" && index(","$4",", c) && index(","$4",", ",noprefix,") {f=1} END {exit !f}' /proc/mounts && continue
    mkdir -p "$CG/$C"
    mount -t cgroup -o "$C" cgroup "$CG/$C" 2>/dev/null || rmdir "$CG/$C"
  done
  [ -e "$CG/systemd" ] || { mkdir -p "$CG/systemd"; mount -t cgroup -o none,name=systemd cgroup "$CG/systemd" 2>/dev/null || rmdir "$CG/systemd"; }
}

do_start() {
  need_rootfs
  mount -o remount,dev,suid /data 2>/dev/null || say "не удалось remount /data dev,suid (sudo внутри может не работать)"
  # Корень chroot должен быть точкой монтирования: dockerd при распаковке слоёв и runc делают mount --make-rslave /
  # и иначе падают ("failed to register layer: remount /, flags: 0x84000: invalid argument", termux-packages#18359).
  # private - чтобы монтирования внутри не дублировались через общую (shared) /data в пространства имён приложений.
  if ! ismnt "$R"; then
    if awk -v r="$R/" 'index($2, r)==1 {f=1} END {exit !f}' /proc/mounts; then
      say "Debian смонтирован старой версией скрипта - для Docker выполни: debian.sh stop, затем start"
    elif mount -o bind "$R" "$R" 2>/dev/null; then
      propagation private "$R"
    else say "не удалось mount --bind $R на себя (docker pull может не работать)"; fi
  fi
  mnt "$R/proc" -t proc proc
  mnt "$R/sys" -t sysfs sysfs
  # /dev и /data у Android shared: bind-копия попала бы в ту же группу, и монтирования внутри ($R/dev/shm,
  # $R/dev/pts, тома в /sdcard) появлялись бы и в самом Android. rslave: изменения Android видим, свои не отдаём.
  mnt "$R/dev" -o bind /dev && propagation rslave "$R/dev"
  mnt "$R/dev/pts" -o bind /dev/pts
  [ -d /dev/shm ] || mkdir -p /dev/shm
  mnt "$R/dev/shm" -t tmpfs -o mode=1777,nosuid,nodev,size=2G tmpfs
  mnt "$R/run" -t tmpfs -o mode=755,nosuid,nodev,size=256M tmpfs
  mkdir -p "$R/run/lock" "$R/run/user" "$R/run/sshd" "$R/tmp"; chmod 1777 "$R/tmp" "$R/run/lock"
  [ -d /data/media/0 ] && mnt "$R/sdcard" -o bind /data/media/0 && propagation rslave "$R/sdcard"
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

comm_pids() { # comm_pids <имя> - процессы chroot с этим именем (llama-server из npu.sh вне chroot не трогаем)
  for P in $(chroot_pids); do [ "$(cat "/proc/$P/comm" 2>/dev/null)" = "$1" ] && echo "$P"; done
}

do_stop() {
  pkill -f termux-x11 2>/dev/null
  [ -n "$(comm_pids dockerd)" ] && docker_stop # dockerd сам корректно остановит контейнеры
  for SIG in TERM KILL; do
    PIDS=$(chroot_pids); [ -n "$PIDS" ] || break
    # shellcheck disable=SC2086
    kill -s "$SIG" $PIDS 2>/dev/null; sleep 2
  done
  awk -v r="$R" '$2==r || index($2, r "/")==1 {print $2, $1}' /proc/mounts | sort -r | while read -r M S; do
    umount "$M" 2>/dev/null || umount -l "$M" 2>/dev/null || say "не размонтировалось: $M"
    case "$S" in /dev/block/loop*|/dev/loop*) losetup -d "$S" 2>/dev/null ;; esac # образ Docker
  done
  say "остановлено"
}

do_status() {
  echo "rootfs: $R $( [ -x "$R/bin/sh" ] && echo '(есть)' || echo '(нет)')"
  echo "монтирований: $(awk -v r="$R" '$2==r || index($2, r "/")==1' /proc/mounts | wc -l)"
  echo "процессов в chroot: $(chroot_pids | wc -l)"
  for N in sshd dockerd llama-server; do
    P=$(comm_pids "$N" | head -n 1)
    # cpuset не "/" (например /background) - процесс зажат на малых ядрах
    if [ -n "$P" ]; then echo "$N: работает (pid $P, cpuset $(cat "/proc/$P/cpuset" 2>/dev/null))"; else echo "$N: нет"; fi
  done
  B=/sys/class/power_supply/battery
  if [ -r "$B/capacity" ]; then
    T=$(cat "$B/temp" 2>/dev/null); L=$(cat "$B/batt_full_capacity" 2>/dev/null)
    echo "батарея: $(cat "$B/capacity")% $(cat "$B/status" 2>/dev/null)${T:+, $((T / 10)).$((T % 10))°C}${L:+, предел заряда $L}"
  fi
  IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  [ -n "$IP" ] && echo "Wi-Fi IP: $IP  (ssh -p $SSH_PORT $DEB_USER@$IP, http://$IP:$LLAMA_PORT)"
}

valid_user() { # как NAME_REGEX Debian по умолчанию: имя попадает в команды внутри chroot
  case "$1" in ''|[!a-z_]*|*[!a-z0-9_-]*) return 1 ;; esac
  [ ${#1} -le 32 ]
}

do_install() {
  TARBALL=$1; [ -n "$2" ] && DEB_USER=$2
  valid_user "$DEB_USER" || die "имя пользователя '$DEB_USER': латиница в нижнем регистре, цифры, _ и -, с буквы или _, до 32 символов"
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
      echo "DOCKER_STORAGE=   # пусто = выбирает dockerd (overlay2); vfs - если overlay2 не работает (медленно, много места)"
      echo "DOCKER_IMG_GB=$DOCKER_IMG_GB  # данные Docker в образе ext4 такого размера (место занимается по мере заполнения); 0 - прямо в /data"
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
  [ -n "$(comm_pids sshd)" ] && { say "sshd уже работает (порт $SSH_PORT)"; return 0; }
  in_chroot /bin/sh -c "mkdir -p /run/sshd && ssh-keygen -A >/dev/null 2>&1; /usr/sbin/sshd -p $SSH_PORT" && say "sshd на порту $SSH_PORT"
}

net_dev() { ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# overlay2 (слои Docker) не любит /data: f2fs с шифрованием и casefold ядро 4.19 не берёт как upperdir, и dockerd
# уходит на медленный vfs. Поэтому /var/lib/docker - образ ext4 (файл внутри Debian), смонтированный через loop.
docker_img() {
  [ "${DOCKER_IMG_GB:-0}" -gt 0 ] 2>/dev/null || return 0
  IMG=$R/var/lib/docker.img; DIR=$R/var/lib/docker
  ismnt "$DIR" && return 0
  NEW=""
  if [ ! -f "$IMG" ]; then
    if [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then say "в /var/lib/docker уже есть данные - образ ext4 не создаю (DOCKER_IMG_GB=0 убирает это сообщение)"; return 0; fi
    say "создаю образ ext4 для Docker до ${DOCKER_IMG_GB} ГБ: $IMG (место занимается по мере заполнения)"
    # orphan_file (по умолчанию в e2fsprogs 1.47) ядро 4.19 не знает - выключаем
    if ! truncate -s "${DOCKER_IMG_GB}G" "$IMG" || ! { in_chroot mkfs.ext4 -q -F -m 0 -O ^orphan_file /var/lib/docker.img || mke2fs -t ext4 -q -F -m 0 "$IMG"; }; then
      rm -f "$IMG"; say "образ не создался - данные Docker прямо в /data"; return 0
    fi
    NEW=1
  fi
  mkdir -p "$DIR"
  # новый образ, который не смонтировался, удаляем: иначе позже он закроет собой данные, записанные в /data
  mount -t ext4 -o loop,noatime,discard "$IMG" "$DIR" 2>/dev/null || { [ -n "$NEW" ] && rm -f "$IMG"; say "не смонтировался $IMG - данные Docker прямо в /data"; return 0; }
}

docker_stop() {
  P=$(comm_pids dockerd | head -n 1) # не /run/docker.pid: после сбоя там может быть чужой pid
  if [ -z "$P" ]; then say "dockerd не запущен"
  else
    # dockerd при SIGTERM останавливает контейнеры (до 15 с на каждый) - ждём до 30 с
    kill "$P" 2>/dev/null
    N=0; while kill -0 "$P" 2>/dev/null && [ $N -lt 30 ]; do sleep 1; N=$((N+1)); done
    if kill -0 "$P" 2>/dev/null; then kill -9 "$P" 2>/dev/null; say "dockerd не вышел за 30 с - убит"; else say "dockerd остановлен"; fi
  fi
  # containerd и shim-ы контейнеров, если что-то осталось (comm обрезан до 15 символов: containerd-shim-runc-v2)
  for N in containerd-shim containerd; do
    P=$(comm_pids "$N")
    # shellcheck disable=SC2086
    [ -n "$P" ] && kill $P 2>/dev/null
  done
  return 0
}

do_docker() {
  if [ "$1" = stop ]; then docker_stop; return; fi
  do_start >/dev/null
  mkdir -p "$R/etc/docker"
  [ -n "$(comm_pids dockerd)" ] || docker_img
  # в ядре нет NAT для IPv6 (CONFIG_IP6_NF_NAT) - ip6tables у dockerd всегда выключен
  {
    echo "{"
    [ -n "$DOCKER_STORAGE" ] && echo "  \"storage-driver\": \"$DOCKER_STORAGE\","
    [ "$DOCKER_NET" = bridge ] || printf '  "bridge": "none",\n  "iptables": false,\n'
    printf '  "ip6tables": false,\n  "dns": ["1.1.1.1", "8.8.8.8"]\n}\n'
  } > "$R/etc/docker/daemon.json"
  [ "$DOCKER_NET" = bridge ] && echo 1 > /proc/sys/net/ipv4/ip_forward
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
    stop) P=$(comm_pids llama-server); [ -n "$P" ] || { say "llama-server не запущен"; return; }
      # shellcheck disable=SC2086
      kill $P 2>/dev/null; sleep 2; P=$(comm_pids llama-server)
      # shellcheck disable=SC2086
      [ -n "$P" ] && kill -9 $P 2>/dev/null
      say "llama-server остановлен"; return ;;
    log) tail -n 50 "$R/var/log/llama-server.log"; return ;;
  esac
  do_start >/dev/null
  [ -x "$R/opt/llama.cpp/bin/llama-server" ] || die "нет /opt/llama.cpp (setup_in_chroot.sh ставит его)"
  [ -n "$(comm_pids llama-server)" ] && { say "llama-server уже работает (порт $LLAMA_PORT)"; return 0; }
  if [ -n "$LLAMA_MODEL" ]; then
    # /sdcard (/data/media/0) зашифрован до первой разблокировки после загрузки
    [ -r "$R$LLAMA_MODEL" ] || die "модель $LLAMA_MODEL не читается (нет файла или телефон ещё не разблокирован после загрузки)"
    M="-m $LLAMA_MODEL"
  else M="-hf $LLAMA_HF"; fi
  # ключ - файлом в tmpfs /run (--api-key-file), а не в командной строке: её видно в ps
  K=""; rm -f "$R/run/llama-api-key"
  if [ -n "$LLAMA_API_KEY" ]; then
    (umask 077; printf '%s\n' "$LLAMA_API_KEY" >"$R/run/llama-api-key") && K="--api-key-file /run/llama-api-key"
  fi
  GPU=""; [ "$LLAMA_DEVICE" != none ] && GPU=". /etc/profile.d/fold2-gpu.sh;"
  TS=""
  if [ -n "$LLAMA_CPUS" ]; then
    if in_chroot taskset -c "$LLAMA_CPUS" true 2>/dev/null; then TS="taskset -c $LLAMA_CPUS"
    else say "taskset -c $LLAMA_CPUS не работает (cpuset $(cat /proc/$$/cpuset 2>/dev/null)) - без привязки к ядрам"; fi
  fi
  in_chroot /bin/sh -c "$GPU export LLAMA_CACHE=/var/lib/llama LD_LIBRARY_PATH=/opt/llama.cpp/bin; mkdir -p /var/lib/llama;
    nohup $TS /opt/llama.cpp/bin/llama-server $M --host 0.0.0.0 --port $LLAMA_PORT \
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
  am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1
  in_chroot /bin/su -l "$DEB_USER" -c 'export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-$USER; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR;
    [ -f /etc/profile.d/fold2-gpu.sh ] && . /etc/profile.d/fold2-gpu.sh; nohup dbus-launch --exit-with-session startxfce4 >/tmp/xfce.log 2>&1 &'
  say "XFCE запущен в Termux:X11 (в DeX окно можно перетащить на монитор и развернуть)"
}

do_autostart() {
  F=/data/adb/service.d/fold2-debian.sh
  case "$1" in
    on) mkdir -p /data/adb/service.d
        { printf '#!/system/bin/sh\n# fold2: автозапуск Debian (debian.sh autostart off - убрать)\n'
          printf "BASE='%s'\n" "$BASE"
          cat <<'EOS'
export FOLD2_BASE=$BASE
D=$BASE/debian.sh; R=$BASE/debian
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done; sleep 20
# shellcheck disable=SC1091
. "$BASE/debian.conf"
exec >>"$BASE/autostart.log" 2>&1; echo "== $(date)"
sh "$D" start
[ "$AUTO_SSH" = 1 ] && sh "$D" ssh
[ "$AUTO_DOCKER" = 1 ] && sh "$D" docker
if [ "$AUTO_LLAMA" = 1 ]; then
  # модель в /sdcard читается только после первой разблокировки телефона (шифрование FBE) - ждём до суток
  N=0; while [ -n "$LLAMA_MODEL" ] && [ ! -r "$R$LLAMA_MODEL" ] && [ $N -lt 5760 ]; do sleep 15; N=$((N+1)); done
  sh "$D" llama
fi
EOS
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
  *) sed -n '3,15p' "$SELF"; exit 1 ;;
esac
