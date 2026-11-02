#!/system/bin/sh
# fold2: проверка телефона после прошивки f2q (или её обновления): загрузка, root, модем и SIM, Wi-Fi, Bluetooth, NFC,
# камеры, экран, датчики, батарея, cDSP (NPU), ядро для Docker, место; какие службы падают и что режет SELinux.
# Root не обязателен (Magisk можно ещё не ставить) - с root подробнее: dmesg, /proc/config.gz, падения служб init.
#   adb push check_phone.sh /data/local/tmp/ && adb shell sh /data/local/tmp/check_phone.sh > fold2-check.txt
#   с root:  adb shell su -c "sh /data/local/tmp/check_phone.sh" > fold2-check.txt    (с ПК проще: pc_check_phone.sh)
# Вывод: ИТОГ (OK / ВНИМАНИЕ / НЕТ / ИНФО по пунктам), пустая строка, подробности. IMEI, серийные номера, MAC, ICCID/IMSI,
# номера телефонов (числа от 10 цифр) и адреса почты заменяются на ***, имя сети Wi-Fi не выводится - отчёт можно присылать.

W=/data/local/tmp/fold2-check.$$
mkdir -p "$W" 2>/dev/null || { echo "не создать $W" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
SUM=$W/sum; DET=$W/det; : >"$SUM"; : >"$DET"
NOK=0; NWARN=0; NBAD=0
st() { # st OK|ВНИМАНИЕ|НЕТ|ИНФО <что>
  case "$1" in
    OK) NOK=$((NOK + 1)); echo "OK        $2" ;;
    ВНИМАНИЕ) NWARN=$((NWARN + 1)); echo "ВНИМАНИЕ  $2" ;;
    НЕТ) NBAD=$((NBAD + 1)); echo "НЕТ       $2" ;;
    *) echo "ИНФО      $2" ;;
  esac >>"$SUM"
}
sec() { printf '\n--- %s\n' "$*" >>"$DET"; }
det() { cat >>"$DET"; } # det <<< вывод команды
have() { command -v "$1" >/dev/null 2>&1; }
TO=""; have timeout && TO="timeout 20" # dumpsys зависшей службы не должен останавливать всю проверку
ds() { $TO dumpsys "$@" 2>/dev/null; }
gp() { getprop "$1" 2>/dev/null; }
num() { case "$1" in ""|*[!0-9]*) echo "${2:-0}" ;; *) echo "$1" ;; esac; } # число или $2: вывод служб бывает любым
ROOT=0; [ "$(id -u 2>/dev/null)" = 0 ] && ROOT=1

# все свойства: имя=значение. Имена с серийниками/IMEI/MAC не выводим, а их значения вырезаем из всего отчёта
P=$W/props
getprop 2>/dev/null | sed -n 's/^\[\([^]]*\)\]: \[\(.*\)\]$/\1=\2/p' >"$P"
SENS='serial|imei|meid|iccid|imsi|msisdn|number|mac|addr|uid|did|android_?id|uniqueid'
grep -iE "^[^=]*($SENS)[^=]*=" "$P" | cut -d= -f2- | grep -E '^.{6,}$' | grep -viE '^(unknown|default|none|null|false|true|0x0+)$' |
  sort -u | sed -e 's/[]\/$*.^[]/\\&/g' -e 's/.*/s\/&\/***\/g/' >"$W/lit.sed"
printf '%s\n' 's/[0-9]{10,}/***/g' 's/([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}/**:**:**:**:**:**/g' \
  's/\+[0-9][0-9 ()-]{7,}[0-9]/+***/g' 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/***@***/g' >"$W/gen.sed"
props() { grep -E "^($1)" "$P" | grep -viE "^[^=]*($SENS)[^=]*="; } # props <ERE начала имени>

# --- прошивка
MODEL=$(gp ro.product.model); AV=$(gp ro.build.version.release); BLD=$(gp ro.build.display.id); BL=$(gp ro.boot.bootloader)
AV=${AV:-?}; BLD=${BLD:-?}; BL=${BL:-?}
case "$MODEL" in
  SM-F916B) st OK "прошивка: $MODEL, Android $AV, $BLD; загрузчик $BL" ;;
  *) st ВНИМАНИЕ "прошивка: модель '$MODEL' (ждали SM-F916B), Android $AV, $BLD; загрузчик $BL" ;;
esac
sec "прошивка"; props 'ro\.build\.(display\.id|version\.(release|sdk|security_patch|incremental)|fingerprint|date=)|ro\.product\.(model|device|name)=|ro\.boot\.(bootloader|debug_level|warranty_bit|verifiedbootstate|flash\.locked)=' | det

# --- загрузка
UP=$(num "$(cut -d. -f1 /proc/uptime 2>/dev/null)")
if [ "$(gp sys.boot_completed)" = 1 ]; then st OK "загрузка завершена, телефон работает $((UP / 60)) мин"
else st НЕТ "загрузка НЕ завершена (sys.boot_completed пусто) - проверка неполная"; fi
sec "причина прошлой перезагрузки"; props 'sys\.boot\.reason|ro\.boot\.bootreason|persist\.sys\.boot\.reason' | det

# --- уровень отладки: не LOW - при падении ядра телефон висит в Upload mode вместо перезагрузки
DL=$(gp ro.boot.debug_level)
case "$DL" in
  0x4f4c|0x4F4C) st OK "уровень отладки LOW" ;;
  0x494d|0x494D|0x4948) st ВНИМАНИЕ "уровень отладки $DL (не LOW): при сбое ядра/DSP телефон зависнет в Upload mode - pc_install_debian.sh предложит LOW" ;;
  *) st ИНФО "уровень отладки: ${DL:-неизвестен}" ;;
esac

# --- root, SELinux. Magisk = su в boot (su -v отвечает и без разрешения) + приложение + «доп. настройка» (/data/adb/magisk:
# без неё Magisk не запускает модули и service.d - автозапуск Debian, а debian.sh install не найдёт busybox)
MG=com.topjohnwu.magisk
MV=""; have magisk && MV=$(magisk -c 2>/dev/null)
SUV=""; have su && SUV=$(su -v 2>/dev/null | head -n 1)
case "$SUV" in *MAGISK*) ;; *) SUV="" ;; esac
APP=0; pm list packages "$MG" 2>/dev/null | grep -qx "package:$MG" && APP=1
MV=${MV:-$SUV}; MVN=${MV%%:*}
if [ "$ROOT" = 1 ]; then
  if [ -x /data/adb/magisk/busybox ]; then st OK "root: есть${MV:+ (Magisk $MV)}"
  elif [ -n "$MV" ]; then st НЕТ "Magisk $MVN не настроен до конца (нет /data/adb/magisk): открой приложение Magisk -> «Требуется дополнительная настройка» -> OK (перезагрузка); без этого не работают модули и автозапуск Debian"
  else st ВНИМАНИЕ "root есть, но не от Magisk: debian.sh и автозапуск рассчитаны на Magisk"; fi
  [ "$APP" = 1 ] || [ -z "$MV" ] || st ИНФО "приложение Magisk ($MG) не найдено - скрыто под другим именем или удалено"
elif [ -n "$SUV" ] && [ "$APP" = 0 ]; then
  st ВНИМАНИЕ "Magisk $MVN в boot есть, приложения нет: поставь Magisk-v$MVN.apk из релиза f2q (pc_install_debian.sh ставит сам); проверка без root неполная"
elif [ -n "$SUV" ]; then
  st ВНИМАНИЕ "проверка без root (Magisk $MVN есть): запусти через su -c - будет подробнее; Magisk -> Суперпользователь -> разреши Shell"
elif have su; then st ВНИМАНИЕ "проверка без root; su не от Magisk - debian.sh и автозапуск рассчитаны на Magisk"
else st ВНИМАНИЕ "root нет: в boot нет Magisk (прошит BOOT_noroot?) - прошей AP из релиза f2q-N; проверка без root неполная"; fi
SE=$(getenforce 2>/dev/null)
case "$SE" in
  Enforcing) st OK "SELinux: Enforcing" ;;
  Permissive) st ИНФО "SELinux: Permissive (так делает debian.sh x11 при X11_SELINUX_PERMISSIVE=1; до перезагрузки)" ;;
  *) st ИНФО "SELinux: ${SE:-неизвестно}" ;;
esac

# --- службы init: restarting сейчас = падает и перезапускается
RS=$(sed -n 's/^init\.svc\.\([^=]*\)=restarting$/\1/p' "$P" | tr '\n' ' ' | sed 's/ *$//')
if [ -n "$RS" ]; then st НЕТ "службы падают и перезапускаются: $RS"; else st OK "службы init: ни одна не в цикле перезапуска"; fi
sec "службы init не в состоянии running"; grep -E '^init\.svc\.' "$P" | grep -v '=running$' | head -n 80 | det
if [ "$ROOT" = 1 ] && have dmesg; then
  dmesg 2>/dev/null >"$W/dmesg"
  sed -nE "s/.*init: Service '([^']+)' \(pid [0-9]+\) (exited with status [1-9]|killed by signal|received signal).*/\1/p" "$W/dmesg" |
    sort | uniq -c | sort -rn | head -n 15 >"$W/svc"
  CR=$(awk '$1 >= 3 {printf "%s(%s) ", $2, $1}' "$W/svc")
  [ -n "$CR" ] && st ВНИМАНИЕ "службы падали с загрузки (3 раза и больше): $CR"
  sec "падения служб init с загрузки (dmesg: число, служба)"; det <"$W/svc"
fi

# --- модем и SIM
BB=$(gp gsm.version.baseband); SIMS=$(gp gsm.sim.state); NT=$(gp gsm.network.type); OP=$(gp gsm.operator.alpha)
case "$BB" in
  ""|unknown|,) st НЕТ "модем: нет версии baseband - RIL/модем не поднялся (ошибки radio ниже)" ;;
  *) st OK "модем: $BB" ;;
esac
case "$SIMS" in
  *READY*|*LOADED*) st OK "SIM: $SIMS; сеть: ${OP:-?} ${NT:-?}" ;;
  *) st ВНИМАНИЕ "SIM: ${SIMS:-нет данных} (не вставлена или не видна; ABSENT в обоих слотах при вставленной SIM - RIL)" ;;
esac
sec "связь (gsm.*, ril.*, multisim)"; props 'gsm\.|ril\.|persist\.radio\.|ro\.multisim|persist\.ril|ro\.telephony' | head -n 80 | det
sec "ошибки в logcat -b radio (последние 40)"
logcat -b radio -d 2>/dev/null | grep -iE 'error|fail|exception|not_available|denied' | tail -n 40 | det

# --- Wi-Fi (без имени сети), Bluetooth, NFC
WS=$(cmd wifi status 2>/dev/null | grep -oE '^Wifi is (enabled|disabled|connected|not connected)' | sed 's/^Wifi is //' | tr '\n' ' ' | sed 's/ *$//')
if ! ip link show wlan0 >/dev/null 2>&1; then st НЕТ "Wi-Fi: нет интерфейса wlan0 (драйвер не загрузился?)${WS:+; $WS}"
else
  case "$WS" in
    *disabled*) st ВНИМАНИЕ "Wi-Fi: выключен (включи и запусти проверку снова)" ;;
    *"not connected"*) st ИНФО "Wi-Fi: включён, не подключён к сети" ;;
    *connected*) st OK "Wi-Fi: включён, подключён" ;;
    *) st ИНФО "Wi-Fi: wlan0 есть, состояние: ${WS:-неизвестно}" ;;
  esac
fi
BT=$(ds bluetooth_manager | grep -m 2 -E '^ *(enabled|state): ' | sed 's/^ *//' | tr '\n' ' ' | sed 's/ *$//')
case "$BT" in
  *"enabled: true"*) st OK "Bluetooth: включён ($BT)" ;;
  *"enabled: false"*) st ИНФО "Bluetooth: выключен (включи и запусти проверку снова)" ;;
  *) st ИНФО "Bluetooth: состояние неизвестно" ;;
esac
NFC=$(grep -iE '^init\.svc\.[^=]*nfc[^=]*=' "$P" | sed 's/^init\.svc\.//' | tr '\n' ' ' | sed 's/ *$//')
case "$NFC" in
  *=restarting*) st НЕТ "NFC: служба падает ($NFC)" ;;
  *=running*) st OK "NFC: служба работает ($NFC)" ;;
  "") st ИНФО "NFC: службы *nfc* не найдено" ;;
  *) st ИНФО "NFC: $NFC" ;;
esac

# --- камеры
NC=$(ds media.camera | sed -n 's/.*Number of camera devices: *\([0-9][0-9]*\).*/\1/p' | head -n 1)
case "$NC" in
  ""|0) st НЕТ "камеры: ${NC:-нет ответа media.camera} (камера HAL не поднялась? ошибки ниже)" ;;
  *) st OK "камеры: $NC" ;;
esac
sec "камеры: ошибки в logcat (последние 30)"
logcat -d 2>/dev/null | grep -iE 'camera' | grep -iE 'error|fail|fatal|exception' | tail -n 30 | det

# --- экран
SZ=$(wm size 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'); DN=$(wm density 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
case "$SZ" in
  *1768*|*2208*) st ВНИМАНИЕ "экран: $SZ, $DN - похоже на внутренний экран (основным должен быть внешний 816x2260)" ;;
  "") st ИНФО "экран: wm size не ответил" ;;
  *) st OK "экран: $SZ, $DN" ;;
esac
sec "экраны (dumpsys display) и частоты"
ds display | grep -oE 'DisplayDeviceInfo\{"[^"]*": uniqueId="[^"]*", [0-9]+ x [0-9]+' | sort -u | det
ds display | grep -oE 'fps=[0-9.]+' | sort -u | tr '\n' ' ' | det; echo >>"$DET"
ds device_state | grep -iE 'committed|current|base state' | head -n 5 | det

# --- датчики, батарея
NS=$(ds sensorservice | sed -n 's/.*Total \([0-9][0-9]*\) h\/w sensors.*/\1/p' | head -n 1)
case "$NS" in ""|0) st ВНИМАНИЕ "датчики: ${NS:-нет ответа sensorservice}" ;; *) st OK "датчики: $NS" ;; esac
ds battery >"$W/bat"
LV=$(sed -n 's/^ *level: *//p' "$W/bat" | head -n 1); TC=$(sed -n 's/^ *temperature: *//p' "$W/bat" | head -n 1)
if [ -n "$LV" ]; then
  TT=$(num "${TC#-}"); TT=$((TT / 10)); case "$TC" in -*) TT=$((0 - TT)) ;; esac
  if [ "$TT" -ge 45 ]; then st ВНИМАНИЕ "батарея: $LV%, ${TT}°C - горячая"; else st OK "батарея: $LV%, ${TT}°C"; fi
else st ИНФО "батарея: dumpsys battery не ответил"; fi
sec "батарея"; grep -E 'powered|status|health|level|temperature|voltage|Charge counter' "$W/bat" | head -n 15 | det

# --- подсистемы (modem, adsp, cdsp, slpi...) и cDSP для NPU
SUB=""
for D in /sys/bus/msm_subsys/devices/*; do
  [ -f "$D/name" ] || continue
  SUB="$SUB$(cat "$D/name" 2>/dev/null)=$(cat "$D/state" 2>/dev/null) "
done
CD=$(echo "$SUB" | tr ' ' '\n' | sed -n 's/^cdsp=//p' | head -n 1)
RPC=""; for F in /dev/adsprpc-smd /dev/fastrpc-cdsp; do [ -e "$F" ] && RPC="$RPC$F "; done
if [ -z "$RPC" ]; then st ВНИМАНИЕ "cDSP (NPU): нет /dev/adsprpc-smd - FastRPC недоступен, llama.cpp будет на CPU"
elif [ -n "$CD" ] && [ "$CD" != ONLINE ]; then st ВНИМАНИЕ "cDSP (NPU): подсистема cdsp $CD (не ONLINE)"
else st OK "cDSP (NPU): ${RPC% }${CD:+, cdsp $CD}"; fi
[ -n "$SUB" ] && { sec "подсистемы (msm_subsys)"; echo "$SUB" | det; }

# --- ядро: опции для Docker из target/f2q/kernel-src/docker.config
KOPTS="NAMESPACES UTS_NS IPC_NS PID_NS NET_NS USER_NS CGROUPS CGROUP_CPUACCT CGROUP_DEVICE CGROUP_FREEZER CGROUP_SCHED
CGROUP_PIDS CGROUP_BPF CGROUP_NET_PRIO CPUSETS MEMCG BLK_CGROUP KEYS POSIX_MQUEUE SECCOMP SECCOMP_FILTER OVERLAY_FS VETH
BRIDGE BRIDGE_NETFILTER DUMMY MACVLAN VXLAN NF_NAT IP_NF_FILTER IP_NF_NAT IP_NF_TARGET_MASQUERADE
NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK NETFILTER_XT_MARK"
KV=$(uname -r 2>/dev/null)
if zcat /proc/config.gz >"$W/kconf" 2>/dev/null && [ -s "$W/kconf" ]; then
  MISS=""; for O in $KOPTS; do grep -q "^CONFIG_$O=[ym]" "$W/kconf" || MISS="$MISS$O "; done
  SEC=""; for O in SECURITY_DEFEX PROCA FIVE; do grep -q "^CONFIG_$O=y" "$W/kconf" && SEC="$SEC$O "; done
  if [ -n "$MISS" ]; then st ВНИМАНИЕ "ядро $KV: для Docker нет опций: $MISS"
  else st OK "ядро $KV: все опции для Docker на месте"; fi
  [ -n "$SEC" ] && st ВНИМАНИЕ "ядро: включены защиты Samsung ($SEC) - мешают root/chroot/Docker"
else st ИНФО "ядро $KV: /proc/config.gz не прочитался (нужен root) - опции Docker не проверены"; fi

# --- место, память, часы, интернет
FREE=$(num "$(df -k /data 2>/dev/null | awk 'NR>1 {print $(NF-2); exit}')" "")
MT=$(num "$(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)")
MA=$(num "$(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)")
if [ -z "$FREE" ]; then st ИНФО "место в /data: df не ответил"
elif [ "$FREE" -lt 8388608 ]; then st ВНИМАНИЕ "место в /data: свободно $((FREE / 1048576)) ГБ (Debian с XFCE и Docker - от 8 ГБ)"
else st OK "место в /data: свободно $((FREE / 1048576)) ГБ; память: $((MT / 1024)) МБ, доступно $((MA / 1024)) МБ"; fi
Y=$(date +%Y 2>/dev/null)
if [ "${Y:-0}" -ge 2025 ] 2>/dev/null; then st OK "часы: $(date '+%Y-%m-%d %H:%M')"
else st ВНИМАНИЕ "часы: $(date) - сбиты (не скачается ничего по https)"; fi
if have ping; then
  if ping -c 1 -W 5 github.com >/dev/null 2>&1; then st OK "интернет: github.com отвечает"
  elif ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then st ВНИМАНИЕ "интернет: 1.1.1.1 отвечает, а github.com нет - DNS?"
  else st ВНИМАНИЕ "интернет: нет ответа (нужен для установки Debian на телефоне)"; fi
fi

# --- падения приложений и native (буфер crash), отказы SELinux
logcat -b crash -d 2>/dev/null >"$W/crash"
{ grep -oE 'Process: [^,]+' "$W/crash" | sed 's/^Process: //'; grep -oE '>>> [^ ]+ <<<' "$W/crash" | sed 's/^>>> //; s/ <<<$//'; } |
  sort | uniq -c | sort -rn >"$W/crashes"
NCR=$(awk '{n += $1} END {print n + 0}' "$W/crashes")
if [ "$NCR" = 0 ]; then st OK "падения с загрузки: нет"
else st ВНИМАНИЕ "падения с загрузки: $NCR ($(head -n 3 "$W/crashes" | awk '{printf "%s x%s; ", $2, $1}'))"; fi
sec "падения (число, процесс)"; head -n 20 "$W/crashes" | det
if [ "$ROOT" = 1 ]; then
  NTS=0; for F in /data/tombstones/tombstone*; do [ -e "$F" ] && NTS=$((NTS + 1)); done
  NA=0; for F in /data/anr/*; do [ -e "$F" ] && NA=$((NA + 1)); done
  echo "tombstones: $NTS, ANR: $NA" | det
fi
logcat -d -b all 2>/dev/null | grep -E 'avc: +denied' >"$W/avc"
[ -s "$W/avc" ] || { [ -f "$W/dmesg" ] && grep -E 'avc: +denied' "$W/dmesg" >"$W/avc"; }
NAVC=$(grep -c . "$W/avc")
st ИНФО "отказы SELinux (avc: denied): $NAVC (на портах обычно есть; важны, если рядом с тем, что не работает)"
sec "отказы SELinux: число, кто -> что:класс { права }"
sed -nE 's/.*avc: +denied +\{ ([^}]*)\}.*scontext=u:r:([^:]+):.*tcontext=u:[^:]+:([^:]+):.*tclass=([^ ]+).*/\2 -> \3:\4 { \1}/p' "$W/avc" |
  sort | uniq -c | sort -rn | head -n 20 | det

# --- Magisk-модули, USB
if [ "$ROOT" = 1 ] && [ -d /data/adb/modules ]; then
  sec "модули Magisk"; for M in /data/adb/modules/*; do [ -d "$M" ] && echo "${M##*/}"; done | det
fi
sec "USB"; props 'sys\.usb\.(config|state)=' | det

{ echo "fold2: проверка телефона $(date '+%Y-%m-%d %H:%M'), root: $([ "$ROOT" = 1 ] && echo да || echo нет)"
  echo "ИТОГ: OK $NOK, ВНИМАНИЕ $NWARN, НЕТ $NBAD"
  cat "$SUM"; echo; echo "ПОДРОБНОСТИ"; cat "$DET"
} | sed -f "$W/lit.sed" | sed -E -f "$W/gen.sed"
exit 0
