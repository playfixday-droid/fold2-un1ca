// f2q_kernel.h - ядро умножения плиток f2qdsp (HVX на cDSP, скалярная эталонная версия на любом CPU)
#pragma once
#include <stdint.h>
// окно подкачки весов в L2 на DSP (байт, 0 - без подкачки), см. f2q_kernel.c
#ifndef F2Q_PF_W
#define F2Q_PF_W 8192
#endif
#ifdef __cplusplus
extern "C" {
#endif
// Плитки [tile0, tile1) весов w (начало массива плиток), n строк активаций x (шаг xstride байт).
// Пишет y[t * ystride + tile * 32 + i] (float), i = 0..31.
void f2q_mm_tiles(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                  const uint8_t * x, int n, int xstride, float * y, int ystride);
// Скалярная эталонная реализация (те же целочисленные операции бит в бит)
void f2q_mm_tiles_ref(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                      const uint8_t * x, int n, int xstride, float * y, int ystride);
#ifdef __cplusplus
}
#endif
