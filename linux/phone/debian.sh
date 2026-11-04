#!/system/bin/sh
# shellcheck disable=SC2016
# fold2: Debian 13 (trixie) в chroot на Galaxy Z Fold2 (UN1CA, Magisk root).
# Запуск (adb shell или терминал на телефоне):  su -mm -c "sh /data/local/fold2/debian.sh <команда>"
#   install <rootfs.tar.xz> [пользователь] - распаковать Debian и поставить XFCE, Docker, Vulkan, llama.cpp
#                                (оборвалась - повторный install продолжает настройку, rootfs не нужен)
#   install-bg <...> | install-log [N] - то же отдельно от adb/терминала (лог install.log, код install.rc) и его вывод
#   start | stop | status        - смонтировать / остановить всё и размонтировать / состояние
#   shell [пользователь]         - войти (по умолчанию пользователь из debian.conf)
#   run <команда...>             - выполнить команду в Debian от root
#   x11 [stop|restart]           - рабочий стол XFCE в Termux:X11 (окно можно увести на монитор DeX); уже запущен -
#                                просто открывает Termux:X11. AUTO_X11=1 в debian.conf - сразу при загрузке
#   ssh                          - sshd на порту SSH_PORT (по умолчанию 2222)
#   docker [stop]                - dockerd (сеть DOCKER_NET=host|bridge из debian.conf)
#   llama [stop|log]             - llama-server на LLAMA_PORT (CPU или Vulkan/Turnip); без LLAMA_API_KEY - только 127.0.0.1
#   autostart on|off             - запуск start/ssh/docker/llama/x11 при загрузке (Magisk service.d) + кнопка module
#   module on|off                - кнопка в Magisk: Модули -> «Fold2: Debian» -> «Действие» = рабочий стол (без ПК и
#                                терминала); ставит её и autostart on
#   battery [N|off]              - предел заряда N% (50-99): дальше телефон питается от зарядки мимо батареи
#   bootlog [ls]                 - сохранить логи прошлой загрузки (почему перезагрузился) в bootlogs/
#   backup <файл|-> [models]     - копия Debian (и debian.conf) в .tar.gz; - = в stdout, сообщения - в stderr (так её
#                                забирает на ПК pc_backup_debian.sh; adb exec-out смешал бы их с архивом: 2>файл).
#                                Работающий Debian остановит на время копии и запустит снова.
#                                Не входят: Docker (/var/lib/docker), кэш apt, /tmp, модели llama (с models - входят)
#   restore <файл|->             - вернуть Debian из копии backup (- = из stdin); если Debian уже есть - сначала remove yes
#   remove [yes]                 - удалить Debian (без yes - только показать, что удалится): остановит, выключит
#                                автозапуск и удалит, только если внутри ничего не осталось смонтированным (/sdcard!)
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
X11_SELINUX_PERMISSIVE=1 # README Termux:X11 для chroot: "Do not forget to disable SELinux"
AUTO_SSH=1
AUTO_DOCKER=0
AUTO_LLAMA=0
AUTO_X11=0
AUTO_BOOTLOG=1
BOOTLOG_KEEP=5
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
  say "nsenter не найден, остаюсь в текущем namespace (запускай через su -mm)" >&2 # не в stdout: backup - пишет туда архив
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
DONE=$R/etc/fold2-setup.done # пишет setup_in_chroot.sh в самом конце: настройка Debian закончена

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
  # binfmt_misc (ядро f2q-5 и новее): программы x86-64 через qemu-user-binfmt/box64 запускаются сами
  [ -d "$R/proc/sys/fs/binfmt_misc" ] && mnt "$R/proc/sys/fs/binfmt_misc" -t binfmt_misc binfmt_misc
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
  # регистрации binfmt живут в ядре до перезагрузки - вернуть их (пакеты qemu-user-binfmt, box64 и т.п.)
  if [ -x "$R/usr/sbin/update-binfmts" ] && ismnt "$R/proc/sys/fs/binfmt_misc"; then
    in_chroot /usr/sbin/update-binfmts --enable >/dev/null 2>&1 || true
  fi
  say "Debian смонтирован: $R"
}

chroot_pids() { # процессы, у которых корень внутри $R (или $1)
  CR=${1:-$R}
  for P in /proc/[0-9]*; do
    RT=$(readlink "$P/root" 2>/dev/null) || continue
    case "$RT" in "$CR"|"$CR"/*) echo "${P#/proc/}" ;; esac
  done
}

comm_pids() { # comm_pids <имя> - процессы chroot с этим именем (llama-server из npu.sh вне chroot не трогаем)
  for P in $(chroot_pids); do [ "$(cat "/proc/$P/comm" 2>/dev/null)" = "$1" ] && echo "$P"; done
}

do_stop() {
  pkill -f termux-x11 2>/dev/null; x11_selinux_back # отметка - в $R/run, до размонтирования
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
  N=$(mounts_in | wc -l)
  [ "$N" -eq 0 ] || { say "остановлено НЕ до конца: осталось смонтированным $N (debian.sh status; поможет перезагрузка)"; return 1; }
  say "остановлено"
}

mounts_in() { awk -v r="${1:-$R}" '$2==r || index($2, r "/")==1 {print $2}' /proc/mounts; } # монтирования внутри $R (или $1)

do_remove() {
  [ -e "$R" ] || { say "Debian не установлен ($R нет)"; return 0; }
  if [ "$1" != yes ]; then
    say "удалится: $R - Debian целиком (домашние каталоги, Docker, модели в /var/lib/llama), автозапуск и кнопка в Magisk"
    say "останутся: $CONF, $BASE/bootlogs, файлы телефона (/sdcard)"
    say "удалить: debian.sh remove yes"
    exit 2
  fi
  do_autostart off; do_module off
  do_stop
  # rm -rf идёт и внутрь точек монтирования: смонтированный $R/sdcard - это /data/media/0, файлы телефона
  M=$(mounts_in)
  [ -z "$M" ] || die "не удаляю: внутри $R ещё смонтировано ($(echo "$M" | tr '\n' ' ')) - rm -rf прошёлся бы по файлам телефона. Перезагрузи телефон (автозапуск уже выключен) и повтори debian.sh remove yes"
  [ -z "$(chroot_pids)" ] || die "не удаляю: в Debian ещё работают процессы ($(chroot_pids | tr '\n' ' ')) - перезагрузи телефон и повтори"
  # не трогаем то, что не похоже на rootfs fold2 (ошибка в FOLD2_BASE/debian.conf не должна стоить данных)
  [ -x "$R/bin/sh" ] || [ -f "$R/root/setup_in_chroot.sh" ] || [ -z "$(ls -A "$R" 2>/dev/null)" ] || die "$R не похож на Debian fold2 (нет bin/sh) - не удаляю"
  say "удаляю $R ..."
  # start в это же время (автозапуск: llama после ожидания сети, кнопка Magisk) смонтировал бы /data/media/0 в
  # $R/sdcard прямо под rm -rf. После mv start не найдёт $R/bin/sh; смонтированный $R mv не переименует (EBUSY)
  X=$BASE/.removing.$$
  mv "$R" "$X" || die "не удалось переименовать $R (смонтирован?) - перезагрузи телефон и повтори"
  M=$(mounts_in "$X"); PS=$(chroot_pids "$X")
  [ -z "$M" ] || { [ -e "$R" ] || mv "$X" "$R"; die "не удаляю: пока шла проверка, внутри смонтировали ($(echo "$M" | tr '\n' ' ')) - перезагрузи телефон и повтори"; }
  [ -z "$PS" ] || { [ -e "$R" ] || mv "$X" "$R"; die "не удаляю: пока шла проверка, в Debian запустились процессы ($(echo "$PS" | tr '\n' ' ')) - перезагрузи телефон и повтори"; }
  rm -rf "$X" || die "не всё удалилось из $X"
  say "Debian удалён. Поставить заново: pc_install_debian.sh или debian.sh install <rootfs.tar.xz>"
}

# backup/restore - tar системы: на Android это toybox (/system/bin/tar), в нём есть -X и --numeric-owner; в busybox
# бывает без -X (busybox-static Ubuntu)
bk_exclude() { # шаблоны tar -X: от имени в архиве, каталог - вместе с содержимым
  for D in proc sys dev run tmp; do echo "debian/$D/*"; done # точки монтирования и tmpfs - пустыми
  # /sdcard = /data/media/0: start во время копии (кнопка Magisk, автозапуск llama) смонтирует его уже после проверки
  echo "debian/sdcard/*"
  # Docker: образ ext4 разреженный (до DOCKER_IMG_GB, tar прочитал бы его целиком) или данные прямо в /data
  echo "debian/var/lib/docker.img"; echo "debian/var/lib/docker/*"
  echo "debian/var/cache/apt/archives/*.deb"
  [ "$1" = models ] || echo "debian/var/lib/llama/*" # модели llama -hf скачаются заново
}

wakelock() { # wakelock on|off [имя] - CPU не засыпает, пока идёт копия или установка (минуты: погаснет экран - не
  # встанет); если скрипт оборвётся, снимется сам через 3 ч
  WL=${2:-fold2-backup}
  if [ "$1" = on ]; then [ -e /sys/power/wake_lock ] && echo "$WL 10800000000000" >/sys/power/wake_lock
  else [ -e /sys/power/wake_unlock ] && echo "$WL" >/sys/power/wake_unlock; fi 2>/dev/null
  return 0
}

abs_path() { case "$1" in -|/*) echo "$1" ;; *) echo "$(pwd)/$1" ;; esac; } # tar -C меняет каталог

do_backup() { # do_backup <файл|-> [models]
  OUT=$1; WHAT=${2:-}
  [ -n "$OUT" ] || die "куда: debian.sh backup <файл.tar.gz> [models] (- = в stdout)"
  case "$WHAT" in ""|models) ;; *) die "backup: непонятный аргумент '$WHAT' (можно только models)" ;; esac
  [ "$OUT" = - ] && exec 3>&1 1>&2 # stdout - сам архив: все сообщения - в stderr
  # stdin не нужен; у adb exec-out это тот же канал, что stdout - запущенные снова службы не должны его держать
  exec </dev/null
  need_rootfs
  command -v tar >/dev/null || die "нет tar"
  OUT=$(abs_path "$OUT")
  if [ "$OUT" != - ]; then
    case "$OUT" in "$R"|"$R"/*) die "копию внутрь самого Debian ($OUT) не кладу" ;; esac
    [ -d "${OUT%/*}" ] || die "нет каталога ${OUT%/*}"
  fi
  WAS=""; UP=""
  if [ -n "$(mounts_in)" ] || [ -n "$(chroot_pids)" ]; then
    WAS=1
    for N in sshd dockerd llama-server; do [ -n "$(comm_pids "$N")" ] && UP="$UP $N"; done
    x11_up && UP="$UP x11"
    say "Debian работает - останавливаю на время копии (файлы не должны меняться на ходу)"
    do_stop >/dev/null
  fi
  # копия по смонтированному /sdcard (/data/media/0) унесла бы все файлы телефона
  M=$(mounts_in)
  [ -z "$M" ] && [ -z "$(chroot_pids)" ] || die "не копирую: Debian не остановился (смонтировано: $(echo "$M" | tr '\n' ' ')) - перезагрузи телефон и повтори"
  # file capabilities (setcap) tar не хранит - их список едет в самой копии
  rm -f "$R/var/lib/fold2-caps"
  [ -x "$R/usr/sbin/getcap" ] && in_chroot /usr/sbin/getcap -r / 2>/dev/null | sed 's/ = / /' >"$R/var/lib/fold2-caps"
  X=$BASE/.backup-exclude; bk_exclude "$WHAT" >"$X"
  # сокеты (остались от служб) toybox tar не пишет и кончает с ошибкой - мимо копии, службы создадут их заново.
  # Имя для -X - шаблон: [ ] * ? \ экранируем
  (cd "$BASE" && find debian -type s 2>/dev/null) | sed 's/[][*?\\]/\\&/g' >>"$X"
  set -- debian; [ -f "$CONF" ] && set -- debian debian.conf
  say "копия Debian $( [ "$OUT" = - ] && echo '-> stdout' || echo "-> $OUT") ... (минуты: всё сжимается)"
  say "не входят: Docker (/var/lib/docker), кэш apt, /tmp$( [ "$WHAT" = models ] || echo ', модели llama (/var/lib/llama, скачаются заново; с ними: backup ... models)')"
  wakelock on
  if [ "$OUT" = - ]; then
    tar -czf - -C "$BASE" -X "$X" "$@" >&3; RC=$?
    # закрыть сразу: службы, запущенные ниже снова, унаследовали бы stdout - и adb exec-out на ПК не дождался бы конца
    exec 3>&-
  else
    rm -f "$OUT.part"
    (umask 077; tar -czf "$OUT.part" -C "$BASE" -X "$X" "$@") && mv "$OUT.part" "$OUT"; RC=$?
    [ "$RC" = 0 ] || rm -f "$OUT.part"
  fi
  wakelock off; rm -f "$X" "$R/var/lib/fold2-caps"
  if [ "$RC" = 0 ]; then
    if [ "$OUT" = - ]; then say "копия готова"
    else say "копия готова: $OUT ($(( $(du -k "$OUT" | cut -f1) / 1024 )) МБ). Вернуть: debian.sh restore $OUT"; fi
  else say "ОШИБКА: копия не получилась (tar: код $RC; мало места?)"; fi
  if [ -n "$WAS" ]; then # запускаем то, что работало
    (do_start >/dev/null) || say "Debian не запустился снова (копия цела) - запусти: debian.sh start"
    for N in $UP; do
      case "$N" in sshd) (do_ssh) ;; dockerd) (do_docker) ;; llama-server) (do_llama) ;; x11) (do_x11) ;; esac || say "не запустился снова: $N"
    done
  fi
  [ "$RC" = 0 ]
}

do_restore() { # do_restore <файл|->
  IN=$1
  [ -n "$IN" ] || die "откуда: debian.sh restore <файл.tar.gz> (- = из stdin)"
  IN=$(abs_path "$IN")
  [ "$IN" = - ] || [ -f "$IN" ] || die "нет файла $IN"
  [ -e "$R" ] && die "Debian уже есть в $R - поверх не восстанавливаю. Убрать его целиком: debian.sh remove yes, потом restore"
  command -v tar >/dev/null || die "нет tar"
  # распаковка рядом и перенос: оборвалась (место, битый архив) - $R не появится наполовину
  ST=$BASE/.restore; rm -rf "$ST"; mkdir -p "$ST" || die "не создаётся $ST"
  say "распаковка копии ... (минуты)"
  # --numeric-owner: владельцы - числами из копии, а не по именам из базы Android (там audio, nobody - другие числа)
  wakelock on; tar -xzpf "$IN" -C "$ST" --numeric-owner; RC=$?; wakelock off
  [ "$RC" = 0 ] || { rm -rf "$ST"; die "распаковка не удалась (архив битый или мало места) - ничего не изменено"; }
  { [ -x "$ST/debian/bin/sh" ] && [ -f "$ST/debian/etc/passwd" ]; } || { rm -rf "$ST"; die "в архиве нет Debian (debian/bin/sh) - это копия debian.sh backup?"; }
  mv "$ST/debian" "$R" || { rm -rf "$ST"; die "не перенести в $R"; }
  if [ -f "$ST/debian.conf" ]; then # настройки - из копии: они к этому Debian (пользователь, порты)
    [ -f "$CONF" ] && ! cmp -s "$CONF" "$ST/debian.conf" && mv "$CONF" "$CONF.before-restore" && say "прежний debian.conf: $CONF.before-restore"
    mv "$ST/debian.conf" "$CONF"
  fi
  rm -rf "$ST"
  mkdir -p "$R/proc" "$R/sys" "$R/dev" "$R/run" "$R/tmp"; chmod 1777 "$R/tmp"
  if [ -s "$R/var/lib/fold2-caps" ] && [ -x "$R/usr/sbin/setcap" ]; then
    # строка: "<файл> <capabilities>", в имени файла могут быть пробелы - capabilities последним словом
    in_chroot /bin/sh -c 'while read -r L; do F=${L% *}; [ -e "$F" ] && setcap "${L##* }" "$F"; done </var/lib/fold2-caps' \
      || say "не все file capabilities вернулись (например, ping от пользователя может не работать)"
  fi
  rm -f "$R/var/lib/fold2-caps"
  say "Debian восстановлен: $R. Дальше: debian.sh ssh (или x11), автозапуск: debian.sh autostart on"
}

do_status() {
  echo "rootfs: $R $( [ -x "$R/bin/sh" ] && echo '(есть)' || echo '(нет)')"
  [ -x "$R/bin/sh" ] && echo "настройка Debian: $( [ -f "$DONE" ] && echo закончена || echo 'НЕ закончена (продолжить: debian.sh install -)')"
  echo "монтирований: $(mounts_in | wc -l)"
  echo "процессов в chroot: $(chroot_pids | wc -l)"
  for N in sshd dockerd llama-server; do
    P=$(comm_pids "$N" | head -n 1)
    # cpuset не "/" (например /background) - процесс зажат на малых ядрах
    if [ -n "$P" ]; then echo "$N: работает (pid $P, cpuset $(cat "/proc/$P/cpuset" 2>/dev/null))"; else echo "$N: нет"; fi
  done
  echo "рабочий стол (XFCE): $(x11_up && echo работает || echo нет); при загрузке: $([ "$AUTO_X11" = 1 ] && echo да || echo 'нет (AUTO_X11=1 в debian.conf)')"
  batt_line
  temps
  IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  [ -n "$IP" ] && echo "Wi-Fi IP: $IP  (ssh -p $SSH_PORT $DEB_USER@$IP$([ -n "$LLAMA_API_KEY" ] && echo ", http://$IP:$LLAMA_PORT"))"
  return 0
}

BATT=/sys/class/power_supply/battery
batt_line() {
  [ -r "$BATT/capacity" ] || return 0
  # temp - в десятых долях °C, бывает и меньше нуля
  T=$(awk '{ printf "%.1f", $1 / 10; exit }' "$BATT/temp" 2>/dev/null); L=$(cat "$BATT/batt_full_capacity" 2>/dev/null)
  case "$L" in ''|0|100) L="" ;; *) L="$L%" ;; esac
  echo "батарея: $(cat "$BATT/capacity")% $(cat "$BATT/status" 2>/dev/null)${T:+, $T°C}${L:+, предел заряда $L}"
}

# Предел заряда Samsung (sb_full_soc.c ядра): на N% зарядка останавливается, а телефон питается от адаптера
# (CHARGING_OFF), снова заряжается с N-2%. Это же делает Настройки -> Защита аккумулятора. Не путать с
# batt_slate_mode (работа от батареи под кабелем) - для сервера он вреден.
do_battery() {
  F=$BATT/batt_full_capacity
  if [ -n "$1" ]; then
    [ -e "$F" ] || die "нет $F (в ядре нет предела заряда Samsung)"
    case "$1" in
      off) N=100 ;;
      [5-9][0-9]) N=$1 ;;
      *) die "предел: 50-99 или off" ;;
    esac
    echo "$N" >"$F" 2>/dev/null || die "не записать $N в $F"
  fi
  batt_line
}

temps() { # самый горячий датчик в группах: cpu, cpuss, gpuss (GPU), q6-hvx (cDSP), npu
  for Z in /sys/class/thermal/thermal_zone*; do
    T=$(cat "$Z/type" 2>/dev/null) || continue
    case "$T" in cpu-*-usr|cpuss-*-usr|gpuss-*-usr|q6-hvx-usr|npu-usr) V=$(cat "$Z/temp" 2>/dev/null) && echo "$T $V" ;; esac
  done | awk '{ g = $1; sub(/-usr$/, "", g); sub(/(-[0-9]+)+$/, "", g); v = $2 + 0; if (v > 1000) v /= 1000
    if (!(g in m)) { k[++n] = g; m[g] = v } else if (v > m[g]) m[g] = v }
    END { for (i = 1; i <= n; i++) s = s (i > 1 ? ", " : "") sprintf("%s %.0f°C", k[i], m[k[i]]); if (n) print "температура: " s }'
}

# Логи прошлой загрузки: pstore (ramoops), Samsung /proc/last_kmsg и /proc/reset_*, logcat -L.
# Первое за загрузку чтение /proc/reset_reason Samsung засчитывает в свою статистику перезагрузок (так делает и сама система).
do_bootlog() {
  L=$BASE/bootlogs
  if [ "$1" = ls ]; then
    for X in "$L"/*; do [ -d "$X" ] && echo "${X##*/}: $(head -n 1 "$X/reset_reason" 2>/dev/null)"; done
    return 0
  fi
  case "$BOOTLOG_KEEP" in ''|0|*[!0-9]*) K=5 ;; *) K=$BOOTLOG_KEEP ;; esac
  ID=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null); ID=${ID:-noid}
  for X in "$L"/*-"$ID"; do [ -d "$X" ] && rm -rf "$X"; done # эту загрузку уже собирали - собираем заново
  O=$L/$(date +%Y%m%d-%H%M%S)-$ID
  mkdir -p "$O" || die "не создать $O"
  for F in /sys/fs/pstore/*; do [ -f "$F" ] && cp "$F" "$O/pstore-${F##*/}" 2>/dev/null; done
  for F in reset_reason reset_summary reset_history reset_klog reset_tzlog auto_comment last_kmsg; do
    [ -r "/proc/$F" ] && cat "/proc/$F" >"$O/$F" 2>/dev/null
  done
  command -v logcat >/dev/null 2>&1 && logcat -L -d >"$O/logcat-last.txt" 2>/dev/null
  { echo "собрано: $(date)"; for P in ro.boot.bootreason sys.boot.reason ro.boot.debug_level; do echo "$P=$(getprop "$P" 2>/dev/null)"; done; } >"$O/info.txt"
  for F in "$O"/*; do [ -s "$F" ] || rm -f "$F"; done
  # shellcheck disable=SC2012
  ls -1 "$L" | sort -r | tail -n +$((K + 1)) | while read -r X; do rm -rf "${L:?}/$X"; done
  say "логи прошлой загрузки: $O (причина: $(head -n 1 "$O/reset_reason" 2>/dev/null || echo '?'))"
}

valid_user() { # как NAME_REGEX Debian по умолчанию: имя попадает в команды внутри chroot
  case "$1" in ''|[!a-z_]*|*[!a-z0-9_-]*) return 1 ;; esac
  [ ${#1} -le 32 ]
}

do_install() {
  TARBALL=$1; [ -n "$2" ] && DEB_USER=$2
  valid_user "$DEB_USER" || die "имя пользователя '$DEB_USER': латиница в нижнем регистре, цифры, _ и -, с буквы или _, до 32 символов"
  [ -f "$DONE" ] && die "уже установлено в $R (переставить начисто: debian.sh remove yes, затем install)"
  if [ -x "$R/bin/sh" ] && [ -f "$R/root/setup_in_chroot.sh" ]; then
    # rootfs распакован целиком (setup_in_chroot.sh кладётся после распаковки), а настройка не закончилась
    say "Debian уже распакован, но настройка не закончена - продолжаю её (повторять можно)"
  else
    [ -f "$TARBALL" ] || die "нет файла rootfs: $TARBALL"
    BB=/data/adb/magisk/busybox; [ -x "$BB" ] || die "нет $BB (нужен Magisk)"
    mkdir -p "$R"
    say "распаковка $TARBALL ..."
    "$BB" tar -xJpf "$TARBALL" -C "$R" || { say "busybox tar -J не смог, пробую xzcat"; xzcat "$TARBALL" | "$BB" tar -xpf - -C "$R"; } || die "распаковка не удалась"
  fi
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
      echo "LLAMA_NGL=$LLAMA_NGL"; echo "LLAMA_API_KEY=    # если задать - сервер с ключом и виден в сети; пусто - только 127.0.0.1"; echo "LLAMA_ARGS="
      echo "X11_SELINUX_PERMISSIVE=$X11_SELINUX_PERMISSIVE"; echo "AUTO_SSH=$AUTO_SSH"; echo "AUTO_DOCKER=$AUTO_DOCKER"; echo "AUTO_LLAMA=$AUTO_LLAMA"
      echo "BATT_LIMIT=       # 50-99: предел заряда при загрузке (autostart) для телефона всегда на зарядке; пусто - не трогать"
      echo "AUTO_BOOTLOG=$AUTO_BOOTLOG"; echo "BOOTLOG_KEEP=$BOOTLOG_KEEP"; } > "$CONF"
  fi
  do_start
  say "установка пакетов (XFCE, Docker, Vulkan, сборочные) - 10-30 минут, нужен интернет"
  in_chroot /bin/bash /root/setup_in_chroot.sh "$DEB_USER" || die "setup_in_chroot.sh завершился с ошибкой (лог выше); продолжить: debian.sh install - $DEB_USER"
  say "готово. Пароль пользователя $DEB_USER задай: debian.sh run passwd $DEB_USER"
}

# install-bg: установка отдельно от adb. Через «adb shell» её обрывали выдернутый кабель, уснувший ПК, закрытый
# терминал (adbd закрывает канал: SIGHUP/SIGPIPE посреди dpkg). Своя сессия (setsid), вывод - в файл, без HUP.
IPID=$BASE/install.pid; ILOG=$BASE/install.log; IRC=$BASE/install.rc
install_running() {
  P=$(cat "$IPID" 2>/dev/null) && [ -n "$P" ] && [ -d "/proc/$P" ] || return 1
  tr '\000' ' ' <"/proc/$P/cmdline" 2>/dev/null | grep -q " install-run" # не чужой процесс с тем же pid
}

do_install_bg() {
  if install_running; then say "установка уже идёт (pid $(cat "$IPID")), лог: $ILOG"; return 0; fi
  rm -f "$IRC" "$IPID"; : >"$ILOG"
  SHX=/system/bin/sh; [ -x "$SHX" ] || SHX="sh" # не sh из PATH: в Debian/Ubuntu это dash
  setsid "$SHX" "$SELF" install-run "$@" </dev/null >>"$ILOG" 2>&1 &
  # быстрая ошибка (нет rootfs) успевает закончиться до проверки: тогда pid уже нет, но есть код
  N=0; while [ ! -s "$IPID" ] && [ ! -f "$IRC" ] && [ $N -lt 50 ]; do sleep 0.2; N=$((N+1)); done
  [ -s "$IPID" ] || [ -f "$IRC" ] || die "установка не запустилась (лог: $ILOG)"
  say "установка идёт отдельно от adb: обрыв связи её не прервёт; лог: $ILOG, код: $IRC"
}

do_install_run() { # из install-bg: код - в $IRC, всегда exit (debian.sh могли заменить на диске, дальше не читаем)
  trap '' HUP
  echo $$ >"$IPID.new" && mv "$IPID.new" "$IPID"
  wakelock on fold2-install
  ( do_install "$@" ); RC=$?
  wakelock off fold2-install
  echo "$RC" >"$IRC.new" && mv "$IRC.new" "$IRC"; rm -f "$IPID"
  exit "$RC"
}

do_install_log() { # install-log [N]: строки install.log после N-й (только целые), в конце "@@fold2 <строк> <код|run|dead>"
  N=${1:-0}; case "$N" in ''|*[!0-9]*) N=0 ;; esac
  # сначала состояние: код пишется после всего вывода - если он есть, лог уже полный
  if [ -f "$IRC" ]; then ST=$(cat "$IRC"); elif install_running; then ST=run
  elif [ -f "$IRC" ]; then ST=$(cat "$IRC"); else ST=dead; fi # закончилась между проверками
  L=0; [ -f "$ILOG" ] && L=$(wc -l <"$ILOG" | tr -d ' ')
  if [ "$ST" = run ]; then [ "$L" -gt "$N" ] && sed -n "$((N + 1)),${L}p" "$ILOG"
  elif [ -f "$ILOG" ]; then sed -n "$((N + 1)),\$p" "$ILOG"; [ -n "$(tail -c 1 "$ILOG")" ] && echo; fi # без \n в конце
  echo "@@fold2 $L ${ST:-dead}"
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
    # образ разреженный: кончится место на /data - ext4 в нём получит ошибки записи, а Android останется без места
    FREE=$(df -k "$R/var/lib" 2>/dev/null | awk 'NR > 1 {print $4; exit}')
    case "$FREE" in
      ""|*[!0-9]*) ;;
      *) [ "$FREE" -ge $(( (DOCKER_IMG_GB + 4) * 1048576 )) ] || say "ВНИМАНИЕ: на /data свободно $((FREE / 1048576)) ГБ, а образ - до ${DOCKER_IMG_GB} ГБ: если /data заполнится, данные Docker испортятся. Меньше: DOCKER_IMG_GB в $CONF (до создания образа)" ;;
    esac
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
  # NAT для IPv6 (CONFIG_IP6_NF_NAT) есть в ядре только с f2q-5; IPv6 в Docker 26 (Debian 13) и так выключен -
  # ip6tables не включаем, чтобы dockerd запускался и на старых ядрах
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
    # имена таблиц Android (wlan0, rmnet_data0) знает только iproute2 телефона; в автозапуске "ip" - busybox Magisk
    IP=ip; [ -x /system/bin/ip ] && IP=/system/bin/ip
    $IP rule del pref 5000 2>/dev/null; $IP rule del pref 5001 2>/dev/null
    $IP rule add pref 5000 from all lookup main
    [ -n "$D" ] && { $IP rule add pref 5001 from 172.16.0.0/12 lookup "$D" || say "ip rule для $D не добавилось - у контейнеров не будет сети"; }
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
  # сервер работает от root: без ключа - только 127.0.0.1 (с ПК: adb forward tcp:$LLAMA_PORT tcp:$LLAMA_PORT)
  H=127.0.0.1; [ -n "$K" ] && H=0.0.0.0
  GPU=""; [ "$LLAMA_DEVICE" != none ] && GPU=". /etc/profile.d/fold2-gpu.sh;"
  TS=""
  if [ -n "$LLAMA_CPUS" ]; then
    if in_chroot taskset -c "$LLAMA_CPUS" true 2>/dev/null; then TS="taskset -c $LLAMA_CPUS"
    else say "taskset -c $LLAMA_CPUS не работает (cpuset $(cat /proc/$$/cpuset 2>/dev/null)) - без привязки к ядрам"; fi
  fi
  in_chroot /bin/sh -c "$GPU export LLAMA_CACHE=/var/lib/llama LD_LIBRARY_PATH=/opt/llama.cpp/bin; mkdir -p /var/lib/llama;
    nohup $TS /opt/llama.cpp/bin/llama-server $M --host $H --port $LLAMA_PORT \
      -t $LLAMA_THREADS -c $LLAMA_CTX --device $LLAMA_DEVICE -ngl $LLAMA_NGL --jinja $K $LLAMA_ARGS \
      >/var/log/llama-server.log 2>&1 &"
  say "llama-server запускается (модель качается при первом запуске): http://$([ "$H" = 0.0.0.0 ] && echo '<IP телефона>' || echo 127.0.0.1):$LLAMA_PORT  лог: debian.sh llama log"
  [ "$H" = 0.0.0.0 ] || say "без LLAMA_API_KEY сервер не виден в сети (с ПК: adb forward tcp:$LLAMA_PORT tcp:$LLAMA_PORT)"
}

x11_up() { [ -S "$R/tmp/.X11-unix/X0" ] && [ -n "$(comm_pids xfce4-session)" ]; } # X-сервер и сеанс XFCE живы
x11_open() { am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1; }

x11_selinux_back() { # SELinux снова Enforcing, если Permissive его сделал x11
  [ -f "$R/run/fold2-selinux-x11" ] || return 0
  rm -f "$R/run/fold2-selinux-x11"; setenforce 1 2>/dev/null && say "SELinux снова Enforcing"
  return 0
}

do_x11() {
  case "$1" in
    ""|start) ;;
    stop) for P in $(comm_pids xfce4-session); do kill "$P" 2>/dev/null; done
          pkill -f termux-x11 2>/dev/null; x11_selinux_back; say "рабочий стол остановлен"; return 0 ;;
    restart) do_x11 stop >/dev/null; sleep 2 ;;
    *) die "x11 [stop|restart]" ;;
  esac
  # второй запуск (кнопка в Magisk, автозапуск) не должен убивать открытый рабочий стол со всеми окнами
  if [ "$1" != restart ] && x11_up; then x11_open; say "рабочий стол уже запущен - открываю Termux:X11"; return 0; fi
  do_start >/dev/null
  PKG=$(pm path com.termux.x11 2>/dev/null | head -n1 | cut -d: -f2)
  [ -n "$PKG" ] || die "не установлен Termux:X11 (pc_install_debian.sh ставит его)"
  if [ "$X11_SELINUX_PERMISSIVE" = 1 ] && [ "$(getenforce)" = Enforcing ]; then
    say "SELinux -> Permissive, пока работает рабочий стол (требование Termux:X11 для chroot; X11_SELINUX_PERMISSIVE=0 - не трогать)"
    setenforce 0 && : >"$R/run/fold2-selinux-x11" # отметка в tmpfs: Enforcing вернут x11 stop и stop
  fi
  pkill -f termux-x11 2>/dev/null; sleep 1
  rm -rf "$R/tmp/.X11-unix" "$R/tmp/.X0-lock"
  (export TMPDIR="$R/tmp" XKB_CONFIG_ROOT="$R/usr/share/X11/xkb" CLASSPATH="$PKG"
   nohup /system/bin/app_process / --nice-name=termux-x11 com.termux.x11.CmdEntryPoint :0 >"$BASE/termux-x11.log" 2>&1 &)
  N=0; while [ $N -lt 15 ] && [ ! -S "$R/tmp/.X11-unix/X0" ]; do sleep 1; N=$((N+1)); done
  [ -S "$R/tmp/.X11-unix/X0" ] || { cat "$BASE/termux-x11.log"; x11_selinux_back; die "X-сервер Termux:X11 не поднялся"; }
  x11_open # до первой разблокировки не откроется - не страшно: X-сервер ждёт приложение и подключит его, когда его откроют
  in_chroot /bin/su -l "$DEB_USER" -c 'export DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-$USER; mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR;
    [ -f /etc/profile.d/fold2-gpu.sh ] && . /etc/profile.d/fold2-gpu.sh; nohup dbus-launch --exit-with-session startxfce4 >/tmp/xfce.log 2>&1 &'
  say "XFCE запущен в Termux:X11 (в DeX окно можно перетащить на монитор и развернуть)"
  if [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    say "SELinux Enforcing: если в Termux:X11 чёрный экран - X11_SELINUX_PERMISSIVE=1 в $CONF (Permissive до перезагрузки)"
  fi
}

MOD=/data/adb/modules/fold2
do_module() {
  case "$1" in
    on|"") mkdir -p "$MOD"
      { echo "id=fold2"; echo "name=Fold2: Debian (компьютер)"; echo "version=1"; echo "versionCode=1"; echo "author=fold2-un1ca"
        echo "description=«Действие» - рабочий стол XFCE в Termux:X11 (Debian запускается сам). Остальное: $BASE/debian.sh"; } >"$MOD/module.prop"
      { printf '#!/system/bin/sh\n# fold2: кнопка «Действие» в Magisk -> Модули (убрать: debian.sh module off)\n'
        printf "export FOLD2_BASE='%s'\n" "$BASE"
        echo 'sh "$FOLD2_BASE/debian.sh" x11; sh "$FOLD2_BASE/debian.sh" status'; } >"$MOD/action.sh"
      : >"$MOD/skip_mount"; chmod 755 "$MOD/action.sh"; [ "$SELF" = "$BASE/debian.sh" ] || cp "$SELF" "$BASE/debian.sh"
      say "кнопка: Magisk -> Модули -> «Fold2: Debian (компьютер)» -> «Действие» - рабочий стол" ;;
    off) rm -rf "$MOD"; say "кнопка в Magisk убрана" ;;
    *) die "module on|off" ;;
  esac
}

do_autostart() {
  F=/data/adb/service.d/fold2-debian.sh
  case "$1" in
    on) mkdir -p /data/adb/service.d
        { printf '#!/system/bin/sh\n# fold2: автозапуск Debian (debian.sh autostart off - убрать)\n'
          printf "BASE='%s'\n" "$BASE"
          cat <<'EOS'
export FOLD2_BASE="$BASE"
D=$BASE/debian.sh; R=$BASE/debian
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done; sleep 20
AUTO_SSH=1; AUTO_DOCKER=0; AUTO_LLAMA=0; AUTO_X11=0; AUTO_BOOTLOG=1; BATT_LIMIT=; LLAMA_MODEL= # как в debian.sh без debian.conf
# shellcheck disable=SC1091
[ -f "$BASE/debian.conf" ] && . "$BASE/debian.conf"
exec >>"$BASE/autostart.log" 2>&1; echo "== $(date)"
[ "${AUTO_BOOTLOG:-1}" = 1 ] && sh "$D" bootlog
if [ -n "$BATT_LIMIT" ] && sh "$D" battery "$BATT_LIMIT"; then
  # система (Защита аккумулятора) может переписать предел - сверяем раз в 10 минут
  ( F=/sys/class/power_supply/battery/batt_full_capacity; N=$BATT_LIMIT
    while sleep 600; do [ "$(cat "$F" 2>/dev/null)" = "$N" ] || { echo "$N" >"$F" && echo "$(date): предел заряда снова $N%"; }; done ) &
fi
sh "$D" start
[ "$AUTO_SSH" = 1 ] && sh "$D" ssh
[ "$AUTO_DOCKER" = 1 ] && sh "$D" docker
# рабочий стол: X-сервер Termux:X11 и XFCE - сразу; приложение подключится к ним, когда его откроют (или в DeX)
[ "$AUTO_X11" = 1 ] && pm path com.termux.x11 >/dev/null 2>&1 && sh "$D" x11
if [ "$AUTO_LLAMA" = 1 ]; then
  # модель в /sdcard читается только после первой разблокировки телефона (шифрование FBE) - ждём до суток
  N=0; while [ -n "$LLAMA_MODEL" ] && [ ! -r "$R$LLAMA_MODEL" ] && [ $N -lt 5760 ]; do sleep 15; N=$((N+1)); done
  # без LLAMA_MODEL модель берётся с Hugging Face (-hf) - ждём сеть (Wi-Fi подключается не сразу), до 10 минут
  N=0; while [ -z "$LLAMA_MODEL" ] && ! ip route get 1.1.1.1 >/dev/null 2>&1 && [ $N -lt 40 ]; do sleep 15; N=$((N+1)); done
  sh "$D" llama
fi
EOS
        } > "$F"; chmod 755 "$F"; [ "$SELF" = "$BASE/debian.sh" ] || cp "$SELF" "$BASE/debian.sh"
        say "автозапуск включён ($F; что именно - AUTO_* в $CONF)"; do_module on ;;
    off) rm -f "$F"; say "автозапуск выключен" ;;
    *) die "autostart on|off" ;;
  esac
}

CMD=$1; [ $# -gt 0 ] && shift
case "$CMD" in
  install) do_install "$@" ;;
  install-bg) do_install_bg "$@" ;;
  install-run) do_install_run "$@" ;;
  install-log) do_install_log "$@" ;;
  start) do_start ;;
  stop) do_stop ;;
  status) do_status ;;
  shell|login) do_shell "$@" ;;
  run) do_start >/dev/null; in_chroot "$@" ;;
  x11|xfce|desktop) do_x11 "$@" ;;
  ssh|sshd) do_ssh ;;
  docker) do_docker "$@" ;;
  llama) do_llama "$@" ;;
  autostart) do_autostart "$@" ;;
  module|button) do_module "$@" ;;
  battery|batt) do_battery "$@" ;;
  bootlog) do_bootlog "$@" ;;
  backup) do_backup "$@" ;;
  restore) do_restore "$@" ;;
  remove|uninstall) do_remove "$@" ;;
  *) sed -n '3,/^$/p' "$SELF" | sed '/^$/d'; exit 1 ;; # справка - шапка файла до пустой строки
esac
