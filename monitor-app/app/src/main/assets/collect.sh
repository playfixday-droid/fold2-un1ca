# Fold2 Монитор: функции сбора, загружаются один раз в постоянный root-шелл (mksh/toybox).
# Вывод: строки "ТЕГ поля...", разбирает Hub.java. Все чтения - встроенным read (без fork).
f2s() {
  echo "K $(uname -r)"; echo "SE $(getenforce)"
  echo "FW $(getprop ro.build.display.id)"; echo "OU $(getprop ro.build.version.oneui)"
  echo "HW $(getprop ro.boot.hardware) $(getprop ro.soc.model)"
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    f=$c/cpufreq; [ -r $f/cpuinfo_max_freq ] || continue
    mx=; mn=; rc=; read -r mx < $f/cpuinfo_max_freq; read -r mn < $f/cpuinfo_min_freq
    [ -r $f/related_cpus ] && read -r rc < $f/related_cpus
    echo "CS ${c##*cpu} $mn $mx $rc"
  done
  for z in /sys/class/thermal/thermal_zone*; do t=; read -r t < $z/type; echo "ZT ${z##*zone} $t"; done
  for d in /sys/class/devfreq/*; do a=; [ -r $d/available_frequencies ] && read -r a < $d/available_frequencies; echo "DA ${d##*/} $a"; done
  g=/sys/class/kgsl/kgsl-3d0
  for f in gpu_model max_gpuclk min_clock_mhz max_clock_mhz; do [ -r $g/$f ] && { v=; read -r v < $g/$f; echo "GS $f $v"; }; done
}
f2f() {
  while read -r l; do case $l in cpu*) echo "S $l";; procs_running*) echo "PR ${l#* }";; esac; done < /proc/stat
  for c in /sys/devices/system/cpu/cpu[0-9]*; do
    o=1; [ -r $c/online ] && read -r o < $c/online
    f=$c/cpufreq; cur=0; smn=0; smx=0; gv=-
    if [ -r $f/scaling_cur_freq ]; then read -r cur < $f/scaling_cur_freq; read -r smn < $f/scaling_min_freq; read -r smx < $f/scaling_max_freq; read -r gv < $f/scaling_governor; fi
    echo "C ${c##*cpu} $o $cur $smn $smx $gv"
  done
  [ -r /sys/devices/system/cpu/isolated ] && { v=; read -r v < /sys/devices/system/cpu/isolated; echo "ISO $v"; }
  if [ "$1" = 1 ]; then for z in /sys/class/thermal/thermal_zone*; do v=; read -r v < $z/temp; echo "Z ${z##*zone} $v"; done; fi
  g=/sys/class/kgsl/kgsl-3d0
  for f in gpu_busy_percentage gpuclk devfreq/cur_freq temp gpubusy; do [ -r $g/$f ] && { v=; read -r v < $g/$f; echo "G $f $v"; }; done
  for d in /sys/class/devfreq/*; do c=; a=; b=; read -r c < $d/cur_freq; read -r a < $d/min_freq; read -r b < $d/max_freq; echo "D ${d##*/} $c $a $b"; done
  while read -r l; do case $l in MemTotal:*|MemFree:*|MemAvailable:*|Buffers:*|Cached:*|SwapTotal:*|SwapFree:*|Shmem:*) echo "M $l";; esac; done < /proc/meminfo
  [ -r /sys/block/zram0/mm_stat ] && { v=; read -r v < /sys/block/zram0/mm_stat; echo "ZR $v"; }
  while read -r a b c d e f g h i j k; do case $c in sd[a-z]|mmcblk[0-9]|nvme[0-9]n[0-9]) echo "IO $c $f $j";; esac; done < /proc/diskstats
  while read -r l; do case $l in *:*) echo "N $l";; esac; done < /proc/net/dev
  v=; read -r v < /proc/uptime; echo "U $v"; v=; read -r v < /proc/loadavg; echo "L $v"
  for p in /sys/class/power_supply/*; do
    n=${p##*/}
    for f in status health online type usb_type real_type charge_type capacity current_now current_avg current_max input_current_limit constant_charge_current voltage_now voltage_avg voltage_max temp charge_full charge_full_design charge_counter cycle_count batt_current_ua_now batt_current_ua_avg battery_cycle fg_asoc batt_charging_source hv_charger_status power_now time_to_full_now; do
      [ -r $p/$f ] && { v=; read -r v < $p/$f; echo "P $n $f $v"; }
    done
  done
}
f2sub() { for s in /sys/bus/msm_subsys/devices/*; do n=; st=; read -r n < $s/name; read -r st < $s/state; echo "SB $n $st"; done; }
f2top() { top -b -q -n 1 -m ${1:-8} -o PID,%CPU,RES,NAME | while read -r a b c d; do echo "TP $a $b $c $d"; done; }
f2rpc() {
  ls -l /proc/[0-9]*/fd | while read -r l; do case $l in /proc/*) p=${l%/fd:}; p=${p#/proc/};; *adsprpc*|*fastrpc*) echo "RP $p";; esac; done
}
f2comm() { for p in "$@"; do v=; read -r v < /proc/$p/comm && echo "RC $p $v"; done; }
