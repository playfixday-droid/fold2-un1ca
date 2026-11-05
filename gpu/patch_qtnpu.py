#!/usr/bin/env python3
# patch_qtnpu.py - после linux/phone/qwentts_fold2.sh (QT_REPACK=1 - веса Q8_0 в CPU_REPACK): QT_REPACK=2 кладёт те же
# веса в F2QDSP - матрицы считает NPU (Hexagon cDSP, Android-сборка с F2QDSP=1, npu/patch_llama.py). Аргумент - корень qwentts.cpp.
import sys
from pathlib import Path

p = Path(sys.argv[1]) / "src/weight-ctx.h"
s = p.read_text()
if "F2QDSP" in s:
    print("qtnpu: уже"); sys.exit(0)
a = '''    const char * e = std::getenv("QT_REPACK");
    if (!e || std::atoi(e) <= 0) {
        return NULL;
    }'''
b = '        if (std::strcmp(ggml_backend_buft_name(*b), "CPU_REPACK") == 0) {'
c = 'Q8_0 tensors (%.1f MB) in CPU_REPACK", n, (float) bytes / (1024 * 1024));'
for x in (a, b, c):
    if s.count(x) != 1:
        sys.exit(f"qtnpu: якорь не найден: {x[:60]!r}")
s = s.replace(a, a + '\n    const char * want = std::atoi(e) == 2 ? "F2QDSP" : "CPU_REPACK";  // fold2: 2 - NPU')
s = s.replace(b, '        if (std::strcmp(ggml_backend_buft_name(*b), want) == 0) {')
s = s.replace(c, 'Q8_0 tensors (%.1f MB) in %s", n, (float) bytes / (1024 * 1024), ggml_backend_buft_name(rb));')
p.write_text(s)
print("qtnpu: ok")
