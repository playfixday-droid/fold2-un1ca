// f2q_pack.c - перепаковка весов и квантование активаций (см. f2q_format.h). Переносимый C.
#include "f2q_pack.h"
#include "f2q_format.h"
#include <math.h>
#include <string.h>

float f2q_fp16_to_fp32(uint16_t h) {
    const uint32_t s = (uint32_t) (h & 0x8000) << 16;
    uint32_t e = (h >> 10) & 0x1f, m = h & 0x3ff, u;
    if (e == 0) {
        if (m == 0) { u = s; }
        else { // денормализованное
            e = 127 - 15 + 1;
            while (!(m & 0x400)) { m <<= 1; e--; }
            u = s | (e << 23) | ((m & 0x3ff) << 13);
        }
    } else if (e == 31) {
        u = s | 0x7f800000 | (m << 13);
    } else {
        u = s | ((e + 127 - 15) << 23) | (m << 13);
    }
    float f;
    memcpy(&f, &u, 4);
    return f;
}

uint16_t f2q_fp32_to_fp16(float f) { // округление к ближайшему чётному, как в ggml
    uint32_t x;
    memcpy(&x, &f, 4);
    const uint32_t s = (x >> 16) & 0x8000;
    const int32_t e = (int32_t) ((x >> 23) & 0xff) - 127 + 15;
    uint32_t m = x & 0x7fffff;
    if (((x >> 23) & 0xff) == 0xff) return (uint16_t) (s | 0x7c00 | (m ? 0x200 : 0));
    if (e >= 31) return (uint16_t) (s | 0x7c00);
    if (e <= 0) {
        if (e < -10) return (uint16_t) s;
        m |= 0x800000;
        const int sh = 14 - e;
        uint32_t r = m >> sh;
        const uint32_t rem = m & ((1u << sh) - 1), half = 1u << (sh - 1);
        if (rem > half || (rem == half && (r & 1))) r++;
        return (uint16_t) (s | r);
    }
    uint32_t r = ((uint32_t) e << 10) | (m >> 13);
    const uint32_t rem = m & 0x1fff;
    if (rem > 0x1000 || (rem == 0x1000 && (r & 1))) r++;
    return (uint16_t) (s | r);
}

static inline int16_t qscale(float d, float R) {
    if (R == 0.0f) return 0;
    long v = lroundf(d / R * 32767.0f);
    if (v > 32767) v = 32767;
    if (v < -32767) v = -32767;
    return (int16_t) v;
}

void f2q_pack_weights(const void * src, int wtype, int M, int K, uint8_t * dst, int tile0, int tile1) {
    const int nb = f2q_nb(K), nv = f2q_wvecs(wtype);
    const size_t bsz = wtype == F2Q_W_Q4 ? 18 : 34; // байт на блок ggml
    const uint32_t tb = f2q_tile_bytes(wtype, K);
    for (int tile = tile0; tile < tile1; tile++) {
        uint8_t * tp = dst + (size_t) tile * tb;
        memset(tp, 0, tb);
        if (wtype == F2Q_W_Q8) { // нули весов = 128 (смещённый uint8)
            uint8_t * wp = tp + F2Q_VEC;
            for (int b = 0; b < nb; b += 2) {
                wp += F2Q_VEC;
                for (int h = 0; h < 2 && b + h < nb; h++) { memset(wp, 128, 8 * F2Q_VEC); wp += 8 * F2Q_VEC; }
            }
        } else {
            uint8_t * wp = tp + F2Q_VEC;
            for (int b = 0; b < nb; b += 2) {
                wp += F2Q_VEC;
                for (int h = 0; h < 2 && b + h < nb; h++) { memset(wp, 0x88, 4 * F2Q_VEC); wp += 4 * F2Q_VEC; }
            }
        }
        float * R = (float *) tp;
        for (int i = 0; i < F2Q_TILE; i++) {
            const int row = tile * F2Q_TILE + i;
            if (row >= M) break;
            const uint8_t * rs = (const uint8_t *) src + (size_t) row * nb * bsz;
            float mx = 0.0f;
            for (int b = 0; b < nb; b++) {
                uint16_t dh;
                memcpy(&dh, rs + b * bsz, 2);
                const float d = fabsf(f2q_fp16_to_fp32(dh));
                if (d > mx) mx = d;
            }
            R[i] = mx;
            uint8_t * wp = tp + F2Q_VEC;
            for (int b = 0; b < nb; b += 2) {
                int32_t * S = (int32_t *) wp;
                wp += F2Q_VEC;
                for (int h = 0; h < 2 && b + h < nb; h++) {
                    const int bb = b + h;
                    const uint8_t * blk = rs + bb * bsz;
                    uint16_t dh;
                    memcpy(&dh, blk, 2);
                    const int16_t m = qscale(f2q_fp16_to_fp32(dh), mx);
                    if (h) S[i] = (int32_t) (((uint32_t) S[i] & 0xFFFF0000u) | (uint16_t) m);
                    else S[i] = (int32_t) (((uint32_t) (uint16_t) m << 16) | ((uint32_t) S[i] & 0xFFFFu));
                    const uint8_t * qs = blk + 2;
                    for (int e = 0; e < F2Q_QK; e++) {
                        const int s = e / 4, j = e % 4;
                        if (wtype == F2Q_W_Q8) {
                            wp[s * F2Q_VEC + 4 * i + j] = (uint8_t) ((int8_t) qs[e] + 128);
                        } else {
                            const int u = e < 16 ? (qs[e] & 15) : (qs[e - 16] >> 4);
                            uint8_t * pb = wp + (s >> 1) * F2Q_VEC + 4 * i + j;
                            if (s & 1) *pb = (uint8_t) ((*pb & 0x0F) | (u << 4));
                            else *pb = (uint8_t) ((*pb & 0xF0) | u);
                        }
                    }
                    wp += nv * F2Q_VEC;
                }
            }
        }
    }
}

void f2q_unpack_weights(const uint8_t * src, int wtype, int M, int K, void * dst) {
    const int nb = f2q_nb(K), nv = f2q_wvecs(wtype);
    const size_t bsz = wtype == F2Q_W_Q4 ? 18 : 34;
    const uint32_t tb = f2q_tile_bytes(wtype, K);
    for (int row = 0; row < M; row++) {
        const int tile = row / F2Q_TILE, i = row % F2Q_TILE;
        const uint8_t * tp = src + (size_t) tile * tb;
        const float R = ((const float *) tp)[i];
        uint8_t * rd = (uint8_t *) dst + (size_t) row * nb * bsz;
        const uint8_t * wp = tp + F2Q_VEC;
        for (int b = 0; b < nb; b += 2) {
            const int32_t * S = (const int32_t *) wp;
            wp += F2Q_VEC;
            for (int h = 0; h < 2 && b + h < nb; h++) {
                const int bb = b + h;
                const int16_t m = h ? (int16_t) (S[i] & 0xFFFF) : (int16_t) ((uint32_t) S[i] >> 16);
                uint8_t * blk = rd + bb * bsz;
                const uint16_t dh = f2q_fp32_to_fp16((float) m / 32767.0f * R);
                memcpy(blk, &dh, 2);
                uint8_t * qs = blk + 2;
                if (wtype == F2Q_W_Q4) memset(qs, 0, 16);
                for (int e = 0; e < F2Q_QK; e++) {
                    const int s = e / 4, j = e % 4;
                    if (wtype == F2Q_W_Q8) {
                        qs[e] = (uint8_t) (int8_t) (wp[s * F2Q_VEC + 4 * i + j] - 128);
                    } else {
                        const uint8_t pb = wp[(s >> 1) * F2Q_VEC + 4 * i + j];
                        const int u = (s & 1) ? (pb >> 4) : (pb & 15);
                        if (e < 16) qs[e] |= (uint8_t) u; else qs[e - 16] |= (uint8_t) (u << 4);
                    }
                }
                wp += nv * F2Q_VEC;
            }
        }
    }
}

void f2q_quant_x(const float * x, int K, uint8_t * dst) {
    const int nb = f2q_nb(K);
    int8_t * q = (int8_t *) dst;
    int16_t * mx = (int16_t *) (dst + f2q_x_mx(K));
    int16_t * sx = (int16_t *) (dst + f2q_x_sx(K));
    float dd[4096];
    float * d16 = nb <= 4096 ? dd : NULL; // K до 131072
    float T = 0.0f;
    for (int b = 0; b < nb; b++) {
        float amax = 0.0f;
        for (int j = 0; j < F2Q_QK; j++) { const float v = fabsf(x[b * F2Q_QK + j]); if (v > amax) amax = v; }
        const float d = amax / 127.0f, id = d ? 1.0f / d : 0.0f;
        int s = 0;
        for (int j = 0; j < F2Q_QK; j++) {
            const int v = (int) roundf(x[b * F2Q_QK + j] * id);
            q[b * F2Q_QK + j] = (int8_t) v;
            s += v;
        }
        sx[b] = (int16_t) s;
        const float dr = f2q_fp16_to_fp32(f2q_fp32_to_fp16(d)); // как ggml: масштаб хранится в fp16
        if (d16) d16[b] = dr;
        if (dr > T) T = dr;
    }
    for (int b = 0; b < nb; b++) {
        float dr = d16 ? d16[b] : 0.0f;
        if (!d16) { // повтор для очень длинных строк
            float amax = 0.0f;
            for (int j = 0; j < F2Q_QK; j++) { const float v = fabsf(x[b * F2Q_QK + j]); if (v > amax) amax = v; }
            dr = f2q_fp16_to_fp32(f2q_fp32_to_fp16(amax / 127.0f));
        }
        mx[b] = qscale(dr, T);
    }
    memcpy(dst + f2q_x_t(K), &T, 4);
    const uint32_t used = (uint32_t) f2q_x_t(K) + 4, st = f2q_x_stride(K);
    if (st > used) memset(dst + used, 0, st - used);
}
