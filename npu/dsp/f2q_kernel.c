// f2q_kernel.c - умножение плиток весов (Q8/Q4, формат f2q_format.h) на активации Q8.
// __HVX__: HVX 128B (Hexagon v66, cDSP SM8250). Иначе - только скалярная эталонная версия.
#include "f2q_kernel.h"
#include "../common/f2q_format.h"

void f2q_mm_tiles_ref(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                      const uint8_t * x, int n, int xstride, float * y, int ystride) {
    const int nb = f2q_nb(k), nv = f2q_wvecs(wtype), off = f2q_off(wtype);
    const uint32_t tb = f2q_tile_bytes(wtype, k);
    for (int tile = tile0; tile < tile1; tile++) {
        const uint8_t * tp = w + (uint32_t) tile * tb;
        const float * R = (const float *) tp;
        for (int t = 0; t < n; t++) {
            const uint8_t * xr = x + (uint32_t) t * (uint32_t) xstride;
            const int8_t * xq = (const int8_t *) xr;
            const int32_t * mx = (const int32_t *) (xr + f2q_x_mx(k));
            const int16_t * sx = (const int16_t *) (xr + f2q_x_sx(k));
            const float T = f2q_row_scale(xr, k, wtype);
            uint32_t tot[F2Q_TILE] = { 0 };
            const uint8_t * wp = tp + F2Q_VEC;
            for (int b = 0; b < nb; b += 2) {
                const int32_t * S = (const int32_t *) wp;
                wp += F2Q_VEC;
                for (int h = 0; h < 2 && b + h < nb; h++) {
                    const int bb = b + h;
                    for (int i = 0; i < F2Q_TILE; i++) {
                        int32_t acc = 0;
                        for (int s = 0; s < 8; s++) {
                            int u[4];
                            if (wtype == F2Q_W_Q4) {
                                const uint8_t * pv = wp + (s >> 1) * F2Q_VEC + 4 * i;
                                for (int j = 0; j < 4; j++) u[j] = (s & 1) ? (pv[j] >> 4) : (pv[j] & 15);
                            } else {
                                const uint8_t * pv = wp + s * F2Q_VEC + 4 * i;
                                for (int j = 0; j < 4; j++) u[j] = pv[j];
                            }
                            for (int j = 0; j < 4; j++) acc += u[j] * xq[32 * bb + 4 * s + j];
                        }
                        acc = (int32_t) ((uint32_t) (acc - off * sx[bb]) << f2q_mx_l(mx[bb], wtype));
                        const int32_t m = h ? (int16_t) (S[i] & 0xFFFF) : (int16_t) ((uint32_t) S[i] >> 16);
                        acc = f2q_mulhi(acc, m);
                        acc = f2q_mulhi(acc, f2q_mx_m(mx[bb]));
                        acc = f2q_rsh(acc, f2q_mx_r(mx[bb]));
                        tot[i] += (uint32_t) acc;
                    }
                    wp += nv * F2Q_VEC;
                }
            }
            float * yr = y + (uint32_t) t * (uint32_t) ystride + (uint32_t) tile * F2Q_TILE;
            for (int i = 0; i < F2Q_TILE; i++) yr[i] = (float) (int32_t) tot[i] * R[i] * T;
        }
    }
}

#if defined(__HVX__)
#include <hexagon_protos.h>
#include <hexagon_types.h>
#include <hvx_hexagon_protos.h>

#define AI static inline __attribute__((always_inline))

// Подкачка весов в L2 (l2fetch): у HVX нет своей предвыборки - без неё каждый блок весов ждёт DDR. Замер Fold2
// без подкачки: Q8 8192x2048 - 2,4 мс (7 ГБ/с), Q4 - 2,1 мс: вдвое меньше байт, а почти то же время - упор в задержку
// памяти, а не в пропускную способность. Поток идёт по своим плиткам подряд (они лежат в памяти друг за другом):
// окно F2Q_PF_W байт впереди подкачивается, пока считается текущее. F2Q_PF_W=0 - без подкачки (как раньше).
AI void f2q_l2fetch(const uint8_t * p, const uint8_t * lim, uint32_t len) {
    if (p >= lim) return;
    if ((uint32_t) (lim - p) < len) len = (uint32_t) (lim - p);
    // Rtt: [47:32] шаг, [31:16] ширина, [15:0] высота - одна «строка» len байт (len <= 65535)
    Q6_l2fetch_AP((void *) p, ((unsigned long long) len << 32) | ((unsigned long long) len << 16) | 1u);
}
typedef struct { const uint8_t * nxt, * lim; } f2q_pf;

// NT строк активаций за проход по плитке (веса читаются один раз)
AI void tile_core(const uint8_t * tp, const int Q4, const int NT, const int nb, const int k,
                  const uint8_t * const * xr, float * const * yr, f2q_pf * pf) {
    const int off = Q4 ? 8 : 128;
    const HVX_Vector vmask = Q6_V_vsplat_R(0x0F0F0F0F);
    HVX_Vector tot[4];
    const int32_t * xw[4];
    const int32_t * mx[4];
    const int16_t * sx[4];
    for (int t = 0; t < NT; t++) {
        tot[t] = Q6_V_vzero();
        xw[t] = (const int32_t *) xr[t];
        mx[t] = (const int32_t *) (xr[t] + f2q_x_mx(k));
        sx[t] = (const int16_t *) (xr[t] + f2q_x_sx(k));
    }
    const HVX_Vector * wp = (const HVX_Vector *) (tp + F2Q_VEC);
    for (int b = 0; b < nb; b += 2) {
#if F2Q_PF_W
        // текущее место ближе окна к границе подкачанного - следующее окно (прошлое к этому времени уже в L2)
        if ((const uint8_t *) wp + F2Q_PF_W >= pf->nxt && pf->nxt < pf->lim) {
            f2q_l2fetch(pf->nxt, pf->lim, F2Q_PF_W);
            pf->nxt += F2Q_PF_W;
        }
#endif
        const HVX_Vector sv = *wp++;
        for (int h = 0; h < 2 && b + h < nb; h++) {
            const int bb = b + h;
            const HVX_Vector mv = h ? Q6_Vw_vasl_VwR(sv, 16) : sv;
            HVX_Vector a0[4], a1[4];
            for (int t = 0; t < NT; t++) { a0[t] = Q6_V_vzero(); a1[t] = Q6_V_vzero(); }
            if (Q4) {
                for (int v = 0; v < 4; v++) {
                    const HVX_Vector pv = wp[v];
                    const HVX_Vector lo = Q6_V_vand_VV(pv, vmask);
                    const HVX_Vector hi = Q6_V_vand_VV(Q6_Vuh_vlsr_VuhR(pv, 4), vmask);
                    for (int t = 0; t < NT; t++) {
                        a0[t] = Q6_Vw_vrmpyacc_VwVubRb(a0[t], lo, xw[t][bb * 8 + 2 * v]);
                        a1[t] = Q6_Vw_vrmpyacc_VwVubRb(a1[t], hi, xw[t][bb * 8 + 2 * v + 1]);
                    }
                }
                wp += 4;
            } else {
                for (int s = 0; s < 8; s += 2) {
                    const HVX_Vector w0 = wp[s], w1 = wp[s + 1];
                    for (int t = 0; t < NT; t++) {
                        a0[t] = Q6_Vw_vrmpyacc_VwVubRb(a0[t], w0, xw[t][bb * 8 + s]);
                        a1[t] = Q6_Vw_vrmpyacc_VwVubRb(a1[t], w1, xw[t][bb * 8 + s + 1]);
                    }
                }
                wp += 8;
            }
            for (int t = 0; t < NT; t++) {
                HVX_Vector acc = Q6_Vw_vadd_VwVw(a0[t], a1[t]);
                const int32_t me = mx[t][bb], r = f2q_mx_r(me);
                acc = Q6_Vw_vsub_VwVw(acc, Q6_V_vsplat_R(off * (int32_t) sx[t][bb]));
                acc = Q6_Vw_vasl_VwR(acc, f2q_mx_l(me, Q4));
                acc = Q6_Vw_vmpyo_VwVh_s1_rnd_sat(acc, mv);
                acc = Q6_Vw_vmpyo_VwVh_s1_rnd_sat(acc, Q6_V_vsplat_R(me)); // vmpyo берёт старшее полуслово = m
                acc = Q6_Vw_vasr_VwR(Q6_Vw_vadd_VwVw(acc, Q6_V_vsplat_R((1 << r) >> 1)), r); // rsh(acc, r)
                tot[t] = Q6_Vw_vadd_VwVw(tot[t], acc);
            }
        }
    }
    const float * R = (const float *) tp;
    for (int t = 0; t < NT; t++) {
        HVX_Vector buf __attribute__((aligned(128))) = tot[t];
        const int32_t * a = (const int32_t *) &buf;
        const float s = f2q_row_scale(xr[t], k, Q4);
        for (int i = 0; i < F2Q_TILE; i++) yr[t][i] = (float) a[i] * R[i] * s;
    }
}

void f2q_mm_tiles(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                  const uint8_t * x, int n, int xstride, float * y, int ystride) {
    const int nb = f2q_nb(k);
    const uint32_t tb = f2q_tile_bytes(wtype, k);
    const int CH = 32; // строк активаций за раз (держим в L2)
    for (int t0 = 0; t0 < n; t0 += CH) {
        const int t1 = t0 + CH < n ? t0 + CH : n;
        // свои плитки [tile0, tile1) - один непрерывный кусок памяти: сразу два окна, дальше - по окну
        f2q_pf pf = { w + (uint32_t) tile0 * tb, w + (uint32_t) tile1 * tb };
#if F2Q_PF_W
        f2q_l2fetch(pf.nxt, pf.lim, 2 * F2Q_PF_W);
        pf.nxt += 2 * F2Q_PF_W;
#endif
        for (int tile = tile0; tile < tile1; tile++) {
            const uint8_t * tp = w + (uint32_t) tile * tb;
            int t = t0;
            for (; t + 4 <= t1; t += 4) {
                const uint8_t * xr[4];
                float * yr[4];
                for (int j = 0; j < 4; j++) {
                    xr[j] = x + (uint32_t) (t + j) * (uint32_t) xstride;
                    yr[j] = y + (uint32_t) (t + j) * (uint32_t) ystride + (uint32_t) tile * F2Q_TILE;
                }
                if (wtype == F2Q_W_Q4) tile_core(tp, 1, 4, nb, k, xr, yr, &pf); else tile_core(tp, 0, 4, nb, k, xr, yr, &pf);
            }
            for (; t < t1; t++) {
                const uint8_t * xr[1] = { x + (uint32_t) t * (uint32_t) xstride };
                float * yr[1] = { y + (uint32_t) t * (uint32_t) ystride + (uint32_t) tile * F2Q_TILE };
                if (wtype == F2Q_W_Q4) tile_core(tp, 1, 1, nb, k, xr, yr, &pf); else tile_core(tp, 0, 1, nb, k, xr, yr, &pf);
            }
        }
    }
}
#else
void f2q_mm_tiles(const uint8_t * w, int wtype, int k, int tile0, int tile1,
                  const uint8_t * x, int n, int xstride, float * y, int ystride) {
    f2q_mm_tiles_ref(w, wtype, k, tile0, tile1, x, n, xstride, y, ystride);
}
#endif
