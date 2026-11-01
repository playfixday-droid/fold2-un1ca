#!/system/bin/sh
# fold2: llama.cpp с f2qdsp (MUL_MAT на cDSP Hexagon 698) прямо в Android, без Debian.
# Запуск от root:  su -c "sh /data/local/tmp/fold2-npu/npu.sh <команда>"
#   test [M K]        - f2q-bench: открылся ли DSP, совпадает ли результат с CPU, скорость DSP против CPU
#   server [модель]   - llama-server на 0.0.0.0:NPU_PORT (8081) в фоне; модель - путь или имя .gguf
#   bench [модель]    - llama-bench: F2QDSP=0 (обычный CPU), cpu (формат f2q на CPU), 1 (DSP + CPU)
#   stop              - остановить llama-server
#   log [dsp]         - конец лога llama-server; "log dsp" - сообщения FastRPC/DSP из logcat
# Модель ищется в /sdcard/models, затем в кэше llama.cpp Debian (/data/local/fold2/debian/var/lib/llama).
# Только веса Q4_0/Q8_0 идут на DSP. Настройки (необязательно): $D/npu.conf, например
#   NPU_MODEL=Qwen3-1.7B-Q4_0.gguf  NPU_PORT=8081  NPU_THREADS=4  NPU_CPUMASK=f0  NPU_CTX=4096
#   NPU_API_KEY=секрет  NPU_ARGS="--no-webui"  NPU_LOG_LEVEL=4  export F2QDSP_SPLIT=0.5  export F2QDSP_DEBUG=1
# NPU_LOG_LEVEL - -lv llama-server: 4 (по умолчанию) - видно "F2QDSP model buffer size" и лог F2QDSP_DEBUG,
#   3 - тише (llama.cpp v0.8.0 прячет INFO-строки библиотеки на уровне 3).

HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
if [ -n "$FOLD2_NPU_DIR" ]; then D=$FOLD2_NPU_DIR
elif [ -n "$HERE" ] && [ -d "$HERE/bin" ]; then D=$HERE
else D=/data/local/tmp/fold2-npu
fi
NPU_MODEL=Qwen3-1.7B-Q4_0.gguf
NPU_MODEL_DIRS="/sdcard/models /data/media/0/models /data/local/fold2/debian/var/lib/llama"
NPU_PORT=8081
NPU_THREADS=4
NPU_CPUMASK=f0
NPU_CTX=4096
NPU_API_KEY=
NPU_ARGS=
NPU_LOG_LEVEL=4
# shellcheck disable=SC1091
[ -f "$D/npu.conf" ] && . "$D/npu.conf"

LOG=$D/llama-server.log
PID=$D/llama-server.pid

say() { echo "[fold2-npu] $*"; }
die() { echo "[fold2-npu] ОШИБКА: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "нужен root: su -c \"sh $0 $*\""
[ -d "$D/bin" ] || die "нет $D/bin - распакуй f2qdsp-android-arm64.tar.xz в $D (pc_install_debian.sh делает это сам)"
chmod 755 "$D"/bin/* 2>/dev/null

export LD_LIBRARY_PATH="$D/lib:/vendor/lib64"
export ADSP_LIBRARY_PATH="$D/dsp;/vendor/dsp/cdsp;/vendor/dsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp"
[ -n "$F2QDSP" ] || export F2QDSP=1

need() { [ -x "$D/bin/$1" ] || die "нет $D/bin/$1"; }

# taskset из toybox принимает маску в hex (f0 = ядра 4-7: 3 Gold + Prime у SD865).
# Префикс, а не функция: "$TS cmd &" даёт в $! pid самого процесса (taskset/nohup делают exec),
# и "VAR=x $TS cmd" одинаково работает в mksh/ash/dash.
TS=""
if [ -n "$NPU_CPUMASK" ] && command -v taskset >/dev/null 2>&1; then TS="taskset $NPU_CPUMASK"; fi

find_model() { # find_model [имя|путь] -> путь к .gguf в stdout
  M=${1:-$NPU_MODEL}
  case "$M" in
    /*) [ -r "$M" ] && { echo "$M"; return 0; }; return 1 ;;
  esac
  for DIR in $NPU_MODEL_DIRS; do
    [ -d "$DIR" ] || continue
    [ -r "$DIR/$M" ] && { echo "$DIR/$M"; return 0; }
    F=$(find "$DIR" -name "*$M" 2>/dev/null | head -n 1)
    [ -n "$F" ] && [ -r "$F" ] && { echo "$F"; return 0; }
  done
  [ -n "$1" ] && return 1
  # модели по умолчанию нет - берём любую Q4_0/Q8_0 (только их веса считает DSP)
  for DIR in $NPU_MODEL_DIRS; do
    [ -d "$DIR" ] || continue
    F=$(find "$DIR" \( -name "*Q4_0*.gguf" -o -name "*Q8_0*.gguf" \) 2>/dev/null | grep -v mmproj | head -n 1)
    [ -n "$F" ] && [ -r "$F" ] && { echo "$F"; return 0; }
  done
  return 1
}

model_or_die() {
  MP=$(find_model "$1") || die "модель ${1:-$NPU_MODEL} не найдена в: $NPU_MODEL_DIRS (положи .gguf в /sdcard/models)"
  say "модель: $MP"
}

running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

hints() {
  say "подсказки, если DSP недоступен:"
  for F in /dev/adsprpc-smd /dev/fastrpc-cdsp /vendor/lib64/libcdsprpc.so "$D/dsp/libf2qdsp_skel.so"; do
    if [ -e "$F" ]; then echo "  есть: $F"; else echo "  НЕТ:  $F"; fi
  done
  SH=""; for P in /vendor/dsp/cdsp /vendor/dsp /vendor/lib/rfsa/adsp /dsp; do [ -e "$P/fastrpc_shell_unsigned_3" ] && { SH=$P/fastrpc_shell_unsigned_3; break; }; done
  if [ -n "$SH" ]; then echo "  есть: $SH (оболочка unsigned PD на cDSP)"
  else echo "  НЕТ:  fastrpc_shell_unsigned_3 (оболочка unsigned PD) в /vendor/dsp/cdsp, /vendor/dsp, /dsp - unsigned PD может не запуститься"; fi
  echo "  SELinux: $(getenforce 2>/dev/null)"
  echo "  если 'открыть f2qdsp ... rc=0x...' - Samsung, скорее всего, не пускает unsigned PD на cDSP;"
  echo "  тогда всё работает на CPU (llama.cpp сам отключит DSP). Подробно: F2QDSP_DEBUG=1, '$0 log dsp'"
}

do_test() {
  need f2q-bench
  OUT=$D/f2q-bench.log
  say "f2q-bench ${1:-2048} ${2:-2048} (вывод также в $OUT)"
  # shellcheck disable=SC2086
  $TS "$D/bin/f2q-bench" "${1:-2048}" "${2:-2048}" 2>&1 | tee "$OUT"
  # -F: grep из busybox (Magisk) не находит кириллицу как регулярное выражение
  if grep -qF "ИТОГ: OK" "$OUT"; then RC=0; else RC=1; fi
  if ! grep -qF "DSP ГОТОВ" "$OUT"; then
    hints
    [ "$RC" = 0 ] && { say "CPU-часть в порядке, но DSP не открылся"; return 3; }
  fi
  if [ "$RC" = 0 ]; then say "тест пройден: DSP работает и совпадает с CPU бит в бит"; else say "тест НЕ пройден - пришли $OUT"; fi
  return "$RC"
}

do_server() {
  need llama-server
  if running; then say "llama-server уже работает (pid $(cat "$PID")), порт $NPU_PORT"; return 0; fi
  model_or_die "$1"
  K=""; [ -n "$NPU_API_KEY" ] && K="--api-key $NPU_API_KEY"
  # shellcheck disable=SC2086
  $TS nohup "$D/bin/llama-server" -m "$MP" --host 0.0.0.0 --port "$NPU_PORT" -t "$NPU_THREADS" -c "$NPU_CTX" \
    --jinja -lv "$NPU_LOG_LEVEL" $K $NPU_ARGS >"$LOG" 2>&1 &
  echo $! >"$PID"
  I=0
  while [ $I -lt 120 ]; do
    if ! running; then tail -n 30 "$LOG"; rm -f "$PID"; die "llama-server завершился - лог выше ($LOG)"; fi
    if grep -q "listening on" "$LOG" 2>/dev/null; then break; fi
    sleep 1; I=$((I + 1))
  done
  W=$(grep "F2QDSP model buffer size" "$LOG" 2>/dev/null | tail -n 1 | sed 's/.*= *//')
  if [ -n "$W" ]; then say "на DSP: веса $W (буфер F2QDSP)"
  elif grep -q "listening on" "$LOG" 2>/dev/null && [ "$NPU_LOG_LEVEL" -ge 4 ] 2>/dev/null; then
    say "DSP не задействован: DSP не открылся ($0 test) или в модели нет весов Q4_0/Q8_0 - всё на CPU"
  fi
  IP=$(ip -4 addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
  if grep -q "listening on" "$LOG" 2>/dev/null; then
    say "готово: http://${IP:-<IP телефона>}:$NPU_PORT  (лог: $0 log, стоп: $0 stop)"
  else
    say "llama-server ещё загружается (pid $(cat "$PID")), смотри: $0 log"
  fi
}

do_bench() {
  need llama-bench
  model_or_die "$1"
  for MODE in 0 cpu 1; do
    say "llama-bench, F2QDSP=$MODE"
    # shellcheck disable=SC2086
    F2QDSP=$MODE $TS "$D/bin/llama-bench" -m "$MP" -t "$NPU_THREADS" -p 128 -n 32 -r 2 2>&1 | grep -vE "^(llama_|load|print_info)"
  done
}

do_stop() {
  if running; then
    kill "$(cat "$PID")" 2>/dev/null
    I=0; while running && [ $I -lt 10 ]; do sleep 1; I=$((I + 1)); done
    running && kill -9 "$(cat "$PID")" 2>/dev/null
    say "llama-server остановлен"
  elif pkill -f "$D/bin/llama-server" 2>/dev/null; then
    say "llama-server (без pid-файла) остановлен"
  else
    say "llama-server не запущен"
  fi
  rm -f "$PID"
}

do_log() {
  if [ "$1" = dsp ]; then
    command -v logcat >/dev/null 2>&1 || die "нет logcat (это не Android?)"
    logcat -d 2>/dev/null | grep -iE "adsprpc|fastrpc|f2qdsp|cdsp|open_shell|apps_std|remote_handle|rpcmem|unsigned" | tail -n "${2:-60}"
  else
    [ -f "$LOG" ] || die "лога нет: $LOG (server ещё не запускался)"
    tail -n "${1:-50}" "$LOG"
  fi
}

CMD=$1; [ $# -gt 0 ] && shift
case "$CMD" in
  test) do_test "$@" ;;
  server) do_server "$@" ;;
  bench) do_bench "$@" ;;
  stop) do_stop ;;
  log) do_log "$@" ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
