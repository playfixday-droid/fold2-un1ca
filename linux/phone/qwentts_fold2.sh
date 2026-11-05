#!/bin/bash
# Fold2: патч qwentts.cpp (github.com/ServeurpersoCom/qwentts.cpp, проверено на 5916bf7) - запускать в Debian chroot:
#   sh /data/local/fold2/debian.sh run bash /path/qwentts_fold2.sh
# Добавляет две переменные окружения (без них поведение прежнее):
#   QT_REF_SEED=N - клон голоса (ICL, с текстом образца): кодек декодирует перед новой речью не 144 последних кадра
#                   образца (11,5 с, ~2/3 времени синтеза на телефоне), а N. 24 кадра: 3,6 с речи - 56 с вместо 97 с.
#   QT_THREADS=N  - потоки ggml (по умолчанию половина ядер = 4; на SD865 лучше 4 потока на ядрах 4-7).
set -e
cd "${1:-/opt/qwentts.cpp}"
P=src/pipeline-tts.cpp B=src/backend.h
grep -q QT_REF_SEED $P || sed -i 's|^\(\s*\)seed = s.ref_codes_T < left_ctx_frames ? s.ref_codes_T : left_ctx_frames;|&\n\1if (const char * e = std::getenv("QT_REF_SEED")) { const int m = std::atoi(e); if (m >= 0 \&\& seed > m) seed = m; }  // fold2|' $P
grep -q '#include <cstdlib>' $P || sed -i '1i #include <cstdlib>' $P
grep -q QT_THREADS $B || sed -i 's|^\(\s*\)int n = (int) std::thread::hardware_concurrency() / 2;|\1if (const char * e = std::getenv("QT_THREADS")) { const int t = std::atoi(e); if (t > 0) return t; }  // fold2\n&|' $B
grep -q QT_REF_SEED $P && grep -q QT_THREADS $B || { echo "патч не лёг (другая версия qwentts.cpp?)"; exit 1; }
cmake --build build --target qwen-tts -j "$(nproc)"
echo "qwentts_fold2: готово"
