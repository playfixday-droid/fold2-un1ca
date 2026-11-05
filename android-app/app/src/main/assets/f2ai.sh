#!/system/bin/sh
# Fold2 AI: команды приложения (от root через su -mm). Путь к себе - /data/media/0/Android/data/com.fold2.ai/files/f2ai
FD=/data/local/fold2; NPU=/data/local/tmp/fold2-npu; M=/data/media/0/models
A=${0%/*}; AC=$(echo "$A" | sed 's|^/data/media/0|/sdcard|')
# python: venv qwen-tts (torch-запасной путь TTS), иначе системный python3 Debian - серверу хватает stdlib
PY=/opt/qwen-tts/bin/python; [ -e $FD/debian/opt/qwen-tts/pyvenv.cfg ] || PY=/usr/bin/python3
SDB="$FD/debian/opt/sdcpu/bin/sd-cli $FD/debian/opt/stable-diffusion.cpp/build/bin/sd-cli"
QTB=$FD/debian/opt/qwentts.cpp/build/qwen-tts
# DAC на GPU (npu/dacgpu): dacgpu + libtensorflowlite*.so + модели dac*.tflite (spec-строки - в models.txt)
DAC=$FD/dac; DACTAG=dacgpu-6
dacstart() {
  [ -x $DAC/dacgpu ] || return 0
  pgrep -f "dacgpu serve" >/dev/null && return 0
  # exec в фоновом подшелле: без ждущего sh, который держал бы stdout вызывающего (приложение ждало бы EOF)
  # libf2prio.so (dacgpu-6+): контексты OpenCL с низким приоритетом - GPU уступает экрану/DeX, F2CL_PRIO меняет cfg
  (cd $DAC || exit 1; export LD_LIBRARY_PATH=$DAC DACGPU_CACHE=$DAC/cache F2CL_PRIO=low
   [ -e $DAC/libf2prio.so ] && export LD_PRELOAD=$DAC/libf2prio.so
   exec setsid nohup ./dacgpu serve 8083 $(cat models.txt 2>/dev/null || echo dac64.tflite dac256.tflite) > $FD/dacgpu.log 2>&1 < /dev/null) > /dev/null 2>&1 < /dev/null &
}
# GPU-версии (OpenCL, вендорский драйвер Adreno): llama.cpp и sd.cpp под Android из релиза gpu-N (команда gpu-install)
GD=$FD/debian/opt/gpu; GPUTAG=gpu-3
gpustop() { pkill -f "$GD/llama/llama-server" 2>/dev/null; rm -f $GD/llama/server.pid; }
# «максимальная скорость» для чата: на время ответа все ядра (cpufreq) и L3/LLCC/память (devfreq, с GPU - и он) на
# максимальной частоте. Прежние минимумы - в том же файле, что у ai_server.py (/tmp chroot): кто бы ни включил, вернёт любой.
BF=$FD/debian/tmp/f2_devfreq_saved.json
brestore() {
  [ -f $BF ] || return 0
  # строки в кавычках по порядку: путь /sys/..., его значение (в именах devfreq бывают запятые)
  awk 'BEGIN{RS="\""} NR%2==0{ if(k!=""){print k, $0; k=""} else if(index($0,"/sys/")==1) k=$0 }' $BF | while read -r P V; do
    [ -n "$V" ] && echo "$V" > "$P" 2>/dev/null; done
  rm -f $BF
}
bpin() { V=$(cat "$1" 2>/dev/null) && MX=$(cat "$2" 2>/dev/null) && [ -n "$V" ] && echo "$MX" > "$1" 2>/dev/null && J="$J\"$1\": \"$V\", "; }
any() { for f in "$@"; do [ -e "$f" ] && return 0; done; return 1; }
# серверу есть что делать: быстрый TTS (qwentts.cpp), torch TTS или FLUX (sd-cli)
aiok() { [ -x $QTB ] || ttsok || any $SDB; }
aistop() {
  pkill -f ai_server.py && R=0 || R=1
  # дочерние sd-cli / qwen-tts (сервер сам их снимает по SIGTERM, это - на случай kill -9)
  sleep 1; pkill -f /bin/sd-cli; pkill -f build/qwen-tts; pkill -f build/tts-server; pkill -f build/qwen-codec; pkill -f "dacgpu serve"
  return $R
}
yn() { [ -e "$1" ] && echo 1 || echo 0; }
# venv: bin/python - ссылка на /usr/bin/python3 Debian (снаружи chroot не видна) - готовность по пакету qwen_tts
ttsok() { ls -d $FD/debian/opt/qwen-tts/lib/python3*/site-packages/qwen_tts >/dev/null 2>&1; }
case "$1" in
  status)
    echo "npu=$(yn $NPU/npu.sh)"
    echo "debian=$(yn $FD/debian/etc/fold2-setup.done)"
    echo "tts=$(ttsok && echo 1 || echo 0)"
    echo "sd=$(any $SDB && echo 1 || echo 0)"
    echo "sdcpu=$(yn $FD/debian/opt/sdcpu/bin/sd-cli)"
    echo "models=$(cd $M 2>/dev/null && ls *.gguf 2>/dev/null | grep -v '^mmproj' | tr '\n' ' ')"
    echo "mmproj=$(cd $M 2>/dev/null && ls mmproj*.gguf 2>/dev/null | tr '\n' ' ')"
    echo "qtmodels=$(cd $M/qwentts 2>/dev/null && ls qwen-talker-*.gguf 2>/dev/null | sed 's/^qwen-talker-//; s/\.gguf$//' | tr '\n' ' ')"
    echo "flux=$(ls $M/flux2 2>/dev/null | tr '\n' ' ')"
    echo "ttsmodel=$(yn $M/qwen3-tts-0.6b-base/model.safetensors)"
    echo "qwentts=$(yn $QTB)$(yn $M/qwentts/qwen-talker-0.6b-base-Q8_0.gguf)"
    echo "qtserver=$(yn $FD/debian/opt/qwentts.cpp/build/tts-server)$(yn $FD/debian/opt/qwentts.cpp/build/qwen-codec)"
    echo "dacgpu=$(yn $DAC/dacgpu)$(pgrep -f 'dacgpu serve' >/dev/null && echo 1 || echo 0)"
    echo "llm=$(pgrep -f 'fold2-npu/bin/llama-server|opt/gpu/llama/llama-server' >/dev/null && echo 1 || echo 0)"
    echo "gpu=$(for W in llama sdcpp; do [ -x $GD/$W/llama-server ] || [ -x $GD/$W/sd-cli ] && printf '%s ' $W; done)"
    echo "gputag=$(cat $GD/tag 2>/dev/null)"
    echo "llmspec=$(grep -qa -- '--spec-type' $NPU/bin/llama-server 2>/dev/null && echo 1 || echo 0)"
    echo "asr=$(yn $FD/debian/opt/whisper/bin/whisper-cli)"
    echo "mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
    echo "setup=$(tail -n 1 /data/local/tmp/ai_get3.log 2>/dev/null)"
    echo "ttssetup=$(tail -n 1 /data/local/tmp/tts_fix.log 2>/dev/null)"
    ;;
  llm-start)
    case "$2" in ""|*[!A-Za-z0-9._-]*) echo "плохое имя модели: $2"; exit 2 ;; esac
    # $4 - маска ядер (hex для taskset: f0 = 4-7), $5 - потоки, $6 - слоёв на GPU (0 - процессор/NPU), $7 - 1: угадывание повторов
    MK=${4:-f0}; TH=${5:-4}; NGL=${6:-0}; SPEC=${7:-0}
    case "$MK" in ""|*[!0-9a-fA-F]*) echo "плохая маска ядер: $MK"; exit 2 ;; esac
    case "$TH$NGL$SPEC" in *[!0-9]*) echo "плохие числа: $TH $NGL $SPEC"; exit 2 ;; esac
    sh $NPU/npu.sh stop >/dev/null 2>&1; gpustop
    export NPU_CTX=4096
    if [ "$3" = 1 ]; then export F2QDSP=1 F2QDSP_MAX_MB=1536; else export F2QDSP=0; fi
    # зрение: к модели Qwen3VL-2B-Instruct-Q4_K_M.gguf - mmproj-Qwen3VL-2B-Instruct-*.gguf (картинки в чат)
    B=$(echo "$2" | sed -E 's/\.gguf$//; s/[-.](I?Q[0-9][A-Za-z0-9_]*|F16|BF16|F32)$//')
    MM=$(ls $M/mmproj-$B*.gguf 2>/dev/null | head -n 1)
    export F2_ARGS=""; [ -n "$MM" ] && export F2_ARGS="--mmproj $MM" && echo "зрение: $MM"
    # угадывание повторов: черновик из уже написанного (n-граммы), без второй модели - только если сборка умеет
    spec() { [ "$SPEC" = 1 ] && grep -qa -- '--spec-type' "$1" && echo "--spec-type ngram-simple"; }
    if [ "$NGL" != 0 ] && [ -x $GD/llama/llama-server ]; then
      # GPU-сборка: слои на Adreno (OpenCL), остальное - процессор; libf2cl3.so - заглушка функций OpenCL 3.0
      MP=$M/$2; [ -f "$MP" ] || { echo "нет модели $MP"; exit 1; }
      PRE=""; [ -e $GD/llama/libf2cl3.so ] && PRE=$GD/llama/libf2cl3.so
      [ "$3" = 1 ] && echo "NPU и GPU вместе не работают - беру GPU"
      L=$GD/llama/server.log
      (cd $GD/llama || exit 1; export LD_LIBRARY_PATH=/vendor/lib64 LD_PRELOAD=$PRE
       exec setsid nohup taskset $MK $GD/llama/llama-server -m "$MP" --host 127.0.0.1 --port 8081 -t $TH -c $NPU_CTX \
         -ngl $NGL --jinja -lv 3 $F2_ARGS $(spec $GD/llama/llama-server) > $L 2>&1 < /dev/null) > /dev/null 2>&1 < /dev/null &
      I=0; while [ $I -lt 120 ]; do
        grep -q "listening on" $L 2>/dev/null && { echo "готово на GPU: $NGL слоёв, $TH потоков, ядра $MK (лог $L)"; exit 0; }
        pgrep -f "$GD/llama/llama-server" >/dev/null || [ $I -lt 3 ] || { tail -n 15 $L; echo "GPU-сервер не запустился - лог выше"; exit 1; }
        sleep 1; I=$((I + 1))
      done; echo "GPU-сервер ещё загружается (лог $L)"; exit 0
    fi
    [ "$NGL" != 0 ] && echo "нет GPU-версии llama.cpp (Система → GPU-версии) - запускаю на процессоре"
    # npu.sh задаёт NPU_ARGS, NPU_CPUMASK, NPU_THREADS сам и читает npu.conf - строки-мостики берут их из F2_*
    export F2_ARGS="$F2_ARGS $(spec $NPU/bin/llama-server)" F2_MASK=$MK F2_THREADS=$TH
    grep -q F2_ARGS $NPU/npu.conf 2>/dev/null || echo '[ -n "$F2_ARGS" ] && NPU_ARGS="$NPU_ARGS $F2_ARGS" # f2ai' >> $NPU/npu.conf
    grep -q F2_MASK $NPU/npu.conf 2>/dev/null || echo '[ -n "$F2_MASK" ] && NPU_CPUMASK=$F2_MASK; [ -n "$F2_THREADS" ] && NPU_THREADS=$F2_THREADS # f2ai' >> $NPU/npu.conf
    sh $NPU/npu.sh server "$2"
    ;;
  llm-stop) sh $NPU/npu.sh stop; pgrep -f "$GD/llama/llama-server" >/dev/null && gpustop && echo "GPU-сервер остановлен" ;;
  gpu-install)  # GPU-версии llama.cpp и sd.cpp (OpenCL) из релиза gpu-N, качает и проверяет Debian (curl, sha256sum, tar)
    T=${2:-$GPUTAG}; case "$T" in *[!A-Za-z0-9._-]*) echo "плохой тег"; exit 2 ;; esac
    sh $FD/debian.sh start >/dev/null 2>&1; mkdir -p $GD
    cat > $FD/debian/tmp/gpu_get.sh <<'G'
set -e; cd /tmp; U=https://github.com/playfixday-droid/fold2-un1ca/releases/download/$1
curl -sSfL -o gpu.sums $U/SHA256SUMS
for W in llama sdcpp; do F=gpu-$W-android-arm64.tar.xz
  curl -sSfL -o $F $U/$F || { echo "не скачалось: $F"; continue; }
  grep " $F\$" gpu.sums | sha256sum -c --quiet || { echo "sha256 не совпал: $F"; rm -f $F; continue; }
  rm -rf /opt/gpu/$W.new; mkdir -p /opt/gpu/$W.new; tar -xJf $F -C /opt/gpu/$W.new; rm -f $F
  chmod 755 /opt/gpu/$W.new/*; rm -rf /opt/gpu/$W; mv /opt/gpu/$W.new /opt/gpu/$W
  echo "ok $W: $(cat /opt/gpu/$W/*.version 2>/dev/null)"
done
G
    sh $FD/debian.sh run sh /tmp/gpu_get.sh "$T" || { echo "не скачалось (нет релиза $T?)"; exit 1; }
    echo $T > $GD/tag; echo "GPU-версии установлены: $GD ($T)"
    ;;
  ai-start)
    if pgrep -f ai_server.py >/dev/null; then echo "сервер TTS/FLUX уже запущен"; exit 0; fi
    aiok || { echo "нет ни qwentts.cpp, ни sd-cli, ни TTS на torch в Debian - сначала установка: $(tail -n 1 /data/local/tmp/tts_fix.log 2>/dev/null)"; exit 1; }
    sh $FD/debian.sh start >/dev/null 2>&1
    # старая версия DAC на GPU - обновить в фоне (новая умеет уступать экрану DeX), сервер стартует сразу
    if [ -x $DAC/dacgpu ] && [ "$(cat $DAC/tag 2>/dev/null)" != $DACTAG ]; then
      setsid nohup sh "$0" dac-install > $FD/dac_install.log 2>&1 < /dev/null &
    fi
    dacstart
    setsid nohup sh $FD/debian.sh run $PY $AC/ai_server.py > $FD/ai_server.log 2>&1 < /dev/null &
    echo "сервер TTS/FLUX запускается (лог $FD/ai_server.log)"
    ;;
  ai-stop) aistop && echo "сервер TTS/FLUX остановлен" || echo "сервер TTS/FLUX не был запущен" ;;
  ai-restart)
    aistop >/dev/null 2>&1
    I=0; while pgrep -f ai_server.py >/dev/null && [ $I -lt 10 ]; do sleep 1; I=$((I + 1)); done
    exec sh "$0" ai-start
    ;;
  dac-install)  # DAC на GPU: dacgpu-N (бинарник + TFLite .so) и dac-N (модели) из релизов GitHub, качает curl из Debian
    T1=${2:-$DACTAG}; T2=${3:-dac-1}; G=https://github.com/playfixday-droid/fold2-un1ca/releases/download
    mkdir -p $DAC/cache $DAC/new
    for f in $T1/dacgpu $T1/libtensorflowlite_jni.so $T1/libtensorflowlite_gpu_jni.so $T1/libf2prio.so $T2/dac64.tflite $T2/dac128.tflite $T2/dac256.tflite; do
      case $f in *.tflite) [ -s $DAC/${f#*/} ] && continue ;; esac  # модели не меняются - не качать заново
      sh $FD/debian.sh run curl -sSfL -o /tmp/dac.dl "$G/$f" && mv $FD/debian/tmp/dac.dl $DAC/new/${f#*/} || {
        case $f in *libf2prio.so) echo "нет $f - без приоритета"; continue ;; esac
        echo "не скачалось: $f"; rm -rf $DAC/new; exit 1; }
    done
    pkill -f "dacgpu serve"; sleep 1; mv -f $DAC/new/* $DAC/; rmdir $DAC/new
    echo "dac64.tflite dac128.tflite dac256.tflite" > $DAC/models.txt; echo $T1 > $DAC/tag
    chmod 755 $DAC/dacgpu; dacstart; echo "DAC на GPU установлен: $DAC ($T1)"
    ;;
  boost)  # boost on [gpu] | off: см. brestore
    if [ "$2" = on ]; then
      brestore; J=""
      for P in /sys/devices/system/cpu/cpufreq/policy*; do bpin $P/scaling_min_freq $P/scaling_max_freq; done
      for P in /sys/class/devfreq/*; do N=${P##*/}
        case "$N" in *cdsp*) continue ;; *cpu*l3*|*cpu*llcc*|*cpu*ddr*) ;; *kgsl-3d0|*gpubw) [ "$3" = gpu ] || continue ;; *) continue ;; esac
        bpin $P/min_freq $P/max_freq; done
      T=$(date +%s); mkdir -p ${BF%/*}; echo "{$J\"_t\": $T}" > $BF
      # страховка: приложение закрыли посреди ответа - через 10 мин без нового «boost on» частоты вернутся сами
      setsid nohup sh -c "sleep 600; grep -q '\"_t\": $T}' $BF 2>/dev/null && sh '$0' boost off" > /dev/null 2>&1 < /dev/null &
      echo "boost on: $(grep -o '/sys/[^"]*' $BF | wc -l) частот на максимуме"
    else brestore; echo "boost off"; fi
    ;;
  npu-test) sh $NPU/npu.sh test ;;
  logs)
    echo "== llama-server"; sh $NPU/npu.sh log 2>&1 | tail -n 20
    echo "== сервер TTS/FLUX"; tail -n 30 $FD/ai_server.log 2>/dev/null
    echo "== DAC на GPU"; tail -n 6 $FD/dacgpu.log 2>/dev/null
    echo "== установка TTS/FLUX"; tail -n 8 /data/local/tmp/ai_get3.log 2>/dev/null
    echo "== установка TTS"; tail -n 6 /data/local/tmp/tts_fix.log 2>/dev/null
    echo "== загрузки"; tail -n 4 /data/local/tmp/ai_models.log 2>/dev/null
    ;;
  *) echo "команды: status llm-start <модель> <0|1> [маска потоки слоиGPU 0|1] llm-stop gpu-install [тег] ai-start ai-stop ai-restart dac-install npu-test logs"; exit 2 ;;
esac
