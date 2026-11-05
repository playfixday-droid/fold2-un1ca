#!/bin/bash
# Fold2: патч qwentts.cpp (github.com/ServeurpersoCom/qwentts.cpp, проверено на 5916bf7) - запускать в Debian chroot:
#   sh /data/local/fold2/debian.sh run bash /path/qwentts_fold2.sh
# Добавляет переменные окружения (без них поведение прежнее, кроме обрезки DAC - она бит-в-бит):
#   QT_REF_SEED=N - клон голоса (ICL, с текстом образца): кодек декодирует перед новой речью не 144 последних кадра
#                   образца (11,5 с, ~2/3 времени синтеза на телефоне), а N. 24 кадра: 3,6 с речи - 56 с вместо 97 с.
#   QT_DAC_MARGIN=N - (по умолчанию 8) кадры образца идут через трансформер кодека целиком (контекст), а через DAC
#                   (~95% вычислений кодека, рецептивное поле ~5 кадров) - только последние N. Звук бит-в-бит тот же,
#                   кодек ~2x быстрее (29 -> 13,5 с). -1 - выключить.
#   QT_DAC_EXT=файл - вход DAC (latent 50 Гц) пишется в файл, сам DAC не считается: его считает dacgpu на GPU
#                   (npu/dacgpu, ~2,3 с на 3,6 с речи против ~13 с на CPU). QT_DAC_DUMP=файл - записать и посчитать DAC.
#   QT_THREADS=N  - потоки ggml (по умолчанию половина ядер = 4; на SD865 лучше 4 потока на ядрах 4-7).
set -e
cd "${1:-/opt/qwentts.cpp}"
P=src/pipeline-tts.cpp B=src/backend.h
grep -q QT_REF_SEED $P || sed -i 's|^\(\s*\)seed = s.ref_codes_T < left_ctx_frames ? s.ref_codes_T : left_ctx_frames;|&\n\1if (const char * e = std::getenv("QT_REF_SEED")) { const int m = std::atoi(e); if (m >= 0 \&\& seed > m) seed = m; }  // fold2|' $P
grep -q '#include <cstdlib>' $P || sed -i '1i #include <cstdlib>' $P
grep -q QT_THREADS $B || sed -i 's|^\(\s*\)int n = (int) std::thread::hardware_concurrency() / 2;|\1if (const char * e = std::getenv("QT_THREADS")) { const int t = std::atoi(e); if (t > 0) return t; }  // fold2\n&|' $B
grep -q QT_REF_SEED $P && grep -q QT_THREADS $B || { echo "патч не лёг (другая версия qwentts.cpp?)"; exit 1; }
python3 - "$PWD" <<'PYEOF'
# fold2: DAC trim - prefix (ICL seed) frames go through quantizer/transformer/upsample (context), but the
# DAC (95% of codec FLOPs, receptive field ~5 frames @12.5 Hz) runs only on the last QT_DAC_MARGIN seed frames.
import sys, re
root = sys.argv[1] if len(sys.argv) > 1 else "/opt/qwentts.cpp"
pc = root + "/src/pipeline-codec.cpp"; pt = root + "/src/pipeline-tts.cpp"
s = open(pc).read()
if "g_qt_dac_skip" not in s:
    a = "std::vector<float> pipeline_codec_decode(PipelineCodec * pc, const int32_t * codes, int K, int T) {"
    assert s.count(a) == 1, "decode fn"
    s = s.replace(a, "int g_qt_dac_skip = 0;  // fold2: 12.5 Hz frames to skip in the DAC (output zero-filled)\n\n" + a)
    i = s.index(a)
    b = "    h                      = dac_decoder_forward(gctx, &pc->dac, h);"
    j = s.index(b, i)
    s = s[:j] + ("    int dac_skip = 0;  // fold2\n"
        "    if (g_qt_dac_skip > 0 && g_qt_dac_skip < T) {\n"
        "        const int up = (int) (h->ne[0] / T);\n"
        "        dac_skip = g_qt_dac_skip;\n"
        "        h = ggml_cont(gctx, ggml_view_2d(gctx, h, h->ne[0] - (int64_t) dac_skip * up, h->ne[1], h->nb[1], (size_t) dac_skip * up * h->nb[0]));\n"
        "    }\n") + s[j:]
    c = "    std::vector<float> audio((size_t) n_samples);\n    ggml_backend_tensor_get(h, audio.data(), 0, (size_t) n_samples * sizeof(float));"
    k = s.index(c, i)
    s = s[:k] + ("    std::vector<float> audio((size_t) n_samples, 0.0f);\n"
        "    const size_t n_skip = (size_t) dac_skip * TOKENIZER_HOP_LENGTH;  // fold2\n"
        "    ggml_backend_tensor_get(h, audio.data() + n_skip, 0, ((size_t) n_samples - n_skip) * sizeof(float));") + s[k+len(c):]
    open(pc, "w").write(s)
t = open(pt).read()
if "g_qt_dac_skip" not in t:
    a = "            Timer              t_codec;\n            std::vector<float> audio =\n                codec_chunked_decode(&pt->codec, codes_kt.data(), num_codebooks, T_dec, chunk_frames, left_ctx_frames);\n"
    assert t.count(a) == 1, "tts call"
    t = t.replace(a, "            {  // fold2: DAC trim (QT_DAC_MARGIN=-1 disables)\n"
        "                int m = 8;\n"
        "                if (const char * e = std::getenv(\"QT_DAC_MARGIN\")) m = std::atoi(e);\n"
        "                g_qt_dac_skip = (m >= 0 && T_dec <= chunk_frames && seed > m) ? seed - m : 0;\n"
        "            }\n" + a + "            g_qt_dac_skip = 0;\n")
    t = t.replace('#include "codec-chunked-decode.h"', '#include "codec-chunked-decode.h"\nextern int g_qt_dac_skip;  // fold2', 1)
    if "#include <cstdlib>" not in t: t = "#include <cstdlib>\n" + t
    open(pt, "w").write(t)
print("dactrim: ok")
PYEOF
python3 - "$PWD" <<'PYEOF'
# fold2: QT_DAC_EXT=file - qwen-tts writes the DAC input (latent [T50][1024] f32, header 'DAC1',T,C,drop) and skips the
# DAC (dacgpu decodes it on the GPU); QT_DAC_DUMP=file - writes it and still runs the DAC (check). Single-chunk decodes only.
import sys
root = sys.argv[1] if len(sys.argv) > 1 else "/opt/qwentts.cpp"
pc = root + "/src/pipeline-codec.cpp"; pt = root + "/src/pipeline-tts.cpp"
s = open(pc).read()
assert "g_qt_dac_skip" in s, "run dactrim first"
if "QT_DAC_EXT" not in s:
    k0 = s.index("int g_qt_dac_skip = 0;"); k1 = s.index("\n", k0)
    s = s[:k1 + 1] + "int g_qt_dac_ext_ok = 0, g_qt_dac_drop = 0;  // fold2: QT_DAC_EXT allowed (single chunk), seed frames kept before the DAC\n" + s[k1 + 1:]
    i = s.index("std::vector<float> pipeline_codec_decode(")
    a = ("    h                      = dac_decoder_forward(gctx, &pc->dac, h);                             // [T*1920, 1]\n"
         "    h                      = ggml_clamp(gctx, h, -1.0f, 1.0f);\n")
    j = s.index(a, i)
    s = s[:j] + ("    const char * lat_ext  = g_qt_dac_ext_ok ? std::getenv(\"QT_DAC_EXT\") : NULL;  // fold2\n"
        "    const char * lat_path = lat_ext ? lat_ext : (g_qt_dac_ext_ok ? std::getenv(\"QT_DAC_DUMP\") : NULL);\n"
        "    const int    lat_up   = (int) (h->ne[0] / (T - dac_skip));\n"
        "    struct ggml_tensor * lat = NULL;\n"
        "    if (lat_path) {\n"
        "        lat = ggml_cont(gctx, ggml_transpose(gctx, h));  // [1024, T50] -> memory [T50][1024]\n"
        "        ggml_set_name(lat, \"dac_latent\");\n"
        "        ggml_set_output(lat);\n"
        "    }\n"
        "    if (lat_ext) {\n"
        "        h = lat;\n"
        "    } else {\n" + a.replace("    h ", "        h ") + "    }\n") + s[j + len(a):]
    b = "    ggml_build_forward_expand(graph, h);\n"
    k = s.index(b, i)
    s = s[:k + len(b)] + "    if (lat && lat != h) {\n        ggml_build_forward_expand(graph, lat);\n    }\n" + s[k + len(b):]
    c = "    const int          n_samples = T * TOKENIZER_HOP_LENGTH;\n"
    k = s.index(c, i)
    s = s[:k + len(c)] + ("    if (lat_path) {  // fold2: latent for dacgpu\n"
        "        std::vector<float> lv((size_t) ggml_nelements(lat));\n"
        "        ggml_backend_tensor_get(lat, lv.data(), 0, lv.size() * sizeof(float));\n"
        "        FILE * lf = std::fopen(lat_path, \"wb\");\n"
        "        if (lf) {\n"
        "            const int32_t hd[4] = { 0x31434144, (int32_t) lat->ne[1], (int32_t) lat->ne[0], g_qt_dac_drop * lat_up };\n"
        "            std::fwrite(hd, 4, 4, lf);\n"
        "            std::fwrite(lv.data(), sizeof(float), lv.size(), lf);\n"
        "            std::fclose(lf);\n"
        "        }\n"
        "        if (lat_ext) {\n"
        "            return std::vector<float>((size_t) n_samples, 0.0f);\n"
        "        }\n"
        "    }\n") + s[k + len(c):]
    open(pc, "w").write(s)
t = open(pt).read()
if "g_qt_dac_ext_ok" not in t:
    t = t.replace("extern int g_qt_dac_skip;  // fold2", "extern int g_qt_dac_skip;  // fold2\nextern int g_qt_dac_ext_ok, g_qt_dac_drop;", 1)
    a = "                g_qt_dac_skip = (m >= 0 && T_dec <= chunk_frames && seed > m) ? seed - m : 0;\n"
    assert t.count(a) == 1
    t = t.replace(a, a + "                g_qt_dac_ext_ok = T_dec <= chunk_frames;\n                g_qt_dac_drop = seed - g_qt_dac_skip;\n")
    t = t.replace("            g_qt_dac_skip = 0;\n", "            g_qt_dac_skip = 0;\n            g_qt_dac_ext_ok = 0;\n", 1)
    open(pt, "w").write(t)
print("dacext: ok")
PYEOF
cmake --build build --target qwen-tts -j "$(nproc)"
echo "qwentts_fold2: готово"
