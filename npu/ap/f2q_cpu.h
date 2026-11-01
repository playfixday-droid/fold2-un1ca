// f2q_cpu.h - те же плитки f2q на ARM (NEON dotprod) - для части строк, пока DSP считает остальные
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// как f2q_mm_tiles, но пишет только строки < mrows; результат бит в бит равен f2q_mm_tiles_ref
void f2q_cpu_tiles(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                   const uint8_t * x, int n, int xstride, float * y, int ystride, int mrows);
#ifdef __cplusplus
}
#endif
