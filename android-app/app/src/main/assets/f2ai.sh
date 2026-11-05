#!/system/bin/sh
# Fold2 AI: команды приложения (от root через su -mm). Путь к себе - /data/media/0/Android/data/com.fold2.ai/files/f2ai
FD=/data/local/fold2; NPU=/data/local/tmp/fold2-npu; M=/data/media/0/models
A=${0%/*}; AC=$(echo "$A" | sed 's|^/data/media/0|/sdcard|')
PY=/opt/qwen-tts/bin/python
yn() { [ -e "$1" ] && echo 1 || echo 0; }
# venv: bin/python - ссылка на /usr/bin/python3 Debian (снаружи chroot не видна) - готовность по пакету qwen_tts
ttsok() { ls -d $FD/debian/opt/qwen-tts/lib/python3*/site-packages/qwen_tts >/dev/null 2>&1; }
case "$1" in
  status)
    echo "npu=$(yn $NPU/npu.sh)"
    echo "debian=$(yn $FD/debian/etc/fold2-setup.done)"
    echo "tts=$(ttsok && echo 1 || echo 0)"
    echo "sd=$(yn $FD/debian/opt/stable-diffusion.cpp/build/bin/sd-cli)"
    echo "models=$(cd $M 2>/dev/null && ls *.gguf 2>/dev/null | tr '\n' ' ')"
    echo "flux=$(ls $M/flux2 2>/dev/null | tr '\n' ' ')"
    echo "ttsmodel=$(yn $M/qwen3-tts-0.6b-base/model.safetensors)"
    echo "qwentts=$(yn $FD/debian/opt/qwentts.cpp/build/qwen-tts)$(yn $M/qwentts/qwen-talker-0.6b-base-Q8_0.gguf)"
    echo "mem=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
    echo "setup=$(tail -n 1 /data/local/tmp/ai_get3.log 2>/dev/null)"
    echo "ttssetup=$(tail -n 1 /data/local/tmp/tts_fix.log 2>/dev/null)"
    ;;
  llm-start)
    case "$2" in ""|*[!A-Za-z0-9._-]*) echo "плохое имя модели: $2"; exit 2 ;; esac
    sh $NPU/npu.sh stop >/dev/null 2>&1
    export NPU_CTX=4096
    if [ "$3" = 1 ]; then export F2QDSP=1 F2QDSP_MAX_MB=1536; else export F2QDSP=0; fi
    sh $NPU/npu.sh server "$2"
    ;;
  llm-stop) sh $NPU/npu.sh stop ;;
  ai-start)
    if pgrep -f ai_server.py >/dev/null; then echo "сервер TTS/FLUX уже запущен"; exit 0; fi
    ttsok || { echo "TTS ещё ставится в Debian (torch + qwen-tts), подожди: $(tail -n 1 /data/local/tmp/tts_fix.log 2>/dev/null)"; exit 1; }
    sh $FD/debian.sh start >/dev/null 2>&1
    setsid nohup sh $FD/debian.sh run $PY $AC/ai_server.py > $FD/ai_server.log 2>&1 < /dev/null &
    echo "сервер TTS/FLUX запускается (лог $FD/ai_server.log)"
    ;;
  ai-stop) pkill -f ai_server.py && echo "сервер TTS/FLUX остановлен" || echo "сервер TTS/FLUX не был запущен" ;;
  npu-test) sh $NPU/npu.sh test ;;
  logs)
    echo "== llama-server"; sh $NPU/npu.sh log 2>&1 | tail -n 20
    echo "== сервер TTS/FLUX"; tail -n 30 $FD/ai_server.log 2>/dev/null
    echo "== установка TTS/FLUX"; tail -n 8 /data/local/tmp/ai_get3.log 2>/dev/null
    echo "== установка TTS"; tail -n 6 /data/local/tmp/tts_fix.log 2>/dev/null
    echo "== загрузки"; tail -n 4 /data/local/tmp/ai_models.log 2>/dev/null
    ;;
  *) echo "команды: status llm-start <модель> <0|1> llm-stop ai-start ai-stop npu-test logs"; exit 2 ;;
esac
