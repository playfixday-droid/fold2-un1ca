// f2q_pack.h - перепаковка весов ggml (Q8_0/Q4_0) и квантование активаций в формат f2q_format.h
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
float    f2q_fp16_to_fp32(uint16_t h);
uint16_t f2q_fp32_to_fp16(float f);
// src: M строк по K/32 блоков ggml (block_q8_0: fp16 d + 32 int8; block_q4_0: fp16 d + 16 байт)
// dst: ceil(M/32) плиток по f2q_tile_bytes(wtype, K). Строки tile0*32 .. min(M, tile1*32)
void f2q_pack_weights(const void * src, int wtype, int M, int K, uint8_t * dst, int tile0, int tile1);
// обратно в ggml-блоки (для get_tensor / проверки)
void f2q_unpack_weights(const uint8_t * src, int wtype, int M, int K, void * dst);
// строка активаций float[K] -> строка формата f2q (q, mx, T, sx); dst длиной f2q_x_stride(K)
void f2q_quant_x(const float * x, int K, uint8_t * dst);
#ifdef __cplusplus
}
#endif
