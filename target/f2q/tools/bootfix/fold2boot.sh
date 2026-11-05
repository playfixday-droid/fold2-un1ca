#!/system/bin/sh
# Fold2 (f2q) UN1CA: помощник первой загрузки (Magisk overlay.d, запускается из fold2.rc).
#   fix   - on post-fs, до mount_all --late. Если /data «пустая» - стёрта (первые 4 КиБ 00/FF), свежая f2fs
#           без шифрования (после сброса стоковым recovery) или с прерванным шифрованием на месте - удаляет
#           старый ключ /metadata/vold/metadata_encryption, а свежую/недошифрованную f2fs ещё и «стирает»
#           (обнуляет 8 КиБ с обоими суперблоками). Тогда fs_mgr (formattable) отдаёт /data vold на
#           форматирование: новый ключ, dm-default-key, make_f2fs с casefold/project_quota (их требует
#           emulated storage) вместо шифрования на месте. /data с данными (много файлов) не трогается.
#   log   - логи загрузки в /cache/fold2log/boot-N (раз в 5 с sync - переживают зависание и перезагрузку).
#           Хранятся boot-1..3 и 5 последних. Выключить: touch /cache/fold2log/off
#   check - только показать решение (для тестов): FOLD2_USERDATA=образ sh fold2boot.sh check
# Ничего не ждёт бесконечно; любые ошибки только пишутся в лог, загрузка идёт дальше.
PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
U=${FOLD2_USERDATA:-/dev/block/bootdevice/by-name/userdata}
K=${FOLD2_KEYDIR:-/metadata/vold/metadata_encryption}
D=${FOLD2_LOGDIR:-/cache/fold2log}
HOLD=${FOLD2_HOLD:-180}   # сколько ещё писать логи после sys.boot_completed=1, с
TMAX=${FOLD2_TMAX:-1800}  # и не дольше этого uptime, с (зависшая загрузка)
MAXBLK=262144   # «свежая» f2fs: не больше 1 ГиБ занятых блоков (после mkfs - десятки)
MAXINO=1024     # и не больше 1024 inode (после первой загрузки любой системы - десятки тысяч)

say() {
  echo "$*"
  [ -n "$FOLD2_TEST" ] || echo "fold2boot: $*" > /dev/kmsg 2>/dev/null
}
# rd <файл> <блок 4 КиБ> <смещение в блоке> <4|8> -> беззнаковое десятичное (little-endian)
rd() { v=$(dd if="$1" bs=4096 skip="$2" count=1 2>/dev/null | od -An -tu"$4" -j "$3" -N "$4"); echo $v; }
# num <строка> <максимум>: десятичное число и не больше максимума (длина <=9: без переполнения mksh)
num() { case $1 in ''|*[!0-9]*) return 1 ;; esac; [ ${#1} -le 9 ] && [ "$1" -le "$2" ]; }

wiped() {  # как partition_wiped() libcutils: первые 4096 байт все 0x00 или все 0xFF
  h=$(dd if="$1" bs=4096 count=1 2>/dev/null | od -An -tx1 -v)
  [ "$(echo "$h" | wc -l)" -eq 256 ] || return 1      # прочитано ровно 4096 байт (по 16 в строке)
  echo "$h" | grep -q '[^ 0]' || return 0
  echo "$h" | grep -q '[^ f]' || return 0
  return 1
}

f2fs_fresh() {  # суперблок f2fs @1024 (magic 0xF2F52010) и оба checkpoint-пака почти пустые
  m=$(rd "$1" 0 1024 4)
  [ "$m" = 4076150800 ] || { echo "f2fs: нет суперблока (magic=$m)"; return 1; }
  lbs=$(rd "$1" 0 1040 4); lbps=$(rd "$1" 0 1044 4); cp=$(rd "$1" 0 1100 4)
  echo "f2fs: log_blocksize=$lbs log_blocks_per_seg=$lbps cp_blkaddr=$cp"
  [ "$lbs" = 12 ] && num "$lbps" 12 && [ "$lbps" -ge 1 ] && num "$cp" 99999999 && [ "$cp" -ge 1 ] || {
    echo "f2fs: странный суперблок - не трогаю"; return 1; }
  n=0; ok=1
  for b in $cp $((cp + (1 << lbps))); do
    ver=$(rd "$1" "$b" 0 8); vb=$(rd "$1" "$b" 16 8); vi=$(rd "$1" "$b" 148 4)
    echo "f2fs: checkpoint @$b ver=$ver valid_blocks=$vb valid_inodes=$vi"
    [ "$ver" = 0 ] && continue          # второй пак сразу после mkfs пустой
    n=$((n + 1))
    num "$vb" $MAXBLK && num "$vi" $MAXINO || ok=0
  done
  [ $n -ge 1 ] && [ $ok = 1 ]
}

decide() {  # печатает: wiped | fresh | interrupted | keep | nodev
  if [ ! -b "$U" ] && [ ! -f "$U" ]; then echo nodev; return; fi
  if wiped "$U"; then echo wiped; return; fi
  if f2fs_fresh "$U" > /dev/null; then echo fresh; return; fi
  if [ -e "$K/in_progress" ]; then echo interrupted; return; fi
  echo keep
}

fix() {
  mkdir -p "$D" 2>/dev/null
  L=$D/fix.log
  [ -f "$L" ] && [ "$(stat -c %s "$L" 2>/dev/null || echo 0)" -gt 262144 ] && mv -f "$L" "$L.old"
  {
    echo "== fix $(date '+%F %T') uptime=$(cut -d' ' -f1 /proc/uptime) userdata=$U"
    ls -la "$K" "$K/key" 2>&1 | head -20
    f2fs_fresh "$U"
    a=$(decide)
    case $a in
      wiped)       say "userdata стёрта: удаляю старый ключ, fs_mgr отформатирует (formattable)" ;;
      fresh)       say "userdata - свежая f2fs без шифрования: стираю суперблоки и ключ, vold отформатирует" ;;
      interrupted) say "шифрование /data на месте было прервано: fs_mgr всё равно форматирует - стираю суперблоки и ключ" ;;
      keep)        say "userdata с данными или уже зашифрована - не трогаю" ;;
      *)           say "нет $U - ничего не делаю" ;;
    esac
    if [ "$a" = fresh ] || [ "$a" = interrupted ]; then
      dd if=/dev/zero of="$U" bs=4096 count=2 conv=notrunc 2>&1
      sync; blockdev --flushbufs "$U" 2>/dev/null
      if wiped "$U"; then say "суперблоки затёрты"; else say "ОШИБКА: суперблоки не затёрлись"; fi
    fi
    if [ "$a" = wiped ] || [ "$a" = fresh ] || [ "$a" = interrupted ]; then
      if [ -e "$K" ]; then rm -rf "$K" && say "удалён $K"; fi
      sync
    fi
  } >> "$L" 2>&1
}

snap() {  # снимок состояния загрузки: свойства (только при изменении) и процессы (раз в 30 с)
  s=$(getprop | grep -E '^\[(init\.svc\.|sys\.boot_completed|dev\.bootcomplete|vold\.|ro\.crypto\.|apexd\.|keystore\.|odsign\.|sys\.usb\.(config|state)|service\.bootanim|persist\.vendor\.softdog|ro\.boot\.(verifiedbootstate|bootreason))')
  if [ "$s" != "$last" ]; then { echo "=== $1"; echo "$s"; } >> "$B/props.txt"; last=$s; fi
  case $(( $2 % 6 )) in 0) { echo "=== $1"; ps -A -o PID,PPID,S,TIME,RSS,NAME 2>/dev/null || ps -A; } >> "$B/ps.txt" ;; esac
}

log() {
  [ -e "$D/off" ] && exit 0
  mkdir -p "$D" || exit 0
  free=$(df -k "$D" 2>/dev/null | awk 'NR==2 {print $4}')
  case $free in ''|*[!0-9]*) free=0 ;; esac
  [ "$free" -ge 65536 ] || { echo "мало места в $D: $free КиБ" >> "$D/fix.log"; exit 0; }
  n=$(cat "$D/seq" 2>/dev/null); case $n in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1)); echo $n > "$D/seq"
  o=$((n - 5)); [ $o -gt 3 ] && rm -rf "$D/boot-$o"
  B=$D/boot-$n; mkdir -p "$B" || exit 0
  exec > "$B/fold2boot.txt" 2>&1
  echo "boot-$n $(date '+%F %T') uptime=$(cut -d' ' -f1 /proc/uptime)"
  cat /proc/cmdline > "$B/cmdline.txt"
  cp /proc/last_kmsg "$B/last_kmsg.txt" 2>/dev/null       # ядро прошлой загрузки (Samsung)
  for f in /sys/fs/pstore/*; do [ -f "$f" ] && cp "$f" "$B/pstore-${f##*/}"; done
  cp "$D/fix.log" "$B/fix.log" 2>/dev/null
  getprop > "$B/getprop-start.txt"
  dmesg -w > "$B/dmesg.txt" 2>&1 &
  DP=$!
  ( while [ ! -e "$B/.stop" ]; do                         # logd может перезапуститься - logcat заново
      logcat -b all -v threadtime -f "$B/logcat.txt" -r 2048 -n 4 &
      echo $! > "$B/.logcat"
      [ -e "$B/.stop" ] && kill $! 2>/dev/null
      wait $!; sleep 2
    done ) &
  LP=$!
  last=; i=0; done=
  while :; do
    up=$(cut -d' ' -f1 /proc/uptime); up=${up%.*}
    snap "uptime ${up}s $(date +%T)" $i
    sync
    if [ -z "$done" ] && [ "$(getprop sys.boot_completed)" = 1 ]; then done=$up; echo "boot_completed: uptime ${up}s"; fi
    [ -n "$done" ] && [ $((up - done)) -ge $HOLD ] && break
    [ "$up" -ge $TMAX ] && { echo "uptime $TMAX с без boot_completed - стоп"; break; }
    sz=$(stat -c %s "$B/dmesg.txt" 2>/dev/null || echo 0)
    [ "$sz" -gt 16777216 ] && kill $DP 2>/dev/null
    sleep ${FOLD2_STEP:-5}; i=$((i + 1))
  done
  if [ -d /data/tombstones ]; then
    mkdir -p "$B/tombstones"; ls -la /data/tombstones > "$B/tombstones/ls.txt" 2>&1
    cp /data/tombstones/tombstone_* "$B/tombstones/" 2>/dev/null
  fi
  if [ -d /data/system/dropbox ]; then
    mkdir -p "$B/dropbox"; ls -la /data/system/dropbox > "$B/dropbox/ls.txt" 2>&1
    for f in /data/system/dropbox/*crash* /data/system/dropbox/*TOMBSTONE* /data/system/dropbox/*anr* /data/system/dropbox/*wtf*; do
      [ -f "$f" ] && cp "$f" "$B/dropbox/"
    done
  fi
  getprop > "$B/getprop-end.txt"
  touch "$B/.stop"; kill "$(cat "$B/.logcat" 2>/dev/null)" 2>/dev/null
  sleep 1; kill "$(cat "$B/.logcat" 2>/dev/null)" $LP $DP 2>/dev/null
  echo "конец $(date '+%F %T') uptime=$(cut -d' ' -f1 /proc/uptime)"
  sync
}

case $1 in
  fix) fix ;;
  log) log ;;
  check) f2fs_fresh "$U"; echo "decision: $(decide)" ;;
  *) echo "usage: $0 fix|log|check"; exit 1 ;;
esac
exit 0
