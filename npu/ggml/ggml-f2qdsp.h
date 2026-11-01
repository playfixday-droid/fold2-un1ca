// ggml-f2qdsp.h - дополнительный тип буфера CPU-бэкенда ggml: веса Q4_0/Q8_0 в формате f2q,
// MUL_MAT делится между cDSP (f2qdsp) и ядрами CPU. Включается переменной окружения F2QDSP=1.
#pragma once
#include "ggml-backend.h"

// nullptr, если F2QDSP не включён или DSP недоступен (тогда llama.cpp работает как обычно)
ggml_backend_buffer_type_t ggml_backend_cpu_f2qdsp_buffer_type(void);
