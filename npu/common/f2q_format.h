// f2q_format.h - общий для ARM (llama.cpp) и cDSP формат данных f2qdsp.
//
// Веса: матрица M x K (K % 32 == 0) режется на плитки по 32 строки (последняя дополняется нулями).
// Плитка:
//   float   R[32]                          - масштаб строки = max|d| по блокам строки
//   для каждой пары блоков p (блок = 32 элемента по K):
//     int32 S[32]                          - слово строки i: (m[2p] << 16) | (uint16) m[2p+1],
//                                            m = round(d_блока / R * 32767), int16
//     веса блока 2p, затем блока 2p+1 (если есть):
//       Q8: 8 векторов по 128 байт, вектор s: байт 4*i+j = q[i][4s+j] + 128   (uint8)
//       Q4: 4 вектора по 128 байт, вектор v: байт 4*i+j = u[i][8v+j] | u[i][8v+4+j] << 4,
//           u = q + 8 (0..15) - младшие полубайты дают шаг 2v, старшие - шаг 2v+1
// Активации: n строк по xstride байт (кратно 128):
//   int8  q[K]           - как q8_0 в ggml (d = amax/127, q = round(x/d))
//   int16 mx[nb]         - round(d_блока / T * 32767)
//   int16 sx[nb]         - сумма q по блоку
//   float T              - max d по блокам строки
// Результат: y[t][r] = R[r] * T * F2Q_C * 2^-P * sum_b mulhi(mulhi((acc_b - off*sx_b) << P, m_b), mx_b),
//   acc_b = sum_j w_b[j] * q_b[j] (w - uint8 как выше), off = 128 (Q8) или 8 (Q4),
//   mulhi(a, h) = sat32((2*a*h + 0x8000) >> 16) - это HVX vmpyo(Vw,Vh):<<1:rnd:sat и NEON vqrdmulh(a, h<<16).
//   P = f2q_shift(): максимальный сдвиг, при котором |сумма| <= 2^30 (точность без переполнения int32).
#pragma once
#include <stdint.h>

#define F2Q_VERSION   1
#define F2Q_TILE      32
#define F2Q_QK        32
#define F2Q_VEC       128
#define F2Q_W_Q8      0
#define F2Q_W_Q4      1
#define F2Q_C         1.0000610370189520f /* 2^30 / 32767^2 */

static inline int f2q_nb(int k) { return k / F2Q_QK; }
static inline int f2q_wvecs(int wtype) { return wtype == F2Q_W_Q4 ? 4 : 8; }
static inline int f2q_off(int wtype) { return wtype == F2Q_W_Q4 ? 8 : 128; }
static inline uint32_t f2q_tile_bytes(int wtype, int k) {
    const int nb = f2q_nb(k);
    return (uint32_t) (F2Q_VEC + ((nb + 1) / 2) * F2Q_VEC + nb * f2q_wvecs(wtype) * F2Q_VEC);
}
static inline uint32_t f2q_x_stride(int k) {
    const int nb = f2q_nb(k);
    return (uint32_t) ((k + 4 * nb + 4 + F2Q_VEC - 1) / F2Q_VEC * F2Q_VEC);
}
// смещения внутри строки активаций
static inline int f2q_x_mx(int k) { return k; }
static inline int f2q_x_sx(int k) { return k + 2 * f2q_nb(k); }
static inline int f2q_x_t(int k) { return k + 4 * f2q_nb(k); }

static inline int f2q_shift(int wtype, int k) {
    int lg = 0;
    while ((1 << lg) < f2q_nb(k)) lg++;
    const int p = (wtype == F2Q_W_Q4 ? 15 : 11) - lg; // |acc - off*sx| < 2^15 (Q4) / 2^19 (Q8)
    return p < 0 ? 0 : p;
}
// множитель результата: T * F2Q_C * 2^-P (одинаково на ARM и DSP)
static inline float f2q_out_scale(float T, int p) {
    union { uint32_t u; float f; } e;
    e.u = (uint32_t) (127 - p) << 23;
    return T * (F2Q_C * e.f);
}
static inline int32_t f2q_mulhi(int32_t a, int32_t h) {
    int64_t r = ((int64_t) a * h * 2 + 0x8000) >> 16;
    if (r > INT32_MAX) r = INT32_MAX;
    if (r < INT32_MIN) r = INT32_MIN;
    return (int32_t) r;
}
