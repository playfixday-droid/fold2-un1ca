// f2q_cpu.c - плитки f2q на CPU. NEON+dotprod (Kryo 585 / Cortex-A77/A55) или переносимый C.
#include "f2q_cpu.h"
#include "../common/f2q_format.h"
#include <string.h>
#if defined(__ARM_NEON) && defined(__ARM_FEATURE_DOTPROD)
#include <arm_neon.h>
#define F2Q_NEON 1
#endif

#ifdef F2Q_NEON
// одна плитка, одна строка активаций: 32 строки весов в 8 регистрах по 4
static void tile_row_neon(const uint8_t * tp, int Q4, int nb, int k, const uint8_t * xr, int32_t tot_out[32]) {
    int32x4_t tot[8];
    for (int r = 0; r < 8; r++) tot[r] = vdupq_n_s32(0);
    const int32_t * xw = (const int32_t *) xr;
    const int32_t * mx = (const int32_t *) (xr + f2q_x_mx(k));
    const uint8_t * wp = tp + F2Q_VEC;
    const uint8x16_t m4 = vdupq_n_u8(0x0F), x80 = vdupq_n_u8(0x80);
    const int8x16_t s8 = vdupq_n_s8(8);
    for (int b = 0; b < nb; b += 2) {
        const int32_t * S = (const int32_t *) wp;
        wp += F2Q_VEC;
        for (int h = 0; h < 2 && b + h < nb; h++) {
            const int bb = b + h;
            int32x4_t acc[8];
            for (int r = 0; r < 8; r++) acc[r] = vdupq_n_s32(0);
            if (Q4) {
                for (int v = 0; v < 4; v++) {
                    const int8x16_t xl = vreinterpretq_s8_s32(vdupq_n_s32(xw[bb * 8 + 2 * v]));
                    const int8x16_t xh = vreinterpretq_s8_s32(vdupq_n_s32(xw[bb * 8 + 2 * v + 1]));
                    for (int r = 0; r < 8; r++) {
                        const uint8x16_t pv = vld1q_u8(wp + v * F2Q_VEC + 16 * r);
                        const int8x16_t lo = vsubq_s8(vreinterpretq_s8_u8(vandq_u8(pv, m4)), s8);
                        const int8x16_t hi = vsubq_s8(vreinterpretq_s8_u8(vshrq_n_u8(pv, 4)), s8);
                        acc[r] = vdotq_s32(acc[r], lo, xl);
                        acc[r] = vdotq_s32(acc[r], hi, xh);
                    }
                }
                wp += 4 * F2Q_VEC;
            } else {
                for (int s = 0; s < 8; s++) {
                    const int8x16_t xs = vreinterpretq_s8_s32(vdupq_n_s32(xw[bb * 8 + s]));
                    for (int r = 0; r < 8; r++) {
                        const int8x16_t wv = vreinterpretq_s8_u8(veorq_u8(vld1q_u8(wp + s * F2Q_VEC + 16 * r), x80));
                        acc[r] = vdotq_s32(acc[r], wv, xs);
                    }
                }
                wp += 8 * F2Q_VEC;
            }
            const int32x4_t mxv = vdupq_n_s32((int32_t) ((uint32_t) mx[bb] & 0xFFFF0000u));
            const int32x4_t sh = vdupq_n_s32(f2q_mx_l(mx[bb], Q4));
            const int32x4_t rv = vdupq_n_s32(-f2q_mx_r(mx[bb])); // vrshl на -r = rsh(a, r)
            for (int r = 0; r < 8; r++) {
                int32x4_t sv = vld1q_s32(S + 4 * r);
                sv = h ? vshlq_n_s32(sv, 16) : vreinterpretq_s32_u32(vandq_u32(vreinterpretq_u32_s32(sv), vdupq_n_u32(0xFFFF0000u)));
                int32x4_t a = vshlq_s32(acc[r], sh);
                a = vqrdmulhq_s32(a, sv);
                a = vqrdmulhq_s32(a, mxv);
                a = vrshlq_s32(a, rv);
                tot[r] = vaddq_s32(tot[r], a);
            }
        }
    }
    for (int r = 0; r < 8; r++) vst1q_s32(tot_out + 4 * r, tot[r]);
}
#endif

static void tile_row_c(const uint8_t * tp, int Q4, int nb, int k, const uint8_t * xr, int32_t tot_out[32]) {
    const int8_t * xq = (const int8_t *) xr;
    const int32_t * mx = (const int32_t *) (xr + f2q_x_mx(k));
    uint32_t tot[F2Q_TILE] = { 0 };
    const uint8_t * wp = tp + F2Q_VEC;
    for (int b = 0; b < nb; b += 2) {
        const int32_t * S = (const int32_t *) wp;
        wp += F2Q_VEC;
        for (int h = 0; h < 2 && b + h < nb; h++) {
            const int bb = b + h;
            const int8_t * xb = xq + 32 * bb;
            for (int i = 0; i < F2Q_TILE; i++) {
                int32_t acc = 0;
                if (Q4) {
                    for (int v = 0; v < 4; v++) {
                        const uint8_t * pv = wp + v * F2Q_VEC + 4 * i;
                        for (int j = 0; j < 4; j++) {
                            acc += ((pv[j] & 15) - 8) * xb[8 * v + j];
                            acc += ((pv[j] >> 4) - 8) * xb[8 * v + 4 + j];
                        }
                    }
                } else {
                    for (int s = 0; s < 8; s++) {
                        const uint8_t * pv = wp + s * F2Q_VEC + 4 * i;
                        for (int j = 0; j < 4; j++) acc += ((int) pv[j] - 128) * xb[4 * s + j];
                    }
                }
                const int32_t m = h ? (int16_t) (S[i] & 0xFFFF) : (int16_t) ((uint32_t) S[i] >> 16);
                acc = (int32_t) ((uint32_t) acc << f2q_mx_l(mx[bb], Q4));
                acc = f2q_mulhi(acc, m);
                acc = f2q_mulhi(acc, f2q_mx_m(mx[bb]));
                acc = f2q_rsh(acc, f2q_mx_r(mx[bb]));
                tot[i] += (uint32_t) acc;
            }
            wp += (Q4 ? 4 : 8) * F2Q_VEC;
        }
    }
    memcpy(tot_out, tot, sizeof(tot));
}

void f2q_cpu_tiles(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                   const uint8_t * x, int n, int xstride, float * y, int ystride, int mrows) {
    const int nb = f2q_nb(k), Q4 = wtype == F2Q_W_Q4;
    const uint32_t tb = f2q_tile_bytes(wtype, k);
    int32_t tot[F2Q_TILE];
    for (int tile = tile0; tile < tile1; tile++) {
        const uint8_t * tp = w + (size_t) tile * tb;
        const float * R = (const float *) tp;
        const int r0 = tile * F2Q_TILE, nr = mrows - r0 < F2Q_TILE ? mrows - r0 : F2Q_TILE;
        for (int t = 0; t < n; t++) {
            const uint8_t * xr = x + (size_t) t * xstride;
#ifdef F2Q_NEON
            tile_row_neon(tp, Q4, nb, k, xr, tot);
#else
            tile_row_c(tp, Q4, nb, k, xr, tot);
#endif
            const float s = f2q_row_scale(xr, k, wtype);
            float * yr = y + (size_t) t * ystride + r0;
            for (int i = 0; i < nr; i++) yr[i] = (float) tot[i] * R[i] * s;
        }
    }
    (void) tile_row_c;
}
